// [device-access] Email & Text Drafts for Device Access (docs/device-access.md): no iOS permission to ask (nothing is
// sent without the owner reviewing and tapping Send), so only `drafts.create`'s own rules matter. DraftsStore keeps
// the draft on disk and raises the notification that opens it.

import Foundation

enum DraftsAccess: DeviceAccessHandler {
    static let kind = DeviceAccess.Kind.drafts

    static var permission: DeviceAccessPermission { .allowed }

    static func requestPermission(turningOn key: String) async -> Bool {
        // [mac] Mail compose works through Mac Catalyst; there's no Messages composer to hand a text draft to.
        #if targetEnvironment(macCatalyst)
        key != "text"
        #else
        true
        #endif
    }

    /// Audit 09-10: said when Text Message Drafts is turned on, rather than the switch flipping back without a word.
    static func unsupported(_ key: String) -> String? {
        #if targetEnvironment(macCatalyst)
        key == "text" ? "\(AppIdentity.current.displayName) can’t open a text message to send on the Mac. Email drafts work here." : nil
        #else
        nil
        #endif
    }

    static func answer(_ request: DeviceAccess.Request, scopes: Set<String>) async -> DeviceAccess.Answer {
        guard request.op == "drafts.create" else { return .unavailable(DeviceAccess.unknownWords) }
        guard let plan = DeviceAccess.draftPlan(request) else {
            return .failed("That draft needs someone to send it to and words to send.")
        }
        #if targetEnvironment(macCatalyst)
        guard plan.kind != "text" else { return .unavailable("Text drafts aren’t available on this device.") }
        #endif
        guard scopes.contains(plan.kind) else { return .unavailable(DeviceAccess.scopeOffWords(.drafts, [plan.kind])) }
        let draft = DeviceAccess.Draft(id: request.id, kind: plan.kind, to: plan.to, cc: plan.cc, subject: plan.subject,
                                       body: plan.body, bot: DeviceAccessCenter.shared.botName(request.bot),
                                       createdAt: .now)
        DraftsStore.add(draft)
        let posted = await DraftsStore.notify(draft)
        var note = "The draft is waiting on the user's \(DeviceWord.name); nothing is sent until they review it and tap Send."
        if !posted { note += " They’ll find it in Settings › Device Access › \(DeviceAccess.Kind.drafts.title)." }
        return .done(["draft": "waiting", "kind": .string(plan.kind), "note": .string(note)])
    }
}
