// [preview-vault] 1Password & Hermes Vault autofill for the collaborative In-App Browser (matches Hermes Desktop's
// `preview-vault.ts` + `preview-vault-picker.tsx` and backend `tools/browser_vault_preview.py` + `vault.preview.fill`).
//
// Security contract:
// - The app NEVER sees, stores, or logs resolved passwords.
// - On a pick, the browser pins ONE live `(tab, documentGeneration)` under an opaque random UUID (`target`), calls
//   `vault.preview.fill`, and only evaluates backend-generated fill scripts while that exact document is still loaded
//   (any navigation, reload, or tab close increments `documentGeneration` and immediately invalidates the binding).
// - Exception text from `evaluateJavaScript` is discarded and replaced with fixed text so script/secret content can
//   never leak into logs or responses.

import Foundation
import SwiftUI
import UIKit
import WebKit

/// Strict origin normalization (`https://Example.com:443/login` → `https://example.com`).
/// Returns nil for non-HTTP(S) schemes (same rule as Hermes Desktop's `pageOrigin`).
nonisolated enum PreviewVaultOrigin {
    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let formattedHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        if let port = url.port {
            let isDefault = (scheme == "http" && port == 80) || (scheme == "https" && port == 443)
            return isDefault ? "\(scheme)://\(formattedHost)" : "\(scheme)://\(formattedHost):\(port)"
        }
        return "\(scheme)://\(formattedHost)"
    }

    static func origin(of raw: String) -> String? {
        guard let url = URL(string: raw) else { return nil }
        return origin(of: url)
    }
}

/// One saved login returned by `vault.list` (metadata only — never a password).
nonisolated struct PreviewVaultLogin: Identifiable, Sendable, Equatable {
    var id: String
    var kind: String
    var label: String
    var identifier: String?
    var origin: String?
    var allowedOrigins: [String]
    var backend: String

    init(id: String, kind: String = "login", label: String, identifier: String? = nil,
         origin: String? = nil, allowedOrigins: [String] = [], backend: String = "vault") {
        self.id = id
        self.kind = kind
        self.label = label
        self.identifier = identifier
        self.origin = origin
        self.allowedOrigins = allowedOrigins
        self.backend = backend
    }

    init?(_ value: JSONValue) {
        guard let id = value["id"]?.string, !id.isEmpty else { return nil }
        self.id = id
        self.kind = value["kind"]?.string ?? "login"
        self.label = value["label"]?.string ?? id
        self.identifier = RosterText.trimmed(value["identifier"])
        self.origin = RosterText.trimmed(value["origin"])
        self.allowedOrigins = value["allowed_origins"]?.array?.compactMap(\.string) ?? []
        self.backend = value["backend"]?.string ?? "vault"
    }

    var backendDisplayName: String {
        switch backend.lowercased() {
        case "1password", "onepassword", "op": return "1Password"
        case "bitwarden", "bw": return "Bitwarden"
        case "keychain", "apple": return "Keychain"
        case "browser", "chrome": return "Chrome"
        case "vault", "hermes", "local", "": return "Hermes Vault"
        default: return ConfigText.pretty(backend)
        }
    }

    /// Exact origin match (no parent-domain or wildcard match, matching Hermes Desktop & backend fill guard).
    static func matching(_ items: [PreviewVaultLogin], origin: String) -> [PreviewVaultLogin] {
        items.filter { item in
            item.kind == "login" && (item.origin == origin || item.allowedOrigins.contains(origin))
        }
    }
}

/// Result of a single `vault.preview.fill` RPC.
nonisolated struct PreviewVaultFillResult: Sendable, Equatable {
    var success: Bool
    var filledFields: Int
    var error: String?
    var errorType: String?

    init(success: Bool, filledFields: Int = 0, error: String? = nil, errorType: String? = nil) {
        self.success = success
        self.filledFields = filledFields
        self.error = error
        self.errorType = errorType
    }

    init(_ value: JSONValue) {
        self.success = value["success"]?.bool == true
        self.filledFields = value["filled_fields"]?.int ?? 0
        self.error = value["error"]?.string
        self.errorType = value["error_type"]?.string
    }
}

/// Snapshot loaded when the user clicks the 🔑 Key button in the browser bar.
struct PreviewVaultMenuState {
    var origin: String
    var logins: [PreviewVaultLogin]
    var lockedSources: [VaultSource]
    var onePasswordConnected: Bool
    var onePasswordInstalled: Bool
    var loadError: String?
}

// MARK: - Short-lived document bindings (`preview.act` with `action == "vault"`)

/// Minimal document handle a vault binding pins to. `PreviewTabController.BrowserTab` adopts it; tests can provide a stub.
@MainActor protocol PreviewVaultDocument: AnyObject {
    var documentGeneration: Int { get }
    var isLiveForVault: Bool { get }
    func evaluateVaultExpression(_ expression: String) async throws -> Any?
}

@MainActor final class PreviewVaultBindings {
    enum EvalOutcome {
        case decline
        case success(Any?)
        case failure(String)
    }

    private struct Binding {
        weak var document: (any PreviewVaultDocument)?
        let generation: Int
        let sessionId: String   // empty = user binding (matched by random UUID target alone)
        let isUser: Bool
        let expiresAt: Date
    }

    static let maxBindings = 16
    static let agentTTL: TimeInterval = 5 * 60
    static let userTTL: TimeInterval = 60

    static let noPageError = "No live preview page is available."
    static let changedError = "The selected preview page changed. Open a new target."
    static let pageFailedError = "The preview page could not complete the vault action."

    private var bindings: [String: Binding] = [:]
    private var order: [String] = []
    var now: () -> Date = Date.init

    /// User path: pin the exact document of the tab whose 🔑 button was clicked.
    func openUserBinding(document: any PreviewVaultDocument) -> String? {
        guard document.isLiveForVault else { return nil }
        return pin(document: document, sessionId: "", isUser: true, ttl: Self.userTTL)
    }

    /// Agent path (`browser_vault` target=preview): pin the active tab of the requesting session.
    func openAgentBinding(sessionId: String, document: (any PreviewVaultDocument)?) -> String? {
        guard !sessionId.isEmpty, let document, document.isLiveForVault else { return nil }
        return pin(document: document, sessionId: sessionId, isUser: false, ttl: Self.agentTTL)
    }

    private func pin(document: any PreviewVaultDocument, sessionId: String, isUser: Bool, ttl: TimeInterval) -> String {
        prune(makeRoom: true)
        let target = UUID().uuidString.lowercased()
        bindings[target] = Binding(document: document, generation: document.documentGeneration,
                                   sessionId: sessionId, isUser: isUser, expiresAt: now().addingTimeInterval(ttl))
        order.append(target)
        return target
    }

    private func prune(makeRoom: Bool = false) {
        let current = now()
        order.removeAll { key in
            guard let b = bindings[key], b.expiresAt > current else {
                bindings.removeValue(forKey: key)
                return true
            }
            return false
        }
        while makeRoom && bindings.count >= Self.maxBindings, let oldest = order.first {
            order.removeFirst()
            bindings.removeValue(forKey: oldest)
        }
    }

    private func owns(_ binding: Binding, sessionId: String) -> Bool {
        if binding.isUser { return sessionId.isEmpty }
        return !sessionId.isEmpty && binding.sessionId == sessionId
    }

    private func stillPinned(_ binding: Binding, activeDocument: (any PreviewVaultDocument)?) -> Bool {
        guard let doc = binding.document, doc.isLiveForVault, doc.documentGeneration == binding.generation else { return false }
        if binding.isUser { return true }
        return activeDocument === doc
    }

    /// Evaluate backend-generated fill JS only while the exact pinned document is still live.
    func evaluate(target: String, sessionId: String, expression: String,
                  activeDocument: (any PreviewVaultDocument)?) async -> EvalOutcome {
        prune()
        guard let binding = bindings[target], owns(binding, sessionId: sessionId) else {
            return .decline
        }
        guard stillPinned(binding, activeDocument: activeDocument), let doc = binding.document else {
            return .failure(Self.changedError)
        }
        do {
            let result = try await doc.evaluateVaultExpression(expression)
            guard stillPinned(binding, activeDocument: activeDocument) else {
                return .failure(Self.changedError)
            }
            return .success(result)
        } catch {
            // Never return or log JS error details: they can echo the injected fill script & password.
            return .failure(Self.pageFailedError)
        }
    }

    /// Release a binding after `vault.preview.fill` or `browser_vault` finishes. Returns false if unknown (decline).
    func close(target: String, sessionId: String) -> Bool {
        guard let binding = bindings[target], owns(binding, sessionId: sessionId) else { return false }
        forget(target: target)
        return true
    }

    /// Drop a user binding unconditionally on cleanup.
    func forget(target: String) {
        bindings.removeValue(forKey: target)
        order.removeAll { $0 == target }
    }

    /// Handle a `preview.act` request where `params["action"] == "vault"`.
    /// Returns nil when this window does not own `target` (caller declines with 4404).
    func handleAct(sessionId: String, params: JSONValue,
                   activeDocument: (any PreviewVaultDocument)?,
                   onActivity: ((String) -> Void)? = nil) async -> String? {
        let vault = params["vault"]?.object ?? [:]
        let operation = (vault["operation"]?.string ?? "").lowercased()
        let target = vault["target"]?.string ?? ""
        let expression = vault["expression"]?.string ?? ""

        switch operation {
        case "open":
            guard let minted = openAgentBinding(sessionId: sessionId, document: activeDocument) else {
                return PreviewActEngine.encode(["success": false, "error": Self.noPageError])
            }
            onActivity?("Filling saved login…")
            return PreviewActEngine.encode(["success": true, "target": minted])

        case "evaluate":
            switch await evaluate(target: target, sessionId: sessionId, expression: expression, activeDocument: activeDocument) {
            case .decline:
                return nil
            case .failure(let message):
                return PreviewActEngine.encode(["success": false, "error": message])
            case .success(let value):
                var out: [String: Any] = ["success": true]
                if let value, !(value is NSNull), JSONSerialization.isValidJSONObject(["v": value]) {
                    out["result"] = value
                } else if let str = value as? String {
                    out["result"] = str
                } else if let num = value as? NSNumber {
                    out["result"] = num
                } else {
                    out["result"] = NSNull()
                }
                return PreviewActEngine.encode(out)
            }

        case "close":
            guard close(target: target, sessionId: sessionId) else { return nil }
            return PreviewActEngine.encode(["success": true])

        default:
            return PreviewActEngine.encode(["success": false, "error": "The preview vault operation is invalid."])
        }
    }
}

// MARK: - Gateway Vault RPC Client

@MainActor final class PreviewVaultService {
    private let client: any GatewayClient

    init(client: any GatewayClient) {
        self.client = client
    }

    private func scoped(_ base: [String: JSONValue], profile: String?) -> JSONValue {
        var params = base
        if let profile, !profile.isEmpty, profile != "default" {
            params["profile"] = .string(profile)
        }
        return .object(params)
    }

    func load(origin: String, profile: String?) async -> PreviewVaultMenuState {
        async let listCall: JSONValue? = try? client.call("vault.list", scoped([:], profile: profile), timeout: .seconds(30))
        async let sourcesCall: JSONValue? = try? client.call("vault.sources", scoped([:], profile: profile), timeout: .seconds(15))
        async let opStatus = OnePasswordAllowModel.status()

        let (listValue, sourcesValue, onePassword) = await (listCall, sourcesCall, opStatus)
        if listValue == nil && sourcesValue == nil {
            return PreviewVaultMenuState(
                origin: origin,
                logins: [],
                lockedSources: [],
                onePasswordConnected: onePassword.connected,
                onePasswordInstalled: onePassword.supported,
                loadError: "Couldn’t reach your gateway’s vault."
            )
        }
        let allItems = (listValue?["items"]?.array ?? []).compactMap(PreviewVaultLogin.init)
        let matching = PreviewVaultLogin.matching(allItems, origin: origin)
        let allSources = (sourcesValue?["sources"]?.array ?? []).compactMap(VaultSource.init)
        let locked = allSources.filter { $0.needsUnlock && $0.enabled && $0.installed && !$0.unlocked }
        let opSource = allSources.first { $0.id == OnePasswordAllowWire.backend }
        let opConnected = onePassword.connected || (opSource?.enabled == true && opSource?.unlocked == true)
        let opInstalled = onePassword.supported || (opSource?.installed == true)

        return PreviewVaultMenuState(
            origin: origin,
            logins: matching,
            lockedSources: locked,
            onePasswordConnected: opConnected,
            onePasswordInstalled: opInstalled,
            loadError: nil
        )
    }

    func fill(login: PreviewVaultLogin, document: any PreviewVaultDocument,
              bindings: PreviewVaultBindings, profile: String?) async -> PreviewVaultFillResult {
        guard let target = bindings.openUserBinding(document: document) else {
            return PreviewVaultFillResult(success: false, error: "Page isn’t ready to fill yet.")
        }
        defer { bindings.forget(target: target) }
        do {
            let params = scoped(["handle": .string(login.id), "target": .string(target)], profile: profile)
            let answer = try await client.call("vault.preview.fill", params, timeout: .seconds(35))
            return PreviewVaultFillResult(answer)
        } catch {
            return PreviewVaultFillResult(success: false, error: (error as? LocalizedError)?.errorDescription ?? "Couldn’t fill this login.")
        }
    }

    func unlock(source: VaultSource, password: String, profile: String?) async -> (ok: Bool, error: String?) {
        do {
            let params = scoped(["source": .string(source.id), "password": .string(password)], profile: profile)
            let answer = try await client.call("vault.unlock", params, timeout: .seconds(20))
            if answer["ok"]?.bool == false || answer["success"]?.bool == false {
                return (false, answer["error"]?.string ?? "Couldn’t unlock \(source.name).")
            }
            return (true, nil)
        } catch {
            return (false, (error as? LocalizedError)?.errorDescription ?? "Couldn’t unlock \(source.name).")
        }
    }
}
