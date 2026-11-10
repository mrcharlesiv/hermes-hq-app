// Artifacts image previews (docs/spec/1x-pages.md §5.5): a tile whose read failed for the link shows the failure and is
// not asked again on its own (no loop while the outage gate fails reads at once), but gateway.ready or the page's
// return asks again; a missing file stays failed. Pictures outlive the page (owner 2026-11-01, "Every time I open the
// artifacts page … it has to … reload and repopulate everything"): kept for the next page, on disk for the next run, and
// up while their chat is read again.

import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

@MainActor @Suite(.serialized) struct ArtifactPreviewsTests {
    nonisolated private static let path = "/api/fs/read-data-url"
    nonisolated private static let pixel = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

    private func record(_ id: String) -> ArtifactRecord {
        ArtifactRecord(id: id, kind: .image, value: "/a/\(id).png", href: "/a/\(id).png", label: "\(id).png",
                       sessionId: "s", profile: "research", sessionTitle: "t", timestamp: 0)
    }

    /// A page's previews with nothing kept from another test (memory or disk).
    private func fresh(_ client: PagesFakeClient) -> ArtifactPreviews {
        ArtifactThumbs.shared.forgetMemory()
        PagesCache.flush()
        try? FileManager.default.removeItem(at: ArtifactThumbs.folder(client.account))
        return ArtifactPreviews(client: client, account: client.account)
    }

    private func settle(_ previews: ArtifactPreviews, _ record: ArtifactRecord) async {
        for _ in 0..<200 {
            if case .loading = previews.state(record) { try? await Task.sleep(for: .milliseconds(5)) } else { return }
        }
    }

    @Test func aLinkFailureWaitsForTheGatewayThenAsksAgain() async {
        let failures = Mutex(1)
        let client = PagesFakeClient { request in
            guard request.path == Self.path else { return .object([:]) }
            if failures.withLock({ left in defer { left -= 1 }; return left > 0 }) { throw URLError(.notConnectedToInternet) }
            return ["dataUrl": .string(Self.pixel)]
        }
        let previews = fresh(client)
        let tile = record("a")
        previews.request(tile, pixels: 64)
        await settle(previews, tile)
        guard case .failed = previews.state(tile) else { Issue.record("expected failed"); return }
        // Shown again (a reconfigure) without a gateway.ready: not asked again.
        previews.request(tile, pixels: 64)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(client.log.count == 1, "no loop: \(client.logLines)")
        // The gateway is back.
        #expect(previews.retryTransient())
        guard case .loading = previews.state(tile) else { Issue.record("expected loading"); return }
        previews.request(tile, pixels: 64)
        await settle(previews, tile)
        guard case .image = previews.state(tile) else { Issue.record("expected image"); return }
        #expect(client.log.count == 2)
        #expect(!previews.retryTransient(), "nothing left to retry")
    }

    @Test func aMissingFileStaysFailed() async {
        let client = PagesFakeClient { request in
            if request.path == Self.path { throw httpError(404, "File not found") }
            return .object([:])
        }
        let previews = fresh(client)
        let tile = record("gone")
        previews.request(tile, pixels: 64)
        await settle(previews, tile)
        #expect(!previews.retryTransient())
        guard case .failed(_, let missing, _) = previews.state(tile) else { Issue.record("expected failed"); return }
        #expect(missing)
    }

    private func gatewayReads(_ client: PagesFakeClient) -> Int { client.log.filter { $0.path == Self.path }.count }

    @Test func theNextPageShowsThePictureAtOnce() async {
        let client = PagesFakeClient { request in
            request.path == Self.path ? ["dataUrl": .string(Self.pixel)] : .object([:])
        }
        let first = fresh(client), tile = record("shared")
        first.request(tile, pixels: 64)
        await settle(first, tile)
        guard case .image = first.state(tile) else { Issue.record("expected image"); return }
        // The page is opened again: a new page's previews.
        let second = ArtifactPreviews(client: client, account: client.account)
        guard case .image = second.state(tile) else { Issue.record("expected the kept image at once"); return }
        second.request(tile, pixels: 64)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(gatewayReads(client) == 1, "not read again: \(client.logLines)")
    }

    @Test func aRelaunchReadsThePictureFromDisk() async {
        let client = PagesFakeClient { request in
            request.path == Self.path ? ["dataUrl": .string(Self.pixel)] : .object([:])
        }
        let first = fresh(client), tile = record("disk")
        first.request(tile, pixels: 64)
        await settle(first, tile)
        PagesCache.flush()
        #expect(FileManager.default.fileExists(atPath: ArtifactThumbs.fileURL(client.account, tile.id, "s").path))
        // A new run: nothing in memory.
        ArtifactThumbs.shared.forgetMemory()
        let second = ArtifactPreviews(client: client, account: client.account)
        var updated: [String] = []
        second.onUpdate = { updated.append($0) }
        second.request(tile, pixels: 64)
        await settle(second, tile)
        guard case .image = second.state(tile) else { Issue.record("expected the disk copy"); return }
        #expect(updated == [tile.id])
        #expect(gatewayReads(client) == 1, "the disk copy, not the gateway: \(client.logLines)")
    }

    @Test func aChatReadAgainKeepsItsPictureUpWhileTheFreshOneLoads() async {
        let gate = Mutex(false)
        let client = PagesFakeClient { request in
            guard request.path == Self.path else { return .object([:]) }
            while gate.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
            return ["dataUrl": .string(Self.pixel)]
        }
        let previews = fresh(client), tile = record("stale")
        previews.request(tile, pixels: 64)
        await settle(previews, tile)
        guard case .image = previews.state(tile) else { Issue.record("expected image"); return }
        // The chat was read again; the fresh read is held.
        gate.withLock { $0 = true }
        previews.forget(sessions: [ArtifactSessionRow(id: tile.sessionId, profile: tile.profile)], in: [tile])
        previews.request(tile, pixels: 64)
        try? await Task.sleep(for: .milliseconds(30))
        guard case .image = previews.state(tile) else { Issue.record("the kept picture blanked"); return }
        #expect(gatewayReads(client) == 2, "read again: \(client.logLines)")
        gate.withLock { $0 = false }
        for _ in 0..<200 where ArtifactThumbs.shared.isStale(client.account, tile.id) { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(!ArtifactThumbs.shared.isStale(client.account, tile.id))
        // A fresh page doesn't read it a third time.
        let next = ArtifactPreviews(client: client, account: client.account)
        next.request(tile, pixels: 64)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(gatewayReads(client) == 2)
    }

    /// A kept picture whose fresh read fails stays up, and the tile drawn again doesn't ask again (no loop while the
    /// outage gate fails reads at once); the gateway's return asks once more.
    @Test func aFailedFreshReadKeepsThePictureWithoutALoop() async {
        let down = Mutex(false)
        let client = PagesFakeClient { request in
            guard request.path == Self.path else { return .object([:]) }
            if down.withLock({ $0 }) { throw URLError(.notConnectedToInternet) }
            return ["dataUrl": .string(Self.pixel)]
        }
        let previews = fresh(client), tile = record("kept")
        previews.request(tile, pixels: 64)
        await settle(previews, tile)
        down.withLock { $0 = true }
        previews.forget(sessions: [ArtifactSessionRow(id: tile.sessionId, profile: tile.profile)], in: [tile])
        previews.request(tile, pixels: 64)
        try? await Task.sleep(for: .milliseconds(30))
        for _ in 0..<5 { previews.request(tile, pixels: 64) }   // drawn again as each update lands
        try? await Task.sleep(for: .milliseconds(30))
        guard case .image = previews.state(tile) else { Issue.record("the kept picture went"); return }
        #expect(gatewayReads(client) == 2, "no loop: \(client.logLines)")
        down.withLock { $0 = false }
        #expect(previews.retryTransient())
        previews.request(tile, pixels: 64)
        for _ in 0..<200 where ArtifactThumbs.shared.isStale(client.account, tile.id) { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(gatewayReads(client) == 3)
        #expect(!ArtifactThumbs.shared.isStale(client.account, tile.id))
    }

    /// A pass reads a chat and its tile's picture loads while the pass runs: at the pass's end the picture is fresh,
    /// not read once more (the first visit read every picture twice). One kept from before the listing is read again.
    @Test func aPictureReadDuringThePassIsNotReadAgainAtItsEnd() async {
        let client = PagesFakeClient { request in
            request.path == Self.path ? ["dataUrl": .string(Self.pixel)] : .object([:])
        }
        let previews = fresh(client), before = record("before"), during = record("during")
        previews.request(before, pixels: 64)
        await settle(previews, before)
        try? await Task.sleep(for: .milliseconds(5))
        let listedAt = Date()
        previews.request(during, pixels: 64)
        await settle(previews, during)
        previews.forget(sessions: [ArtifactSessionRow(id: "s", profile: "research")], in: [before, during], keptBefore: listedAt)
        #expect(ArtifactThumbs.shared.isStale(client.account, before.id))
        #expect(!ArtifactThumbs.shared.isStale(client.account, during.id))
    }
}
