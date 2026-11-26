// [tiles-v2] Unit tests for Tiles v2 improvements: pending maker persistence, bot-aware ideas, tile activity summary,
// Tall/Banner sizes, DashboardPage icons & drag-reorder, remote widget snapshot validation, content hashing, and prompts.

import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
import UIKit
import UniformTypeIdentifiers
import WebKit
@testable import HermesHQNative

private nonisolated final class FakeWidgetGateway: GatewayClient, Sendable {
    let account = GatewayAccount(id: "http://127.0.0.1:9745|tiles", baseURL: URL(string: "http://127.0.0.1:9745")!,
                                 kind: .password, username: "tiles", label: "tiles fixture")
    let responder: @Sendable (String, [URLQueryItem]) throws -> Data

    init(responder: @escaping @Sendable (String, [URLQueryItem]) throws -> Data) {
        self.responder = responder
    }

    func rest(_ method: String, _ path: String, query: [URLQueryItem], body: Data?) async throws -> Data {
        try responder(path, query)
    }

    func call(_ method: String, _ params: JSONValue, timeout: Duration) async throws -> JSONValue { .object([:]) }
    func events() -> AsyncStream<GatewayEvent> { AsyncStream { _ in } }
    func connectionStates() -> AsyncStream<ConnectionState> { AsyncStream { $0.yield(.ready) } }
    var latestReady: JSONValue? { nil }
    func appDidBecomeActive() {}
    func appDidEnterBackground() {}
    func shutdown() {}
}

@MainActor
struct TilesV2Tests {
    private func freshDefaults() -> UserDefaults {
        let name = "tiles-v2-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func sampleJPEG(width: Int = 160, height: Int = 160) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cg = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    // MARK: Pending TileMaker persistence

    @Test func pendingMakersPersistPruneAndRemove() {
        let defaults = freshDefaults()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fresh = PendingTileMaker(id: "m1", accountId: "acct-1", sessionId: "sess-1", botId: "otto",
                                     pinId: nil, pinName: nil, path: "", what: "Revenue this week",
                                     dashboardPage: "main", desiredSize: .banner, acting: false,
                                     askedAt: now.timeIntervalSince1970 - 60)
        let stale = PendingTileMaker(id: "m2", accountId: "acct-1", sessionId: "sess-2", botId: "ivy",
                                     pinId: "pin-1", pinName: "Weather", path: "/Users/me/w.html", what: "Add wind",
                                     dashboardPage: "main", desiredSize: nil, acting: false,
                                     askedAt: now.timeIntervalSince1970 - TilePendingStore.maxAge - 10)
        TilePendingStore.upsert(fresh, defaults: defaults, now: now)
        TilePendingStore.upsert(stale, defaults: defaults, now: now)

        let loaded = TilePendingStore.load(accountId: "acct-1", defaults: defaults, now: now)
        #expect(loaded == [fresh], "expired entries are pruned on load")
        #expect(TilePendingStore.load(accountId: "acct-2", defaults: defaults, now: now).isEmpty)

        TilePendingStore.remove(id: "m1", accountId: "acct-1", defaults: defaults)
        #expect(TilePendingStore.load(accountId: "acct-1", defaults: defaults, now: now).isEmpty)
    }

    // MARK: Bot-aware ideas

    @Test func ideasRankMatchingBotRolesFirst() {
        let dev = TileIdeaMatcher.ranked(for: ["Wren", "GitHub engineer and code reviewer"])
        #expect(dev.first?.words.contains("GitHub") == true)
        #expect(dev.first?.matched == true)
        #expect(dev.count == TileIdeaMatcher.catalog.count)

        let fitness = TileIdeaMatcher.ranked(for: ["Juno", "Health & workout coach"])
        #expect(fitness.first?.words.contains("workouts") == true)
        #expect(fitness.first?.matched == true)

        let generic = TileIdeaMatcher.ranked(for: [])
        #expect(generic.allSatisfy { !$0.matched })
    }

    // MARK: Tile activity & daily run estimation

    @Test func activitySummaryEstimatesDailyModelRuns() {
        var hourly = CronJob(id: "j1")
        hourly.schedule = CronSchedule(kind: "cron", expr: "0 * * * *")
        hourly.enabled = true

        var every15 = CronJob(id: "j2")
        every15.schedule = CronSchedule(kind: "cron", expr: "*/15 * * * *")
        every15.enabled = true

        var scriptJob = CronJob(id: "j3")
        scriptJob.schedule = CronSchedule(kind: "cron", expr: "*/15 * * * *")
        scriptJob.noAgent = true
        scriptJob.enabled = true

        var pausedJob = CronJob(id: "j4")
        pausedJob.schedule = CronSchedule(kind: "cron", expr: "0 * * * *")
        pausedJob.enabled = false

        var failedJob = CronJob(id: "j5")
        failedJob.schedule = CronSchedule(kind: "cron", expr: "0 8 * * *")
        failedJob.enabled = true
        failedJob.lastStatus = "error"
        failedJob.lastError = "Timeout"

        #expect(TileJobs.estimatedRunsPerDay(hourly) == 24)
        #expect(TileJobs.estimatedRunsPerDay(every15) == 96)
        #expect(TileJobs.estimatedRunsPerDay(pausedJob) == nil)
        #expect(TileJobs.estimatedRunsPerDay(failedJob) == 1)

        let summary = TileActivitySummary.summarize([hourly, every15, scriptJob, pausedJob, failedJob])
        #expect(summary.totalJobs == 5)
        #expect(summary.activeJobs == 4)
        #expect(summary.pausedJobs == 1)
        #expect(summary.failingJobs == 1)
        #expect(summary.scriptJobs == 1)
        #expect(summary.estimatedModelRunsPerDay == 121)
        #expect(summary.headline == "4 active tiles · ~121 model runs/day")
        #expect(summary.detail == "1 failing · 1 paused · 1 script-only")
    }

    // MARK: DashboardPage icons & drag-reorder

    @Test func dashboardPagesSupportIconsAndDragReorder() throws {
        let pins = ArtifactPins(fileURL: nil)
        let work = pins.addPage(named: "Work", symbol: "briefcase.fill")
        let home = pins.addPage(named: "Home")
        let ops = pins.addPage(named: "Ops", symbol: "bolt.fill")

        #expect(pins.pages.map(\.name) == ["Main", "Work", "Home", "Ops"])
        #expect(pins.pages[1].symbol == "briefcase.fill")
        #expect(pins.pages[2].symbol == nil)

        pins.setPageSymbol(home.id, symbol: "house.fill")
        #expect(pins.pages[2].symbol == "house.fill")

        // Drag Ops onto Work's position (Main always stays first).
        pins.reorderPage(ops.id, to: work.id)
        #expect(pins.pages.map(\.name) == ["Main", "Ops", "Work", "Home"])

        // Attempting to reorder Main does nothing; dragging onto Main lands at index 1.
        pins.reorderPage(DashboardPage.mainId, to: home.id)
        #expect(pins.pages[0].id == DashboardPage.mainId)
        pins.reorderPage(home.id, to: DashboardPage.mainId)
        #expect(pins.pages.map(\.name) == ["Main", "Home", "Ops", "Work"])

        // Backward-compatible decoding of old DashboardPage JSON without `symbol`.
        let oldJSON = #"{"id":"p1","name":"Finance"}"#
        let decoded = try JSONDecoder().decode(DashboardPage.self, from: Data(oldJSON.utf8))
        #expect(decoded.name == "Finance" && decoded.symbol == nil)
    }

    // MARK: New prompts & schedules

    @Test func promptsCarrySizeScheduleDuplicateAndRecoveryDetails() {
        let sized = TileMaker.prompt("Sales", size: .banner, schedule: .every(TileJobs.frequencies[0]))
        #expect(sized.contains("Banner (full-width × 1 strip)"))
        #expect(sized.contains("every 15 min"))
        #expect(sized.contains("*/15 * * * *"))

        let oneTime = TileMaker.prompt("Launch countdown", size: .tall, schedule: .oneTime)
        #expect(oneTime.contains("Tall (1×2 vertical)"))
        #expect(oneTime.contains("one-time static tile"))

        let sched = TileJobs.schedulePrompt(path: "/Users/me/dash/a.html", name: "Alpha", frequency: TileJobs.frequencies[2])
        #expect(sched.contains("hourly"))
        #expect(sched.contains("hq-tile-job"))
        #expect(sched.contains("MEDIA:/Users/me/dash/a.html"))

        let fix = TileJobs.fixPrefill(error: "API rate limit\nstack trace")
        #expect(fix.contains("API rate limit"))
        #expect(!fix.contains("stack trace"))

        let dup = TileJobs.duplicatePrompt(sourcePath: "/Users/me/dash/rev.html", sourceName: "Revenue", what: "Expenses", size: .medium)
        #expect(dup.contains("do not overwrite /Users/me/dash/rev.html"))
        #expect(dup.contains("Expenses"))
        #expect(dup.contains("Medium (2×1 wide)"))
    }

    // MARK: Content hash & remote widget snapshots

    @Test func contentHashMatchesIdenticalBytesAndChangesOnDiff() {
        let a = PageSnapshots.contentHash(Data("<html>hello</html>".utf8))
        let b = PageSnapshots.contentHash(Data("<html>hello</html>".utf8))
        let c = PageSnapshots.contentHash(Data("<html>world</html>".utf8))
        #expect(a.count == 64)
        #expect(a == b)
        #expect(a != c)
    }

    @Test func remoteWidgetSnapshotHandlesSuccessAndUnsupportedGracefully() async {
        let jpeg = sampleJPEG(width: 320, height: 160)
        let okGateway = FakeWidgetGateway { path, query in
            #expect(path == TileWidgetRemote.endpoint)
            #expect(query.first { $0.name == "theme" }?.value == "dark")
            return jpeg
        }
        let ok = await TileWidgetRemote.fetch(client: okGateway, path: "/Users/me/d.html", profile: "otto",
                                              width: 160, height: 80, dark: true, scale: 2, maxBytes: TileWidgetStore.maxPictureBytes)
        #expect(ok == .picture(jpeg, width: 320, height: 160))

        let missingGateway = FakeWidgetGateway { _, _ in throw HTTPError(status: 404, body: "Not Found") }
        let missing = await TileWidgetRemote.fetch(client: missingGateway, path: "/Users/me/d.html", profile: "default",
                                                   width: 160, height: 80, dark: false, scale: 2, maxBytes: TileWidgetStore.maxPictureBytes)
        #expect(missing == .unsupported)

        let badBytesGateway = FakeWidgetGateway { _, _ in Data("not a jpeg".utf8) }
        let bad = await TileWidgetRemote.fetch(client: badBytesGateway, path: "/Users/me/d.html", profile: "default",
                                               width: 160, height: 80, dark: false, scale: 2, maxBytes: TileWidgetStore.maxPictureBytes)
        #expect(bad == .unavailable)
    }

    // MARK: Theme & light/dark updates on tiles

    @Test func themeKeyTracksVisualThemeAndModeOnly() {
        let light = HTMLPageSheet.pageTraits(dark: false)
        let dark = HTMLPageSheet.pageTraits(dark: true)
        let highLight = HTMLPageSheet.pageTraits(dark: false, highContrast: true)

        let lightKey = HTMLPageSheet.themeKey(light)
        let darkKey = HTMLPageSheet.themeKey(dark)
        let highKey = HTMLPageSheet.themeKey(highLight)
        #expect(lightKey != darkKey)
        #expect(lightKey != highKey)

        let skinKey = ThemeTable.$testSet.withValue(ThemeResolver.resolve(ThemeState(skinID: "catppuccin"))) {
            HTMLPageSheet.themeKey(light)
        }
        #expect(skinKey != lightKey)

        let desktopKey = ThemeTable.$testSet.withValue(ThemeResolver.resolve(ThemeState(desktopLook: true))) {
            HTMLPageSheet.themeKey(light)
        }
        #expect(desktopKey != lightKey)

        let unrelatedKey = ThemeTable.$testSet.withValue(ThemeResolver.resolve(ThemeState(bubbleCorners: 20, density: .compact))) {
            HTMLPageSheet.themeKey(light)
        }
        #expect(unrelatedKey == lightKey)

        let ctx = MediaContext(accountId: MediaContext.demoAccount, profile: "otto", storedSessionId: "s-theme")
        #expect(PageSnapshots.shared.key(path: "/Users/me/tile.html", context: ctx, traits: light)
                != PageSnapshots.shared.key(path: "/Users/me/tile.html", context: ctx, traits: dark))
    }

    @Test func applyThemeUpdatesWebViewInPlaceWithoutReload() async throws {
        let html = """
        <!doctype html><html><body>
        <h2 id="h" style="color:#1d3a5c">Heading</h2>
        <p id="p" style="color:var(--foreground);border:1px solid var(--accent)">Body</p>
        </body></html>
        """
        let lightTraits = HTMLPageSheet.pageTraits(dark: false)
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(
            source: HTMLPageSheet.prelude(lightTraits, talks: false),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 320), configuration: config)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = web.frame
        window.overrideUserInterfaceStyle = .light
        window.addSubview(web)
        window.isHidden = false
        defer { window.isHidden = true }

        web.loadHTMLString(html, baseURL: nil)
        for _ in 0..<80 {
            try await Task.sleep(for: .milliseconds(50))
            let ready = (try? await web.evaluateJavaScript(
                "document.readyState === 'complete' && !!window.__hqLegible && typeof window.__hqApplyTheme === 'function'"
            )) as? Bool
            if ready == true { break }
        }

        let darkTraits = HTMLPageSheet.pageTraits(dark: true)
        web.overrideUserInterfaceStyle = .dark
        let needsReload = try await web.evaluateJavaScript(HTMLPageSheet.applyThemeScript(darkTraits)) as? Bool
        #expect(needsReload == false)
        try await Task.sleep(for: .milliseconds(100))

        let scheme = try #require(try await web.evaluateJavaScript("getComputedStyle(document.documentElement).colorScheme") as? String)
        #expect(scheme.contains("dark"))

        let headingRGB = try #require(try await web.evaluateJavaScript(
            "getComputedStyle(document.getElementById('h')).color"
        ) as? String)
        #expect(headingRGB != "rgb(29, 58, 92)", "dark heading ink should be lifted in place for dark ground, got \(headingRGB)")

        let beforeBorder = try #require(try await web.evaluateJavaScript(
            "getComputedStyle(document.getElementById('p')).borderTopColor"
        ) as? String)
        let solarizedAccent = try await ThemeTable.$testSet.withValue(ThemeResolver.resolve(ThemeState(skinID: "solarized"))) {
            let traits = HTMLPageSheet.pageTraits(dark: true)
            let reload = try await web.evaluateJavaScript(HTMLPageSheet.applyThemeScript(traits)) as? Bool
            #expect(reload == false)
            return try #require(try await web.evaluateJavaScript(
                "getComputedStyle(document.getElementById('p')).borderTopColor"
            ) as? String)
        }
        #expect(solarizedAccent != beforeBorder)

        _ = try await web.evaluateJavaScript("document.body.appendChild(document.createElement('canvas'));0")
        let canvasNeedsReload = try await web.evaluateJavaScript(HTMLPageSheet.applyThemeScript(lightTraits)) as? Bool
        #expect(canvasNeedsReload == true)
    }

    @Test func snapshotReRendersWithNewThemeAndCancelsStalePrewarm() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "tile-theme-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let tileURL = dir.appending(path: "tile.html")
        let html = """
        <!doctype html><html><head><style>
        html,body{margin:0;width:100vw;height:100vh;overflow:hidden}
        body{background:var(--card,#ffffff);color:var(--foreground,#111111)}
        @media(prefers-color-scheme:dark){body{background:#101218;color:#f5f5f7}}
        </style></head><body><div>Tile</div></body></html>
        """
        try Data(html.utf8).write(to: tileURL)

        let ctx = MediaContext(accountId: MediaContext.demoAccount, profile: "otto", storedSessionId: "s-snap-theme")
        let shape = PageSnapshots.Shape.frame(width: 180, height: 180)
        let lightTraits = HTMLPageSheet.pageTraits(dark: false)
        let darkTraits = HTMLPageSheet.pageTraits(dark: true)

        let lightResult = await snapshot(path: tileURL.path, name: "tile.html", context: ctx, traits: lightTraits, shape: shape)
        guard case .image(let lightImg) = lightResult else {
            Issue.record("expected light snapshot image")
            return
        }

        let darkResult = await snapshot(path: tileURL.path, name: "tile.html", context: ctx, traits: darkTraits, shape: shape)
        guard case .image(let darkImg) = darkResult else {
            Issue.record("expected dark snapshot image")
            return
        }

        let lightEdge = try #require(PinPictures.edgeColor(lightImg))
        let darkEdge = try #require(PinPictures.edgeColor(darkImg))
        #expect(lightEdge != darkEdge)

        let skinResult = await ThemeTable.$testSet.withValue(ThemeResolver.resolve(ThemeState(skinID: "catppuccin"))) {
            let traits = HTMLPageSheet.pageTraits(dark: false)
            return await snapshot(path: tileURL.path, name: "tile.html", context: ctx, traits: traits, shape: shape)
        }
        guard case .image(let skinImg) = skinResult else {
            Issue.record("expected catppuccin light snapshot image")
            return
        }
        let skinEdge = try #require(PinPictures.edgeColor(skinImg))
        #expect(skinEdge != lightEdge)

        // Verify cancelling background prewarm settles pending callbacks cleanly without hanging.
        var prewarmResults: [PageSnapshots.SnapshotResult] = []
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let extraURL = dir.appending(path: "prewarm.html")
            try? Data(html.utf8).write(to: extraURL)
            let prewarmShape = PageSnapshots.Shape.frame(width: 200, height: 200)
            PageSnapshots.shared.pictureResult(path: extraURL.path, name: "prewarm.html", context: ctx,
                                               traits: darkTraits, shape: prewarmShape,
                                               priority: .background, localOnly: true, cancelOnModeChange: true) { result in
                prewarmResults.append(result)
                done.resume()
            }
            PageSnapshots.shared.cancelPrewarm()
        }
        #expect(prewarmResults.count == 1)
    }

    private func snapshot(path: String, name: String, context: MediaContext, traits: UITraitCollection,
                          shape: PageSnapshots.Shape) async -> PageSnapshots.SnapshotResult {
        await withCheckedContinuation { continuation in
            PageSnapshots.shared.pictureResult(path: path, name: name, context: context, traits: traits, shape: shape) {
                continuation.resume(returning: $0)
            }
        }
    }
}
