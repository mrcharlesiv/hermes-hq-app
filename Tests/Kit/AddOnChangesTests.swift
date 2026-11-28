import Foundation
import Testing
@testable import HermesHQNative

/// [addon-whats-new] Tester 2026-11-05: the update sheet says what it installs, from the add-ons' release commits.
@Suite struct AddOnChangesTests {
    private let subjects = [
        "hermes-hq-push 0.9.40: after an update the app reads the whole task list again; the add-on says its own version",
        "hermes-hq-browser 3.8.0: tests live outside the plugin",
        "Task ideas: the daily look gets the bot's usual tools",
        "hermes-hq-push 0.9.39: Task ideas",
        "hermes-hq-push 0.9.33: a made-up place in the made-note example",
        "hermes-hq-push 0.9.33: Hermes takes its part of a task",
        "hermes-hq-push 0.9.10: an old one",
    ]

    @Test func versionsNewerThanHermesHasNewestFirst() {
        let changes = AddOnChanges.changes(subjects: subjects, plugin: "hermes-hq-push", after: "0.9.32")
        #expect(changes.map(\.version) == ["0.9.40", "0.9.39", "0.9.33"], "three at most")
        #expect(changes[0].line == "After an update the app reads the whole task list again")
        // A version's first (oldest) commit names it; the follow-up's words don't.
        #expect(changes[2].line == "Hermes takes its part of a task")
        #expect(AddOnChanges.newest(changes) == "0.9.40")
    }

    @Test func nothingNewerIsEmpty() {
        #expect(AddOnChanges.changes(subjects: subjects, plugin: "hermes-hq-push", after: "0.9.40").isEmpty)
    }

    @Test func noInstalledVersionTakesTheNewest() {
        let changes = AddOnChanges.changes(subjects: subjects, plugin: "hermes-hq-push", after: nil, limit: 2)
        #expect(changes.map(\.version) == ["0.9.40", "0.9.39"])
    }

    @Test func otherAddOnsAndPlainCommitsAreLeftOut() {
        let changes = AddOnChanges.changes(subjects: subjects, plugin: "hermes-hq-browser", after: "3.7.0")
        #expect(changes == [AddOnChanges.Change(version: "3.8.0", line: "Tests live outside the plugin")])
    }

    @Test func readsGitHubsCommitList() throws {
        let json = #"[{"commit":{"message":"hermes-hq-push 0.9.39: Task ideas\n\nLonger body"}},{"commit":{"message":"README"}}]"#
        let changes = AddOnChanges.parse(Data(json.utf8), plugin: "hermes-hq-push", after: "0.9.38")
        #expect(changes == [AddOnChanges.Change(version: "0.9.39", line: "Task ideas")])
        #expect(AddOnChanges.parse(Data("{}".utf8), plugin: "hermes-hq-push", after: nil).isEmpty)
    }

    @Test func sheetVersionWords() {
        #expect(AddOnUpdate.versions(from: "0.9.33", to: "0.9.40", setUp: false) == "0.9.33 → 0.9.40")
        #expect(AddOnUpdate.versions(from: "2.0.1", to: "2.0.1", setUp: false) == "2.0.1 · newer build", "the same number: said, not 2.0.1 → 2.0.1")
        #expect(AddOnUpdate.versions(from: nil, to: "0.9.40", setUp: true) == "New · 0.9.40")
        #expect(AddOnUpdate.versions(from: "0.9.33", to: nil, setUp: false) == "0.9.33 → newest")
        #expect(AddOnUpdate.versions(from: nil, to: nil, setUp: false) == nil)
    }

    @Test func aCutInsideBracketsDropsTheAside() {
        #expect(AddOnChanges.tidy("tasks can be turned off entirely (tools hidden; no note)") == "Tasks can be turned off entirely")
        // Mac polish #145: an aside naming code goes; one in words stays.
        #expect(AddOnChanges.tidy("works on 0.22.6 (browser_exec only) and older") == "Works on 0.22.6 and older")
        #expect(AddOnChanges.tidy("works on 0.22.6 (and newer) and older") == "Works on 0.22.6 (and newer) and older")
        // Mac polish #145's leftover: an aside that opens the line takes its space with it.
        #expect(AddOnChanges.tidy("(browser_exec only) pages open faster") == "Pages open faster")
        // Internal tags like (owner ...) and (issue #11) are stripped while plain wording stays.
        #expect(AddOnChanges.tidy("1Password logins never fill on a sibling host (issue #11)") == "1Password logins never fill on a sibling host")
        #expect(AddOnChanges.tidy("goal tasks keep their files (owner 2026-11-23)") == "Goal tasks keep their files")
    }

    @Test func preReleaseSemverAndAliasesAndCompoundCommits() {
        #expect((AddOnChanges.compareVersions("0.4.0", "0.4.0-beta.2") ?? 0) > 0, "stable beats pre-release")
        #expect((AddOnChanges.compareVersions("0.4.0-beta.10", "0.4.0-beta.2") ?? 0) > 0, "numeric pre-release order")
        #expect((AddOnChanges.compareVersions("0.4.0-beta.1", "0.3.0-beta.3") ?? 0) > 0)
        #expect(AddOnChanges.versionAtLeast("0.4.0-beta.2", "0.4.0-beta.1"))
        #expect(!AddOnChanges.versionAtLeast("0.3.0-beta.3", "0.4.0-beta.1"))

        let mixed = [
            "Proactivity 0.4.0-beta.2: a hand-off says the date once",
            "hermes-hq-proactive 0.4.0-beta.1: finds are said in the bot's chat",
            "hermes-hq-proactive 0.3.0-beta.3: a closed item takes its suggestion with it",
            "hermes-hq-push 0.9.89 & hermes-hq-browser 3.13.1: fix vault fill and alert on browser ask",
            "unrelated commit message",
        ]
        let proactive = AddOnChanges.changes(subjects: mixed, plugin: "hermes-hq-proactive", after: "0.3.0-beta.3", limit: 10)
        #expect(proactive.map(\.version) == ["0.4.0-beta.2", "0.4.0-beta.1"])
        #expect(proactive[0].line == "A hand-off says the date once")
        #expect(proactive[1].line == "Finds are said in the bot's chat")

        let push = AddOnChanges.changes(subjects: mixed, plugin: "hermes-hq-push", after: "0.9.88", limit: 10)
        #expect(push == [AddOnChanges.Change(version: "0.9.89", line: "Fix vault fill and alert on browser ask")])

        let browser = AddOnChanges.changes(subjects: mixed, plugin: "hermes-hq-browser", after: "3.13.0", limit: 10)
        #expect(browser == [AddOnChanges.Change(version: "3.13.1", line: "Fix vault fill and alert on browser ask")])
    }

    @Test func mergeKeepsFutureReleasesAndFillsOfflineGaps() {
        // Offline / rate-limited: built-in curated notes still explain what's changing.
        let offlinePush = AddOnChanges.merge(live: [], plugin: "hermes-hq-push", after: "0.9.85")
        #expect(offlinePush.map(\.version).contains("0.9.91"))
        #expect(offlinePush.map(\.version).contains("0.9.86"))
        #expect(offlinePush.count > 3, "does not silently truncate at 3")

        let offlineProactive = AddOnChanges.merge(live: [], plugin: "hermes-hq-proactive", after: "0.3.0-beta.3")
        #expect(offlineProactive.map(\.version) == ["0.4.0-beta.2", "0.4.0-beta.1"])

        // Future release from live GitHub appears first, above built-in notes.
        let future = [AddOnChanges.Change(version: "0.9.95", line: "Adds brand new notification grouping")]
        let merged = AddOnChanges.merge(live: future, plugin: "hermes-hq-push", after: "0.9.89")
        #expect(merged.first == future[0])
        #expect(merged.map(\.version).prefix(3) == ["0.9.95", "0.9.91", "0.9.90"])
    }

    @Test func bestTargetVersionReplacesCommitSHAAndFallsBackCleanly() {
        #expect(AddOnChanges.isCommitSHA("0e31cd2"))
        #expect(!AddOnChanges.isCommitSHA("0.4.0-beta.2"))
        #expect(AddOnChanges.bestTargetVersion(liveNewest: "0.4.0-beta.2", fallbackTo: "0e31cd2", plugin: "hermes-hq-proactive") == "0.4.0-beta.2")
        #expect(AddOnChanges.bestTargetVersion(liveNewest: nil, fallbackTo: "0e31cd2", plugin: "hermes-hq-proactive") == "0.4.0-beta.2")
        #expect(AddOnChanges.bestTargetVersion(liveNewest: nil, fallbackTo: nil, plugin: "hermes-hq-push") == PushPolicy.wantedVersion)
        #expect(AddOnChanges.bestTargetVersion(liveNewest: nil, fallbackTo: nil, plugin: "hermes-hq-browser") == BrowserAddOn.wantedVersion)
    }

    @Test func hqPluginHelpersAndGuaranteedFallbackCopy() {
        #expect(AddOnChanges.isHQPlugin("hermes-hq-push"))
        #expect(AddOnChanges.isHQPlugin("hermes-hq-browser"))
        #expect(AddOnChanges.isHQPlugin("hermes-hq-proactive"))
        #expect(AddOnChanges.isHQPlugin("hermes-hq-future"))
        #expect(!AddOnChanges.isHQPlugin("web-clipper"))

        #expect(AddOnChanges.displayTitle(for: "hermes-hq-push") == "Hermes HQ Add-on")
        #expect(AddOnChanges.displayTitle(for: "hermes-hq-browser") == "Browser Add-on")
        #expect(AddOnChanges.displayTitle(for: "hermes-hq-proactive") == "Proactivity (Beta)")
        #expect(AddOnChanges.displayTitle(for: "web-clipper") == "Web Clipper")

        #expect(!AddOnChanges.fallbackSummary(plugin: "hermes-hq-push", from: "0.9.91", to: "0.9.91", setUp: false, botsNote: "For Finance").isEmpty)
        #expect(AddOnChanges.fallbackSummary(plugin: "hermes-hq-push", from: "0.9.91", to: "0.9.91", setUp: false, botsNote: "For Finance").contains("remaining bots"))
        #expect(AddOnChanges.fallbackSummary(plugin: "hermes-hq-browser", from: nil, to: "3.13.1", setUp: true).contains("Browser Add-on"))
        #expect(AddOnChanges.fallbackSummary(plugin: "hermes-hq-proactive", from: "0.3.0-beta.3", to: "0.4.0-beta.2", setUp: false).contains("Proactivity (Beta)"))
    }
}
