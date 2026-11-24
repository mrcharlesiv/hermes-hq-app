// [first-run] The redrawn first run's words, one view per screen, over the stage (ArrivalStage): Hello, Where, the note,
// Found and Hermes is here. Their places, sizes and the rise each part comes in with are the approved mock's
// (build/first-run/spec/prototype.src.html: `.col` `--zone`, `.eb`, `.h`, `.lead`, `.card`, `.notec`, `.next`, `.addr`,
// `.foot`, `.in` `--d`). The buttons sit where today's are pinned (WelcomeView's footer); the ids and closures are
// today's, so the guide's tests and debug hooks reach them as before.

import SwiftUI
import UIKit

// MARK: - Shared

/// Bumped each time its screen comes on, so the parts rise again (the mock re-runs a screen's script on every visit).
@MainActor @Observable final class ArrivalEntrance {
    var count = 0
}

/// The mock's `cubic-bezier(.2,.85,.2,1)`.
private func riseCurve(_ duration: Double) -> Animation { .timingCurve(0.2, 0.85, 0.2, 1, duration: duration) }

/// The mock's `.in`: rises 16 pt and fades in, `delay` seconds after its screen comes on (headings also unblur).
private struct ArrivalRise: ViewModifier {
    let entrance: ArrivalEntrance
    let delay: Double
    var blur = false
    @State private var shown = false
    @State private var seen = -1

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || HQMotion.reduced ? 0 : 16)
            .blur(radius: shown || !blur || HQMotion.reduced ? 0 : 8)
            .onAppear { play() }
            .onChange(of: entrance.count) { play() }
    }

    private func play() {
        guard seen != entrance.count else { return }
        seen = entrance.count
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { shown = false }
        Task { @MainActor in
            HQMotion.withAnimation(riseCurve(0.7).delay(delay), fades: true) { shown = true }
        }
    }
}

/// The mock's `.late`: hidden until its moment (Hermes is here), then rises in (headings unblur).
private struct ArrivalLate: ViewModifier {
    let on: Bool
    var blur = false

    func body(content: Content) -> some View {
        content
            .opacity(on ? 1 : 0)
            .offset(y: on || HQMotion.reduced ? 0 : 14)
            .blur(radius: on || !blur || HQMotion.reduced ? 0 : 8)
    }
}

extension View {
    fileprivate func rise(_ entrance: ArrivalEntrance, _ delay: Double, blur: Bool = false) -> some View {
        modifier(ArrivalRise(entrance: entrance, delay: delay, blur: blur))
    }

    fileprivate func late(_ on: Bool, blur: Bool = false) -> some View { modifier(ArrivalLate(on: on, blur: blur)) }
}

/// The stage and its layout, as the screens need them.
struct ArrivalKit {
    let stage: ArrivalStage
    var layout: ArrivalLayout { stage.layout }
    /// The mock's `tap` cue on every tap.
    func tap() { stage.cue(.tap) }
}

/// One screen: the words from the mock's `--zone` down (scrolling when they don't fit), the ways on pinned below them
/// as today's are, and the round glass Back at the top left on steps 2–4.
private struct ArrivalPage<Content: View, Footer: View>: View {
    let kit: ArrivalKit
    let zone: Double
    var back: (() -> Void)?
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = kit.layout
        // At the accessibility sizes the stage stands down and the words start near the top.
        let top: CGFloat = layout.standsDown || typeSize.isAccessibilitySize ? (back == nil ? 24 : 64) : layout.belowSafeTop(zone)
        ScrollView {
            VStack(spacing: 0) { content }
                .frame(maxWidth: 440)
                .padding(.horizontal, 24)
                .padding(.top, top)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) { footer }
                .frame(maxWidth: 440)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                // The words scroll under the buttons only at the accessibility sizes: the page's colour there.
                .background { if typeSize.isAccessibilitySize { Color.hqPage.ignoresSafeArea(edges: .bottom) } }
        }
        .overlay(alignment: .topLeading) {
            if let back {
                ArrivalBackButton { kit.tap(); back() }
                    .padding(.leading, 16)
                    .padding(.top, 4)
            }
        }
    }
}

private struct ArrivalBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(Font.hq(.body).weight(.semibold))
                .frame(width: 30, height: 30)
        }
        .buttonBorderShape(.circle)
        .hqGlassButtonStyle()
        .tint(Color.hqLabel)
        .accessibilityLabel(OnboardingCopy.Arrival.back)
        .accessibilityIdentifier("onboarding.arrival.back")
    }
}

/// The mock's `.eb`: small capitals over a heading.
private struct ArrivalEyebrow: View {
    let text: String
    @ScaledMetric(relativeTo: .footnote) private var size: CGFloat = 12.5

    var body: some View {
        Text(text.uppercased())
            .font(Font.hqSystem(size: size, weight: .semibold))
            .tracking(size * 0.1)
            .foregroundStyle(Color.hqLabel2)
            .padding(.bottom, 8)
    }
}

/// The mock's `.h` (32 pt) and `.h.big` (37 pt), centred, tight.
private struct ArrivalHeading: View {
    let text: String
    var big = false
    var id: String?
    @ScaledMetric(relativeTo: .largeTitle) private var regular: CGFloat = 32
    @ScaledMetric(relativeTo: .largeTitle) private var large: CGFloat = 37

    var body: some View {
        let size = big ? large : regular
        Text(text)
            .font(Font.hqSystem(size: size, weight: .bold))
            .tracking(-0.03 * size)
            .lineSpacing(big ? 0 : 1)
            .foregroundStyle(Color.hqLabel)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(id ?? "")
    }
}

/// The mock's `.lead`: 17 pt, secondary, at most 322 pt wide.
private struct ArrivalLead: View {
    let text: String
    @ScaledMetric(relativeTo: .body) private var width: CGFloat = 322

    var body: some View {
        Text(text)
            .font(Font.hq(.body))
            .foregroundStyle(Color.hqLabel2)
            .lineSpacing(4)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: min(width, 440))
            .padding(.top, 10)
    }
}

/// The mock's `.btn.t`: a quiet text button in the tint.
private struct ArrivalQuietButton: View {
    let title: String
    let id: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Font.hq(.body).weight(.medium))
                .foregroundStyle(Color.hqTint)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

/// "This iPhone already uses Tailscale" as one quiet line with a tick (today's card and switch stood half under the
/// pinned buttons here). Its words and what it does are today's (`OnboardingCopy.Tailnet`, `SetupReach`).
private struct ArrivalTailnetRow: View {
    let reach: SetupReach
    let id: String
    let tapped: () -> Void

    var body: some View {
        Button {
            tapped()
            reach.tailnetOnly.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: reach.tailnetOnly ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(reach.tailnetOnly ? Color.hqTint : Color.hqLabel2)
                    .accessibilityHidden(true)
                Text(OnboardingCopy.Tailnet.toggleTitle)
                    .foregroundStyle(reach.tailnetOnly ? Color.hqLabel : Color.hqLabel2)
                    .multilineTextAlignment(.leading)
            }
            .font(Font.hq(.subheadline))
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityHint(OnboardingCopy.Tailnet.toggleText)
        .accessibilityAddTraits(reach.tailnetOnly ? .isSelected : [])
    }
}

/// A large button with a symbol before its words (Send to My Hermes, Copy It Instead).
private struct ArrivalIconButton: View {
    let title: String
    let symbol: String
    let id: String
    var prominent = true
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 34

    var body: some View {
        let button = Button(action: action) {
            Label { Text(title) } icon: { Image(systemName: symbol) }
                .font(Font.hq(.headline))
                .frame(maxWidth: .infinity, minHeight: height)
        }
        .controlSize(.large)
        .accessibilityIdentifier(id)
        if prominent { button.hqGlassProminentButtonStyle().tint(Color.hqTint) } else { button.hqGlassButtonStyle() }
    }
}

/// The mock's card surface (`--cd` with a hairline inside).
private struct ArrivalCardBackground: View {
    var radius: CGFloat = 24
    var pressed = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: HQShape.radius(radius, .card), style: .continuous)
        shape.fill(Color(uiColor: pressed ? HQPalette.cellPressed : HQPalette.groupedCard))
            .overlay(shape.strokeBorder(pressed ? Color.hqTint : Color.hqLabel.opacity(0.09), lineWidth: pressed ? 2 : 1))
    }
}

// MARK: - Hello

struct ArrivalHelloView: View {
    let kit: ArrivalKit
    let entrance: ArrivalEntrance
    let go: (OnboardingStep) -> Void
    @ScaledMetric(relativeTo: .footnote) private var brandSize: CGFloat = 13
    @ScaledMetric(relativeTo: .subheadline) private var trustSize: CGFloat = 14.5
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var wordGap: CGFloat = 8

    var body: some View {
        let copy = OnboardingCopy.Welcome.self
        ArrivalPage(kit: kit, zone: 420) {
            heading
            ArrivalLead(text: OnboardingCopy.Arrival.helloLead).rise(entrance, 1.9)
        } footer: {
            HStack(spacing: 8) {
                Image(systemName: "lock").accessibilityHidden(true)
                Text(OnboardingCopy.Arrival.trust)
            }
            .font(Font.hqSystem(size: trustSize))
            .foregroundStyle(Color.hqLabel2)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .padding(.bottom, 6)
            .rise(entrance, 2.1)
            GuideActionButton(title: copy.start, id: "onboarding.welcome.start") { kit.tap(); go(.start) }
                .rise(entrance, 2.25)
            GuideActionButton(title: copy.haveAddress, id: "onboarding.welcome.address", prominent: false) { kit.tap(); go(.connect) }
                .rise(entrance, 2.33)
        }
        .overlay(alignment: .top) {
            if !kit.layout.standsDown, !typeSize.isAccessibilitySize {
                HStack(spacing: 8) {
                    WornAppIcon(side: 22)
                    Text(OnboardingCopy.Arrival.brand.uppercased())
                        .font(Font.hqSystem(size: brandSize, weight: .semibold))
                        .tracking(brandSize * 0.12)
                        .foregroundStyle(Color.hqLabel2)
                }
                .padding(.top, 12)
                .accessibilityHidden(true)   // the heading says it all; the app's name is the screen's own
                .rise(entrance, 0.2)
            }
        }
    }

    /// "Your Hermes, wherever you are.", each word rising in after the last (the mock's `.hello-h span`).
    @ViewBuilder private var heading: some View {
        let copy = OnboardingCopy.Welcome.self
        let lines = [copy.headingLine1, copy.headingLine2].map { $0.split(separator: " ").map(String.init) }
        let delays = [[1.2, 1.28], [1.46, 1.54, 1.62]]
        Group {
            if typeSize.isAccessibilitySize {
                ArrivalHeading(text: copy.headingLine1 + "\n" + copy.headingLine2, big: true).rise(entrance, 1.2, blur: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(lines.indices, id: \.self) { line in
                        // The gap is a space's width at this size: a trailing space in a Text isn't measured.
                        HStack(spacing: wordGap) {
                            ForEach(lines[line].indices, id: \.self) { word in
                                ArrivalHeading(text: lines[line][word], big: true)
                                    .rise(entrance, delays[line][min(word, delays[line].count - 1)], blur: true)
                            }
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(copy.headingLine1 + " " + copy.headingLine2)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("onboarding.welcome")
    }
}

// MARK: - Where

struct ArrivalWhereView: View {
    let kit: ArrivalKit
    let entrance: ArrivalEntrance
    let go: (OnboardingStep) -> Void
    let back: () -> Void
    let cloud: (() -> Void)?
    let access: (() -> Void)?

    var body: some View {
        let copy = OnboardingCopy.Arrival.self
        ArrivalPage(kit: kit, zone: 196, back: back) {
            ArrivalEyebrow(text: copy.whereEyebrow).rise(entrance, 0)
            ArrivalHeading(text: OnboardingCopy.Start.heading, id: "onboarding.start").rise(entrance, 0.06, blur: true)
            ArrivalLead(text: copy.whereLead).rise(entrance, 0.12)
            VStack(spacing: 10) {
                ArrivalChoiceRow(symbol: "laptopcomputer", title: copy.computerTitle, text: copy.computerText,
                                 id: "onboarding.start." + OnboardingCopy.Start.computerID) { kit.tap(); go(.hermes) }
                    .rise(entrance, 0.2)
                if let cloud {
                    ArrivalChoiceRow(symbol: OnboardingCopy.Cloud.symbol, title: OnboardingCopy.Cloud.title, text: OnboardingCopy.Cloud.text,
                                     id: "onboarding.start." + OnboardingCopy.Cloud.id) { kit.tap(); cloud() }
                        .rise(entrance, 0.27)
                }
                ArrivalChoiceRow(symbol: "plus", title: copy.noneTitle, text: copy.noneText,
                                 id: "onboarding.start." + OnboardingCopy.Start.noneID) { kit.tap(); go(.getHermes) }
                    .rise(entrance, 0.34)
            }
            .padding(.top, 24)
        } footer: {
            if let access {
                ArrivalQuietButton(title: copy.cloudflare, id: "onboarding.start." + OnboardingCopy.Start.accessID) { kit.tap(); access() }
                    .rise(entrance, 0.45)
            }
        }
    }
}

/// The mock's `.card`: a tinted tile, a bold title over a line, a chevron; 82 pt at least.
private struct ArrivalChoiceRow: View {
    let symbol: String
    let title: String
    let text: String
    let id: String
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var tile: CGFloat = 50
    @ScaledMetric(relativeTo: .body) private var titleSize: CGFloat = 18
    @ScaledMetric(relativeTo: .subheadline) private var textSize: CGFloat = 14.5

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(Font.hq(.title2))
                    .foregroundStyle(Color.hqTint)
                    .frame(width: min(tile, 72), height: min(tile, 72))
                    .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.hqTint.opacity(0.15)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Font.hqSystem(size: titleSize, weight: .semibold)).tracking(-0.02 * titleSize).foregroundStyle(Color.hqLabel)
                    Text(text).font(Font.hqSystem(size: textSize)).foregroundStyle(Color.hqLabel2)
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                SettingsChevron()
            }
            .padding(.vertical, 14)
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(ArrivalCardStyle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }
}

private struct ArrivalCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(ArrivalCardBackground(pressed: configuration.isPressed))
            .scaleEffect(configuration.isPressed && !HQMotion.reduced ? 0.975 : 1)
            .animation(HQMotion.swiftUI(.easeOut(duration: 0.18)), value: configuration.isPressed)
    }
}

// MARK: - The note

/// The note screen's state: what Send and Copy did, and the note's flight once it has gone.
@MainActor @Observable final class ArrivalNoteModel {
    let reach: SetupReach
    @ObservationIgnored private let actions: GuideActions
    @ObservationIgnored let kit: ArrivalKit
    /// Today's line under the buttons (a copy or share that failed); empty otherwise.
    private(set) var status = ""
    private(set) var sent = false
    /// The card has flown into the globe.
    private(set) var flown = false
    /// The heading and lead say it has gone (they fade out and back in as they change).
    private(set) var saysSent = false
    private(set) var wordsOut = false
    private(set) var nextOn = false
    var readingAll = false

    init(actions: GuideActions, reach: SetupReach, kit: ArrivalKit) {
        self.actions = actions; self.reach = reach; self.kit = kit
    }

    /// What Send and Copy hand over (today's message, or its Tailscale kind).
    var text: String { OnboardingCopy.FeedbackKind.agent.text(tailnetOnly: reach.tailnetOnly) }

    func copy() {
        kit.tap()
        status = ""
        if actions.copy(text) { leave() } else { say(OnboardingCopy.FeedbackKind.agent.couldNotCopy) }
    }

    /// The note leaves only on a share that completed; a cancelled one changes nothing.
    func share(from anchor: CGRect?) {
        kit.tap()
        status = ""
        let opened: Bool
        if let reporting = actions.shareReporting {
            opened = reporting(text, anchor) { [weak self] completed in if completed { self?.leave() } }
        } else {
            opened = actions.share(text, anchor)
        }
        if !opened { say(OnboardingCopy.couldNotShare) }
    }

    private func say(_ line: String) {
        status = line
        actions.announce(line)
    }

    /// The mock's S[2] after the tap: the card flies, the note leaves over the horizon, the words change.
    private func leave() {
        guard !sent else { return }
        sent = true
        kit.stage.noteSent()
        let still = kit.stage.still
        // motion-ok: the card's flight is the mock's (`.notec.fly`); Reduce Motion fades it instead (HQMotion.swiftUI).
        HQMotion.withAnimation(.timingCurve(0.6, -0.1, 0.7, 0.4, duration: 0.45), fades: true) { flown = true }
        Task { @MainActor [weak self] in
            if !still { try? await Task.sleep(for: .milliseconds(380)) }
            guard let self else { return }
            HQMotion.withAnimation(.easeOut(duration: 0.19), fades: true) { self.wordsOut = true }
            if !still { try? await Task.sleep(for: .milliseconds(190)) }
            self.saysSent = true
            HQMotion.withAnimation(.easeOut(duration: 0.2), fades: true) { self.wordsOut = false }
            HQMotion.withAnimation(riseCurve(0.6).delay(0.3), fades: true) { self.nextOn = true }
            self.actions.announce(OnboardingCopy.Arrival.sentHeading)
        }
    }
}

struct ArrivalNoteView: View {
    let kit: ArrivalKit
    let entrance: ArrivalEntrance
    @State var model: ArrivalNoteModel
    let go: (OnboardingStep) -> Void
    let back: () -> Void
    @State private var sendFrame: CGRect = .zero
    @ScaledMetric(relativeTo: .body) private var noteSize: CGFloat = 17
    @ScaledMetric(relativeTo: .footnote) private var toSize: CGFloat = 12.5
    @ScaledMetric(relativeTo: .subheadline) private var linkSize: CGFloat = 14.5

    var body: some View {
        let copy = OnboardingCopy.Arrival.self
        ArrivalPage(kit: kit, zone: 250, back: back) {
            ArrivalEyebrow(text: copy.noteEyebrow).rise(entrance, 0)
            ArrivalHeading(text: model.saysSent ? copy.sentHeading : copy.noteHeading, id: "onboarding.hermes")
                .opacity(model.wordsOut ? 0 : 1)
                .rise(entrance, 0.06, blur: true)
            ArrivalLead(text: model.saysSent ? copy.sentLead : copy.noteLead)
                .opacity(model.wordsOut ? 0 : 1)
                .rise(entrance, 0.12)
            ZStack(alignment: .top) {
                if model.nextOn || model.saysSent { next.late(model.nextOn) }
                if !model.flown || !model.saysSent { card.rise(entrance, 0.22) }
            }
            .padding(.top, 24)
            .frame(maxWidth: .infinity, minHeight: 170, alignment: .top)
            GuideStatusLine(text: model.status, id: "onboarding.hermes.status")
                .foregroundStyle(Color.hqRed)
                .padding(.top, 10)
                .animation(HQMotion.swiftUI(.smooth(duration: HQMotion.fade), fades: true), value: model.status)
            if !model.sent {
                ArrivalTailnetRow(reach: model.reach, id: "onboarding.hermes.tailnet") { kit.tap() }
                    .rise(entrance, 0.5)
            }
        } footer: {
            if model.sent {
                GuideActionButton(title: copy.haveAddress, id: "onboarding.hermes.have-address", prominent: false) { kit.tap(); go(.connect) }
                    .late(model.nextOn)
                ArrivalQuietButton(title: copy.myself, id: "onboarding.hermes.myself") { kit.tap(); go(.where) }
                    .late(model.nextOn)
            } else {
                ArrivalIconButton(title: copy.send, symbol: "paperplane", id: "onboarding.hermes.share") { model.share(from: sendFrame) }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { sendFrame = $0 }
                    .rise(entrance, 0.34)
                ArrivalIconButton(title: copy.copy, symbol: "doc.on.doc", id: "onboarding.hermes.copy", prominent: false) { model.copy() }
                    .rise(entrance, 0.4)
            }
        }
        .sheet(isPresented: $model.readingAll) { wholeNote }
    }

    /// The mock's `.notec`: who it's for, Read it all, and the note's start in a book face.
    private var card: some View {
        let copy = OnboardingCopy.Arrival.self
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(copy.noteTo.uppercased())
                    .font(Font.hqSystem(size: toSize, weight: .semibold))
                    .tracking(toSize * 0.08)
                    .foregroundStyle(Color.hqLabel2)
                    .accessibilityHidden(true)
                Spacer(minLength: 8)
                Button(copy.readAll) { kit.tap(); model.readingAll = true }
                    .font(Font.hqSystem(size: linkSize, weight: .medium))
                    .foregroundStyle(Color.hqTint)
                    .buttonStyle(.plain)
                    .frame(minHeight: 30)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("onboarding.hermes.show-message")
            }
            Text(copy.excerpt(model.text))
                .font(Font.hqSystem(size: noteSize, design: .serif))
                .foregroundStyle(Color.hqLabel)
                .lineSpacing(noteSize * 0.2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(copy.noteTo + ": " + copy.excerpt(model.text))
        }
        .padding(.top, 14)
        .padding(.horizontal, 16)
        .padding(.bottom, 15)
        .background(ArrivalCardBackground(radius: 22))
        .scaleEffect(model.flown && !HQMotion.reduced ? 0.04 : 1)
        .offset(y: model.flown && !HQMotion.reduced ? -300 : 0)
        .opacity(model.flown ? 0 : 1)
        .multilineTextAlignment(.leading)
        .accessibilityElement(children: .contain)
    }

    /// The mock's `.next`: three numbered lines saying what happens now.
    private var next: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(OnboardingCopy.Arrival.next.enumerated()), id: \.offset) { index, line in
                HStack(spacing: 14) {
                    Text("\(index + 1)")
                        .font(Font.hq(.subheadline).weight(.bold))
                        .foregroundStyle(Color.hqLabel2)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color(uiColor: HQPalette.fill3)))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(line.title).font(Font.hq(.body)).foregroundStyle(Color.hqLabel)
                        Text(line.text).font(Font.hqSystem(size: linkSize)).foregroundStyle(Color.hqLabel2)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(index + 1). \(line.title). \(line.text)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .multilineTextAlignment(.leading)
        .accessibilityIdentifier("onboarding.hermes.next")
    }

    /// Read it all: the whole note, to read or select.
    private var wholeNote: some View {
        NavigationStack {
            ScrollView {
                GuideBlock(text: model.text, id: "onboarding.hermes.message").padding(20)
            }
            .background(Color.hqPage.ignoresSafeArea())
            .navigationTitle(OnboardingCopy.Arrival.wholeNote)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(OnboardingCopy.Arrival.done) { model.readingAll = false }
                        .accessibilityIdentifier("onboarding.hermes.message.done")
                }
            }
        }
    }
}

// MARK: - Found

/// The connect step's state in the first run: Found (an address that came by link) or today's whole form.
@MainActor @Observable final class ArrivalConnectState {
    /// Today's form (typed addresses, errors, notes from the probe, Use a Password Instead).
    var full = true { didSet { if full != oldValue { onChange?() } } }
    /// Signed in: the face is on its way (the button keeps saying Signing in… while the bots are read).
    var arriving = false
    @ObservationIgnored var onChange: (() -> Void)?
}

struct ArrivalConnectView: View {
    let kit: ArrivalKit
    let entrance: ArrivalEntrance
    let model: SignInModel
    let state: ArrivalConnectState
    let back: () -> Void

    var body: some View {
        if state.full {
            SignInView(model: model)
                .background(Color.hqPage.ignoresSafeArea())
        } else {
            ArrivalFoundView(kit: kit, entrance: entrance, model: model, state: state, back: back)
                .transition(.opacity)
        }
    }
}

private struct ArrivalFoundView: View {
    let kit: ArrivalKit
    let entrance: ArrivalEntrance
    let model: SignInModel
    let state: ArrivalConnectState
    let back: () -> Void
    @ScaledMetric(relativeTo: .subheadline) private var pillSize: CGFloat = 14

    private var signingIn: Bool { model.busy == .nous || state.arriving }
    private var waysKnown: Bool { model.waysAreCurrent }
    private var nousOffered: Bool { !waysKnown || model.ways?.showsNous == true }

    var body: some View {
        let copy = OnboardingCopy.Arrival.self
        ArrivalPage(kit: kit, zone: 290, back: signingIn ? nil : back) {
            ArrivalEyebrow(text: copy.foundEyebrow).rise(entrance, 1.0)
            ArrivalHeading(text: copy.foundHeading, id: "onboarding.found").rise(entrance, 1.06, blur: true)
            ArrivalLead(text: copy.foundLead).rise(entrance, 1.12)
            pill.padding(.top, 20).rise(entrance, 1.22)
        } footer: {
            if nousOffered {
                Button {
                    kit.tap()
                    model.signInWithNous()
                } label: {
                    HStack(spacing: 8) {
                        if signingIn { ProgressView().tint(Color.white) }
                        Text(signingIn ? copy.signingIn : model.browserTitle)
                    }
                    .font(Font.hq(.headline))
                    .frame(maxWidth: .infinity, minHeight: 34)
                }
                .controlSize(.large)
                .hqGlassProminentButtonStyle()
                .tint(Color.hqTint)
                .disabled(!waysKnown || signingIn)
                .accessibilityIdentifier("onboarding.found.nous")
                .rise(entrance, 1.35)
                ArrivalQuietButton(title: copy.usePassword, id: "onboarding.found.password") { kit.tap(); state.full = true }
                    .disabled(signingIn)
                    .rise(entrance, 1.42)
            } else {
                // This Hermes takes a password only: that is the way on.
                GuideActionButton(title: copy.usePassword, id: "onboarding.found.password") { kit.tap(); state.full = true }
                    .disabled(state.arriving)
                    .rise(entrance, 1.35)
            }
        }
        .onChange(of: model.busy == .nous) { _, on in kit.stage.scanning(on) }
        .onChange(of: model.error) { _, error in if error != nil { state.full = true } }
        .onChange(of: model.note) { _, note in if note != nil, !model.checking { state.full = true } }
    }

    /// The mock's `.addr`: the address's host in a pill, with "Reachable" when the probe found Hermes answering there.
    private var pill: some View {
        let reachable = model.reachable && model.waysAreCurrent
        let host = URL(string: SignInAddress.normalize(model.address))?.host() ?? model.address
        return HStack(spacing: 9) {
            Circle()
                .fill(reachable ? Color.hqGreen : Color.hqLabel2.opacity(0.5))
                .frame(width: 9, height: 9)
                .background(Circle().fill((reachable ? Color.hqGreen : Color.clear).opacity(0.22)).padding(-4))
                .accessibilityHidden(true)
            Text(host)
                .font(Font.hqSystem(size: pillSize, design: .monospaced))
                .foregroundStyle(Color.hqLabel2)
                .lineLimit(1)
                .truncationMode(.middle)
            if reachable {
                Text(OnboardingCopy.Arrival.reachable)
                    .font(Font.hqSystem(size: pillSize, weight: .semibold))
                    .foregroundStyle(Color.hqGreen)
            }
        }
        .padding(.vertical, 10)
        .padding(.leading, 13)
        .padding(.trailing, 16)
        .background(ArrivalCardBackground(radius: 99))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("onboarding.found.address")
    }
}

// MARK: - Hermes is here

/// What the arrival knows about the bots once it has asked (nothing is guessed: `others` stays empty unless the list
/// came in time).
nonisolated struct ArrivalRoster: Sendable {
    struct Other: Sendable { var name: String; var head: JSONValue? }
    /// The arriving bot's profile name and its head record (nil: the default head).
    var profile = "default"
    var head: JSONValue?
    /// The list came in time (else nothing below is known: no others are shown).
    var known = false
    /// The others that came with it, in the gateway's order.
    var others: [Other] = []
}

struct ArrivalHereView: View {
    let kit: ArrivalKit
    let beats: ArrivalHereBeats
    let roster: ArrivalRoster
    let sayHello: () -> Void
    @ScaledMetric(relativeTo: .subheadline) private var othersSize: CGFloat = 15

    var body: some View {
        let copy = OnboardingCopy.Arrival.self
        ArrivalPage(kit: kit, zone: roster.others.isEmpty ? 456 : 438) {
            ArrivalHeading(text: copy.hereHeading, big: true, id: "onboarding.here")
                .late(beats.heading, blur: true)
            ArrivalLead(text: copy.hereLead).late(beats.lead)
            if !roster.others.isEmpty {
                VStack(spacing: 10) {
                    HStack(spacing: 14) {
                        ForEach(roster.others.prefix(3), id: \.name) { other in
                            HeadImage(raw: other.head, profile: other.name, size: 44)
                        }
                    }
                    .accessibilityHidden(true)
                    Text(copy.others(roster.others.count))
                        .font(Font.hqSystem(size: othersSize))
                        .foregroundStyle(Color.hqLabel2)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("onboarding.here.others")
                }
                .padding(.top, 22)
                .late(beats.others)
            }
        } footer: {
            GuideActionButton(title: copy.sayHello, id: "onboarding.here.hello") { kit.tap(); sayHello() }
                .late(beats.button)
                .disabled(!beats.button)
        }
    }
}

/// Hermes is here: not a step of the guide (nothing goes back from it). The real face sits over the words where the
/// stage drew its own, and takes over from it once the eyes are open.
final class ArrivalHereController: UIHostingController<HQScaledRoot<AnyView>> {
    let face: HeadView
    private let stage: ArrivalStage
    private let beats: ArrivalHereBeats
    private let watch = ArrivalWatchGesture(target: nil, action: nil)
    /// How much of its picture the head's body fills across.
    private var fill: CGFloat = 1

    init(kit: ArrivalKit, beats: ArrivalHereBeats, roster: ArrivalRoster, sayHello: @escaping () -> Void) {
        stage = kit.stage
        self.beats = beats
        face = HeadView(side: 120)
        super.init(rootView: HQScaledRoot(AnyView(ArrivalHereView(kit: kit, beats: beats, roster: roster, sayHello: sayHello)
            .environment(kit.layout))))
        face.configure(raw: roster.head, profile: roster.profile, follows: true)
        let head = Head.resolve(roster.head, profile: roster.profile)
        fill = head.theme == .shape && head.tile == .none ? 984.0 / 1024 : 1
    }

    @available(*, unavailable) required dynamic init?(coder: NSCoder) { fatalError("not from a storyboard") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        face.alpha = 0
        face.isUserInteractionEnabled = false
        face.isAccessibilityElement = false
        face.accessibilityElementsHidden = true
        view.addSubview(face)
        watch.space = stage.touch
        watch.onMove = { [weak self] point in self?.stage.watch(point) }
        view.addGestureRecognizer(watch)
        observe()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        placeFace()
    }

    /// The real face over the drawn one: same middle, the same body size. A Shapes head with no tile fills 984 of its
    /// picture's 1024 (`HeadGeometry.placement`); any other head's picture is the face itself.
    private func placeFace() {
        let centre = stage.viewPoint(x: 195, y: beats.faceY)
        let side = CGFloat(beats.faceR * 2 * stage.layout.k) / fill
        let local = view.convert(centre, from: stage.touch)
        let transform = face.transform
        face.transform = .identity
        face.frame = CGRect(x: local.x - side / 2, y: local.y - side / 2, width: side, height: side)
        face.transform = transform
    }

    private func observe() {
        withObservationTracking {
            _ = beats.realFace
            _ = beats.faceY
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.placeFace()
                if self.beats.realFace, self.face.alpha == 0 {
                    self.stage.handOver(to: self.face)
                    HQMotion.animate(0.25, fading: self.face, changes: { self.face.alpha = 1 })
                }
                self.observe()
            }
        }
    }
}
