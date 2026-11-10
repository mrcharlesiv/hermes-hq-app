// [nous-sign-in] Sign Hermes on the computer in to Nous from the phone, so managed apps can show (owner 2026-10-15:
// "Shouldn't we have that button in our app?"). The same device-code sign-in the desktop starts
// (`startOAuthLogin('nous')`, apps/desktop/src/api/config.ts): `POST /api/providers/oauth/nous/start` gives a code and a
// Nous page, the person approves there, `GET /api/providers/oauth/nous/poll/<session>` turns "approved", and Hermes
// saves the account itself. `GET /api/providers/oauth` says whether it is signed in already. Nothing is kept here.

import Observation
import SwiftUI
import UIKit

@MainActor @Observable
final class NousAccountModel {
    enum State: Equatable {
        case unknown          // not read yet, or the gateway has no provider list
        case signedOut
        case signedIn
        case starting
        case waiting(code: String)
        case failed(String)
    }

    var state = State.unknown
    /// A read has finished (either way). Until then `.unknown` only means not read yet, so the section keeps its slot.
    private(set) var didRead = false
    /// The managed section's last read (`profile|unavailable`): the box it draws after moving slots doesn't read again.
    @ObservationIgnored var readKey: String?
    /// Called when the sign-in finished: the managed apps read again.
    @ObservationIgnored var onSignedIn: (() -> Void)?
    @ObservationIgnored weak var presenter: UIViewController?
    @ObservationIgnored private let client: any GatewayClient
    @ObservationIgnored private var browser: (any NousBrowser)?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var session: String?
    @ObservationIgnored private var profile = "default"

    init(client: any GatewayClient) { self.client = client }

    private func query(_ profile: String) -> [URLQueryItem] { [URLQueryItem(name: "profile", value: profile)] }

    /// Reads whether Hermes on the computer is signed in to Nous (for this bot's profile).
    func refresh(profile: String) async {
        self.profile = profile
        if case .waiting = state { return }
        if state == .starting { return }
        guard let data = try? await client.rest("GET", "/api/providers/oauth", query: query(profile), body: nil),
              let value = try? JSONValue.parse(data),
              let row = (value["providers"]?.array ?? []).compactMap(OAuthProviderRow.init).first(where: { $0.id == "nous" }) else {
            if state != .signedIn { state = .unknown }
            didRead = true
            return
        }
        state = row.connected ? .signedIn : .signedOut
        didRead = true
    }

    func start() {
        guard polling == nil else { return }
        Haptics.play(.light)
        state = .starting
        let profile = self.profile
        polling = Task { [weak self] in
            guard let self else { return }
            defer { self.polling = nil }
            do {
                let raw = try await client.rest("POST", "/api/providers/oauth/nous/start", query: query(profile), body: Data("{}".utf8))
                let started = try JSONValue.parse(raw)
                guard let session = RosterText.trimmed(started["session_id"]),
                      let link = RosterText.trimmed(started["verification_url"]), let url = ManagedSignInBrowser.accepts(link) else {
                    throw HTTPError(status: 500, body: #"{"detail":"Hermes didn’t send a sign-in page."}"#)
                }
                self.session = session
                state = .waiting(code: RosterText.text(started["user_code"]))
                open(url)
                let interval = max(2, started["poll_interval"]?.int ?? 5)
                let deadline = Date().addingTimeInterval(TimeInterval(started["expires_in"]?.int ?? 900))
                while !Task.isCancelled, Date() < deadline {
                    try await Task.sleep(for: .seconds(interval))
                    let poll = try JSONValue.parse(try await client.rest("GET", "/api/providers/oauth/nous/poll/\(session)",
                                                                         query: query(profile), body: nil))
                    switch RosterText.trimmed(poll["status"]) ?? "pending" {
                    case "pending": continue
                    case "approved":
                        finish()
                        NousSheetLogin.finished()
                        Haptics.play(.success)
                        state = .signedIn
                        onSignedIn?()
                        return
                    case "denied": throw Failure("The sign-in was turned down on the Nous page.")
                    case "expired": throw Failure("The sign-in timed out. Try again.")
                    default: throw Failure(RosterText.trimmed(poll["error_message"]) ?? "Nous didn’t finish the sign-in. Try again.")
                    }
                }
                if !Task.isCancelled { throw Failure("The sign-in timed out. Try again.") }
            } catch is CancellationError {
            } catch {
                finish()
                Haptics.play(.error)
                state = .failed((error as? Failure)?.words ?? CapabilitiesStore.detail(error))
            }
        }
    }

    /// [nous-different-account] Use Another Nous Account: the Nous page opens private, so Safari's saved login can't
    /// approve for the account it holds.
    func startWithOtherAccount() {
        guard polling == nil else { return }
        NousSheetLogin.chooseAccount()
        start()
    }

    /// The person closed the Nous page: keep listening a little (they may have approved), then stop on Cancel.
    func cancel() {
        polling?.cancel(); polling = nil
        if let session {
            let profile = self.profile
            Task { _ = try? await client.rest("DELETE", "/api/providers/oauth/sessions/\(session)", query: query(profile), body: nil) }
        }
        finish()
        state = .signedOut
    }

    private func open(_ url: URL) {
        let sheet = ManagedSignInBrowser.make(presenter?.view.window, NousSheetLogin.isPrivate)
        browser = sheet
        _ = sheet.open(url) { [weak self] in self?.browser = nil }
    }

    private func finish() {
        browser?.close()
        browser = nil
        session = nil
    }

    private struct Failure: Error { let words: String; init(_ words: String) { self.words = words } }
}

/// The Managed Apps box when the apps can't show: why, and the button that fixes it when it can be fixed here.
struct NousAccountBox: View {
    @Bindable var nous: NousAccountModel
    let botName: String
    let unavailable: Bool
    let readOnly: Bool

    /// The states where the box is only a quiet line, with nothing to tap.
    static func isQuiet(_ state: NousAccountModel.State, unavailable: Bool, read: Bool) -> Bool {
        guard unavailable else { return false }
        switch state {
        case .signedIn: return true
        case .unknown: return read   // before the first read it may yet be a Sign In card: stay in the top slot
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch nous.state {
            // Nothing to do here while Nous hasn't turned the apps on: one quiet line, not a card above the usable rows.
            case .signedIn where unavailable:
                quiet("Nous hasn’t turned on managed apps for your account yet. They appear here once it does.")
            case .waiting(let code):
                words("Approve the sign-in on the Nous page.",
                      code.isEmpty ? "This updates by itself once you’ve approved." : "Check the page shows the code \(code). This updates by itself once you’ve approved.")
                HStack(spacing: 10) {
                    ProgressView()
                    Button("Cancel", role: .cancel) { nous.cancel() }.hqBorderedButtonStyle()
                        .accessibilityIdentifier("nous.cancel")
                }
                .padding(.top, 2)
            case .unknown where unavailable:
                quiet("Managed apps aren’t available for this account yet. Your other connectors are unaffected.")
            case .starting:
                words("Opening Nous…", "")
                ProgressView().padding(.top, 2)
            default:
                words("Sign in to Nous to use managed apps.",
                      "Gmail, Google Calendar, Slack and more connect through a Nous account. This signs \(HostWord.phrase) in to Nous, for \(botName) and your other bots.")
                if case .failed(let reason) = nous.state {
                    Text(reason).font(Font.hq(.subheadline)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("nous.failed")
                }
                if readOnly {
                    Text("This gateway is read-only. Sign in on \(HostWord.phrase).").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                } else {
                    Button { nous.start() } label: {
                        Text("Sign In to Nous").font(Font.hq(.body).weight(.semibold)).frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .hqGlassProminentButtonStyle()
                    .padding(.top, 4)
                    .accessibilityIdentifier("nous.sign-in")
                    NousOtherAccountLink(id: "nous.other-account") { nous.startWithOtherAccount() }
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("managed.nous")
    }

    private func quiet(_ text: String) -> some View {
        // [mac] Stress test 2026-10-28 #52: the quiet line reads as Connectors' second footer, so it takes the
        // footer's size (it was a size bigger than the footer over it).
        // [mac] Stress test 2026-10-28 round 8: on the Text itself. `hqMacFont` after the Text's own font only set the
        // environment's, which a Text with a font ignores, so the line kept the subheadline size.
        Text(text).font(DeviceWord.isMac ? MacType.footnoteFont : Font.hq(.subheadline))
            .foregroundStyle(Color.hqLabel2).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("nous.unavailable")
    }

    @ViewBuilder private func words(_ title: String, _ detail: String) -> some View {
        Text(title).font(Font.hq(.body).weight(.semibold)).foregroundStyle(Color.hqLabel).fixedSize(horizontal: false, vertical: true)
        if !detail.isEmpty {
            Text(detail).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).fixedSize(horizontal: false, vertical: true)
        }
    }
}
