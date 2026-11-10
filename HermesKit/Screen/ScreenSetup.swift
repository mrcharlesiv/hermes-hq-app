// "Set up with Hermes" (docs/spec/3x-screen.md §5.13): the words, the installer the app carries, and the request the
// bot's own chat receives. The web's `bot-screen-setup.ts` and `bot-screen-setup-view.tsx`. The app never unpacks or
// runs the installer: it is opaque data handed to the owner's own gateway, exactly as the web app handed it over.

import CryptoKit
import Foundation

nonisolated enum ScreenSetupPrompt {
    /// The web's prompt with one sentence reworded (DECISION D26: the gateway stores this text as the message, so it
    /// can be read in the chat later, and the pre-rename product name must never show on screen).
    static let paragraphs: [String] = [
        "Set up live Mac screen sharing for me in Hermes HQ on \(HostWord.phrase) for this chat. Do the setup yourself and verify it; do not send me a list of terminal commands.",
        "The attached hermes-hq-screen-setup source bundle came with Hermes HQ. Verify its SHA-256 against the value below before extracting it to a fresh directory with /usr/bin/ditto -x -k so executable permissions are preserved. Read hermes-hq-screen-setup/SETUP.md and scripts/setup-screen-helper.py, then run the installer by its absolute path with python3 and --control --wait-permissions 60 --json. Run it on the Mac hosting this gateway using an available host execution route; if your terminal runs in Docker or over SSH, verify the host route first and report a missing route as a blocker. If the bundle includes a signed Hermes HQ Screen.app, prefer that app and pass its absolute extracted path with --app so no compiler or signing identity is required on this Mac. The working directory is not assumed to contain the Hermes HQ repository. Use the attached bundle; do not invent a download URL or require a preexisting checkout. If the source attachment is unavailable, explain that exact blocker.",
        "Set up both viewing and remote control. This click authorizes installing the helper and plugin and enabling screen sharing and remote input with --control. Preserve the existing profile access and signing-team restrictions. The Mac's whole console will be visible to gateway users who have access to Screen. Keep its visible Stop sharing control. Ask me only for actions macOS requires me to take locally, such as approving Screen Recording, Accessibility, or an administrator password. Explain both permissions up front in one short checklist: Screen Recording lets me see the Mac; Accessibility lets me move its pointer, click, and type. Do not bypass macOS permissions, weaken signing checks, use ad hoc signing for the installed helper. If this Mac still has the older screen plugin or helper app from before the rename, the installer carries their settings over and removes them so only one helper runs (macOS keeps the existing permissions); if it reports it could not remove the old plugin, run the removal command it reports yourself. If Xcode, a suitable signing identity, or permission is missing, report the precise remaining requirement without claiming success.",
        "While I approve permissions, keep checking with the installer rather than asking me to send a new message after each approval. If macOS requires Quit & Reopen, relaunch only this helper using its existing launcher and check again. After a bounded wait, report the exact outstanding permission with a single next action; never claim it is ready early.",
        "Use the installer's check mode (--check --json --control) and hermes hq-screen doctor to verify the helper signature, plugin compatibility and Screen Recording. If Hermes must restart to load the plugin, use its existing managed service or launcher, preserve its arguments and profile, and make the restart survive this chat's connection closing. Do not kill unmanaged processes or restart unrelated services. After any restart, reconnect and verify the actual gateway answering Hermes HQ: /api/plugins/hermes-hq-screen/health must report installed and enabled, no drift or blocker, and a live helper with ok and tcc.screen true; this bot's display.status must report supported, installed, no missing dependencies or blocker, and This Mac. Start the display normally if the helper is idle. Verify health.control is true and helper.tcc.events is true for Accessibility. Viewing alone does not complete this request. Local setup is verified only after these live checks succeed. A successful build or installer exit alone is insufficient; report a pending restart or permission honestly. Then tell me to open this bot's Screen. Confirm live sharing only after an actual screen frame appears; the health checks alone do not prove the stream works.",
    ]

    static let text = paragraphs.joined(separator: "\n\n")
    /// SHA-256 of `text` (3,953 UTF-8 bytes; UX study #24: "the computer running Hermes", was "the gateway computer"); a unit test holds the text to it.
    static let sha256 = "fb7b7a4dc80eae6c0a0ca41068874f2e22e22d494d9345c3f59009aca11c6107"
    /// What the chat shows for the request.
    static let queueTitle = "Set up live screen sharing on my Mac and verify it."

    /// The message sent: the prompt, then where the gateway put the installer, its hash and the signed helper's path.
    static func message(refText: String, sha256: String, helperAppPath: String?) -> String {
        var out = "\(text)\n\nInstaller source: \(refText)\nSHA-256: \(sha256)"
        if let helperAppPath, !helperAppPath.isEmpty { out += "\nSigned helper inside the bundle: \(helperAppPath)" }
        return out
    }
}

/// Why a setup request did not start. The words are the web's.
nonisolated enum ScreenSetupError: Error, Equatable, Sendable {
    case notConnected
    case chatDidNotOpen
    case chatChanged
    case notReady
    case changedWhilePreparing
    case installer(String?)
    case changedBeforeStart
    case notQueued

    static let alertTitle = "Couldn’t Start Screen Setup"

    var message: String {
        switch self {
        case .notConnected: "This bot’s gateway is no longer connected."
        case .chatDidNotOpen: "Hermes could not open this bot’s chat. Try again."
        case .chatChanged: "The selected chat changed before setup could start."
        case .notReady: "This bot’s chat did not become ready for setup. Try again."
        case .changedWhilePreparing: "The chat connection changed while preparing setup. Try again."
        case .installer(let said): said.flatMap { $0.isEmpty ? nil : $0 } ?? "Hermes could not receive the Mac screen installer. Try again."
        case .changedBeforeStart: "The chat connection changed before setup could start. Try again."
        case .notQueued: "Hermes could not queue the setup request in this chat. Try again."
        }
    }
}

/// The installer source the app ships: the exact bytes public build 240 shipped.
nonisolated struct ScreenSetupBundle: Sendable, Equatable {
    static let filename = "hermes-hq-screen-setup.zip"
    static let resource = "HermesHQScreenSetup"
    static let byteCount = 550_200
    static let expectedSHA256 = "71ff241d0a3e803b8a457a9df5f91c14df48c1f227893d785974837af0c8de09"
    static let helperAppPath = "hermes-hq-screen-setup/Hermes HQ Screen.app"

    var filename: String
    var dataURL: String
    var sha256: String
    var helperAppPath: String

    static func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// The resource's bytes, refused unless they are the bytes that were reviewed (never a silent send without it).
    static func verified(_ data: Data?) throws(ScreenSetupError) -> ScreenSetupBundle {
        guard let data, data.count == byteCount else { throw .installer(nil) }
        let hash = hex(data)
        guard hash == expectedSHA256 else { throw .installer(nil) }
        return ScreenSetupBundle(filename: filename, dataURL: "data:application/zip;base64," + data.base64EncodedString(),
                                 sha256: hash, helperAppPath: helperAppPath)
    }

    /// Reads and checks the installer off the main thread.
    @concurrent static func load(from bundle: Bundle = .main) async throws(ScreenSetupError) -> ScreenSetupBundle {
        let url = bundle.url(forResource: resource, withExtension: "zip")
        return try verified(url.flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) })
    }
}

/// What the gateway answered to `file.attach`.
nonisolated enum ScreenSetupAttach {
    /// The `ref_text` to name in the prompt; throws the gateway's own words when it did not take the file.
    static func refText(_ answer: JSONValue) throws(ScreenSetupError) -> String {
        let ref = answer["ref_text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard answer["attached"]?.bool == true, !ref.isEmpty else { throw .installer(answer["message"]?.string) }
        return answer["ref_text"]?.string ?? ref
    }
}

/// The setup card's words (§5.13), exact.
nonisolated enum ScreenSetupCopy {
    static func heading(controlOnly: Bool) -> String { controlOnly ? "Enable Screen Control" : "Set Up Viewing and Control" }
    static let how = "Hermes will install the helper, enable viewing and control, and check both permissions in one setup. Follow its progress in your bot’s chat."
    static let shares = "This shares your Mac’s entire screen and enables pointer and keyboard control for people with Screen access on your gateway. Approve Screen Recording to view, and Accessibility to click and type, on the Mac when prompted."
    static let update = "Hermes will also check whether your gateway needs an update."
    static let requested = "Setup was requested in your bot’s chat. Hermes will report any permissions or requirements that still need attention."
    static let windows = "Live screen sharing isn’t available on Windows yet. Your bot’s latest screenshots will appear here."
    static let opening = "Opening setup…"

    static func primary(requested: Bool, controlOnly: Bool, working: Bool) -> String {
        if working { return opening }
        if requested { return "Continue with Hermes" }
        return controlOnly ? "Enable Control with Hermes" : "Set Up with Hermes"
    }

    static func check(working: Bool) -> String { working ? "Checking…" : "Check Setup" }
}
