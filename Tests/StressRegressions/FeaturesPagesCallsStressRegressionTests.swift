// Stress regression tests for Domain 3:
// - TasksStore.flushPending() concurrent delete / edit / conflict safety (C2)
// - PluginPageSchemeHandler.allowedAssetPath() traversal & encoding guards (C5)
// - PreviewTabController external URL scheme allowlist, popup URL validation, left-tab close selection (C6, M24)
// - samplehost 404 JSON preservation, callStatus, PhoneSetupCheck, PhoneConnectionResolver.needsFix, repairVoiceConnection custom webhook (H6/H14, H15)
// - BrowserFrameDecoder lock-release concurrency race & 32 MP JPEG bomb cap (H25)
// - ScreenFramebuffer.drawJPEG bomb rejection & ScreenStream split DesktopSize non-incremental request (H26)
// - TerminalConnection resize during dial() handshake (H27)
// - ArtifactsViewController.point off-hierarchy popover anchor safety (H8)
// - HealthLookup.activityMoveModeName nil safety (H31)

import CoreGraphics
import Foundation
#if !targetEnvironment(macCatalyst)
import HealthKit
#endif
import ImageIO
import Synchronization
import Testing
import UIKit
import WebKit
@testable import HermesHQNative

// MARK: - Private samplehost URLProtocol Stub (isolated from PhoneCallsTests.samplehostStub)

nonisolated private final class StresssamplehostStub: URLProtocol, @unchecked Sendable {
    struct Seen: Sendable {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data?

        var path: String { url.path }
        var json: [String: Any] { body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:] }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _seen: [Seen] = []
    nonisolated(unsafe) private static var _route: @Sendable (Seen) -> (Int, Data) = { _ in (404, Data()) }

    static var seen: [Seen] { lock.withLock { _seen } }

    static func json(_ payload: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }

    static func reset(_ route: @escaping @Sendable (Seen) -> (Int, Data)) {
        lock.withLock {
            _seen = []
            _route = route
        }
    }

    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StresssamplehostStub.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            body = data
        }
        let seen = Seen(
            method: request.httpMethod ?? "GET",
            url: request.url!,
            headers: request.allHTTPHeaderFields ?? [:],
            body: body
        )
        let route = Self.lock.withLock { Self._seen.append(seen); return Self._route }
        let (status, data) = route(seen)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Helpers

nonisolated private enum StressJPEGHelper {
    /// Patches the SOF0/SOF1/SOF2 width and height fields of a valid baseline JPEG to simulate a dimension bomb
    /// without allocating a giant image buffer.
    static func withDimensions(width: UInt16, height: UInt16) -> Data {
        var bytes = [UInt8](ScreenTestImage.jpeg(width: 16, height: 16, r: 0.2, g: 0.6, b: 0.9))
        var i = 2
        while i + 9 < bytes.count {
            guard bytes[i] == 0xFF else { break }
            let marker = bytes[i + 1]
            if marker == 0xD9 || marker == 0xDA { break }
            if marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7) {
                i += 2
                continue
            }
            let length = (Int(bytes[i + 2]) << 8) | Int(bytes[i + 3])
            guard length >= 2 else { break }
            if marker == 0xC0 || marker == 0xC1 || marker == 0xC2 {
                bytes[i + 5] = UInt8(height >> 8)
                bytes[i + 6] = UInt8(height & 0xFF)
                bytes[i + 7] = UInt8(width >> 8)
                bytes[i + 8] = UInt8(width & 0xFF)
                break
            }
            i += 2 + length
        }
        return Data(bytes)
    }
}

nonisolated private final class StressGate: Sendable {
    private let state = Mutex<(entered: Bool, released: Bool, enterWaiter: CheckedContinuation<Void, Never>?, releaseWaiter: CheckedContinuation<Void, Never>?)>((false, false, nil, nil))

    func arriveAndWait() async {
        let waiterToResume: CheckedContinuation<Void, Never>? = state.withLock { s in
            s.entered = true
            let w = s.enterWaiter
            s.enterWaiter = nil
            return w
        }
        waiterToResume?.resume()
        let alreadyReleased = state.withLock { $0.released }
        if alreadyReleased { return }
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { s -> Bool in
                if s.released { return true }
                s.releaseWaiter = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func waitUntilEntered() async {
        let already = state.withLock { $0.entered }
        if already { return }
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { s -> Bool in
                if s.entered { return true }
                s.enterWaiter = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release() {
        let waiter: CheckedContinuation<Void, Never>? = state.withLock { s in
            s.released = true
            let w = s.releaseWaiter
            s.releaseWaiter = nil
            return w
        }
        waiter?.resume()
    }
}

// MARK: - 1. TasksStore.flushPending() Stress Regressions (C2)

@MainActor
@Suite("TasksStore flushPending stress regressions")
struct TasksFlushStressRegressionTests {
    private nonisolated static func makeTask(_ id: String, _ title: String, rev: Int = 1) -> TodoTask {
        let o: [String: JSONValue] = [
            "id": .string(id),
            "rev": .number(Double(rev)),
            "title": .string(title),
            "who": .string("me"),
            "status": .string("open"),
            "priority": .number(0),
            "updated_at": .string("2026-11-04T08:00:00Z"),
            "created_at": .string("2026-11-03T08:00:00Z"),
            "steps": .array([]),
        ]
        return try! JSONDecoder().decode(TodoTask.self, from: JSONValue.object(o).encoded())
    }

    private nonisolated static func wire(_ task: TodoTask) -> JSONValue {
        try! JSONValue.parse(JSONEncoder().encode(task))
    }

    @Test func deleteLocalTaskDuringInFlightAddDoesNotCrashOrResurrectAndDeletesOrphan() async throws {
        let client = PagesFakeClient { _ in .object(["rev": 1, "tasks": .array([])]) }
        let store = TasksStore(api: TasksAPI(client: client), account: client.account, directory: nil)
        await store.refresh()

        // Queue one offline `.add`.
        client.respond { _ in throw URLError(.notConnectedToInternet) }
        let added = await store.add(TodoWire.newTask(title: "Temp offline task", who: .me, bot: nil, due: nil, repeatRule: nil, prep: false))
        let localID = try #require(added?.id)
        #expect(TodoIDs.isLocal(localID))
        #expect(store.pendingCount == 1)

        // Come back online with a gated POST so we can delete `localID` mid-flight.
        let gate = StressGate()
        let deletedPaths = Mutex<[String]>([])
        let createdOnServer = Self.makeTask("t_server_orphan", "Temp offline task", rev: 1)
        client.respond { request in
            if request.method == "POST" {
                await gate.arriveAndWait()
                return Self.wire(createdOnServer)
            }
            if request.method == "DELETE" {
                deletedPaths.withLock { $0.append(request.path) }
                return .object(["ok": true])
            }
            return .object(["rev": 2, "tasks": .array([])])
        }

        let flushTask = Task { await store.flushPending() }
        await gate.waitUntilEntered()

        // Delete the local task while `api.create` is suspended (empties `pendingOps`).
        #expect(await store.delete(localID))
        #expect(store.pendingCount == 0)
        #expect(store.task(localID) == nil)

        // Release `api.create` — must neither crash on empty `pendingOps` nor resurrect `createdOnServer`.
        gate.release()
        await flushTask.value

        #expect(store.pendingCount == 0)
        #expect(store.task(localID) == nil)
        #expect(store.task("t_server_orphan") == nil, "deleted task must not be resurrected when in-flight add returns")
        #expect(deletedPaths.withLock { $0 }.contains { $0.hasSuffix("/tasks/t_server_orphan") },
                "best-effort server delete cleans up the orphan created while deleting locally")
    }

    @Test func editLocalTaskDuringInFlightAddQueuesSeparatePatchAndAppliesToCreatedID() async throws {
        let client = PagesFakeClient { _ in .object(["rev": 1, "tasks": .array([])]) }
        let store = TasksStore(api: TasksAPI(client: client), account: client.account, directory: nil)
        await store.refresh()

        client.respond { _ in throw URLError(.notConnectedToInternet) }
        let added = await store.add(TodoWire.newTask(title: "Initial title", who: .me, bot: nil, due: nil, repeatRule: nil, prep: false))
        let localID = try #require(added?.id)

        let gate = StressGate()
        let patchedTitles = Mutex<[String]>([])
        let serverCreated = Self.makeTask("t_server_live", "Initial title", rev: 1)
        let serverPatched = Self.makeTask("t_server_live", "Updated while flushing", rev: 2)
        client.respond { request in
            if request.method == "POST" {
                await gate.arriveAndWait()
                return Self.wire(serverCreated)
            }
            if request.method == "PATCH" {
                if let title = request.body?["title"]?.string {
                    patchedTitles.withLock { $0.append(title) }
                }
                return Self.wire(serverPatched)
            }
            return .object(["rev": 2, "tasks": .array([Self.wire(serverPatched)])])
        }

        let flushTask = Task { await store.flushPending() }
        await gate.waitUntilEntered()

        // Edit the local task while `.add` is in flight: must not fold into the already-sent `.add` op.
        #expect(await store.patch(localID, ["title": .string("Updated while flushing")]))
        #expect(store.pendingCount == 2)

        gate.release()
        await flushTask.value

        #expect(store.pendingCount == 0)
        #expect(patchedTitles.withLock { $0 } == ["Updated while flushing"])
        #expect(store.task("t_server_live")?.title == "Updated while flushing")
    }
}

// MARK: - 2. PluginPageSchemeHandler Traversal Guard (C5)

@Suite("PluginPageSchemeHandler asset path regressions")
struct PluginAssetPathStressRegressionTests {
    @Test func allowsValidPluginAssetsAndBlocksEncodedTraversal() {
        // Valid assets
        #expect(PluginPageSchemeHandler.allowedAssetPath("/dashboard-plugins/memory-wiki/assets/icon.png", plugin: "memory-wiki", profile: "default") == "/dashboard-plugins/memory-wiki/assets/icon.png")
        #expect(PluginPageSchemeHandler.allowedAssetPath("/dashboard-plugins/memory-wiki/assets/icon.png", query: "?v=2", plugin: "memory-wiki", profile: "default") == "/dashboard-plugins/memory-wiki/assets/icon.png?v=2")
        #expect(PluginPageSchemeHandler.allowedAssetPath("/dashboard-plugins/@ivy/memory-wiki/assets/caf%C3%A9.png", plugin: "memory-wiki", profile: "ivy") == "/dashboard-plugins/@ivy/memory-wiki/assets/caf%C3%A9.png")

        // Percent-encoded and raw directory traversal
        let badPaths = [
            "/dashboard-plugins/memory-wiki/%2e%2e/other/secret.js",
            "/dashboard-plugins/memory-wiki/%2E%2E/other/secret.js",
            "/dashboard-plugins/memory-wiki/%2e%2e%2fother/secret.js",
            "/dashboard-plugins/memory-wiki/../other/secret.js",
            "/dashboard-plugins/memory-wiki/assets/..",
            "/dashboard-plugins/memory-wiki/assets/%2e%2e",
            "/dashboard-plugins/memory-wiki/./icon.png",
            "/dashboard-plugins/memory-wiki/%2e/icon.png",
            "/dashboard-plugins/memory-wiki/assets/%5csecret.js",
            "/dashboard-plugins/memory-wiki/assets/icon%00.png",
            "/dashboard-plugins/memory-wikix/icon.png",
            "//example.com/dashboard-plugins/memory-wiki/icon.png",
        ]
        for path in badPaths {
            #expect(PluginPageSchemeHandler.allowedAssetPath(path, plugin: "memory-wiki", profile: "default") == nil,
                    "expected rejection for \(path)")
        }
    }
}

// MARK: - 3. PreviewTabController Security & Tab Selection Regressions (C6, M24)

@MainActor
@Suite("PreviewTabController security and tab selection regressions")
struct PreviewTabStressRegressionTests {
    @Test func externalSchemePolicyRequiresUserMainFrameTapAndAllowlist() {
        let mailto = URL(string: "mailto:ivy@example.com")!
        let tel = URL(string: "tel:+15550100001")!
        #expect(PreviewTabController.canOpenExternally(mailto, navigationType: .linkActivated, isMainFrame: true))
        #expect(PreviewTabController.canOpenExternally(tel, navigationType: .linkActivated, isMainFrame: true))

        // Non-user or subframe navigations are blocked even for safe schemes.
        #expect(!PreviewTabController.canOpenExternally(mailto, navigationType: .other, isMainFrame: true))
        #expect(!PreviewTabController.canOpenExternally(mailto, navigationType: .linkActivated, isMainFrame: false))

        // Own app schemes and dangerous schemes are always blocked.
        let blocked = [
            URL(string: "\(AppIdentity.current.urlScheme)://chat/otto")!,
            URL(string: "hermes://settings")!,
            URL(string: "hermeshq-native://pair?code=123")!,
            URL(string: "file:///etc/passwd")!,
            URL(string: "javascript:alert(1)")!,
            URL(string: "shortcuts://run-shortcut?name=test")!,
            URL(string: "customapp://steal")!,
        ]
        for url in blocked {
            #expect(!PreviewTabController.canOpenExternally(url, navigationType: .linkActivated, isMainFrame: true),
                    "expected external open blocked for \(url.absoluteString)")
        }
    }

    @Test func popupURLAllowsOnlyHTTPAndHTTPS() {
        #expect(PreviewTabController.allowsPopupURL(URL(string: "https://example.com/page")!))
        #expect(PreviewTabController.allowsPopupURL(URL(string: "http://example.com/page")!))
        #expect(!PreviewTabController.allowsPopupURL(URL(string: "javascript:alert(1)")!))
        #expect(!PreviewTabController.allowsPopupURL(URL(string: "file:///tmp/x.html")!))
        #expect(!PreviewTabController.allowsPopupURL(URL(string: "hermes://open")!))
        #expect(!PreviewTabController.allowsPopupURL(URL(string: "tel:+15550100001")!))
    }

    @Test func closingTabToTheLeftPreservesActiveSelection() {
        let urlA = URL(string: "https://a.example.com/")!
        let urlB = URL(string: "https://b.example.com/")!
        let urlC = URL(string: "https://c.example.com/")!
        let urlD = URL(string: "https://d.example.com/")!

        let controller = PreviewTabController(initialURL: urlA, label: "A", botName: "Otto", allowLoopback: false)
        controller.loadViewIfNeeded()
        controller.debugAddTab(url: urlB, label: "B", select: false)
        controller.debugAddTab(url: urlC, label: "C", select: true)
        controller.debugAddTab(url: urlD, label: "D", select: false)

        #expect(controller.debugTabCount == 4)
        #expect(controller.debugSelectedIndex == 2)
        #expect(controller.debugActiveURL == urlC)

        // Closing index 0 (left of selected index 2) must keep tab C selected at index 1.
        controller.debugRemoveTab(at: 0)
        #expect(controller.debugTabCount == 3)
        #expect(controller.debugSelectedIndex == 1)
        #expect(controller.debugActiveURL == urlC)

        // Closing index 2 (right of selected index 1) must leave tab C selected at index 1.
        controller.debugRemoveTab(at: 2)
        #expect(controller.debugTabCount == 2)
        #expect(controller.debugSelectedIndex == 1)
        #expect(controller.debugActiveURL == urlC)
    }
}

// MARK: - 4. Phone Calls / samplehost Regressions (H6/H14, H15)

@MainActor
@Suite("Phone Calls samplehost stress regressions", .serialized)
struct PhoneCallsStressRegressionTests {
    private func makeAPI(key: String = "KEYTEST") -> samplehostAPI {
        samplehostAPI(key: key, base: samplehostEndpoint.production, session: StresssamplehostStub.session)
    }

    @Test func samplehost404WithJSONBodyPreservesNotFoundAndRedactsKey() async throws {
        let api = makeAPI(key: "KEYTEST")
        let jsonBody = try JSONSerialization.data(withJSONObject: [
            "errors": [["code": "10005", "title": "Resource not found", "detail": "Call not found for KEYTEST"]]
        ])
        let err = api.failure(status: 404, jsonBody)
        #expect(err.isNotFound)
        #expect(!err.description.contains("KEYTEST"), "API key must never leak into error messages")
        #expect(api.failure(status: 404, Data()).isNotFound)

        // callStatus treats JSON 404 as call ended (nil) rather than throwing.
        StresssamplehostStub.reset { _ in
            (404, StresssamplehostStub.json(["errors": [["code": "10005", "title": "Resource not found", "detail": "Call already ended"]]]))
        }
        let status = try await api.callStatus(callControlID: "v3:sim+call/404")
        #expect(status == nil)
    }

    @Test func setupCheckFlagsJSON404AndNilWebhookAsFail() {
        let setup = PhoneSetup(
            apiKey: "KEYTEST",
            fromNumber: "+15550100001",
            connectionID: "conn-1",
            assistantID: "assistant-1",
            assistantName: "Otto"
        )
        let notFound = samplehostError.notFound("Resource not found")
        let reads404 = PhoneSetupCheck.Reads(
            numbers: .success([samplehostNumber(id: "n-1", phone_number: "+15550100001", status: "active", connection_id: "conn-1")]),
            app: .failure(notFound),
            profile: nil,
            assistant: .failure(notFound),
            balance: .success(samplehostBalance(balance: "25.00", currency: "USD"))
        )
        let rows404 = PhoneSetupCheck.rows(setup: setup, reads: reads404)
        #expect(rows404.first(where: { $0.id == "connection" })?.state == .fail)
        #expect(rows404.first(where: { $0.id == "assistant" })?.state == .fail)

        // Nil webhook_event_url must fail setup check, not pass.
        let appNilWebhook = samplehostCallControlApp(
            id: "conn-1",
            active: true,
            application_name: "Voice App",
            webhook_event_url: nil,
            outbound: .init(outbound_voice_profile_id: "prof-1")
        )
        let readsNilWebhook = PhoneSetupCheck.Reads(
            numbers: .success([samplehostNumber(id: "n-1", phone_number: "+15550100001", status: "active", connection_id: "conn-1")]),
            app: .success(appNilWebhook),
            profile: .success(samplehostVoiceProfile(id: "prof-1", name: "Default", enabled: true, whitelisted_destinations: ["US"])),
            assistant: .success(samplehostAssistantDetail(json: ["id": "assistant-1", "name": "Otto", "model": "openai/gpt-4o", "enabled_features": ["telephony"], "greeting": "Hi"])),
            balance: .success(samplehostBalance(balance: "25.00", currency: "USD"))
        )
        let rowsNilWebhook = PhoneSetupCheck.rows(setup: setup, reads: readsNilWebhook)
        #expect(rowsNilWebhook.first(where: { $0.id == "connection" })?.state == .fail)
    }

    @Test func connectionResolverNeedsFixCatchesNilWebhookAndNilOutbound() {
        let missingWebhook = samplehostCallControlAppSummary(id: "c1", application_name: "A", webhook_event_url: nil, outbound: .init(outbound_voice_profile_id: "p1"))
        let missingOutbound = samplehostCallControlAppSummary(id: "c2", application_name: "B", webhook_event_url: PhoneLimits.voiceWebhookURL, outbound: nil)
        let emptyOutbound = samplehostCallControlAppSummary(id: "c3", application_name: "C", webhook_event_url: PhoneLimits.voiceWebhookURL, outbound: .init(outbound_voice_profile_id: ""))
        let healthy = samplehostCallControlAppSummary(id: "c4", application_name: "D", webhook_event_url: PhoneLimits.voiceWebhookURL, outbound: .init(outbound_voice_profile_id: "p1"))

        #expect(PhoneConnectionResolver.needsFix(missingWebhook))
        #expect(PhoneConnectionResolver.needsFix(missingOutbound))
        #expect(PhoneConnectionResolver.needsFix(emptyOutbound))
        #expect(!PhoneConnectionResolver.needsFix(healthy))
    }

    @Test func repairVoiceConnectionPrefersExplicitCustomWebhookOverStaleExistingURL() async throws {
        let customWebhook = "https://hooks.example.com/samplehost-voice"
        let staleWebhook = "https://stale.example.com/old-webhook"
        let patchedWebhooks = Mutex<[String]>([])

        StresssamplehostStub.reset { seen in
            switch (seen.method, seen.path) {
            case ("GET", "/v2/call_control_applications/conn-1"):
                return (200, StresssamplehostStub.json(["data": [
                    "id": "conn-1",
                    "application_name": "Voice App",
                    "active": true,
                    "webhook_event_url": staleWebhook,
                    "outbound": ["outbound_voice_profile_id": "prof-1"],
                ]]))
            case ("GET", "/v2/outbound_voice_profiles/prof-1"):
                return (200, StresssamplehostStub.json(["data": [
                    "id": "prof-1",
                    "name": "Default",
                    "enabled": true,
                    "whitelisted_destinations": ["US"],
                ]]))
            case ("PATCH", "/v2/call_control_applications/conn-1"):
                if let url = seen.json["webhook_event_url"] as? String {
                    patchedWebhooks.withLock { $0.append(url) }
                }
                return (200, StresssamplehostStub.json(["data": [
                    "id": "conn-1",
                    "application_name": "Voice App",
                    "active": true,
                    "webhook_event_url": seen.json["webhook_event_url"] as? String ?? customWebhook,
                    "outbound": ["outbound_voice_profile_id": "prof-1"],
                ]]))
            default:
                return (404, StresssamplehostStub.json(["errors": [["code": "10005", "title": "Not found"]]]))
            }
        }

        let api = makeAPI()
        let number = samplehostNumber(id: "num-1", phone_number: "+15550100001", status: "active", connection_id: "conn-1")
        _ = try await api.repairVoiceConnection(connectionID: "conn-1", for: number, webhookURL: customWebhook)
        #expect(patchedWebhooks.withLock { $0 } == [customWebhook],
                "explicit custom webhookURL must override stale existing webhook_event_url")

        // When called with the default placeholder webhookURL, an existing valid custom URL is preserved.
        patchedWebhooks.withLock { $0.removeAll() }
        _ = try await api.repairVoiceConnection(connectionID: "conn-1", for: number)
        #expect(patchedWebhooks.withLock { $0 } == [staleWebhook],
                "default placeholder webhookURL should preserve an existing valid https:// webhook")
    }
}

// MARK: - 5. BrowserFrameDecoder Concurrency & JPEG Bomb Cap (H25)

@Suite("BrowserFrameDecoder stress regressions")
struct BrowserFrameDecoderStressRegressionTests {
    @Test func rejectsOversizedJPEGBombHeadersWithoutDecoding() throws {
        let huge = StressJPEGHelper.withDimensions(width: 10_000, height: 10_000)
        // Verify ImageIO actually reads the patched 10000x10000 header.
        let source = try #require(CGImageSourceCreateWithData(huge as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect((props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 10_000)
        #expect((props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 10_000)

        #expect(BrowserFrameDecoder.decode(huge) == nil, "dimension > 8192 must be rejected before decode")

        let over32MP = StressJPEGHelper.withDimensions(width: 8192, height: 8192)
        #expect(BrowserFrameDecoder.decode(over32MP) == nil, "64 MP exceeds 32 MP cap even when each side <= 8192")

        let valid = ScreenTestImage.jpeg(width: 32, height: 24, r: 0.3, g: 0.5, b: 0.7)
        let decoded = BrowserFrameDecoder.decode(valid)
        #expect(decoded?.width == 32 && decoded?.height == 24)
    }

    @Test func concurrentFrameBurstDeliversStrictlyIncreasingSeqsAndFinalFrame() async {
        let jpeg = ScreenTestImage.jpeg(width: 24, height: 18, r: 0.1, g: 0.8, b: 0.2)
        let delivered = Mutex<[Int]>([])
        let failedCount = Mutex<Int>(0)
        let decoder = BrowserFrameDecoder(
            decoded: { frame, _ in
                delivered.withLock { $0.append(frame.seq) }
            },
            skipped: { _ in },
            failed: {
                failedCount.withLock { $0 += 1 }
            }
        )

        let totalFrames = 250
        for seq in 1...totalFrames {
            decoder.push(BrowserFrame(seq: seq, tab: "t1", epoch: 1, width: 24, height: 18, jpeg: jpeg))
            if seq % 15 == 0 {
                try? await Task.sleep(for: .milliseconds(2))
            }
        }

        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if delivered.withLock({ $0.last }) == totalFrames { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        let seqs = delivered.withLock { $0 }
        #expect(failedCount.withLock { $0 } == 0)
        #expect(decoder.stats.mainThreadDecodes == 0)
        #expect(seqs.last == totalFrames, "last frame must never be dropped by a busy-flag race")
        for i in 1..<seqs.count {
            #expect(seqs[i] > seqs[i - 1], "decoded sequence numbers must stay strictly monotonic (no overlapping runs)")
        }
        decoder.close()
    }
}

// MARK: - 6. Screen RFB JPEG Bomb & Split DesktopSize Regressions (H26)

@MainActor
@Suite("Screen RFB and ScreenStream stress regressions")
struct ScreenStressRegressionTests {
    @Test func framebufferRejectsOversizedJPEGHeaderBeforeDecode() throws {
        let fb = try #require(ScreenFramebuffer(width: 64, height: 64))
        let bomb = StressJPEGHelper.withDimensions(width: 10_000, height: 10_000)
        #expect(!fb.drawJPEG(bomb, x: 0, y: 0, w: 64, h: 64), "oversized JPEG header must fail before CGImage decode")

        // Larger than framebuffer dimensions (128x128 > 64x64) is also rejected.
        let biggerThanFB = ScreenTestImage.jpeg(width: 128, height: 128, r: 0.9, g: 0.1, b: 0.1)
        #expect(!fb.drawJPEG(biggerThanFB, x: 0, y: 0, w: 64, h: 64), "JPEG larger than framebuffer must be rejected")

        let valid = ScreenTestImage.jpeg(width: 64, height: 64, r: 0.0, g: 1.0, b: 0.0)
        #expect(fb.drawJPEG(valid, x: 0, y: 0, w: 64, h: 64))
        #expect(fb.pixel(x: 16, y: 16).g > 200)
    }

    @Test func splitDesktopSizeAndPixelRectStillRequestsFullNonIncrementalFrame() async {
        let socket = FakeScreenSocket()
        let frames = Mutex<[(Int, Int)]>([])
        let stream = ScreenStream(
            socket: socket,
            onReady: { _, _ in },
            onFrame: { _, w, h, _ in frames.withLock { $0.append((w, h)) } },
            onEnd: { _ in }
        )
        stream.start()
        defer { stream.stop(handBack: false) }

        // Initial 64x48 frame.
        socket.push(RFBBuild.preamble(width: 64, height: 48) + RFBBuild.update([RFBBuild.tightFill(0, 0, 64, 48, r: 10, g: 20, b: 30)]))
        #expect(await screenWait { frames.withLock { $0.count } == 1 })

        // Build a 2-rect update: DesktopSize(96, 60) + TightFill(0, 0, 96, 60), split right between the two rects so
        // chunk 1 produces `out.resized == true, out.updates == 0` and chunk 2 produces `out.resized == false, out.updates == 1`.
        let desktopRect = RFBBuild.desktopSize(96, 60)
        let fillRect = RFBBuild.tightFill(0, 0, 96, 60, r: 40, g: 80, b: 120)
        let headerAndDesktop = Data([0, 0] + RFBBuild.be16(2)) + desktopRect
        socket.push(headerAndDesktop)
        try? await Task.sleep(for: .milliseconds(50))
        socket.push(fillRect)

        #expect(await screenWait { frames.withLock { $0.count } == 2 && socket.requests.count >= 3 })
        let expectedFull = RFBMessage.updateRequest(incremental: false, width: 96, height: 60)
        #expect(socket.requests.last == expectedFull,
                "latched resize across split frames must request a non-incremental 96x60 update")
    }
}

// MARK: - 7. TerminalConnection Resize During Dial Regression (H27)

@MainActor
@Suite("TerminalConnection resize during dial regressions", .serialized)
struct TerminalResizeDialStressRegressionTests {
    @Test func resizeWhileDialIsInFlightIsSentOnReady() async {
        TerminalConnection.backoff = { _ in .milliseconds(20) }
        TerminalConnection.giveUpAfter = 4

        let dialGate = StressGate()
        let socket = FakeTerminalSocket()
        let connection = TerminalConnection(session: String(repeating: "c", count: 32)) { _ in
            await dialGate.arriveAndWait()
            return socket
        }
        defer { connection.stop() }

        connection.start(cols: 80, rows: 24)
        await dialGate.waitUntilEntered()

        // Resize arrives while dial() is suspended on the handshake.
        connection.resize(cols: 120, rows: 40)
        dialGate.release()

        // Wait until the socket is installed and send `.ready`.
        try? await Task.sleep(for: .milliseconds(30))
        socket.ready(offset: 0)

        let live = await screenWait { connection.phase == TerminalConnection.Phase.live }
        #expect(live)
        #expect(socket.sent.contains(.text(TerminalWire.resize(cols: 120, rows: 40))),
                "a resize that happened while dial() was in flight must be sent once ready arrives")
    }
}

// MARK: - 8. ArtifactsViewController Popover Anchor Safety Regression (H8)

@MainActor
@Suite("Artifacts popover anchor safety regressions")
struct ArtifactsPopoverStressRegressionTests {
    @Test func offHierarchyAnchorFallsBackToHostViewCenter() {
        let host = UIViewController()
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 400, height: 600)

        let detachedAnchor = UIView(frame: CGRect(x: 10, y: 10, width: 40, height: 40))
        let sheet = UIActivityViewController(activityItems: ["https://example.com"], applicationActivities: nil)
        sheet.modalPresentationStyle = .popover

        ArtifactsViewController.point(sheet, item: nil, anchor: detachedAnchor, in: host)
        if let popover = sheet.popoverPresentationController {
            #expect(popover.sourceView === host.view)
            #expect(popover.permittedArrowDirections == [])
        }
    }
}

// MARK: - 9. HealthLookup Activity Move Mode Regression (H31)

#if !targetEnvironment(macCatalyst)
@Suite("HealthLookup activityMoveMode regressions")
struct HealthLookupStressRegressionTests {
    @Test func activityMoveModeNameReturnsNilWhenUnavailable() {
        #expect(HealthLookup.activityMoveModeName(nil) == nil)
        #expect(HealthLookup.activityMoveModeName(.appleMoveTime) == "move time")
        #expect(HealthLookup.activityMoveModeName(.activeEnergy) == "active energy")
    }
}
#endif
