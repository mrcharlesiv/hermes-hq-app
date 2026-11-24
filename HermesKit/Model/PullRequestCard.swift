// [coding-pr-review] Owner 2026-11-21 (option B of artifacts/coding-pr-review/mock1.html, its fourth column): a coding
// row's PR mark opens the PR card, a sheet that says where the chat's code stands. What it shows is decided here, apart
// from the drawing, so each state's sections and actions are tested (Tests/Sessions/CodingPRReviewTests.swift).
//
//   state line   the state's glyph and its words ("Open #24", "Draft", "Merged #23")
//   name         the pull request's title (the add-on's `title`), else the chat's title
//   place        repo · branch → base, each part only when known
//   Checks, Changes   from a `detail: true` answer (PullRequestCardDetail.swift), only with their data
//   Actions      Open on GitHub (a link), Ask <bot> to Fix Checks… (failing), Ask <bot> to Merge… (draft or open,
//                not marked closed by the owner)
//   Also in This Chat   every other pull request or branch of the chat (more than one listed)

import Foundation

nonisolated struct PullRequestCard: Hashable, Sendable {
    /// Which of the chat's pull requests or branches the card shows: the lead (the answer the row's mark draws), or one
    /// of `items` by its place in the list.
    enum Focus: Hashable, Sendable {
        case lead
        case item(Int)
    }

    enum Action: Hashable, Sendable {
        case openOnGitHub(URL)
        /// Ask the chat's bot to merge: the words a confirmation shows, then sends to the chat.
        case askToMerge(words: String)
        /// [pr-card-detail] While checks fail: ask the bot to fix them (the same confirmation and send).
        case askToFixChecks(words: String)
    }

    /// One other pull request or branch of the chat ("Also in This Chat").
    struct Other: Hashable, Sendable {
        var focus: Focus
        var state: SessionPRStatus.State
        var label: String
    }

    let status: SessionPRStatus
    let focus: Focus
    /// What the card is about: the lead or the focused item, as one item.
    let shown: SessionPRItem
    let chatTitle: String
    let botName: String

    /// No card where the row draws no mark (no status, or no code changes).
    init?(status: SessionPRStatus?, focus: Focus = .lead, chatTitle: String, botName: String) {
        guard let status, status.state != .none else { return nil }
        let items = status.items ?? []
        var resolved = focus
        if case .item(let index) = focus, !items.indices.contains(index) { resolved = .lead }
        let shown: SessionPRItem
        switch resolved {
        case .item(let index): shown = items[index]
        case .lead: shown = Self.lead(of: status)
        }
        // An item whose state is "none" draws no mark of its own either.
        if shown.state == .none { return nil }
        self.status = status
        self.focus = resolved
        self.shown = shown
        self.chatTitle = chatTitle
        self.botName = botName
    }

    /// The lead as an item: the entry of `items` that matches the top-level answer (same number, else same repo and
    /// branch), whose facts it takes; else the top-level answer itself.
    static func lead(of status: SessionPRStatus) -> SessionPRItem {
        if let index = leadIndex(of: status), let item = status.items?[index] { return item }
        return SessionPRItem(state: status.state, repo: status.repo, branch: status.branch, number: status.number, url: status.url,
                             source: status.number != nil ? .github : .git,
                             size: status.size, checks: status.checks, title: status.title, base: status.base)
    }

    /// The place in `items` of the entry the top-level answer was picked from (the contract's rule), if any.
    static func leadIndex(of status: SessionPRStatus) -> Int? {
        guard let items = status.items, !items.isEmpty else { return nil }
        if let number = status.number, let index = items.firstIndex(where: { $0.number == number }) { return index }
        if status.number == nil, let branch = status.branch,
           let index = items.firstIndex(where: { $0.number == nil && $0.branch == branch && $0.repo == status.repo }) { return index }
        return nil
    }

    /// The sheet's title: "Pull Request", or "Branch" when there is no number.
    var title: String { shown.number == nil ? "Branch" : "Pull Request" }

    /// Whether the owner's manual Closed mark applies to the focused item (the lead only, never secondary items).
    var isLeadManual: Bool { (focus == .lead || focus == Self.leadFocus(status)) && status.manual }

    /// The state's words. The owner's own Closed mark on the lead says so.
    var stateWords: String {
        if isLeadManual { return "Closed, marked by you" }
        switch shown.state {
        case .unknown: return "Status Unknown"
        default: return shown.status.label
        }
    }

    /// The state the glyph draws: the owner's Closed mark wins on the lead.
    var markState: SessionPRStatus.State {
        isLeadManual ? .closed : shown.state
    }

    /// Plain explanation when the focused status is `.unknown`.
    var unknownNotice: String? {
        guard shown.state == .unknown && !isLeadManual else { return nil }
        return status.unknownExplanation
    }

    /// Whether the owner can mark this chat closed (or reopen it) from the card.
    var markClosedToggle: Bool? {
        guard focus == .lead || focus == Self.leadFocus(status) else { return nil }
        if status.manual { return false }
        let eligible: Set<SessionPRStatus.State> = status.items != nil ? [.draft, .open, .none, .unknown] : [.draft, .none, .unknown]
        return eligible.contains(status.state) ? true : nil
    }

    private static func leadFocus(_ status: SessionPRStatus) -> Focus? { leadIndex(of: status).map { .item($0) } }

    /// The bold name: the pull request's title when the add-on sends one, else the chat's.
    var name: String {
        if let title = shown.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        let chat = chatTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return chat.isEmpty ? "Untitled Chat" : chat
    }

    /// "example/app · fix/reconnect-crash → main", each part only when known (no arrow without a base). nil: nothing.
    var place: String? {
        var parts: [String] = []
        if let repo = shown.repo?.trimmingCharacters(in: .whitespaces), !repo.isEmpty { parts.append(repo) }
        let base = shown.base?.trimmingCharacters(in: .whitespaces) ?? ""
        if let branch = shown.branch?.trimmingCharacters(in: .whitespaces), !branch.isEmpty {
            parts.append(base.isEmpty ? branch : "\(branch) \u{2192} \(base)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var actions: [Action] {
        var out: [Action] = []
        if let url = shown.url { out.append(.openOnGitHub(url)) }
        if let words = fixChecksWords { out.append(.askToFixChecks(words: words)) }
        if [.draft, .open].contains(shown.state), !isLeadManual, let words = Self.mergeWords(number: shown.number, branch: shown.branch, base: shown.base) {
            out.append(.askToMerge(words: words))
        }
        return out
    }

    /// Warning title for the merge confirmation alert when merging now carries risk; nil for a clean open PR.
    func mergeConfirmTitle(chatWorking: Bool = false) -> String {
        if shown.checks?.state == .failed { return "Checks Are Failing — Merge Anyway?" }
        if shown.state == .draft { return shown.number == nil ? "Merge Unopened Branch?" : "Merge Draft Pull Request?" }
        if chatWorking { return "\(botName) Is Still Working — Merge?" }
        return mergeTitle.replacingOccurrences(of: "…", with: "")
    }

    /// "Ask Otto to Merge…"
    var mergeTitle: String { "Ask \(botName) to Merge…" }

    /// The words Ask to Merge sends: "Merge pull request #24." for a pull request with a number, else "Merge the branch
    /// <branch> into <base>." ("Merge the branch <branch>." without a known base). nil: nothing to name.
    static func mergeWords(number: Int?, branch: String?, base: String?) -> String? {
        if let number { return "Merge pull request #\(number)." }
        guard let branch = branch?.trimmingCharacters(in: .whitespaces), !branch.isEmpty else { return nil }
        if let base = base?.trimmingCharacters(in: .whitespaces), !base.isEmpty { return "Merge the branch \(branch) into \(base)." }
        return "Merge the branch \(branch)."
    }

    /// Every other pull request or branch of the chat, in its list's order: only when it lists more than one.
    var others: [Other] {
        guard let items = status.items, items.count > 1 else { return [] }
        let current: Int? = {
            switch focus {
            case .item(let index): return index
            case .lead: return Self.leadIndex(of: status)
            }
        }()
        return items.enumerated().compactMap { index, item in
            guard index != current, item.state != .none else { return nil }
            return Other(focus: .item(index), state: item.state, label: item.label)
        }
    }
}
