// [tiles-v2] Companion actions, menus, sharing, batch controls, and keyboard shortcuts for the Tiles dashboard,
// extracted from ArtifactsViewController.swift to keep the controller modular.

import UIKit

extension ArtifactsViewController {
    // MARK: Keyboard shortcuts (Mac & iPad hardware keyboards)

    override var canBecomeFirstResponder: Bool { pinnedOnly || super.canBecomeFirstResponder }

    override var keyCommands: [UIKeyCommand]? {
        var commands = super.keyCommands ?? []
        guard pinnedOnly, presentedViewController == nil else { return commands }
        if services != nil, services?.readOnlyGateway == false {
            let newCmd = UIKeyCommand(title: "New Tile", action: #selector(keyNewTile), input: "n", modifierFlags: .command)
            newCmd.wantsPriorityOverSystemBehavior = true
            commands.append(newCmd)
        }
        let refreshCmd = UIKeyCommand(title: "Refresh Tiles", action: #selector(keyRefreshTiles), input: "r", modifierFlags: .command)
        refreshCmd.wantsPriorityOverSystemBehavior = true
        commands.append(refreshCmd)
        if showsPages, pins.pages.count > 1 {
            for index in 0..<min(9, pins.pages.count) {
                let cmd = UIKeyCommand(title: "Show \(pins.pages[index].name)", action: #selector(keySwitchDashboardPage(_:)),
                                       input: "\(index + 1)", modifierFlags: .command)
                cmd.wantsPriorityOverSystemBehavior = true
                commands.append(cmd)
            }
        }
        return commands
    }

    @objc private func keyNewTile() { newTile() }

    @objc private func keyRefreshTiles() {
        PagesHaptics.selection()
        pinPictures.redraw(pins.pins)
        for pin in pins.pins where pin.isPage { liveTiles?.reload(pin.id) }
        watchTiles(true)
        reload(animated: false)
    }

    @objc private func keySwitchDashboardPage(_ command: UIKeyCommand) {
        guard let input = command.input, let oneBased = Int(input), oneBased >= 1 else { return }
        let index = oneBased - 1
        guard pins.pages.indices.contains(index) else { return }
        showPage(pins.pages[index].id)
    }

    // MARK: Share as Image, Duplicate, Keep Updated, Fix with Bot, View Job

    /// [tiles-v2] Shares a rendered PNG snapshot of a page tile (far cleaner in Messages/Slack/Discord than raw .html).
    func shareTileAsImageAction(_ pin: ArtifactPin, anchor: UIView? = nil, presenter: UIViewController? = nil) -> UIAction? {
        guard pin.isPage else { return nil }
        let action = UIAction(title: "Share as Image…", image: UIImage(systemName: "photo.on.rectangle.angled")) { [weak self, weak anchor, weak presenter] _ in
            self?.shareTileAsImage(pin, anchor: anchor, presenter: presenter)
        }
        action.accessibilityIdentifier = "tile.share-image"
        return action
    }

    func shareTileAsImage(_ pin: ArtifactPin, anchor: UIView? = nil, presenter: UIViewController? = nil) {
        let host = presenter ?? self
        if let image = currentPicture(pin) ?? pinPictures.shown(pin) {
            presentImageShare(image, name: pins.name(pin), from: host, anchor: anchor)
            return
        }
        guard let path = pin.gatewayPath else { return }
        let dark = traitCollection.userInterfaceStyle == .dark
        let shape = pinPictureShape(pin)
        PagesHUD.show("Rendering Image…", symbol: "photo", from: host)
        PageSnapshots.shared.picture(path: path, name: pin.label, context: pinPictures.context(pin), dark: dark, shape: shape) { [weak self, weak host, weak anchor] image in
            guard let self, let host else { return }
            guard let image else {
                PagesHaptics.error()
                PagesHUD.show("Couldn’t Render Tile Image", symbol: "exclamationmark.triangle", from: host)
                return
            }
            self.presentImageShare(image, name: self.pins.name(pin), from: host, anchor: anchor)
        }
    }

    private func presentImageShare(_ image: UIImage, name: String, from host: UIViewController, anchor: UIView?) {
        PagesHaptics.selection()
        let items: [Any]
        if let png = image.pngData() {
            let safe = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
            let file = FileManager.default.temporaryDirectory.appending(path: (safe.isEmpty ? "Tile" : safe) + ".png")
            if (try? png.write(to: file, options: [.atomic])) != nil {
                items = [file]
            } else {
                items = [image]
            }
        } else {
            items = [image]
        }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        point(sheet, item: nil, anchor: anchor)
        host.present(sheet, animated: true)
    }

    /// [tiles-v2] Duplicate…: opens ChangeTileSheet in `.duplicate` mode to create a new tile modeled on `pin`.
    func duplicateTileAction(_ pin: ArtifactPin, presenter: (() -> UIViewController?)? = nil) -> UIAction {
        let action = UIAction(title: "Duplicate…", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
            guard let self else { return }
            self.askTileChange(pin, initialWhat: "", mode: .duplicate, from: presenter?() ?? self)
        }
        action.accessibilityIdentifier = "tile.duplicate"
        let hasBot = (services?.bots ?? []).contains(where: { $0.id == pin.profile })
        if !hasBot || pin.gatewayPath == nil || services?.readOnlyGateway == true { action.attributes = .disabled }
        return action
    }

    func duplicateTile(id: String, what words: String) {
        guard let services, !services.readOnlyGateway, let pin = pins.pins.first(where: { $0.id == id }),
              let path = pin.gatewayPath, let bot = services.bots.first(where: { $0.id == pin.profile }) else { return }
        let chat = services.tileChat(for: bot)
        TileMaker.duplicate(pin, sourcePath: path, bot: bot, what: words, accountId: store.account.id, chat: chat, from: self)
    }

    /// [tiles-v2] Turns a static pinned HTML page into a self-updating tile on the chosen frequency.
    func keepTileUpdated(_ pin: ArtifactPin, frequency: TileJobs.Frequency) {
        guard let services, !services.readOnlyGateway, let path = pin.gatewayPath,
              let bot = services.bots.first(where: { $0.id == pin.profile }) else { return }
        PagesHaptics.selection()
        let chat = tileOwnChat(pin, bot: bot, services: services)
        TileMaker.keepUpdated(pin, path: path, bot: bot, frequency: frequency, accountId: store.account.id, chat: chat, from: self)
    }

    /// [tiles-v2] Opens the tile's scheduled job in `JobDetailViewController` (from Updates › View Last Run / View Job).
    func openTileJob(_ job: CronJob, from presenter: UIViewController? = nil) {
        guard let store = JobsStore.current, let services else { return }
        PagesHaptics.selection()
        let actions = JobActions(store: store)
        actions.services = services
        let detail = JobDetailViewController(jobKey: job.key, store: store, actions: actions, services: services, makeChat: makeChat)
        if let presenter, presenter !== self {
            presenter.dismiss(animated: true) { [weak self] in
                self?.navigationController?.pushViewController(detail, animated: true)
            }
        } else {
            navigationController?.pushViewController(detail, animated: true)
        }
    }

    /// [tiles-v2] Batch actions for all tiles on the currently shown Dashboard page.
    func currentPagePins() -> [ArtifactPin] {
        let visible = hidden.visible(pins.pins)
        guard showsPages else { return visible }
        return visible.filter { pins.pageId(of: $0) == pins.currentPage }
    }

    func updateAllCurrentPageTiles() {
        TileUpdates.shared.updateAll(currentPagePins(), accountId: store.account.id, client: services?.gateway, host: self) { [weak self] id in
            self?.redrawTile(id)
        }
    }

    func setAllCurrentPageTilesPaused(_ pause: Bool) {
        Task { [weak self] in
            guard let self else { return }
            _ = await TileUpdates.shared.setAllPaused(pause, pins: self.currentPagePins(), accountId: self.store.account.id,
                                                      client: self.services?.gateway, host: self)
        }
    }

    /// [tiles-v2] Updates menu builder shared between a tile's hold menu and the opened tile's clock button.
    func buildTileUpdatesMenu(_ pin: ArtifactPin, inline: Bool, host: UIViewController) -> UIMenuElement {
        let botName = PagesNames.botName(pin.profile, bots: services?.bots ?? [])
        let botModel = services?.botModelName(pin.profile)
        return TileUpdates.shared.menu(
            for: pin,
            accountId: pinPictures.context(pin).accountId,
            client: services?.gateway,
            from: host,
            inline: inline,
            botName: botName,
            botModel: botModel,
            onKeepUpdated: { [weak self] frequency in
                self?.keepTileUpdated(pin, frequency: frequency)
            },
            onFixFailed: { [weak self, weak host] error in
                guard let self else { return }
                self.askTileChange(pin, initialWhat: TileJobs.fixPrefill(error: error), mode: .change, from: host ?? self)
            },
            onOpenJob: { [weak self, weak host] job in
                self?.openTileJob(job, from: host)
            },
            redraw: { [weak self] in
                self?.redrawTile(pin.id)
            })
    }
}
