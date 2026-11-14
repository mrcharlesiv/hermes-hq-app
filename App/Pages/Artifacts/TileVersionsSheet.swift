// [tile-versions] Versions of a tile (owner 2026-11-11: "when you make one it's v1, if you edit it it's now v2, etc… and
// you can roll back to prior versions if you want to and can see what prior versions looked like").
//
// `TileVersions` keeps them (HermesKit/Pages/TileVersions.swift says where and when): New Tile's page is Version 1, each
// Change… makes the next, and an edit asked in a chat is kept the next time the app looks. The tile's menu has Versions:
// a sheet with every version newest first, each with its picture, what was asked and when. A tap opens a version full
// size, as the tile opens; Roll Back puts that version's page back on the tile (newer ones stay, so going forward again
// is the same tap).

import SwiftUI
import UIKit

/// The app's side of a tile's versions: one read or write at a time per tile, the version that shows kept on its pin.
@MainActor
final class TileVersions {
    static let shared = TileVersions()

    /// Each tile's work, in order (a look kept before a change must land before the one kept after it).
    private var tails: [String: Task<Void, Never>] = [:]

    private func store(_ pin: ArtifactPin, accountId: String) -> TileVersionStore? {
        guard pin.isPage, let path = pin.gatewayPath, let client = AttachmentCenter.existing(accountId)?.client else { return nil }
        return TileVersionStore(client: client, profile: pin.profile, tile: path)
    }

    private func perform(_ pin: ArtifactPin, accountId: String,
                         _ work: @escaping @Sendable (TileVersionStore) async throws -> TileVersionList) async -> Result<TileVersionList, any Error> {
        guard let store = store(pin, accountId: accountId) else { return .failure(TileVersionError.unreadable) }
        let earlier = tails[pin.id]
        let task = Task { @MainActor () -> Result<TileVersionList, any Error> in
            await earlier?.value
            do {
                let list = try await work(store)
                ArtifactPins.of(accountId: accountId).noteVersion(id: pin.id, list.current)
                return .success(list)
            } catch {
                return .failure(error)
            }
        }
        tails[pin.id] = Task { _ = await task.value }
        return await task.value
    }

    /// The tile's page looked at now, and kept as a new version when its look isn't the one that shows.
    @discardableResult
    func keep(_ pin: ArtifactPin, accountId: String, kind: TileVersion.Kind, what: String?) async -> Result<TileVersionList, any Error> {
        let result = await perform(pin, accountId: accountId) { try await $0.note(kind: kind, what: what) }
        switch result {
        case .success(let list): AppLog.note("pages", "tile versions: \(list.versions.count) kept, version \(list.current) shows (\(kind.rawValue))")
        case .failure(let error): AppLog.swallowed("pages", "keeping a tile's version", error)
        }
        return result
    }

    /// `keep`, not waited for (New Tile and Change…, as the bot starts or ends).
    func keepSoon(pinId: String, accountId: String, kind: TileVersion.Kind, what: String?) {
        guard let pin = ArtifactPins.of(accountId: accountId).pins.first(where: { $0.id == pinId }), pin.isPage else { return }
        Task { await keep(pin, accountId: accountId, kind: kind, what: what) }
    }

    /// The versions as kept, nothing written (a read-only gateway).
    func read(_ pin: ArtifactPin, accountId: String) async -> Result<TileVersionList, any Error> {
        await perform(pin, accountId: accountId) { try await $0.list() }
    }

    func rollBack(_ pin: ArtifactPin, accountId: String, to number: Int) async -> Result<TileVersionList, any Error> {
        let result = await perform(pin, accountId: accountId) { try await $0.rollBack(to: number) }
        if case .failure(let error) = result { AppLog.swallowed("pages", "rolling a tile back", error) } else {
            AppLog.note("pages", "tile rolled back to version \(number)")
        }
        return result
    }
}

@MainActor @Observable
final class TileVersionsModel {
    let pin: ArtifactPin
    let name: String
    let botName: String?
    let context: MediaContext
    /// Versions can be kept and rolled back (not on a read-only gateway).
    let writable: Bool
    var list: TileVersionList?
    var problem: String?
    /// The version being put back.
    var rolling: Int?
    var pictures: [Int: UIImage] = [:]
    @ObservationIgnored private var asked: Set<Int> = []
    @ObservationIgnored weak var controller: UIViewController?
    /// A version was put back on the tile (the Tiles page draws it again).
    @ObservationIgnored var onRolledBack: ((TileVersion) -> Void)?

    init(pin: ArtifactPin, name: String, botName: String?, context: MediaContext, writable: Bool) {
        self.pin = pin
        self.name = name
        self.botName = botName
        self.context = context
        self.writable = writable
    }

    #if DEBUG
    /// `-HQPagesTileVersions` (PagesDebug): versions to list in place of the gateway's, and Roll Back's question asked
    /// on the oldest once it shows (`-HQPagesTileRollBack`), for the tour's pictures.
    static var debugList: TileVersionList?
    static var debugAsk = false
    #endif

    func load() {
        problem = nil
        #if DEBUG
        if let list = Self.debugList { self.list = list; return }
        #endif
        Task { [weak self, pin, context, writable] in
            // Opening Versions looks at the tile: an edit asked in a chat since is kept now.
            let result = writable
                ? await TileVersions.shared.keep(pin, accountId: context.accountId, kind: .outside, what: nil)
                : await TileVersions.shared.read(pin, accountId: context.accountId)
            guard let self else { return }
            switch result {
            case .success(let list): self.list = list
            case .failure(let error): self.problem = TileVersionError.words(error)
            }
        }
    }

    func path(_ version: TileVersion) -> String? {
        pin.gatewayPath.map { TileVersionFiles.path(of: version, tile: $0) }
    }

    /// The version's picture, drawn the first time its row shows.
    func askPicture(_ version: TileVersion) {
        guard pictures[version.number] == nil, let path = path(version), asked.insert(version.number).inserted else { return }
        let dark = controller?.traitCollection.userInterfaceStyle == .dark
        PageSnapshots.shared.picture(path: path, name: version.file, context: context, dark: dark, shape: .box(aspect: 4.0 / 3)) { [weak self] image in
            guard let self, let image else { return }
            self.pictures[version.number] = image
        }
    }

    /// "Roll Back" to an earlier version; a later one than shows is put back with "Restore".
    func verb(_ version: TileVersion) -> String { asksFirst(version) ? "Roll Back" : "Restore" }

    /// [Mac UI check 2026-11-13] Owner: Roll Back asks first; Restore (which undoes a roll back) doesn't.
    func asksFirst(_ version: TileVersion) -> Bool { version.number < (list?.current ?? 0) }
    static let rollBackQuestion = "Roll Back to This Version?"
    /// What a roll back does, in one plain sentence.
    func rollBackWords(_ version: TileVersion) -> String {
        "\(name) goes back to how \(version.title) looked. The newer versions stay here, so you can restore them."
    }

    /// Roll Back's question, pointing at `anchor` (the row's button); an alert where there is no button left to point
    /// at (the version's full-size page closed). Restore puts the version back at once.
    func askRollBack(_ version: TileVersion, from anchor: UIView? = nil) {
        guard asksFirst(version) else { rollBack(version); return }
        guard let controller else { return }
        let pointed = anchor?.window != nil
        #if DEBUG
        AppLog.note("pages", "tile versions: Roll Back asks (\(pointed ? "at its button" : "as an alert"))")
        #endif
        let alert = UIAlertController(title: Self.rollBackQuestion, message: rollBackWords(version),
                                      preferredStyle: pointed ? .actionSheet : .alert)
        let roll = UIAlertAction(title: "Roll Back", style: .default) { [weak self] _ in self?.rollBack(version) }
        alert.addAction(roll)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.preferredAction = roll
        if pointed, let anchor, let popover = alert.popoverPresentationController {
            popover.sourceView = anchor
            popover.sourceRect = anchor.bounds
        }
        controller.present(alert, animated: true)
    }

    /// The version full size, as the tile opens; its Roll Back is in the bar.
    func open(_ version: TileVersion) {
        guard let controller, let path = path(version) else { return }
        PagesHaptics.selection()
        let current = version.number == list?.current
        var tile = HTMLPageSheet.Tile(name: version.title, fileName: name,
                                      status: { nil }, menu: { _ in UIMenu(children: []) })
        tile.version = .init(verb: current || !writable ? nil : verb(version)) { [weak self] host in
            host.dismiss(animated: true) { self?.askRollBack(version) }
        }
        FilePreviewPresenter.shared.open(path: path, name: version.file, context: context, from: controller, row: nil, tile: tile)
    }

    func rollBack(_ version: TileVersion) {
        guard writable, rolling == nil, version.number != list?.current else { return }
        rolling = version.number
        PagesHaptics.selection()
        Task { [weak self, pin, context] in
            let result = await TileVersions.shared.rollBack(pin, accountId: context.accountId, to: version.number)
            guard let self else { return }
            self.rolling = nil
            switch result {
            case .success(let list):
                self.list = list
                PagesHaptics.success()
                if let controller = self.controller { PagesHUD.show("\(self.name) Is on \(version.title)", symbol: "checkmark", from: controller) }
                self.onRolledBack?(version)
            case .failure(let error):
                PagesHaptics.error()
                self.alert("Couldn’t Put \(version.title) Back", TileVersionError.words(error))
            }
        }
    }

    private func alert(_ title: String, _ words: String) {
        guard let controller else { return }
        let alert = UIAlertController(title: title, message: words, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        controller.present(alert, animated: true)
    }
}

enum TileVersionsSheet {
    static func make(pin: ArtifactPin, name: String, botName: String?, context: MediaContext, writable: Bool,
                     onRolledBack: @escaping (TileVersion) -> Void) -> UIViewController {
        let model = TileVersionsModel(pin: pin, name: name, botName: botName, context: context, writable: writable)
        model.onRolledBack = onRolledBack
        let host = UIHostingController(rootView: HQScaledRoot(TileVersionsView(model: model)))
        host.view.accessibilityIdentifier = "tile.versions.sheet"
        model.controller = host
        let nav = ChatSheet.wrap(host, title: "Versions")
        host.navigationItem.subtitle = name
        nav.sheetPresentationController?.selectedDetentIdentifier = .large
        model.load()
        return nav
    }
}

struct TileVersionsView: View {
    var model: TileVersionsModel

    var body: some View {
        Form {
            if let list = model.list {
                Section {
                    ForEach(list.newestFirst) { version in
                        TileVersionRow(model: model, version: version, current: version.number == list.current)
                            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    }
                } footer: { HQSectionFooter { Text(footer(list)) } }
            } else if let problem = model.problem {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Couldn’t Read This Tile’s Versions").font(Font.hq(.subheadline).weight(.semibold)).foregroundStyle(Color.hqLabel)
                        Text(problem).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                        Button("Try Again") { model.load() }
                            .font(Font.hq(.subheadline))
                            .accessibilityIdentifier("tile.versions.retry")
                    }
                    .padding(.vertical, 4)
                }
            } else {
                Section {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Reading versions…").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                    }
                }
            }
        }
        .hqGroupedPage()
    }

    private func footer(_ list: TileVersionList) -> String {
        var words = list.versions.count == 1
            ? "This is the only version so far. Each change makes a new one, and the ones before stay here."
            : "\(DeviceWord.isMac ? "Click" : "Tap") a version to see it full size. Rolling back puts that version on the tile; the others stay here."
        if model.writable, list.versions.count > 1, let bot = model.botName {
            words += " If a job keeps this tile up to date, \(bot) makes sure it keeps the version you chose."
        }
        if !model.writable { words += " This gateway is read-only, so versions can’t be rolled back from here." }
        return words
    }
}

/// One version: its picture, "Version 3" (and Current), what was asked, when, and Roll Back.
private struct TileVersionRow: View {
    var model: TileVersionsModel
    var version: TileVersion
    var current: Bool
    /// [Mac UI check 2026-11-13] The Roll Back button's place, for its question to point at.
    @State private var anchor = TileVersionAnchor()

    var body: some View {
        let width = HQFont.scaled(88), height = HQFont.scaled(66)
        let shape = RoundedRectangle(cornerRadius: HQShape.radius(9, .card), style: .continuous)
        let picture = model.pictures[version.number]
        HStack(spacing: 10) {
            Button { model.open(version) } label: {
                HStack(spacing: 10) {
                    Rectangle()
                        .fill(picture.flatMap(PinPictures.edgeColor).map { Color(uiColor: $0) } ?? Color.hqFill3)
                        .overlay {
                            if let picture {
                                PagePictureView(picture: picture, padding: 2)
                            } else {
                                ProgressView().controlSize(.mini)
                            }
                        }
                        .frame(width: width, height: height)
                        .clipShape(shape)
                        .overlay { shape.strokeBorder(current ? Color.hqTint : Color.hqStroke, lineWidth: current ? 2 : (Theme.isDesktop ? 1 : 0.5)) }
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(version.title)
                                .font(Font.hq(.subheadline).weight(.semibold))
                                .foregroundStyle(Color.hqLabel)
                            if current {
                                Text("Current")
                                    .font(Font.hq(.caption2).weight(.semibold))
                                    .foregroundStyle(Color.hqTintText)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background(Capsule().fill(Color.hqTint.opacity(0.16)))
                            }
                        }
                        Text(version.words)
                            .font(Font.hq(.footnote))
                            .foregroundStyle(Color.hqLabel2)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(JobWords.relativeDateTime(Date(timeIntervalSince1970: version.at)))
                            .font(Font.hq(.caption))
                            .foregroundStyle(Color.hqLabel3)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(version.title)\(current ? ", current" : ""). \(version.words)")
            .accessibilityHint("Opens this version")
            .accessibilityIdentifier("tile.version.\(version.number)")
            if !current, model.writable {
                if model.rolling == version.number {
                    ProgressView().controlSize(.small).frame(minWidth: HQFont.scaled(64))
                } else {
                    Button(model.verb(version)) { model.askRollBack(version, from: anchor.view) }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .font(Font.hq(.footnote).weight(.medium))
                        .disabled(model.rolling != nil)
                        .accessibilityLabel("\(model.verb(version)) to \(version.title)")
                        .accessibilityIdentifier("tile.version.rollback.\(version.number)")
                        .background(TileVersionAnchorView(anchor: anchor))
                }
            }
        }
        .onAppear {
            model.askPicture(version)
            #if DEBUG
            if TileVersionsModel.debugAsk, model.asksFirst(version), version.number == 1 {
                TileVersionsModel.debugAsk = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [anchor] in model.askRollBack(version, from: anchor.view) }
            }
            #endif
        }
    }
}

/// [Mac UI check 2026-11-13] Where a row's Roll Back button sits, for its question to point at.
final class TileVersionAnchor {
    weak var view: UIView?
}

private struct TileVersionAnchorView: UIViewRepresentable {
    let anchor: TileVersionAnchor
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        anchor.view = view
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { anchor.view = view }
}
