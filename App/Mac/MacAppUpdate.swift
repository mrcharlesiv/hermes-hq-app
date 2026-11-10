// [mac-update] The Mac download's own update sheet, in place of Sparkle's stock windows. Owner 2026-11-10: "The Mac app
// needs a better update UI UX. It just kinda like falls off and you can't see what it is doing. Make it GREAT."
//
// Sparkle still does the work (MacUpdater.swift: the appcast, the EdDSA check, the installer, the relaunch); this is
// its user driver (SPUUserDriver), so every step it takes shows here, in the app's own window:
//   Checking → Update Available (versions, size, What's New; Later, Skip This Version, Update Now)
//   → Updating: Download (MB, speed, time left, a bar) → Check & Unpack → Install → Reopen
//   → Ready to Restart: a 5-second countdown with Restart Now and Later (installs when you quit)
//   → Restarting: says the app closes and opens again by itself (and, if macOS won't let it close, Try Again)
//   → the copy that opens says "Updated to 1.0.2 (925)" with what's new, or that the update didn't take.
// The sheet can be hidden while it downloads; the Dock icon then shows the percent, Hermes HQ › Show Update… brings
// it back, and it comes forward by itself for the countdown. Pure half: HermesKit/Pages/More/MacAppUpdateFlow.swift.

#if targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

@MainActor @Observable final class MacAppUpdate {
    static let shared = MacAppUpdate()

    enum Phase: Equatable {
        case idle
        case checking
        case found
        case working
        case ready
        case restarting
        case onQuit
        case upToDate(String)
        case failed(headline: String, line: String)
        case updated
        case didntFinish
    }

    struct Step: Identifiable, Equatable {
        let id: MacAppUpdateStepID
        var state: MacAppUpdateStepState = .waiting
        var detail: String?
        var started: Date?
        var finished: Date?
    }

    private(set) var phase: Phase = .idle
    let currentBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    let current = MacAppUpdateWords.version(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                                            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    private(set) var target: String?
    private(set) var targetBuild: String?
    private(set) var size: UInt64?
    private(set) var notes = MacAppUpdateNotes.empty
    private(set) var critical = false
    /// Downloaded on an earlier run (or staged to install at quit): Update Now restarts straight away.
    private(set) var staged = false
    /// An information-only update (the appcast links a page, no download): Learn More opens it.
    private(set) var isInfoOnly = false
    private(set) var steps: [Step] = []
    private(set) var transfer = MacAppUpdateTransfer()
    private(set) var unpacked: Double?
    /// Seconds until the restart; nil when not counting (the app is in the background, or the person hasn't asked).
    private(set) var countdown: Int?
    /// macOS didn't let the app close for the install.
    private(set) var stuck = false
    private(set) var details: String?
    private(set) var wantsWebsite = false
    /// Where the update came from: the menu (shown at once) or the daily check (shown when nothing else is up).
    private(set) var userInitiated = false
    /// The ticking clock for the download line (1 s), so "About 6 s left" moves between Sparkle's data callbacks.
    private(set) var now = Date()

    // Sparkle's replies, each called at most once.
    @ObservationIgnored private var choose: ((Int) -> Void)?
    @ObservationIgnored private var cancelCheck: (() -> Void)?
    @ObservationIgnored private var cancelDownload: (() -> Void)?
    @ObservationIgnored private var install: ((Int) -> Void)?
    @ObservationIgnored private var acknowledge: (() -> Void)?
    @ObservationIgnored private var retryQuit: (() -> Void)?
    @ObservationIgnored private var infoURL: URL?
    @ObservationIgnored private var restartAsked = false
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var waitingToShow: Task<Void, Never>?
    @ObservationIgnored private var badge: String?
    @ObservationIgnored fileprivate weak var sheet: MacAppUpdateController?
    @ObservationIgnored private var record: MacAppUpdateRecord?

    static let website = URL(string: "https://gethermeshq.com/download")!

    /// The menu item's words: Show Update… while one is under way.
    var menuTitle: String {
        switch phase {
        case .found, .working, .ready, .restarting: "Show Update…"
        default: "Check for Updates…"
        }
    }

    var isRunning: Bool { phase == .working || phase == .ready || phase == .restarting }

    /// The download, unpack and install as one bar (download is most of the wait).
    var overall: Double {
        let download = transfer.fraction ?? 0
        if phase == .ready || phase == .restarting { return phase == .restarting ? 1 : 0.96 }
        if let unpacked { return 0.8 + 0.15 * unpacked }
        if steps.first(where: { $0.id == .unpack })?.state == .active { return 0.8 }
        return 0.8 * download
    }

    // MARK: Sparkle's calls (MacUpdateDriver)

    func checking(cancel: @escaping () -> Void) {
        reset()
        userInitiated = true
        cancelCheck = cancel
        set(.checking)
        show()
    }

    func found(item: NSObject, state: NSObject, reply: @escaping (Int) -> Void) {
        let wasChecking = phase == .checking
        cancelCheck = nil
        choose = reply
        let display = item.value(forKey: "displayVersionString") as? String
        let build = item.value(forKey: "versionString") as? String
        target = MacAppUpdateWords.version(display, build: build)
        targetBuild = build
        size = (item.value(forKey: "contentLength") as? NSNumber)?.uint64Value
        if size == 0 { size = nil }
        notes = MacAppUpdateNotes(item.value(forKey: "itemDescription") as? String)
        critical = (item.value(forKey: "criticalUpdate") as? Bool) ?? false
        infoURL = (item.value(forKey: "informationOnlyUpdate") as? Bool) == true ? item.value(forKey: "infoURL") as? URL : nil
        isInfoOnly = infoURL != nil
        let stage = (state.value(forKey: "stage") as? NSNumber)?.intValue ?? 0
        staged = stage > 0
        userInitiated = wasChecking || ((state.value(forKey: "userInitiated") as? Bool) ?? false)
        details = nil
        AppLog.note("mac", "updates: offering \(target ?? "?") (stage \(stage), \(userInitiated ? "asked" : "daily check"))")
        if restartAsked && staged {
            // Restart Now on the onQuit card: Sparkle offers the staged update again; it goes straight to the restart.
            updateNow()
            return
        }
        set(.found)
        if userInitiated { show() } else { showWhenFree() }
    }

    func upToDate(_ error: NSError, acknowledge: @escaping () -> Void) {
        cancelCheck = nil
        self.acknowledge = acknowledge
        // SPUNoUpdateFoundReasonKey and SPULatestAppcastItemFoundKey (SUErrors.h) are these strings in Sparkle 2.
        let reason = (error.userInfo["SUNoUpdateFoundReason"] as? NSNumber)?.intValue
        let latest = (error.userInfo["SULatestAppcastItemFound"] as? NSObject).map {
            MacAppUpdateWords.version($0.value(forKey: "displayVersionString") as? String, build: $0.value(forKey: "versionString") as? String)
        }
        set(.upToDate(MacAppUpdateWords.upToDate(reason: reason, current: current, latest: latest)))
        show()
    }

    func failed(_ error: NSError, acknowledge: @escaping () -> Void) {
        cancelCheck = nil
        cancelDownload = nil
        self.acknowledge = acknowledge
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        // A download's network failure arrives wrapped in Sparkle's; its words are about the network.
        let shown = (error.domain == "SUSparkleErrorDomain" && error.code == 2001 && underlying?.domain == NSURLErrorDomain) ? underlying! : error
        let words = MacAppUpdateWords.failure(domain: shown.domain, code: shown.code, description: AppLog.scrub(shown.localizedDescription))
        wantsWebsite = MacAppUpdateWords.wantsWebsite(domain: error.domain, code: error.code)
        details = "\(error.domain) \(error.code): \(AppLog.scrub(error.localizedDescription))"
            + (underlying.map { "\nUnder it: \($0.domain) \($0.code): \(AppLog.scrub($0.localizedDescription))" } ?? "")
            + "\nThis copy: \(current)" + (target.map { "\nUpdate: \($0)" } ?? "")
        if let index = steps.firstIndex(where: { $0.state == .active }) {
            steps[index].state = .failed
            if steps[index].id == .download {
                steps[index].detail = transfer.expected > 0
                    ? "Stopped at \(MacAppUpdateWords.size(transfer.received, unit: false, like: transfer.expected)) of \(MacAppUpdateWords.size(transfer.expected))"
                    : "Stopped"
            }
        }
        if MacAppUpdateWords.isCancel(domain: error.domain, code: error.code) { details = nil }
        set(.failed(headline: words.headline, line: words.line))
        MacAppUpdateRecord.clear()
        show()
    }

    func downloadStarted(cancel: @escaping () -> Void) {
        cancelDownload = cancel
        transfer = MacAppUpdateTransfer(expected: size ?? 0)
        transfer.begin(at: Date())
        unpacked = nil
        if phase != .working { set(.working) }
        step(.download, .active, detail: transfer.words(at: Date()))
        startTicker()
    }

    func downloadSize(_ bytes: UInt64) {
        if bytes > 0 { transfer.expected = bytes; size = bytes }
        step(.download, .active, detail: transfer.words(at: Date()))
    }

    func downloaded(_ bytes: UInt64) {
        // The bar follows every chunk; the line's numbers change once a second (the ticker), or they blur as they
        // roll many times a second (seen in the end-to-end test's frames).
        let first = transfer.received == 0
        transfer.add(bytes, at: Date())
        if first { step(.download, .active, detail: transfer.words(at: Date())) }
        updateBadge()
    }

    func unpacking() {
        cancelDownload = nil
        let took = steps.first(where: { $0.id == .download })?.started.map { Date().timeIntervalSince($0) }
        step(.download, .done, detail: [transfer.received > 0 ? MacAppUpdateWords.size(transfer.received) : nil, took.map(MacAppUpdateWords.took)]
            .compactMap { $0 }.joined(separator: " · "))
        step(.unpack, .active, detail: "Checking the signature")
        updateBadge()
    }

    func unpackProgress(_ fraction: Double) {
        unpacked = max(0, min(1, fraction))
        step(.unpack, .active, detail: "Unpacking · \(Int((unpacked ?? 0) * 100))%")
        updateBadge()
    }

    func readyToInstall(reply: @escaping (Int) -> Void) {
        install = reply
        cancelDownload = nil
        if steps.isEmpty { steps = Self.freshSteps() }
        for id in [MacAppUpdateStepID.download, .unpack] where steps.first(where: { $0.id == id })?.state != .done {
            step(id, .done, detail: id == .download ? (staged ? "Downloaded earlier" : nil) : nil)
        }
        if let started = steps.first(where: { $0.id == .unpack })?.started {
            step(.unpack, .done, detail: MacAppUpdateWords.took(Date().timeIntervalSince(started)))
        }
        if restartAsked {
            restartNow()
            return
        }
        set(.ready)
        updateBadge()
        // Update Now was the person's own click: count down from 5, Restart Now and Later beside it. A daily check's
        // update (never clicked) waits for the click.
        countdown = userInitiated || choseUpdate ? 5 : nil
        show()
        startTicker()
    }

    func installing(terminated: Bool, retry: @escaping () -> Void) {
        retryQuit = retry
        if phase != .restarting {
            saveRecord(onQuit: false)
            set(.restarting)
        }
        step(.install, .active, detail: terminated ? "Installing" : "Closing Hermes HQ")
        if !terminated, hasSheets { clearSheets { retry() } }
        // If the app is still here a while later, something (an unsaved window, a sheet) kept it open.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, self.phase == .restarting else { return }
            self.stuck = true
            self.step(.install, .failed, detail: "Hermes HQ didn’t close")
            AppLog.note("mac", "updates: the app didn't close for the install")
            self.show()
        }
    }

    func installedAndRelaunched(_ relaunched: Bool, acknowledge: @escaping () -> Void) {
        // Called when the app wasn't the one replaced (or it wasn't relaunched): the install finished while it ran.
        self.acknowledge = acknowledge
        step(.install, .done)
        step(.reopen, relaunched ? .done : .waiting)
        record = MacAppUpdateRecord.load()
        set(.updated)
        show()
    }

    func dismissed() {
        // Sparkle's session is over. A card the person should still read (an end) stays; anything mid-way closes.
        cancelCheck = nil
        cancelDownload = nil
        choose = nil
        install = nil
        stopTicker()
        clearBadge()
        switch phase {
        case .checking, .found, .working, .ready: close(); set(.idle)
        default: break
        }
    }

    func focus() { show() }

    // MARK: The person's choices

    @ObservationIgnored private var choseUpdate = false

    func updateNow() {
        if let infoURL {
            UIApplication.shared.open(infoURL)
            reply(choose, 2)
            choose = nil
            close()
            return
        }
        choseUpdate = true
        steps = Self.freshSteps()
        if staged {
            // Already downloaded: straight to the restart.
            restartAsked = true
            step(.download, .done, detail: "Downloaded earlier")
            step(.unpack, .done)
            set(.restarting)
            saveRecord(onQuit: false)
            step(.install, .active, detail: "Closing Hermes HQ")
            let reply = choose
            choose = nil
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.9))
                self.clearSheets { reply?(1) }
            }
            return
        }
        set(.working)
        step(.download, .active, detail: "Starting…")
        startTicker()
        reply(choose, 1)
        choose = nil
    }

    func later() {
        reply(choose, 2)
        choose = nil
        close()
    }

    func skip() {
        reply(choose, 0)
        choose = nil
        close()
    }

    func cancel() {
        switch phase {
        case .checking:
            let cancel = cancelCheck
            cancelCheck = nil
            cancel?()
            close()
            set(.idle)
        case .working:
            let cancel = cancelDownload
            cancelDownload = nil
            cancel?()
            AppLog.note("mac", "updates: download cancelled from the sheet")
            close()
            set(.idle)
        default:
            close()
        }
    }

    func restartNow() {
        countdown = nil
        restartAsked = true
        saveRecord(onQuit: false)
        set(.restarting)
        step(.install, .active, detail: "Closing Hermes HQ")
        DiagnosticLog.shared.flush()
        let reply = install
        install = nil
        // A beat on screen first, so the window says what's about to happen before it goes; then the sheets go, or
        // macOS refuses the installer's quit.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.9))
            self.clearSheets { reply?(1) }
        }
    }

    func restartLater() {
        countdown = nil
        saveRecord(onQuit: true)
        let reply = install
        install = nil
        reply?(2)
        clearBadge()
        set(.onQuit)
    }

    func pauseCountdown() { countdown = nil }

    func tryQuitAgain() {
        stuck = false
        step(.install, .active, detail: "Closing Hermes HQ")
        let retry = retryQuit
        clearSheets { retry?() }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, self.phase == .restarting else { return }
            self.stuck = true
            self.step(.install, .failed, detail: "Hermes HQ didn’t close")
        }
    }

    func tryAgain() {
        let ack = acknowledge
        acknowledge = nil
        close()
        set(.idle)
        ack?()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.4))
            MacUpdater.checkNow()
        }
    }

    func openWebsite() {
        UIApplication.shared.open(Self.website)
    }

    func copyDetails() {
        UIPasteboard.general.string = details
    }

    /// Done on an end card (or the sheet closed).
    func done() {
        close()
    }

    // MARK: After a relaunch

    /// At launch: the note the last copy left before it quit to install.
    func launched() {
        guard let saved = MacAppUpdateRecord.load() else { return }
        let outcome = saved.outcome(runningBuild: currentBuild, now: Date())
        AppLog.note("mac", "updates: launched after an update to \(saved.toDisplay): \(outcome)")
        if !saved.keepsWaiting(runningBuild: currentBuild, now: Date()) { MacAppUpdateRecord.clear() }
        switch outcome {
        case .updated:
            record = saved
            target = saved.toDisplay
            notes = MacAppUpdateNotes(saved.notes)
            steps = Self.freshSteps().map { var step = $0; step.state = .done; return step }
            // How long it was gone: from Restart Now to this copy running.
            if let index = steps.firstIndex(where: { $0.id == .reopen }) {
                steps[index].detail = "Back in \(MacAppUpdateWords.took(Date().timeIntervalSince(saved.at)))"
            }
            set(.updated)
        case .didntFinish:
            record = saved
            target = saved.toDisplay
            set(.didntFinish)
        case .nothing:
            return
        }
        userInitiated = true
        // As soon as the window is up: the card the last copy showed comes straight back (owner 2026-11-10: "we can't
        // have that break in between").
        showWhenFree()
    }

    var updatedFrom: String? { record?.fromDisplay }

    // MARK: The sheet

    func show() {
        waitingToShow?.cancel()
        if let sheet, sheet.view.window != nil { sheet.view.window?.makeKey(); return }
        guard let host = FailureAlert.topmost(MainTabController.current) else { showWhenFree(); return }
        let controller = MacAppUpdateController(update: self)
        sheet = controller
        host.present(controller, animated: true)
    }

    /// The daily check's find, or the card after a relaunch: once the app is in front with no other sheet up.
    func showWhenFree(after delay: TimeInterval = 0) {
        waitingToShow?.cancel()
        waitingToShow = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            while !Task.isCancelled {
                guard let self else { return }
                if let tabs = MainTabController.current, tabs.viewIfLoaded?.window != nil,
                   UIApplication.shared.applicationState == .active,
                   (tabs.view.window?.rootViewController?.presentedViewController == nil || self.userInitiated) {
                    self.show()
                    return
                }
                // Quick at launch, so the reopened card is up with the window.
                try? await Task.sleep(for: .seconds(0.3))
            }
        }
    }

    func close() {
        waitingToShow?.cancel()
        sheet?.dismiss(animated: true)
    }

    fileprivate func sheetClosed() {
        sheet = nil
        switch phase {
        case .found:
            // Closed without a choice: as Later.
            reply(choose, 2)
            choose = nil
            set(.idle)
        case .ready:
            // Closed during the countdown: it waits for Show Update… (or installs at quit, Sparkle's own rule).
            countdown = nil
        case .upToDate, .failed, .updated, .didntFinish, .onQuit:
            let ack = acknowledge
            acknowledge = nil
            set(.idle)
            ack?()
        default:
            break
        }
    }

    // MARK: Inner workings

    private func reset() {
        target = nil; targetBuild = nil; size = nil; notes = .empty; critical = false; staged = false; isInfoOnly = false; infoURL = nil
        steps = []; transfer = MacAppUpdateTransfer(); unpacked = nil; countdown = nil; stuck = false
        details = nil; wantsWebsite = false; restartAsked = false; choseUpdate = false; record = nil
        acknowledge = nil; install = nil; retryQuit = nil; choose = nil; cancelDownload = nil
    }

    private func set(_ new: Phase) {
        let wasIdle = menuTitle
        phase = new
        if menuTitle != wasIdle { UIMenuSystem.main.setNeedsRebuild() }
        if !isRunning {
            stopTicker()
            clearBadge()
        }
    }

    private static func freshSteps() -> [Step] { MacAppUpdateStepID.allCases.map { Step(id: $0) } }

    private func step(_ id: MacAppUpdateStepID, _ state: MacAppUpdateStepState, detail: String? = nil) {
        if steps.isEmpty { steps = Self.freshSteps() }
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        var step = steps[index]
        if state == .active, step.started == nil { step.started = Date() }
        if state == .done, step.finished == nil { step.finished = Date() }
        step.state = state
        step.detail = detail
        if step != steps[index] { steps[index] = step }
    }

    private func reply(_ choose: ((Int) -> Void)?, _ choice: Int) {
        guard let choose else { return }
        AppLog.note("mac", "updates: \([0: "skip", 1: "install", 2: "later"][choice] ?? "\(choice)") for \(target ?? "?")")
        choose(choice)
    }

    private func saveRecord(onQuit: Bool) {
        let saved = MacAppUpdateRecord(fromBuild: currentBuild, fromDisplay: current, toBuild: targetBuild ?? "?",
                                       toDisplay: target ?? "?", notes: notesText, at: Date(), onQuit: onQuit)
        saved.save()
        record = saved
    }

    /// The notes back as text, for the record (the new copy shows them).
    private var notesText: String? {
        let lines = (notes.intro.map { [$0] } ?? []) + notes.items.map { "- " + $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// One tick a second while it works: the time-left line, and the countdown.
    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.now = Date()
                if self.phase == .working, self.steps.first(where: { $0.id == .download })?.state == .active, self.transfer.received > 0 {
                    self.step(.download, .active, detail: self.transfer.words(at: self.now))
                }
                if self.phase == .ready, let left = self.countdown {
                    // Only while the window is in front and the sheet is up: never a restart the person can't see.
                    guard UIApplication.shared.applicationState == .active, self.sheet?.view.window != nil else { continue }
                    if left <= 1 { self.countdown = nil; self.restartNow() } else { self.countdown = left - 1 }
                }
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    /// [mac-update] The end-to-end test of 2026-11-10: with the update sheet up, Sparkle's installer asked the app to
    /// quit and got "User canceled" (AppKit won't quit with a sheet on a window; Sparkle's own window was a window, not
    /// a sheet), so the app stayed open on "Restarting…". Every sheet on the main window goes first.
    private var hasSheets: Bool {
        MainTabController.current?.viewIfLoaded?.window?.rootViewController?.presentedViewController != nil
    }

    private func clearSheets(then action: @escaping () -> Void) {
        // The sockets' background graces would hold the quitting app for 20 s with its window already gone.
        BackgroundTaskHolder.endAllForQuit()
        guard let root = MainTabController.current?.viewIfLoaded?.window?.rootViewController, root.presentedViewController != nil else {
            action()
            return
        }
        root.dismiss(animated: false) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.3))
                action()
            }
        }
    }

    // MARK: The Dock

    private func updateBadge() {
        let words: String? = switch phase {
        case .working: "\(Int((overall * 100).rounded(.down)))%"
        case .ready, .restarting: "↻"
        default: nil
        }
        guard words != badge else { return }
        badge = words
        Self.dockBadge(words)
    }

    private func clearBadge() {
        guard badge != nil else { return }
        badge = nil
        Self.dockBadge(nil)
    }

    /// NSApp.dockTile.badgeLabel, reached by name as MacDockIcon reaches NSApp.
    private static func dockBadge(_ words: String?) {
        guard let app = (NSClassFromString("NSApplication") as? NSObject.Type)?.value(forKey: "sharedApplication") as? NSObject,
              let tile = app.value(forKey: "dockTile") as? NSObject else { return }
        tile.setValue(words, forKey: "badgeLabel")
    }

    // MARK: Words

    var headline: String {
        switch phase {
        case .idle, .checking: "Checking for Updates…"
        case .found: critical ? "Important Update" : "Update Available"
        case .working: "Updating Hermes HQ"
        case .ready: "Ready to Restart"
        case .restarting: stuck ? "Hermes HQ Didn’t Close" : "Restarting…"
        case .onQuit: "Updates When You Quit"
        case .upToDate: "Hermes HQ Is Up to Date"
        case .failed(let headline, _): headline
        case .updated: "Updated to \(target ?? "the New Version")"
        case .didntFinish: "The Update Didn’t Finish"
        }
    }

    var line: String? {
        switch phase {
        case .idle, .checking: "Looking at gethermeshq.com"
        case .found:
            isInfoOnly ? "This update is on the website. Learn More opens it."
                : staged ? "It’s downloaded. Hermes HQ restarts to finish, in about 10 seconds."
                : [size.map { MacAppUpdateWords.size($0) }, "Hermes HQ restarts by itself to finish"].compactMap { $0 }.joined(separator: " · ")
        case .working: "Keep working meanwhile. You’ll get a few seconds’ warning before Hermes HQ restarts."
        case .ready: "Hermes HQ closes and reopens by itself. Chats and drafts stay as they are."
        case .restarting:
            stuck ? "Something kept it open. Try again, or quit Hermes HQ yourself: the update installs as it closes."
                : "Hermes HQ closes now and opens again by itself in a few seconds."
        case .onQuit: "\(target ?? "The update") installs the next time you quit Hermes HQ."
        case .upToDate(let line): line
        case .failed(_, let line): line
        case .updated: updatedFrom.map { "From \($0). Everything’s where you left it." } ?? "Everything’s where you left it."
        case .didntFinish: "Hermes HQ is still on \(current). Try again, or download the newest copy from gethermeshq.com."
        }
    }

    /// "1.0.2 (919) → 1.0.2 (925)".
    var versions: String? {
        switch phase {
        case .found, .working, .ready, .restarting, .onQuit:
            target.map { "\(current) → \($0)" }
        default: nil
        }
    }

    var showsSteps: Bool {
        switch phase {
        case .working, .ready, .restarting: true
        // The copy that reopens shows the same card with every step ticked: one pop-up across the restart.
        case .updated: !steps.isEmpty
        case .failed: !steps.isEmpty
        default: false
        }
    }

    var showsNotes: Bool {
        (phase == .found || phase == .updated) && (notes.intro != nil || !notes.items.isEmpty)
    }

    var symbol: (name: String, color: Color)? {
        switch phase {
        case .upToDate, .updated: ("checkmark.circle.fill", .green)
        case .failed, .didntFinish: ("exclamationmark.triangle.fill", .orange)
        case .restarting where stuck: ("exclamationmark.triangle.fill", .orange)
        default: nil
        }
    }

    static func title(_ id: MacAppUpdateStepID) -> String {
        switch id {
        case .download: "Download"
        case .unpack: "Check and Unpack"
        case .install: "Install"
        case .reopen: "Reopen Hermes HQ"
        }
    }

    static func plan(_ id: MacAppUpdateStepID) -> String? {
        switch id {
        case .download: nil
        case .unpack: "Its signature is checked first"
        case .install: "Hermes HQ closes for a moment"
        case .reopen: "It opens again by itself"
        }
    }

    // MARK: Pictures (DEBUG `-HQDebugMacUpdateShot <state>`)

    #if DEBUG
    var debugSheetWindow: UIWindow? { sheet?.viewIfLoaded?.window }

    func demo(_ state: String) {
        reset()
        let now = Date()
        target = "1.0.2 (925)"
        targetBuild = "925"
        size = 52_795_660
        notes = MacAppUpdateNotes("What's new since the last Mac update: - The Mac app updates itself in its own window: you see it download, check, install and reopen. - Math in replies is drawn as real math: fractions, roots, sums, aligned steps, cases and matrices. - Command-Delete is now Delete Chat, and it asks first. Archive Chat moved to Control-Command-A. - Dragging the sidebar's edge to make it wider or narrower works again. - The gateway switcher at the top of the sidebar is a proper row.")
        userInitiated = true
        func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
        func set(_ id: MacAppUpdateStepID, _ state: MacAppUpdateStepState, _ detail: String? = nil, from: TimeInterval? = nil, to: TimeInterval? = nil) {
            guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
            steps[index].state = state
            steps[index].detail = detail
            steps[index].started = from.map(at)
            steps[index].finished = to.map(at)
        }
        switch state {
        case "checking": phase = .checking
        case "found": phase = .found
        case "downloading":
            phase = .working
            steps = Self.freshSteps()
            transfer = MacAppUpdateTransfer(expected: 52_795_660)
            transfer.begin(at: at(4))
            for second in 1...4 { transfer.add(5_300_000, at: at(4 - Double(second))) }
            set(.download, .active, transfer.words(at: now), from: 4)
        case "unpacking":
            phase = .working
            steps = Self.freshSteps()
            transfer = MacAppUpdateTransfer(expected: 52_795_660)
            transfer.add(52_795_660, at: now)
            unpacked = 0.62
            set(.download, .done, "52.8 MB · 9 s", from: 11, to: 2)
            set(.unpack, .active, "Unpacking · 62%", from: 2)
        case "ready", "restarting", "stuck":
            phase = state == "ready" ? .ready : .restarting
            steps = Self.freshSteps()
            set(.download, .done, "52.8 MB · 9 s", from: 14, to: 5)
            set(.unpack, .done, "3 s", from: 5, to: 2)
            if state == "ready" { countdown = 4 } else {
                set(.install, state == "stuck" ? .failed : .active, state == "stuck" ? "Hermes HQ didn’t close" : "Closing Hermes HQ", from: 1)
                stuck = state == "stuck"
            }
        case "onquit": phase = .onQuit
        case "uptodate": phase = .upToDate(MacAppUpdateWords.upToDate(reason: 1, current: current, latest: current))
        case "failed":
            let words = MacAppUpdateWords.failure(domain: "SUSparkleErrorDomain", code: 2001, description: "")
            steps = Self.freshSteps()
            set(.download, .failed, "Stopped at 31.0 of 52.8 MB", from: 8)
            details = "SUSparkleErrorDomain 2001: A network error occurred while downloading the update."
            phase = .failed(headline: words.headline, line: words.line)
        case "failed-signature":
            let words = MacAppUpdateWords.failure(domain: "SUSparkleErrorDomain", code: 3001, description: "")
            wantsWebsite = true
            details = "SUSparkleErrorDomain 3001: The update is improperly signed."
            phase = .failed(headline: words.headline, line: words.line)
        case "updated":
            record = MacAppUpdateRecord(fromBuild: "919", fromDisplay: "1.0.2 (919)", toBuild: "925", toDisplay: "1.0.2 (925)", notes: nil, at: now, onQuit: false)
            phase = .updated
        case "didnt":
            phase = .didntFinish
        default: return
        }
        UIMenuSystem.main.setNeedsRebuild()
        if phase == .working { updateBadge() }
        show()
    }
    #endif
}

// MARK: - The sheet

/// A fitted Mac sheet: as tall as its content (the update card is short; the window-tall sheet of Update Hermes would
/// be mostly empty here), 540 wide, resizing with each step.
final class MacAppUpdateController: UIHostingController<HQScaledRoot<MacAppUpdateView>> {
    private let update: MacAppUpdate

    init(update: MacAppUpdate) {
        self.update = update
        super.init(rootView: HQScaledRoot(MacAppUpdateView(update: update)))
        modalPresentationStyle = .formSheet
        sizingOptions = [.preferredContentSize]
        isModalInPresentation = false
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if presentingViewController == nil || isBeingDismissed { update.sheetClosed() }
    }

    // Escape: the card's own close (Later, Hide, Done), never mid-restart.
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escape))]
    }

    @objc private func escape() {
        switch update.phase {
        case .found: update.later()
        case .checking: update.cancel()
        case .restarting: break
        case .ready: update.pauseCountdown(); update.done()
        default: update.done()
        }
    }
}

struct MacAppUpdateView: View {
    @Bindable var update: MacAppUpdate

    var body: some View {
        let _ = Theme.touch()
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 16)
            if update.showsSteps || update.showsNotes {
                VStack(alignment: .leading, spacing: 14) {
                    if update.showsSteps { steps }
                    if update.showsNotes { whatsNew }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
                .transition(.hqMotion(.opacity))
            }
            Divider().overlay(Color.hqStroke)
            buttons
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.hqGroupedPage.ignoresSafeArea())
        .animation(HQMotion.swiftUI(.smooth(duration: 0.3)), value: update.phase)
        .animation(HQMotion.swiftUI(.smooth(duration: 0.3)), value: update.steps)
        .accessibilityIdentifier("mac-update")
    }

    // MARK: Header: the icon, what's happening, the versions

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack(alignment: .bottomTrailing) {
                WornAppIcon(side: 64)
                if let symbol = update.symbol {
                    Image(systemName: symbol.name)
                        .font(.system(size: 22, weight: .semibold))   // a11y-font-ok: a badge on the fixed 64-pt app icon
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, symbol.color)
                        .background(Circle().fill(Color.hqGroupedPage).padding(-2))
                        .offset(x: 6, y: 6)
                        .transition(.hqMotion(.scale.combined(with: .opacity)))
                } else if update.phase == .checking || update.phase == .restarting {
                    ProgressView()
                        .controlSize(.small)
                        .padding(4)
                        .background(Circle().fill(Color.hqGroupedPage))
                        .offset(x: 6, y: 6)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(update.headline)
                    .font(Font.hq(.title3).weight(.bold))
                    .foregroundStyle(Color.hqLabel)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("mac-update.headline")
                if let versions = update.versions {
                    Text(versions)
                        .font(Font.hq(.subheadline).weight(.medium).monospacedDigit())
                        .foregroundStyle(Color.hqLabel)
                        .accessibilityLabel(versions.replacingOccurrences(of: "→", with: "to"))
                        .accessibilityIdentifier("mac-update.versions")
                }
                if let line = update.line {
                    Text(line)
                        .font(Font.hq(.subheadline))
                        .foregroundStyle(Color.hqLabel2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("mac-update.line")
                }
                if update.phase == .working || update.phase == .ready || update.phase == .restarting {
                    ProgressView(value: update.overall)
                        .progressViewStyle(.linear)
                        .tint(Color.hqTint)
                        .padding(.top, 6)
                        .accessibilityLabel("Update progress")
                        .accessibilityValue("\(Int(update.overall * 100)) percent")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentTransition(.opacity)
    }

    // MARK: The steps

    private var steps: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(update.steps.enumerated()), id: \.element.id) { index, step in
                if index > 0 { Divider().overlay(Color.hqStroke).padding(.leading, 44) }
                MacAppUpdateStepRow(step: step)
            }
        }
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.hqGroupedCard))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.hqStroke, lineWidth: 0.5))
        .accessibilityIdentifier("mac-update.steps")
    }

    // MARK: What's New

    private var whatsNew: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(update.phase == .updated ? "What’s New in This Version" : "What’s New")
                .font(Font.hq(.footnote).weight(.semibold))
                .foregroundStyle(Color.hqLabel2)
            let list = VStack(alignment: .leading, spacing: 7) {
                if let intro = update.notes.intro {
                    Text(intro).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(update.notes.items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel3).accessibilityHidden(true)
                        Text(item).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                // A long list scrolls in a fixed box; a short one is drawn whole.
                if update.notes.items.count > 6 {
                    ScrollView { list }.frame(height: 260)
                } else {
                    list
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.hqGroupedCard))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.hqStroke, lineWidth: 0.5))
        }
        .accessibilityIdentifier("mac-update.whats-new")
    }

    // MARK: Buttons: the Mac's order, the default action last on the right

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 10) {
            switch update.phase {
            case .idle, .checking:
                Spacer()
                push("Cancel", id: "mac-update.cancel") { update.cancel() }
            case .found:
                if !update.critical && !update.staged {
                    push("Skip This Version", id: "mac-update.skip") { update.skip() }
                }
                Spacer()
                push("Later", id: "mac-update.later") { update.later() }
                push(update.staged ? "Restart to Update" : update.isInfoOnly ? "Learn More" : "Update Now", id: "mac-update.go", prominent: true) {
                    update.updateNow()
                }
            case .working:
                push("Cancel", id: "mac-update.cancel") { update.cancel() }
                Spacer()
                push("Hide", id: "mac-update.hide", prominent: true) { update.done() }
            case .ready:
                countdownWords
                Spacer()
                push("Later", id: "mac-update.later") { update.restartLater() }
                push("Restart Now", id: "mac-update.restart", prominent: true) { update.restartNow() }
            case .restarting:
                Spacer()
                if update.stuck {
                    push("Try Again", id: "mac-update.retry-quit", prominent: true) { update.tryQuitAgain() }
                } else {
                    Text("Back in a few seconds")
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqLabel2)
                        .padding(.vertical, 4)
                }
            case .failed:
                if update.details != nil {
                    push("Copy Details", id: "mac-update.copy") { update.copyDetails() }
                }
                Spacer()
                if update.wantsWebsite {
                    push("Open Website", id: "mac-update.website") { update.openWebsite() }
                }
                push("Done", id: "mac-update.done") { update.done() }
                push("Try Again", id: "mac-update.retry", prominent: true) { update.tryAgain() }
            case .didntFinish:
                push("Open Website", id: "mac-update.website") { update.openWebsite() }
                Spacer()
                push("Done", id: "mac-update.done") { update.done() }
                push("Try Again", id: "mac-update.retry", prominent: true) { update.tryAgain() }
            case .upToDate, .updated, .onQuit:
                Spacer()
                push("Done", id: "mac-update.done", prominent: true) { update.done() }
            }
        }
        .controlSize(.large)
    }

    private var countdownWords: some View {
        Group {
            if let left = update.countdown {
                Text("Restarting in \(left) s")
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .accessibilityIdentifier("mac-update.countdown")
            } else {
                Text("Restart when you’re ready")
            }
        }
        .font(Font.hq(.footnote))
        .foregroundStyle(Color.hqLabel2)
        .animation(HQMotion.swiftUI(.smooth(duration: 0.25)), value: update.countdown)
    }

    private func push(_ title: String, id: String, prominent: Bool = false, perform: @escaping () -> Void) -> some View {
        Group {
            if prominent {
                Button(action: perform) { Text(title).frame(minWidth: 72) }
                    .hqProminentButtonStyle()
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(action: perform) { Text(title).frame(minWidth: 60) }
                    .hqBorderedButtonStyle()
            }
        }
        .accessibilityIdentifier(id)
    }
}

private struct MacAppUpdateStepRow: View {
    var step: MacAppUpdate.Step

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                switch step.state {
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.hqGreen)
                        .transition(.hqMotion(.scale.combined(with: .opacity)))
                case .active:
                    ProgressView().controlSize(.small)
                case .waiting:
                    Image(systemName: "circle").foregroundStyle(Color.hqLabel3)
                case .failed:
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.hqRed)
                }
            }
            .font(Font.hq(.body))
            .frame(width: 20, height: 20)
            Text(MacAppUpdate.title(step.id))
                .font(Font.hq(.body).weight(step.state == .active ? .semibold : .regular))
                .foregroundStyle(step.state == .waiting ? Color.hqLabel2 : Color.hqLabel)
            Spacer(minLength: 12)
            if let detail = step.detail ?? (step.state == .waiting ? MacAppUpdate.plan(step.id) : nil) {
                Text(detail)
                    .font(Font.hq(.footnote).monospacedDigit())
                    .foregroundStyle(step.state == .failed ? Color.hqRed : Color.hqLabel2)
                    .lineLimit(1)
                    .accessibilityIdentifier("mac-update.detail.\(step.id.rawValue)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .animation(HQMotion.swiftUI(.smooth(duration: 0.3)), value: step.state)
        .accessibilityElement(children: .combine)
        .accessibilityValue(step.state == .done ? "Done" : step.state == .active ? "In progress" : step.state == .failed ? "Failed" : "Waiting")
        .accessibilityIdentifier("mac-update.step.\(step.id.rawValue)")
    }
}
#endif
