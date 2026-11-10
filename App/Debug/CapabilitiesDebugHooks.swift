// [capabilities] DEBUG-only hooks for the Capabilities and Connect Apps UI tests (compiled out of Release).
//
// - `-HQDebugResetConnectApps YES`  forget the Composio key and the Connect Apps caches before launch
// - `HQN_CAP_AUTH=allow|deny|close` (environment) answer a connector or Connect Apps sign-in page with URLSession
//                                   instead of the system sign-in sheet (which runs in another process and asks the
//                                   person first). Everything after the page — the loopback relay, the gateway calls,
//                                   the polls, the callback URL — is the app's real code.
// - `HQN_COMPOSIO_BASE=http://127.0.0.1:<port>` the stand-in for Composio (read in HermesKit/Composio/ComposioClient.swift)

#if DEBUG
import UIKit

@MainActor enum CapabilitiesDebugHooks {
    static var auth: String? { ProcessInfo.processInfo.environment["HQN_CAP_AUTH"].flatMap { ["allow", "deny", "close"].contains($0) ? $0 : nil } }

    static func applyBeforeLaunch() {
        if UserDefaults.standard.bool(forKey: "HQDebugResetConnectApps") {
            ComposioKeychain().clear()
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("connectapps.") || key.hasPrefix("capabilities.") {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        guard let auth else { return }
        McpSignIn.makeBrowser = { _ in PageDriver(choice: auth) }
        ManagedSignInBrowser.make = { _, _ in PageDriver(choice: auth) }   // [connectors] a managed app's sign-in link
        ComposioConnect.driver = { link, _ in await PageDriver.composio(link, choice: auth) }
    }

    /// Loads the stand-in's sign-in page with the choice already made; its redirect lands on the app's own listener.
    final class PageDriver: NousBrowser {
        let choice: String
        private var task: Task<Void, Never>?
        init(choice: String) { self.choice = choice }

        func open(_ url: URL, userCancelled: @escaping @MainActor () -> Void) -> Bool {
            guard choice != "close", var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                task = Task { try? await Task.sleep(for: .milliseconds(600)); userCancelled() }
                return true
            }
            parts.queryItems = (parts.queryItems ?? []) + [URLQueryItem(name: "choice", value: choice)]
            guard let target = parts.url else { return false }
            task = Task { _ = try? await URLSession(configuration: .ephemeral).data(from: target) }
            return true
        }

        func close() {}

        /// The Connect link with the choice made: the 302's Location is the callback the sheet would have returned.
        static func composio(_ link: URL, choice: String) async -> URL? {
            guard choice != "close", var parts = URLComponents(url: link, resolvingAgainstBaseURL: false) else {
                try? await Task.sleep(for: .milliseconds(600)); return nil
            }
            parts.queryItems = [URLQueryItem(name: "choice", value: choice)]
            guard let target = parts.url else { return nil }
            let session = URLSession(configuration: .ephemeral, delegate: Stay(), delegateQueue: nil)
            guard let (_, response) = try? await session.data(from: target), let http = response as? HTTPURLResponse,
                  let location = http.value(forHTTPHeaderField: "Location") else { return nil }
            return URL(string: location)
        }
    }

    nonisolated private final class Stay: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
#endif
