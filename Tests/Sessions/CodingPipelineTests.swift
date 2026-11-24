import Foundation
import Testing
@testable import HermesHQNative

@Suite struct CodingPipelineTests {
    private func row(_ id: String, cwd: String = "/app", status: SessionStatus = .idle,
                     running: Bool = false, unread: Bool = false, archived: Bool = false,
                     pinned: Bool = false, pr: SessionPRStatus? = nil,
                     lastActive: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> SessionSummary {
        var s = SessionSummary(id: id, profile: "default", title: id, preview: "preview",
                               lastActive: lastActive, source: nil, unread: unread, isRunning: running)
        s.cwd = cwd
        s.status = status
        s.archived = archived
        s.pinned = pinned
        s.pullRequest = pr
        return s
    }

    @Test func bucketClassifiesEveryCodingStateClearly() {
        let readyPR = SessionPRStatus(state: .open, number: 10, checks: .init(state: .passed, passed: 6, failed: 0, running: 0))
        let readyNoCI = SessionPRStatus(state: .open, number: 11)
        let failingPR = SessionPRStatus(state: .open, number: 12, checks: .init(state: .failed, passed: 2, failed: 1, running: 0))
        let runningPR = SessionPRStatus(state: .open, number: 13, checks: .init(state: .running, passed: 2, failed: 0, running: 1))
        let draftPR = SessionPRStatus(state: .draft, number: 14)
        let mergedPR = SessionPRStatus(state: .merged, number: 15)
        let closedPR = SessionPRStatus(state: .closed, number: 16)
        let unmatchedChat = SessionPRStatus(state: .unknown, unknownReason: .unmatched)

        // Ready to Ship
        #expect(CodingPipeline.bucket(for: row("ready", pr: readyPR)) == .ready)
        #expect(CodingPipeline.bucket(for: row("ready-noci", pr: readyNoCI)) == .ready)
        #expect(CodingPipeline.isReadyToMerge(row("ready", pr: readyPR)))

        // Needs You: needsInput, failing CI, or unread non-ready active reply
        #expect(CodingPipeline.bucket(for: row("ask", status: .needsInput, pr: readyPR)) == .needsYou)
        #expect(CodingPipeline.bucket(for: row("fail", pr: failingPR)) == .needsYou)
        #expect(CodingPipeline.hasFailingChecks(row("fail", pr: failingPR)))
        #expect(CodingPipeline.bucket(for: row("unread-draft", unread: true, pr: draftPR)) == .needsYou)

        // In Flight: working bot (even on an open/merged PR), running checks, quiet draft, plain non-git chat
        #expect(CodingPipeline.bucket(for: row("working-open", running: true, pr: readyPR)) == .inFlight)
        #expect(CodingPipeline.bucket(for: row("working-merged", running: true, pr: mergedPR)) == .inFlight)
        #expect(CodingPipeline.bucket(for: row("running-ci", pr: runningPR)) == .inFlight)
        #expect(CodingPipeline.bucket(for: row("draft", pr: draftPR)) == .inFlight)
        #expect(CodingPipeline.bucket(for: row("chat", pr: unmatchedChat)) == .inFlight)
        #expect(CodingPipeline.bucket(for: row("plain", pr: nil)) == .inFlight)

        // Shipped: quiet merged/closed or archived
        #expect(CodingPipeline.bucket(for: row("merged", pr: mergedPR)) == .shipped)
        #expect(CodingPipeline.bucket(for: row("closed", pr: closedPR)) == .shipped)
        #expect(CodingPipeline.bucket(for: row("archived", archived: true, pr: readyPR)) == .shipped)
    }

    @Test func projectPageUsesShippingPipelineSectionsAndMatchesCountsOneToOne() {
        let projects = ["default": [SessionProject(id: "app", label: "App", root: "/app", paths: ["/app"])]]
        let entries = [SessionProjectEntry(key: "/app", label: "App")]
        let rows = [
            row("r1", pr: SessionPRStatus(state: .open, number: 538, checks: .init(state: .passed, passed: 6, failed: 0, running: 0))),
            row("n1", pr: SessionPRStatus(state: .open, number: 535, checks: .init(state: .failed, passed: 1, failed: 2, running: 0))),
            row("f1", running: true, pr: SessionPRStatus(state: .draft, number: 541)),
            row("c1", pr: SessionPRStatus(state: .unknown, unknownReason: .unmatched)),
            row("s1", pr: SessionPRStatus(state: .merged, number: 532))
        ]
        let archived = [row("s2", archived: true, pr: SessionPRStatus(state: .merged, number: 500))]

        var prefs = SessionsViewPrefs()
        prefs.pills = .projects
        prefs.groupBy = .project
        prefs.projectFilter = ["/app"]

        let input = SessionListInput(live: rows, archived: archived, prefs: prefs, projectsByProfile: projects,
                                     projects: entries, codingProjects: ["/app"])
        let groups = SessionListPipeline.groups(input)
        let sectionTitles = groups.dropFirst().map(\.title)
        #expect(sectionTitles == ["Ready to Ship", "Needs You", "In Flight", "Shipped"])

        // Shipped starts collapsed by default, holding total 2.
        let shipped = groups.first { $0.title == "Shipped" }
        #expect(shipped?.collapsed == true && shipped?.total == 2 && shipped?.sessions.isEmpty == true)

        // Counts match 1-to-1 with filtering to each bucket.
        let counts = CodingPipeline.counts(rows + archived)
        #expect(counts == [.ready: 1, .needsYou: 1, .inFlight: 2, .shipped: 2])

        for bucket in CodingPipelineBucket.allCases {
            var filteredInput = input
            filteredInput.projectPipelineBucket = bucket
            let filteredGroups = SessionListPipeline.groups(filteredInput).dropFirst()
            let displayed = filteredGroups.flatMap(\.sessions)
            #expect(displayed.count == counts[bucket])
            #expect(filteredGroups.allSatisfy { !$0.collapsed })
        }

        // Projects with Sort › By Status or Sort › Newest also honor all 4 pipeline header toggles 1-to-1.
        var byStatusInput = input
        byStatusInput.projectsByStatus = ["/app"]
        #expect(SessionListPipeline.groups(byStatusInput).dropFirst().map(\.title) == ["Ready to Ship", "Needs You", "In Flight", "Shipped"])
        for bucket in CodingPipelineBucket.allCases {
            var f = byStatusInput
            f.projectPipelineBucket = bucket
            #expect(SessionListPipeline.groups(f).dropFirst().flatMap(\.sessions).count == counts[bucket])
        }

        var byNewestInput = input
        byNewestInput.projectsByNewest = ["/app"]
        for bucket in CodingPipelineBucket.allCases {
            var f = byNewestInput
            f.projectPipelineBucket = bucket
            #expect(SessionListPipeline.groups(f).dropFirst().flatMap(\.sessions).count == counts[bucket])
        }
    }

    @Test func diffLinesParseRealLineNumbersAndFormatTargetedComments() {
        let patch = """
        @@ -516,4 +516,6 @@ extension SessionsViewController {
             func projectCodingRows(_ key: String) -> [SessionSummary] {
        -        for row in store.liveRows {
        +        let archived = store.archivedSessions
        +        for row in store.sessions + archived {
                 guard let store else { return [] }
        """
        let lines = PullRequestDiffLines.parse(patch)
        #expect(lines.count == 6)
        #expect(lines[0].kind == .hunk && lines[0].number == nil)
        #expect(lines[1].kind == .context && lines[1].number == 516)
        #expect(lines[2].kind == .removed && lines[2].number == 517)
        #expect(lines[3].kind == .added && lines[3].number == 517)
        #expect(lines[4].kind == .added && lines[4].number == 518)
        #expect(lines[5].kind == .context && lines[5].number == 519)

        let msg = PullRequestDiffLines.commentMessage(path: "App/Sessions/ProjectPage.swift",
                                                      lineNumber: 518,
                                                      codeLine: "+ for row in store.sessions + archived {",
                                                      note: "Also guard outside rows here")
        #expect(msg.contains("App/Sessions/ProjectPage.swift"))
        #expect(msg.contains("line 518"))
        #expect(msg.contains("Also guard outside rows here"))
    }
}
