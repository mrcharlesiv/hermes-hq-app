// Alerts (port of the web app's HermesNotifications, HermesPlatform.swift, build 240): the notification center's
// delegate (set before launch finishes, so a tap or an Approve/Deny that cold-launches the app is never dropped), the
// categories, local alerts raised from the gateway socket for every chat but the one on screen (Messages rules), the
// in-app reply peek, the app icon's badge, and where a tapped alert goes. Alert text never reaches AppLog.

@preconcurrency import UserNotifications
import Intents
import UIKit

@MainActor final class NotificationHub: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationHub()

    static let approvalCategory = "DISPATCH_APPROVAL"
    static let localApprovalCategory = "DISPATCH_APPROVAL_LOCAL"

    /// Who a chat's alerts are from, by runtime id and by stored id (AppModel keeps it current).
    struct Entry: Equatable {
        var who: NotificationWho
        var stored: String
        var profile: String
        /// The id the lists' unread markers count this chat by (a bot's chat: its canonical id).
        var badge: String
    }

    /// Opens a chat (stored id, bot profile). Nil until the signed-in app is up: a tap that cold-launched waits in `pending`.
    var openChat: ((_ stored: String, _ profile: String?) -> Void)? { didSet { deliverPending() } }
    /// Answers an approval the app holds (a local alert's Approve/Deny): entry id, choice.
    var answerLocal: ((_ request: String, _ approve: Bool) -> Void)? { didSet { deliverPending() } }
    /// The bot's face for a profile (for the peek and Communication Notifications), and whether it is the bot's photo
    /// ([photoheads] the peek draws a photo as an app-icon tile and cuts only a head round).
    var face: ((_ profile: String) -> BotFaces.Face?)?
    /// The window the peek drops into.
    var window: (() -> UIWindow?)?
    /// [groups] Whether a stored session id is a group member's hidden turn session (the room alerts its replies itself).
    var isRoomMemberSession: ((_ stored: String) -> Bool)?
    /// A tapped alert came from another gateway account (its push tag): says which, instead of opening a chat (UX study
    /// #262). `chat`: the chat it would have opened (stored id, bot profile), for a switch to that gateway.
    var otherGateway: ((_ account: String, _ chat: (stored: String, profile: String?)?) -> Void)? { didSet { deliverPending() } }
    /// [device-access] Opens a bot's email or text draft (DraftsStore) in its composer: the draft's id.
    var openDraft: ((_ id: String) -> Void)? { didSet { deliverPending() } }
    /// [tasks] A task's alert (`kind: "task"`, pushed or this phone's own due reminder): that task's sheet.
    var openTask: ((_ id: String, _ profile: String?) -> Void)? { didSet { deliverPending() } }

    private var pending: (stored: String, profile: String?)?
    /// The push account of a tap that came before this phone knew whose gateway it is on (a cold launch): checked
    /// once the owner is set, before the chat opens (UX study #262).
    private var pendingAccount: String?
    private var pendingOther: (account: String, chat: (stored: String, profile: String?)?)?
    private var pendingAnswer: (request: String, approve: Bool)?
    private var pendingDraft: String?
    private var pendingTask: (id: String, profile: String?)?
    private(set) var epoch = 0
    private var seen = Set<String>()
    private var order: [String] = []
    /// The chat on screen (nil on a list), by runtime id and by stored id.
    var viewing: String?
    var viewingStored: String?
    private var directory: [String: Entry] = [:]
    private var directoryOrder: [String] = []
    private var badge = NotificationBadge()
    private(set) var badgeCount = 0
    private var savedFaces: [String: Int] = [:]

    // MARK: Launch

    func install() {
        #if DEBUG
        // UI tests: Settings › Notifications as on a fresh install (all on, previews on, setup not yet offered).
        if UserDefaults.standard.bool(forKey: "HQDebugResetNotificationPrefs") {
            for key in [NotificationPrefs.key, NotificationPrefs.bannersKey, "hermes.pushSetup.offeredLevel", AddOnUpdate.byHandKey] { UserDefaults.standard.removeObject(forKey: key) }
            // [addon-reminder] and every account's quiet reminder
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("push.addOnReminder.") {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        #endif
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(Set(Self.categories()))
    }

    static func categories() -> [UNNotificationCategory] {
        // Approving runs a command on the gateway computer, so it needs an unlocked phone; Deny doesn't. A pushed alert
        // answers through the push plugin without opening the app; a local one opens the app to answer.
        // UX study #147: title case, as iOS's own action buttons are.
        let approve = UNNotificationAction(identifier: "approve", title: "Approve Once", options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: "deny", title: "Deny", options: [.destructive])
        let approveHere = UNNotificationAction(identifier: "approve", title: "Approve Once", options: [.authenticationRequired, .foreground])
        let denyHere = UNNotificationAction(identifier: "deny", title: "Deny", options: [.destructive, .foreground])
        return [UNNotificationCategory(identifier: approvalCategory, actions: [approve, deny], intentIdentifiers: [], options: []),
                UNNotificationCategory(identifier: localApprovalCategory, actions: [approveHere, denyHere], intentIdentifiers: [], options: [])]
    }

    /// [tasks] A task push reached the app: the Tasks list reads again.
    static let taskPushed = Notification.Name("hq.tasks.pushed")

    private func deliverPending() {
        if let pending, let openChat {
            self.pending = nil
            let account = pendingAccount
            pendingAccount = nil
            // UX study #262: a cold launch's tap is checked now that the owner is known.
            if let account, let owner = PushRegistrar.shared.owner, account != owner {
                AppLog.note("notify", "alert from another gateway (launch)")
                pendingOther = (account, pending)
            } else {
                openChat(pending.stored, pending.profile)
            }
        }
        if let pendingAnswer, let answerLocal { self.pendingAnswer = nil; answerLocal(pendingAnswer.request, pendingAnswer.approve) }
        if let pendingOther, let otherGateway { self.pendingOther = nil; otherGateway(pendingOther.account, pendingOther.chat) }
        if let pendingDraft, let openDraft { self.pendingDraft = nil; openDraft(pendingDraft) }
        if let pendingTask, let openTask { self.pendingTask = nil; openTask(pendingTask.id, pendingTask.profile) }
    }

    // MARK: Directory

    func label(runtime: String?, entry: Entry) {
        for key in [runtime, entry.stored].compactMap({ $0 }) where NotificationRules.valid(key) {
            directoryOrder.removeAll { $0 == key }
            directory[key] = entry
            directoryOrder.append(key)
        }
        while directoryOrder.count > 512 { directory[directoryOrder.removeFirst()] = nil }
    }

    func entry(_ session: String) -> Entry? { directory[session] }

    /// The bot's round face for pushed alerts, saved where the extension reads it (by account and profile).
    /// `signature` names what the face is drawn from (its head record): an unchanged bot is never drawn or written again.
    func saveFace(profile: String, signature: Int, account: String?, image: () -> UIImage?) {
        guard let account, !profile.isEmpty else { return }
        let key = account + "\n" + profile
        guard savedFaces[key] != signature, let png = Self.roundPNG(image()) else { return }
        if PushFaces.save(png, account: account, profile: profile) { savedFaces[key] = signature }
    }

    /// [photoheads] Whether `saveFace` would draw and write this face (false: this run already saved it as it is).
    func needsFace(profile: String, signature: Int, account: String) -> Bool {
        !profile.isEmpty && savedFaces[account + "\n" + profile] != signature
    }

    static func roundPNG(_ image: UIImage?) -> Data? {
        guard let image else { return nil }
        let size = CGSize(width: 120, height: 120), rect = CGRect(origin: .zero, size: size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { _ in
            UIBezierPath(ovalIn: rect).addClip()
            image.draw(in: rect)
        }
    }

    // MARK: Badge

    /// The lists' unread markers (Bots tab + Sessions tab ids): the icon's badge.
    func setUnread(_ ids: [String]) {
        let prefs = NotificationPrefs.load()
        badge.markers(ids, enabled: prefs.enabled, active: UIApplication.shared.applicationState == .active)
        applyBadge(prefs.enabled ? badge.count : 0)
    }

    func becameActive() {
        badge.becameActive()
        applyBadge(NotificationPrefs.load().enabled ? badge.count : 0)
    }

    private func applyBadge(_ count: Int) {
        guard count != badgeCount else { return }
        badgeCount = count
        Task { try? await UNUserNotificationCenter.current().setBadgeCount(count) }
    }

    // MARK: Local alerts

    /// A frame's event from the gateway socket for a chat the directory knows (`runtime`): a finished or failed reply.
    func observeTurnEnd(runtime: String, seq: Int?, failed: Bool, text: String, entry: Entry?) {
        let kind = failed ? "turnError" : "message.complete"
        let key = "\(runtime):\(seq.map(String.init) ?? String(text.hashValue)):\(kind)"
        guard remember(key) else { return }
        // Once the gateway's push plugin delivers these, local copies would duplicate them (its push still peeks here).
        guard !PushRegistrar.shared.delivers(kind) else {
            AppLog.trace("notify", "local \(kind) \(AppLog.tag(runtime)) skipped: push plugin delivers it")
            return
        }
        let session = entry?.stored ?? runtime
        guard NotificationRules.shouldPost(session: session, active: UIApplication.shared.applicationState == .active,
                                           viewing: viewing ?? viewingStored, viewingStored: viewingStored),
              runtime != viewing else { return }
        let shown = failed ? text : NotificationText.preview(text)
        let current = epoch
        Task { _ = await self.post(kind: kind, session: session, id: key, text: shown, entry: entry, epoch: current) }
    }

    /// [settings] Credits paused or restored (`notification.show` with key `credits.depleted` / `credits.restored`): an alert
    /// while the app is not in front (in front, the person is looking; docs/spec/3x-settings.md §15c).
    func observeCredits(key: String, id: String?, text: String) {
        guard Self.creditKeys.contains(key), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let marker = "credits:\(key):\(id ?? String(text.hashValue))"
        guard remember(marker), !PushRegistrar.shared.delivers("credits"),
              UIApplication.shared.applicationState != .active else { return }
        let current = epoch
        Task { _ = await self.post(kind: "credits", session: "", id: marker, title: "Credits", about: text, epoch: current) }
    }
    nonisolated static let creditKeys: Set<String> = ["credits.depleted", "credits.restored"]

    /// [settings] A background process of a chat finished (spec §15b): an alert unless that chat is on screen and the app in front.
    func observeBackground(processId: String, runtime: String, stored: String?, text: String, entry: Entry?) {
        guard remember("background:\(processId)"), !PushRegistrar.shared.delivers("backgroundDone") else { return }
        let session = entry?.stored ?? stored ?? runtime
        guard NotificationRules.shouldPost(session: session, active: UIApplication.shared.applicationState == .active,
                                           viewing: viewing ?? viewingStored, viewingStored: viewingStored) else { return }
        let current = epoch
        Task { _ = await self.post(kind: "backgroundDone", session: session, id: "background-" + processId, text: text, entry: entry, epoch: current) }
    }

    /// A request the app holds for a chat (approval, question, password): it alerts when that chat isn't on screen.
    func observeRequest(id: String, kind: PromptKind, runtime: String, params: JSONValue, entry: Entry?) {
        guard remember("request:\(id)") else { return }
        let alertKind = kind == .approval ? "approval.request" : "input"
        if PushRegistrar.shared.delivers(alertKind) { return }
        let session = entry?.stored ?? runtime
        guard NotificationRules.shouldPost(session: session, active: UIApplication.shared.applicationState == .active,
                                           viewing: viewing ?? viewingStored, viewingStored: viewingStored),
              runtime != viewing else { return }
        let text: String, about: String
        switch kind {
        case .approval:
            text = NotificationText.commandSummary(params["command"]?.string ?? "")
            about = NotificationText.preview(params["description"]?.string ?? "")
        case .clarify:
            text = NotificationText.preview(params["questions"]?.array?.first?["question"]?.string ?? params["question"]?.string ?? "")
            about = ""
        default:
            text = NotificationText.preview(NotificationText.valueRequestLine(kind, params: params))
            about = ""
        }
        let current = epoch
        Task { _ = await self.post(kind: alertKind, session: session, id: "request-" + id, text: text, about: about,
                                   request: kind == .approval ? id : "", entry: entry, epoch: current) }
    }

    private func remember(_ key: String) -> Bool {
        guard !seen.contains(key) else { return false }
        seen.insert(key); order.append(key)
        if order.count > 512 { seen.remove(order.removeFirst()) }
        return true
    }

    /// One local alert. `text` is what it previews (a reply, question, command or failure reason); `title`/`about` are
    /// the Settings test's own words or an approval's description.
    @discardableResult
    func post(kind: String, session: String, id: String = UUID().uuidString, title: String? = nil, text: String? = nil,
              about: String? = nil, request: String = "", entry: Entry? = nil, epoch: Int? = nil) async -> Bool {
        let observed = epoch ?? self.epoch
        let prefs = NotificationPrefs.load()
        guard kind == "test" || prefs.allows(NotificationPrefs.preference(kind)) else {
            AppLog.trace("notify", "\(kind) \(AppLog.tag(session)) skipped: preference off")
            return false
        }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let active = UIApplication.shared.applicationState == .active
        let entry = entry ?? directory[session]
        // Per-bot Mute on this iPhone: a muted bot's finished replies neither alert nor peek; approvals still do.
        guard BotMuteCenter.shared.allows(kind: kind, profile: entry?.profile ?? "") else {
            AppLog.note("notify", "muted \(kind) \(AppLog.tag(session))")
            return false
        }
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            // No permission: inside the app a reply still peeks.
            AppLog.trace("notify", "\(kind) \(AppLog.tag(session)) skipped: not authorized")
            if kind == "message.complete", active, let entry { showPeek(name: entry.who.sender, body: text ?? "", entry: entry) }
            return false
        }
        let copy = NotificationText.notification(kind: kind, who: entry?.who, text: text, title: title, body: about,
                                                 previews: prefs.previews)
        let content = UNMutableNotificationContent()
        content.title = copy.title
        content.subtitle = copy.subtitle
        content.body = copy.body
        content.sound = .default
        content.interruptionLevel = .active
        content.relevanceScore = NotificationRules.relevance(kind: kind, session: session, viewing: viewingStored)
        let stored = entry?.stored ?? session
        if !session.isEmpty { content.threadIdentifier = stored }
        content.userInfo = NotificationText.localInfo(session: session, stored: stored, request: request, kind: kind,
                                                      profile: entry?.profile ?? "")
        let command = kind == "approval.request" ? NotificationText.commandSummary(text ?? "") : ""
        if prefs.previews, NotificationText.approvable(command), NotificationRules.valid(session), !request.isEmpty {
            content.categoryIdentifier = Self.localApprovalCategory
        }
        let chat = entry?.badge ?? stored
        if prefs.enabled, badge.alert(kind: kind, chat: chat, active: active) {
            content.badge = NSNumber(value: badge.count)
            badgeCount = badge.count
        }
        var final: UNNotificationContent = content
        let png = entry.flatMap { face?($0.profile)?.image }.flatMap(Self.roundPNG)   // [intents] made once: the alert's and the donation's
        if let entry, !entry.who.sender.isEmpty, let png {
            let who = NotificationText.sanitized(entry.who)
            let name = !who.group.isEmpty ? who.group : copy.subtitle
            final = PushFaces.message(content, sender: who.sender, profile: entry.profile, face: png, chat: name, conversation: stored)
        }
        guard NotificationText.mayPost(observed: observed, current: self.epoch) else {
            AppLog.trace("notify", "\(kind) \(AppLog.tag(session)) skipped: sign-out epoch changed mid-post")
            return false
        }
        donateConversation(kind: kind, entry: entry, subtitle: copy.subtitle, stored: stored, face: png)   // [intents] not waited for
        do {
            try await center.add(UNNotificationRequest(identifier: id, content: final, trigger: nil))
            AppLog.note("notify", "posted \(kind) \(AppLog.tag(session))")
            return true
        } catch {
            AppLog.swallowed("notify", "post \(kind) \(AppLog.tag(session))", error)
            return false
        }
    }

    // MARK: Peek

    private func showPeek(name: String, body: String, entry: Entry) {
        guard NotificationPrefs.banners(), let window = window?() else { return }
        let alert = PeekAlert(name: name.isEmpty ? "New reply" : name, body: body, session: entry.stored, profile: entry.profile,
                              face: face?(entry.profile))
        PresenceNotice.shared.dismiss(up: true)   // [presence] one banner at the banner spot: the newer one wins
        ReplyPeek.shared.show(alert, in: window) { [weak self] alert in self?.open(alert.session, profile: alert.profile) }
        AppLog.note("notify", "peek")
    }

    // MARK: Sign-out

    func clear() {
        epoch += 1
        seen.removeAll(); order.removeAll(); directory.removeAll(); directoryOrder.removeAll(); savedFaces.removeAll()
        badge = NotificationBadge(); badgeCount = 0; pending = nil; pendingAccount = nil; pendingAnswer = nil; pendingOther = nil; pendingDraft = nil; pendingTask = nil; viewing = nil; viewingStored = nil
        ReplyPeek.shared.dismiss(up: true)
        INInteraction.deleteAll { _ in }
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests(); center.removeAllDeliveredNotifications()
        Task { try? await center.setBadgeCount(0) }
    }

    /// An approval answered anywhere (the plugin's silent settle push): its alert, saved answer and notice go.
    func settle(request: String) async {
        PushRegistrar.shared.withdraw(request)
        let center = UNUserNotificationCenter.current()
        let ids = await center.deliveredNotifications().filter {
            (($0.request.content.userInfo["dispatch"] as? [String: Any])?["request"] as? String) == request
        }.map { $0.request.identifier }
        center.removeDeliveredNotifications(withIdentifiers: ids + [PushRegistrar.notice(request)])
    }

    /// UX study #257: requests the app held that went (answered here or elsewhere, withdrawn, expired): their local
    /// alerts (`request-<id>`) leave Notification Center, so no stale Approve is left to tap.
    func withdrawLocal(requests: Set<String>) {
        guard !requests.isEmpty else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: requests.map { "request-" + $0 })
    }

    /// UX study #257: a chat came on screen: its delivered alerts (by thread, the chat's stored id) go.
    func withdrawDelivered(thread: String) {
        guard NotificationRules.valid(thread) else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            let ids = await center.deliveredNotifications().filter { $0.request.content.threadIdentifier == thread }
                .map { $0.request.identifier }
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    // MARK: Delegate

    // The completion-handler forms, finished on the main thread: with the async forms Swift calls UIKit's completion from
    // a background thread, and UIKit raises "Call must be made on main thread" (a tapped alert crashed the app).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let box = UnsafeTransfer((notification, completionHandler))
        DispatchQueue.main.async {
            MainActor.assumeIsolated { box.value.1(self.present(box.value.0)) }
        }
    }

    private func present(_ notification: UNNotification) -> UNNotificationPresentationOptions {
        let content = notification.request.content
        // [device-access] A bot's draft waiting on this phone (DraftsStore): always shown, it's for no chat.
        if content.userInfo["deviceDraft"] is String { return [.banner, .list, .sound] }
        // [update-flow] A Hermes update ended while its sheet wasn't on screen: always shown.
        if content.userInfo[HermesUpdate.alertKey] is String { return [.banner, .list, .sound] }
        let info = PushSeal.opened(content.userInfo, keys: PushSealKeys.all())
        let kind: String
        let muteKind: String
        if let remote = info["dispatch"] as? [String: Any] {
            // [device-access] A bot's request reached the app on screen as a presented push (the add-on sends it silent;
            // a simulator only delivers it with words): answered, never shown.
            if remote["kind"] as? String == "device" {
                Task { await DeviceAccessCenter.shared.woke() }
                return []
            }
            // [tasks] The list changed on the computer: read it again (the alert still shows).
            if remote["kind"] as? String == "task" { NotificationCenter.default.post(name: NotificationHub.taskPushed, object: nil) }
            if remote["settled"] as? Bool == true {
                let request = remote["request"] as? String ?? ""
                Task { await self.settle(request: request) }
                return []
            }
            // UX study #261: its real kind, so only a finished reply borrows the peek (questions keep iOS's banner).
            kind = NotificationRules.pushedKind(remote)
            muteKind = BotMutes.pushKind(remote)
        } else {
            kind = info["kind"] as? String ?? ""
            muteKind = kind
        }
        let target = NotificationRules.target(info)
        let session = target?.session ?? ""
        // Per-bot Mute: a muted bot's finished reply shows nothing while the app is open (the extension already made it quiet).
        if let profile = target?.profile ?? directory[session]?.profile, !BotMuteCenter.shared.allows(kind: muteKind, profile: profile) {
            AppLog.trace("notify", "incoming \(kind) \(AppLog.tag(session)) presented as nothing: bot muted")
            return []
        }
        // [mac] Stress test 2026-10-28 #31: a Mac app runs while another app is in front, where the window (and a peek in
        // it) goes unseen: only the frontmost app counts as looking, so a covered one gets the system's banner. iOS asks
        // here only while the app is on screen.
        let looking = !DeviceWord.isMac || UIApplication.shared.applicationState == .active
        guard NotificationRules.shouldPost(session: session, active: looking, viewing: viewing ?? viewingStored, viewingStored: viewingStored)
        else {
            AppLog.trace("notify", "incoming \(kind) \(AppLog.tag(session)) presented as nothing: chat on screen")
            return []
        }
        // [groups] A room member's hidden session: its reply is the room's, which the app alerts itself (and never for a
        // "(pass)"), so the add-on's push for it shows nothing. A "(pass)" pushed for a session the app doesn't know as a
        // room's (an add-on before 0.9.41, a room from another device) shows nothing either.
        if kind == "message.complete", isRoomMemberSession?(session) == true || GroupPrompt.isRoomPass(content.body) {
            AppLog.trace("notify", "incoming \(kind) \(AppLog.tag(session)) presented as nothing: a group member's turn")
            return []
        }
        // While the app is on screen another chat's finished reply is the app's own notice (the peek): iOS's banner
        // would cover the chat's title. The sound and Notification Center stay; approvals keep the banner.
        if kind == "message.complete", looking, NotificationPrefs.banners(), let target, let window = window?() {
            let entry = directory[target.session]
            let name = entry?.who.sender.isEmpty == false ? entry!.who.sender : content.title
            let profile = target.profile ?? entry?.profile
            let alert = PeekAlert(name: name, body: content.body, session: target.session, profile: profile,
                                  face: profile.flatMap { face?($0) })
            PresenceNotice.shared.dismiss(up: true)   // [presence] one banner at the banner spot
            ReplyPeek.shared.show(alert, in: window) { [weak self] alert in self?.open(alert.session, profile: alert.profile) }
            AppLog.note("notify", "peek")
            return [.list, .sound, .badge]
        }
        if !looking { AppLog.trace("notify", "incoming \(kind) \(AppLog.tag(session)) as a banner: another app in front") }
        return [.banner, .list, .sound, .badge]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let box = UnsafeTransfer((response, completionHandler))
        Task { @MainActor in
            await self.respond(box.value.0)
            box.value.1()     // on the main actor
        }
    }

    private func respond(_ response: UNNotificationResponse) async {
        let delivered = response.notification.request.content.userInfo
        if let draft = delivered["deviceDraft"] as? String {
            // [device-access] A bot's email or text: its composer, filled in (nothing is sent until Send there).
            AppLog.note("notify", "response draft")
            if let openDraft { openDraft(draft) } else { pendingDraft = draft }
            return
        }
        if let key = delivered[HermesUpdate.alertKey] as? String {
            // [update-flow] The update's sheet, with how it ended.
            AppLog.note("notify", "response hermes update")
            let shown = response.notification.request.content
            HermesUpdateCenter.shared.open(key, title: shown.title, body: shown.body)
            return
        }
        let info = PushSeal.opened(delivered, keys: PushSealKeys.all())
        let action = response.actionIdentifier
        let remote = info["dispatch"] as? [String: Any]
        let actionSession = (remote?["session"] as? String) ?? (info["kind"] != nil ? NotificationRules.target(info)?.session : nil)
        AppLog.note("notify", "response \(action == UNNotificationDefaultActionIdentifier ? "open" : action) \(AppLog.tag(actionSession))")
        if action == "approve" || action == "deny", let remote {
            // UX study #260: a follow-up about this answer names the bot and the command the alert showed.
            let shown = response.notification.request.content
            let session = remote["session"] as? String ?? "", profile = remote["profile"] as? String ?? ""
            let known = directory[session]?.who.sender ?? ""
            let about = PushRegistrar.About(who: known.isEmpty && delivered["seal"] == nil ? shown.title : known,
                                            command: NotificationText.shownCommand(shown.body), profile: profile)
            if action == "approve", !PushPolicy.mayAnswer(action, delivered: delivered) {
                await PushRegistrar.shared.unseenApproval(remote["request"] as? String ?? "", session: session, about: about)
                return
            }
            await PushRegistrar.shared.answer(remote, choice: action == "approve" ? "once" : "deny", about: about)
            return
        }
        // UX study #262: an alert from a gateway this phone switched away from would open a chat id this gateway
        // doesn't have; it says where it came from instead.
        let target = NotificationRules.target(info)
        let account = NotificationRules.account(info)
        if let account, let owner = PushRegistrar.shared.owner, account != owner {
            AppLog.note("notify", "alert from another gateway")
            let chat = target.map { (stored: $0.session, profile: $0.profile) }
            if let otherGateway { otherGateway(account, chat) } else { pendingOther = (account, chat) }
            return
        }
        if action == "approve" || action == "deny", let request = info["request"] as? String, !request.isEmpty {
            // A local approval alert: the app answers it (it opened for that), in the chat it belongs to.
            if let answerLocal { answerLocal(request, action == "approve") } else { pendingAnswer = (request, action == "approve") }
        }
        // [tasks] A task's alert opens its sheet (a pushed one in `dispatch`, this phone's own due reminder at the top).
        let taskInfo: [AnyHashable: Any] = remote.map { $0.reduce(into: [AnyHashable: Any]()) { $0[$1.key] = $1.value } } ?? info
        // The add-on's alert carries the task's id as its `request` (hermes-hq-push 0.9.32); this phone's own due
        // reminder says `task_id`.
        if taskInfo["kind"] as? String == "task", let id = (taskInfo["task_id"] as? String) ?? (taskInfo["request"] as? String), !id.isEmpty {
            let profile = taskInfo["profile"] as? String
            AppLog.note("notify", "response task")
            if let openTask { openTask(id, profile) } else { pendingTask = (id, profile) }
            return
        }
        // No owner yet (a cold launch): the account goes with the waiting tap and is checked when the app is up.
        if let target { open(target.session, profile: target.profile, account: PushRegistrar.shared.owner == nil ? account : nil) }
    }

    func open(_ stored: String, profile: String?) { open(stored, profile: profile, account: nil) }

    private func open(_ stored: String, profile: String?, account: String?) {
        if let openChat { openChat(stored, profile) } else { pending = (stored, profile); pendingAccount = account }
    }

    /// A link or tap that arrived before the app was up.
    func queueOpen(_ stored: String, profile: String?) { open(stored, profile: profile) }
}

/// Hands a value the system gave on its own thread to the main actor (UserNotifications types aren't Sendable).
nonisolated struct UnsafeTransfer<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
