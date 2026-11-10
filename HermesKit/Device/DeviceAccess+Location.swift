// [device-access] Location's pure parts (App/DeviceAccess/LocationAccess.swift does the CoreLocation/MapKit work):
// the precision this phone actually answers at, and the state or province MapKit's address summary doesn't break out
// on its own.

import Foundation

nonisolated extension DeviceAccess {
    /// The lower of what was asked and what's shared (nil: nothing of the kind is shared). `scopes` is this
    /// request's switches that are on; the shared level is the highest of city/address/exact among them.
    static func locationPrecision(asked: String?, scopes: Set<String>) -> String? {
        guard let sharedIndex = locationLevels.lastIndex(where: scopes.contains) else { return nil }
        guard let askedIndex = asked.flatMap({ locationLevels.firstIndex(of: $0) }) else { return locationLevels[sharedIndex] }
        return locationLevels[min(askedIndex, sharedIndex)]
    }

    /// Audit 09-7: with iOS's Precise Location off, a street address or exact answer is labelled `approximate`, with
    /// a note of how far off it may be, never `exact`. A city answer stays as it is (a rough fix still has the city).
    static func locationApproximated(_ result: [String: JSONValue], approximate: Bool, accuracy: Double) -> [String: JSONValue] {
        guard approximate, let precision = result["precision"]?.string, precision != "city" else { return result }
        var out = result
        out["precision"] = "approximate"
        let km = accuracy > 0 && accuracy.isFinite ? max(1, Int((accuracy / 1000).rounded())) : nil
        out["note"] = .string("Precise Location is off for this app in the device's settings, so this is only roughly where the user is"
                              + (km.map { " (within about \($0) km)." } ?? "."))
        return out
    }

    /// The state or province MKAddressRepresentations doesn't expose on its own: what `cityWithContext`
    /// ("Cupertino, CA") adds after the city name. nil when there's nothing after it (no city, or no subdivision for
    /// this address, as in many countries).
    static func locationRegion(city: String?, cityWithContext: String?) -> String? {
        guard let city, !city.isEmpty, let cityWithContext, cityWithContext.hasPrefix(city) else { return nil }
        let rest = cityWithContext.dropFirst(city.count).trimmingCharacters(in: CharacterSet(charactersIn: ", "))
        return rest.isEmpty ? nil : rest
    }
}
