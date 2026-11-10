// [device-access] Settings › Device Access: what this phone shares with the bots, and the rules for the requests they
// send (hermes-hq-push's device_access.py; Contacts in 0.9.19, every other kind in 0.9.21). Pure Foundation;
// DeviceAccessCenter applies them and one handler per kind (App/DeviceAccess) does the work. Each kind has switches
// ("scopes"): Contacts' details, Reminders' See and Add, Health's kinds of data… Everything starts off, the switches are
// this phone's (not an account's), and this phone checks every request against them, whatever the add-on last heard.
// The request and answer shapes are in docs/device-access.md.

import Foundation

nonisolated enum DeviceAccess {
    // MARK: Kinds and their switches

    /// What a bot may use from this phone; the order is the page's.
    enum Kind: String, CaseIterable, Codable, Sendable {
        case contacts, location, reminders, calendar, alarms, photos, health, motion, music, drafts

        var title: String {
            switch self {
            case .contacts: "Contacts"
            case .location: "Location"
            case .reminders: "Reminders"
            case .calendar: "Calendar"
            case .alarms: "Alarms & Timers"
            case .photos: "Photos"
            case .health: "Health"
            case .motion: "Motion & Fitness"
            case .music: "Music"
            case .drafts: "Email & Text Drafts"
            }
        }

        var systemImage: String {
            switch self {
            case .contacts: "person.crop.circle"
            case .location: "location"
            case .reminders: "checklist"
            case .calendar: "calendar"
            case .alarms: "alarm"
            case .photos: "photo.on.rectangle"
            case .health: "heart"
            case .motion: "figure.walk.motion"
            case .music: "music.note"
            case .drafts: "square.and.pencil"
            }
        }

        /// The switches, in the page's order. Location's precision is one choice of three (city, address, exact:
        /// each includes the ones before it) plus While Locked.
        var scopes: [Scope] {
            switch self {
            case .contacts: ContactField.allCases.map { Scope(key: $0.rawValue, title: $0.title, short: $0.short, systemImage: $0.systemImage) }
            case .location: [Scope(key: "city", title: "City", short: "City", systemImage: "building.2"),
                             Scope(key: "address", title: "Street Address", short: "Address", systemImage: "house"),
                             Scope(key: "exact", title: "Exact Location", short: "Exact", systemImage: "scope"),
                             Scope(key: "locked", title: "While Locked", short: "While Locked", systemImage: "lock")]
            case .reminders: [Scope(key: "read", title: "See Reminders", short: "See", systemImage: "eye"),
                              Scope(key: "write", title: "Add, Edit & Complete", short: "Add & Edit", systemImage: "square.and.pencil")]
            case .calendar: [Scope(key: "read", title: "See Events", short: "See", systemImage: "eye"),
                             Scope(key: "write", title: "Add Events", short: "Add", systemImage: "calendar.badge.plus")]
            case .alarms: [Scope(key: "set", title: "Set Alarms & Timers", short: "On", systemImage: "alarm")]
            case .photos: [Scope(key: "find", title: "Find Photos", short: "Find", systemImage: "magnifyingglass"),
                           Scope(key: "send", title: "Send Photos", short: "Send", systemImage: "paperplane")]
            // [health-all-types] One switch per Health type this iOS has (HealthCatalog), keyed by its HealthKit identifier.
            case .health: DeviceAccess.healthScopes
            case .motion: [Scope(key: "activity", title: "Activity & Steps", short: "On", systemImage: "figure.walk.motion")]
            case .music: [Scope(key: "nowPlaying", title: "What’s Playing", short: "Playing", systemImage: "music.note.list"),
                          Scope(key: "control", title: "Play & Pause", short: "Control", systemImage: "playpause")]
            case .drafts: [Scope(key: "email", title: "Email Drafts", short: "Email", systemImage: "envelope"),
                           Scope(key: "text", title: "Text Message Drafts", short: "Texts", systemImage: "message")]
            }
        }

        /// Switches that share something by themselves (Location's While Locked only changes when).
        var sharingKeys: Set<String> {
            switch self {
            case .location: ["city", "address", "exact"]
            case .health: DeviceAccess.healthScopeKeys
            default: Set(scopes.map(\.key))
            }
        }

        /// What the page says under the switches.
        var footer: String {
            switch self {
            case .contacts: "Your bots can look someone up by name, email address or phone number, and get only the details switched on here. They never get your whole address book."
            case .location: "Your bots can ask where you are, as precisely as you choose here. With While Locked off, they can ask only while the app is open."
            case .reminders: "Your bots can see your reminders and lists, and with Add, Edit & Complete, add new ones and tick them off."
            case .calendar: "Your bots can see your events, and with Add Events, put new ones on your calendar. They can’t change or delete events."
            case .alarms: "Your bots can set alarms and timers that ring like the Clock app’s, and see or cancel only the ones they set. Your own Clock alarms stay private."
            case .photos: "Your bots can find photos by date, place or favorite, and with Send Photos, get a copy of one to look at. Each photo found comes with about where it was taken (to roughly 100 m), even with Location off. They never get your whole library."
            case .health: "Your bots can read summaries of the kinds of Health data switched on here, never change them. Health can be read only while this \(DeviceWord.name) is unlocked."
            case .motion: "Your bots can tell whether you’re walking, running, driving or still, and how many steps you’ve taken."
            case .music: "Your bots can see what’s playing and, with Play & Pause, play something from your library, pause or skip."
            case .drafts: "Your bots can write an email or a text message for you. It waits on this \(DeviceWord.name) as a draft: nothing is sent until you \(DeviceWord.tap) Send."
            }
        }

        /// Kinds this device can do: a Mac has no Health, motion sensors, AlarmKit, Music player control or Messages composer.
        var available: Bool {
            #if targetEnvironment(macCatalyst)
            return [.contacts, .location, .reminders, .calendar, .photos, .drafts].contains(self)
            #else
            return true
            #endif
        }
    }

    /// One switch of a kind. `key` is the add-on's name for it.
    struct Scope: Equatable, Sendable, Hashable {
        let key: String
        let title: String
        /// The page's summary of what is on ("Phone, Email").
        let short: String
        let systemImage: String
    }

    /// A detail a contact lookup may return; the order is the page's.
    enum ContactField: String, CaseIterable, Codable, Sendable {
        case phone, email, birthday, address

        var title: String {
            switch self {
            case .phone: "Phone Numbers"
            case .email: "Email Addresses"
            case .birthday: "Birthdays"
            case .address: "Postal Addresses"
            }
        }

        var short: String {
            switch self {
            case .phone: "Phone"
            case .email: "Email"
            case .birthday: "Birthday"
            case .address: "Address"
            }
        }

        var systemImage: String {
            switch self {
            case .phone: "phone"
            case .email: "envelope"
            case .birthday: "gift"
            case .address: "mappin.and.ellipse"
            }
        }
    }

    /// Location's precision levels, least first; sharing one shares the ones before it.
    static let locationLevels = ["city", "address", "exact"]

    /// [health-all-types] Health's switches: every type this iOS has, in the page's order.
    static let healthScopes: [Scope] = HealthCatalog.available().map {
        Scope(key: $0.key, title: $0.name, short: $0.name, systemImage: $0.category.systemImage)
    }
    static let healthScopeKeys = Set(healthScopes.map(\.key))

    /// What this phone shares: per kind, the switches that are on. Everything starts off.
    struct Settings: Codable, Equatable, Sendable {
        var shared: [String: Set<String>] = [:]

        static let key = "hq.deviceAccess"

        init() {}

        static func load(_ defaults: UserDefaults = .standard) -> Settings {
            defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
        }

        func save(_ defaults: UserDefaults = .standard) {
            defaults.set(try? JSONEncoder().encode(self), forKey: Self.key)
        }

        private enum CodingKeys: String, CodingKey { case shared, contacts }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            shared = try c.decodeIfPresent([String: Set<String>].self, forKey: .shared) ?? [:]
            // Build 550 saved only Contacts' details, as {"contacts": ["phone", …]}.
            if shared.isEmpty, let old = try c.decodeIfPresent([String].self, forKey: .contacts), !old.isEmpty {
                shared[Kind.contacts.rawValue] = Set(old)
            }
            for (name, keys) in shared {
                guard let kind = Kind(rawValue: name) else { shared[name] = nil; continue }
                // [health-all-types] Before 0.9.46 Health had four switches (steps, sleep, workouts, heart): each turns
                // into the types it read, so what was shared stays shared and iOS asks nothing new.
                let kept = (kind == .health ? HealthCatalog.expandingLegacy(keys) : keys).intersection(kind.scopes.map(\.key))
                shared[name] = kept.isEmpty ? nil : kept
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(shared.filter { !$0.value.isEmpty }, forKey: .shared)
        }

        func scopes(_ kind: Kind) -> Set<String> { shared[kind.rawValue] ?? [] }
        func has(_ kind: Kind, _ key: String) -> Bool { scopes(kind).contains(key) }
        func shares(_ kind: Kind) -> Bool { !scopes(kind).isDisjoint(with: kind.sharingKeys) }
        var sharesAnything: Bool { Kind.allCases.contains(where: shares) }

        /// Turns one switch on or off. Location's levels stay a choice of one: turning one on turns the others off
        /// (`precision` says which is chosen), and turning the last off turns While Locked off too.
        mutating func set(_ kind: Kind, _ key: String, on: Bool) {
            var keys = scopes(kind)
            if kind == .location, DeviceAccess.locationLevels.contains(key) {
                keys.subtract(DeviceAccess.locationLevels)
                if on { keys.insert(key) } else { keys.remove("locked") }
            } else if on {
                keys.insert(key)
            } else {
                keys.remove(key)
            }
            if kind == .location, keys == ["locked"] { keys = [] }
            shared[kind.rawValue] = keys.isEmpty ? nil : keys
        }

        /// [health-all-types] Turns several switches of a kind on or off at once (a Health group's Turn On All).
        /// Not for Location, whose levels are a choice of one.
        mutating func set(_ kind: Kind, _ keys: Set<String>, on: Bool) {
            var current = scopes(kind)
            if on { current.formUnion(keys.intersection(kind.scopes.map(\.key))) } else { current.subtract(keys) }
            shared[kind.rawValue] = current.isEmpty ? nil : current
        }

        /// The location level chosen (nil: Location is off).
        var precision: String? { DeviceAccess.locationLevels.last { has(.location, $0) } }

        var contacts: Set<ContactField> {
            get { Set(scopes(.contacts).compactMap(ContactField.init(rawValue:))) }
            set { shared[Kind.contacts.rawValue] = newValue.isEmpty ? nil : Set(newValue.map(\.rawValue)) }
        }

        /// The add-on's shape: every kind with every switch named, {"contacts": {"phone": true, "email": false, …}, …}.
        /// Location's levels go up as cumulative ("exact" also says city and address).
        var wire: [String: Any] {
            var out: [String: Any] = [:]
            for kind in Kind.allCases {
                var keys = scopes(kind)
                if kind == .location, let level = precision, let index = DeviceAccess.locationLevels.firstIndex(of: level) {
                    keys.formUnion(DeviceAccess.locationLevels[...index])
                }
                if !kind.available { keys = [] }
                if kind == .health {
                    // [health-all-types] The four old switches, each on while one of its types is (an add-on before
                    // 0.9.46 knows only these), then every type that is on. Types that are off aren't listed.
                    var health: [String: Any] = Dictionary(uniqueKeysWithValues: HealthCatalog.legacyKeys.map { ($0, false) })
                    for key in HealthCatalog.legacyOn(keys) { health[key] = true }
                    for key in keys { health[key] = true }
                    out[kind.rawValue] = health
                    continue
                }
                out[kind.rawValue] = Dictionary(uniqueKeysWithValues: kind.scopes.map { ($0.key, keys.contains($0.key)) })
            }
            return out
        }

        /// The page's one-line summary of a kind: "Off", "On", or the short names of what's on ("Phone, Email").
        func summary(_ kind: Kind) -> String {
            guard shares(kind) else { return "Off" }
            if kind == .location {
                let level = kind.scopes.first { $0.key == precision }?.short ?? "On"
                return has(.location, "locked") ? "\(level), While Locked" : level
            }
            let on = kind.scopes.filter { has(kind, $0.key) }
            if kind.scopes.count == 1 || on.count == kind.scopes.count { return "On" }
            // [health-all-types] Health has a switch per type: how many are on, not their names.
            if kind == .health { return "\(on.count) On" }
            return on.map(\.short).joined(separator: ", ")
        }

        /// Settings' row: the kinds shared, or Off.
        var rowSummary: String {
            let on = Kind.allCases.filter { $0.available && shares($0) }
            switch on.count {
            case 0: return "Off"
            case 1: return on[0].title
            default: return "\(on.count) On"
            }
        }
    }

    /// The add-on's route (the push add-on's own, `deviceAccess` in its status).
    static func route(_ device: String) -> String { PushPolicy.route + "/device-access/" + device }

    /// Is this gateway's add-on one that takes Device Access?
    static func supported(_ status: [String: Any]?) -> Bool { PushPolicy.deviceAccess(status) }

    /// Does it take every kind (0.9.21's `deviceAccessKinds`), not only Contacts?
    static func supportsKinds(_ status: [String: Any]?) -> Bool {
        (status?["deviceAccessKinds"] as? NSNumber)?.boolValue == true
    }

    /// [health-all-types] Does it take every Health type (0.9.46's `deviceAccessHealthTypes`)? An older add-on hears
    /// only the four old Health switches, so its bots can read only steps, sleep, workouts and heart rate.
    static func supportsHealthTypes(_ status: [String: Any]?) -> Bool {
        (status?["deviceAccessHealthTypes"] as? NSNumber)?.boolValue == true
    }

    // MARK: Requests

    /// Each request the add-on sends, the kind it belongs to and the switches any one of which allows it.
    static let operations: [String: (kind: Kind, any: Set<String>)] = [
        "contacts.search": (.contacts, Kind.contacts.sharingKeys),
        "location.get": (.location, Kind.location.sharingKeys),
        "reminders.list": (.reminders, ["read"]),
        "reminders.create": (.reminders, ["write"]),
        "reminders.update": (.reminders, ["write"]),
        "calendar.list": (.calendar, ["read"]),
        "calendar.create": (.calendar, ["write"]),
        "alarms.set": (.alarms, ["set"]),
        "alarms.timer": (.alarms, ["set"]),
        "alarms.list": (.alarms, ["set"]),
        "alarms.cancel": (.alarms, ["set"]),
        "photos.search": (.photos, ["find"]),
        "photos.get": (.photos, ["send"]),
        "health.summary": (.health, Kind.health.sharingKeys),
        "motion.activity": (.motion, ["activity"]),
        "music.now": (.music, ["nowPlaying"]),
        "music.control": (.music, ["control"]),
        "drafts.create": (.drafts, ["email", "text"]),
    ]

    /// One thing a bot asked this phone (POST …/pending). `args` is the request's own JSON object, read by its handler.
    struct Request: Equatable, Sendable {
        let id: String
        let op: String
        var args: [String: JSONValue] = [:]
        /// The bot that asked (its profile name; "" for the main bot or an older add-on).
        var bot = ""

        var kind: Kind? { DeviceAccess.operations[op]?.kind }

        /// A trimmed string argument (nil when missing or empty), cut to `max` characters.
        func string(_ key: String, max: Int = 500) -> String? {
            guard let raw = args[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
            return String(raw.prefix(max))
        }
        func strings(_ key: String, max: Int = 20) -> [String] {
            (args[key]?.array ?? []).compactMap { $0.string?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.prefix(max).map { String($0.prefix(500)) }
        }
        func int(_ key: String) -> Int? { args[key]?.int }
        func double(_ key: String) -> Double? { args[key]?.double.flatMap { $0.isFinite ? $0 : nil } }
        func bool(_ key: String) -> Bool? { args[key]?.bool }
        /// A date argument: "2026-11-01" (that day's start here) or a date and time, with or without an offset (none: here).
        func date(_ key: String) -> Date? { string(key, max: 40).flatMap { DeviceAccess.date($0)?.date } }
        func hasTime(_ key: String) -> Bool { string(key, max: 40).flatMap { DeviceAccess.date($0)?.hasTime } ?? false }
    }

    static func requests(_ body: [String: Any]?) -> [Request] {
        (body?["requests"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String, id.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil,
                  let op = item["op"] as? String, !op.isEmpty else { return nil }
            var args: [String: JSONValue] = [:]
            if let raw = item["args"] as? [String: Any], JSONSerialization.isValidJSONObject(raw),
               let data = try? JSONSerialization.data(withJSONObject: raw), let value = try? JSONValue.parse(data) {
                args = value.object ?? [:]
            }
            return Request(id: id, op: String(op.prefix(40)), args: args, bot: String((item["profile"] as? String ?? "").prefix(64)))
        }
    }

    /// The answer posted back (POST …/results/<id>), and a file sent first when there is one (a photo).
    struct Answer: Equatable, Sendable {
        enum Status: String, Sendable { case done, failed, unavailable }
        struct File: Equatable, Sendable {
            var data: Data
            var type: String
            var name: String
        }
        var status: Status
        var result: [String: JSONValue] = [:]
        var error = ""
        var file: File? = nil

        static func done(_ result: [String: JSONValue] = [:]) -> Answer { Answer(status: .done, result: result) }
        static func unavailable(_ why: String) -> Answer { Answer(status: .unavailable, error: why) }
        static func failed(_ why: String) -> Answer { Answer(status: .failed, error: why) }

        /// A list answer: the items under `key`, how many, and whether more matched than were sent.
        static func list(_ key: String, _ items: [JSONValue], more: Bool = false, extra: [String: JSONValue] = [:]) -> Answer {
            var result = extra
            result[key] = .array(items)
            result["count"] = .number(Double(items.count))
            if more { result["more"] = true }
            return .done(result)
        }

        static func contacts(_ people: [Contact], more: Bool) -> Answer { list("contacts", people.map(\.wire), more: more) }

        /// How many things came back, for the log (never what they were).
        var count: Int? { result["count"]?.int }

        var body: [String: Any] {
            ["status": status.rawValue, "result": DeviceAccess.foundation(.object(result)), "error": error]
        }
    }

    // Audit 09-12: what bots hear names this device ("this Mac", "this iPad") and this app as it's called, since a
    // bot may say it back to the person.
    static var here: String { "this \(DeviceWord.name)" }
    static var app: String { AppIdentity.current.displayName }
    static var unknownWords: String { "This version of \(app) can’t do that yet." }
    static func offWords(_ kind: Kind) -> String { "\(kind.title) sharing is off on \(here)." }
    static func notAllowedWords(_ kind: Kind) -> String { "\(app) isn’t allowed to use \(kind.title) on \(here)." }
    static func scopeOffWords(_ kind: Kind, _ keys: Set<String>) -> String {
        let names = kind.scopes.filter { keys.contains($0.key) }.map { "“\($0.title)”" }
        return "\(kind.title): \(names.joined(separator: " or ")) is off on \(here)."
    }
    static func notHereWords(_ kind: Kind) -> String { "\(kind.title) isn’t available on this device." }

    /// Requests that change something on the device (a reminder, an event, an alarm, a draft, what plays).
    static let changingOps: Set<String> = ["reminders.create", "reminders.update", "calendar.create", "alarms.set",
                                           "alarms.timer", "alarms.cancel", "music.control", "drafts.create"]

    /// What the bot hears when its request ran past its time. Audit 09-9: one that changes something may still have
    /// done it, so the bot checks before asking again (rather than adding a second reminder).
    static func tooLongWords(_ op: String) -> String {
        let late = "The \(DeviceWord.name) took too long to answer."
        return changingOps.contains(op) ? late + " It may still have done it: check before asking again." : late
    }

    /// Audit 09-8: the time one more request may take with `left` seconds of background time: its own `each`, less
    /// a few seconds to send the answer, or nil when that leaves too little to start it.
    static func requestSeconds(left: Double, each: Double) -> Double? {
        let room = left - 3
        return room < 2 ? nil : min(each, room)
    }

    /// What this phone does with a request: hand it to its kind's handler with the switches that are on, or answer at
    /// once with why it can't.
    enum Check: Equatable, Sendable {
        case run(Kind, scopes: Set<String>)
        case answer(Answer)
    }

    static func check(_ request: Request, settings: Settings) -> Check {
        guard let rule = operations[request.op] else { return .answer(.unavailable(unknownWords)) }
        guard rule.kind.available else { return .answer(.unavailable(notHereWords(rule.kind))) }
        guard settings.shares(rule.kind) else { return .answer(.unavailable(offWords(rule.kind))) }
        let on = settings.scopes(rule.kind)
        guard !on.isDisjoint(with: rule.any) else { return .answer(.unavailable(scopeOffWords(rule.kind, rule.any))) }
        return .run(rule.kind, scopes: on)
    }

    // MARK: Contacts

    /// A lookup's plan: what to search for and which details to return (the asked ones that are on; none asked or
    /// none of them on: every one that is on).
    static func contactsPlan(_ request: Request, shared: Set<String>) -> (query: String, fields: Set<ContactField>)? {
        guard let query = request.string("query", max: 120) else { return nil }
        let on = Set(shared.compactMap(ContactField.init(rawValue:)))
        let asked = Set(request.strings("fields").compactMap(ContactField.init(rawValue:)))
        let kept = asked.intersection(on)
        return (query, kept.isEmpty ? on : kept)
    }

    /// What a query is: an email address, a phone number, or (anything else) part of a name.
    enum QueryKind: Equatable, Sendable { case email, phone, name }

    static func kind(of query: String) -> QueryKind {
        if query.contains("@") { return .email }
        let digits = query.filter(\.isNumber).count
        let phoneish = query.allSatisfy { $0.isNumber || " +-().".contains($0) }
        return phoneish && digits >= 5 ? .phone : .name
    }

    struct Labeled: Equatable, Sendable {
        var label: String
        var value: String
        var wire: JSONValue { label.isEmpty ? ["value": .string(value)] : ["label": .string(label), "value": .string(value)] }
    }

    /// One person found, with only the details shared. The name (and company) always come: they are what was looked up.
    struct Contact: Equatable, Sendable {
        var name: String
        var organization = ""
        var phones: [Labeled]? = nil
        var emails: [Labeled]? = nil
        var birthday: String? = nil
        var addresses: [Labeled]? = nil

        var wire: JSONValue {
            var out: [String: JSONValue] = ["name": .string(name)]
            if !organization.isEmpty { out["organization"] = .string(organization) }
            if let phones { out["phones"] = .array(phones.map(\.wire)) }
            if let emails { out["emails"] = .array(emails.map(\.wire)) }
            if let birthday { out["birthday"] = .string(birthday) }
            if let addresses { out["addresses"] = .array(addresses.map(\.wire)) }
            return .object(out)
        }
    }

    /// A birthday as the bot reads it: 1990-05-12, or --05-12 when the year isn't saved.
    static func birthday(_ parts: DateComponents?) -> String? {
        guard let parts, let month = parts.month, let day = parts.day else { return nil }
        let monthDay = String(format: "%02d-%02d", month, day)
        if let year = parts.year, year != NSDateComponentUndefined { return String(format: "%04d-", year) + monthDay }
        return "--" + monthDay
    }

    static let maxMatches = 10

    // MARK: Dates

    /// "2026-11-01" (the day's start here, hasTime false), "2026-11-01T09:30", "2026-11-01 09:30:15" (here), or with
    /// "Z"/"+02:00". nil for anything else.
    static func date(_ text: String, calendar: Calendar = .current) -> (date: Date, hasTime: Bool)? {
        let s = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "T")
        let pattern = #"^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?(Z|[+-]\d{2}:?\d{2})?)?$"#
        guard let match = s.range(of: pattern, options: .regularExpression), match == s.startIndex..<s.endIndex,
              let regex = try? NSRegularExpression(pattern: pattern),
              let found = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        func group(_ i: Int) -> String? {
            let r = found.range(at: i)
            return r.location == NSNotFound ? nil : Range(r, in: s).map { String(s[$0]) }
        }
        var parts = DateComponents()
        parts.year = group(1).flatMap(Int.init); parts.month = group(2).flatMap(Int.init); parts.day = group(3).flatMap(Int.init)
        let hasTime = group(4) != nil
        parts.hour = group(4).flatMap(Int.init) ?? 0; parts.minute = group(5).flatMap(Int.init) ?? 0
        parts.second = group(6).flatMap(Int.init) ?? 0
        guard let month = parts.month, (1...12).contains(month), let day = parts.day, (1...31).contains(day),
              (0...23).contains(parts.hour ?? 0), (0...59).contains(parts.minute ?? 0), (0...60).contains(parts.second ?? 0) else { return nil }
        var cal = calendar
        if let zone = group(7) {
            if zone == "Z" { cal.timeZone = TimeZone(secondsFromGMT: 0)! } else {
                let digits = zone.dropFirst().replacingOccurrences(of: ":", with: "")
                guard let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2)) else { return nil }
                let seconds = (hours * 3600 + minutes * 60) * (zone.hasPrefix("-") ? -1 : 1)
                guard let tz = TimeZone(secondsFromGMT: seconds) else { return nil }
                cal.timeZone = tz
            }
        }
        guard let date = cal.date(from: parts), cal.component(.day, from: date) == day else { return nil }
        return (date, hasTime)
    }

    /// A date and time as the bot reads it: "2026-11-01T09:30:00-05:00" (this phone's offset).
    static func stamp(_ date: Date, zone: TimeZone = .current) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = zone
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    /// A day as the bot reads it: "2026-11-01".
    static func day(_ date: Date, zone: TimeZone = .current) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = zone
        f.formatOptions = [.withFullDate]
        return f.string(from: date)
    }

    // MARK: Recent Requests

    /// One line of the page's Recent Requests: kept on this phone only (the last 50), never sent anywhere.
    struct LogEntry: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var date: Date
        var op: String
        var bot: String
        var summary: String
        var status: String
        var count: Int?

        /// `status` for an answer that couldn't be sent back to the gateway.
        static let undelivered = "undelivered"
    }

    /// The request in a few words, as Recent Requests shows it ("Look up “Ann”", "Location (city)").
    static func describe(_ request: Request) -> String {
        func quoted(_ key: String, max: Int = 40) -> String? { request.string(key, max: max).map { "“\($0)”" } }
        switch request.op {
        case "contacts.search": return ["Look up", quoted("query")].compactMap { $0 }.joined(separator: " ")
        case "location.get": return "Location" + (request.string("precision").map { " (\($0))" } ?? "")
        case "reminders.list": return quoted("search").map { "Reminders matching \($0)" } ?? "See reminders"
        case "reminders.create": return ["New reminder", quoted("title")].compactMap { $0 }.joined(separator: " ")
        case "reminders.update": return request.bool("completed") == true ? "Complete a reminder" : "Edit a reminder"
        case "calendar.list": return quoted("search").map { "Events matching \($0)" } ?? "See events"
        case "calendar.create": return ["New event", quoted("title")].compactMap { $0 }.joined(separator: " ")
        case "alarms.set": return ["Alarm", request.string("time", max: 10)].compactMap { $0 }.joined(separator: " ")
        case "alarms.timer":
            let seconds = request.int("seconds") ?? 0
            return seconds >= 60 ? "Timer \(seconds / 60) min" : "Timer \(seconds) s"
        case "alarms.list": return "See alarms"
        case "alarms.cancel": return "Cancel an alarm"
        case "photos.search": return "Find photos"
        case "photos.get": return "Send a photo"
        case "health.summary":
            // [health-all-types] Types by their names ("Health: Heart Rate, Steps and 3 more").
            let asked = request.strings("categories").map { HealthCatalog.Category(rawValue: $0)?.title ?? $0 }
                + request.strings("metrics", max: DeviceAccess.healthMaxAsked).map(HealthCatalog.name)
            guard !asked.isEmpty else { return "Health summary" }
            let shown = asked.prefix(3).joined(separator: ", ")
            return "Health: " + (asked.count > 3 ? "\(shown) and \(asked.count - 3) more" : shown)
        case "motion.activity": return "Motion & activity"
        case "music.now": return "What’s playing"
        case "music.control":
            let action = request.string("action", max: 20) ?? "play"
            return ["Music: \(action)", quoted("query")].compactMap { $0 }.joined(separator: " ")
        case "drafts.create":
            let what = request.string("kind") == "text" ? "Text draft" : "Email draft"
            return [what, request.strings("to", max: 1).first.map { "to \($0)" }].compactMap { $0 }.joined(separator: " ")
        default: return request.op
        }
    }

    // MARK: JSON

    /// A JSONValue as JSONSerialization takes it.
    static func foundation(_ value: JSONValue) -> Any {
        switch value {
        case .null: NSNull()
        case .bool(let b): b
        case .number(let n): n.rounded() == n && abs(n) < 9.007e15 ? Int(n) as Any : n as Any
        case .string(let s): s
        case .array(let a): a.map(foundation)
        case .object(let o): o.mapValues(foundation)
        }
    }
}
