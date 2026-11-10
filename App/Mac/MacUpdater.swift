// [mac] The website's download keeps itself up to date (owner, Oct 23: "automatic updates need to be built in - the
// user needs to be prompted to update"). Sparkle checks gethermeshq.com's appcast once a day and with Hermes HQ ›
// Check for Updates…, asks before it installs a newer build, and relaunches the app (docs/mac.md, "Updates").
// [mac-update] Owner 2026-11-10: Sparkle's stock windows let the update "fall off" out of sight. Its updater now runs
// with the app's own user driver (`MacUpdateDriver`, below): every step shows in the app's update sheet
// (MacAppUpdate.swift), and the copy that opens after the install says what happened.
//
// Only the download carries Sparkle: `ship.py dmg` puts Sparkle.framework in Contents/Frameworks and the feed and
// public key in Info.plist. The App Store build has neither, so there this does nothing and the menu item never shows.
// Sparkle is a macOS (AppKit) framework a Mac Catalyst target can't link, so it is loaded when the app starts and
// driven through the Objective-C runtime.
//
// [diagnostics] Every step is a `mac` log line: whether Sparkle started (and why not), each check and what it found,
// a download or install that failed (with Sparkle's error), the install and relaunch (`UpdaterLog`, its delegate).

import ObjectiveC
import UIKit

#if targetEnvironment(macCatalyst)
/// The part of Sparkle's SPUUpdater the app uses.
@objc(HQSparkleUpdater) private protocol SparkleUpdater: NSObjectProtocol {
    init(hostBundle: Bundle, applicationBundle: Bundle, userDriver: AnyObject, delegate: AnyObject?)
    @objc(startUpdater:) func startUpdater() throws
    func checkForUpdates()
    var canCheckForUpdates: Bool { get }
    var sessionInProgress: Bool { get }
}

/// SUUpdatePermissionResponse's initializer (only asked for when SUEnableAutomaticChecks is missing from Info.plist).
@objc(HQSparklePermissionResponse) private protocol SparklePermissionResponse: NSObjectProtocol {
    init(automaticUpdateChecks: Bool, sendSystemProfile: Bool)
}

@MainActor enum MacUpdater {
    private static var updater: SparkleUpdater?
    private static let driver = MacUpdateDriver()
    static let check = #selector(AppDelegate.hqCheckForUpdates(_:))

    /// Starts Sparkle when the app has it; it then checks on its own schedule (SUEnableAutomaticChecks).
    static func start() {
        #if DEBUG
        // `-HQDebugMacUpdateShot checking|found|downloading|unpacking|ready|restarting|stuck|onquit|uptodate|failed|failed-signature|updated|didnt`:
        // the update sheet in that state with a made-up update (no Sparkle in a Debug build). Pair with -HQDebugMacShots.
        if let state = UserDefaults.standard.string(forKey: "HQDebugMacUpdateShot") {
            UIMenuSystem.main.setNeedsRebuild()
            Task { @MainActor in
                for _ in 0..<60 where MainTabController.current?.viewIfLoaded?.window == nil { try? await Task.sleep(for: .seconds(0.5)) }
                try? await Task.sleep(for: .seconds(2))
                MacAppUpdate.shared.demo(state)
            }
        }
        #endif
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
            AppLog.note("mac", "updates: none in this build (no feed)")
            return
        }
        guard let url = Bundle.main.privateFrameworksURL?.appendingPathComponent("Sparkle.framework"),
              let sparkle = Bundle(url: url) else {
            AppLog.note("mac", "updates: off, Sparkle.framework is missing")
            return
        }
        do { try sparkle.loadAndReturnError() } catch {
            AppLog.error("updates: Sparkle did not load", error)
            return
        }
        guard let type = NSClassFromString("SPUUpdater") else {
            AppLog.note("mac", "updates: off, Sparkle has no SPUUpdater")
            return
        }
        class_addProtocol(type, SparkleUpdater.self)
        if let userDriver = objc_getProtocol("SPUUserDriver") { class_addProtocol(MacUpdateDriver.self, userDriver) }
        guard let updaterType = type as? SparkleUpdater.Type else { return }
        let made = updaterType.init(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: UpdaterLog.shared)
        let version = sparkle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        do {
            try made.startUpdater()
        } catch {
            AppLog.error("updates: Sparkle \(version) didn't start", error)
            return
        }
        updater = made
        let automatic = UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") as? Bool
            ?? Bundle.main.object(forInfoDictionaryKey: "SUEnableAutomaticChecks") as? Bool ?? false
        AppLog.note("mac", "updates: Sparkle \(version) started with the app's update sheet, automatic checks \(automatic ? "on" : "off")")
        UIMenuSystem.main.setNeedsRebuild()
        MacAppUpdate.shared.launched()
        #if DEBUG
        debugFilm()
        #endif
    }

    static func checkNow() {
        let update = MacAppUpdate.shared
        // An update already on show (or hidden while it downloads): bring it back rather than start over.
        if update.isRunning || update.phase == .found {
            update.show()
            return
        }
        AppLog.note("mac", "updates: Check for Updates…")
        #if DEBUG
        if updater == nil, UserDefaults.standard.string(forKey: "HQDebugMacUpdateShot") != nil { update.demo("checking"); return }
        #endif
        guard let updater else { return }
        if !updater.canCheckForUpdates {
            // A background download or check is under way: say so instead of doing nothing.
            AppLog.note("mac", "updates: a check is already under way")
            update.show()
            return
        }
        updater.checkForUpdates()
    }

    /// Hermes HQ › Check for Updates… (Show Update… while one is under way), under About, in the download only.
    static func addMenuItem(_ builder: UIMenuBuilder) {
        var shown = updater != nil
        #if DEBUG
        shown = shown || UserDefaults.standard.string(forKey: "HQDebugMacUpdateShot") != nil
        #endif
        guard shown else { return }
        let item = UICommand(title: MacAppUpdate.shared.menuTitle, action: check)
        builder.insertSibling(UIMenu(title: "", options: .displayInline, children: [item]), afterMenu: .about)
    }
}

#if DEBUG
extension MacUpdater {
    /// [mac-update] DEBUG, for the end-to-end test of a real update (two Debug copies, a local feed):
    /// `-HQDebugMacUpdateFilm YES` photographs the update sheet whenever it changes (`film-<run>-<n>-<phase>.png`, and
    /// the window at the offer and at "Updated") through `-HQDebugMacShotsPost`, with a line per picture in
    /// `film-<run>.txt`; `-HQDebugMacUpdateCheck YES` checks 3 s after start; `-HQDebugMacUpdateGo YES` presses Update
    /// Now. Film and Post are saved so the copy Sparkle reopens (with no arguments) films too; it clears them after 25 s
    /// and quits.
    static func debugFilm() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "HQDebugMacUpdateFilm") else { return }
        let update = MacAppUpdate.shared
        let startedOn = defaults.string(forKey: "HQDebugMacUpdateFilmBuild")
        let reopened = startedOn != nil && startedOn != update.currentBuild
        // Saved only when an install is coming (Go): the copy Sparkle reopens clears them. Debug copies share one data
        // folder, so a saved Film would set any later Debug launch filming.
        if !reopened, defaults.bool(forKey: "HQDebugMacUpdateGo") {
            defaults.set(true, forKey: "HQDebugMacUpdateFilm")
            if let post = defaults.string(forKey: "HQDebugMacShotsPost") { defaults.set(post, forKey: "HQDebugMacShotsPost") }
            defaults.set(update.currentBuild, forKey: "HQDebugMacUpdateFilmBuild")
        }
        let run = reopened ? "b" : "a"
        let folder = FileManager.default.temporaryDirectory.appending(path: "mac-update-film", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let notes = folder.appending(path: "film-\(run).txt")
        var lines = ["run \(run) build \(update.currentBuild) started \(Date())"]
        Task { @MainActor in
            if !reopened, defaults.bool(forKey: "HQDebugMacUpdateCheck") {
                try? await Task.sleep(for: .seconds(3))
                checkNow()
            }
        }
        Task { @MainActor in
            let start = Date()
            var count = 0
            var last = ""
            var lastShot = Date.distantPast
            var pressed = false
            var windowShots: Set<String> = []
            while count < 300 {
                try? await Task.sleep(for: .seconds(0.4))
                let phase = String(describing: update.phase).components(separatedBy: "(").first ?? "?"
                let steps = update.steps.map { "\($0.id.rawValue)=\($0.state)\($0.detail.map { ":" + $0 } ?? "")" }.joined(separator: " ")
                let state = "\(phase) | \(update.headline) | \(update.line ?? "") | \(steps) | countdown \(update.countdown.map(String.init) ?? "-")"
                if !reopened, !pressed, update.phase == .found, defaults.bool(forKey: "HQDebugMacUpdateGo") {
                    pressed = true
                    try? await Task.sleep(for: .seconds(2.5))
                    lines.append("\(String(format: "%6.1f", Date().timeIntervalSince(start))) pressing Update Now")
                    update.updateNow()
                    continue
                }
                if let window = update.debugSheetWindow, state != last || Date().timeIntervalSince(lastShot) > 3 {
                    count += 1
                    last = state
                    lastShot = Date()
                    let name = String(format: "film-%@-%03d-%@.png", run, count, phase)
                    MacShots.shoot(window, to: folder.appending(path: name))
                    lines.append("\(String(format: "%6.1f", Date().timeIntervalSince(start))) \(name) \(state)")
                    try? lines.joined(separator: "\n").write(to: notes, atomically: true, encoding: .utf8)
                    MacShots.post(notes)
                    if (phase == "found" || phase == "updated" || phase == "didntFinish"), !windowShots.contains(phase),
                       let main = MainTabController.current?.viewIfLoaded?.window {
                        windowShots.insert(phase)
                        MacShots.shoot(main, to: folder.appending(path: "film-\(run)-window-\(phase).png"))
                    }
                }
                if reopened, Date().timeIntervalSince(start) > 25 {
                    for key in ["HQDebugMacUpdateFilm", "HQDebugMacShotsPost", "HQDebugMacUpdateFilmBuild"] { defaults.removeObject(forKey: key) }
                    lines.append("done, quitting")
                    try? lines.joined(separator: "\n").write(to: notes, atomically: true, encoding: .utf8)
                    MacShots.post(notes)
                    try? await Task.sleep(for: .seconds(1.5))
                    exit(0)
                }
            }
        }
    }
}
#endif

/// Sparkle's user driver (SPUUserDriver, SPUUserDriver.h): each call goes to the app's update sheet. Sparkle calls these
/// on the main thread and holds the driver strongly; `MacUpdater.driver` keeps it too.
final class MacUpdateDriver: NSObject {

    @objc(showUpdatePermissionRequest:reply:)
    func permission(_ request: NSObject, reply: @escaping @convention(block) (NSObject) -> Void) {
        // Info.plist sets SUEnableAutomaticChecks, so Sparkle shouldn't ask; if it does, the daily check stays on.
        AppLog.note("mac", "updates: Sparkle asked about automatic checks; answered yes")
        guard let type = NSClassFromString("SUUpdatePermissionResponse") else { return }
        class_addProtocol(type, SparklePermissionResponse.self)
        guard let responseType = type as? SparklePermissionResponse.Type else { return }
        guard let response = responseType.init(automaticUpdateChecks: true, sendSystemProfile: false) as? NSObject else { return }
        reply(response)
    }

    @objc(showUserInitiatedUpdateCheckWithCancellation:)
    func checking(_ cancellation: @escaping @convention(block) () -> Void) {
        MainActor.assumeIsolated { MacAppUpdate.shared.checking(cancel: cancellation) }
    }

    @objc(showUpdateFoundWithAppcastItem:state:reply:)
    func found(_ item: NSObject, state: NSObject, reply: @escaping @convention(block) (Int) -> Void) {
        MainActor.assumeIsolated { MacAppUpdate.shared.found(item: item, state: state, reply: reply) }
    }

    @objc(showUpdateReleaseNotesWithDownloadData:)
    func releaseNotes(_ data: NSObject) {
        // The appcast carries its notes inline (`ship.py appcast`), so there is no separate page to show.
    }

    @objc(showUpdateReleaseNotesFailedToDownloadWithError:)
    func releaseNotesFailed(_ error: NSError) {
        AppLog.note("mac", "updates: release notes didn't load: \(error.domain) \(error.code)")
    }

    @objc(showUpdateNotFoundWithError:acknowledgement:)
    func notFound(_ error: NSError, acknowledgement: @escaping @convention(block) () -> Void) {
        MainActor.assumeIsolated { MacAppUpdate.shared.upToDate(error, acknowledge: acknowledgement) }
    }

    @objc(showUpdaterError:acknowledgement:)
    func failed(_ error: NSError, acknowledgement: @escaping @convention(block) () -> Void) {
        AppLog.note("mac", "updates: error shown: \(error.domain) \(error.code)")
        MainActor.assumeIsolated { MacAppUpdate.shared.failed(error, acknowledge: acknowledgement) }
    }

    @objc(showDownloadInitiatedWithCancellation:)
    func downloadStarted(_ cancellation: @escaping @convention(block) () -> Void) {
        MainActor.assumeIsolated { MacAppUpdate.shared.downloadStarted(cancel: cancellation) }
    }

    @objc(showDownloadDidReceiveExpectedContentLength:)
    func downloadSize(_ length: UInt64) {
        MainActor.assumeIsolated { MacAppUpdate.shared.downloadSize(length) }
    }

    @objc(showDownloadDidReceiveDataOfLength:)
    func downloaded(_ length: UInt64) {
        MainActor.assumeIsolated { MacAppUpdate.shared.downloaded(length) }
    }

    @objc(showDownloadDidStartExtractingUpdate)
    func unpacking() {
        MainActor.assumeIsolated { MacAppUpdate.shared.unpacking() }
    }

    @objc(showExtractionReceivedProgress:)
    func unpackProgress(_ progress: Double) {
        MainActor.assumeIsolated { MacAppUpdate.shared.unpackProgress(progress) }
    }

    @objc(showReadyToInstallAndRelaunch:)
    func ready(_ reply: @escaping @convention(block) (Int) -> Void) {
        MainActor.assumeIsolated { MacAppUpdate.shared.readyToInstall(reply: reply) }
    }

    @objc(showInstallingUpdateWithApplicationTerminated:retryTerminatingApplication:)
    func installing(_ terminated: Bool, retryTerminatingApplication: @escaping @convention(block) () -> Void) {
        DiagnosticLog.shared.flush()
        MainActor.assumeIsolated { MacAppUpdate.shared.installing(terminated: terminated, retry: retryTerminatingApplication) }
    }

    @objc(showUpdateInstalledAndRelaunched:acknowledgement:)
    func installed(_ relaunched: Bool, acknowledgement: @escaping @convention(block) () -> Void) {
        MainActor.assumeIsolated { MacAppUpdate.shared.installedAndRelaunched(relaunched, acknowledge: acknowledgement) }
    }

    @objc(dismissUpdateInstallation)
    func dismiss() {
        MainActor.assumeIsolated { MacAppUpdate.shared.dismissed() }
    }

    @objc(showUpdateInFocus)
    func focus() {
        MainActor.assumeIsolated { MacAppUpdate.shared.focus() }
    }
}

extension AppDelegate {
    @objc func hqCheckForUpdates(_ sender: Any?) { MacUpdater.checkNow() }
}

/// Sparkle's updater delegate (SPUUpdaterDelegate), only to log: Sparkle asks with respondsToSelector, so these
/// optional methods are all it sees. It holds its delegate weakly; `shared` keeps this one.
final class UpdaterLog: NSObject {
    static let shared = UpdaterLog()

    /// "1.0 (456)": an appcast item's display version and build.
    private static func version(_ item: NSObject) -> String {
        let display = item.value(forKey: "displayVersionString") as? String ?? "?"
        let build = item.value(forKey: "versionString") as? String ?? "?"
        return "\(display) (\(build))"
    }

    private static func words(_ error: NSError) -> String {
        "\(error.domain) \(error.code): \(AppLog.scrub(error.localizedDescription))"
            + ((error.userInfo[NSUnderlyingErrorKey] as? NSError).map { " (under it: \($0.domain) \($0.code))" } ?? "")
    }

    @objc(updater:didFinishLoadingAppcast:) func didLoadAppcast(_ updater: NSObject, _ appcast: NSObject) {
        AppLog.trace("mac", "updates: the appcast loaded")
    }

    @objc(updater:didFindValidUpdate:) func didFind(_ updater: NSObject, _ item: NSObject) {
        AppLog.note("mac", "updates: found \(Self.version(item))")
    }

    @objc(updaterDidNotFindUpdate:error:) func didNotFind(_ updater: NSObject, _ error: NSError) {
        AppLog.note("mac", "updates: up to date (\(Self.words(error)))")
    }

    @objc(updater:didDownloadUpdate:) func didDownload(_ updater: NSObject, _ item: NSObject) {
        AppLog.note("mac", "updates: downloaded \(Self.version(item))")
    }

    @objc(updater:failedToDownloadUpdate:error:) func failedToDownload(_ updater: NSObject, _ item: NSObject, _ error: NSError) {
        AppLog.note("mac", "updates: download of \(Self.version(item)) failed: \(Self.words(error))")
    }

    @objc(updater:willInstallUpdate:) func willInstall(_ updater: NSObject, _ item: NSObject) {
        AppLog.note("mac", "updates: installing \(Self.version(item))")
        DiagnosticLog.shared.flush()
    }

    @objc(updaterWillRelaunchApplication:) func willRelaunch(_ updater: NSObject) {
        AppLog.note("mac", "updates: relaunching")
        DiagnosticLog.shared.flush()
    }

    @objc(updater:didAbortWithError:) func didAbort(_ updater: NSObject, _ error: NSError) {
        AppLog.note("mac", "updates: stopped: \(Self.words(error))")
    }

    @objc(userDidCancelDownload:) func userDidCancelDownload(_ updater: NSObject) {
        AppLog.note("mac", "updates: download cancelled")
    }

    @objc(updater:userDidMakeChoice:forUpdate:state:) func userChoice(_ updater: NSObject, _ choice: Int, _ item: NSObject, _ state: NSObject) {
        let words = [0: "skip this version", 1: "install", 2: "remind me later"]
        AppLog.note("mac", "updates: the person chose \(words[choice] ?? "choice \(choice)") for \(Self.version(item))")
    }
}
#endif
