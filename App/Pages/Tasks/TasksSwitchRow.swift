// [tasks] Settings › Tasks. Owner 2026-11-04: "We need a way for users to be able to turn off the tasks feature
// entirely." Off: the Tasks page leaves More, the tabs and the Mac's Tools; this phone's due alerts go; the gateway is
// told (hermes-hq-push 0.9.36), so no bot sees the task tools, gets the shared-tasks note or runs its prep job. The
// list is kept, and on brings it all back. Shown while a gateway is signed in.

import SwiftUI

struct TasksSwitchRow: View {
    @State private var on: Bool
    @State private var saving = false
    private let account: GatewayAccount

    init?() {
        guard let context = MorePages.context else { return nil }
        account = context.account
        _on = State(initialValue: !TasksHub.isOff(context.account))
    }

    var body: some View {
        // The switch itself ticks (a system control): no cue of ours on top.
        Toggle(isOn: Binding(get: { on }, set: { next in
            on = next
            saving = true
            Task {
                await TasksHub.setEnabled(next)
                saving = false
                on = !TasksHub.isOff(account)   // a failed save puts it back
            }
        })) {
            SettingsRowLabel(title: "Tasks", systemImage: "checklist")
        }
        .disabled(saving)
        .accessibilityIdentifier("settings.tasks")
    }

    /// Settings search's "row:tasks" mark (the row it scrolls to and flashes).
    func revealed(_ revealed: String?) -> some View { revealRow("row:tasks", revealed) }

    static let footer = "Off hides Tasks, and your bots stop adding tasks or working on them. Your list is kept for when you turn it back on."
}
