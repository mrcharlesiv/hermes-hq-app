// [device-access] Location for Device Access (docs/device-access.md): CoreLocation's permission, a one-shot fix
// (works from the background after a silent push, with Always authorization and the While Locked switch), and
// reverse geocoding with MapKit's MKReverseGeocodingRequest (iOS 26; CLGeocoder is deprecated as of this OS in favor
// of it). Location is available on the Mac too (CoreLocation and MapKit both are); it just can't be asked for while
// the app is in the background there either.

import CoreLocation
import Foundation
import MapKit
import UIKit

enum LocationAccess: DeviceAccessHandler {
    static let kind = DeviceAccess.Kind.location

    static var permission: DeviceAccessPermission {
        switch LocationCenter.shared.status {
        case .authorizedAlways: .allowed
        case .authorizedWhenInUse: .limited
        case .notDetermined: .notAsked
        default: .denied // .denied, .restricted
        }
    }

    static var permissionNote: String? {
        let center = LocationCenter.shared
        var notes: [String] = []
        // Audit 09-7: with iOS's Precise Location off, iOS hands out only a rough position (a few km).
        if center.approximate, center.status == .authorizedAlways || center.status == .authorizedWhenInUse {
            notes.append("Precise Location is off for \(AppIdentity.current.displayName) in \(DeviceWord.settingsApp), so Street Address and Exact Location are only approximate.")
        }
        if center.status == .authorizedWhenInUse {
            notes.append("In \(DeviceWord.settingsApp) you can allow Location “Always” so While Locked can turn on.")
        }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    /// city/address/exact ask When In Use (true once it's that or better); locked asks Always (iOS shows the
    /// upgrade prompt only once; true only once it's actually Always).
    static func requestPermission(turningOn key: String) async -> Bool {
        let center = LocationCenter.shared
        guard center.status != .denied, center.status != .restricted else { return false }
        if key == "locked" {
            if center.status == .notDetermined { _ = await center.requestAlways() }
            if center.status == .authorizedWhenInUse { _ = await center.requestAlways() }
            return center.status == .authorizedAlways
        }
        if center.status == .notDetermined { _ = await center.requestWhenInUse() }
        return center.status == .authorizedWhenInUse || center.status == .authorizedAlways
    }

    static func answer(_ request: DeviceAccess.Request, scopes: Set<String>) async -> DeviceAccess.Answer {
        guard let precision = DeviceAccess.locationPrecision(asked: request.string("precision", max: 10), scopes: scopes) else {
            return .unavailable(DeviceAccess.offWords(.location))
        }
        let center = LocationCenter.shared
        guard center.status == .authorizedAlways || center.status == .authorizedWhenInUse else {
            return .unavailable(DeviceAccess.notAllowedWords(.location))
        }
        if !DeviceAccessCenter.appOpen {   // [mac] Mac polish #26: a Mac window behind another app's counts as open
            guard scopes.contains("locked") else {
                return .unavailable("Location needs \(DeviceAccess.app) open on the \(DeviceWord.name) (While Locked is off).")
            }
            // While Locked is on but iOS was later set back to While Using: a background fix would only fail.
            guard center.status == .authorizedAlways else {
                return .unavailable("Location needs \(DeviceAccess.app) open on the \(DeviceWord.name) (Location isn’t set to Always).")
            }
        }
        switch await center.fix(timeout: 15) {
        case .failed(let message): return .failed(message)
        case .found(let location): return await Self.result(for: location, precision: precision, approximate: center.approximate)
        }
    }

    private static func result(for location: CLLocation, precision: String, approximate: Bool) async -> DeviceAccess.Answer {
        let found = await Self.reverseGeocode(location)
        var place: [String: JSONValue] = [:]
        if let city = found.city { place["city"] = .string(city) }
        if let region = found.region { place["region"] = .string(region) }
        if let country = found.country { place["country"] = .string(country) }
        if precision != "city", let address = found.address { place["address"] = .string(address) }

        var result: [String: JSONValue] = [
            "precision": .string(precision),
            "place": .object(place),
            "at": .string(DeviceAccess.stamp(location.timestamp)),
            "timezone": .string(TimeZone.current.identifier),
        ]
        if precision == "exact" {
            result["coordinates"] = .object([
                "latitude": .number(location.coordinate.latitude),
                "longitude": .number(location.coordinate.longitude),
                "accuracy_m": .number(location.horizontalAccuracy),
            ])
        }
        return .done(DeviceAccess.locationApproximated(result, approximate: approximate, accuracy: location.horizontalAccuracy))
    }

    /// MapKit's reverse geocoder (iOS 26). It doesn't break a state or province out on its own, so
    /// `DeviceAccess.locationRegion` reads it from the "Cupertino, CA" string. Nothing found, or MapKit couldn't:
    /// every part comes back nil (the answer just carries less).
    private static func reverseGeocode(_ location: CLLocation) async -> (city: String?, region: String?, country: String?, address: String?) {
        guard let geocode = MKReverseGeocodingRequest(location: location) else { return (nil, nil, nil, nil) }
        guard let items = try? await geocode.mapItems, let parts = items.first?.addressRepresentations else {
            return (nil, nil, nil, nil)
        }
        let city = parts.cityName
        let region = DeviceAccess.locationRegion(city: city, cityWithContext: parts.cityWithContext)
        let country = parts.regionName
        let address = parts.fullAddress(includingRegion: false, singleLine: true)
        return (city, region, country, address)
    }
}

/// CoreLocation's delegate callbacks aren't actor-isolated, so this hops to the main actor itself; it's created
/// there (lazily, on first use) and every call into it happens there too.
@MainActor private final class LocationCenter: NSObject, CLLocationManagerDelegate {
    static let shared = LocationCenter()

    private let manager = CLLocationManager()
    private var authPending: Pending<CLAuthorizationStatus>?
    private var locationPending: Pending<LocationFix>?

    override init() {
        super.init()
        manager.delegate = self
    }

    var status: CLAuthorizationStatus { manager.authorizationStatus }
    /// iOS's Precise Location is off for the app: every fix is a rough one.
    var approximate: Bool { manager.accuracyAuthorization == .reducedAccuracy }

    func requestWhenInUse() async -> CLAuthorizationStatus {
        guard status == .notDetermined else { return status }
        return await waitForAuthorizationChange { self.manager.requestWhenInUseAuthorization() }
    }

    /// From not determined, this shows the base prompt (landing on When In Use, not Always: iOS never offers Always
    /// on the first ask). From When In Use, it shows the once-only upgrade prompt.
    func requestAlways() async -> CLAuthorizationStatus {
        guard status != .denied, status != .restricted else { return status }
        return await waitForAuthorizationChange { self.manager.requestAlwaysAuthorization() }
    }

    private func waitForAuthorizationChange(timeout: Double = 5, _ ask: @MainActor () -> Void) async -> CLAuthorizationStatus {
        await withCheckedContinuation { continuation in
            let pending = Pending(continuation)
            authPending = pending
            ask()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                guard !pending.done else { return }
                pending.finish(self.manager.authorizationStatus)
                self.authPending = nil
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Not `manager.authorizationStatus`: that parameter isn't Sendable, and `self.manager` is the same instance.
        Task { @MainActor in
            self.authPending?.finish(self.manager.authorizationStatus)
            self.authPending = nil
        }
    }

    /// One fix, or why not, within `timeout` seconds (cancelled and its late answer dropped past it).
    func fix(timeout: Double) async -> LocationFix {
        guard CLLocationManager.locationServicesEnabled() else { return .failed("Location Services is off on this device.") }
        return await withCheckedContinuation { continuation in
            let pending = Pending(continuation)
            locationPending = pending
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.requestLocation()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                guard !pending.done else { return }
                pending.finish(.failed("The \(DeviceWord.name) took too long to get your location."))
                self.locationPending = nil
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            guard let location = locations.last else { return }
            self.locationPending?.finish(.found(location))
            self.locationPending = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.locationPending?.finish(.failed("The \(DeviceWord.name) couldn’t get your location."))
            self.locationPending = nil
        }
    }
}

/// `fix(timeout:)`'s answer. Not `Result<CLLocation, String>`: `Result`'s failure side has to be an `Error`, and a
/// plain message is plainer to read at the call site. `@unchecked`: CLLocation isn't marked Sendable, but it's an
/// immutable snapshot of a fix, safe to read from anywhere.
private enum LocationFix: @unchecked Sendable {
    case found(CLLocation)
    case failed(String)
}

/// One continuation, resumed at most once (a second resume would crash).
@MainActor private final class Pending<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?
    nonisolated init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }
    var done: Bool { continuation == nil }
    func finish(_ value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
