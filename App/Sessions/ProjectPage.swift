// [project-pills] Owner 2026-11-15: a project pill opens its project as a page (`SessionListPipeline.projectPage`).
// This is the page's header, the list's first row. [projects-switch] Owner 2026-11-15 ("maximizing screen real estate
// and improving visual clarity … less visually stressful"): it is three short lines, not a block: the project's
// name; one quiet line with its folder, the newest chat's branch and the bots that work in it; and
// the three counts as small chips, always in the same places, a zero dimmed (Needs You, New, Working; a tap
// filters the list). No faces here:
// the rows under it carry them (Show › Bot Faces). The chats follow in the list's own rows, by section.
// [project-header-card] Owner 2026-11-16 (a screenshot of a project's page, the header ringed): "This section up here
// needs to have something behind it, like not that takes up any more room, but just kind of makes it feel like that's
// more of its own space … like a card maybe. And it has to work for every theme properly and in every scenario." The
// three lines stand on a card in the project cards' colour (`ProjectCard.fill`, the theme's `groupedCard`), in the same
// height as before: the words keep their column (the rows' edge) and the card reaches out round them. On Soft Cards the
// section already stands on its own soft card, so it draws none (never a card on a card). Where a theme's card is too
// close to its page to part from it, the card steps toward the theme's ink until it does (`cardColour`); the Desktop
// Look outlines it too, as every card there.

import SwiftUI
import UIKit

struct ProjectPageHeader: View {
    var name: String
    /// The project's key: its folder (as the gateway's computer has it).
    var folder: String
    var branch: String?
    /// The bots that work in it, the one with the newest chat first.
    var bots: [String]
    var needs: Int
    var ready: Int
    var working: Int
    var total: Int
    /// A count tapped ("needs", "ready", "working"): the page narrows to those chats, or back to all of them.
    var onJump: (String) -> Void
    /// [page-count-chips] The counts the page is narrowed to (lit): New's narrowing lights Needs You and New.
    var lit: Set<String> = []
    /// [project-header-card] The section stands on a soft card already (Soft Cards, the page's picture showing): no card
    /// of its own.
    var onSoftCard = false
    /// [project-default-bot] Optional bot actions in the header's ⋯; coding settings are always available.
    var menu: BotMenu? = nil
    var coding = false
    var prCounts: [SessionPRStatus.State: Int] = [:]
    var selectedPR: SessionPRStatus.State? = nil
    var onPRPick: (SessionPRStatus.State) -> Void = { _ in }
    var pipelineCounts: [CodingPipelineBucket: Int] = [:]
    var selectedBucket: CodingPipelineBucket? = nil
    var onBucketPick: (CodingPipelineBucket) -> Void = { _ in }
    var onCodingChange: (Bool) -> Void = { _ in }
    /// [project-sort] ⋯ › Sort.
    var sort: ProjectPageSort = .needsMeFirst
    var onSortChange: (ProjectPageSort) -> Void = { _ in }
    /// [project-settings] ⋯ › Project Settings…: the project's own settings, on one page (Pins Stay in Project moved
    /// there from this menu).
    var onSettings: () -> Void = {}
    /// [project-look] The project's emoji and colour, before its name.
    var look = ProjectLook()
    /// [pr-manage] The ⋯'s Repository… (the project's repository on the computer running Hermes); nil on a gateway
    /// that takes no links, and it shows only while Coding Project is on.
    var onRepository: (() -> Void)? = nil
    /// Quiet, actionable setup/error notice shown inside the header card only when something needs attention.
    var codingHealth: CodingHealth? = nil
    var onHealthAction: (() -> Void)? = nil

    struct CodingHealth: Hashable {
        enum Kind: Hashable {
            case unsupported
            case needsRepo
            case unmatched(Int)
            case unavailable
        }
        var kind: Kind
        var message: String
        var actionTitle: String?
    }

    /// [project-default-bot] Owner 2026-11-17: "a project should be able to have a default bot". The bar's Compose
    /// starts the chat with it at once; this menu says which bot that is, changes it, and starts a chat with another.
    struct BotMenu {
        var bots: [(id: String, name: String)]
        /// The default bot; nil asks.
        var usual: String?
        /// A bot's profile, or `ProjectDefaultBot.ask`.
        var onPick: (String) -> Void
        var onNewChatWith: () -> Void
    }

    /// The folder as people write it: a home folder as "~".
    static func shortFolder(_ path: String) -> String {
        guard !path.hasPrefix("id:") else { return "" }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        if (path.hasPrefix("/Users/") || path.hasPrefix("/home/")), parts.count >= 2 {
            return (["~"] + parts.dropFirst(2)).joined(separator: "/")
        }
        return path
    }

    /// "~/site · main · Hermes, Otto": each part only when there is one; past three bots, "and N more".
    static func meta(folder: String, branch: String?, bots: [String]) -> String {
        let who = bots.count > 3 ? bots.prefix(2).joined(separator: ", ") + " and \(bots.count - 2) more" : bots.joined(separator: ", ")
        // [bot-home] Home has no folder: its key ("home") read as one, beside the branch of whichever folder its newest
        // chat ran in. It says what Home is, then whose chats.
        if folder == SessionProjects.homeKey { return ["No project", who].filter { !$0.isEmpty }.joined(separator: " · ") }
        return [shortFolder(folder), branch ?? "", who].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// [project-header-repo] Owner 2026-11-22 (the Repository page on hermes-hq-native, the header still on the folder
    /// the project is named for): "This project folder showing on the project card doesn't match the folder that I'm
    /// pointing the project to". With a repository linked, the header says that folder. The branch beside it is the
    /// newest chat's in the folder it ran in, so it is said only when that is the linked folder.
    static func place(key: String, linked: String?, branch: String?) -> (folder: String, branch: String?) {
        guard let linked = linked.map(SessionStore.tidyFolder), linked.hasPrefix("/"),
              linked != SessionStore.tidyFolder(key) else { return (key, branch) }
        return (linked, nil)
    }

    /// Count verified answers once per project chat, including archived chats. [pr-multi] A chat counts under each
    /// state one of its pull requests or branches is in (a merged one and an open one: under both), so two waiting
    /// in one chat never hide behind one mark; the counts stay counts of chats, as the filter they pick shows chats.
    static func pullRequestCounts(_ rows: [SessionSummary], project: String,
                                  projects: [String: [SessionProject]]) -> [SessionPRStatus.State: Int] {
        var seen = Set<String>()
        var counts: [SessionPRStatus.State: Int] = [:]
        for row in rows {
            guard SessionProjects.key(cwd: row.cwd, profile: row.profile, projectsByProfile: projects) == project,
                  let states = row.pullRequest?.countedStates, !states.isEmpty,
                  seen.insert(SessionListPipeline.key(row)).inserted else { continue }
            for state in states { counts[state, default: 0] += 1 }
        }
        return counts
    }

    private var lead: CGFloat { ProjectCard.gutter }   // [projects-tidy] the list's margin (14 pt on the Mac)

    // MARK: [project-header-card] The card

    /// Draws a card: not on a soft card.
    private var carded: Bool { !onSoftCard }
    /// From the card's edge to the words: the words stay on the rows' edge (`lead`), so the card stands this much
    /// outside it.
    static var cardPad: CGFloat { Theme.isDesktop ? 10 : 12 }
    /// Room inside the card over the name and under the counts.
    static var cardPadV: CGFloat { Theme.isDesktop ? 8 : 10 }
    static var cardRadius: CGFloat { HQShape.radius(18, .card) }
    /// The least contrast (WCAG ratio) between the card and its page: about what iOS's own grouped card has on a white
    /// page (#F2F2F7, 1.11), a little under it.
    nonisolated static let cardLeast = 1.08

    /// [project-header-card] The card's colour: the theme's card (as a project's card), or, where that card is too close
    /// to the page to read as one (14 of the 70 looks in the test, the Desktop Look's and Paper's among them), the card
    /// stepped toward the theme's own ink, a percent at a time, until it stands apart. It keeps the theme's hue.
    nonisolated static func cardColour(page: RGBA, card: RGBA, ink: RGBA) -> RGBA {
        let page = page.over(.white), card = card.over(page), ink = ink.over(page)
        var colour = card
        var step = 0.0
        while ratio(page, colour) < cardLeast, step < 40 {
            step += 1
            colour = ink.mix(step, card)
        }
        return colour
    }

    /// The same, as a colour that follows the look (light, dark, the skin, Increase Contrast). Every project card's too
    /// (`ProjectCard.fill`).
    static let fill: UIColor = {
        let page = HQPalette.page, card = HQPalette.groupedCard, ink = HQPalette.label   // read here: resolved off the main thread
        return UIColor { @Sendable traits in
            cardColour(page: rgba(page.resolvedColor(with: traits)), card: rgba(card.resolvedColor(with: traits)),
                       ink: rgba(ink.resolvedColor(with: traits))).uiColor
        }
    }()

    nonisolated private static func rgba(_ colour: UIColor) -> RGBA {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        colour.getRed(&r, green: &g, blue: &b, alpha: &a)
        return RGBA(unit: Double(r), Double(g), Double(b), Double(a))
    }

    /// WCAG contrast ratio of two opaque colours.
    nonisolated static func ratio(_ a: RGBA, _ b: RGBA) -> Double {
        func luminance(_ c: RGBA) -> Double {
            func channel(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
        }
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    @ViewBuilder private var card: some View {
        if carded {
            let shape = RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous)
            shape
                .fill(Color(uiColor: Self.fill))
                .overlay { if Theme.isDesktop { shape.strokeBorder(Color(uiColor: HQPalette.stroke), lineWidth: 1) } }
                .accessibilityHidden(true)
        }
    }

    /// A count's capsule: on the card, a step off it (the page's colour in light, a raised grey in dark, as a project's
    /// folder box on its card); off it, the list's grey.
    private var chipFill: Color { Color(uiColor: carded ? ProjectCard.box : HQPalette.fill3) }

    var body: some View {
        let place = Self.meta(folder: folder, branch: branch, bots: bots)
        // Keep the Mac’s chat total in the subtitle; activity belongs in the chips below it.
        let chatTotal = DeviceWord.isMac && total > 0 ? "\(total) \(total == 1 ? "chat" : "chats")" : ""
        let meta = [place, chatTotal].filter { !$0.isEmpty }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: carded ? 5 : 6) {
            // [sessions-ux] Owner 2026-11-10 ("There should be one go-to"): no New Chat here. The bar's Compose, a thumb
            // away, starts the chat in this project (and says so: "New Chat in <project>"); the capsule beside the
            // name was a second button for the same thing.
            HStack(spacing: 4) {
                if !look.isEmpty {
                    ProjectLookMark(look: look, size: 18)
                        .padding(.trailing, 2)
                        .accessibilityIdentifier("sessions.projectPage.look")
                }
                Text(name)
                    .font(Font.hq(.title3).weight(.bold))
                    .foregroundStyle(Color.hqLabel)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                moreButton(menu)
            }
            .frame(height: HQFont.scaled(carded ? 26 : 30))
            if !meta.isEmpty {
                Text(meta)
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqLabel2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("sessions.projectPage.place")
            }
            if coding {
                codingPipelineBar
                    .padding(.top, carded ? 4 : 5)
            } else {
                // Owner 2026-11-15 (picked from four drawings): the three counts always, in the same places, a zero dimmed.
                // [project-header-card] Where the three don't fit on one line (the largest text sizes: "0 Nee…", "1 N…") they
                // keep their marks and numbers and drop their words, which VoiceOver still says.
                ViewThatFits(in: .horizontal) {
                    counts(words: true)
                    if DeviceWord.isMac { counts(words: false, labelActive: true) }
                    counts(words: false)
                }
                .padding(.top, carded ? 1 : 2)
            }
            if coding, let health = codingHealth {
                codingHealthBanner(health)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // [project-header-card] On the card the words keep their column and the header its height (measured: the first
        // heading under it stands where it stood): the card's room inside is the room that stood round the words.
        .padding(.leading, carded ? Self.cardPad : lead)
        .padding(.trailing, carded ? Self.cardPad : lead - 4)
        .padding(.top, carded ? Self.cardPadV : 0)
        .padding(.bottom, carded ? Self.cardPadV - 1 : 0)
        .background { card }
        .padding(.horizontal, carded ? lead - Self.cardPad : 0)
        .padding(.top, carded ? 2 : 8)   // [sessions-ux] the name stood 7 pt under the pills, closer than any heading under it
        .padding(.bottom, carded ? 0 : 6)
    }

    /// [project-default-bot] The ⋯ at the name's end. [coding-pr-review] Owner 2026-11-21 (option B): the ⓘ left the
    /// header (its icon guide is Project Settings' last row), so the ⋯ is the header's last control and stands where
    /// the ⓘ stood: its glyph on the card's inner edge, its touch 44 pt on the iPhone (the Mac's smaller frame, as the
    /// ⓘ had). This replaces the 2026-11-19 placement ("information icon on the right, three dots to the left").
    private func moreButton(_ menu: BotMenu?) -> some View {
        HeaderMoreButton(label: "Actions for \(name)", identifier: "sessions.projectPage.more", glyph: Theme.isDesktop ? 14 : 17,
                         cap: 22, width: DeviceWord.isMac ? 28 : 44, height: DeviceWord.isMac ? 24 : 44) {
            Button(action: onSettings) { Label("Project Settings…", systemImage: "gearshape") }
                .accessibilityIdentifier("sessions.projectPage.settings")
            Toggle(isOn: Binding(get: { coding }, set: onCodingChange)) {
                Label("Coding Project", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .accessibilityHint("Shows pull request status instead of timestamps in this project")
            .accessibilityIdentifier("sessions.projectPage.coding")
            Picker(selection: Binding(get: { sort }, set: onSortChange)) {
                ForEach(ProjectPageSort.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("sessions.projectPage.sort")
            if coding, let onRepository {
                Button(action: onRepository) { Label("Repository…", systemImage: "arrow.triangle.branch") }
                    .accessibilityIdentifier("sessions.projectPage.repository")
            }
            if let menu {
                Button(action: menu.onNewChatWith) { Label("New Chat With…", systemImage: "square.and.pencil") }
                Picker(selection: Binding(get: { menu.usual ?? ProjectDefaultBot.ask }, set: { menu.onPick($0) })) {
                    ForEach(menu.bots, id: \.id) { bot in Text(bot.name).tag(bot.id) }
                    Divider()
                    Text("Ask Every Time").tag(ProjectDefaultBot.ask)
                } label: {
                    Label("Default Bot", systemImage: "person.crop.circle.badge.checkmark")
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("sessions.projectPage.defaultBot")
            }
        }
        .padding(.trailing, DeviceWord.isMac ? -6 : -12)
    }

    static func prWord(_ state: SessionPRStatus.State) -> String {
        ["none": "No PR", "draft": "Draft", "open": "Open", "merged": "Merged", "closed": "Closed", "unknown": "Unknown"][state.rawValue] ?? ""
    }

    /// The count line's states, in order: [coding-pr-review] owner 2026-11-21 (option B), a state at zero is not drawn,
    /// unless it is the picked one (lit at zero, so the filter can be cleared). Empty: the line is absent.
    nonisolated static func shownPRStates(_ counts: [SessionPRStatus.State: Int], selected: SessionPRStatus.State?) -> [SessionPRStatus.State] {
        [SessionPRStatus.State.none, .draft, .open, .merged, .closed, .unknown].filter { counts[$0, default: 0] > 0 || $0 == selected }
    }

    /// Owner 2026-11-19: the picked state says its name inside its ring ("58 Merged"), so the filter on screen reads
    /// without a guide; where the line runs out, the flow puts the last marks on a second line.
    private var pullRequestCounts: some View {
        // A narrow sidebar or larger counts can push the last mark onto a second line.
        PagesFlowLayout(spacing: 12, lineSpacing: 0) {
            ForEach(Self.shownPRStates(prCounts, selected: selectedPR), id: \.self) { state in
                let count = prCounts[state, default: 0]
                let status: String = switch state {
                case .none: "No PR yet"
                case .unknown: "PR status unknown"
                default: "\(SessionPRStatus(state: state).label) PR"
                }
                let label = "\(status), \(count) loaded \(count == 1 ? "chat" : "chats")"
                let picked = selectedPR == state
                Button { onPRPick(state) } label: {
                HStack(spacing: 3) {
                    Image(uiImage: SessionPRGlyph.image(state))
                        .renderingMode(.template)
                        .resizable().frame(width: 14, height: 14)
                        .foregroundStyle(Color(uiColor: SessionPRGlyph.color(state)))
                    Text(picked ? "\(count) \(Self.prWord(state))" : "\(count)")
                        .font(Font.hq(.caption).weight(.medium)).monospacedDigit()
                        .lineLimit(1).fixedSize()
                }
                .padding(.horizontal, picked ? 8 : 4).frame(minHeight: 32)
                .overlay { if picked { Capsule().strokeBorder(Color.hqTint, lineWidth: 1.5) } }
                .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
                .accessibilityHint(selectedPR == state ? "Clear pull request filter" : "Filter chats by pull request state")
                .accessibilityAddTraits(selectedPR == state ? .isSelected : [])
                .accessibilityIdentifier("sessions.projectPage.pr.\(state.rawValue)")
                .help(label)
            }
        }
        .animation(HQMotion.swiftUI(.snappy(duration: 0.2)), value: selectedPR)
    }

    /// Calm, lineless 4-bucket shipping pipeline bar for coding projects (Ready / Needs You / In Flight / Shipped).
    private var codingPipelineBar: some View {
        HStack(spacing: 4) {
            pipelineSegment(.ready, dot: Color.hqGreen)
            pipelineSegment(.needsYou, dot: Color.hqOrange)
            pipelineSegment(.inFlight, dot: nil)
            pipelineSegment(.shipped, dot: nil)
        }
    }

    private func pipelineSegment(_ bucket: CodingPipelineBucket, dot: Color?) -> some View {
        let count = pipelineCounts[bucket, default: 0]
        let picked = selectedBucket == bucket
        let dim = count == 0 && !picked
        let shape = RoundedRectangle(cornerRadius: HQShape.radius(9, .control), style: .continuous)
        let spoken = "\(bucket.sectionTitle), \(count) \(count == 1 ? "chat" : "chats")"

        return Button { onBucketPick(bucket) } label: {
            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    if let dot, count > 0 {
                        Circle()
                            .fill(dot)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                    }
                    Text("\(count)")
                        .font(Font.hq(.subheadline).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(dim ? Color.hqLabel3 : (bucket == .shipped && !picked ? Color.hqLabel2 : Color.hqLabel))
                }
                Text(bucket.label)
                    .font(Font.hq(.caption2).weight(picked ? .semibold : .regular))
                    .foregroundStyle(picked ? Color.hqLabel : Color.hqLabel2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(shape.fill(picked ? chipFill : Color.clear))
            .overlay(shape.strokeBorder(picked ? Color.hqLabel.opacity(0.22) : Color.clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(dim)
        .accessibilityLabel(spoken)
        .accessibilityHint(picked ? "Show all chats" : "Filter chats to \(bucket.sectionTitle)")
        .accessibilityAddTraits(picked ? .isSelected : [])
        .accessibilityIdentifier("sessions.projectPage.pipeline.\(bucket.rawValue)")
        .help(spoken)
    }

    /// Quiet inline status strip shown only when PR tracking needs setup or failed (zero chrome when healthy).
    private func codingHealthBanner(_ health: CodingHealth) -> some View {
        let icon: String
        let tint: Color
        switch health.kind {
        case .needsRepo:
            icon = "arrow.triangle.branch"; tint = Color.hqOrange
        case .unmatched:
            icon = "questionmark.circle"; tint = Color.hqLabel2
        case .unavailable:
            icon = "exclamationmark.triangle"; tint = Color.hqOrange
        case .unsupported:
            icon = "info.circle"; tint = Color.hqLabel2
        }
        return HStack(spacing: 6) {
            Image(systemName: icon)
                .font(Font.hq(.caption))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(health.message)
                .font(Font.hq(.caption))
                .foregroundStyle(Color.hqLabel2)
                .lineLimit(2)
            Spacer(minLength: 4)
            if let title = health.actionTitle, let onHealthAction {
                Button(title, action: onHealthAction)
                    .font(Font.hq(.caption).weight(.semibold))
                    .foregroundStyle(Color.hqTintText)
                    .buttonStyle(.plain)
                    .fixedSize()
                    .accessibilityIdentifier("sessions.projectPage.codingHealth.action")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: HQShape.radius(10, .control), style: .continuous).fill(chipFill))
        .padding(.top, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sessions.projectPage.codingHealth")
    }

    private func counts(words: Bool, labelActive: Bool = false) -> some View {
        func showLabel(_ id: String, _ count: Int) -> Bool {
            words || (labelActive && (count > 0 || isLit(id, count)))
        }
        return HStack(spacing: 6) {
            chip(needs, "Needs You", id: "needs", words: showLabel("needs", needs)) { Circle().fill(Color.hqOrange).frame(width: 7, height: 7) }
            chip(ready, "New", id: "ready", words: showLabel("ready", ready)) { Circle().fill(Color.hqTint).frame(width: 7, height: 7) }
            chip(working, "Working", id: "working", words: showLabel("working", working)) {
                ZStack {
                    Circle().stroke(Color.hqLabel.opacity(0.25), lineWidth: 2)
                    Circle().trim(from: 0, to: 0.25).stroke(Color.hqLabel, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }.frame(width: 9, height: 9)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// [page-count-chips] A count the page is narrowed to. New's narrowing lights New, and Needs You while it counts a chat.
    private func isLit(_ id: String, _ count: Int) -> Bool { lit.contains(id) && (count > 0 || id != "needs") }

    /// One count: its mark, the number and the word, in a small capsule. A zero is dimmed and takes no tap.
    private func chip<Mark: View>(_ count: Int, _ word: String, id: String, words: Bool = true,
                                  @ViewBuilder mark: () -> Mark) -> some View {
        Button {
            onJump(id)
        } label: {
            HStack(spacing: 5) {
                mark()
                Text(words ? "\(count) \(word)" : "\(count)")
                    .font(Font.hq(.caption).weight(.medium)).monospacedDigit()
                    .foregroundStyle(Color.hqLabel)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .frame(minHeight: HQFont.scaled(24))
            .background(Capsule().fill(chipFill))
            // [page-count-chips] Lit while the page is narrowed to it: the tint's ring, as a picked pill says "on".
            .overlay { if isLit(id, count) { Capsule().strokeBorder(Color.hqTint, lineWidth: 1.5) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A lit count takes the tap at zero too (its last chat read): the way back to every chat.
        .disabled(count == 0 && !isLit(id, count))
        .opacity(count == 0 && !isLit(id, count) ? 0.45 : 1)
        .accessibilityLabel("\(word), \(count) \(count == 1 ? "chat" : "chats")")
        .accessibilityAddTraits(isLit(id, count) ? .isSelected : [])
        .accessibilityIdentifier("sessions.projectPage.\(id)")
        .help("\(word), \(count) \(count == 1 ? "chat" : "chats")")
    }
}

extension SessionsViewController {
    /// Opens the project's Repository… sheet.
    func presentProjectRepository(_ key: String) {
        guard let store else { return }
        let page = ProjectRepositoryPage(project: key, store: store)
        present(ChatSheet.wrap(UIHostingController(rootView: page), title: "Repository", detents: [.large()]), animated: true)
    }

    /// [project-settings] ⋯ › Project Settings…: the project's settings as a sheet titled with its name. The page
    /// behind redraws as each setting changes.
    func presentProjectSettings(_ key: String, name: String) {
        guard let store else { return }
        let usual = organizer?.projectDefaultBot(key: key) ?? store.projectHolders(key: key).first?.profile ?? "default"
        let botName = owners[usual]?.name ?? Self.readableProfileName(usual)
        // [coding-pr-review] The icon guide is the page's last row (it left the header's ⓘ): pushed in this sheet.
        weak var sheet: UINavigationController?
        let openRepository: (() -> Void)? = store.prManageAvailable ? { [weak store] in
            guard let store else { return }
            let repo = UIHostingController(rootView: ProjectRepositoryPage(project: key, store: store))
            repo.title = "Repository"
            repo.navigationItem.largeTitleDisplayMode = .never
            sheet?.pushViewController(repo, animated: true)
        } : nil
        let page = ProjectSettingsPage(project: key, store: store, bot: (usual, botName), onChange: { [weak self] in
            self?.reload(animated: false)
        }, onRepository: openRepository, onIconGuide: { [weak store] in
            let guide = UIHostingController(rootView: ProjectIconGuide(coding: store?.isCodingProject(key) ?? false))
            guide.title = "Icon Guide"
            guide.navigationItem.largeTitleDisplayMode = .never
            sheet?.pushViewController(guide, animated: true)
        })
        let wrapped = ChatSheet.wrap(UIHostingController(rootView: page), title: name, detents: [.large()])
        sheet = wrapped
        present(wrapped, animated: true)
    }

    /// [coding-pr-review] A coding row's PR mark: the PR card for its chat (its lead first). Ask to Merge opens the
    /// chat and sends the words there. [pr-card-detail] The card asks for this chat's checks and files as it opens.
    func presentPRCard(_ session: SessionSummary) {
        let chat = PullRequestCardSheet.Chat(profile: session.profile, id: session.id, title: SessionRowView.title(session),
                                             botName: owner(of: session).name, isWorking: session.isRunning || session.status == .working)
        let profile = session.profile, id = session.id, store = self.store
        let status = store?.pullRequest(profile: profile, id: id) ?? session.pullRequest
        let key = Self.key(session)
        let projectKey = projectPageKey
        let onMarkClosed: ((Bool) async throws -> SessionPRStatus?)? = store?.prManage == true ? { [weak store] closed in
            guard let store else { return nil }
            try await store.setPRClosed(session, closed)
            return store.pullRequest(profile: profile, id: id)
        } : nil
        let onRepository: (() -> Void)? = (store?.prManageAvailable == true && projectKey != nil) ? { [weak self] in
            guard let projectKey else { return }
            self?.presentProjectRepository(projectKey)
        } : nil
        guard let sheet = PullRequestCardSheet.make(status: status, chat: chat, refreshResult: { [weak store] manual in
            guard let store else { return nil }
            return try await store.pullRequestDetailResult(profile: profile, id: id, manualRetry: manual)
        }, onOpenChat: { [weak self] in
            self?.open(key)
        }, onMarkClosed: onMarkClosed, onRepository: onRepository, send: { [weak self] words in
            PullRequestCardSheet.deliver(words, to: chat) { self?.open(key) }
        }) else { return }
        Haptics.play(.selection)
        present(sheet, animated: true)
    }

    /// Leading swipe quick action on a coding project page: green Merge on ready PRs, orange/red Fix CI on failing PRs.
    func codingQuickSwipeAction(for session: SessionSummary) -> UIContextualAction? {
        guard let projectKey = projectPageKey, store?.isCodingProject(projectKey) == true else { return nil }
        let status = store?.pullRequest(profile: session.profile, id: session.id) ?? session.pullRequest
        let botName = owner(of: session).name
        let title = SessionRowView.title(session)
        let key = Self.key(session)
        let chat = PullRequestCardSheet.Chat(profile: session.profile, id: session.id, title: title,
                                             botName: botName, isWorking: session.isRunning || session.status == .working)
        guard let card = PullRequestCard(status: status, chatTitle: title, botName: botName) else { return nil }

        if CodingPipeline.isReadyToMerge(session),
           let mergeWords = card.actions.compactMap({ if case .askToMerge(let w) = $0 { return w }; return nil }).first {
            let action = UIContextualAction(style: .normal, title: "Merge") { [weak self] _, _, done in
                done(true)
                guard let self else { return }
                PullRequestCardSheet.confirm(mergeWords, title: card.mergeConfirmTitle(chatWorking: chat.isWorking), from: self) {
                    PullRequestCardSheet.deliver(mergeWords, to: chat) { [weak self] in self?.open(key) }
                }
            }
            action.image = UIImage(systemName: "checkmark.circle.fill")
            action.backgroundColor = .systemGreen
            action.accessibilityLabel = "Ask \(botName) to Merge"
            return action
        }

        if CodingPipeline.hasFailingChecks(session), let fixWords = card.fixChecksWords {
            let action = UIContextualAction(style: .normal, title: "Fix CI") { [weak self] _, _, done in
                done(true)
                guard let self else { return }
                PullRequestCardSheet.confirm(fixWords, title: card.fixChecksTitle, from: self) {
                    PullRequestCardSheet.deliver(fixWords, to: chat) { [weak self] in self?.open(key) }
                }
            }
            action.image = UIImage(systemName: "wrench.and.screwdriver.fill")
            action.backgroundColor = .systemRed
            action.accessibilityLabel = "Ask \(botName) to Fix Checks"
            return action
        }

        return nil
    }

    /// [project-settings] What of a project's settings its page's header and rows draw (the header redraws when it
    /// changes).
    func projectSettingsSign(_ key: String) -> String {
        guard let store else { return "" }
        let look = store.projectLook(key)
        return "\(look.emoji ?? "")/\(look.color.map(String.init) ?? "")/\(store.isProjectBranchRows(key))"
    }

    /// All loaded rows that the project page can display for `key`, matching `SessionListPipeline.projectPage` 1-to-1
    /// (live + non-outside archived, respecting bot and status filters so every pill count equals the filtered rows).
    func projectCodingRows(_ key: String) -> [SessionSummary] {
        guard let store else { return [] }
        var seen = Set<String>()
        var out: [SessionSummary] = []
        let pool = store.sessions + store.archivedSessions.filter { !ChatSource.hasFolder($0.source) }
        for row in pool {
            if let bot = store.botFilter, row.profile != bot { continue }
            if !store.view.statusFilter.isEmpty, !store.view.statusFilter.contains(row.status) { continue }
            guard SessionProjects.key(cwd: row.cwd, profile: row.profile, projectsByProfile: store.projectsByProfile) == key,
                  seen.insert(SessionListPipeline.key(row)).inserted else { continue }
            var copy = row
            copy.pullRequest = store.pullRequest(profile: row.profile, id: row.id) ?? row.pullRequest
            out.append(copy)
        }
        return out
    }

    /// Count the entire loaded project by PR state.
    func projectPRCounts(_ key: String) -> [SessionPRStatus.State: Int] {
        guard let store else { return [:] }
        var counts: [SessionPRStatus.State: Int] = [:]
        for row in projectCodingRows(key) {
            guard let states = row.pullRequest?.countedStates, !states.isEmpty else { continue }
            for state in states { counts[state, default: 0] += 1 }
        }
        return counts
    }

    /// Count the coding project's rows into the 4 shipping pipeline buckets, matching `SessionListPipeline.projectPage` 1-to-1.
    func projectPipelineCounts(_ key: String) -> [CodingPipelineBucket: Int] {
        guard let store else { return [:] }
        let rows = projectCodingRows(key)
        let rule = store.projectAutoDoneRules[key]
        let localPins = store.projectPinKeys[key] ?? []
        let now = Date()
        return CodingPipeline.counts(rows) { session in
            let rowKey = SessionListPipeline.key(session)
            let isPinned = session.pinned || localPins.contains(rowKey)
            let quiet = SessionProjectState.of(session).isEmpty
            if session.archived && quiet { return true }
            guard let rule, quiet, !session.archived, !isPinned, !store.keepNew.contains(rowKey) else { return false }
            if rule.onMerge, session.pullRequest?.state == .merged { return true }
            guard let days = rule.days, let last = session.lastActive ?? session.startedAt else { return false }
            return now.timeIntervalSince(last) > Double(days) * 86_400
        }
    }

    /// Quiet inline diagnostic for a coding project header; nil whenever everything is working cleanly.
    func projectCodingHealth(_ key: String) -> ProjectPageHeader.CodingHealth? {
        guard let store, store.isCodingProject(key) else { return nil }
        if store.isPRRouteUnsupported {
            return .init(kind: .unsupported, message: "Pull request tracking needs the Hermes HQ add-on.", actionTitle: nil)
        }
        let rows = projectCodingRows(key)
        let unavailable = rows.filter { $0.pullRequest?.state == .unknown && $0.pullRequest?.unknownReason == .unavailable }.count
        let unmatched = rows.filter { $0.pullRequest?.state == .unknown && $0.pullRequest?.unknownReason == .unmatched }.count
        let matched = rows.filter { $0.pullRequest.map { $0.state != .unknown } == true }.count
        let linked = store.prRepo(forProject: key)
        if store.prReposState == .failed && linked == nil && (matched == 0 || unmatched > 0 || unavailable > 0) {
            return .init(kind: .unavailable, message: "Couldn’t check repository link.", actionTitle: "Retry")
        }
        if store.prManage && linked == nil && matched == 0 && (store.prAutoLinkFailed.contains(key) || unmatched > 0) {
            return .init(kind: .needsRepo, message: "Link a git repository to track pull requests.", actionTitle: "Link…")
        }
        if unavailable > 0 && unavailable == rows.count {
            return .init(kind: .unavailable, message: "Couldn’t reach the gateway for pull request status.", actionTitle: "Retry")
        }
        if matched == 0 && unmatched > 0 && store.prManageAvailable && linked != nil {
            return .init(kind: .unmatched(unmatched), message: "No chats matched \(SessionStore.folderName(linked!.path)).",
                         actionTitle: "Repository…")
        }
        return nil
    }
}

/// [project-sections] A project state's mark, as the page's count chips draw it: Needs You an orange dot, Ready the
/// tint's dot, Working the still quarter ring; nothing for quiet.
struct ProjectStateMark: View {
    var state: SessionProjectState

    var body: some View {
        switch state {
        case .needsYou: Circle().fill(Color.hqOrange).frame(width: 7, height: 7)
        case .ready: Circle().fill(Color.hqTint).frame(width: 7, height: 7)
        case .working:
            ZStack {
                Circle().stroke(Color.hqLabel.opacity(0.25), lineWidth: 2)
                Circle().trim(from: 0, to: 0.25).stroke(Color.hqLabel, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }.frame(width: 9, height: 9)
        case .quiet: EmptyView()
        }
    }
}
