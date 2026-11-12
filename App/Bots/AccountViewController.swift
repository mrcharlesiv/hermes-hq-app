// Settings-lite for M1: the gateway this phone is signed in to, who it's signed in as, and Sign Out.

import SwiftUI
import UIKit

final class AccountViewController: UIHostingController<HQScaledRoot<AccountView>> {
    init(services: any AppServices) {
        let actions = AccountActions()
        super.init(rootView: HQScaledRoot(AccountView(account: services.account, connection: services.connection, actions: actions)))
        actions.done = { [weak self] in self?.dismiss(animated: true) }
        actions.signOut = { [weak self, weak services] in
            self?.dismiss(animated: true) { services?.signOut() }
        }
        // The Gateway page's words: the gateway by name, where the app goes next, what this phone deletes.
        actions.signOutWords = { [weak services] in
            let rows = (services as? SettingsServices)?.gateways.accounts ?? []
            let account = services?.account
            let name = rows.first(where: \.isCurrent)?.title ?? account.map { GatewayNaming.title(url: $0.baseURL, label: nil) } ?? "this gateway"
            return SignOutWords.signOut(accountId: account?.id, name: name, next: rows.first { !$0.isCurrent }?.title)
        }
        if let sheet = sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.hqPreferLargeAtAccessibilitySizes()   // [a11y]
            sheet.prefersGrabberVisible = false
            sheet.hqGlassPage()   // [glass-audit] a half-height sheet sits on Liquid Glass, its rows on solid cards
        }
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

final class AccountActions {
    var done: () -> Void = {}
    var signOut: () -> Void = {}
    var signOutWords: () -> (title: String, message: String) = { ("Sign out of this gateway?", "") }
}

struct AccountView: View {
    var account: GatewayAccount?
    var connection: ConnectionState
    var actions: AccountActions
    @State private var confirming = false
    @State private var confirmTitle = ""
    @State private var confirmMessage = ""

    /// How the account is named: "Nous account" for Sign in with Nous, never its id (spec 01 §2.1).
    static func signedInAs(_ account: GatewayAccount?) -> String {
        guard let account else { return "—" }
        if account.kind == .nous { return GatewayNaming.accountName(account) }
        return account.username?.isEmpty == false ? account.username! : "—"
    }

    static func status(_ connection: ConnectionState) -> String {
        switch connection {
        case .connecting: return "Connecting…"
        case .ready: return "Connected"
        case .reconnecting: return "Reconnecting…"
        case .offline: return "Offline"
        case .signedOut: return "Signed Out"   // as the field, the status line and Settings say it
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Gateway", value: account?.label ?? "—")
                    if let url = account?.baseURL {
                        LabeledContent("Address") {
                            Text(url.absoluteString).lineLimit(2).multilineTextAlignment(.trailing).textSelection(.enabled)
                        }
                    }
                    LabeledContent("Signed in as", value: Self.signedInAs(account))
                    LabeledContent("Status", value: Self.status(connection))
                }
                .hqSheetRows()
                Section {
                    Button("Sign Out", role: .destructive) {
                        (confirmTitle, confirmMessage) = actions.signOutWords()
                        confirming = true
                    }
                }
                .hqSheetRows()
            }
            .hqGroupedPage()   // [desktoplook] the page follows the skin
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SheetCloseToolbar(word: "Done", id: "account.done", speaksWord: false) { actions.done() } }   // [mac] Mac polish #123
            .confirmationDialog(confirmTitle, isPresented: $confirming, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) { actions.signOut() }
            } message: {
                Text(confirmMessage)
            }
        }
    }
}
