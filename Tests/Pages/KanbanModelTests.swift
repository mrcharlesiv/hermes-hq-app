// P-U4: the Kanban board model (`S/ui-kanban/kanban.test.ts:49-134`) and the store's optimistic writes.

import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

private func task(_ id: String, _ title: String, _ status: String, body: String? = nil) -> KanbanTask {
    var t = KanbanTask(id: id, title: title, status: status)
    t.body = body
    return t
}

private let board = KanbanBoard(columns: [
    KanbanColumn(name: "triage", tasks: []),
    KanbanColumn(name: "todo", tasks: [task("t_1", "Write the brief", "todo")]),
    KanbanColumn(name: "blocked", tasks: [task("t_2", "Fix scene picker", "blocked", body: "needs the room list")]),
    KanbanColumn(name: "done", tasks: [task("t_3", "Old", "done")]),
])

private func whereIs(_ b: KanbanBoard) -> [String: String] {
    Dictionary(uniqueKeysWithValues: b.columns.flatMap { column in column.tasks.map { ($0.id, column.name) } })
}

struct KanbanModelTests {
    /// UX study 2026-10-19 #132: a heading, so no full stop (in the Desktop Look's capitals it read as a typo).
    @Test func statusHeadingHasNoFullStop() {
        #expect(KanbanModel.groupHeading(count: 2, status: "blocked") == "2 Tasks · Waiting on something, often you")
        #expect(KanbanModel.groupHeading(count: 1, status: "done") == "1 Task · Finished. The result is on the task")
        #expect(KanbanModel.groupHeading(count: 3, status: "parked") == "3 Tasks")
        #expect(KanbanModel.statusHelp["blocked"] == "Waiting on something, often you.", "the help itself keeps its full stop elsewhere")
    }

    @Test func putsBlockedFirstThenWorkflowOrderThenStatusesTheBackendAdds() {
        #expect(KanbanModel.chipOrder(["triage", "todo", "ready", "running", "blocked", "done", "archived", "parked"])
                == ["blocked", "triage", "todo", "ready", "running", "done", "parked"])
    }

    @Test func opensOnTheFirstStatusWithWorkDoneOnlyWhenNothingElseHasAny() {
        #expect(KanbanModel.defaultStatus(["blocked", "todo", "done"], ["blocked": 0, "todo": 2, "done": 9]) == "todo")
        #expect(KanbanModel.defaultStatus(["blocked", "todo", "done"], ["done": 9]) == "done")
        #expect(KanbanModel.defaultStatus(["blocked", "todo"], [:]) == "blocked")
    }

    @Test func countsAndSearchesAcrossTitleDescriptionAndId() {
        #expect(KanbanModel.statusCounts(board) == ["triage": 0, "todo": 1, "blocked": 1, "done": 1])
        #expect(KanbanModel.statusCounts(KanbanModel.filter(board, "room LIST")) == ["triage": 0, "todo": 0, "blocked": 1, "done": 0])
        #expect(KanbanModel.statusCounts(KanbanModel.filter(board, "t_3"))["done"] == 1)
        #expect(KanbanModel.filter(board, "  ") == board)
    }

    @Test func movesAndRemovesCardsInASnapshot() {
        let moved = KanbanModel.moveCard(board, "t_2", to: "todo")
        #expect(moved.columns.first { $0.name == "todo" }?.tasks.map { [$0.id, $0.status] } == [["t_2", "todo"], ["t_1", "todo"]])
        #expect(moved.columns.first { $0.name == "blocked" }?.tasks.isEmpty == true)
        #expect(KanbanModel.moveCard(board, "missing", to: "todo") == board)
        #expect(KanbanModel.removeCard(board, "t_1").columns[1].tasks.isEmpty)
    }

    @Test func groupsDoneByWhenItFinished() {
        let c = Chicago.calendar
        let now = Chicago.date(2026, 9, 3, 12)
        func at(_ y: Int, _ m: Int, _ d: Int) -> Double { Chicago.date(y, m, d, 9).timeIntervalSince1970 }
        #expect(KanbanModel.doneGroup(at(2026, 9, 3), now: now, calendar: c) == "Today")
        #expect(KanbanModel.doneGroup(at(2026, 9, 2), now: now, calendar: c) == "Yesterday")
        #expect(KanbanModel.doneGroup(at(2026, 8, 29), now: now, calendar: c) == "This Week")
        #expect(KanbanModel.doneGroup(at(2026, 5, 6), now: now, calendar: c) == "June")
        #expect(KanbanModel.doneGroup(at(2025, 11, 1), now: now, calendar: c) == "December 2025")
        #expect(KanbanModel.doneGroup(nil, now: now, calendar: c) == "Earlier")
        #expect(KanbanModel.groupBy([1, 1, 2, 1]) { String($0) }.map { "\($0.heading):\($0.items.count)" } == ["1:2", "2:1", "1:1"])
    }

    @Test func saysAgesBlockReasonsAndQuickMovesInWords() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let s = now.timeIntervalSince1970
        #expect(KanbanModel.shortAge(s - 30, now: now) == "now")
        #expect(KanbanModel.shortAge(s - 90 * 60, now: now) == "1h")
        #expect(KanbanModel.shortAge(s - 3 * 86_400, now: now) == "3d")
        #expect(KanbanModel.shortAge(s - 119 * 86_400, now: now) == "3mo")
        #expect(KanbanModel.shortAge(nil, now: now) == "")
        #expect(KanbanModel.blockReason("needs_input") == "Needs your input")
        #expect(KanbanModel.blockReason(nil) == "Needs you")
        #expect(KanbanModel.quickMove("blocked")! == ("ready", "Unblock"))
        #expect(KanbanModel.quickMove("done")! == ("ready", "Reopen"))
        #expect(KanbanModel.quickMove("todo")! == ("ready", "Mark Ready"), "the sheet's words on the board too")
        #expect(KanbanModel.quickMove("running") == nil)
    }

    /// The task sheet's Running For spells its units out; rows keep the short form.
    @Test func runningForSpellsItsUnitsOut() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let s = now.timeIntervalSince1970
        #expect(KanbanModel.runningFor(s - 30, now: now) == "Just started")
        #expect(KanbanModel.runningFor(s - 12 * 60, now: now) == "12 min")
        #expect(KanbanModel.runningFor(s - 3 * 3600 - 60, now: now) == "3 hr")
        #expect(KanbanModel.runningFor(s - 86_400 - 60, now: now) == "1 day")
        #expect(KanbanModel.runningFor(s - 9 * 86_400, now: now) == "9 days")
        #expect(KanbanModel.runningFor(nil, now: now) == "")
    }

    @Test func anUnassignedTaskNamesTheDefaultBotWhenThereIsOne() {
        #expect(KanbanModel.nobodyWords(defaultBot: "") == "No One")
        #expect(KanbanModel.nobodyWords(defaultBot: "Deploys") == "Deploys (default)")
    }

    @Test func namesBoardsAsPeopleReadThem() {
        #expect(KanbanModel.boardTitle(slug: "savant-ha-dashboard", name: nil) == "Savant HA Dashboard")
        #expect(KanbanModel.boardTitle(slug: "maple-saas-build", name: "maple-saas-build") == "Maple SaaS Build")
        #expect(KanbanModel.boardTitle(slug: "x", name: "Launch Plan") == "Launch Plan")
        #expect(KanbanModel.boardTitle(slug: "default", name: nil) == "Default Board")
    }

    @Test func saysAProgressNoteAndTheMainBotsCommentsInWords() {
        let bot = { (name: String) in name == "default" ? "Hermes" : name }
        let heartbeat = KanbanModel.activityLine(kind: "heartbeat", payload: #"{"note":"Running the full suite"}"#,
                                                 line: ("heartbeat", "note=Running the full suite"), botName: bot)
        #expect(heartbeat.label == "Progress update" && heartbeat.detail == "Running the full suite")
        #expect(KanbanModel.activityLine(kind: "commented", payload: ["author": "default"], line: ("comment by default", nil), botName: bot).label == "Comment from Hermes")
        #expect(KanbanModel.activityLine(kind: "commented", payload: ["author": "desktop"], line: ("comment by desktop", nil), botName: bot).label == "Comment from you")
        #expect(KanbanModel.activityLine(kind: "status", payload: "{bad", line: ("moved to Ready", nil), botName: bot).label == "moved to Ready")
        #expect(KanbanModel.eventText(kind: "status", payload: ["status": "ready"]).label == "moved to Ready")
        #expect(KanbanModel.eventText(kind: "created", payload: ["status": "todo", "assignee": "deploys"]).label == "created in Todo · assigned to deploys")
    }

    @Test func lockedStatusesAreNeverMoveTargets() {
        for status in ["running", "review", "scheduled"] { #expect(KanbanModel.isLocked(status)) }
        #expect(!KanbanModel.isLocked("ready"))
        #expect(KanbanModel.lockedReason("running") == "A bot moves a task into Running when it starts work on it.")
    }
}

/// R21: a failed optimistic write undoes only its own task.
struct KanbanRestoreTests {
    @Test func aSlowFailedMoveOfADoesNotUndoALaterSuccessfulMoveOfB() {
        let start = board
        let afterA = KanbanModel.moveCard(start, "t_1", to: "done", token: 1)
        let afterB = KanbanModel.moveCard(afterA, "t_2", to: "todo", token: 2)
        let undone = KanbanModel.restoreTask(now: afterB, before: start, after: afterA, id: "t_1")
        #expect(whereIs(undone) == ["t_1": "todo", "t_2": "todo", "t_3": "done"])
        #expect(undone.columns.first { $0.name == "todo" }!.tasks.map(\.id) == ["t_1", "t_2"])
    }

    @Test func aRemovedCardComesBackAndANewerWriteOrRefetchIsLeftAlone() {
        let removed = KanbanModel.removeCard(board, "t_3")
        #expect(whereIs(KanbanModel.restoreTask(now: removed, before: board, after: removed, id: "t_3"))["t_3"] == "done")
        let afterA = KanbanModel.moveCard(board, "t_1", to: "done", token: 1)
        let newer = KanbanModel.moveCard(afterA, "t_1", to: "blocked", token: 2)
        #expect(KanbanModel.restoreTask(now: newer, before: board, after: afterA, id: "t_1") == newer)
        // A refetch decodes fresh tasks (no edit token): the gateway owns it now.
        var refetched = afterA
        refetched.columns = afterA.columns.map { KanbanColumn(name: $0.name, tasks: $0.tasks.map { var t = $0; t.editToken = 0; return t }) }
        #expect(KanbanModel.restoreTask(now: refetched, before: board, after: afterA, id: "t_1") == refetched)
    }
}

@MainActor
struct KanbanStoreTests {
    nonisolated static func boardJSON(_ tasks: [(String, String, String)]) -> JSONValue {
        let columns = ["triage", "todo", "scheduled", "ready", "running", "blocked", "review", "done"].map { name -> JSONValue in
            .object(["name": .string(name), "tasks": .array(tasks.filter { $0.2 == name }.map { ["id": .string($0.0), "title": .string($0.1), "status": .string($0.2)] })])
        }
        return ["columns": .array(columns), "latest_event_id": 1]
    }

    @Test func aFailedMovePutsBackOnlyItsTaskAndSaysWhy() async throws {
        let refuse = "Cannot move to 'ready': blocked by parent(s) not done — 'Cut the 2.4 branch' (t_x, status=running)"
        let client = PagesFakeClient { request in
            switch (request.method, request.path) {
            case ("GET", "/api/plugins/kanban/board"): return Self.boardJSON([("t_a", "A", "todo"), ("t_b", "B", "blocked")])
            case ("GET", "/api/plugins/kanban/boards"): return ["boards": [["slug": "release-2-4", "total": 2, "is_current": true]], "current": "release-2-4"]
            case ("PATCH", "/api/plugins/kanban/tasks/t_a"): throw httpError(409, refuse)
            default: return ["ok": true]
            }
        }
        let api = KanbanAPI(client: client, nudger: KanbanNudger(client: client, delay: .milliseconds(10)))
        let store = KanbanStore(api: api, account: client.account, directory: nil)
        await store.readBoard()
        let failed = Mutex<String?>(nil)
        store.onWriteFailed = { reason in failed.withLock { $0 = reason } }
        let a = try #require(store.board?.task("t_a"))
        await store.move(a, to: "ready")
        #expect(failed.withLock { $0 } == refuse)
        #expect(store.board?.columns.first { $0.name == "todo" }?.tasks.map(\.id) == ["t_a"])
        let patch = try #require(client.log.first { $0.method == "PATCH" })
        #expect(patch.body == ["status": "ready"])
        #expect(patch.query["board"] == nil)
        try await Task.sleep(for: .milliseconds(60))
        #expect(!client.log.contains { $0.path.hasSuffix("/dispatch") }, "no nudge after a refused write")
    }

    /// UX study #134: a failed delete or Undo goes to the caller (an alert with Try Again), not the board's notice.
    @Test func aFailedDeleteOrUndoIsToldToTheCaller() async throws {
        let client = PagesFakeClient { request in
            switch (request.method, request.path) {
            case ("GET", "/api/plugins/kanban/board"): return Self.boardJSON([("t_a", "A", "done")])
            case ("GET", "/api/plugins/kanban/boards"): return ["boards": [["slug": "release-2-4", "total": 1, "is_current": true]], "current": "release-2-4"]
            case ("DELETE", _), ("PATCH", _): throw httpError(409, "The board is busy.")
            default: return ["ok": true]
            }
        }
        let api = KanbanAPI(client: client, nudger: KanbanNudger(client: client, delay: .milliseconds(10)))
        let store = KanbanStore(api: api, account: client.account, directory: nil)
        await store.readBoard()
        let notice = Mutex<String?>(nil), told = Mutex<String?>(nil)
        store.onWriteFailed = { reason in notice.withLock { $0 = reason } }
        let a = try #require(store.board?.task("t_a"))
        let deleted = await store.delete(a) { reason in told.withLock { $0 = reason } }
        #expect(!deleted && told.withLock { $0 } == "The board is busy." && notice.withLock { $0 } == nil)
        #expect(store.board?.task("t_a") != nil, "the card comes back")
        #expect(await store.unarchive(a, to: "done", board: "release-2-4") == "The board is busy.")
        #expect(notice.withLock { $0 } == nil)
    }

    /// UX study #205: a pull that fails while a board is shown hands back the reason (the page says it couldn't
    /// refresh); with no board yet the page's own error state says it instead.
    @Test func aFailedPullWithABoardShownSaysSo() async throws {
        let failing = Mutex(true)
        let client = PagesFakeClient { request in
            if request.path == "/api/plugins/kanban/board" {
                if failing.withLock({ $0 }) { throw httpError(409, "The board is busy.") }
                return Self.boardJSON([("t_a", "A", "todo")])
            }
            return ["ok": true]
        }
        let store = KanbanStore(api: KanbanAPI(client: client), account: client.account, directory: nil)
        #expect(await store.pullToRefresh() == nil, "no board yet: the error state, not the notice")
        failing.withLock { $0 = false }
        #expect(await store.pullToRefresh() == nil)
        #expect(store.board != nil)
        failing.withLock { $0 = true }
        #expect(await store.pullToRefresh() != nil)
        #expect(store.board?.task("t_a") != nil, "the board stays as saved")
    }

    @Test func aMoveNudgesTheDispatcherOnceOnTheBoardItStartedOn() async throws {
        let client = PagesFakeClient { request in
            if request.path == "/api/plugins/kanban/board" { return Self.boardJSON([("t_b", "B", "blocked")]) }
            return ["ok": true, "task": ["id": "t_b", "title": "B", "status": "ready"]]
        }
        let api = KanbanAPI(client: client, nudger: KanbanNudger(client: client, delay: .milliseconds(20)))
        let store = KanbanStore(api: api, account: client.account, directory: nil)
        await store.readBoard()
        let b = try #require(store.board?.task("t_b"))
        await store.move(b, to: "ready")
        #expect(store.board?.columns.first { $0.name == "ready" }?.tasks.first?.id == "t_b")
        try await Task.sleep(for: .milliseconds(100))
        #expect(client.log.filter { $0.path == "/api/plugins/kanban/dispatch" }.count == 1)
    }

    @Test func lockedTargetsAndReadOnlySendNothing() async throws {
        let client = PagesFakeClient { request in
            if request.path == "/api/plugins/kanban/board" { return Self.boardJSON([("t_b", "B", "todo")]) }
            return ["ok": true]
        }
        let store = KanbanStore(api: KanbanAPI(client: client), account: client.account, directory: nil)
        await store.readBoard()
        let notices = Mutex<[String]>([])
        store.onNotice = { text in notices.withLock { $0.append(text) } }
        let b = try #require(store.board?.task("t_b"))
        await store.move(b, to: "running")
        store.readOnlyGateway = true
        await store.move(b, to: "ready")
        #expect(!client.log.contains { $0.method != "GET" })
        #expect(notices.withLock { $0 } == ["A bot moves a task into Running when it starts work on it.", "Changes are off for this gateway."])
    }

    /// "" unassigns: the gateway's reassign takes an empty profile as none, and the card shows no one at once.
    @Test func assigningNoOneSendsAnEmptyProfile() async throws {
        let unassigned = Mutex(false)
        let client = PagesFakeClient { request in
            if request.path.hasSuffix("/reassign") { unassigned.withLock { $0 = true } }
            if request.path == "/api/plugins/kanban/board" {
                let who: JSONValue = unassigned.withLock { $0 } ? .null : "deploys"
                return ["columns": [["name": "todo", "tasks": [["id": "t_b", "title": "B", "status": "todo", "assignee": who]]]],
                        "latest_event_id": 1]
            }
            return ["ok": true]
        }
        let store = KanbanStore(api: KanbanAPI(client: client), account: client.account, directory: nil)
        await store.readBoard()
        let b = try #require(store.board?.task("t_b"))
        #expect(b.assignee == "deploys")
        await store.assign(b, to: "")
        let post = try #require(client.log.first { $0.method == "POST" && $0.path.hasSuffix("/reassign") })
        #expect(post.body == ["profile": "", "reclaim_first": true])
        #expect(store.board?.task("t_b")?.assignee == nil)
    }

    @Test func newTaskSendsOnlyWhatWasGiven() async throws {
        let client = PagesFakeClient { request in
            if request.method == "POST", request.path == "/api/plugins/kanban/tasks" {
                return ["task": ["id": "t_new", "title": "Write the release post", "status": "ready"]]
            }
            return Self.boardJSON([])
        }
        let store = KanbanStore(api: KanbanAPI(client: client), account: client.account, directory: nil)
        _ = try await store.create(title: " Write the release post ", body: "", assignee: nil, priority: 0, skills: [], start: "ready", goalMode: false)
        let post = try #require(client.log.first { $0.method == "POST" && $0.path == "/api/plugins/kanban/tasks" })
        #expect(post.body == ["title": "Write the release post", "priority": 0, "triage": false, "goal_mode": false])
        #expect(!client.log.contains { $0.method == "PATCH" }, "it landed where asked")
        #expect(store.pickedChip == "ready")
    }
}
