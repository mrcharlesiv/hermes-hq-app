// [device-access] Drafts waiting on this phone (Settings › Device Access › Email & Text Drafts): kept in
// UserDefaults, newest first, expired or over the cap dropped (DeviceAccess.liveDrafts). Opening one hands it to Mail
// or Messages, already filled in; nothing goes until the owner taps Send there.

import Foundation
import MessageUI
import UIKit
import UserNotifications

enum DraftsStore {
    /// Posted when a draft is added, sent or cleared (the Email & Text Drafts page lists the waiting ones).
    static let changed = Notification.Name("hq.deviceAccess.draftsChanged")
    static let key = "hq.deviceAccess.drafts"
    private static var openDelegates: [String: ComposeDelegate] = [:]

    private static func load(_ defaults: UserDefaults) -> [DeviceAccess.Draft] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([DeviceAccess.Draft].self, from: data)) ?? []
    }

    private static func save(_ drafts: [DeviceAccess.Draft], _ defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(drafts), forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// Newest first; nothing over 24 hours old (trimmed on disk too, so a stale one is never opened).
    static var waiting: [DeviceAccess.Draft] {
        let defaults = UserDefaults.standard
        let before = load(defaults)
        let live = DeviceAccess.liveDrafts(before)
        if live.count != before.count { save(live, defaults) }
        return live
    }

    @discardableResult
    static func add(_ draft: DeviceAccess.Draft, _ defaults: UserDefaults = .standard) -> DeviceAccess.Draft {
        save(DeviceAccess.liveDrafts(load(defaults), adding: draft), defaults)
        return draft
    }

    static func discard(_ id: String, _ defaults: UserDefaults = .standard) {
        save(load(defaults).filter { $0.id != id }, defaults)
    }

    static func find(_ id: String, _ defaults: UserDefaults = .standard) -> DeviceAccess.Draft? {
        DeviceAccess.liveDrafts(load(defaults)).first { $0.id == id }
    }

    // MARK: Notification

    /// Posts the "wrote an email/text" alert; false when notifications aren't allowed (the draft still waits;
    /// DraftsAccess adds where to find it to the words it sends back).
    @discardableResult
    static func notify(_ draft: DeviceAccess.Draft) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return false }
        let content = UNMutableNotificationContent()
        content.title = DeviceAccess.draftNotificationTitle(kind: draft.kind, bot: draft.bot)
        content.body = DeviceAccess.draftNotificationBody(to: draft.to, body: draft.body)
        content.sound = .default
        content.userInfo = ["deviceDraft": draft.id]
        do {
            try await center.add(UNNotificationRequest(identifier: "draft-" + draft.id, content: content, trigger: nil))
            return true
        } catch {
            return false
        }
    }

    // MARK: Opening

    /// Tapping the notification (or a waiting-drafts row) calls this: Mail or Messages, filled in. Sent: the draft
    /// goes. Cancelled: it stays, to open again later.
    static func open(_ id: String, from presenter: UIViewController) {
        guard let draft = find(id) else { return }
        draft.kind == "text" ? openText(draft, from: presenter) : openEmail(draft, from: presenter)
    }

    private static func openEmail(_ draft: DeviceAccess.Draft, from presenter: UIViewController) {
        guard MFMailComposeViewController.canSendMail() else { return openMailto(draft) }
        let composer = MFMailComposeViewController()
        composer.setToRecipients(draft.to)
        if !draft.cc.isEmpty { composer.setCcRecipients(draft.cc) }
        composer.setSubject(draft.subject ?? "")
        composer.setMessageBody(draft.body, isHTML: false)
        let delegate = ComposeDelegate(id: draft.id)
        composer.mailComposeDelegate = delegate
        openDelegates[draft.id] = delegate
        presenter.present(composer, animated: true)
    }

    private static func openText(_ draft: DeviceAccess.Draft, from presenter: UIViewController) {
        guard MFMessageComposeViewController.canSendText() else {
            let alert = UIAlertController(title: "Can’t Send a Text", message: "\(DeviceWord.Subject) can’t send text messages.",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            presenter.present(alert, animated: true)
            return
        }
        let composer = MFMessageComposeViewController()
        composer.recipients = draft.to
        composer.body = draft.body
        let delegate = ComposeDelegate(id: draft.id)
        composer.messageComposeDelegate = delegate
        openDelegates[draft.id] = delegate
        presenter.present(composer, animated: true)
    }

    /// No Mail account set up: a mailto: link, filled in. It can't say whether the mail was sent, so the draft stays
    /// until the owner clears it themselves.
    private static func openMailto(_ draft: DeviceAccess.Draft) {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = draft.to.joined(separator: ",")
        var query: [URLQueryItem] = []
        if !draft.cc.isEmpty { query.append(URLQueryItem(name: "cc", value: draft.cc.joined(separator: ","))) }
        if let subject = draft.subject, !subject.isEmpty { query.append(URLQueryItem(name: "subject", value: subject)) }
        query.append(URLQueryItem(name: "body", value: draft.body))
        components.queryItems = query
        guard let url = components.url else { return }
        UIApplication.shared.open(url)
    }

    private static func finished(_ id: String, sent: Bool) {
        if sent { discard(id) }
        openDelegates[id] = nil
    }

    @MainActor private final class ComposeDelegate: NSObject, MFMailComposeViewControllerDelegate, MFMessageComposeViewControllerDelegate {
        let id: String
        init(id: String) { self.id = id }

        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            controller.dismiss(animated: true)
            DraftsStore.finished(id, sent: result == .sent)
        }

        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            controller.dismiss(animated: true)
            DraftsStore.finished(id, sent: result == .sent)
        }
    }
}
