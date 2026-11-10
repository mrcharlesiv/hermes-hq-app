// desktoplook: "Hermes HQ Themes for Desktop" (spec 3x-desktoplook §10). The phone writes one file, the owner's own
// desktop theme plugin, into the gateway computer's Hermes folder through two REST calls; the desktop app loads it by
// itself. Installing never switches the desktop's theme.

import CryptoKit
import Foundation

nonisolated enum DesktopThemeInstall {
    /// Constants, never taken from input (HermesNative.swift:2370).
    static let folder = "~/.hermes/desktop-plugins/hermes-hq-theme"
    static let file = "~/.hermes/desktop-plugins/hermes-hq-theme/plugin.js"
    static let link = "https://github.com/mrcharlesiv/hermes-hq/tree/main/desktop-plugin/hermes-hq-theme"
    /// The bundled copy of `desktop-plugin/hermes-hq-theme/plugin.js` (the whole-app look, 2026-10-19).
    static let sha256 = "41c31d701da1415a9bfe0c84fa725526d63499b484bab7aea74258b8bcbb68ca"
    /// The web's native limit for the file (HermesNative.swift:2366).
    static let maxBytes = 256 * 1024
    static let timeout: TimeInterval = 15

    static let mkdirPath = "/api/files/mkdir"
    static let writePath = "/api/fs/write-text"

    static func mkdirBody() -> Data {
        (try? JSONSerialization.data(withJSONObject: ["path": folder])) ?? Data()
    }

    static func writeBody(_ content: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["path": file, "content": content])) ?? Data()
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The plugin's text, read only when Add is tapped. nil when the app's own copy is missing, empty or too large:
    /// the page then shows no Add button (never a button that cannot work).
    static func bundledText(in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "hermes-hq-theme", withExtension: "js"),
              let data = try? Data(contentsOf: url), !data.isEmpty, data.count <= maxBytes,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    /// A 200 whose body is not Hermes's own answer (a proxy's or a captive network's page, an empty body, an error
    /// object). Stress round 2: such a body read as "Added" though nothing was written.
    static let notHermes = -1

    /// The status the page goes by. Both routes answer `{"ok": true, …}` (hermes_cli/web_routers/files.py:637, 852):
    /// a 200 counts only when its body is a JSON object that does not say otherwise.
    /// DECISION: stricter than the web (desktop-theme-install.ts takes any 200), so "Added" is never shown for a
    /// page that some other machine answered with. `ok` may be absent (an older Hermes), never false.
    static func status(_ http: Int, body: Data?) -> Int {
        guard http == 200 else { return http }
        guard let body, let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return notHermes }
        if let ok = object["ok"] as? Bool, !ok { return notHermes }
        if object["error"] != nil || object["detail"] != nil { return notHermes }
        return 200
    }

    /// One REST call with the target computer's own sign-in: the status from `status(_:body:)`, 0 when there was no answer.
    typealias Call = @Sendable (_ path: String, _ body: Data) async -> Int

    /// mkdir, then write-text only if mkdir answered 200. nil = installed; otherwise the failing request's status.
    static func install(content: String, call: Call) async -> Int? {
        let made = await call(mkdirPath, mkdirBody())
        guard made == 200 else { return made }
        let written = await call(writePath, writeBody(content))
        return written == 200 ? nil : written
    }

    /// Failure words by status (desktop-theme-install.ts:19-24).
    static func failureWords(_ status: Int) -> String {
        switch status {
        // Mac UX stress test #60: the Hermes host has one name; "this" is only ever the device the app runs on.
        case notHermes: "Something answered, but it wasn’t Hermes. Check the address of \(HostWord.phrase) in Settings › Gateway, then try again."
        case 0: "\(HostWord.sentence) didn’t answer. Check that it’s on and connected, then try again."
        case 401, 403: "This \(DeviceWord.name) isn’t signed in to Hermes anymore. Sign in again in Settings › Gateway."
        case 404: "This Hermes is too old to take files from the \(DeviceWord.name). Update Hermes on \(HostWord.updateTarget), then try again."
        default: "Its Hermes refused the file (HTTP \(status))."
        }
    }

    static let addedNote = "Added. In the desktop app, open Settings › Appearance › Theme and pick Hermes HQ or Nous High Contrast."
    // UX study #60: one short sentence each; the install steps show once the link is copied, or with the link if copying fails.
    static let elsewhereNote = "Hermes app on another computer? Copy the link to add the themes there."
    static let copiedNote = "Copied. In that Hermes app’s Settings, open Plugins › Manage plugins › Install from Git and paste the link."
    static let copyFailedNote = "Couldn’t copy. The link is \(link). In that Hermes app’s Settings, open Plugins › Manage plugins › Install from Git and paste it."

    /// `targets[0].title` is the computer's name on this phone (its address only when it has no name).
    static func description(targets: [GatewayAccountRow]) -> String {
        let place = targets.count == 1 ? " on \(targets[0].title)" : ""
        return "Adds two themes to the Hermes desktop app\(place): Hermes HQ, this app’s look, and Nous High Contrast."
    }

    /// Saved computers this phone is signed in to: the one in use first, then the saved order
    /// (desktop-theme-row.tsx:86-90).
    static func targets(_ rows: [GatewayAccountRow]) -> [GatewayAccountRow] {
        let signedIn = rows.filter(\.hasSession)
        return signedIn.filter(\.isCurrent) + signedIn.filter { !$0.isCurrent }
    }
}
