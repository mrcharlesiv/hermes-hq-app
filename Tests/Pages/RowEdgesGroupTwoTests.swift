// Owner 2026-11-10 (design picks 5, 10, 26): the facts that moved to a row's trailing edge, and the connector row
// that lets its dot say "Connected".

import Foundation
import Testing
@testable import HermesHQNative

@Suite struct RowEdgesGroupTwoTests {
    /// [kanban-edge] The age and the comments are marked for the edges; who and why stay in the flow.
    @Test func aKanbanCardsAgeAndCommentsAreItsEdges() {
        var task = KanbanTask(id: "t1", title: "Approve the notes", status: "blocked")
        task.assignee = "deploys"
        task.commentCount = 2
        let now = Date()
        task.createdAt = now.timeIntervalSince1970 - 3 * 3600
        let bits = KanbanRowModel.bits(task, fallback: "", botName: { $0 ?? "No one" }, now: now)
        #expect(bits.filter { $0.edge == nil }.map(\.text).first == "deploys")
        #expect(bits.contains { $0.edge == nil && $0.alert }, "why it is blocked stays beside who")
        #expect(bits.last?.edge == .comments(2))
        #expect(bits.last?.text == "2 comments", "VoiceOver and the largest text sizes keep the words")
        #expect(bits.filter { $0.edge == .age }.count <= 1)
        task.commentCount = 0
        #expect(!KanbanRowModel.bits(task, fallback: "", botName: { $0 ?? "No one" }, now: now).contains { if case .comments = $0.edge { true } else { false } })
    }

    /// [artifact-rows] The chat and the time apart, saying together what the one line said.
    @Test func anArtifactsChatAndTimeComeApart() {
        let now = Chicago.date(2026, 10, 10, 18, 30)
        let stamp = Chicago.date(2026, 10, 10, 14, 8).timeIntervalSince1970 * 1000
        let parts = ArtifactListWords.parts(sessionTitle: "The 2.4 report", timestamp: stamp, now: now, calendar: Chicago.calendar)
        #expect(parts.chat == "The 2.4 report")
        #expect(parts.when == "2:08 PM")
        #expect(ArtifactListWords.subtitle(sessionTitle: "The 2.4 report", timestamp: stamp, now: now, calendar: Chicago.calendar)
                == "\(parts.chat) · \(parts.when)")
        #expect(ArtifactListWords.parts(sessionTitle: " ", timestamp: stamp, now: now, calendar: Chicago.calendar).chat.isEmpty)
    }

    /// [connector-rows] The row starts at the tool count; every other state keeps its words.
    @Test func aConnectedRowLetsItsDotSaySo() {
        let browser = McpServer(name: "browser", transport: "stdio", enabled: true, source: "plugin", plugin: "hermes-hq-browser",
                                status: "connected", tools: 12)
        #expect(ConnectorRow.shownWords(browser) == "12 tools · Plugin")
        #expect(ConnectorRow.words(browser) == "Connected · 12 tools · Plugin", "what VoiceOver hears")
        var off = McpServer(name: "github", transport: "http", enabled: true, source: "config", plugin: nil, status: "connected", tools: 5)
        #expect(ConnectorRow.shownWords(off) == "5 tools")
        off.enabled = false
        #expect(ConnectorRow.shownWords(off) == "Off")
    }
}
