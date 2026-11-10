// [onboarding] The pieces the welcome and guide screens are built from (docs/spec/3x-onboarding.md §3.4, §4): the page
// scaffold, numbered steps, note and command cards, the disclosure, the status line and the choice row. Plain filled
// cards and system glass buttons; nothing here draws its own glass.

import SwiftUI
import UIKit

// MARK: - Rich text

/// The copy's small markup (OnboardingCopy.swift): `**bold**`, `[[key cap]]`, `` `code` ``, `<<text|address>>`.
nonisolated enum GuideText {
    enum Piece: Equatable, Sendable {
        case text(String), bold(String), key(String), code(String), link(String, String)
    }

    static func pieces(_ markup: String) -> [Piece] {
        var pieces: [Piece] = []
        var rest = Substring(markup)
        var plain = ""
        func flush() { if !plain.isEmpty { pieces.append(.text(plain)); plain = "" } }
        let marks: [(open: String, close: String)] = [("**", "**"), ("[[", "]]"), ("`", "`"), ("<<", ">>")]
        outer: while !rest.isEmpty {
            for (index, mark) in marks.enumerated() where rest.hasPrefix(mark.open) {
                let body = rest.dropFirst(mark.open.count)
                guard let end = body.range(of: mark.close) else { continue }
                let inner = String(body[..<end.lowerBound])
                flush()
                switch index {
                case 0: pieces.append(.bold(inner))
                case 1: pieces.append(.key(inner))
                case 2: pieces.append(.code(inner))
                default:
                    let parts = inner.split(separator: "|", maxSplits: 1).map(String.init)
                    pieces.append(parts.count == 2 ? .link(parts[0], parts[1]) : .text(inner))
                }
                rest = body[end.upperBound...]
                continue outer
            }
            plain.append(rest.removeFirst())
        }
        flush()
        return pieces
    }

    /// The words alone: what the web shows.
    static func plain(_ markup: String) -> String {
        pieces(markup).map { piece in
            switch piece {
            case .text(let s), .bold(let s), .key(let s), .code(let s), .link(let s, _): s
            }
        }.joined()
    }

    /// The words as VoiceOver should say them: key caps by name ("⌘ Space" → "Command Space").
    static func spoken(_ markup: String) -> String {
        pieces(markup).map { piece in
            switch piece {
            case .key(let s): s.replacingOccurrences(of: "⌘", with: "Command")
            case .text(let s), .bold(let s), .code(let s), .link(let s, _): s
            }
        }.joined()
    }

    static func hasKeys(_ markup: String) -> Bool { pieces(markup).contains { if case .key = $0 { true } else { false } } }
    static func hasLinks(_ markup: String) -> Bool { pieces(markup).contains { if case .link = $0 { true } else { false } } }

    /// DECISION D5: key caps are semibold text on a quiet fill (SwiftUI text cannot border a run).
    @MainActor static func attributed(_ markup: String) -> AttributedString {
        var result = AttributedString()
        for piece in pieces(markup) {
            switch piece {
            case .text(let s):
                result += AttributedString(s)
            case .bold(let s):
                var run = AttributedString(s)
                run.inlinePresentationIntent = .stronglyEmphasized
                run.foregroundColor = Color(uiColor: HQPalette.label)
                result += run
            case .key(let s):
                var run = AttributedString("\u{200A}" + s.replacingOccurrences(of: " ", with: "\u{00A0}") + "\u{200A}")
                run.inlinePresentationIntent = .stronglyEmphasized
                run.foregroundColor = Color(uiColor: HQPalette.label)
                run.backgroundColor = Color(uiColor: HQPalette.fill3)
                result += run
            case .code(let s):
                var run = AttributedString(s.replacingOccurrences(of: " ", with: "\u{00A0}"))
                run.inlinePresentationIntent = .code
                run.foregroundColor = Color(uiColor: HQPalette.label)
                run.backgroundColor = Color(uiColor: HQPalette.fill3)
                result += run
            case .link(let s, let address):
                var run = AttributedString(s)
                run.link = URL(string: address)
                run.foregroundColor = Color(uiColor: HQPalette.tint)
                result += run
            }
        }
        return result
    }
}

/// A paragraph of guide copy. Links go to `open` (the screen's `GuideLinkOpener`), never straight to the system.
struct GuideParagraph: View {
    let markup: String
    var font: Font = .body
    var color: Color = .hqLabel2
    var open: ((String) -> Void)?

    init(_ markup: String, font: Font = .body, color: Color = .hqLabel2, open: ((String) -> Void)? = nil) {
        self.markup = markup; self.font = font; self.color = color; self.open = open
    }

    var body: some View {
        let text = Text(GuideText.attributed(markup))
            .font(font)
            .foregroundStyle(color)
            .tint(Color.hqTint)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                open?(url.absoluteString)
                return .handled
            })
        if GuideText.hasKeys(markup) && !GuideText.hasLinks(markup) {
            text.accessibilityLabel(GuideText.spoken(markup))
        } else {
            text
        }
    }
}

// MARK: - Page

/// One guide screen: the heading (content, not the bar: DECISION D4), the screen's parts, and its error line.
struct GuidePage<Content: View>: View {
    let id: String
    let heading: String
    var error: String = ""
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(heading)
                    .font(Font.hq(.title).weight(.bold))
                    .foregroundStyle(Color.hqLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(id)
                content
                if !error.isEmpty {
                    Label { Text(error) } icon: { Image(systemName: "exclamationmark.circle.fill") }
                        .font(Font.hq(.callout))
                        .foregroundStyle(Color.hqRed)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier(id + ".error")
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: 440, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
            .animation(HQMotion.swiftUI(.smooth(duration: 0.2), fades: true), value: error)
        }
        .background(Color.hqPage.ignoresSafeArea())
    }
}

// MARK: - Steps, notes, cards

struct GuideSteps: View {
    let steps: [String]
    @ScaledMetric(relativeTo: .body) private var badge: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                GuideStepRow(number: index + 1, badge: badge) {
                    GuideParagraph(step, color: .hqLabel).accessibilityHidden(true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(index + 1). \(GuideText.spoken(step))")
            }
        }
    }
}

/// A numbered row: the filled circle with its digit and whatever stands beside it.
struct GuideStepRow<Content: View>: View {
    let number: Int
    let badge: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(Font.hq(.subheadline).weight(.bold))
                .foregroundStyle(.white)
                .frame(width: badge, height: badge)
                .background(Circle().fill(Color.hqTint))
                .accessibilityHidden(true)
            content
        }
    }
}

/// A filled card: wrapping text gets 14 pt above and below (the owner's row-padding rule).
struct GuideCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: HQShape.radius(14, .card), style: .continuous).fill(Color(uiColor: HQPalette.groupedCard)))
    }
}

struct GuideNote: View {
    let text: String
    var body: some View {
        GuideCard { GuideParagraph(text, font: .subheadline, color: .hqLabel) }
    }
}

/// A command or message as text to select: monospaced, wrapping anywhere.
struct GuideBlock: View {
    let text: String
    var id: String?

    var body: some View {
        Text(text)
            .font(Font.hqSystem(.footnote, design: .monospaced))
            .foregroundStyle(Color.hqLabel)
            .lineSpacing(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: HQShape.radius(10, .control), style: .continuous).fill(Color(uiColor: HQPalette.fill3)))
            .accessibilityIdentifier(id ?? "")
    }
}

/// The `role="status"` line under a card's buttons; nothing while empty.
struct GuideStatusLine: View {
    let text: String
    let id: String

    var body: some View {
        if !text.isEmpty {
            Text(text)
                .font(Font.hq(.footnote))
                .foregroundStyle(Color.hqLabel2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier(id)
                .transition(.opacity)
        }
    }
}

/// A closed-at-first section (the web's `<details>`); its state lives as long as the screen is on the stack.
struct GuideDisclosure<Content: View>: View {
    let title: String
    let id: String
    @State private var open = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                HQMotion.withAnimation(.smooth(duration: 0.25)) { open.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text(title).font(Font.hq(.body)).multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(Font.hq(.footnote).weight(.semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(Color.hqTint)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            .accessibilityIdentifier(id)
            if open { content.transition(.opacity) }
        }
    }
}

/// The card with Copy and Send…: an optional command to read, one or two glass buttons of equal width (stacked when
/// they do not fit), the status line, and an optional "Show the message".
struct CommandCard<Extra: View>: View {
    let id: String
    var block: String?
    let copyTitle: String
    var shareTitle: String?
    let feedback: GuideFeedback
    @ViewBuilder var extra: Extra
    /// The Send… button's frame in the window: where an iPad's share popover points.
    @State private var shareFrame: CGRect = .zero

    var body: some View {
        GuideCard {
            if let block { GuideBlock(text: block, id: id + ".command") }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { buttons }
                VStack(spacing: 10) { buttons }
            }
            GuideStatusLine(text: feedback.status, id: id + ".status")
            extra
        }
        .animation(HQMotion.swiftUI(.smooth(duration: 0.2), fades: true), value: feedback.status)
    }

    @ViewBuilder private var buttons: some View {
        GuideTintedButton(title: copyTitle, id: id + ".copy", fill: true) { feedback.copy() }
        if let shareTitle {
            GuideTintedButton(title: shareTitle, id: id + ".share", fill: true) { feedback.share(from: shareFrame) }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { shareFrame = $0 }
        }
    }
}

extension CommandCard where Extra == EmptyView {
    init(id: String, block: String? = nil, copyTitle: String, shareTitle: String? = nil, feedback: GuideFeedback) {
        self.init(id: id, block: block, copyTitle: copyTitle, shareTitle: shareTitle, feedback: feedback) { EmptyView() }
    }
}

// MARK: - Buttons

/// A regular-size system glass button (Copy, Send…, Get Tailscale, Copy All Steps).
struct GuideTintedButton: View {
    let title: String
    let id: String
    var fill = false
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: action) {
            // UX study #124: the words wrap rather than run off the card at the accessibility sizes. CommandCard's
            // ViewThatFits still measures them on one line, so they sit side by side only when both fit unwrapped.
            // There the label is at least 44 pt tall too; the default sizes keep 30, so no setup screen moves.
            Text(title)
                .font(Font.hq(.body).weight(.medium))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: fill ? .infinity : nil, minHeight: typeSize.isAccessibilitySize ? 44 : 30)
                .padding(.horizontal, 4)
        }
        .hqGlassButtonStyle()
        .tint(Color.hqTint)
        .accessibilityIdentifier(id)
    }
}

/// The large action at the end of a screen: prominent glass for the way on, plain glass for the other way.
struct GuideActionButton: View {
    let title: String
    let id: String
    var prominent = true
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 34

    var body: some View {
        let button = Button(action: action) {
            Text(title).font(Font.hq(.headline)).multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: height)
        }
        .controlSize(.large)
        .accessibilityIdentifier(id)
        if prominent {
            button.hqGlassProminentButtonStyle().tint(Color.hqTint)
        } else {
            button.hqGlassButtonStyle()
        }
    }
}

/// "This iPhone already uses Tailscale": turns the setup command and message into their `--private` kind (only on the
/// person's own Tailscale network, never on the internet). The choice carries to the screens after it.
struct GuideTailnetToggle: View {
    let reach: SetupReach
    let id: String
    @Environment(\.dynamicTypeSize) private var size

    var body: some View {
        let isOn = Binding(get: { reach.tailnetOnly }, set: { reach.tailnetOnly = $0 })
        // At the accessibility sizes the switch goes under the words: beside them it pushes the page past the screen.
        let layout = size.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
        GuideCard {
            layout {
                VStack(alignment: .leading, spacing: 3) {
                    Text(OnboardingCopy.Tailnet.toggleTitle).font(Font.hq(.headline)).foregroundStyle(Color.hqLabel)
                    Text(OnboardingCopy.Tailnet.toggleText).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { isOn.wrappedValue.toggle() }
                // The switch says it all to VoiceOver: its label and hint are these words.
                .accessibilityHidden(true)
                Toggle(OnboardingCopy.Tailnet.toggleTitle, isOn: isOn)
                    .labelsHidden()
                    .accessibilityHint(OnboardingCopy.Tailnet.toggleText)
                    .accessibilityIdentifier(id)
            }
        }
    }
}

/// A row of the chooser: symbol, bold title, a line under it, a chevron; 76 pt at least, 14 pt above and below.
struct GuideChoiceRow: View {
    let symbol: String
    let title: String
    let text: String
    let id: String
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var icon: CGFloat = 36

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(Font.hq(.title2))
                    .foregroundStyle(Color.hqTint)
                    .frame(width: min(icon, 58))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(Font.hq(.headline)).foregroundStyle(Color.hqLabel)
                    Text(text).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                SettingsChevron()
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(GuideRowStyle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }
}

private struct GuideRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: HQShape.radius(14, .card), style: .continuous)
                .fill(Color(uiColor: configuration.isPressed ? HQPalette.cellPressed : HQPalette.groupedCard)))
    }
}
