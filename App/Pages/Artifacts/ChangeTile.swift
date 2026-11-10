// [tiles] Change Tile (owner 2026-11-10: "the experience when you request a change on a tile needs to be greatly
// improved"). It was an alert with a one-line field whose example was cut off, and nothing of the tile in sight. Now a
// sheet as New Tile's: the tile as it looks now, who changes it and how often it's updated, a field that grows as you
// write, and quick changes that a tap adds to your words (a second tap takes one out). The bot then works on it in a
// new chat; the tile itself says it's being changed, and when it's done the tile is drawn again and the page says so
// (or, when the bot needs you or hit a problem, offers its chat).

import SwiftUI
import UIKit

@MainActor @Observable
final class ChangeTileModel {
    let name: String
    let bot: Bot
    let picture: UIImage?
    /// How often it's updated ("Every hour · 10 min ago"), read as the sheet opens.
    var status: String?
    var what = ""
    @ObservationIgnored var onChange: ((String) -> Void)?
    @ObservationIgnored weak var controller: UIViewController?

    init(name: String, bot: Bot, picture: UIImage?) {
        self.name = name
        self.bot = bot
        self.picture = picture
    }

    var canChange: Bool { !what.pgTrim.isEmpty }

    func toggle(_ change: String) {
        PagesHaptics.selection()
        what = TileChangeWords.toggling(change, in: what)
    }

    func change() {
        guard canChange else { return }
        PagesHaptics.success()
        let words = what.pgTrim
        controller?.dismiss(animated: true)
        onChange?(words)
    }
}

enum ChangeTileSheet {
    static func make(name: String, bot: Bot, picture: UIImage?, status: (() async -> String?)?,
                     onChange: @escaping (String) -> Void) -> UIViewController {
        let model = ChangeTileModel(name: name, bot: bot, picture: picture)
        model.onChange = onChange
        let host = ChangeTileHostController(model: model)
        let nav = ChatSheet.wrap(host, title: "Change Tile")
        host.installClose()
        nav.sheetPresentationController?.selectedDetentIdentifier = .large
        if let status {
            Task { @MainActor [weak model] in
                let words = await status()
                model?.status = words
            }
        }
        return nav
    }
}

final class ChangeTileHostController: UIHostingController<HQScaledRoot<ChangeTileView>> {
    let model: ChangeTileModel
    private var changeItem: UIBarButtonItem!

    init(model: ChangeTileModel) {
        self.model = model
        super.init(rootView: HQScaledRoot(ChangeTileView(model: model)))
        model.controller = self
        title = "Change Tile"
        changeItem = UIBarButtonItem(title: "Change", primaryAction: UIAction { [weak self] _ in self?.model.change() })
        changeItem.style = .prominent
        changeItem.accessibilityIdentifier = "tile.change.send"
        navigationItem.rightBarButtonItem = changeItem
        updateChange()
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + (model.canChange ? [.save("Change", #selector(changeFromKeyboard))] : [])
    }
    override var canBecomeFirstResponder: Bool { true }
    @objc private func changeFromKeyboard() { model.change() }

    func installClose() {
        let close = UIBarButtonItem.hqClose(DeviceWord.isMac ? .cancel : .close, action: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        close.accessibilityIdentifier = "sheet.close"
        navigationItem.hqPlaceFormClose(close)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "tile.change.sheet"
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = model.what
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.updateChange(); self?.observe() }
        }
    }

    private func updateChange() { changeItem.setProminentEnabled(model.canChange) }
}

struct ChangeTileView: View {
    @Bindable var model: ChangeTileModel
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                ChangeTileHeader(model: model)
                    .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 16))
            }
            Section {
                TextField("For example: make it a bar chart and add last month", text: $model.what, axis: .vertical)
                    .lineLimit(2...8)
                    .focused($focused)
                    .textInputAutocapitalization(.sentences)
                    .accessibilityIdentifier("tile.change.field")
            } header: { HQSectionLabel { Text("What Should Change?") } }
            Section {
                PagesFlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(TileChangeWords.quick, id: \.words) { change in
                        ChangeTileChip(label: change.label, words: change.words, symbol: change.symbol,
                                       on: TileChangeWords.contains(model.what, change.words)) {
                            model.toggle(change.words)
                        }
                    }
                }
                .padding(.vertical, 4)
                .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
            } header: { HQSectionLabel { Text("Quick Changes") } } footer: { HQSectionFooter {
                Text("\(model.bot.name) changes it in a new chat. The tile stays where it is and shows it’s being changed, then it’s drawn again when it’s done.")
            } }
        }
        .hqGroupedPage()
        .onAppear { focused = true }
    }
}

/// The tile as it looks now, its name, the bot that changes it and how often it's updated.
private struct ChangeTileHeader: View {
    var model: ChangeTileModel

    var body: some View {
        let width = HQFont.scaled(96), height = HQFont.scaled(72)
        let shape = RoundedRectangle(cornerRadius: HQShape.radius(10, .card), style: .continuous)
        HStack(spacing: 12) {
            Rectangle()
                .fill(model.picture.flatMap(PinPictures.edgeColor).map { Color(uiColor: $0) } ?? Color.hqFill3)
                .overlay {
                    if let picture = model.picture {
                        PagePictureView(picture: picture, padding: 3)
                    } else {
                        Image(systemName: "chart.xyaxis.line").hqSymbolFont(22, weight: .light, cap: 32)
                            .foregroundStyle(Color.hqLabel3)
                    }
                }
                .frame(width: width, height: height)
                .clipShape(shape)
                .overlay { shape.strokeBorder(Color.hqStroke, lineWidth: Theme.isDesktop ? 1 : 0.5) }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.name)
                    .font(Font.hq(.subheadline).weight(.semibold))
                    .foregroundStyle(Color.hqLabel)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    HeadImage(raw: model.bot.head, profile: model.bot.id, size: HQFont.scaled(18))
                        .frame(width: HQFont.scaled(18), height: HQFont.scaled(18))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    Text("Changed by \(model.bot.name)")
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqLabel2)
                        .lineLimit(1)
                }
                if let status = model.status, let first = status.first {
                    HStack(spacing: 6) {
                        Image(systemName: "clock").hqSymbolFont(12, cap: 18)
                            .frame(width: HQFont.scaled(18))
                        Text(first.uppercased() + status.dropFirst()).lineLimit(1)
                    }
                    .font(Font.hq(.caption))
                    .foregroundStyle(Color.hqLabel2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("tile.change.tile")
    }
}

/// A quick change: a capsule with its symbol; tinted while the words hold it.
private struct ChangeTileChip: View {
    var label: String
    var words: String
    var symbol: String
    var on: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: on ? "checkmark" : (UIImage(systemName: symbol) != nil ? symbol : "sparkles"))
                    .hqSymbolFont(11, weight: .semibold, cap: 18)
                Text(label).lineLimit(2).multilineTextAlignment(.leading)
            }
            .font(Font.hq(.footnote).weight(on ? .semibold : .medium))
            .foregroundStyle(on ? Color.hqTintText : Color.hqLabel)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(on ? Color.hqTint.opacity(0.16) : Color.hqFill3))
            .overlay { Capsule().strokeBorder(on ? Color.hqTint.opacity(0.5) : Color.clear, lineWidth: 1) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint("Adds “\(words)”")
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("tile.change.quick")
    }
}

/// [tiles] On a tile while its bot changes it (Change…) or answers one of its buttons: the picture dims a little under a
/// "Changing…" capsule, and the tile's edge breathes in the tint. Taps go through (the tile still opens).
struct TileChangingVeil: View {
    var words: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bright = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.hqPage.opacity(0.35)
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(words)
                    .font(Font.hq(.caption).weight(.semibold))
                    .foregroundStyle(Color.hqLabel)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .overlay { Capsule().strokeBorder(Color.hqStroke, lineWidth: 0.5) }
            .padding(8)
        }
        .overlay {
            Rectangle().strokeBorder(Color.hqTint.opacity(bright ? 0.85 : 0.35), lineWidth: 2)
        }
        .allowsHitTesting(false)
        .onAppear {
            guard !reduceMotion else { bright = true; return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { bright = true }
        }
        .accessibilityHidden(true)
        .accessibilityIdentifier("tile.changing")
    }
}

/// [tiles] On a tile just after its bot finished changing it: a tint ring that fades, so the eye finds it.
struct TileChangedRing: View {
    @State private var faded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Rectangle().strokeBorder(Color.hqTint, lineWidth: 3)
            .opacity(faded ? 0 : 1)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeOut(duration: reduceMotion ? 0.2 : 2.4).delay(reduceMotion ? 2.5 : 1.2)) { faded = true }
            }
            .accessibilityHidden(true)
    }
}
