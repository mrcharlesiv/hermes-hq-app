// [settings] m9 "settings" stream (docs/spec/3x-settings.md): the haptics gate and switch (§1), Intro Splash (§7),
// power saver's leftovers (§3) and the desktop-only controls that must stay absent (§13).

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func swiftSources(_ folders: [String]) -> [(file: String, lines: [String])] {
    var out: [(String, [String])] = []
    for folder in folders {
        guard let walker = FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil) else { continue }
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            out.append((url.path.replacingOccurrences(of: root.path + "/", with: ""), text.components(separatedBy: "\n")))
        }
    }
    return out
}

/// These suites change process-wide settings (the Haptics switch, the power override): one at a time.
@Suite(.serialized) @MainActor struct M9SettingsTests {

    // MARK: §1 the gate

    /// No feedback generator and no `.sensoryFeedback(` outside the gate: this is what keeps the switch honest.
    @Test func noHapticBypassesTheGate() {
        let allowed: Set<String> = ["App/Kit/Haptics.swift", "ShareExtension/ShareHaptics.swift"]
        let sources = swiftSources(["App", "HermesKit", "Shared", "ShareKit", "ShareExtension", "NotificationService"])
        #expect(sources.count > 100, "the source tree was found")
        var found: [String] = []
        for (file, lines) in sources where !allowed.contains(file) {
            for (index, line) in lines.enumerated() {
                let code = line.components(separatedBy: "//").first ?? line
                if code.contains("FeedbackGenerator") || code.contains(".sensoryFeedback(") || code.contains("CHHapticEngine") {
                    found.append("\(file):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(found.isEmpty, Comment(rawValue: "Use Haptics.play(…) so the Haptics switch can mute it:\n" + found.joined(separator: "\n")))
    }

    /// The Share extension's own gate reads the same key the app writes for it.
    @Test func theShareExtensionReadsTheAppsKey() throws {
        let text = try String(contentsOf: root.appendingPathComponent("ShareExtension/ShareHaptics.swift"), encoding: .utf8)
        #expect(text.contains("\"\(Haptics.sharedKey)\""))
        #expect(text.contains("guard isOn else { return }"))
    }

    @Test func theSwitchMutesEveryCue() {
        let before = UserDefaults.standard.object(forKey: Haptics.key)
        let oldSink = Haptics.sink
        defer {
            Haptics.sink = oldSink
            if let before { UserDefaults.standard.set(before, forKey: Haptics.key) } else { UserDefaults.standard.removeObject(forKey: Haptics.key) }
        }
        var heard: [Haptics.Kind] = []
        Haptics.sink = { heard.append($0) }

        UserDefaults.standard.removeObject(forKey: Haptics.key)
        #expect(Haptics.isOn, "on until someone turns it off")
        Haptics.play(.selection)
        #expect(heard == [.selection])

        Haptics.isOn = false
        #expect(UserDefaults.standard.object(forKey: Haptics.key) as? Bool == false)
        for kind in Haptics.Kind.allCases { Haptics.play(kind); Haptics.prepare(kind) }
        PagesHaptics.selection(); PagesHaptics.success(); PagesHaptics.error()
        #expect(heard == [.selection], "nothing while off")

        Haptics.isOn = true
        for kind in Haptics.Kind.allCases { Haptics.play(kind) }
        #expect(heard == [.selection] + Haptics.Kind.allCases)
    }

    /// Stress plan L10: 200 cues in a burst with the switch off never reach the system.
    @Test func offMakesNoGenerators() {
        let before = UserDefaults.standard.object(forKey: Haptics.key)
        let oldSink = Haptics.sink
        defer {
            Haptics.sink = oldSink
            if let before { UserDefaults.standard.set(before, forKey: Haptics.key) } else { UserDefaults.standard.removeObject(forKey: Haptics.key) }
        }
        Haptics.sink = nil
        Haptics.isOn = false
        let made = Haptics.generatorsMade
        for _ in 0..<200 { Haptics.play(.selection) }
        #expect(Haptics.generatorsMade == made)
    }

    /// A value that is not a Bool (a corrupted or foreign default) reads as the default, on.
    @Test func aCorruptedSwitchReadsAsOn() {
        let before = UserDefaults.standard.object(forKey: Haptics.key)
        defer { if let before { UserDefaults.standard.set(before, forKey: Haptics.key) } else { UserDefaults.standard.removeObject(forKey: Haptics.key) } }
        UserDefaults.standard.set("abc", forKey: Haptics.key)
        #expect(Haptics.isOn)
    }

    @Test func hapticsAndIntroSplashAreSearchable() {
        func find(_ words: String) -> [String] { SettingsSearch.results(words, in: SettingsSearch.appRows).map(\.label) }
        #expect(find("haptics").first == "Haptics", "the section name finds its rows too, Haptics first")
        #expect(find("vibration").contains("Haptics"))
        #expect(find("taptic").contains("Haptics"))
        #expect(find("intro splash") == ["Greeting on Empty Chats"], "the old name still finds it")
        #expect(find("greeting").contains("Greeting on Empty Chats"))
    }

    /// UX study 2026-10-21 #113, #108: the root's own switches and Notifications' are found, and a root switch's result
    /// names its row (the list scrolls to it) rather than the section.
    @Test func rootSwitchesAndNotificationSwitchesAreSearchable() {
        func find(_ words: String) -> [SettingsSearchEntry] { SettingsSearch.results(words, in: SettingsSearch.appRows) }
        #expect(find("timestamps").first?.target == .root("row:fewer-timestamps"))
        #expect(find("kanban").first?.target == .root(SettingsSearch.kanbanTabTarget))
        #expect(find("previews").map(\.label).contains("Show Previews"))
        #expect(find("banners").map(\.label).contains("Bot Activity Banners"))
        #expect(find("enable notifications").first?.target == .root("notifications"))
        #expect(find("haptics").first?.target == .root("row:haptics"))
    }

    /// Tester 2026-11-10: New Chat Asks for a Project is found and synced; the New Chat sheet's memory.
    @Test func newChatAsksForAProject() {
        let found = SettingsSearch.results("new chat project", in: SettingsSearch.appRows)
        #expect(found.contains { $0.target == .root("row:new-chat-asks-project") })
        #expect(SyncedSettingKeys.settings.contains(NewChatProjectChoice.key))
        // "Last used": only the row the bot started in last; nothing stored, no tag.
        #expect(!NewChatLast.marks(stored: nil, row: nil))
        #expect(NewChatLast.marks(stored: NewChatLast.none, row: nil), "No Project was last")
        #expect(!NewChatLast.marks(stored: NewChatLast.none, row: "/site"))
        #expect(NewChatLast.marks(stored: "/site", row: "/site"))
        #expect(!NewChatLast.marks(stored: "/site", row: nil) && !NewChatLast.marks(stored: "/site", row: "/other"))
        // The lit bot: the picked pill's, else the one used last while still offered, else Hermes, else the first.
        #expect(NewChatLast.opensOn(picked: "research", last: "deploys", among: ["default", "research", "deploys"]) == "research")
        #expect(NewChatLast.opensOn(picked: nil, last: "deploys", among: ["default", "research", "deploys"]) == "deploys")
        #expect(NewChatLast.opensOn(picked: nil, last: "gone", among: ["default", "research"]) == "default")
        #expect(NewChatLast.opensOn(picked: nil, last: nil, among: ["research", "deploys"]) == "research")
        // The sheet lists every project while there are six or fewer; with more, the bot's recent ones first, five in
        // all, and All Projects holds the rest.
        let few = ["a", "b", "c", "d", "e", "f"]
        #expect(NewChatLast.shown(all: few, recent: ["e"]).keys == few && !NewChatLast.shown(all: few, recent: ["e"]).more)
        let many = ["a", "b", "c", "d", "e", "f", "g"]
        #expect(NewChatLast.shown(all: many, recent: ["g", "home", "c", "g"]).keys == ["g", "c", "a", "b", "d"], "recent first, once, known only")
        #expect(NewChatLast.shown(all: many, recent: []).more)
        #expect(NewChatLast.shown(all: [], recent: ["x"]).keys.isEmpty)
    }

    /// [kanban-tab-one] One Kanban Tab control, on Appearance › Tabs (owner 2026-11-03: one home per page): search finds
    /// it by its name, by "kanban" and by "artifacts tab", and opens the Tabs page at it. "Tabs" still finds Tabs first.
    @Test func kanbanTabIsFoundOnTheTabsPage() {
        func find(_ words: String) -> [SettingsSearchEntry] { SettingsSearch.results(words, in: SettingsSearch.appRows) }
        for words in ["kanban tab", "kanban", "artifacts tab", "Kanban Tab", "kanban or artifacts"] {
            let first = find(words).first
            #expect(first?.label == "Kanban Tab", "\(words)")
            #expect(first?.target == .root(SettingsSearch.kanbanTabTarget), "\(words)")
            #expect(first?.context == "Tabs", "\(words): it says which page it is on")
        }
        #expect(SettingsSearch.kanbanTabTarget == "tab-order:kanban", "not a root row: it isn't on the root any more")
        #expect(!SettingsSearch.kanbanTabTarget.hasPrefix("row:"))
        #expect(find("tabs").first?.label == "Tabs")
        #expect(SettingsSearch.appRows.filter { $0.label == "Kanban Tab" }.count == 1, "one control, one entry")
    }

    /// [thinking-drive] The thinking bar's drive is found by its own names and by what it's for.
    @Test func thinkingBarIsSearchable() {
        func find(_ words: String) -> [SettingsSearchEntry] { SettingsSearch.results(words, in: SettingsSearch.appRows) }
        #expect(find("thinking bar").first?.target == .root("row:thinking-drive"))
        #expect(find("hyperspace").map(\.label) == ["Thinking Bar"])
        #expect(find("afterburner").map(\.label) == ["Thinking Bar"])
        #expect(find("haptics").first?.label == "Haptics", "Haptics still leads its own section")
    }

    // MARK: §7 Intro Splash

    @Test func introSplashOffLeavesAnEmptyChatBlankButNotSilent() {
        let view = ChatPlaceholderView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        view.mode = .empty(name: "Scout", head: nil, profile: "scout")
        view.layoutIfNeeded()
        #expect(!view.isAccessibilityElement)
        #expect(view.subviews.contains { !$0.isHidden && $0 is UIStackView }, "the intro is drawn")

        view.mode = .blank
        view.layoutIfNeeded()
        let allHidden = view.subviews.allSatisfy { $0.isHidden }
        #expect(allHidden, "nothing is drawn")
        #expect(view.isAccessibilityElement)
        #expect(view.accessibilityLabel == "No messages yet")

        // The other placeholders are not the intro: they still show.
        view.mode = .failed("The gateway did not answer.")
        #expect(view.subviews.contains { !$0.isHidden && $0 is UIStackView })
        #expect(!view.isAccessibilityElement)
        #expect(view.accessibilityLabel == nil)
    }

    @Test func introSplashIsOnUntilTurnedOffAndTellsOpenChats() {
        let before = UserDefaults.standard.object(forKey: IntroSplash.key)
        defer { if let before { UserDefaults.standard.set(before, forKey: IntroSplash.key) } else { UserDefaults.standard.removeObject(forKey: IntroSplash.key) } }
        UserDefaults.standard.removeObject(forKey: IntroSplash.key)
        #expect(IntroSplash.isOn)
        var told = 0
        let token = NotificationCenter.default.addObserver(forName: IntroSplash.didChange, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { told += 1 }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        IntroSplash.isOn = false
        IntroSplash.isOn = false
        #expect(!IntroSplash.isOn)
        #expect(told == 1, "once per change")
        IntroSplash.isOn = true
        #expect(told == 2)
        UserDefaults.standard.set(7, forKey: IntroSplash.key)
        #expect(IntroSplash.isOn, "a value that is not a Bool reads as the default")
    }

    // MARK: §3 power saver

    @Test func savingIsLowPowerOrAHotPhone() {
        #expect(!PowerState.saving(lowPower: false, thermal: .nominal))
        #expect(!PowerState.saving(lowPower: false, thermal: .fair))
        #expect(PowerState.saving(lowPower: false, thermal: .serious))
        #expect(PowerState.saving(lowPower: false, thermal: .critical))
        #expect(PowerState.saving(lowPower: true, thermal: .nominal))
    }

    @Test func savingPowerStillsHeadsAndDecorationAndLetsThemMoveAgain() {
        let power = PowerState.shared
        let before = power.override
        defer { power.override = before }

        power.override = false
        #expect(HQMotion.decorativeStill == HQMotion.reduced)
        #expect(HeadMotionSettings.shared.isStill == HQMotion.reduced)
        #expect(!ScreenPower.slow)

        power.override = true
        #expect(HQMotion.decorativeStill)
        #expect(HeadMotionSettings.shared.isStill, "heads keep still while saving power, heat included")
        #expect(ScreenPower.slow, "the Screen viewer reads the same state")

        power.override = false
        #expect(HeadMotionSettings.shared.isStill == HQMotion.reduced, "and move again when saving ends")
    }

    @Test func theSkeletonShimmerStopsWhileSavingAndStartsAgain() throws {
        try #require(!HQMotion.reduced, "Reduce Motion is off in the test simulator")
        let power = PowerState.shared
        let before = power.override
        defer { power.override = before }
        power.override = false

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let view = ChatPlaceholderView(frame: window.bounds)
        window.addSubview(view)
        window.isHidden = false
        defer { window.isHidden = true }
        view.mode = .loading
        view.layoutIfNeeded()
        #expect(view.isShimmering)

        power.override = true
        #expect(!view.isShimmering, "saving power stops it without reopening the chat")
        view.setNeedsLayout(); view.layoutIfNeeded()
        #expect(!view.isShimmering, "and a layout pass does not bring it back")

        power.override = false
        #expect(view.isShimmering, "it starts again when saving ends")
    }

    @Test func toggleOverrideFlipsSaving() {
        let power = PowerState()
        #expect(!power.saving)
        power.toggleOverride()
        #expect(power.saving)
        power.toggleOverride()
        #expect(!power.saving)
    }

    /// One reading of Low Power Mode and heat for the whole app.
    @Test func onlyThePowerServiceReadsThePhone() {
        var found: [String] = []
        for (file, lines) in swiftSources(["App", "HermesKit"]) where file != "HermesKit/Net/PowerPolls.swift" {
            for (index, line) in lines.enumerated() {
                // Observing the change notification is not a reading (diagnostics' PowerLog listens to it).
                let code = (line.components(separatedBy: "//").first ?? line)
                    .replacingOccurrences(of: "thermalStateDidChangeNotification", with: "")
                if code.contains("isLowPowerModeEnabled") || code.contains(".thermalState") { found.append("\(file):\(index + 1)") }
            }
        }
        #expect(found.isEmpty, Comment(rawValue: "Ask PowerState.shared.saving instead: " + found.joined(separator: ", ")))
    }

    // MARK: §4 Largest Attachment

    private func scratch() -> UserDefaults {
        let name = "m9-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// Tester report 2026-11-07: up to Hermes's own 100 MB upload limit, 100 by default.
    @Test func theAttachmentLimitIsClampedAndDefaultsTo100() {
        #expect(AttachmentLimit.clamp(nil) == 100)
        #expect(AttachmentLimit.clamp(0) == 1)
        #expect(AttachmentLimit.clamp(-5) == 1)
        #expect(AttachmentLimit.clamp(99) == 99)
        #expect(AttachmentLimit.clamp(32) == 32, "a limit set before the raise is kept")
        #expect(AttachmentLimit.clamp(250) == 100)
        #expect(AttachmentLimit.clamp(5) == 5)
        #expect(AttachmentLimit.clamp(5.9) == 5)
        #expect(AttachmentLimit.clamp("abc") == 100, "a corrupted value reads as the default")
        #expect(AttachmentLimit.clamp("7") == 100, "text is not a number here")
        #expect(AttachmentLimit.clamp(Double.nan) == 100)
        #expect(AttachmentLimit.clamp(Double.infinity) == 100)

        let defaults = scratch()
        #expect(AttachmentLimit.megabytes(in: defaults) == 100)
        #expect(AttachmentLimit.set(5, in: defaults))
        #expect(AttachmentLimit.megabytes(in: defaults) == 5)
        #expect(!AttachmentLimit.set(5, in: defaults), "the same value is no change")
        #expect(AttachmentLimit.set(400, in: defaults))
        #expect(AttachmentLimit.megabytes(in: defaults) == 100)
        #expect(defaults.object(forKey: AttachmentLimit.key) == nil, "the default is stored as nothing (an upgrade reads 100)")
        #expect(AttachmentLimit.set(0, in: defaults))
        #expect(AttachmentLimit.megabytes(in: defaults) == 1)
        // The process's own setting is the default unless a test run's simulator was changed by hand.
        #expect(AttachmentStaging.maxItemBytes == AttachmentLimit.bytes)
        #expect(MediaLoader.imageCeiling == min(32 << 20, AttachmentLimit.bytes))
    }

    @Test func theRefusalNamesTheLimitAndThisBuildsName() {
        let app = AppIdentity.current.displayName
        #expect(!app.isEmpty)
        #expect(AttachmentLimit.refusal(name: "big.mov", megabytes: 100)
                == "“big.mov” is larger than 100 MB, the most \(app) can send.")
        #expect(AttachmentLimit.refusal(name: "big.mov", megabytes: 2)
                == "“big.mov” is larger than 2 MB, the largest attachment this iPhone is set to send. You can change it in Settings › Largest Attachment.")
        #expect(AttachmentLimit.refusal(name: "a", megabytes: 100, app: "Hermes HQ").contains("Hermes HQ"))
        #expect(AttachmentLimit.footer(app: "Hermes HQ")
                == "The largest file Hermes HQ attaches or previews, in MB. Up to 100, which is the default. Set on this iPhone only, for every bot.")
        // [mac] Stress test 2026-10-28 round 6: the Mac's row shows "MB" itself. Round 7: the default with its unit.
        #expect(AttachmentLimit.macFooter(app: "Hermes HQ")
                == "Files larger than this aren’t attached or previewed. Default: 100 MB. Set on this Mac for every bot.")
        #expect(AttachmentPrepareError.tooLarge(name: "big.mov").errorDescription == AttachmentLimit.refusal(name: "big.mov"))
        // No product name is written into the source of either sentence.
        for (file, lines) in swiftSources(["HermesKit/Attachments"]) {
            for line in lines where line.contains("larger than") {
                #expect(!line.contains("HQ Native") && !line.contains("Hermes HQ"), "\(file): \(line)")
            }
        }
    }

    @Test func aLowerLimitRefusesTheBigItemAndKeepsTheSmallOne() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "m9-limit-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let big = base.appending(path: "big.bin"), small = base.appending(path: "small.bin")
        try Data(count: 3 * 1024 * 1024).write(to: big)
        try Data(count: 1024 * 1024).write(to: small)
        let staging = AttachmentStaging(accountId: "m9-limit", base: base)
        let limit: Int64 = 2 * 1024 * 1024
        #expect(throws: AttachmentPrepareError.tooLarge(name: "big.bin")) {
            _ = try staging.copyIn(big, id: UUID().uuidString, name: "big.bin", limit: limit)
        }
        let kept = try staging.copyIn(small, id: UUID().uuidString, name: "small.bin", limit: limit)
        #expect(FileManager.default.fileExists(atPath: kept.path), "the small one in the same batch still attaches")
    }

    @Test func largestAttachmentIsSearchable() {
        let found = SettingsSearch.results("largest attachment", in: SettingsSearch.appRows)
        #expect(found.map(\.label) == ["Largest Attachment"])
        #expect(found.first?.target == .root("attachment-limit"))
        #expect(SettingsSearch.results("megabytes", in: SettingsSearch.appRows).map(\.label).contains("Largest Attachment"))
    }

    // MARK: §12 File Browser

    @Test func theFilesButtonNeedsTheSwitchAndAFolder() {
        #expect(!FileBrowserPref.showsButton(on: false, directory: "/Users/me/app"))
        #expect(FileBrowserPref.showsButton(on: true, directory: "/Users/me/app"))
        #expect(!FileBrowserPref.showsButton(on: true, directory: nil), "never a dead button")
        #expect(!FileBrowserPref.showsButton(on: true, directory: ""))
        #expect(!FileBrowserPref.showsButton(on: true, directory: "  \n"))
    }

    @Test func fileBrowserIsOffUntilTurnedOnAndTellsOpenChats() {
        let before = UserDefaults.standard.object(forKey: FileBrowserPref.key)
        defer { if let before { UserDefaults.standard.set(before, forKey: FileBrowserPref.key) } else { UserDefaults.standard.removeObject(forKey: FileBrowserPref.key) } }
        UserDefaults.standard.removeObject(forKey: FileBrowserPref.key)
        #expect(!FileBrowserPref.isOn)
        var told = 0
        let token = NotificationCenter.default.addObserver(forName: FileBrowserPref.didChange, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { told += 1 }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        FileBrowserPref.isOn = true
        FileBrowserPref.isOn = true
        #expect(FileBrowserPref.isOn && told == 1)
        UserDefaults.standard.set("yes", forKey: FileBrowserPref.key)
        #expect(!FileBrowserPref.isOn, "a value that is not a Bool reads as the default")
        #expect(SettingsSearch.results("file browser", in: SettingsSearch.appRows).map(\.label) == ["Files Button in Chats"], "the old name still finds it")
    }

    // MARK: §13 hidden on phone (web-shell-only)

    /// The desktop renderer's controls the web shell had to hide on iPhone have no native counterpart: they must not
    /// appear in Settings or its search (a control that does nothing is worse than none).
    @Test func desktopOnlyControlsStayAbsent() throws {
        let banned = ["Tours", "Session Density", "User Bubble", "Tool View", "Hide Code Diffs", "Reasoning Collapsed", "Model Pricing"]
        let labels = (SettingsSearch.appRows + SettingsSearch.rootPages).map(\.label)
        for word in banned {
            #expect(!labels.contains { $0.caseInsensitiveCompare(word) == .orderedSame }, "\(word) is in the search index")
            #expect(SettingsSearch.results(word, in: SettingsSearch.appRows + SettingsSearch.rootPages).allSatisfy { $0.label.caseInsensitiveCompare(word) != .orderedSame })
        }
        let rootView = try String(contentsOf: root.appendingPathComponent("App/Settings/SettingsRootView.swift"), encoding: .utf8)
        for word in banned { #expect(!rootView.contains("\"\(word)\""), "\(word) is a Settings row") }
    }

    // MARK: §5 Default Project Folder

    @Test func sessionCreateCarriesTheFolderOnlyWhenOneIsSet() {
        let none = SessionCreate.params(["profile": "ivy", "follow_profile_config": true], profile: "ivy", folder: nil)
        #expect(none["cwd"] == nil && none["cwd_explicit"] == nil, "no folder: neither key, never null")
        #expect(none["profile"]?.string == "ivy" && none["follow_profile_config"]?.bool == true)
        let with = SessionCreate.params(["profile": "ivy"], profile: "ivy", folder: "/Users/me/app")
        #expect(with["cwd"]?.string == "/Users/me/app" && with["cwd_explicit"]?.bool == true)
    }

    /// A chat HQ starts is a "desktop" chat (the web's own source): as "tui" the agent is told `MEDIA:` doesn't work
    /// and writes a picture as its plain path (tester ivy, 2026-10-26).
    @Test func sessionCreateSaysDesktop() {
        #expect(SessionCreate.params(["profile": "ivy"], profile: "ivy", folder: nil)["source"]?.string == "desktop")
        #expect(SessionCreate.params(["profile": "ivy", "source": "kanban"], profile: "ivy")["source"]?.string == "kanban", "a caller's own source stays")
    }

    @Test func theFolderIsPerGatewayAndFallsBackToTheAllBotsOne() {
        let account = "test|folder-\(UUID().uuidString)"
        defer { DefaultProjectFolder.set(nil, account: account, profile: "default"); DefaultProjectFolder.set(nil, account: account, profile: "coder"); DefaultProjectFolder.activeAccount = nil }
        DefaultProjectFolder.activeAccount = account
        #expect(DefaultProjectFolder.current(profile: "coder") == nil)
        DefaultProjectFolder.set("  /Users/me/app \n", account: account)
        #expect(DefaultProjectFolder.path(account: account) == "/Users/me/app", "trimmed")
        #expect(DefaultProjectFolder.current(profile: "coder") == "/Users/me/app", "every bot")
        DefaultProjectFolder.set("/Users/me/coder", account: account, profile: "coder")
        #expect(DefaultProjectFolder.current(profile: "coder") == "/Users/me/coder", "a bot's own folder wins")
        DefaultProjectFolder.activeAccount = "someone-else"
        #expect(DefaultProjectFolder.current(profile: "coder") == nil, "another gateway has none")
        DefaultProjectFolder.set("   ", account: account)
        #expect(DefaultProjectFolder.path(account: account) == nil, "blank clears")
    }

    @Test func aFolderAnswerNeedsEntriesAndNoError() throws {
        #expect(DefaultProjectFolder.isFolder(try ChatJSON.parse(Data(#"{"entries":[]}"#.utf8))))
        #expect(!DefaultProjectFolder.isFolder(try ChatJSON.parse(Data(#"{"entries":[],"error":"No such directory"}"#.utf8))))
        #expect(!DefaultProjectFolder.isFolder(try ChatJSON.parse(Data(#"{"error":"nope"}"#.utf8))))
        #expect(!DefaultProjectFolder.isFolder(try ChatJSON.parse(Data(#"{}"#.utf8))))
    }

    @Test func aProjectsFolderIsNeverDropped() async throws {
        let account = "test|project-\(UUID().uuidString)"
        defer { DefaultProjectFolder.set(nil, account: account); DefaultProjectFolder.activeAccount = nil }
        DefaultProjectFolder.activeAccount = account
        DefaultProjectFolder.set("/default", account: account)
        let client = FakeGatewayClient()
        client.onCall { _, _ in throw RPCError(code: 4003, message: "cwd not found", data: nil) }
        await #expect(throws: (any Error).self) {
            _ = try await SessionCreate.call(client, profile: "ivy", ["profile": "ivy"], folder: "/h/site", timeout: .seconds(5))
        }
        let calls = client.calls("session.create")
        #expect(calls.count == 1 && calls[0].params["cwd"]?.string == "/h/site", "the project's folder, over the default, once")
    }

    @Test func aRefusedFolderRetriesOnceWithoutIt() async throws {
        let account = "test|retry-\(UUID().uuidString)"
        defer { DefaultProjectFolder.set(nil, account: account); DefaultProjectFolder.activeAccount = nil }
        DefaultProjectFolder.activeAccount = account
        DefaultProjectFolder.set("/gone", account: account)
        let client = FakeGatewayClient()
        client.onCall { _, params in
            if params["cwd"] != nil { throw RPCError(code: 4003, message: "cwd not found", data: nil) }
            return ["session_id": "r1", "stored_session_id": "s1"]
        }
        let made = try await SessionCreate.call(client, profile: "ivy", ["profile": "ivy"], timeout: .seconds(5))
        #expect(made["stored_session_id"]?.string == "s1")
        let calls = client.calls("session.create")
        #expect(calls.count == 2 && calls[0].params["cwd"]?.string == "/gone" && calls[1].params["cwd"] == nil)
        // Without a folder a failure is the failure: no second try.
        DefaultProjectFolder.set(nil, account: account)
        let failing = FakeGatewayClient()
        failing.onCall { _, _ in throw RPCError(code: 4000, message: "no", data: nil) }
        await #expect(throws: (any Error).self) { _ = try await SessionCreate.call(failing, profile: "ivy", ["profile": "ivy"], timeout: .seconds(5)) }
        #expect(failing.calls("session.create").count == 1)
    }

    @Test func everySessionCreateForAChatGoesThroughTheHelper() {
        let allowed: Set<String> = ["HermesKit/Settings/DefaultProjectFolder.swift",
                                    "HermesKit/Groups/GroupTurn.swift",            // plumbing sessions: not chats the person started
                                    "HermesKit/Chat/LiveChatSession+ChatActions.swift"]   // a branch: starts in the original's folder
        var found: [String] = []
        for (file, lines) in swiftSources(["App", "HermesKit"]) where !allowed.contains(file) {
            for (index, line) in lines.enumerated() where line.contains("call(\"session.create\"") { found.append("\(file):\(index + 1)") }
        }
        #expect(found.isEmpty, "session.create outside SessionCreate: \(found)")
        #expect(SettingsSearch.results("project folder", in: SettingsSearch.appRows).map(\.label).contains("Default Project Folder"))
    }

    // MARK: §15 alerts raised from gateway events

    @Test func backgroundTaskWordsFollowTheWeb() {
        #expect(BackgroundTaskText.line(command: "npm test\nmore", status: "exited", exitCode: 0, tail: "ok\n") == "Background task finished: npm test (exit 0)\nok")
        let failed = BackgroundTaskText.line(command: "make", status: "exited", exitCode: 2, tail: "a\nb\nc\nd\n")
        #expect(failed == "Background task failed: make (exit 2)\nb\nc\nd", "the last three lines")
        #expect(BackgroundTaskText.line(command: "", status: "exited", exitCode: nil, tail: nil) == "Background task finished: background process")
        #expect(BackgroundTaskText.line(command: String(repeating: "x", count: 500), status: nil, exitCode: nil, tail: nil).count <= 240)
    }

    @Test func onlyTheTwoCreditKeysRaiseAnAlert() {
        #expect(NotificationHub.creditKeys == ["credits.depleted", "credits.restored"])
    }
}
