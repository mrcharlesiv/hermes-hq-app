// [talk] Audio in the composer's tray plays in a preview sheet (docs/spec/3x-talk.md §11, row L411; the web's
// `src/phone-audio-preview.tsx`): a glyph, the file's name, its size and kind, and a player. It drives the app's one
// memo player, so starting it stops a memo bubble that plays and the other way round, and closing the sheet stops the
// playback it started.

import AVFAudio
import SwiftUI
import UIKit

@MainActor enum AudioPreview {
    struct Item {
        var title: String
        /// A voice memo shows the microphone; any other audio the waveform.
        var isMemo = false
        var bytes: Int64?
        /// The file's name, for the kind ("M4A audio").
        var name: String
        /// The player's key for this audio.
        var path: String
        /// Finds (or downloads) the file to play.
        var resolve: @MainActor () async throws -> URL

        static func local(_ url: URL, title: String? = nil, bytes: Int64?, isMemo: Bool = false) -> Item {
            Item(title: title ?? url.lastPathComponent, isMemo: isMemo, bytes: bytes, name: url.lastPathComponent, path: url.path) {
                guard FileManager.default.fileExists(atPath: url.path) else { throw HTTPError(status: 404, body: "missing") }
                return url
            }
        }
    }

    @discardableResult
    static func present(_ item: Item, from presenter: UIViewController) -> Bool {
        guard presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil else { return false }
        let model = AudioPreviewModel(item: item)
        let page = AudioPreviewController(model: model)
        let navigation = UINavigationController(rootViewController: page)
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController {
            let fit = UISheetPresentationController.Detent.custom(identifier: .init("audio.preview.fit")) { [weak page] context in
                min(context.maximumDetentValue, page?.fittingHeight ?? 320)
            }
            sheet.detents = [fit]
            // As every other chat sheet (ChatSheet.wrap): no grabber. [glass-design] On Liquid Glass like them, with the
            // player on its own solid card, so the chat's bubbles never show through the words or the scrubber; the
            // Desktop Look keeps the opaque grouped page.
            sheet.prefersGrabberVisible = false
            sheet.hqGlassPage()
        }
        presenter.present(navigation, animated: true)
        return true
    }
}

@MainActor @Observable final class AudioPreviewModel {
    enum Phase: Equatable { case loading, ready, failed }

    let item: AudioPreview.Item
    private(set) var phase = Phase.loading
    private(set) var playing = false
    /// The player is fetching or opening the file after Play was pressed.
    private(set) var starting = false
    private(set) var elapsed = 0.0
    private(set) var total = 0.0
    /// While the scrubber is dragged the player's clock does not move it.
    var dragging = false
    /// The content's own height as SwiftUI laid it out (the sheet is exactly this tall under its bar).
    @ObservationIgnored var contentHeight: CGFloat = 0 {
        didSet { if abs(contentHeight - oldValue) > 0.5 { onContentHeight?() } }
    }
    @ObservationIgnored var onContentHeight: (() -> Void)?
    @ObservationIgnored private var observer: (any NSObjectProtocol)?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var load: Task<Void, Never>?
    /// This sheet started the playback (closing it stops only that).
    @ObservationIgnored private var started = false
    @ObservationIgnored private var open = false

    init(item: AudioPreview.Item) { self.item = item }

    private var player: MemoPlayer { .shared }

    /// The sheet came up: the file is found and measured; nothing plays until Play is pressed (as on the web).
    func appeared() {
        guard !open else { return }
        open = true
        observer = NotificationCenter.default.addObserver(forName: MemoPlayer.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.read() } }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
        measure()
    }

    private func measure() {
        phase = .loading
        player.forgetFailure(item.path)
        let resolve = item.resolve
        load?.cancel()
        load = Task { [weak self] in
            do {
                let url = try await resolve()
                let seconds = try await Task.detached(priority: .userInitiated) { try AVAudioPlayer(contentsOf: url).duration }.value
                guard let self, self.open, !Task.isCancelled else { return }
                guard seconds.isFinite, seconds > 0 else { throw HTTPError(status: 415, body: "empty") }
                self.total = seconds
                self.phase = .ready
                self.read()
            } catch {
                guard let self, self.open, !Task.isCancelled else { return }
                self.phase = .failed
            }
        }
    }

    /// Closing the sheet stops the playback it started.
    func closed() {
        guard open else { return }
        open = false
        load?.cancel()
        ticker?.invalidate()
        ticker = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if started, player.isCurrent(item.path) { player.stop() }
        started = false
    }

    /// Play or pause; on a failure, try again.
    func toggle() {
        switch phase {
        case .loading: return
        case .failed: measure()
        case .ready:
            started = true
            player.toggle(item.path, resolve: item.resolve)
            read()
        }
    }

    func seek(to fraction: Double) {
        guard phase == .ready, total > 0 else { return }
        let fraction = max(0, min(1, fraction))
        if player.isCurrent(item.path) {
            let wasPlaying = player.state(of: item.path) == .playing
            player.seek(item.path, to: fraction, resolve: item.resolve)
            if !wasPlaying { elapsed = fraction * total }
        } else {
            // Not loaded into the player yet: it loads and plays from there.
            started = true
            player.seek(item.path, to: fraction, resolve: item.resolve)
        }
        read()
    }

    var fraction: Double { total > 0 ? max(0, min(1, elapsed / total)) : 0 }

    private func read() {
        guard open, phase != .loading else { return }
        let path = item.path
        if player.failed.contains(path) {
            if phase != .failed { phase = .failed }
            if playing { playing = false }
            if starting { starting = false }
            return
        }
        guard phase == .ready else { return }
        guard player.isCurrent(path) else {
            // Nothing of this file is in the player (never played, or another memo took it).
            if playing { playing = false }
            if starting { starting = false }
            return
        }
        let state = player.state(of: path)
        if (state == .loading) != starting { starting = state == .loading }
        if (state == .playing) != playing { playing = state == .playing }
        if player.duration > 0, abs(player.duration - total) > 0.01 { total = player.duration }
        if !dragging {
            let time = player.currentTime(path)
            if abs(time - elapsed) > 0.01 { elapsed = time }
        }
    }
}

final class AudioPreviewController: UIHostingController<HQScaledRoot<AudioPreviewView>> {
    private let model: AudioPreviewModel

    init(model: AudioPreviewModel) {
        self.model = model
        super.init(rootView: HQScaledRoot(AudioPreviewView(model: model)))
        // The ✕ leads and the bar has a title, as on the chat's other sheets (ChatSheet.wrap).
        title = model.item.isMemo ? "Voice Memo" : "Audio"
        navigationItem.largeTitleDisplayMode = .never
        let close = UIBarButtonItem.hqClose(action: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        close.accessibilityIdentifier = "audio.preview.close"
        navigationItem.hqPlaceClose(close)   // [mac] Stress test 2026-10-28 #55: trailing on the Mac
        model.onContentHeight = { [weak self] in
            guard let sheet = self?.navigationController?.sheetPresentationController else { return }
            sheet.animateChanges { sheet.invalidateDetents() }
        }
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The one detent: the bar, the content as tall as it lays out at this width and text size, and a little air.
    /// (A custom detent's value leaves the bottom safe area out, so the home indicator's strip comes on top of this.)
    var fittingHeight: CGFloat {
        let bar = navigationController?.navigationBar.frame.height ?? 0
        let content = model.contentHeight > 0 ? model.contentHeight : 216
        return ceil(content + max(44, bar) + 12)
    }

    #if DEBUG
    /// Screenshots: playing from part of the way in.
    func debugPlay(from fraction: Double) {
        model.seek(to: fraction)
    }
    #endif

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (page: AudioPreviewController, _) in
            page.navigationController?.sheetPresentationController?.invalidateDetents()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        model.appeared()
        navigationController?.sheetPresentationController?.invalidateDetents()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        model.closed()
    }
}

struct AudioPreviewView: View {
    let model: AudioPreviewModel
    @State private var dragValue = 0.0
    @Environment(\.dynamicTypeSize) private var typeSize
    // UX study #226: the header and Play glyphs grow with the text, capped so the header stays a glyph and Play fits
    // its 44 pt circle until that grows too.
    @ScaledMetric(relativeTo: .title) private var headerGlyph: CGFloat = 34
    @ScaledMetric(relativeTo: .body) private var playGlyph: CGFloat = 20
    @Environment(\.hqGlassSheet) private var glass

    var body: some View {
        content
            // [glass-design] On the glass the player is a solid card at the grouped cards' edges; off it (the Desktop
            // Look, the iPad) the page as before.
            .padding(.horizontal, glass ? GlassSheetKit.cardPadding : 24)
            .padding(.vertical, glass ? 18 : 0)
            .background(RoundedRectangle(cornerRadius: GlassSheetKit.cardRadius, style: .continuous)
                .fill(glass ? Color(uiColor: HQPalette.sheetCard) : Color.clear))
            .overlay {   // [glass-design] the cards' thin edge on the glass
                if glass { RoundedRectangle(cornerRadius: GlassSheetKit.cardRadius, style: .continuous)
                    .strokeBorder(Color(uiColor: HQPalette.cardEdge), lineWidth: 1) }
            }
            .padding(.horizontal, glass ? 20 : 0)
            .padding(.top, 4)
            .padding(.bottom, glass ? 12 : 8)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.contentHeight = $0 }
            .frame(maxHeight: .infinity, alignment: .top)
            .accessibilityElement(children: .contain)          // the parts keep their own identifiers
            .accessibilityIdentifier("audio.preview")
    }

    private var content: some View {
        VStack(spacing: 0) {
            Image(systemName: model.item.isMemo ? "mic.fill" : "waveform")
                .font(Font.hqSystem(size: min(headerGlyph, 56), weight: .medium))
                .foregroundStyle(Color.hqTint)
                .frame(height: max(44, min(headerGlyph, 56) + 10))
                .accessibilityHidden(true)
            Text(model.item.title)
                .font(Font.hq(.headline))
                .foregroundStyle(Color.hqLabel)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .padding(.top, 10)
                .accessibilityIdentifier("audio.preview.title")
            Text(AudioPreviewText.detail(bytes: model.item.bytes, name: model.item.name))
                .font(Font.hq(.footnote))
                .foregroundStyle(Color.hqLabel2)
                .padding(.top, 3)
                .accessibilityIdentifier("audio.preview.detail")
            player
                .padding(.top, 22)
            status
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
    }

    /// Play, the scrubber and the time on one row. At accessibility text sizes the time would take the scrubber's
    /// width, so they stack: Play, a full-width scrubber, the time under it.
    private var player: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Button(action: model.toggle) {
                ZStack {
                    if model.phase == .loading || model.starting {
                        ProgressView()
                    } else {
                        Image(systemName: model.phase == .failed ? "arrow.clockwise" : model.playing ? "pause.fill" : "play.fill")
                            .font(Font.hqSystem(size: min(playGlyph, 30), weight: .semibold))
                    }
                }
                .frame(width: playSide, height: playSide)
                .contentShape(Rectangle())
            }
            .modifier(PlayButtonFace(solid: glass))
            .disabled(model.phase == .loading)
            .accessibilityLabel(model.phase == .failed ? "Try Again" : model.playing ? "Pause" : "Play")
            .accessibilityIdentifier("audio.preview.play")

            Slider(value: Binding(
                get: { model.dragging ? dragValue : model.fraction },
                set: { dragValue = $0 }), in: 0...1) { editing in
                    if editing {
                        dragValue = model.fraction
                        model.dragging = true
                    } else {
                        model.seek(to: dragValue)
                        model.dragging = false
                    }
                }
                .disabled(model.phase != .ready || model.total <= 0)
                .accessibilityLabel("Position")
                .accessibilityValue(AudioPreviewText.spokenPosition(elapsed: shownElapsed, total: model.total))
                .accessibilityIdentifier("audio.preview.scrubber")

            Text("\(AudioPreviewText.clock(shownElapsed)) / \(AudioPreviewText.clock(model.total))")
                .font(Font.hq(.footnote).monospacedDigit())
                .foregroundStyle(Color.hqLabel2)
                .accessibilityIdentifier("audio.preview.time")
                .accessibilityLabel(AudioPreviewText.spokenPosition(elapsed: shownElapsed, total: model.total))
        }
    }

    /// 44 pt until the Play glyph passes 24 pt, then it keeps the glyph's margin.
    private var playSide: CGFloat { max(44, min(playGlyph, 30) + 20) }

    private var shownElapsed: Double { model.dragging ? dragValue * model.total : model.elapsed }

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .loading:
            Text(AudioPreviewText.loading)
                .font(Font.hq(.footnote))
                .foregroundStyle(Color.hqLabel2)
                .accessibilityIdentifier("audio.preview.status")
        case .failed:
            Text(AudioPreviewText.failed)
                .font(Font.hq(.footnote))
                .foregroundStyle(Color.hqLabel2)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("audio.preview.status")
        case .ready:
            // The row keeps its height, so the sheet does not jump when the player is ready.
            Text(model.playing ? "Playing" : "Ready")
                .font(Font.hq(.footnote))
                .hidden()
                .accessibilityHidden(true)
        }
    }
}

/// [glass-design] Play on the player's solid card is the accent disc with its own glyph colour (no glass on the card);
/// off the glass the glass circle it always was.
private struct PlayButtonFace: ViewModifier {
    let solid: Bool
    func body(content: Content) -> some View {
        if solid {
            content
                .buttonStyle(SolidPlayStyle())
        } else {
            content
                .hqGlassButtonStyle()
                .buttonBorderShape(.circle)
        }
    }
}

private struct SolidPlayStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.hqOnTint)
            .tint(Color.hqOnTint)                                // the loading spinner
            .background(Circle().fill(Color.hqTint))
            .opacity(configuration.isPressed ? 0.7 : enabled ? 1 : 0.5)
            .contentShape(Circle())
    }
}
