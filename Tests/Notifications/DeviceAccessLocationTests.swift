// [device-access] Location: DeviceAccess+Location's pure parts (precision choice, region parsing), plus live checks
// of LocationAccess.answer against this simulator's set position (xcrun simctl location $SIM set 41.8781,-87.6298).

import CoreLocation
import Foundation
import Testing
@testable import HermesHQNative

@MainActor struct DeviceAccessLocationTests {
    private let id = String(repeating: "a", count: 32)

    private func request(_ args: [String: JSONValue] = [:]) -> DeviceAccess.Request {
        DeviceAccess.Request(id: id, op: "location.get", args: args)
    }

    @Test func precisionIsTheLowerOfAskedAndShared() {
        #expect(DeviceAccess.locationPrecision(asked: nil, scopes: ["exact"]) == "exact")
        #expect(DeviceAccess.locationPrecision(asked: "city", scopes: ["exact"]) == "city")
        #expect(DeviceAccess.locationPrecision(asked: "exact", scopes: ["city"]) == "city")
        #expect(DeviceAccess.locationPrecision(asked: "address", scopes: ["exact", "address"]) == "address")
        #expect(DeviceAccess.locationPrecision(asked: "nonsense", scopes: ["address"]) == "address", "a bad ask falls back to what's shared")
        #expect(DeviceAccess.locationPrecision(asked: "city", scopes: ["locked"]) == nil, "locked alone shares nothing")
    }

    @Test func regionComesFromTheCityWithContextString() {
        #expect(DeviceAccess.locationRegion(city: "Cupertino", cityWithContext: "Cupertino, CA") == "CA")
        #expect(DeviceAccess.locationRegion(city: "Paris", cityWithContext: "Paris") == nil, "nothing after the city")
        #expect(DeviceAccess.locationRegion(city: nil, cityWithContext: "Cupertino, CA") == nil)
        #expect(DeviceAccess.locationRegion(city: "Cupertino", cityWithContext: nil) == nil)
        #expect(DeviceAccess.locationRegion(city: "Cupertino", cityWithContext: "Somewhere Else") == nil, "doesn't start with the city")
    }

    /// Audit 09-7: with Precise Location off, nothing is labelled exact (or a street address); a city stays a city.
    @Test func precisionOffSaysApproximate() {
        let exact: [String: JSONValue] = ["precision": "exact", "timezone": "UTC"]
        #expect(DeviceAccess.locationApproximated(exact, approximate: false, accuracy: 5) == exact)
        let rough = DeviceAccess.locationApproximated(exact, approximate: true, accuracy: 3200)
        #expect(rough["precision"]?.string == "approximate")
        #expect(rough["note"]?.string?.contains("about 3 km") == true)
        #expect(rough["timezone"]?.string == "UTC")
        #expect(DeviceAccess.locationApproximated(["precision": "address"], approximate: true, accuracy: 900)["precision"]?.string == "approximate")
        let city: [String: JSONValue] = ["precision": "city"]
        #expect(DeviceAccess.locationApproximated(city, approximate: true, accuracy: 3200) == city)
    }

    /// Needs Location allowed on this simulator. Runs with the app active, so this doesn't touch the While Locked
    /// gate. Lenient about the geocoded fields (city/region/country): this sandbox may have no network to resolve
    /// them, but the shape (precision, which fields a level adds) still has to hold.
    @Test func answersAtEveryPrecisionTheSimulatorShares() async throws {
        guard LocationAccess.permission == .allowed || LocationAccess.permission == .limited else { return }
        for precision in ["city", "address", "exact"] {
            let answer = await LocationAccess.answer(request(["precision": .string(precision)]), scopes: [precision])
            guard answer.status == .done else { continue } // no fix or no network in this sandbox
            let said = answer.result["precision"]?.string
            #expect(said == precision || (precision != "city" && said == "approximate"), "approximate only with Precise Location off")
            #expect(answer.result["timezone"]?.string == TimeZone.current.identifier)
            #expect(answer.result["at"]?.string != nil)
            let place = answer.result["place"]?.object
            if precision == "city" {
                #expect(place?["address"] == nil)
            } else {
                #expect(place != nil)
            }
            if precision == "exact" {
                #expect(answer.result["coordinates"]?.object?["latitude"]?.double != nil)
                #expect(answer.result["coordinates"]?.object?["accuracy_m"]?.double != nil)
            } else {
                #expect(answer.result["coordinates"] == nil)
            }
        }
    }
}
