import Foundation
import Testing
@testable import HermesHQNative

/// [coding-pr-review] Owner 2026-11-21 (option B of artifacts/coding-pr-review/mock1.html).
@Suite struct CodingPRReviewTests {
    // MARK: Step 1: no pin in a project page's Pinned pile

    @Test func aPinnedPileDrawsNoPin() {
        // A project page's Pinned pile: none, pinned everywhere or in the project.
        #expect(!SessionRowView.drawsPin(pinned: true, compact: false, fresh: .recent, pinnedPile: true))
        #expect(!SessionRowView.drawsPin(pinned: true, compact: false, fresh: nil, pinnedPile: true))
        // Done (an archived pinned chat) and any other pile keep it.
        #expect(SessionRowView.drawsPin(pinned: true, compact: false, fresh: .recent, pinnedPile: false))
        #expect(SessionRowView.drawsPin(pinned: true, compact: false, fresh: nil, pinnedPile: false))
        // The main list's own Pinned rows, as before.
        #expect(!SessionRowView.drawsPin(pinned: true, compact: true, fresh: nil, pinnedPile: false))
        #expect(!SessionRowView.drawsPin(pinned: true, compact: false, fresh: .pinned, pinnedPile: false))
        #expect(!SessionRowView.drawsPin(pinned: false, compact: false, fresh: nil, pinnedPile: false))
    }

    // MARK: Step 2: zero PR counts hide

    @Test func zeroCountsAreNotDrawnUnlessPicked() {
        let counts: [SessionPRStatus.State: Int] = [.none: 1, .merged: 2, .draft: 0]
        #expect(ProjectPageHeader.shownPRStates(counts, selected: nil) == [.none, .merged])
        // A picked state at zero stays, in its place, so the filter can be cleared.
        #expect(ProjectPageHeader.shownPRStates(counts, selected: .open) == [.none, .open, .merged])
        #expect(ProjectPageHeader.shownPRStates(counts, selected: .merged) == [.none, .merged])
        // Nothing to draw: the line is absent.
        #expect(ProjectPageHeader.shownPRStates([:], selected: nil).isEmpty)
        #expect(ProjectPageHeader.shownPRStates([.open: 0, .closed: 0], selected: nil).isEmpty)
        // The order is the line's own whatever the dictionary's.
        #expect(ProjectPageHeader.shownPRStates([.closed: 1, .draft: 3, .open: 2, .none: 4, .merged: 5], selected: nil)
                == [.none, .draft, .open, .merged, .closed])
    }

    // MARK: Step 3: the PR card

    private static let link24 = URL(string: "https://github.com/example/app/pull/24")!

    private func card(_ status: SessionPRStatus?, focus: PullRequestCard.Focus = .lead) -> PullRequestCard? {
        PullRequestCard(status: status, focus: focus, chatTitle: "Fix reconnect crash", botName: "Otto")
    }

    private func merges(_ card: PullRequestCard?) -> [String] {
        (card?.actions ?? []).compactMap { if case .askToMerge(let words) = $0 { words } else { nil } }
    }

    private func links(_ card: PullRequestCard?) -> [URL] {
        (card?.actions ?? []).compactMap { if case .openOnGitHub(let url) = $0 { url } else { nil } }
    }

    @Test func noMarkNoCard() {
        #expect(card(nil) == nil)
        #expect(card(SessionPRStatus(state: .none, repo: "example/app")) == nil)
    }

    @Test func aDraftBranchWithoutANumber() throws {
        let draft = try #require(card(SessionPRStatus(state: .draft, repo: "example/app", branch: "fix/reconnect-crash")))
        #expect(draft.title == "Branch")
        #expect(draft.stateWords == "Draft" && draft.markState == .draft)
        #expect(draft.name == "Fix reconnect crash")
        #expect(draft.place == "example/app · fix/reconnect-crash")       // no base yet: no arrow
        #expect(links(draft).isEmpty)
        #expect(merges(draft) == ["Merge the branch fix/reconnect-crash."])
        #expect(draft.mergeTitle == "Ask Otto to Merge…")
        #expect(draft.others.isEmpty)
        // Nothing to name: no merge.
        #expect(merges(card(SessionPRStatus(state: .draft))).isEmpty)
    }

    @Test func anOpenPullRequestWithALink() throws {
        let open = try #require(card(SessionPRStatus(state: .open, repo: "example/app", branch: "fix/reconnect-crash", number: 24, url: Self.link24)))
        #expect(open.title == "Pull Request")
        #expect(open.stateWords == "Open #24")
        #expect(open.actions == [.openOnGitHub(Self.link24), .askToMerge(words: "Merge pull request #24.")])
    }

    @Test func mergedHasTheLinkOnly() throws {
        let merged = try #require(card(SessionPRStatus(state: .merged, repo: "example/app", number: 23,
                                                        url: URL(string: "https://github.com/example/app/pull/23"))))
        #expect(merged.stateWords == "Merged #23" && merged.title == "Pull Request")
        #expect(merges(merged).isEmpty && links(merged).count == 1)
        #expect(merged.place == "example/app")
    }

    @Test func ownerClosedOffersNoMerge() throws {
        let items = [SessionPRItem(state: .open, repo: "example/app", number: 24, url: Self.link24, source: .github)]
        let closed = try #require(card(SessionPRStatus(state: .closed, repo: "example/app", number: 24, url: Self.link24, manual: true, items: items)))
        #expect(closed.stateWords == "Closed, marked by you" && closed.markState == .closed)
        #expect(merges(closed).isEmpty)
        #expect(links(closed) == [Self.link24])
    }

    @Test func severalItemsListTheOthers() throws {
        let link40 = URL(string: "https://github.com/example/app/pull/40")!
        let status = SessionPRStatus(state: .open, repo: "example/app", number: 44, url: URL(string: "https://github.com/example/app/pull/44"), items: [
            SessionPRItem(state: .open, repo: "example/app", number: 44, url: URL(string: "https://github.com/example/app/pull/44"), source: .github),
            SessionPRItem(state: .draft, branch: "feature/release-notes", source: .git),
            SessionPRItem(state: .merged, repo: "example/app", number: 40, url: link40, source: .github)])
        let lead = try #require(card(status))
        #expect(lead.stateWords == "Open #44")
        #expect(lead.others.map(\.label) == ["Draft · feature/release-notes", "Merged #40"])
        #expect(lead.others.map(\.focus) == [.item(1), .item(2)])
        let branch = try #require(card(status, focus: .item(1)))
        #expect(branch.title == "Branch" && branch.stateWords == "Draft")
        #expect(merges(branch) == ["Merge the branch feature/release-notes."])
        #expect(branch.others.map(\.label) == ["Open #44", "Merged #40"])
        let merged = try #require(card(status, focus: .item(2)))
        #expect(merged.actions == [.openOnGitHub(link40)])
        // A place past the list falls back to the lead.
        #expect(card(status, focus: .item(9))?.focus == .lead)
        // One item only: no "Also in This Chat".
        #expect(card(SessionPRStatus(state: .open, number: 44, items: [SessionPRItem(state: .open, number: 44, source: .github)]))?.others.isEmpty == true)
    }

    @Test func mergeWords() {
        #expect(PullRequestCard.mergeWords(number: 24, branch: "fix/x", base: "main") == "Merge pull request #24.")
        #expect(PullRequestCard.mergeWords(number: nil, branch: "fix/x", base: "main") == "Merge the branch fix/x into main.")
        #expect(PullRequestCard.mergeWords(number: nil, branch: "fix/x", base: nil) == "Merge the branch fix/x.")
        #expect(PullRequestCard.mergeWords(number: nil, branch: "fix/x", base: " ") == "Merge the branch fix/x.")
        #expect(PullRequestCard.mergeWords(number: nil, branch: nil, base: "main") == nil)
    }

    // MARK: Step 4: the wire's new facts and the verdict

    private func parse(_ text: String) throws -> JSONValue { try JSONValue.parse(Data(text.utf8)) }

    private func answer(_ text: String, detail: Bool = false) throws -> SessionPRStatus {
        let value = try parse(text)
        let state = value["state"]?.string.flatMap(SessionPRStatus.State.init(rawValue:)) ?? .unknown
        return SessionStore.prStatus(value, state: state, detail: detail)
    }

    /// The contract's own example, whole.
    private static let example = """
    {"profile": "deploys", "id": "s-release", "state": "open", "repo": "example/app", "branch": "fix/reconnect-crash",
     "number": 24, "url": "https://github.com/example/app/pull/24",
     "size": {"files": 4, "additions": 128, "deletions": 12},
     "checks": {"state": "passed", "passed": 5, "failed": 0, "running": 0},
     "title": "Fix reconnect crash", "base": "main",
     "items": [{"state": "open", "repo": "example/app", "branch": "fix/reconnect-crash", "number": 24,
       "url": "https://github.com/example/app/pull/24", "source": "github",
       "size": {"files": 4, "additions": 128, "deletions": 12},
       "checks": {"state": "passed", "passed": 5, "failed": 0, "running": 0, "runs": [{"name": "unit", "state": "passed"}]},
       "title": "Fix reconnect crash", "base": "main",
       "files": [{"path": "App/Net/Reconnect.swift", "additions": 96, "deletions": 8,
                  "patch": "@@ -10,3 +10,4 @@\\n context\\n-old\\n+new\\n+more"}]}]}
    """

    @Test func theContractsExampleDecodes() throws {
        let plain = try answer(Self.example)
        #expect(plain.size == SessionPRSize(files: 4, additions: 128, deletions: 12))
        #expect(plain.checks == SessionPRChecks(state: .passed, passed: 5, failed: 0, running: 0))
        #expect(plain.title == "Fix reconnect crash" && plain.base == "main")
        let item = try #require(plain.items?.first)
        #expect(item.size == plain.size && item.title == "Fix reconnect crash" && item.base == "main")
        // Without detail: no runs, no files, even when sent.
        #expect(item.checks?.runs == nil && item.files == nil)
        let detailed = try #require(try answer(Self.example, detail: true).items?.first)
        #expect(detailed.checks?.runs == [SessionPRChecks.Run(name: "unit", state: .passed)])
        #expect(detailed.files == [SessionPRFile(path: "App/Net/Reconnect.swift", additions: 96, deletions: 8,
                                                 patch: "@@ -10,3 +10,4 @@\n context\n-old\n+new\n+more")])
        // The top level never carries runs.
        #expect(try answer(Self.example, detail: true).checks?.runs == nil)
    }

    @Test func absentKeysAreNotKnownNeverZero() throws {
        let old = try answer(#"{"state": "open", "repo": "example/app", "number": 24, "items": [{"state": "open", "number": 24, "source": "github"}]}"#,
                             detail: true)
        #expect(old.size == nil && old.checks == nil && old.title == nil && old.base == nil)
        let item = try #require(old.items?.first)
        #expect(item.size == nil && item.checks == nil && item.title == nil && item.base == nil && item.files == nil)
        #expect(PRVerdict.of(old) == nil)
        // The rest of the answer is today's.
        #expect(old.state == .open && old.number == 24 && old.repo == "example/app")
    }

    @Test func aBadKeyDropsOnlyItself() throws {
        let bad = try answer("""
        {"state": "open", "number": 24, "title": 7, "base": ["main"],
         "size": {"files": 4, "additions": -1, "deletions": 12},
         "checks": {"state": "green", "passed": 5, "failed": 0, "running": 0}}
        """)
        #expect(bad.size == nil && bad.checks == nil && bad.title == nil && bad.base == nil)
        #expect(bad.state == .open && bad.number == 24)
        // A count as a string or a fraction is not one; a missing count drops the key.
        #expect(PRFacts.size(try parse(#"{"files": "4", "additions": 1, "deletions": 0}"#)) == nil)
        #expect(PRFacts.size(try parse(#"{"files": 4.5, "additions": 1, "deletions": 0}"#)) == nil)
        #expect(PRFacts.size(try parse(#"{"files": 4, "additions": 1}"#)) == nil)
        #expect(PRFacts.size(try parse(#"{"files": 0, "additions": 0, "deletions": 0}"#)) == SessionPRSize(files: 0, additions: 0, deletions: 0))
        #expect(PRFacts.checks(try parse(#"{"state": "failed", "passed": 1, "failed": -2, "running": 0}"#), runs: false) == nil)
        #expect(PRFacts.checks(try parse(#"{"state": "passed", "passed": 0, "failed": 0, "running": 0}"#), runs: false) == nil)
        // Unknown keys are ignored.
        #expect(PRFacts.checks(try parse(#"{"state": "running", "passed": 1, "failed": 0, "running": 2, "extra": true}"#), runs: false)
                == SessionPRChecks(state: .running, passed: 1, failed: 0, running: 2))
        // Title: trimmed, at most 200; blank is none. Base: blank is none.
        #expect(PRFacts.title(.string("  Fix it  ")) == "Fix it")
        #expect(PRFacts.title(.string(String(repeating: "a", count: 250)))?.count == 200)
        #expect(PRFacts.title(.string("   ")) == nil && PRFacts.base(.string("")) == nil)
    }

    @Test func runsAndFilesReadEntryByEntry() throws {
        let checks = try #require(PRFacts.checks(try parse("""
        {"state": "failed", "passed": 3, "failed": 2, "running": 0,
         "runs": [{"name": "lint", "state": "failed"}, {"name": "", "state": "failed"}, {"name": "unit", "state": "flaky"},
                  {"name": "ui", "state": "failed"}, {"name": 4, "state": "passed"}, {"name": "build", "state": "passed"}]}
        """), runs: true))
        #expect(checks.runs?.map(\.name) == ["lint", "ui", "build"])
        #expect(PRFacts.checks(try parse(#"{"state": "passed", "passed": 1, "failed": 0, "running": 0, "runs": "x"}"#), runs: true)?.runs == nil)
        let files = try #require(PRFacts.files(try parse("""
        [{"path": "a.swift", "additions": 1, "deletions": 0, "patch": "@@ -1 +1 @@\\n+x"},
         {"path": "logo.png", "additions": 0, "deletions": 0, "binary": true, "patch": "ignored"},
         {"path": "big.json", "additions": 900, "deletions": 0, "patch_cut": true},
         {"path": "", "additions": 1, "deletions": 1},
         {"path": "b.swift", "additions": -1, "deletions": 0}]
        """)))
        #expect(files.map(\.path) == ["a.swift", "logo.png", "big.json"])
        #expect(files[0].patch == "@@ -1 +1 @@\n+x" && !files[0].binary && !files[0].patchCut)
        #expect(files[1].binary && files[1].patch == nil && !files[1].patchCut)
        #expect(files[2].patchCut && files[2].patch == nil)
        let many = JSONValue.array((0..<60).map { .object(["path": .string("f\($0)"), "additions": .number(1), "deletions": .number(0)]) })
        #expect(PRFacts.files(many)?.count == 50)
    }

    @Test func theMarksCacheKeepsFactsButNotRunsOrFiles() throws {
        // A file from before the facts loads.
        let old = #"{"at": 1, "marks": {"deploys:s-release": {"state": "open", "number": 24, "items": [{"state": "open", "number": 24, "source": "github"}]}}}"#
        let file = try JSONDecoder().decode(SessionMarksCacheFile.self, from: Data(old.utf8))
        let mark = try #require(file.marks["deploys:s-release"])
        #expect(mark.size == nil && mark.checks == nil && mark.title == nil && mark.base == nil)
        let oldItem = try #require(mark.items?.first.flatMap(SessionStore.prItem))
        #expect(oldItem.size == nil && oldItem.checks == nil)
        // The facts round-trip; the runs are not kept.
        let checks = SessionPRChecks(state: .failed, passed: 3, failed: 2, running: 0, runs: [.init(name: "lint", state: .failed)])
        let kept = SessionMarksCacheFile.Mark.Item(state: "open", number: 24, source: "github",
                                                   size: SessionPRSize(files: 4, additions: 128, deletions: 12),
                                                   checks: .init(checks), title: "Fix reconnect crash", base: "main")
        let data = try JSONEncoder().encode(kept)
        #expect(!String(decoding: data, as: UTF8.self).contains("lint"))
        let back = try #require(SessionStore.prItem(try JSONDecoder().decode(SessionMarksCacheFile.Mark.Item.self, from: data)))
        #expect(back.size == SessionPRSize(files: 4, additions: 128, deletions: 12))
        #expect(back.checks == SessionPRChecks(state: .failed, passed: 3, failed: 2, running: 0))
        #expect(back.title == "Fix reconnect crash" && back.base == "main" && back.files == nil)
        // A cached checks with an unknown state or a negative count reads as none.
        #expect(SessionMarksCacheFile.Mark.Checks(SessionPRChecks(state: .passed, passed: 1, failed: 0, running: 0)).checks != nil)
        var wrong = SessionMarksCacheFile.Mark.Checks(SessionPRChecks(state: .passed, passed: 1, failed: 0, running: 0))
        wrong.state = "green"
        #expect(wrong.checks == nil)
        wrong.state = "passed"; wrong.passed = -1
        #expect(wrong.checks == nil)
    }

    @Test func theVerdictPerCase() {
        let size = SessionPRSize(files: 4, additions: 128, deletions: 12)
        func verdict(_ state: SessionPRStatus.State = .open, size: SessionPRSize? = nil, checks: SessionPRChecks? = nil,
                     manual: Bool = false) -> PRVerdict? {
            PRVerdict.of(SessionPRStatus(state: state, number: 24, manual: manual, size: size, checks: checks))
        }
        let passed = SessionPRChecks(state: .passed, passed: 5, failed: 0, running: 0)
        let failing = SessionPRChecks(state: .failed, passed: 3, failed: 2, running: 0)
        let one = SessionPRChecks(state: .failed, passed: 4, failed: 1, running: 0)
        let running = SessionPRChecks(state: .running, passed: 2, failed: 0, running: 3)
        // Checks passed and a size: ✓ +128 −12 (U+2212).
        #expect(verdict(size: size, checks: passed) == .passed(size))
        #expect(verdict(size: size, checks: passed)?.words == "+128 \u{2212}12")
        #expect(verdict(size: size, checks: passed)?.spoken == "Checks passed, 128 lines added, 12 removed")
        // Failing: the count, singular too.
        #expect(verdict(size: size, checks: failing)?.words == "2 checks failing")
        #expect(verdict(checks: one)?.words == "1 check failing" && verdict(checks: one)?.spoken == "1 check failing")
        // Running.
        #expect(verdict(size: size, checks: running)?.words == "checks running")
        #expect(verdict(checks: running)?.spoken == "Checks running")
        // No checks, a size.
        let other = SessionPRSize(files: 9, additions: 212, deletions: 40)
        #expect(verdict(.draft, size: other) == .size(other))
        #expect(verdict(.draft, size: other)?.words == "+212 \u{2212}40")
        #expect(verdict(.draft, size: other)?.spoken == "212 lines added, 40 removed")
        // Checks passed, no size: the mark alone.
        #expect(verdict(checks: passed) == .passed(nil) && verdict(checks: passed)?.words == nil)
        #expect(verdict(checks: passed)?.spoken == "Checks passed")
        // None of it, or a state that draws none, or the owner's Closed mark: nothing.
        #expect(verdict() == nil)
        for state in [SessionPRStatus.State.merged, .closed, .none, .unknown] {
            #expect(verdict(state, size: size, checks: passed) == nil, "\(state)")
        }
        #expect(verdict(size: size, checks: passed, manual: true) == nil)
        #expect(PRVerdict.spokenSize(SessionPRSize(files: 1, additions: 1, deletions: 1)) == "1 line added, 1 removed")
    }

    @Test func theCardNamesTheTitleAndBase() throws {
        let status = SessionPRStatus(state: .open, repo: "example/app", branch: "fix/reconnect-crash", number: 24, url: Self.link24,
                                     title: "Fix the reconnect crash", base: "main")
        let open = try #require(card(status))
        #expect(open.name == "Fix the reconnect crash")
        #expect(open.place == "example/app · fix/reconnect-crash \u{2192} main")
        let branch = try #require(card(SessionPRStatus(state: .draft, repo: "example/app", branch: "fix/x", base: "main")))
        #expect(merges(branch) == ["Merge the branch fix/x into main."])
        #expect(branch.name == "Fix reconnect crash")       // no title: the chat's
        // The lead's facts come from its entry when the chat lists several.
        let listed = SessionPRStatus(state: .open, number: 24, items: [
            SessionPRItem(state: .open, number: 24, source: .github, title: "From the item", base: "release"),
            SessionPRItem(state: .draft, branch: "feature/y", source: .git)])
        #expect(card(listed)?.name == "From the item")
        #expect(merges(card(listed, focus: .item(1))) == ["Merge the branch feature/y."])
    }

    @Test func theListsSpokenLabelGainsTheVerdict() {
        var session = SessionSummary(id: "s-garden", profile: "default", title: "Garden plan", preview: nil, lastActive: nil,
                                     source: nil, unread: false, isRunning: false)
        session.pullRequest = SessionPRStatus(state: .open, number: 24, size: SessionPRSize(files: 1, additions: 3, deletions: 1),
                                              checks: SessionPRChecks(state: .failed, passed: 1, failed: 2, running: 0))
        let label = SessionRowWords.accessibilityLabel(title: "Garden plan", session: session, ownerName: "Otto", detail: [], time: "",
                                                       snippet: nil, colorName: nil, busy: false, muted: false, showPR: true)
        #expect(label.contains("2 checks failing"))
        let plain = SessionRowWords.accessibilityLabel(title: "Garden plan", session: session, ownerName: "Otto", detail: [], time: "",
                                                       snippet: nil, colorName: nil, busy: false, muted: false, showPR: false)
        #expect(!plain.contains("checks"))
    }

    // MARK: Step 5: the card's Checks and Changes

    private func detailed(_ state: SessionPRStatus.State = .open, number: Int? = 24, checks: SessionPRChecks? = nil,
                          size: SessionPRSize? = nil, files: [SessionPRFile]? = nil, manual: Bool = false) -> PullRequestCard? {
        let item = SessionPRItem(state: state, repo: "example/app", branch: "fix/reconnect-crash", number: number, url: Self.link24,
                                 source: .github, size: size, checks: checks, files: files)
        return card(SessionPRStatus(state: state, repo: "example/app", branch: "fix/reconnect-crash", number: number, url: Self.link24,
                                    manual: manual, items: [item], size: size, checks: checks))
    }

    @Test func theChecksRowWords() throws {
        let runs = [SessionPRChecks.Run(name: "lint", state: .failed), .init(name: "unit", state: .passed)]
        #expect(detailed(checks: .init(state: .passed, passed: 5, failed: 0, running: 0))?.checksRow
                == .init(words: "5 checks passed", state: .passed, runs: nil))
        #expect(detailed(checks: .init(state: .passed, passed: 1, failed: 0, running: 0))?.checksRow?.words == "1 check passed")
        #expect(detailed(checks: .init(state: .failed, passed: 3, failed: 2, running: 0, runs: runs))?.checksRow
                == .init(words: "2 of 5 checks failing", state: .failed, runs: runs))
        #expect(detailed(checks: .init(state: .running, passed: 2, failed: 0, running: 3))?.checksRow?.words == "3 of 5 checks running")
        // An empty runs list pushes nothing; no checks, no section.
        #expect(detailed(checks: .init(state: .passed, passed: 1, failed: 0, running: 0, runs: []))?.checksRow?.runs == nil)
        #expect(detailed()?.checksRow == nil)
        #expect(detailed(.merged, checks: .init(state: .passed, passed: 1, failed: 0, running: 0))?.checksRow == nil)
    }

    @Test func theChangesSection() throws {
        let files = [SessionPRFile(path: "App/Net/Reconnect.swift", additions: 96, deletions: 8, patch: "@@ -1 +1 @@\n-a\n+b"),
                     SessionPRFile(path: "CHANGELOG.md", additions: 1, deletions: 0, patchCut: true),
                     SessionPRFile(path: "Assets/logo.png", additions: 0, deletions: 0, binary: true),
                     SessionPRFile(path: "README.md", additions: 2, deletions: 2)]
        let changes = try #require(detailed(size: SessionPRSize(files: 7, additions: 128, deletions: 12), files: files))
        #expect(changes.changesLabel == "Changes · 7 files · +128 \u{2212}12")
        let rows = changes.fileRows
        #expect(rows.map(\.name) == ["Reconnect.swift", "CHANGELOG.md", "logo.png", "README.md"])
        #expect(rows.map(\.folder) == ["App/Net", nil, "Assets", nil])
        #expect(rows.map(\.counts) == ["+96 \u{2212}8", "+1 \u{2212}0", nil, "+2 \u{2212}2"])
        #expect(rows[0].body == .patch("@@ -1 +1 @@\n-a\n+b") && rows[0].note == nil)
        #expect(rows[1].body == .tooLarge && rows[1].note == "Too large to show here")
        #expect(rows[2].body == .binary && rows[2].note == "Binary file")
        #expect(rows[3].body == .none && rows[3].note == nil)
        #expect(changes.moreFiles == 3 && changes.moreFilesWords == "and 3 more files")
        #expect(detailed(size: SessionPRSize(files: 5, additions: 1, deletions: 0), files: files)?.moreFilesWords == "and 1 more file")
        #expect(detailed(size: SessionPRSize(files: 4, additions: 1, deletions: 0), files: files)?.moreFilesWords == nil)
        // Files without a size: "Changes" alone. A size without files (no detail yet): no section.
        #expect(detailed(files: files)?.changesLabel == "Changes" && detailed(files: files)?.moreFiles == 0)
        #expect(detailed(size: SessionPRSize(files: 4, additions: 1, deletions: 0))?.changesLabel == nil)
        #expect(detailed(size: SessionPRSize(files: 4, additions: 1, deletions: 0), files: [])?.changesLabel == nil)
        #expect(detailed(size: SessionPRSize(files: 1, additions: 1, deletions: 0), files: [files[3]])?.changesLabel == "Changes · 1 file · +1 \u{2212}0")
    }

    @Test func fixChecksWhileFailing() throws {
        let failing = SessionPRChecks(state: .failed, passed: 3, failed: 2, running: 0)
        let open = try #require(detailed(checks: failing))
        #expect(open.fixChecksWords == "The checks on pull request #24 are failing. Fix them.")
        #expect(open.fixChecksTitle == "Ask Otto to Fix Checks…")
        #expect(open.actions == [.openOnGitHub(Self.link24), .askToFixChecks(words: "The checks on pull request #24 are failing. Fix them."),
                                 .askToMerge(words: "Merge pull request #24.")])
        #expect(detailed(checks: .init(state: .passed, passed: 5, failed: 0, running: 0))?.fixChecksWords == nil)
        #expect(detailed(checks: .init(state: .running, passed: 1, failed: 0, running: 1))?.fixChecksWords == nil)
        #expect(detailed(checks: failing, manual: true)?.fixChecksWords == nil)
        #expect(detailed(number: nil, checks: failing)?.fixChecksWords == nil)
    }

    @Test func aFreshAnswerReplacesUnlessTheCodeIsGone() {
        let old = SessionPRStatus(state: .open, number: 24)
        let new = SessionPRStatus(state: .open, number: 24, checks: .init(state: .passed, passed: 1, failed: 0, running: 0))
        #expect(PullRequestCard.refreshed(old, with: new) == new)
        #expect(PullRequestCard.refreshed(old, with: nil) == old)
        #expect(PullRequestCard.refreshed(old, with: SessionPRStatus(state: .none)) == old)
        #expect(PullRequestCard.refreshed(old, with: SessionPRStatus(state: .unknown)) == old)
    }

    // MARK: Trust & Reliability Improvements

    @Test func unknownReasonsDistinguishCheckingFromRealErrors() {
        let checking = SessionPRStatus(state: .unknown, unknownReason: .checking)
        #expect(checking.isPendingCheck && !checking.drawsMark)
        for reason: SessionPRStatus.UnknownReason in [.unavailable, .unsupported, .unmatched] {
            let status = SessionPRStatus(state: .unknown, unknownReason: reason)
            #expect(!status.isPendingCheck && status.drawsMark)
            #expect(!status.unknownExplanation.isEmpty)
        }
        #expect(!SessionPRStatus(state: .none).drawsMark)
        #expect(SessionPRStatus(state: .open, number: 1).drawsMark)
    }

    @Test func manualClosedAppliesToLeadOnlyAndWarningsCoverRiskyMerges() throws {
        let link24 = Self.link24
        let link25 = URL(string: "https://github.com/example/app/pull/25")!
        let status = SessionPRStatus(
            state: .closed, repo: "example/app", number: 24, url: link24, manual: true,
            items: [
                SessionPRItem(state: .open, repo: "example/app", number: 24, url: link24, source: .github),
                SessionPRItem(state: .open, repo: "example/app", number: 25, url: link25, source: .github,
                              checks: .init(state: .failed, passed: 1, failed: 1, running: 0))
            ]
        )
        let lead = try #require(card(status, focus: .lead))
        #expect(lead.isLeadManual && merges(lead).isEmpty && lead.markClosedToggle == false)
        // Secondary item is NOT manually closed, so its actions stay available.
        let second = try #require(card(status, focus: .item(1)))
        #expect(!second.isLeadManual)
        #expect(merges(second) == ["Merge pull request #25."])
        #expect(second.fixChecksWords == "The checks on pull request #25 are failing. Fix them.")
        #expect(second.mergeConfirmTitle(chatWorking: false) == "Checks Are Failing — Merge Anyway?")

        let draft = try #require(card(SessionPRStatus(state: .draft, repo: "example/app", branch: "feat/x", number: 9)))
        #expect(draft.mergeConfirmTitle(chatWorking: false) == "Merge Draft Pull Request?")
        let open = try #require(card(SessionPRStatus(state: .open, repo: "example/app", number: 24)))
        #expect(open.mergeConfirmTitle(chatWorking: false) == "Ask Otto to Merge")
        #expect(open.mergeConfirmTitle(chatWorking: true) == "Otto Is Still Working — Merge?")
    }

    @Test func mergedPRCanShowChangesAndRunsParseUrlAndSummary() throws {
        let files = [SessionPRFile(path: "App/Foo.swift", additions: 5, deletions: 2, patch: "@@ -1 +1 @@\n-a\n+b")]
        let merged = try #require(detailed(.merged, size: SessionPRSize(files: 1, additions: 5, deletions: 2), files: files))
        #expect(merged.fileRows.count == 1)
        #expect(merged.changesLabel == "Changes · 1 file · +5 \u{2212}2")
        #expect(merged.checksRow == nil)

        let checks = try #require(PRFacts.checks(try parse("""
        {"state": "failed", "passed": 1, "failed": 1, "running": 0,
         "runs": [
           {"name": "unit", "state": "failed", "url": "https://github.com/example/app/actions/runs/9", "summary": "2 assertions failed"},
           {"name": "bad-link", "state": "passed", "url": "https://evil.example/runs/1", "summary": "  "}
         ]}
        """), runs: true))
        let runs = try #require(checks.runs)
        #expect(runs.count == 2)
        #expect(runs[0].url?.absoluteString == "https://github.com/example/app/actions/runs/9")
        #expect(runs[0].summary == "2 assertions failed")
        #expect(runs[1].url == nil && runs[1].summary == nil)
    }

    @Test func countedStatesFallsBackWhenItemsAreAllNone() {
        let status = SessionPRStatus(state: .none, items: [SessionPRItem(state: .none, source: .git)])
        #expect(status.countedStates == [SessionPRStatus.State.none])
    }
}
