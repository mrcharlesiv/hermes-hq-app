// [device-access] Settings › Device Access rules (HermesKit/Device/DeviceAccess.swift): what is shared and how it goes
// to the add-on, reading the requests bots sent, this phone's own check of each one, and what is posted back.

import Foundation
import Testing
@testable import HermesHQNative

@MainActor struct DeviceAccessTests {
    private let id = String(repeating: "a", count: 32)

    private func request(_ op: String, _ args: [String: JSONValue] = [:]) -> DeviceAccess.Request {
        DeviceAccess.Request(id: id, op: op, args: args)
    }

    @Test func nothingIsSharedAtFirstAndSwitchesSaveAndSayEveryDetail() throws {
        let defaults = try #require(UserDefaults(suiteName: "device-access-\(UUID().uuidString)"))
        #expect(DeviceAccess.Settings.load(defaults) == DeviceAccess.Settings())
        #expect(!DeviceAccess.Settings.load(defaults).sharesAnything)
        var settings = DeviceAccess.Settings()
        settings.contacts = [.phone, .email]
        settings.set(.reminders, "read", on: true)
        settings.save(defaults)
        #expect(DeviceAccess.Settings.load(defaults) == settings)
        let contacts = try #require(settings.wire["contacts"] as? [String: Bool])
        #expect(contacts == ["phone": true, "email": true, "birthday": false, "address": false])
        #expect(settings.wire["reminders"] as? [String: Bool] == ["read": true, "write": false])
        #expect(settings.wire["health"] as? [String: Bool] == ["steps": false, "sleep": false, "workouts": false, "heart": false])
        #expect(settings.summary(.contacts) == "Phone, Email" && settings.summary(.reminders) == "See" && settings.summary(.photos) == "Off")
        #expect(settings.rowSummary == "2 On")
    }

    @Test func build550sContactsStillLoad() throws {
        let defaults = try #require(UserDefaults(suiteName: "device-access-\(UUID().uuidString)"))
        defaults.set(Data(#"{"contacts":["phone","ssn"]}"#.utf8), forKey: DeviceAccess.Settings.key)
        let settings = DeviceAccess.Settings.load(defaults)
        #expect(settings.contacts == [.phone] && settings.shares(.contacts) && !settings.shares(.location))
    }

    @Test func locationIsOneLevelAndWhileLockedNeedsOne() {
        var settings = DeviceAccess.Settings()
        settings.set(.location, "locked", on: true)
        #expect(!settings.shares(.location) && settings.scopes(.location).isEmpty, "While Locked alone shares nothing")
        settings.set(.location, "city", on: true)
        settings.set(.location, "locked", on: true)
        settings.set(.location, "exact", on: true)
        #expect(settings.precision == "exact" && settings.scopes(.location) == ["exact", "locked"])
        #expect(settings.wire["location"] as? [String: Bool] == ["city": true, "address": true, "exact": true, "locked": true],
                "the add-on hears exact as city, address and exact")
        #expect(settings.summary(.location) == "Exact, While Locked")
        settings.set(.location, "exact", on: false)
        #expect(settings.precision == nil && !settings.shares(.location) && !settings.has(.location, "locked"))
    }

    @Test func requestsAreReadAndBadOnesDropped() {
        let body: [String: Any] = ["requests": [
            ["id": id, "op": "contacts.search", "profile": "otto", "args": ["query": "  Ann  ", "fields": ["phone", "ssn"]]],
            ["id": "../x", "op": "contacts.search", "args": ["query": "Ann"]],
            ["id": String(repeating: "b", count: 32), "op": "photos.list", "args": [:]],
            ["id": String(repeating: "c", count: 32), "op": "calendar.list", "args": ["start": "2026-11-01", "limit": 5]],
        ]]
        let requests = DeviceAccess.requests(body)
        #expect(requests.count == 3)
        #expect(requests[0].op == "contacts.search" && requests[0].bot == "otto" && requests[0].string("query") == "Ann")
        #expect(requests[0].strings("fields") == ["phone", "ssn"] && requests[0].kind == .contacts)
        #expect(requests[1].op == "photos.list" && requests[1].kind == nil)
        #expect(requests[2].int("limit") == 5 && requests[2].hasTime("start") == false && requests[2].date("start") != nil)
    }

    @Test func thisPhoneChecksEveryRequestAgainstItsSwitches() {
        var settings = DeviceAccess.Settings()
        let lookup = request("contacts.search", ["query": "Ann", "fields": ["phone", "birthday"]])
        #expect(DeviceAccess.check(lookup, settings: settings) == .answer(.unavailable(DeviceAccess.offWords(.contacts))))
        settings.contacts = [.phone, .email]
        #expect(DeviceAccess.check(lookup, settings: settings) == .run(.contacts, scopes: ["phone", "email"]))
        #expect(DeviceAccess.contactsPlan(lookup, shared: ["phone", "email"])?.fields == [.phone])
        #expect(DeviceAccess.contactsPlan(request("contacts.search", ["query": "Ann", "fields": ["birthday"]]), shared: ["email"])?.fields == [.email],
                "none of the asked details is shared: the shared ones")
        #expect(DeviceAccess.contactsPlan(request("contacts.search"), shared: ["email"]) == nil)

        settings.set(.reminders, "read", on: true)
        #expect(DeviceAccess.check(request("reminders.list"), settings: settings) == .run(.reminders, scopes: ["read"]))
        #expect(DeviceAccess.check(request("reminders.create", ["title": "Milk"]), settings: settings)
                == .answer(.unavailable(DeviceAccess.scopeOffWords(.reminders, ["write"]))))
        #expect(DeviceAccess.check(request("photos.list"), settings: settings) == .answer(.unavailable(DeviceAccess.unknownWords)))
    }

    /// Audit 09-12: what bots hear names this device and this app, never "this phone" on a Mac or iPad.
    @Test func botWordsNameThisDevice() {
        #expect(DeviceAccess.offWords(.contacts) == "Contacts sharing is off on this \(DeviceWord.name).")
        #expect(DeviceAccess.notAllowedWords(.photos).hasPrefix(AppIdentity.current.displayName + " isn’t allowed"))
        #expect(DeviceAccess.scopeOffWords(.reminders, ["write"]).hasSuffix("is off on this \(DeviceWord.name)."))
    }

    /// Audit 09-14: drafts come to the device and alarms are set on it; the other kinds go up when a bot asks.
    @Test func consentSaysWhichWayThingsGo() {
        #expect(DeviceAccessConsent.message(.contacts).hasPrefix("Your Contacts will be sent to your Hermes gateway"))
        #expect(!DeviceAccessConsent.message(.drafts).contains("will be sent"))
        #expect(DeviceAccessConsent.message(.drafts).contains("nothing is sent until you tap Send"))
        #expect(DeviceAccessConsent.message(.alarms).contains("set alarms and timers"))
    }

    /// Audit 09-8 and 09-9: a wake-up's requests fit its background time; a late one that changes something may
    /// still have happened.
    @Test func backgroundTimeIsShared() {
        #expect(DeviceAccess.requestSeconds(left: 26, each: 20) == 20)
        #expect(DeviceAccess.requestSeconds(left: 10, each: 20) == 7)
        #expect(DeviceAccess.requestSeconds(left: 4, each: 20) == nil)
        #expect(DeviceAccess.tooLongWords("reminders.create").contains("check before asking again"))
        #expect(!DeviceAccess.tooLongWords("reminders.list").contains("check before"))
    }

    @Test func queriesAreEmailPhoneOrName() {
        #expect(DeviceAccess.kind(of: "ann@example.com") == .email)
        #expect(DeviceAccess.kind(of: "+1 (555) 010-2000") == .phone)
        #expect(DeviceAccess.kind(of: "555") == .name)
        #expect(DeviceAccess.kind(of: "Ann Lee") == .name)
    }

    @Test func answersCarryOnlyWhatWasFound() throws {
        var person = DeviceAccess.Contact(name: "Ann Lee", organization: "Acme")
        person.phones = [.init(label: "mobile", value: "+1 555")]
        let answer = DeviceAccess.Answer.contacts([person], more: true)
        #expect(answer.count == 1)
        let body = answer.body
        #expect(body["status"] as? String == "done")
        let result = try #require(body["result"] as? [String: Any])
        #expect(result["count"] as? Int == 1 && result["more"] as? Bool == true)
        let first = try #require((result["contacts"] as? [[String: Any]])?.first)
        #expect(first["name"] as? String == "Ann Lee" && first["organization"] as? String == "Acme")
        #expect(first["emails"] == nil && first["birthday"] == nil)
        #expect((first["phones"] as? [[String: String]]) == [["label": "mobile", "value": "+1 555"]])
        #expect(JSONSerialization.isValidJSONObject(body))
    }

    @Test func datesBothWays() throws {
        let zone = try #require(TimeZone(identifier: "America/Chicago"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let day = try #require(DeviceAccess.date("2026-11-01", calendar: calendar))
        #expect(!day.hasTime && DeviceAccess.stamp(day.date, zone: zone) == "2026-11-01T00:00:00-05:00")
        let local = try #require(DeviceAccess.date("2026-11-01 09:30", calendar: calendar))
        #expect(local.hasTime && DeviceAccess.stamp(local.date, zone: zone) == "2026-11-01T09:30:00-06:00")
        let utc = try #require(DeviceAccess.date("2026-11-01T15:00:00Z", calendar: calendar))
        #expect(DeviceAccess.day(utc.date, zone: zone) == "2026-11-01")
        #expect(DeviceAccess.date("2026-02-30", calendar: calendar) == nil && DeviceAccess.date("tomorrow", calendar: calendar) == nil)
    }

    @Test func recentRequestsSayWhatWasAskedInAFewWords() {
        #expect(DeviceAccess.describe(request("contacts.search", ["query": "Ann"])) == "Look up “Ann”")
        #expect(DeviceAccess.describe(request("location.get", ["precision": "city"])) == "Location (city)")
        #expect(DeviceAccess.describe(request("alarms.timer", ["seconds": 600])) == "Timer 10 min")
        #expect(DeviceAccess.describe(request("drafts.create", ["kind": "text", "to": ["Ann"]])) == "Text draft to Ann")
        #expect(DeviceAccess.describe(request("photos.list")) == "photos.list")
    }

    @Test func birthdaysWithAndWithoutAYear() {
        #expect(DeviceAccess.birthday(DateComponents(year: 1990, month: 5, day: 12)) == "1990-05-12")
        #expect(DeviceAccess.birthday(DateComponents(month: 5, day: 12)) == "--05-12")
        #expect(DeviceAccess.birthday(nil) == nil)
    }

    @Test func theAddOnSaysWhetherItTakesDeviceAccess() {
        #expect(DeviceAccess.supported(["deviceAccess": true]) && !DeviceAccess.supportsKinds(["deviceAccess": true]))
        #expect(DeviceAccess.supportsKinds(["deviceAccess": true, "deviceAccessKinds": true]))
        #expect(!DeviceAccess.supported(["namedSites": true]))
        #expect(DeviceAccess.route("X-1") == "/api/plugins/hermes-hq-push/device-access/X-1")
    }

    @Test func everyRequestHasAKindAndEveryKindItsSwitches() {
        for (op, rule) in DeviceAccess.operations {
            #expect(op.hasPrefix(rule.kind.rawValue + "."), "\(op)")
            #expect(rule.any.isSubset(of: Set(rule.kind.scopes.map(\.key))), "\(op)")
        }
        for kind in DeviceAccess.Kind.allCases {
            #expect(DeviceAccess.operations.values.contains { $0.kind == kind }, "\(kind) has requests")
        }
    }
}
