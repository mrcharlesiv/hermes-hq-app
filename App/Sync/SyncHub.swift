// [sync] The app model's side of what follows the owner from device to device (HermesKit/Store/GatewaySync.swift):
// one `GatewaySync` per signed-in account, with the pins, removed artifacts, the Sessions and Bots orders and the
// settings as its documents. `AppModel` calls its hooks from its own lifecycle (every call there is marked [sync]).

import UIKit

@MainActor final class SyncHub {
    private(set) var sync: GatewaySync?
    private var settings: [SettingsSync] = []
    private weak var pins: ArtifactPins?
    private weak var hidden: ArtifactHidden?
    private weak var bots: BotStore?
    private weak var sessions: SessionStore?
    private weak var providers: ProviderPrefsStore?

    static var deviceName: String {
        #if targetEnvironment(macCatalyst)
        "Mac"
        #else
        UIDevice.current.model
        #endif
    }

    func activated(account: GatewayAccount, client: any GatewayClient, bots: BotStore, sessions: SessionStore) {
        tearDown()
        let sync = GatewaySync(client: client, accountId: account.id, deviceName: Self.deviceName,
                               defaultRow: { [weak bots] in
                                   guard let bots, bots.phase == .full else { return nil }   // a cached or slim row may lack ui_meta
                                   return bots.profiles.first { $0.name == "default" } ?? bots.profiles.first(where: \.isDefault)
                               },
                               readOnly: { [weak bots] in bots?.readOnlyGateway ?? true })
        let pins = ArtifactPins.of(accountId: account.id)
        let hidden = ArtifactHidden.of(accountId: account.id)
        // [provider-manager] The owner's provider and model names and short lists (Settings › Providers).
        ProviderPrefsStore.activate(accountId: account.id)
        let providers = ProviderPrefsStore.of(accountId: account.id)
        providers.syncChanged = { [weak sync] in sync?.changed("providers") }
        pins.syncChanged = { [weak sync] in sync?.changed("pins") }
        hidden.syncChanged = { [weak sync] in sync?.changed("hidden") }
        bots.syncChanged = { [weak sync] in sync?.changed("bots") }
        sessions.syncChanged = { [weak sync] in sync?.changed("sessions") }
        settings = [false, true].map { library in
            let document = SettingsSync(library: library, accountId: account.id)
            let name = document.syncName
            document.syncChanged = { [weak sync] in sync?.changed(name) }
            document.onAdopted = { keys in SettingsAdopted.refresh(keys: keys) }
            return document
        }
        for document in [pins, hidden, bots, sessions, providers] as [GatewaySynced] + settings { sync.register(document) }
        self.sync = sync
        self.pins = pins
        self.hidden = hidden
        self.bots = bots
        self.sessions = sessions
        self.providers = providers
    }

    func tearDown() {
        sync?.shutdown()
        sync = nil
        pins?.syncChanged = nil
        hidden?.syncChanged = nil
        bots?.syncChanged = nil
        sessions?.syncChanged = nil
        providers?.syncChanged = nil
        for document in settings { document.close() }
        settings = []
    }

    /// [13-1] Sign Out and Remove Gateway delete the Sessions and Bots lists' device state (their orders, colours,
    /// favourites): what this device remembers syncing of them goes too, so the next sign-in takes the gateway's copy
    /// rather than writing its empty one over every device's. Pins, removed artifacts, providers and settings stay on the
    /// device, so their bookkeeping stays with them.
    static func forgetLists(accountId: String) {
        GatewaySync.forget(accountId: accountId, documents: ["bots", "sessions"])
    }

    /// A roster arrived (or a bot changed): what another device wrote comes in, what waits here goes out.
    func rosterChanged() { sync?.pulled() }

    /// Leaving the app: what waits goes now, in the background time iOS gives.
    func wentBackground() {
        guard let sync, sync.hasPending else { return }
        let time = BackgroundTime.begin("Hermes HQ sync")
        Task { @MainActor in
            await sync.flushNow()
            time.end()
        }
    }
}

/// After settings from another device were written underneath the screens: the theme and look repaint, and each
/// setting's own "changed" notice goes out so the pages that keep a copy read it again (screens built from
/// @AppStorage follow by themselves).
@MainActor enum SettingsAdopted {
    static func refresh(keys: [String]) {
        guard !keys.isEmpty else { return }
        Theme.shared.reload()
        AppearanceSetting.applyEverywhere()
        PromptLibrary.shared.reloadStored()
        let center = NotificationCenter.default
        for name in [IntroSplash.didChange, FileBrowserPref.didChange, MessageReactionsPref.didChange, ToolCallSettings.didChange,
                     KanbanTabOverride.didChange, AttachmentLimit.didChange, TalkController.readRepliesAloudChanged,
                     TalkController.engineChanged, PhoneVoiceChoice.changed, WordFixes.changed, ArtifactPins.viewChanged] {
            center.post(name: name, object: nil)
        }
    }
}
