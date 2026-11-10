// [terminal] Where the Terminal opens from: More › Workspace › Terminal (so it can be a tab, and a place in the Mac's
// sidebar), and Bot Info › Computer › Terminal, shown over Bot Info. One shell per computer: every bot on a gateway
// shares the computer, so both open the same shell.

import SwiftUI
import UIKit

@MainActor enum TerminalHooks {
    /// For the page's Update Add-on (PushSetupOffer needs the app's model).
    static weak var model: AppModel?

    /// A Terminal page for the signed-in gateway; nil while none is signed in, or its client can't open the socket.
    static func page(presented: Bool) -> TerminalViewController? {
        guard let context = MorePages.context, let sockets = context.client as? any GatewayTerminalSockets else { return nil }
        return TerminalViewController(account: context.account, client: context.client, sockets: sockets, presented: presented)
    }

    /// Bot Info's row: over Bot Info (the Mac: over the right pane), closed with ✕.
    static func open(from host: UIViewController) {
        guard let page = page(presented: true) else { return }
        Haptics.play(.selection)
        PaneViewer.present(UINavigationController(rootViewController: page), from: host)
    }
}

extension MorePages {
    static func installTerminal() {
        factories["terminal"] = { _ in TerminalHooks.page(presented: false) }
    }
}

extension AppModel {
    private static var terminalInstalled = false

    /// Bot Info › Computer's Terminal row.
    func registerTerminal() {
        TerminalHooks.model = self
        #if DEBUG
        // UI tests (`-HQDebugResetTerminal YES`): the first-time question again, a new shell, the default text size.
        if UserDefaults.standard.bool(forKey: "HQDebugResetTerminal") {
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("hq.terminal.") {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        #endif
        guard !Self.terminalInstalled else { return }
        Self.terminalInstalled = true
        BotComputerHooks.terminalRow = { _, host in AnyView(TerminalInfoRow(host: host)) }
    }
}

private struct TerminalInfoRow: View {
    weak var host: UIViewController?

    var body: some View {
        Button {
            if let host { TerminalHooks.open(from: host) }
        } label: {
            HStack(spacing: 8) {
                // An icon, a title and a line under it, as the Screen and Watch Browser rows.
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Terminal").foregroundStyle(Color.hqLabel)
                        Text("Type commands on its computer").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                    }
                } icon: {
                    Image(systemName: "apple.terminal").foregroundStyle(Color.hqLabel)
                }
                Spacer(minLength: 8)
                SettingsChevron()
            }
            .padding(.vertical, 4)
        }
        .accessibilityIdentifier("bot-info.terminal")
    }
}
