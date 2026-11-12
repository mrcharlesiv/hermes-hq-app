// The Sessions tab's cells (spec 06 §6.4, spec 02 §9.3): a 40 pt face with the unread corner badge, the title and
// time, then "<Owner> · <preview>" on two lines (four at the accessibility sizes). [sessionsminimal] No ⋯: the long press
// and the More swipe hold the row's menu, as on Bots.

import SwiftUI
import UIKit

struct SessionRowView: View {
    var session: SessionSummary
    var ownerName: String
    var ownerHead: JSONValue?
    var time: String
    /// Delete is on its way: dimmed, a spinner in place of the time.
    var busy = false
    /// [sessions-m9] Filter › Row Detail: what the trailing text and the second line may show (3x-sessions §9.2).
    var detail: Set<SessionRowDetail> = [.preview, .time]
    /// UX study #248: the chat's bot is muted on this iPhone: a bell.slash beside the pin, as on its Bots row.
    var muted = false
    /// Where the chat came from (`SessionSummary.origin`): the platform's mark before the title. nil inside its folder.
    var origin: String? = nil
    /// The title's lines below the accessibility sizes. The Other Apps page gives it two: its chats all come from one
    /// app and one bot, so the title is what tells them apart (owner call, polish 2026-10-24).
    var titleLines = 1
    /// [sessions-layout] Pinned's rows: one line, the title and the time, a smaller face in the face's column (owner,
    /// 2026-10-31). The accessibility sizes keep the full row.
    var compact = false
    /// [sessions-layout] New for You's rows: the preview on one line, so three chats and the groups under them fit.
    var shortPreview = false
    /// [project-cards] A chat inside a project's card: Pinned's one line, its face on the project's line, and a second
    /// line only while its bot works or waits on you. The project's name (VoiceOver says where the row is).
    var card: String? = nil
    /// [sessions-fresh] Group By Recent's rows: Pinned's (one line) and Recent's (a second line only while the bot works
    /// or waits on you). `faces`: Show › Bot Faces (the cards' rows follow it too).
    var fresh: Fresh? = nil
    var faces = true
    enum Fresh { case pinned, recent }
    @Environment(\.dynamicTypeSize) private var typeSize
    private var large: Bool { typeSize.isAccessibilitySize }
    /// [desktoplook2] The desktop's session row, unified with the Bots row: 32 pt face, 14 pt semibold title, one line
    /// of 12.5 pt preview, 60 pt tall (phone-ui-desktop.css:205-213, 272-276).
    private var desk: Bool { Theme.isDesktop && !large }

    /// `title.trim() || preview.trim() || "Untitled Chat"` (`V/lib/chat-runtime.ts:64-66`, which says "Untitled session";
    /// UX study 2026-10-19 #31: the Sessions tab says Chat everywhere else).
    static func title(_ session: SessionSummary) -> String {
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        let preview = session.preview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return preview.isEmpty ? "Untitled Chat" : preview
    }

    var body: some View {
        if let card { cardBody(card) } else if let fresh { freshBody(fresh) } else if compact && !large { compactBody } else { fullBody }
    }

    /// [card-line-swipe] How far the project's line stops short of a card chat's face (or its dot, Bot Faces off) each
    /// way. The cell's piece of card draws the line, so it can stay while the chat swipes.
    static func cardLineClear(faces: Bool) -> CGFloat { (faces ? ProjectCard.face : cardNode) / 2 + ProjectCard.lineClearance }
    static let cardNode: CGFloat = 8

    /// [project-cards] A chat in a project's card: the face in the face column on the project's line (the line stops
    /// short of it), the title and time on one line, and while the bot works or waits on you, what it is doing under it.
    private func cardBody(_ project: String) -> some View {
        let face = ProjectCard.face
        let node = Self.cardNode   // [sessions-fresh] Bot Faces off: a dot on the project's line in the face's place
        return HStack(alignment: .top, spacing: ProjectCard.columnGap) {
            Group {
                if faces {
                    HeadImage(raw: ownerHead, profile: session.profile, size: face, working: session.isRunning, moods: session.isRunning)
                        .overlay(alignment: .topTrailing) {
                            if session.unread || session.status == .needsInput {
                                Circle().fill(session.status == .needsInput ? Color.hqOrange : Color.hqTint)
                                    .frame(width: 10, height: 10)
                                    .background(Circle().fill(Color(uiColor: ProjectCard.fill)).padding(-2))
                                    .offset(x: 3, y: -3)
                            }
                        }
                } else {
                    Circle()
                        .fill(session.status == .needsInput ? Color.hqOrange : session.unread ? Color.hqTint : Color(uiColor: ProjectCard.line))
                        .frame(width: node, height: node)
                }
            }
            .frame(width: ProjectCard.column, height: face)
            VStack(alignment: .leading, spacing: 0) {
                SessionTitleLine(spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let origin {
                            PlatformMark(source: origin, size: desk ? 14 : 16)
                                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                        }
                        Text(Self.title(session))
                            .font(desk ? Font.hq(.callout).weight(session.unread ? .semibold : .regular) : titleFont)
                            .foregroundStyle(Color.hqLabel)
                            .lineLimit(large ? 3 : 1)
                        if let color = session.color {
                            Circle().fill(Color(uiColor: SessionsOrganizer.uiColor(color)))
                                .frame(width: 9, height: 9)
                                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 0.5 }
                                .accessibilityHidden(true)
                        }
                    }
                    trailingText
                }
                .frame(minHeight: face)
                if let status = cardStatus {
                    Text(status.words)
                        .font(Font.hq(desk ? .footnote : .subheadline))
                        .foregroundStyle(status.color)
                        .lineLimit(large ? 3 : 1)
                        .padding(.bottom, 2)
                }
            }
        }
        .padding(.vertical, ProjectCard.rowPad)
        .padding(.leading, ProjectCard.cellLead)
        .padding(.trailing, ProjectCard.cellTrailing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(accessibilityText). In \(project)")
        .accessibilityAddTraits(.isButton)
        .opacity(busy ? 0.45 : 1)
    }

    /// [sessions-fresh] One line: a 22 pt face centred in the face's column (so the title starts where a project's name
    /// does; none with Bot Faces off), the title, the time and a dot (blue: a reply not read yet; orange: waiting on
    /// you). In Recent, a second line only while the bot works or waits on you.
    private func freshBody(_ fresh: Fresh) -> some View {
        let line: CGFloat = desk ? HQFont.scaled(22) : Density.ios(24, 20)
        let status = fresh == .recent ? cardStatus : nil
        return HStack(alignment: .top, spacing: desk ? DesktopRows.gap : ProjectCard.columnGap) {
            if faces {
                HeadImage(raw: ownerHead, profile: session.profile, size: desk ? HQFont.scaled(18) : Density.ios(22, 18), working: session.isRunning,
                          moods: session.isRunning)
                    .frame(width: desk ? DesktopRows.face : ProjectCard.column, height: line)
            }
            VStack(alignment: .leading, spacing: 1) {
                SessionTitleLine(spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let origin {
                            PlatformMark(source: origin, size: desk ? 14 : 16)
                                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                        }
                        Text(Self.title(session))
                            .font(desk ? Font.hq(.callout).weight(session.unread ? .semibold : .regular) : titleFont)
                            .foregroundStyle(Color.hqLabel)
                            .lineLimit(large ? 3 : 1)
                        if let color = session.color {
                            Circle().fill(Color(uiColor: SessionsOrganizer.uiColor(color)))
                                .frame(width: 9, height: 9)
                                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 0.5 }
                                .accessibilityHidden(true)
                        }
                    }
                    HStack(alignment: .center, spacing: 8) {
                        trailingText
                        Circle()
                            .fill(session.status == .needsInput ? Color.hqOrange : session.unread ? Color.hqTint : Color.clear)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                    }
                }
                .frame(minHeight: line)
                if let status {
                    HStack(spacing: 6) {
                        if session.status != .needsInput {
                            ProgressView().controlSize(.mini).tint(Color.hqLabel2)
                        }
                        Text(status.words)
                            .font(Font.hq(desk ? .footnote : .subheadline))
                            .foregroundStyle(status.color)
                            .lineLimit(large ? 3 : 1)
                    }
                    .padding(.bottom, 2)
                }
            }
        }
        .padding(.vertical, fresh == .pinned ? (desk ? 4 : Density.ios(7, 4)) : (desk ? 6 : Density.ios(10, 5)))
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, minHeight: fresh == .pinned ? (desk ? HQFont.scaled(32) : Density.ios(40, 30)) : (desk ? HQFont.scaled(36) : Density.ios(44, 32)),
               alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
        .rowArc(showsArc)
        .opacity(busy ? 0.45 : 1)
    }

    /// [project-cards] The second line a chat in a card has only while it needs one: waiting on you, or its bot's step.
    private var cardStatus: (words: String, color: Color)? {
        if session.status == .needsInput { return ("Needs your input", Color.hqOrange) }
        if session.isRunning || session.status == .working {
            return (session.step.map(LiveSteps.line) ?? "Working…", Color.hqTintText)
        }
        return nil
    }

    /// [sessions-layout] One line: a small face centred in the face's column (so the title starts where every row's
    /// does), the title, then the figures and time.
    private var compactBody: some View {
        HStack(spacing: desk ? DesktopRows.gap : ProjectCard.columnGap) {
            HeadImage(raw: ownerHead, profile: session.profile, size: desk ? HQFont.scaled(22) : ProjectCard.face, working: session.isRunning,
                      moods: session.isRunning)
                .overlay(alignment: .topTrailing) {
                    if session.unread || session.status == .needsInput {
                        Circle().fill(session.status == .needsInput ? Color.hqOrange : Color.hqTint)
                            .frame(width: 10, height: 10)
                            .background(Circle().fill(Color.hqPage).padding(-2))
                            .offset(x: 3, y: -3)
                    }
                }
                .frame(width: desk ? DesktopRows.face : ProjectCard.column)
            SessionTitleLine(spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let origin {
                        PlatformMark(source: origin, size: desk ? 14 : 16)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                    }
                    Text(Self.title(session))
                        .font(desk ? Font.hq(.callout).weight(.semibold) : titleFont)
                        .foregroundStyle(Color.hqLabel)
                        .lineLimit(1)
                    if let color = session.color {
                        Circle().fill(Color(uiColor: SessionsOrganizer.uiColor(color)))
                            .frame(width: 9, height: 9)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 0.5 }
                            .accessibilityHidden(true)
                    }
                }
                trailingText
            }
        }
        .padding(.vertical, desk ? 4 : Density.ios(7, 4))
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, minHeight: desk ? HQFont.scaled(36) : Density.ios(44, 32), alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
        .rowArc(showsArc)
        .opacity(busy ? 0.45 : 1)
    }

    private var fullBody: some View {
        HStack(alignment: large ? .top : .center, spacing: 0) {
            HStack(alignment: large ? .top : .center, spacing: desk ? DesktopRows.gap : ProjectCard.columnGap) {
                face
                VStack(alignment: .leading, spacing: 1) {
                    // [sessions-m9] The figures and time take their own width; the title keeps at least 30% of the line.
                    SessionTitleLine(spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if let origin {
                                // The desktop's platform chip before the title (`session-row.tsx:518-529`).
                                PlatformMark(source: origin, size: desk ? 14 : 16)
                                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                            }
                            Text(Self.title(session))
                                .font(desk ? Font.hq(.callout).weight(.semibold) : titleFont)
                                .foregroundStyle(Color.hqLabel)
                                .lineLimit(large ? 3 : titleLines)
                            if let color = session.color {
                                // More › Color: a tag after the title (the web's `.ui-ls-color`).
                                Circle().fill(Color(uiColor: SessionsOrganizer.uiColor(color)))
                                    .frame(width: 9, height: 9)
                                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 0.5 }
                                    .accessibilityHidden(true)
                            }
                        }
                        if !large { trailingText }
                    }
                    secondLine
                    if large { trailingText }
                }
            }
            .padding(.vertical, desk ? (fixedDeskHeight ? 0 : 9) : Density.ios(13, 7))
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(.isButton)

        }
        .frame(minHeight: large ? 0 : desk ? DesktopRows.height : Density.ios(72, 50))
        .frame(height: desk && fixedDeskHeight ? DesktopRows.height : nil)
        .rowArc(showsArc)
        .opacity(busy ? 0.45 : 1)
    }

    /// The look's rows are 60 pt; a title allowed a second line lets the row grow to fit it.
    private var fixedDeskHeight: Bool { titleLines <= 1 }

    /// The working arc (V:store/session-dot-state.ts:75): running, not waiting on the person.
    private var showsArc: Bool { Self.showsArc(session, busy: busy) }

    static func showsArc(_ session: SessionSummary, busy: Bool) -> Bool {
        (session.isRunning || session.status == .working) && session.status != .needsInput && !busy
    }

    @ViewBuilder private var trailingText: some View {
        if busy {
            ProgressView().controlSize(.small).accessibilityLabel("Deleting")
        } else {
            HStack(alignment: large ? .firstTextBaseline : .center, spacing: 4) {
                if session.pinned && !compact && fresh != .pinned {   // [sessions-layout] Pinned's own rows need no pin
                    Image(systemName: "pin.fill")
                        .font(Font.hq(.caption2))
                        .foregroundStyle(Color.hqLabel3)
                        .accessibilityHidden(true)
                }
                if session.archived {
                    // Show › Archived lists these with the rest: the mark tells them apart.
                    Image(systemName: "archivebox.fill")
                        .font(Font.hq(.caption2))
                        .foregroundStyle(Color.hqLabel3)
                        .accessibilityHidden(true)
                }
                if muted {
                    Image(systemName: "bell.slash.fill")         // UX study #248
                        .font(Font.hq(.caption2))
                        .foregroundStyle(Color.hqLabel3)
                        .accessibilityHidden(true)
                }
                // [sessions-m9] Row Detail's figures, then the time when Time is on; nothing when all are off.
                if let words = SessionRowWords.trailing(session, detail: detail, time: time) { trailingWords(words) }
            }
        }
    }

    private var face: some View {
        // [moods] The bot's face acts out its turn on the row of the chat it runs in (not on every chat it has).
        HeadImage(raw: ownerHead, profile: session.profile, size: desk ? DesktopRows.face : Density.ios(40, 32), working: session.isRunning,
                  moods: session.isRunning)
            .overlay(alignment: .topTrailing) {
                if session.unread || session.status == .needsInput {
                    // 10 + 0.17 × 40 ≈ 17 pt, 3 pt outside the corner, ringed 2 pt in the page colour.
                    // [sessions-m9] Orange while the chat waits for the user (the web's needs-you badge).
                    Circle().fill(session.status == .needsInput ? Color.hqOrange : Color.hqTint)
                        .frame(width: desk ? 10 : 17, height: desk ? 10 : 17)
                        .background(Circle().fill(Color.hqPage).padding(-2))
                        .offset(x: 3, y: -3)
                }
            }
            .padding(.top, large ? 2 : 0)
    }

    /// The title in the iOS look. [mac] Stress test 2026-10-28 #68: the scaled body, as the Bots row's name (the plain
    /// `.body` carries no UI Scale on the Mac, so names drew smaller than Bots'); bold only while unread, as before.
    private var titleFont: Font {
        // [density] Through the font factory on the iPhone too (it was the system body there), so UI Scale reaches it.
        let body: Font = Font.hq(Density.compact ? .callout : .body)
        return session.unread ? body.weight(.semibold) : body
    }

    private func trailingWords(_ words: String) -> some View {
        Text(words)
            // [mac] Stress test 2026-10-28 #68: the iOS look's time at the Bots row's size (it was a size larger).
            .font(Font.hq(desk ? .caption2 : DeviceWord.isMac ? .caption : .subheadline))
            .monospacedDigit()
            .foregroundStyle(session.unread && fresh == nil ? Color.hqTintText : Color.hqLabel2)   // [sessions-fresh] the dot says it
            .lineLimit(large ? 3 : 1)                 // under the second line at the largest sizes: it wraps, never "$…"
            .truncationMode(.tail)
    }

    private var secondLine: some View {
        let owner = Text(ownerName).foregroundStyle(Color.hqLabel)
        let rest: Text
        if let snippet = session.searchSnippet, !snippet.isEmpty {
            // Search: why the chat matched, the match in bold.
            rest = SessionSearch.parts(snippet).reduce(Text("")) { line, part in
                Text("\(line)\(Text(part.text).foregroundStyle(part.match ? Color.hqLabel : Color.hqLabel2).fontWeight(part.match ? .semibold : .regular))")
            }
        } else if session.status == .needsInput {
            // [sessions-m9] The web's order: a live status, the pending line, then the detail (3x-sessions §9.2, §9.4).
            rest = Text("Needs your input").foregroundStyle(Color.hqOrange)
        } else if session.isRunning || session.status == .working {
            // [toolnow] The step it is on ("Reading package.json…"), else "Working…".
            rest = Text(session.step.map(LiveSteps.line) ?? "Working…").foregroundStyle(Color.hqTintText)
        } else if let pending = session.pending {
            let prefix = Text(pending.prefix).fontWeight(.semibold).foregroundStyle(pending.failed ? Color.hqRed : Color.hqLabel)
            rest = Text("\(prefix) \(Text(pending.text).foregroundStyle(Color.hqLabel2))")
        } else if let words = SessionRowWords.detailText(session, detail: detail) {
            rest = Text(words).foregroundStyle(Color.hqLabel2)
        } else {
            return Text("\(owner)").font(Font.hq(desk ? .footnote : .subheadline)).lineLimit(desk || ((DeviceWord.isMac || shortPreview) && !large) ? 1 : large ? 4 : 2).frame(maxWidth: .infinity, alignment: .leading)
        }
        // [mac] Stress test 2026-10-28: one line in both looks on the Mac (the iOS look wrapped to two or three).
        // [toolnow] A step's line stays one line too, so the row keeps its height as the steps change.
        let stepLine = session.step != nil && (session.isRunning || session.status == .working) && session.searchSnippet == nil
            && session.status != .needsInput
        return Text("\(owner)\(Text(" · ").foregroundStyle(Color.hqLabel2))\(rest)")
            .font(Font.hq(desk ? .footnote : .subheadline))
            .lineLimit(desk || ((DeviceWord.isMac || stepLine || shortPreview) && !large) ? 1 : large ? 4 : 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// [sessions-m9] One stop, the web's order (`SessionRowWords.accessibilityLabel`).
    private var accessibilityText: String {
        let label = SessionRowWords.accessibilityLabel(title: Self.title(session), session: session, ownerName: ownerName, detail: detail, time: time,
                                           snippet: session.searchSnippet.map(SessionSearch.plain), colorName: SessionColors.name(session.color),
                                           busy: busy, muted: muted)
        return origin.map { "\(label). From \(ChatSource.label($0))" } ?? label
    }
}

/// [sessions-m9] The row's first line: the title (and its colour tag) leading, the figures and time trailing, first
/// baselines aligned. The trailing text takes its own width (the web's `.ui-ls-when` never shrinks) and the title what
/// is left, but the title always keeps a fifth of the line: past 80% the trailing text truncates at its tail, unless a
/// short title leaves it more. (The spec's 55% cut its own example, "1.2k · $0.34 · Yesterday", on a 402 pt phone, and
/// 70% still cut a pinned row's "303.7k · $5.64 · Yesterday" by two letters; only absurd figures reach 80%.)
private struct SessionTitleLine: Layout {
    var spacing: CGFloat = 8
    static let trailingShare: CGFloat = 0.8

    private struct Fit {
        var sizes: [CGSize]
        var baselines: [CGFloat]
        var top: CGFloat
        var height: CGFloat
    }

    private func fit(_ width: CGFloat?, _ subviews: Subviews) -> Fit {
        guard let lead = subviews.first else { return Fit(sizes: [], baselines: [], top: 0, height: 0) }
        var proposals: [ProposedViewSize] = []
        if subviews.count > 1, let trail = subviews.last {
            let ideal = trail.sizeThatFits(.unspecified).width
            let spare = width.map { $0 - spacing - lead.sizeThatFits(.unspecified).width } ?? 0     // what a short title leaves
            let trailWidth = width.map { min(ideal, max(($0 * Self.trailingShare).rounded(.down), spare)) } ?? ideal
            let trailSize = trail.sizeThatFits(ProposedViewSize(width: trailWidth, height: nil))
            let leadWidth = width.map { max(0, $0 - spacing - trailSize.width) }
            proposals = [ProposedViewSize(width: leadWidth, height: nil), ProposedViewSize(width: trailWidth, height: nil)]
        } else {
            proposals = [ProposedViewSize(width: width, height: nil)]
        }
        let views = subviews.count > 1 ? [lead, subviews[subviews.count - 1]] : [lead]
        let dimensions = zip(views, proposals).map { $0.dimensions(in: $1) }
        let sizes = dimensions.map { CGSize(width: $0.width, height: $0.height) }
        let baselines = dimensions.map { $0[VerticalAlignment.firstTextBaseline] }
        let top = baselines.max() ?? 0
        let height = zip(sizes, baselines).map { top - $1 + $0.height }.max() ?? 0
        return Fit(sizes: sizes, baselines: baselines, top: top, height: height)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let fit = fit(proposal.width, subviews)
        let natural = fit.sizes.map(\.width).reduce(0, +) + (fit.sizes.count > 1 ? spacing : 0)
        return CGSize(width: proposal.width ?? natural, height: fit.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let fit = fit(bounds.width, subviews)
        guard let lead = subviews.first, !fit.sizes.isEmpty else { return }
        lead.place(at: CGPoint(x: bounds.minX, y: bounds.minY + fit.top - fit.baselines[0]), anchor: .topLeading,
                   proposal: ProposedViewSize(fit.sizes[0]))
        guard subviews.count > 1, fit.sizes.count > 1 else { return }
        subviews[subviews.count - 1].place(at: CGPoint(x: bounds.maxX - fit.sizes[1].width, y: bounds.minY + fit.top - fit.baselines[1]),
                                           anchor: .topLeading, proposal: ProposedViewSize(fit.sizes[1]))
    }
}

/// A titled group that folds (Pinned, a date, a status, a project): tapping the header closes it to the header alone.
struct SessionHeaderFold {
    var collapsed: Bool
    /// Every chat the group holds, and how many are unread (said while closed).
    var total: Int
    var unread: Int
    /// [sessions-collapse] What `total` counts: chats, or the closed "Projects" header's projects.
    var unit = "chat"
    var toggle: () -> Void

    /// "12 chats, 3 unread": a closed group's count.
    static func countWords(total: Int, unread: Int, unit: String = "chat") -> String {
        let chats = total == 1 ? "1 \(unit)" : "\(total) \(unit)s"
        return unread > 0 ? "\(chats), \(unread) unread" : chats
    }
}

/// [sessions-layout] A project's header as its summary row. [project-cards] The top of its card: every bot its chats
/// belong to (newest first), how many chats it holds, its unread count, whether a bot works in it, its newest chat.
/// The row draws the name, unread, working and time on one line; the rest is VoiceOver's.
struct SessionProjectSummary {
    var bots: [ProjectBot]
    var total: Int
    /// Its unread chats (they are in New for You too): a tinted count on the right.
    var unread = 0
    var latestTitle: String?
    var time: String
    var collapsed: Bool
    /// A bot is at work in one of its chats: the closed card shows the working dots.
    var working = false
    /// Under a bot chip: every chat it holds under all bots ("3 of 12 chats").
    var whole: Int? = nil
    /// Home (the chats in no project): a house rather than a folder.
    var home = false
    /// The project above is open: this one stands a card's gap below its card.
    var afterCard = false

    /// "Otto, Herald, Hermes · 12 chats"; past three bots "5 bots · 23 chats"; under a chip "Otto · 3 of 12 chats".
    var whoWords: String {
        let chats: String
        if let whole, whole != total {
            chats = "\(total) of \(whole) chats"
        } else {
            chats = total == 1 ? "1 chat" : "\(total) chats"
        }
        guard !bots.isEmpty else { return total == 0 ? "No chats yet" : chats }
        let names = bots.count > 3 ? "\(bots.count) bots" : bots.map(\.name).joined(separator: ", ")
        return "\(names) · \(chats)"
    }
}

/// A date group's header: Subheadline semibold label-2, 20 pt in (`phone-tabs.css:84-86`), just over its rows with a
/// 20 pt break above it. [sessions-layout] A project's header is a row of its own (`summary`): folder, name, time.
struct SessionDateHeaderView: View {
    var title: String
    /// A project's header (Group By Project): its + starts a new chat in the project.
    var onNewChat: (() -> Void)? = nil
    /// A project's header: a hold (a right click on the Mac) offers Rename Project…, and VoiceOver the same action.
    var onRename: (() -> Void)? = nil
    /// A saved project's header: the hold menu's Delete Project… (after a confirmation).
    var onDelete: (() -> Void)? = nil
    /// The Other Apps page's platform sections: the platform's mark before its name.
    var source: String? = nil
    /// The list's titled groups: the header opens and closes its group (the desktop's divider toggle).
    var fold: SessionHeaderFold? = nil
    /// [manual-order] A project or bot group's place: Favorite, Move Up / Move Down and Reorder… in the hold menu.
    var order: SessionHeaderOrder? = nil
    /// [drag-to-project] A dragged chat is held over this project: the header lights up in the tint as where it goes.
    var dropTarget = false
    /// [sessions-layout] A project's header (Group By Project): drawn as a summary row rather than a caption.
    var summary: SessionProjectSummary? = nil
    /// [sessions-layout] New for You: how many chats it holds, in a tinted capsule after the title.
    var badge: Int? = nil
    /// [sessions-layout] The first project's header: "Projects" over its summary row (with Edit, Reorder Projects…),
    /// so the folded projects read as their own section under Pinned.
    var caption: String? = nil
    var onEditCaption: (() -> Void)? = nil
    /// [sessions-collapse] A tap on "Projects" closes every project to one closed "Projects" header.
    var onFoldCaption: (() -> Void)? = nil
    /// [sessions-fresh] Group By Recent: "See All N" on Pinned's caption and on "Projects".
    var seeAll: SessionSeeAll? = nil
    /// [project-unfold] Which of the header this view draws. Under "Projects" the list draws the caption apart
    /// (SessionHeaderCell) and this view only keeps its place, so the row can move down the header while it stays.
    var part: Part = .whole
    enum Part { case whole, caption, belowCaption }
    /// The list's first group: under the bar, it needs no break above its caption.
    var first = false
    /// [project-unfold] A group opening or closing: what changes across its header (a caret, a count) moves on this.
    var motion: Animation? = nil
    @Environment(\.dynamicTypeSize) private var typeSize
    private var large: Bool { typeSize.isAccessibilitySize }
    private var desk: Bool { Theme.isDesktop && !large }
    /// A group's + (never a project's: [project-cards] New Chat is the foot of its card, and stays in its hold menu).
    private var showsNewChat: Bool { onNewChat != nil && summary == nil }
    /// [header-menus] A header with a hold menu shows a ⋯ with the same menu (owner 2026-11-03).
    private var hasMenu: Bool { ProjectHeaderMenu.offered(onRename: onRename, order: order) }
    /// [header-menus] A caption's ⋯ beside its + (a project's row has its own place for it, `HeaderMenuSpot`).
    private var showsCaptionMenu: Bool { hasMenu && summary == nil }

    var body: some View {
        if part == .caption, let caption {
            sectionCaption(caption)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if let caption, summary != nil {
                    // Drawn by the list over this place (see part): hidden here, the same size.
                    sectionCaption(caption).placeOnly(part == .belowCaption)
                }
                header
            }
        }
    }

    /// [project-unfold] How far down its header a project's row starts: opening or closing changes it (into the card, or
    /// the gap under one above), and the list moves the header's content by the change on its own spring, not SwiftUI's,
    /// so the row and the chats under it move as one. Under "Projects" the caption is drawn apart and stays.
    func with(part: Part) -> Self {
        var view = self
        view.part = part
        return view
    }

    static func rowShift(collapsed: Bool, afterCard: Bool, caption: Bool) -> CGFloat {
        topGap(collapsed: collapsed, afterCard: afterCard, caption: caption) + ProjectCardHeader.topPad(open: !collapsed)
    }

    private var header: some View {
        Group {
            if let summary {
                ProjectCardHeader(title: title, summary: summary, favorite: order?.favorite == true, folds: fold != nil,
                                  dropTarget: dropTarget, motion: motion, menuSpot: hasMenu)
            } else {
                captionRow
            }
        }
            .frame(maxWidth: .infinity, minHeight: summary == nil ? Self.captionHeight : 0, alignment: .leading)
            // A caption's tap reaches up into the break above it (the row below has its own); taps only, so VoiceOver's
            // frame stays the caption's.
            .contentShape(.interaction, RaisedHitShape(above: summary == nil ? Self.hitAbove : 0))
            .onTapGesture { fold?.toggle() }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(spokenLabel)
            .accessibilityValue(spokenValue)
            .accessibilityHint(fold.map { $0.collapsed ? "Shows the chats in this group." : "Hides the chats in this group." } ?? "")
            .accessibilityAddTraits(fold == nil ? .isHeader : [.isHeader, .isButton])
            .accessibilityAction { fold?.toggle() }
            .accessibilityActions {
                if let onRename { Button("Rename Project…", action: onRename) }
                if let onNewChat { Button("New Chat in \(title)", action: onNewChat) }
                if let order {
                    if let onFavorite = order.onFavorite {
                        Button(order.favorite ? "Remove from Favorites" : "Add to Favorites", action: onFavorite)
                    }
                    if let up = order.onMoveUp { Button("Move Up", action: up) }
                    if let down = order.onMoveDown { Button("Move Down", action: down) }
                    Button(order.reorderTitle, action: order.onReorder)
                }
                if let onDelete { Button("Delete Project…", action: onDelete) }
            }
            .modifier(ProjectHeaderMenu(onRename: onRename, onNewChat: onNewChat, onDelete: onDelete, order: order))
            .accessibilityIdentifier("sessions.header")        // [sessions-m9] UI tests read the groups in order
            // [header-menus] A project's ⋯ where its row kept a place for it, past the time: over the row, not in it, so
            // the row's tap still opens and closes the project and VoiceOver finds the ⋯ on its own.
            .overlayPreferenceValue(HeaderMenuSpot.self) { spot in
                if let spot, summary != nil {
                    GeometryReader { geometry in
                        let place = geometry[spot]
                        menuButton(height: ProjectCard.face + 2 * ProjectCard.rowPad, above: 0)
                            .position(x: place.midX, y: place.midY)
                    }
                    .animation(motion, value: summary?.collapsed)   // motion-ok: nil unless a fold's unfold runs
                }
            }
            .padding(.trailing, captionButtonsWidth)
            .overlay(alignment: .trailing) {
                HStack(spacing: 0) {
                    if let onNewChat, showsNewChat {
                        Button(action: onNewChat) {
                            Image(systemName: "plus")
                                .font(Font.hq(.subheadline).weight(.semibold))
                                .foregroundStyle(Color.hqLabel2)
                                .frame(width: 44, height: Self.captionHeight)
                                // The touch reaches up into the break above the caption, as the caption's does.
                                .contentShape(.interaction, RaisedHitShape(above: Self.hitAbove))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("New Chat in \(title)")
                        .accessibilityIdentifier("sessions.header.newChat")
                    }
                    if showsCaptionMenu { menuButton(height: Self.captionHeight, above: Self.hitAbove) }
                }
            }
            .background {
                if dropTarget && summary == nil {
                    // 10 pt in from the list's edges at both ends, the full height of the header's row.
                    RoundedRectangle(cornerRadius: Theme.isDesktop ? DesktopRows.radius : 12, style: .continuous)
                        .fill(Color.hqTint.opacity(0.12))
                        .strokeBorder(Color.hqTint.opacity(0.55), lineWidth: 1.5)
                        .padding(.leading, -10)
                        .padding(.trailing, -6)
                        .accessibilityHidden(true)
                }
            }
            .animation(HQMotion.reduced ? nil : .snappy(duration: 0.2), value: dropTarget)
            // [project-cards] A card spans the list (its own insets) with a gap above and below it (none under "Projects");
            // closed projects, rows on the page, stand as close as Pinned's.
            .padding(.leading, summary == nil ? 20 : 0)
            .padding(.trailing, summary == nil ? 16 : 0)
            .padding(.top, topGap)
    }

    /// [header-menus] Room kept at a caption's end for its + and ⋯ (each 44 pt; the first reaches 8 pt over the caption).
    private var captionButtonsWidth: CGFloat {
        let buttons = (showsNewChat ? 1 : 0) + (showsCaptionMenu ? 1 : 0)
        return buttons == 0 ? 0 : CGFloat(buttons) * 44 - 8
    }

    /// [header-menus] The header's ⋯: its hold menu's items, as the hold menu lists them.
    private func menuButton(height: CGFloat, above: CGFloat) -> some View {
        HeaderMoreButton(label: "Actions for \(title)", identifier: "sessions.header.menu", glyph: desk ? 13 : 15,
                         cap: desk ? 18 : 22, height: height, above: above) {
            ProjectHeaderMenuItems(onRename: onRename, onNewChat: onNewChat, onDelete: onDelete, order: order)
        }
    }

    private var topGap: CGFloat {
        guard let summary else { return Self.breakAbove(first: first) }
        return Self.topGap(collapsed: summary.collapsed, afterCard: summary.afterCard, caption: caption != nil)
    }

    private static func topGap(collapsed: Bool, afterCard: Bool, caption: Bool) -> CGFloat {
        if caption { return collapsed ? 0 : ProjectCard.cardTop }
        return !collapsed || afterCard ? ProjectCard.gap : ProjectCard.rowGap
    }

    /// A caption's line: its text with 2 pt over and under, so it sits just above its own rows (owner, 2026-11-01:
    /// "grouped together tightly … your eyes to fall in the right place"). It was 36 pt, centred: the caption stood as
    /// far from its rows as from the group above it.
    static let captionHeight: CGFloat = 24
    /// The break above a caption, between one group's last row and the next group: wide, so each caption reads as its
    /// own rows' (the list's first, under the bar, needs less).
    static func breakAbove(first: Bool) -> CGFloat { first ? 6 : Density.compact ? 12 : 20 }   // [density]
    /// How far a caption's touch reaches up into that break. [ui-sizing 2026-11-09] All of it: with the caption, 44 pt in
    /// Standard (it was 36, under iOS's 44 for its +, ⋯, Edit and See All); Compact's break is 12.
    static var hitAbove: CGFloat { Density.compact ? 12 : 20 }

    /// Every other group's header: its caption, a favorite's star, the fold caret and (folded) its count.
    private var captionRow: some View {
        HStack(spacing: 8) {
            if let source { PlatformMark(source: source, size: Theme.isDesktop ? 16 : 20) }
            // [desktoplook2] In the look no font on the Text: one set there beats the label's (UX study #196).
            // Text.font(nil) is still a font of the Text's own (the body font), so the look's branch sets none at all.
            Group {
                if Theme.isDesktop { Text(title) } else { Text(title).font(Font.hq(.subheadline).weight(.semibold)) }
            }
            .foregroundStyle(dropTarget ? Color.hqTint : Color.hqLabel2)
            .hqDesktopLabel(color: dropTarget ? .hqTint : .hqLabel2)   // [desktoplook2] EARLIER TODAY, as the desktop's group label
            .layoutPriority(1)
            if let badge, badge > 0 { countBadge(badge) }   // [sessions-layout] New for You's count
            star
            // [sessions-collapse] The caret straight after the name, as "Projects ⌄", ahead of a See All.
            if let fold {
                caret(fold.collapsed)
                if fold.collapsed {
                    Text(fold.unread > 0 ? "\(fold.total) · \(fold.unread) unread" : "\(fold.total)")
                        .font(Font.hq(.subheadline))
                        .foregroundStyle(Color.hqLabel3)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            if let seeAll {
                Spacer(minLength: 8)
                seeAllButton(seeAll)
            }
        }
        // [project-unfold] A caption's fold changes nothing up or down: its caret and closed count move on this.
        .animation(motion, value: fold?.collapsed)   // motion-ok: nil unless a fold's unfold runs (reload skips it under Reduce Motion)
        .geometryGroup()   // [project-unfold] its move down is the list's: only what changes inside it animates
    }

    /// [sessions-layout] A count in a tinted capsule: New for You's, a project's unread.
    private func countBadge(_ count: Int) -> some View {
        Text(BadgeMath.badge(count))
            .font(Font.hq(.caption).weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(Color.hqOnTint)
            .padding(.horizontal, 7)
            .frame(minWidth: 20, minHeight: 20)
            .background(Capsule().fill(Color.hqTint))
            .accessibilityHidden(true)
    }

    /// "Projects", as the other groups' captions are drawn, and Edit on the right (Reorder Projects…).
    private func sectionCaption(_ caption: String) -> some View {
        HStack(spacing: 8) {
            // [sessions-collapse] The name, its caret and the room after it close every project (as a group's caption
            // closes its group); See All and Edit keep their own taps.
            HStack(spacing: 8) {
                Group {
                    if Theme.isDesktop { Text(caption) } else { Text(caption).font(Font.hq(.subheadline).weight(.semibold)) }
                }
                .foregroundStyle(Color.hqLabel2)
                .hqDesktopLabel(color: .hqLabel2)
                if onFoldCaption != nil {
                    Image(systemName: "chevron.down")
                        .font(Font.hq(.caption).weight(.semibold))
                        .foregroundStyle(Color.hqLabel3)
                }
                Spacer(minLength: 8)
            }
            .frame(minHeight: Self.captionHeight)
            .contentShape(.interaction, RaisedHitShape(above: onFoldCaption == nil ? 0 : Self.hitAbove))
            .onTapGesture { onFoldCaption?() }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(caption)
            .accessibilityValue(onFoldCaption == nil ? "" : "Expanded")
            .accessibilityHint(onFoldCaption == nil ? "" : "Hides the projects.")
            .accessibilityAddTraits(onFoldCaption == nil ? .isHeader : [.isHeader, .isButton])
            .accessibilityAction { onFoldCaption?() }
            .accessibilityIdentifier("sessions.projects.caption")
            if let seeAll { seeAllButton(seeAll) }
            if let onEditCaption {
                Button("Edit", action: onEditCaption)
                    .font(Font.hq(desk ? .footnote : .subheadline))
                    .foregroundStyle(Color.hqTintText)
                    .buttonStyle(.plain)
                    .frame(minWidth: 44, minHeight: Self.captionHeight, alignment: .trailing)
                    .contentShape(.interaction, RaisedHitShape(above: Self.hitAbove))
                    .accessibilityLabel("Reorder Projects")
                    .accessibilityIdentifier("sessions.projects.edit")
            }
        }
        .frame(minHeight: Self.captionHeight)
        .padding(.leading, 20)
        .padding(.trailing, 20)
        .padding(.top, Self.breakAbove(first: first))
    }

    /// [sessions-fresh] "See All 24 ⌄", or "Show Less ⌃" once every one is drawn: in the tint, as iOS's own See All
    /// (owner: in the caption's grey it did not read as a button). The chevron says which way the list goes.
    private func seeAllButton(_ seeAll: SessionSeeAll) -> some View {
        Button(action: seeAll.toggle) {
            HStack(spacing: 3) {
                Text(seeAll.expanded ? "Show Less" : "See All \(seeAll.total)")
                Image(systemName: seeAll.expanded ? "chevron.up" : "chevron.down")
                    .font(Font.hq(.caption2).weight(.semibold)).imageScale(.small)
            }
            .font(Font.hq(desk ? .footnote : .subheadline).weight(.medium))
            .foregroundStyle(Color.hqTint)
            .monospacedDigit()
            .frame(minWidth: 44, minHeight: Self.captionHeight, alignment: .trailing)
            .contentShape(.interaction, RaisedHitShape(above: Self.hitAbove))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(seeAll.expanded ? "Show Less" : "See All \(seeAll.total) \(seeAll.kind)")
        .accessibilityIdentifier("sessions.seeAll.\(seeAll.kind.lowercased())")
    }

    @ViewBuilder private var star: some View {
        if order?.favorite == true {
            // [manual-order] A favorite project, kept on top: a small star after its name.
            Image(systemName: "star.fill")
                .font(Font.hq(.caption2).weight(.semibold))
                .foregroundStyle(Color.hqLabel3)
                .accessibilityHidden(true)
        }
    }

    /// The desktop's caret after the caption: down while open, right while closed.
    @ViewBuilder private func caret(_ collapsed: Bool) -> some View {
        if fold != nil {
            Image(systemName: "chevron.down")
                .font(Font.hq(.caption).weight(.semibold))
                .foregroundStyle(Color.hqLabel3)
                .rotationEffect(.degrees(collapsed ? -90 : 0))
        }
    }

    /// What VoiceOver says first: the name (a folded group's count after it, as before). A project's row and New for
    /// You keep their name alone here and say their figures in the value.
    private var spokenLabel: String {
        if summary != nil || badge != nil { return spokenTitle }
        return fold.map { fold in fold.collapsed ? "\(spokenTitle), \(SessionHeaderFold.countWords(total: fold.total, unread: fold.unread, unit: fold.unit))" : spokenTitle } ?? spokenTitle
    }

    /// Then: Collapsed or Expanded, and [sessions-layout] a project's count, newest chat and time, or New for You's count.
    private var spokenValue: String {
        var parts = fold.map { [$0.collapsed ? "Collapsed" : "Expanded"] } ?? []
        if let summary {
            // [project-cards] Who is in it and how many, then unread, a bot at work, the newest chat.
            parts.append(summary.whoWords)
            if summary.unread > 0 { parts.append("\(summary.unread) unread") }
            if summary.working { parts.append("a bot is working") }
            if summary.collapsed, let latest = summary.latestTitle, !latest.isEmpty { parts.append("newest: \(latest)") }
            if !summary.time.isEmpty { parts.append(summary.time) }
        } else if let badge, badge > 0 {
            parts.append(SessionHeaderFold.countWords(total: badge, unread: 0))
        }
        return parts.joined(separator: ", ")
    }
}

/// [sessions-fresh] A caption's See All: how many there are, whether all are drawn, and the tap.
struct SessionSeeAll {
    var total: Int
    var expanded: Bool
    /// What it lists, for VoiceOver and the UI tests ("Pinned", "Projects").
    var kind: String
    var toggle: () -> Void
}

/// A touch area reaching `above` over the view's top and no further down: a caption's tap takes the break above it,
/// never the top of the row below (a separate cell).
nonisolated struct RaisedHitShape: Shape {
    var above: CGFloat
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY - above, width: rect.width, height: rect.height + above))
    }
}

/// [manual-order] A project or bot group's place in the list, for its header's hold menu and VoiceOver.
struct SessionHeaderOrder {
    /// A favorite project (its header shows a star). Bots have no favorites (pin a bot on the Bots tab).
    var favorite = false
    var onFavorite: (() -> Void)?
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    /// "Reorder Projects…" or "Reorder Bots…".
    var reorderTitle: String
    var onReorder: () -> Void
}

extension SessionDateHeaderView {
    /// VoiceOver says a favorite's star.
    fileprivate var spokenTitle: String { order?.favorite == true ? "\(title), Favorite" : title }
}

/// A project header's hold menu: Rename Project…, New Chat; Add to Favorites, Move Up, Move Down, Reorder Projects…;
/// then Delete Project… (red). Home's and a bot's (Group By Bot) hold only the order rows. Other headers get no menu
/// (not even an empty one).
private struct ProjectHeaderMenu: ViewModifier {
    var onRename: (() -> Void)?
    var onNewChat: (() -> Void)?
    var onDelete: (() -> Void)?
    var order: SessionHeaderOrder?

    /// [header-menus] Which headers have the menu (and so the ⋯).
    static func offered(onRename: (() -> Void)?, order: SessionHeaderOrder?) -> Bool { onRename != nil || order != nil }

    func body(content: Content) -> some View {
        if Self.offered(onRename: onRename, order: order) {
            content.contextMenu {
                ProjectHeaderMenuItems(onRename: onRename, onNewChat: onNewChat, onDelete: onDelete, order: order)
            }
        } else {
            content
        }
    }
}

/// [header-menus] The hold menu's items, for the hold and for the header's ⋯ alike.
private struct ProjectHeaderMenuItems: View {
    var onRename: (() -> Void)?
    var onNewChat: (() -> Void)?
    var onDelete: (() -> Void)?
    var order: SessionHeaderOrder?

    var body: some View {
        if let onRename {
            Button(action: onRename) { Label("Rename Project…", systemImage: "pencil") }
                .accessibilityIdentifier("sessions.header.rename")
        }
        if let onNewChat {
            Button(action: onNewChat) { Label("New Chat", systemImage: "square.and.pencil") }
        }
        if let order {
            Section {
                if let onFavorite = order.onFavorite {
                    Button(action: onFavorite) {
                        Label(order.favorite ? "Remove from Favorites" : "Add to Favorites",
                              systemImage: order.favorite ? "star.slash" : "star")
                    }
                    .accessibilityIdentifier("sessions.header.favorite")
                }
                Button(action: order.onMoveUp ?? {}) { Label("Move Up", systemImage: "arrow.up") }
                    .disabled(order.onMoveUp == nil)
                    .accessibilityIdentifier("sessions.header.moveUp")
                Button(action: order.onMoveDown ?? {}) { Label("Move Down", systemImage: "arrow.down") }
                    .disabled(order.onMoveDown == nil)
                    .accessibilityIdentifier("sessions.header.moveDown")
                Button(action: order.onReorder) { Label(order.reorderTitle, systemImage: "line.3.horizontal") }
                    .accessibilityIdentifier("sessions.header.reorder")
            }
        }
        if let onDelete {
            Divider()
            Button(role: .destructive, action: onDelete) { Label("Delete Project…", systemImage: "trash") }
        }
    }
}

/// [header-menus] Where a project's row keeps room for its ⋯ (past the time), read by its header to set the ⋯ there.
struct HeaderMenuSpot: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

/// Under a capped project: "Show More (12)" opens it in place; "Show Less" closes it to its newest chats again.
struct SessionShowMoreRow: View {
    var more: Int
    var body: some View {
        HStack(spacing: ProjectCard.columnGap) {
            // In the title's column (20 + 40 + 12), as the desktop's ellipsis lead lines up with its rows.
            Image(systemName: more > 0 ? "ellipsis" : "chevron.up")
                .font(Font.hq(.subheadline).weight(.semibold))
                .foregroundStyle(Color.hqLabel3)
                .frame(width: ProjectCard.column)   // [ui-sizing] the chat rows' column, Compact's too (was 40)
            Text(more > 0 ? "Show More (\(more))" : "Show Less")
                .font(Font.hq(.subheadline).weight(.medium))
                .foregroundStyle(Color.hqTintText)
            Spacer(minLength: 0)
        }
        .padding(.leading, 20)
        .padding(.trailing, 20)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(SessionRowWords.showMoreLabel(more))
        .accessibilityAddTraits(.isButton)
    }
}

private extension View {
    /// Kept in the layout but not drawn, touched or read, when `hide`.
    @ViewBuilder func placeOnly(_ hide: Bool) -> some View {
        if hide { hidden().accessibilityHidden(true) } else { self }
    }
}
