// [device-access] Photos for Device Access: the pure plan/formatting rules (HermesKit/Device/DeviceAccess+Photos.swift),
// and a live round trip against this Simulator's own photo library (passes without exercising anything when this
// install hasn't been granted Photos access).

import Foundation
import Testing
@testable import HermesHQNative

@MainActor struct DeviceAccessPhotosTests {
    private let id = String(repeating: "a", count: 32)

    private func request(_ args: [String: JSONValue] = [:], op: String = "photos.search") -> DeviceAccess.Request {
        DeviceAccess.Request(id: id, op: op, args: args)
    }

    @Test func searchPlanDefaultsAndClampsItsLimit() {
        let plan = DeviceAccess.photoSearchPlan(request())
        #expect(plan.media == .any && plan.limit == 25 && plan.near == nil && plan.start == nil && plan.favorites == nil)
        let big = DeviceAccess.photoSearchPlan(request(["limit": 500, "media": "screenshot"]))
        #expect(big.limit == 50 && big.media == .screenshot)
        let zero = DeviceAccess.photoSearchPlan(request(["limit": 0]))
        #expect(zero.limit == 1)
        let bad = DeviceAccess.photoSearchPlan(request(["media": "nonsense"]))
        #expect(bad.media == .any)
    }

    @Test func nearDefaultsAndClampsItsRadius() {
        let plan = DeviceAccess.photoSearchPlan(request(["near": ["latitude": 10, "longitude": 20, "radius_km": 500]]))
        #expect(plan.near?.latitude == 10 && plan.near?.radiusKm == 50)
        let defaulted = DeviceAccess.photoSearchPlan(request(["near": ["latitude": 10, "longitude": 20]]))
        #expect(defaulted.near?.radiusKm == 1)
        #expect(DeviceAccess.photoSearchPlan(request(["near": ["latitude": 10]])).near == nil, "longitude missing: no near at all")
    }

    @Test func getPlanNeedsAnIdAndClampsMaxPixels() throws {
        #expect(DeviceAccess.photoGetPlan(request(op: "photos.get")) == nil)
        let plan = try #require(DeviceAccess.photoGetPlan(request(["id": "X", "max_pixels": 9000], op: "photos.get")))
        #expect(plan.id == "X" && plan.maxPixels == 2048)
        let defaulted = try #require(DeviceAccess.photoGetPlan(request(["id": "X"], op: "photos.get")))
        #expect(defaulted.maxPixels == 1600)
    }

    @Test func distanceIsZeroAtTheSamePointAndAboutRightForADegree() {
        #expect(DeviceAccess.kmBetween(0, 0, 0, 0) == 0)
        let oneDegree = DeviceAccess.kmBetween(0, 0, 1, 0)
        #expect(oneDegree > 110 && oneDegree < 112, "a degree of latitude is about 111 km")
    }

    @Test func fittedSizeKeepsProportionsAndNeverUpscales() {
        let shrunk = DeviceAccess.fittedPixelSize(width: 4000, height: 2000, longestSide: 2000)
        #expect(shrunk.width == 2000 && shrunk.height == 1000)
        let kept = DeviceAccess.fittedPixelSize(width: 400, height: 200, longestSide: 2000)
        #expect(kept.width == 400 && kept.height == 200, "never upscales")
    }

    @Test func photoKindPicksScreenshotOverLiveOverVideo() {
        #expect(DeviceAccess.photoKind(isScreenshot: true, isLive: true, isVideo: true) == "screenshot")
        #expect(DeviceAccess.photoKind(isScreenshot: false, isLive: true, isVideo: false) == "live")
        #expect(DeviceAccess.photoKind(isScreenshot: false, isLive: false, isVideo: true) == "video")
        #expect(DeviceAccess.photoKind(isScreenshot: false, isLive: false, isVideo: false) == "photo")
    }

    @Test func summaryWireRoundsPlaceAndOmitsWhatsMissing() {
        let summary = DeviceAccess.PhotoSummary(id: "X", date: nil, kind: "photo", width: 10, height: 20, durationS: nil,
                                                favorite: true, place: (37.33332, -122.03123))
        let wire = summary.wire
        #expect(wire["id"]?.string == "X" && wire["favorite"]?.bool == true && wire["date"] == nil && wire["duration_s"] == nil)
        #expect(wire["place"]?["latitude"]?.double == 37.333 && wire["place"]?["longitude"]?.double == -122.031)
    }

    @Test func fileNameIsTheDay() throws {
        let date = try #require(DeviceAccess.date("2026-11-01"))
        #expect(DeviceAccess.photoFileName(date.date) == "photo-2026-11-01.jpg")
    }

    // MARK: Live (this Simulator's own library)

    @Test func liveSearchAndGetAgainstThisSimulatorsLibrary() async throws {
        guard PhotosAccess.permission == .allowed || PhotosAccess.permission == .limited else { return }
        let search = await PhotosAccess.answer(request(["limit": 5]), scopes: ["find"])
        guard search.status == .done, let photos = search.result["photos"]?.array, let first = photos.first else { return }
        let firstId = try #require(first["id"]?.string)
        let get = await PhotosAccess.answer(request(["id": .string(firstId)], op: "photos.get"), scopes: ["send"])
        #expect(get.status == .done)
        let file = try #require(get.file)
        #expect(file.type == "image/jpeg" && file.data.count > 0 && file.data.count < 3 * 1024 * 1024)
    }

    @Test func liveGetOfAnUnknownIdFails() async {
        guard PhotosAccess.permission == .allowed || PhotosAccess.permission == .limited else { return }
        let get = await PhotosAccess.answer(request(["id": "not-a-real-id"], op: "photos.get"), scopes: ["send"])
        #expect(get.status == .failed)
    }
}
