// What the gateway Settings pages (Model, Chat Behavior, Workspace, Safety, Browser, Memory, Advanced, Sessions,
// Providers, Keys, Vault, Billing) need from the app model: the signed-in gateway's shared config store and its API.
// `AppModel` adopts it here; screens reach it with `services as? GatewaySettingsServices`.

import Foundation

@MainActor protocol GatewaySettingsServices: AnyObject {
    /// The gateway in use's config record, shared by every config page (nil while signed out).
    var configStore: GatewayConfigStore? { get }
    var settingsAPI: GatewaySettingsAPI? { get }
    var isReadOnlyGateway: Bool { get }
}

extension AppModel: GatewaySettingsServices {
    var configStore: GatewayConfigStore? { settingsHub.configStore }
    var settingsAPI: GatewaySettingsAPI? { client.map { GatewaySettingsAPI(client: $0) } }
    var isReadOnlyGateway: Bool { readOnlyGateway }
}

/// Gateway settings the app reads before Settings is ever opened, kept per gateway on this phone from the last config
/// read or save: `display.resume_last_session` ("Reopen Last Chat on Launch", default on). Kept in the launch restore's
/// own store (LaunchChatMemory), which reads it synchronously at a cold start.
enum GatewayLaunchPrefs {
    static func resumeLastSession(accountId: String) -> Bool { LaunchChatMemory.shared.resume(account: accountId) }

    static func remember(_ config: JSONValue, accountId: String) {
        LaunchChatMemory.shared.setResume(ConfigCopy.resumeLastSession(config), account: accountId)
    }

    static func forget(accountId: String) { LaunchChatMemory.shared.setResume(true, account: accountId) }
}
