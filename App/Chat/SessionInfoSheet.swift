// [sessions-m9] Where Session Info's values come from (docs/spec/3x-sessions.md §10.3): the open chat's live state
// (model, effort, usage, folder, branch, a fallback), the chat's stored row (the Sessions store's, else read once by
// id), and the gateway link. `rows()` is asked again while the sheet is open, so a usage tick or a dropped link shows
// without reopening it.

import Foundation

@MainActor final class SessionInfoSheetSource {
    private weak var model: (any ChatSessionModel)?
    private let account: GatewayAccount?
    private let modelName: String?
    private weak var store: SessionStore?
    private let profileName: ((String) -> String)?
    /// The stored row read by id, for a chat the loaded lists do not hold.
    private var fetched: SidebarSessionRow?
    private var last: [SessionInfoRow] = []
    private var asked = false

    init(model: any ChatSessionModel, account: GatewayAccount?, modelName: String?, store: SessionStore?,
         profileName: ((String) -> String)?) {
        self.model = model
        self.account = account
        self.modelName = modelName
        self.store = store
        self.profileName = profileName
    }

    /// The live chat, for its running commands (nil for a demo chat).
    var live: LiveChatSession? { model as? LiveChatSession }

    private var storedId: String? {
        guard let id = (model as? LiveChatSession)?.storedSessionId, !id.isEmpty else { return nil }
        return id
    }

    private var listedRow: SidebarSessionRow? {
        guard let model, let storedId, let store else { return nil }
        return store.listedRow(id: storedId, profile: model.profile)
            ?? store.archivedRow(id: storedId, profile: model.profile)
    }

    /// The sheet opened: one `session.usage` ask (errors swallowed), and the stored row by id when no list holds it.
    /// `changed` runs when either answers.
    func opened(_ changed: @escaping () -> Void) {
        guard !asked else { return }
        asked = true
        if let live = model as? LiveChatSession {
            Task {
                await live.refreshUsage()
                changed()
            }
        }
        if listedRow == nil, let store, let model, let storedId {
            let profile = model.profile
            Task { [weak self] in
                guard let row = await store.fetchRow(id: storedId, profile: profile) else { return }
                self?.fetched = row
                changed()
            }
        }
    }

    func rows() -> [SessionInfoRow] {
        guard let model else { return last }
        let live = model as? LiveChatSession
        let chat = model as? ChatModelControlling
        let row = listedRow ?? fetched
        var source = SessionInfoSource()
        if let chat {
            let state = chat.modelState
            if !state.model.isEmpty {
                source.model = state.model
                source.provider = state.provider.isEmpty ? nil : state.provider
            }
            if !state.reasoningEffort.isEmpty { source.reasoning = ModelNames.effortLabel(state.reasoningEffort) }
            source.fast = state.fast
        }
        source.row = row.map(SessionInfoStoredRow.init)
        if source.model == nil, source.row?.model == nil {
            // A chat not resumed yet and not listed: the model its roster names.
            let named = ((model as? ChatSessionDetails)?.modelName ?? modelName)?.trimmingCharacters(in: .whitespaces) ?? ""
            if !named.isEmpty { source.model = named }
        }
        source.answeredBy = live?.menus.answeredBy
        source.usage = live?.shownUsage
        if let chat, !chat.modelState.model.isEmpty {
            // The model's price from the chat's cached catalog (as ⋯ › Model Prices words it); none until it is read.
            source.price = ModelPricesModel.menuSubtitle(ModelCatalogCache.shared.cached(ModelMenuContext.key(for: chat)),
                                                         model: chat.modelState.model, provider: chat.modelState.provider,
                                                         fallback: ModelsDevCache.shared.stored())
        }
        source.liveCwd = live?.menus.cwd
        source.liveBranch = live?.menus.branch
        source.profile = model.profile.isEmpty ? "default" : model.profile
        source.sessionId = storedId
        if let account {
            source.gateway = SessionInfoRows.host(account.baseURL)
            source.gatewayNote = SessionInfoRows.gatewayNote(chat?.connection ?? .ready)
        }
        var names = SessionInfoNames()
        names.model = { [weak chat] id in ModelNames.displayModelName(id, provider: chat?.modelState.provider ?? "") }   // [provider-manager]
        names.provider = { [weak chat] slug in
            guard let chat else { return ModelNames.plainProviderName(ModelNames.providerDisplayName(slug)) }
            return ModelMenuContext.providerName(for: chat, model: chat.modelState.model, provider: slug)
        }
        if let profileName { names.profile = profileName }
        last = SessionInfoRows.rows(source, names: names)
        return last
    }
}
