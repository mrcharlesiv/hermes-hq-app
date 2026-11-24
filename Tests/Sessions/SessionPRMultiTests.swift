import Foundation
import Testing
@testable import HermesHQNative

/// [pr-multi] A chat with more than one pull request or branch (add-on 0.9.75): the list is read, kept, counted and
/// worded; a chat being opened asks fresh.
@Suite(.serialized) struct SessionPRMultiTests {
    private func makeStore(_ client: BotsFakeGatewayClient, dir: URL = BotsTest.tempDirectory()) -> SessionStore {
        SessionStore(client: client, account: .botsTestAccount, cacheDirectory: dir, timing: .fast, autoStart: false)
    }

    private func row(_ id: String) -> SessionSummary {
        SessionSummary(id: id, profile: "ivy", title: id, preview: nil, lastActive: nil, source: nil, unread: false, isRunning: false)
    }

    nonisolated private static let answer = Data("""
    {"sessions":[{"profile":"ivy","id":"two","state":"open","repo":"o/r","number":12,"url":"https://github.com/o/r/pull/12",
      "items":[{"state":"open","repo":"o/r","number":12,"url":"https://github.com/o/r/pull/12","source":"github"},
               {"state":"draft","branch":"feat/b","source":"git"},
               {"state":"merged","repo":"o/r","number":9,"url":"https://evil.example/o/r/pull/9","source":"github"},
               {"state":"bogus","branch":"x"}]},
     {"profile":"ivy","id":"old","state":"draft","branch":"feat/a"}]}
    """.utf8)

    @Test func itemsAreReadCheckedAndKeptForTheNextLaunch() async throws {
        let dir = BotsTest.tempDirectory()
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, _, _ in Self.answer }
        let store = makeStore(client, dir: dir)
        await store.refreshPullRequests(for: [row("two"), row("old")])
        let two = try #require(store.pullRequest(profile: "ivy", id: "two"))
        let items = try #require(two.items)
        #expect(items.map(\.state) == [.open, .draft, .merged])            // an unknown word is left out
        #expect(items[0].source == .github && items[1].source == .git && items[1].branch == "feat/b")
        #expect(items[2].number == 9 && items[2].url == nil)                 // a link that isn't GitHub's is dropped
        #expect(two.waitingCount == 2)
        #expect(two.summary == "Open #12, 1 more not merged")
        #expect(items[1].label == "Draft · feat/b" && items[0].label == "Open #12")
        let old = try #require(store.pullRequest(profile: "ivy", id: "old"))
        #expect(old.items == nil && old.waitingCount == 1 && old.summary == "Draft")   // an add-on before 0.9.75
        store.stop()
        RosterDiskWriter.shared.flush()

        let quiet = BotsFakeGatewayClient()
        quiet.onREST { _, _, _, _ in try await Task.sleep(for: .seconds(30)); return Data() }
        let next = makeStore(quiet, dir: dir)
        #expect(next.pullRequest(profile: "ivy", id: "two")?.items?.map(\.state) == [.open, .draft, .merged])
        #expect(next.pullRequest(profile: "ivy", id: "two")?.waitingCount == 2)
        #expect(next.pullRequest(profile: "ivy", id: "old")?.items == nil)
        next.stop()
    }

    @Test func onlyAnAskByHandForAFewChatsIsFresh() async throws {
        let client = BotsFakeGatewayClient()
        client.onREST { _, _, _, _ in Self.answer }
        func lastFresh() throws -> JSONValue? {
            let call = try #require(client.restCalls.last { $0.path.hasSuffix("/sessions/pr-status") })
            return try JSONValue.parse(#require(call.body))["fresh"]
        }
        let store = makeStore(client)
        await store.refreshPullRequests(for: [row("two")])
        #expect(try lastFresh() == nil)                                      // the list's own pass
        await store.refreshPullRequests(for: [row("two")], force: true)
        #expect(try lastFresh() == .bool(true))                              // a chat opened, a mark set
        await store.refreshPullRequests(for: (0..<6).map { row("\($0)") }, force: true)
        #expect(try lastFresh() == nil)                                      // never a whole list
        store.stop()
    }

    @Test func countedStatesFollowTheItemsAndTheOwnersMark() {
        func item(_ state: SessionPRStatus.State, _ number: Int? = nil) -> SessionPRItem {
            SessionPRItem(state: state, number: number, source: number == nil ? .git : .github)
        }
        var two = SessionPRStatus(state: .open, number: 2, items: [item(.open, 2), item(.merged, 1)])
        #expect(two.countedStates == [.open, .merged] && two.waitingCount == 1 && two.summary == "Open #2")
        two.manual = true; two.state = .closed
        #expect(two.countedStates == [.closed] && two.summary == "Closed #2, 1 not merged")
        let unread = SessionPRStatus(state: .unknown, items: [item(.unknown, 3), item(.merged, 1)])
        #expect(unread.countedStates == [.unknown, .merged])                  // both unknown and merged count
        #expect(SessionPRStatus(state: .none).countedStates == [SessionPRStatus.State.none])
        #expect(SessionPRStatus(state: .unknown).countedStates == [.unknown])
        #expect(SessionPRStatus(state: .unknown, unknownReason: .checking).countedStates.isEmpty)
        #expect(SessionPRStatus(state: .draft, items: []).countedStates == [.draft])
    }

    /// [pr-numbers] The row's right side: numbers in their state's colour, waiting ones first, two at most.
    @Test func theRowShowsEachNumberWaitingOnesFirst() {
        typealias Tag = SessionPRStatus.Tag
        func item(_ state: SessionPRStatus.State, _ number: Int? = nil) -> SessionPRItem {
            SessionPRItem(state: state, number: number, source: number == nil ? .git : .github)
        }
        // Two at the same time, the older one merged: both, the open one first.
        let pair = SessionPRStatus(state: .open, number: 44, items: [item(.merged, 45), item(.open, 44)])
        #expect(pair.tags().shown == [Tag(state: .open, number: 44), Tag(state: .merged, number: 45)] && pair.tags().more == 0)
        // Newest first within a state; a branch with no PR keeps its place; past two, how many more.
        let many = SessionPRStatus(state: .open, number: 7, items: [
            item(.merged, 8), item(.open, 7), item(.draft), item(.closed, 5), item(.open, 6), item(.none)])
        #expect(many.tags().shown == [Tag(state: .open, number: 7), Tag(state: .draft)] && many.tags().more == 3)
        #expect(many.tags(limit: 9).shown.map(\.number) == [7, nil, 6, 8, 5])
        #expect(SessionPRStatus(state: .unknown, items: [item(.merged, 1), item(.unknown, 2)]).tags().shown.map(\.state)
                == [.unknown, .merged])
        // The same number twice (a PR and its branch both listed) is one.
        #expect(SessionPRStatus(state: .open, number: 3, items: [item(.open, 3), item(.open, 3)]).tags().shown.count == 1)
        // The owner's own Closed mark, an add-on before 0.9.75, nothing listed: the one answer.
        var marked = pair; marked.manual = true; marked.state = .closed
        #expect(marked.tags().shown == [Tag(state: .closed, number: 44)])
        #expect(SessionPRStatus(state: .draft, branch: "feat/a").tags().shown == [Tag(state: .draft)])
        #expect(SessionPRStatus(state: .merged, number: 9, items: []).tags().shown == [Tag(state: .merged, number: 9)])
        // [pr-pill] One pill and how many more: the lead is the open one, the rest counted.
        #expect(pair.tags(limit: 1).shown == [Tag(state: .open, number: 44)] && pair.tags(limit: 1).more == 1)
        #expect(many.tags(limit: 1).more == 4)
        #expect(Tag(state: .open, number: 44).pillText == "#44" && Tag(state: .draft).pillText == "Branch"
                && Tag(state: .none).pillText == "Branch" && Tag(state: .merged).pillText == "Merged"
                && Tag(state: .unknown).pillText == "Unknown")
    }

    @Test @MainActor func aChatWithAMergedAndAnOpenPullRequestCountsUnderBoth() {
        let projects = ["default": [SessionProject(id: "a", label: "A", root: "/a", paths: ["/a"])]]
        func row(_ id: String, _ status: SessionPRStatus) -> SessionSummary {
            var row = SessionSummary(id: id, profile: "default", title: id, preview: nil, lastActive: nil,
                                     source: nil, unread: false, isRunning: false)
            row.cwd = "/a"
            row.pullRequest = status
            return row
        }
        let both = SessionPRStatus(state: .open, number: 2, items: [
            SessionPRItem(state: .open, number: 2, source: .github), SessionPRItem(state: .open, number: 3, source: .github),
            SessionPRItem(state: .merged, number: 1, source: .github)])
        let counts = ProjectPageHeader.pullRequestCounts([row("both", both), row("done", SessionPRStatus(state: .merged))],
                                                         project: "/a", projects: projects)
        #expect(counts[.open] == 1 && counts[.merged] == 2)                   // chats, not pull requests
    }
}
