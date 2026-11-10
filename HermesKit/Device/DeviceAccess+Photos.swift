// [device-access] Photos' own rules for Device Access (docs/device-access.md), kept pure Foundation so they're
// unit-testable without PhotoKit: a search's plan (dates, place, favourites, media kind, limit), the great-circle
// distance `near` filters by, the size a copy is fit to, and one photo's wire shape. App/DeviceAccess/PhotosAccess.swift
// does the actual PhotoKit work and calls into these.

import Foundation

nonisolated extension DeviceAccess {
    /// `photos.search`'s `media` argument.
    enum PhotoMedia: String, Equatable, Sendable { case photo, video, screenshot, live, any }

    /// A search's plan, already defaulted and clamped.
    struct PhotoSearchPlan: Equatable, Sendable {
        var start: Date?
        var end: Date?
        var near: Near?
        var favorites: Bool?
        var media: PhotoMedia
        var limit: Int

        struct Near: Equatable, Sendable {
            var latitude: Double
            var longitude: Double
            var radiusKm: Double
        }
    }

    static func photoSearchPlan(_ request: Request) -> PhotoSearchPlan {
        var near: PhotoSearchPlan.Near?
        if let value = request.args["near"], let latitude = value["latitude"]?.double, let longitude = value["longitude"]?.double {
            let radius = value["radius_km"]?.double ?? 1
            near = .init(latitude: latitude, longitude: longitude, radiusKm: min(max(radius, 0.001), 50))
        }
        let media = request.string("media", max: 20).flatMap(PhotoMedia.init(rawValue:)) ?? .any
        let limit = min(max(request.int("limit") ?? 25, 1), 50)
        return PhotoSearchPlan(start: request.date("start"), end: request.date("end"), near: near,
                               favorites: request.bool("favorites"), media: media, limit: limit)
    }

    /// `photos.get`'s plan: the id asked for, and the longest side a copy is fit to.
    static func photoGetPlan(_ request: Request) -> (id: String, maxPixels: Int)? {
        guard let id = request.string("id", max: 200) else { return nil }
        return (id, min(max(request.int("max_pixels") ?? 1600, 64), 2048))
    }

    /// Great-circle distance in kilometres (haversine), for `near`.
    static func kmBetween(_ aLat: Double, _ aLon: Double, _ bLat: Double, _ bLon: Double) -> Double {
        let r = 6371.0088
        let dLat = (bLat - aLat) * .pi / 180, dLon = (bLon - aLon) * .pi / 180
        let lat1 = aLat * .pi / 180, lat2 = bLat * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    /// `targetSize` for PHImageManager: `width`×`height` kept proportional, its longest side at most `longestSide`.
    static func fittedPixelSize(width: Int, height: Int, longestSide: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (longestSide, longestSide) }
        let longest = max(width, height)
        guard longest > longestSide else { return (width, height) }
        let scale = Double(longestSide) / Double(longest)
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }

    /// "photo-2026-11-01.jpg", the name a sent photo goes up as.
    static func photoFileName(_ date: Date) -> String { "photo-\(day(date)).jpg" }

    /// One photo as `photos.search`/`photos.get` describe it ("P" in docs/device-access.md).
    struct PhotoSummary: Sendable {
        var id: String
        var date: Date?
        var kind: String
        var width: Int
        var height: Int
        var durationS: Double?
        var favorite: Bool
        var place: (latitude: Double, longitude: Double)?

        var wire: JSONValue {
            var out: [String: JSONValue] = [
                "id": .string(id), "kind": .string(kind),
                "width": .number(Double(width)), "height": .number(Double(height)),
                "favorite": .bool(favorite),
            ]
            if let date { out["date"] = .string(DeviceAccess.stamp(date)) }
            if let durationS { out["duration_s"] = .number(durationS) }
            if let place {
                out["place"] = .object(["latitude": .number(rounded3(place.latitude)), "longitude": .number(rounded3(place.longitude))])
            }
            return .object(out)
        }
    }

    /// "screenshot" over "live" over "video"/"photo" (PhotoKit's subtypes aren't exclusive: a screenshot can also be
    /// a photo, a Live Photo never is a screenshot).
    static func photoKind(isScreenshot: Bool, isLive: Bool, isVideo: Bool) -> String {
        if isScreenshot { return "screenshot" }
        if isLive { return "live" }
        return isVideo ? "video" : "photo"
    }

    static func rounded3(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
}
