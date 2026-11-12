// Notifications' hooks into the app model: push registration for the signed-in account (and its removal on sign-out
// or a gateway switch), who each chat's alerts are from, local alerts from the gateway socket, the badge, the Back
// count, opening the chat an alert or a hermes:// link names, and asking for permission once, in context.

import UIKit
import UserNotifications

extension AppModel {
    // MARK: Account lifecycle

    /// Signed in (launch restore, a fresh sign-in, a switch): push talks to this account's gateway now.
    func notificationsDidActivate(_ account: GatewayAccount, client: LiveGatewayClient) {
        let push = PushRegistrar.shared
        push.call = Self.pushCall(client)
        let stored = signIn.store.stored(account)
        push.setOwner(PushPolicy.owner(url: stored?.url ?? account.baseURL.absoluteString,
                                       username: stored?.username ?? account.username ?? ""))
        let hub = NotificationHub.shared
        hub.face = { [weak self] profile in self?.peekFace(profile) }
        hub.isRoomMemberSession = { [weak self] stored in self?.groupsHub.isMemberSession(stored) ?? false }
        // [photoheads] A bot's photo arrived, changed or went: the face kept for pushed alerts is drawn again.
        BotFaces.shared.onFacesChanged = { [weak self] in
            self?.refreshNotificationDirectory()
            self?.shareRosterChanged()                // [ship, m9] the Share sheet's faces follow a photo too
        }
        hub.window = { MainTabController.current?.view.window }
        hub.openChat = { [weak self] stored, profile in
            ShareInbox.personAsked()                  // [share] a chat the person asked for wins over a share's own
            self?.openNotifiedChat(stored: stored, profile: profile)
        }
        // UX study #262: an alert pushed by a gateway this phone left names it, rather than opening a chat it can't show.
        hub.otherGateway = { [weak self] account, chat in self?.alertFromOtherGateway(account, chat: chat) }
        DeviceAccessCenter.shared.botNames = { [weak self] profile in PagesNames.botName(profile, bots: self?.bots ?? []) }
        // [device-access] A bot's draft: Mail or Messages over whatever is on screen.
        hub.openDraft = { id in
            guard let host = FailureAlert.topmost(MainTabController.current) else { return }
            DraftsStore.open(id, from: host)
        }
        hub.openTask = { id, _ in TasksHub.open(taskID: id) }   // [tasks]
        hub.answerLocal = { [weak self] request, approve in
            guard let center = self?.serverRequests else { return }
            Task {
                do {
                    // [#256] Waits for the request on a cold launch; one already answered or expired is said, and a
                    // sent answer is confirmed, so the alert's button never does nothing in silence.
                    switch try await center.answerApprovalFromAlert(request, approve ? .once : .deny) {
                    case .sent:
                        Haptics.play(.success)
                        MenusHUD.show(LocalApprovalWords.sent(approve: approve), in: MainTabController.current?.view.window)
                    case .gone:
                        guard let host = FailureAlert.topmost(MainTabController.current) else { return }
                        Haptics.play(.warning)
                        let alert = UIAlertController(title: LocalApprovalWords.title(approve: approve), message: LocalApprovalWords.gone,
                                                      preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: "OK", style: .default))
                        host.present(alert, animated: true)
                    }
                } catch {
                    // [#138] Said, not swallowed: the chat opens with the card answerable again, and this says so.
                    FailureAlert.present(title: LocalApprovalWords.title(approve: approve), reason: LocalApprovalWords.reason(for: error),
                                         detail: "\(error)", from: MainTabController.current, whole: true)
                }
            }
        }
        serverRequests?.onArrived = { [weak self] entry, runtime in
            guard let self else { return }
            NotificationHub.shared.observeRequest(id: entry.id, kind: entry.kind, runtime: entry.sessionId, params: entry.params,
                                                  entry: self.notificationEntry(runtime: entry.sessionId, profile: runtime?.profile,
                                                                                storedId: runtime?.storedId))
        }
        push.outsideChats = { [weak self] in self?.sessionStore?.showOutsideChats ?? false }
        outsideChatsObserver = NotificationCenter.default.addObserver(forName: SessionStore.outsideChatsChanged, object: nil, queue: .main) { [weak self] note in
            let sender = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let store = self.sessionStore, sender == ObjectIdentifier(store) else { return }
                PushRegistrar.shared.sync()
            }
        }
        push.sync()
        DeviceAccessCenter.shared.accountReady()     // [device-access] this gateway hears what this phone shares
        PushSetupOffer.shared.afterLaunch(model: self)
        PluginUpdateFlow.shared.afterLaunch(model: self)   // [plugin-updates] which plugins have an update
    }

    /// A saved gateway's name by its push owner tag (`PushPolicy.owner`), nil when no saved gateway has it.
    func gatewayTitle(owner: String) -> String? { savedGateway(owner: owner)?.title }

    /// The saved gateway a push account tag names (its `PushPolicy.owner` hash), with the name it goes by here.
    func savedGateway(owner: String) -> (account: GatewayAccount, title: String)? {
        for account in signIn.store.accounts {
            let stored = signIn.store.stored(account)
            guard PushPolicy.owner(url: stored?.url ?? account.baseURL.absoluteString,
                                   username: stored?.username ?? account.username ?? "") == owner else { continue }
            return (account, GatewayNaming.title(url: account.baseURL, label: stored?.label))
        }
        return nil
    }

    /// UX study #262: a tapped alert pushed by a gateway this phone switched away from names it and offers the switch in
    /// one tap ("Switch to <name>", through the live-work guard); once there, the alert's chat opens. A gateway no
    /// longer saved here gets the plain sentence and OK.
    func alertFromOtherGateway(_ owner: String, chat: (stored: String, profile: String?)?) {
        guard let saved = savedGateway(owner: owner), let host = FailureAlert.topmost(MainTabController.current) else {
            FailureAlert.present(title: "From Another Gateway", reason: PushRegistrar.otherGatewayChatWords,
                                 from: MainTabController.current, whole: true)
            return
        }
        Haptics.play(.warning)
        let alert = UIAlertController(title: "From Another Gateway",
                                      message: "That alert came from \(saved.title), not the gateway you’re using now.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel))
        let action = UIAlertAction(title: OfflineCopy.switchTo(saved.title), style: .default) { [weak self] _ in
            GatewaySwitchGuard.confirm(switchingTo: saved.title, from: MainTabController.current) {
                self?.switchForAlert(to: saved.account, title: saved.title, chat: chat)
            }
        }
        alert.addAction(action)
        alert.preferredAction = action
        alert.view.accessibilityIdentifier = "notify.other-gateway"
        host.present(alert, animated: true)
    }

    private func switchForAlert(to account: GatewayAccount, title: String, chat: (stored: String, profile: String?)?) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.gateways.switchTo(account.id)
                if let chat { NotificationHub.shared.open(chat.stored, profile: chat.profile) }
            } catch GatewaySwitchError.needsSignIn(let account) {
                AddGatewayFlow.present(from: MainTabController.current, services: self, prefill: account)
            } catch {
                FailureAlert.present(title: "Couldn’t Switch to \(title)", reason: GatewaySwitchError.reason(switchingTo: title),
                                     detail: "\(error)", from: MainTabController.current)
            }
        }
    }

    /// Plugin calls through the signed-in client.
    static func pushCall(_ client: LiveGatewayClient) -> PushRegistrar.Call {
        { [weak client] path, method, body in
            guard let client else { return (0, nil) }
            return await Self.pushCall(client, path: path, method: method, body: body)
        }
    }

    /// Plugin calls with a saved account's own session and no client (a gateway already left or being removed).
    /// `persisted` false: a session renewed by the call isn't written back (the account was signed out here).
    static func pushCall(_ stored: StoredAccount, vault: AccountVault, persisted: Bool = true) -> PushRegistrar.Call {
        { path, method, body in
            let data = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            let answer = await AccountREST.call(stored, vault: vault, method: method, path: path, body: data, persisted: persisted)
            return (answer.status, answer.data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] })
        }
    }

    /// A switch that didn't happen (the next gateway couldn't be made current): push talks to the current one again.
    func notificationsResume() {
        guard let client else { return }
        PushRegistrar.shared.call = Self.pushCall(client)
        PushRegistrar.shared.sync()
        refreshNotificationDirectory()
    }

    /// Add Gateway signed in elsewhere (the old client is already gone): this phone leaves the old gateway's push list
    /// with that account's own saved session, so it stops pushing here.
    /// Call it before the new account is activated: the DELETE goes out once the new account owns this device.
    func notificationsLeftForAdded(stored: StoredAccount?) {
        NotificationHub.shared.clear()
        PushSetupOffer.shared.reset()
        PushRegistrar.shared.call = nil
        guard let stored else { return }
        let owner = PushPolicy.owner(url: stored.url, username: stored.username)
        let call = Self.pushCall(stored, vault: signIn.store.vault)
        Task { @MainActor in await PushRegistrar.shared.removeDevice(from: owner, call: call) }
    }

    /// One plugin call through the signed-in client: (HTTP status, JSON object). 0 = no answer.
    static func pushCall(_ client: LiveGatewayClient, path: String, method: String, body: [String: Any]?) async -> (status: Int, body: [String: Any]?) {
        let data = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        do {
            let answer = try await client.rest(method, path, query: [], body: data, timeout: 15)
            return (200, (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any] ?? [:])
        } catch let error as HTTPError {
            return (error.status, nil)
        } catch {
            return (0, nil)
        }
    }

    /// Before a sign-out or a switch: this device leaves the gateway it is on (at most 4 s), alerts and badge clear.
    func notificationsLeaving(signingOut: Bool) async {
        let push = PushRegistrar.shared
        let leaving = push.owner
        // Audit 14-1: that gateway's own saved session, taken before a sign-out removes it from this phone.
        let stored = account.flatMap { signIn.store.stored($0) }
        if leaving != nil {
            await PushRegistrar.withBudget(seconds: 4) { await push.unregister() }
            await PushRegistrar.withBudget(seconds: 2) { await DeviceAccessCenter.shared.leaving() }   // [device-access]
        }
        if signingOut { push.clear() }
        push.call = nil
        NotificationHub.shared.clear()
        PushSetupOffer.shared.reset()
        // Audit 14-1: a removal the budget didn't see answered (a slow connection) is sent once more with that gateway's
        // own session, after the client has gone (a sign-out or switch ends it, and its DELETE with it). Not to a gateway
        // another saved account still uses (one device entry per gateway: it would remove that one's).
        guard let leaving, let stored, stored.hasSession, push.owesRemoval(leaving), !sharesGateway(stored, leaving: account) else { return }
        let call = Self.pushCall(stored, vault: signIn.store.vault, persisted: !signingOut)
        Task { @MainActor in await push.removeDevice(from: leaving, call: call) }
    }

    /// Another saved account is on the same gateway address as `stored` (two usernames on one Hermes).
    private func sharesGateway(_ stored: StoredAccount, leaving: GatewayAccount?) -> Bool {
        let key = GatewayAddress.accountKey(url: stored.url, username: "")
        return signIn.store.accounts.contains { other in
            other.id != leaving?.id && GatewayAddress.accountKey(url: other.baseURL.absoluteString, username: "") == key
        }
    }

    /// Audit 14-1: removals still owed by saved gateways not in use (a switch whose DELETE never got an answer, and its
    /// second try neither), sent with each one's own session once per app run, when the app comes to the front. A
    /// gateway signed out here has no session left: its owed removal goes with its next sign-in's registration.
    func notificationsSettleOwedRemovals() {
        let push = PushRegistrar.shared
        guard PushRegistrar.available, !push.owedRemovals.isEmpty else { return }
        for other in signIn.store.accounts where other.id != account?.id {
            guard let stored = signIn.store.stored(other), stored.hasSession else { continue }
            let owner = PushPolicy.owner(url: stored.url, username: stored.username)
            guard push.owedRemovals.contains(owner), !Self.settledThisRun.contains(owner),
                  !sharesGateway(stored, leaving: other) else { continue }
            Self.settledThisRun.insert(owner)
            let call = Self.pushCall(stored, vault: signIn.store.vault)
            Task { @MainActor in await push.removeDevice(from: owner, call: call) }
        }
    }

    @MainActor private static var settledThisRun: Set<String> = []

    /// A saved gateway removed from this phone (not the one in use).
    func notificationsForget(_ account: GatewayAccount, stored: StoredAccount?) async {
        let owner = PushPolicy.owner(url: stored?.url ?? account.baseURL.absoluteString, username: stored?.username ?? account.username ?? "")
        // Sent with its own session, before its sign-out ends that session.
        await PushRegistrar.shared.forget(owner, call: stored.map { Self.pushCall($0, vault: signIn.store.vault) })
    }

    // MARK: Who a chat is

    func notificationEntry(runtime: String?, profile: String?, storedId: String?) -> NotificationHub.Entry? {
        let hub = NotificationHub.shared
        if let storedId, let known = hub.entry(storedId) { return known }
        if let runtime, let known = hub.entry(runtime) { return known }
        guard let profile else { return nil }
        let bot = botStore?.bot(named: profile)
        let session = storedId.flatMap { id in sessionStore?.sessions.first { $0.id == id } }
        let isBotChat = bot != nil && (storedId == nil || bot?.canonicalSessionId == nil || bot?.canonicalSessionId == storedId)
        let who = NotificationWho(sender: bot?.name ?? sessionStore.flatMap { s in session.map { s.ownerName(for: $0) } } ?? "",
                                  chat: isBotChat ? "" : (session?.title ?? ""), group: "", bot: isBotChat)
        let stored = storedId ?? bot?.canonicalSessionId ?? runtime ?? ""
        guard NotificationRules.valid(stored) else { return nil }
        let entry = NotificationHub.Entry(who: who, stored: stored, profile: profile, badge: stored)
        hub.label(runtime: runtime, entry: entry)
        return entry
    }

    /// Every bot chat and listed session, so alerts and pushes name their sender (and the extension has their faces).
    func refreshNotificationDirectory() {
        let hub = NotificationHub.shared
        for bot in bots {
            guard let id = bot.canonicalSessionId, NotificationRules.valid(id) else { continue }
            hub.label(runtime: nil, entry: .init(who: NotificationWho(sender: bot.name, chat: "", group: "", bot: true),
                                                 stored: id, profile: bot.id, badge: id))
        }
        for session in sessions where NotificationRules.valid(session.id) {
            let owner = botStore?.bot(named: session.profile)
            if owner?.canonicalSessionId == session.id { continue }
            let name = owner?.name ?? sessionStore?.ownerName(for: session) ?? ""
            hub.label(runtime: nil, entry: .init(who: NotificationWho(sender: name, chat: session.title, group: "", bot: false),
                                                 stored: session.id, profile: session.profile, badge: session.id))
        }
        if PushRegistrar.available, let owner = PushRegistrar.shared.owner {
            // [photoheads] Each bot's face for pushed alerts: its photo when it wears one, else its head. A face this
            // run already saved is skipped; a photo not in memory is decoded off the main actor (PushFaceSaver).
            PushFaceSaver.shared.save(bots, account: owner)
        }
        refreshBadge()
    }

    // [photoheads] The peek's face comes from the registry: the bot's photo as an app-icon tile when it wears one, its
    // head otherwise. A photo that cannot be drawn yet (just fetched, its file still being written) comes as the head,
    // and says so, so the peek cuts it round as it does every head.
    /// [presence] internal: the "is using its browser" notice shows the same face.
    func peekFace(_ profile: String) -> BotFaces.Face? {
        let speaker = groupsHub.alertSpeaker(profile) ?? profile   // [groups] a room's alert wears the face of the member who spoke
        guard let bot = botStore?.bot(named: speaker) else { return nil }
        let dark = MainTabController.current?.traitCollection.userInterfaceStyle == .dark
        let faces = BotFaces.shared
        return faces.readyFace(profile: bot.id, raw: bot.head, side: 40, scale: 3, dark: dark, shape: .appIcon)
            ?? BotFaces.Face(image: faces.headImage(profile: bot.id, raw: bot.head, side: 40, scale: 3, dark: dark), isPhoto: false)
    }

    // MARK: Badge and Back

    /// The icon's badge = the Bots tab's unread bots + the Sessions tab's unread chats; Back inside a chat says the same count.
    func refreshBadge() {
        let ids = BadgeMath.ids(bots: bots, sessions: sessions, visible: SessionList.isVisible)
        NotificationHub.shared.setUnread(ids)
        MainTabController.current?.setBackCount(ids.count)
    }

    // MARK: Socket events

    /// A turn ended in a chat this run opened (its screen may be gone): another chat's alert, or the peek.
    func notificationsTurnEnded(_ event: GatewayEvent, profile: String, storedId: String?) {
        let failed = event.type == "error" || event.payload["status"]?.string == "error"
        let text: String
        if failed {
            let surface = event.payload["error_surface"]
            text = NotificationText.errorReason(event.payload["error"]?.string ?? event.payload["message"]?.string ?? event.payload["text"]?.string ?? "",
                                                code: surface?["code"]?.string, provider: surface?["provider_label"]?.string ?? surface?["provider"]?.string)
        } else {
            text = String((event.payload["text"]?.string ?? event.payload["rendered"]?.string ?? "").prefix(4000))
        }
        let entry = notificationEntry(runtime: event.sessionId, profile: profile, storedId: storedId)
        NotificationHub.shared.observeTurnEnd(runtime: event.sessionId, seq: event.seq, failed: failed, text: text, entry: entry)
    }

    /// [settings] Alerts the gateway announces by event (spec §15): credits paused or restored, and a background process closing.
    func notificationsGatewayEvent(_ event: GatewayEvent) {
        switch event.type {
        case "notification.show":
            guard let key = event.payload["key"]?.nonEmptyString, let text = event.payload["text"]?.nonEmptyString else { return }
            NotificationHub.shared.observeCredits(key: key, id: event.payload["id"]?.nonEmptyString, text: text)
        case "terminal.close":
            guard let process = event.payload["process_id"]?.nonEmptyString, !event.sessionId.isEmpty else { return }
            backgroundProcessClosed(process, event: event)
        default: break
        }
    }

    /// `terminal.close` names only the process, so ask the gateway what it was (`process.list`, the web's own source) once.
    private func backgroundProcessClosed(_ process: String, event: GatewayEvent) {
        guard let client else { return }
        let runtime = event.sessionId
        let tracked = runningChats[runtime]
        let chat = focusedChat?.runtimeSessionId == runtime ? focusedChat : nil
        guard let profile = chat?.profile ?? tracked?.profile ?? presenceOwner(ofRuntime: runtime) else { return }
        let storedId = chat?.storedSessionId ?? tracked?.storedId
        Task { @MainActor [weak self] in
            guard let answer = try? await client.call("process.list", ["session_id": .string(runtime), "profile": .string(profile)], timeout: .seconds(15)),
                  let self else { return }
            let entries = answer["processes"]?.array ?? []
            guard let entry = entries.first(where: { $0["session_id"]?.string == process }) else { return }
            let text = BackgroundTaskText.line(command: entry["command"]?.string, status: entry["status"]?.string,
                                               exitCode: entry["exit_code"]?.int, tail: entry["output_tail"]?.string)
            let known = self.notificationEntry(runtime: runtime, profile: profile, storedId: storedId)
            NotificationHub.shared.observeBackground(processId: process, runtime: runtime, stored: storedId, text: text, entry: known)
        }
    }

    /// The chat on screen (nil on a list): its own replies don't alert.
    func notificationsFocus(runtime: String?, stored: String?) {
        NotificationHub.shared.viewing = runtime
        NotificationHub.shared.viewingStored = stored
        // UX study #257: the chat is read, so its alerts leave Notification Center, as Messages' do.
        if let stored { NotificationHub.shared.withdrawDelivered(thread: stored) }
    }

    // MARK: Permission, once, in context

    /// After a reply finishes in the chat on screen: ask iOS once, with a word first (notification-permission.ts).
    func askNotificationsOnce(after event: GatewayEvent) {
        guard event.type == "message.complete", UIApplication.shared.applicationState == .active,
              !UserDefaults.standard.bool(forKey: Self.askedKey), !Self.asking,
              let readySince = notificationsReadySince, Date().timeIntervalSince(readySince) > 10 else { return }
        Self.asking = true
        Task { @MainActor in
            defer { Self.asking = false }
            let center = UNUserNotificationCenter.current()
            let status = await center.notificationSettings().authorizationStatus
            if status != .notDetermined { UserDefaults.standard.set(true, forKey: Self.askedKey); return }
            guard MemoController.shared.takeId == nil, let host = FailureAlert.topmost(MainTabController.current) else { return }
            let answered: Bool? = await withCheckedContinuation { continuation in
                // [intents] Dismissed with no button tapped (a shortcut, a quick action, a tapped alert): not an
                // answer, so it is asked again after a later reply.
                let answer = AlertAnswer<Bool?>(continuation, unanswered: nil)
                let alert = UIAlertController(title: "Know When a Bot Replies?",
                                              message: "\(AppIdentity.current.displayName) can tell you when a bot finishes a reply while you’re away. \(DeviceWord.system) asks next.",
                                              preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Not Now", style: .cancel) { _ in answer.answer(false) })
                alert.addAction(UIAlertAction(title: "Continue", style: .default) { _ in answer.answer(true) })
                host.present(alert, animated: true)
            }
            guard let go = answered else { return }          // [intents]
            UserDefaults.standard.set(true, forKey: Self.askedKey)
            guard go else { return }
            _ = await Self.requestPermission()
        }
    }

    static let askedKey = "dispatch.notifications.asked"
    @MainActor static var asking = false

    /// iOS's prompt (once ever); a grant turns alerts on and registers with the gateway's plugin.
    static func requestPermission() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        AppLog.note("notify", granted ? "permission granted" : "permission not granted")
        if granted {
            var prefs = NotificationPrefs.load()
            if !prefs.enabled { prefs.enabled = true; prefs.save() }
            PushRegistrar.shared.sync()
        }
        return granted
    }

    // MARK: Opening the chat an alert names

    /// A tapped alert, the peek, or hermes://session/<id>: the bot's own chat from Bots, another chat from Sessions. A
    /// cold launch may arrive before the lists have their rows: it waits for them (≤ 10 s).
    func openNotifiedChat(stored: String, profile: String?, attempt: Int = 0) {
        guard let root = MainTabController.current, root.view.window != nil else {
            // A cold launch: the tabs are being put on screen right now. Still not there after ~6 s (the launch cover
            // waits on a slow first list, or the offline screen is up): it waits for them rather than being dropped.
            guard attempt < 20 else {
                AppLog.note("notify", "open chat: waiting for the tabs")
                chatAwaitingTabs = (stored, profile, Date())
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.openNotifiedChat(stored: stored, profile: profile, attempt: attempt + 1)
            }
            return
        }
        if attempt == 0 { AppLog.note("notify", "open chat") }
        // [groups] A room's alert names the room in its profile (`room:<room key>`): the room opens, not a member's chat.
        if let profile, profile.hasPrefix("room:") {
            let key = String(profile.dropFirst(5))
            guard root.guardedSheet != nil else { openRoom(key, from: nil); return }
            Task { @MainActor [weak self] in if await root.clearForRoute() { self?.openRoom(key, from: nil) } }   // UX study #263
            return
        }
        // Already on screen: read its tail, since the alert says a reply is there that the screen may not have heard
        // finish (owner, 2026-10-15: "It happened again. Same bot"; the chat was open when the alert was tapped).
        // A chat in a sheet counts too: a task's page on the iPhone is its chat.
        for top in [root.chatOnShow, Self.sheetChat(root)].compactMap({ $0 }) {   // [m9/ipad] either layout
            guard let live = top.session as? LiveChatSession, live.storedSessionId == stored || live.resolvedStoredId == stored else { continue }
            live.probeTailSoon(after: .milliseconds(1500), force: true)
            return
        }
        // [tasks] A task's own chat opens on its task, the task above it (it is hidden, so Sessions has no row for it,
        // and a bot without its own chat yet would have taken it).
        let task = TasksHub.task(forChat: stored)
        let bot = task != nil ? nil : bots.first { $0.canonicalSessionId == stored }
            ?? profile.flatMap { name in bots.first { $0.id == name && $0.canonicalSessionId == nil } }
        let session = sessions.first { $0.id == stored }
        // No task list yet (a cold launch with none on disk): it is read, so the chat can still be told for a task's.
        let listPending = task == nil && bot == nil && session == nil && TasksHub.listPending()
        if task == nil, bot == nil, session == nil, profile == nil || !botsLoaded || listPending, attempt < 20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.openNotifiedChat(stored: stored, profile: profile, attempt: attempt + 1)
            }
            return
        }
        // UX study #263: a sheet holding unsaved edits asks before it goes (S23 otherwise: it closes, the chat opens).
        if root.presentedViewController != nil, root.guardedSheet != nil {
            Task { @MainActor [weak self] in
                guard await root.clearForRoute() else { return }
                self?.openNotifiedChat(stored: stored, profile: profile, attempt: max(attempt, 1))
            }
            return
        }
        root.presentedViewController?.dismiss(animated: false)
        if let task {
            AppLog.note("notify", "open chat: a task's")
            if TasksHub.open(taskID: task.id, atReply: true) { return }
        }
        if let bot {
            root.select(.bots)
            root.botsViewController.navigationController?.popToRootViewController(animated: false)
            root.botsViewController.open(bot.id)
            return
        }
        guard let profile = session?.profile ?? profile ?? task?.chat?.profile else { return }
        root.select(.sessions)
        guard let navigation = root.sessionsViewController.navigationController else { return }
        navigation.popToRootViewController(animated: false)
        // Not listed (a task's chat with no Tasks page to show it on): its name, never an empty bar.
        let summary = session ?? SessionSummary(id: stored, profile: profile, title: task?.title ?? "", preview: nil, lastActive: nil,
                                                source: nil, unread: false, isRunning: false)
        let screen = makeChatScreen(chat(for: summary))
        screen.hidesBottomBarWhenPushed = true
        screen.navigationItem.largeTitleDisplayMode = .never
        ChatViewController.push(screen, on: navigation) {}
    }

    /// The tabs are on screen (AppDelegate.showApp): a tapped alert's chat that was waiting for them opens now, unless
    /// it was tapped more than two minutes ago (a launch that long has moved on).
    func openChatAwaitingTabs() {
        guard let waiting = chatAwaitingTabs else { return }
        chatAwaitingTabs = nil
        guard Date().timeIntervalSince(waiting.at) < 120 else { return }
        DispatchQueue.main.async { [weak self] in self?.openNotifiedChat(stored: waiting.stored, profile: waiting.profile) }
    }

    /// The chat in the sheet on top (a task's page on the iPhone), if one is.
    private static func sheetChat(_ root: MainTabController) -> ChatViewController? {
        var shown = root.presentedViewController
        while let next = shown?.presentedViewController { shown = next }
        return ((shown as? UINavigationController)?.topViewController ?? shown) as? ChatViewController
    }

    /// A connect link or QR code for the gateway already in use.
    nonisolated static func alreadyConnected(_ name: String) -> String { "Already connected to \(name)" }

    /// hermes://session/<id> and hermes://connect?url=… (the gateway's connect QR: fills the form, never signs in).
    func handleLink(_ link: NotificationRules.Link, signedIn: Bool, showSignIn: (String) -> Void) {
        switch link {
        case .session(let id):
            NotificationHub.shared.open(id, profile: nil)
        case .connect(let address):
            AppLog.note("link", "connect")
            if !signedIn { showSignIn(address); return }
            if let current = account, GatewayAddress.accountKey(url: current.baseURL.absoluteString, username: "")
                == GatewayAddress.accountKey(url: address, username: "") {
                // The gateway in use already: nothing to change, and that is said (it had done nothing at all).
                let name = settingsHub.accounts.first(where: \.isCurrent)?.title ?? GatewayNaming.title(url: current.baseURL, label: nil)
                MenusHUD.show(Self.alreadyConnected(name), in: FailureAlert.topmost(MainTabController.current)?.view)
                return
            }
            // UX study #267: a connect link or QR code that opens Add Gateway asks first while Talk or a memo take is live
            // (a sheet already open has asked).
            let host = MainTabController.current
            if let top = FailureAlert.topmost(host), AddGatewayFlow.openFlow(under: top) != nil {
                AddGatewayFlow.present(from: host, services: self, address: address)
                return
            }
            GatewaySwitchGuard.confirm(switchingTo: nil, from: host) { [weak self, weak host] in
                guard let self else { return }
                AddGatewayFlow.present(from: host, services: self, address: address)
            }
        }
    }
}

extension MainTabController {
    /// A sheet over the tabs that guards unsaved edits (it is modal in presentation), nil when none does.
    var guardedSheet: UIViewController? {
        MainBotRequest.presented(over: self).last { $0.isModalInPresentation && !($0 is UIAlertController) }
    }

    /// Before a tapped alert or a quick action opens a chat (spec S23): what is presented closes at once, except a sheet
    /// holding unsaved edits (UX study #263), which asks first, as its own ✕ or a pull down does (its presentation
    /// delegate's question, else a plain "Close This Sheet?"). True once nothing is presented; false when the sheet was
    /// kept, asked nothing, or is still up 30 s later, and then the chat doesn't open.
    func clearForRoute() async -> Bool {
        guard presentedViewController != nil else { return true }
        guard let sheet = guardedSheet else {
            presentedViewController?.dismiss(animated: false)
            return true
        }
        AppLog.note("route", "a sheet with changes asks first")
        // An alert or menu over the sheet goes, so the question can show.
        if let over = sheet.presentedViewController { over.dismiss(animated: false) }
        if let presentation = sheet.presentationController, let delegate = presentation.delegate,
           delegate.responds(to: #selector(UIAdaptivePresentationControllerDelegate.presentationControllerDidAttemptToDismiss(_:))) {
            delegate.presentationControllerDidAttemptToDismiss?(presentation)
        } else {
            // No question of its own: the sheet may hold typed edits, or only be busy (a sign-in, a bot being created,
            // a task saving) or locked (the Update screen, a webhook's one-time secret). The words claim neither.
            let discard = await withCheckedContinuation { continuation in
                let answer = AlertAnswer(continuation, unanswered: false)
                let alert = UIAlertController(title: "Close This Sheet?",
                                              message: "It isn’t finished, and anything not saved in it is lost. Close it to open the chat.",
                                              preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Keep Open", style: .cancel) { _ in answer.answer(false) })
                alert.addAction(UIAlertAction(title: "Close", style: .destructive) { _ in answer.answer(true) })
                sheet.present(alert, animated: true)
            }
            guard discard else { return false }
            presentedViewController?.dismiss(animated: false)
            return true
        }
        // Only Discard counts: once its question is answered Keep, or none shows (a save running, nothing unsaved), a
        // close later on (a save finishing) is not a yes, and the chat or memo doesn't open long after (review of #263).
        var asked = false
        for tick in 0..<600 {
            if presentedViewController == nil { return true }
            if sheet.presentedViewController != nil {
                asked = true
            } else if asked || tick >= 10 {
                // Discard closes the sheet as its question goes: give that closing a moment to finish.
                for _ in 0..<20 where presentedViewController != nil { try? await Task.sleep(for: .milliseconds(50)) }
                return presentedViewController == nil
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
}

/// The badge's ids: unread bots (by their chat's stored id, so an alert about it counts once) and unread listed chats.
enum BadgeMath {
    static func ids(bots: [Bot], sessions: [SessionSummary], visible: (SessionSummary) -> Bool) -> [String] {
        var ids: [String] = []
        var seen = Set<String>()
        for bot in bots where bot.unread && !bot.hidden {
            let id = bot.canonicalSessionId ?? "bot:" + bot.id
            if seen.insert(id).inserted { ids.append(id) }
        }
        for session in sessions where session.unread && visible(session) {
            if seen.insert(session.id).inserted { ids.append(session.id) }
        }
        return ids
    }

    /// "‹ 3" on Back inside a chat (nil: none).
    static func backTitle(_ count: Int) -> String? { count > 0 ? badge(count) : nil }

    /// A count on a badge: the number, "99+" past 99 (the tab badges and the Sessions count capsules, audit 05-19).
    nonisolated static func badge(_ count: Int) -> String { count > 99 ? "99+" : String(count) }
}

extension PushRegistrar {
    /// Runs `work`, waiting for it at most `seconds` (sign-out and switches never hang on an unreachable gateway; the work
    /// itself goes on).
    static func withBudget(seconds: Double, _ work: @escaping @MainActor () async -> Void) async {
        let flag = DoneFlag()
        Task { @MainActor in await work(); flag.done = true }
        let deadline = Date().addingTimeInterval(seconds)
        while !flag.done, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
    }

    private final class DoneFlag { var done = false }
}
