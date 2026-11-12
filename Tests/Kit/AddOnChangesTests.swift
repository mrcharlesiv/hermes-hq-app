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
    }
}
