// [share] Why a share stopped, in the words the sheet shows (docs/spec/3x-share.md §7.8). The sentences are build
// 240's, verbatim (DispatchShareKit.swift:332-368), with the literal name "Hermes HQ" (spec D8), except a gateway error, which no
// longer shows its HTTP status (D8 amendment).

import Foundation

nonisolated enum ShareFailure: Error, Equatable, Sendable {
    case signedOut, needsApp, noRoster, sessionEnded, otherAccount, locked, keychain(Int)
    case tailscaleOff, noChat, tooLarge(String), unreadable(String), nothingToSend
    case refused(String), gateway(Int), transport(String, Int), timedOut, cancelled
    /// prompt.submit went out and its answer never came. The bot may already have the share and the gateway has no
    /// idempotency key, so this is never a plain Try Again.
    case unconfirmed

    /// The device in two of the sentences: "iPhone" (build 240's word), "iPad" in the universal build on an iPad, "Mac"
    /// on the Mac. Audit 09-24. Set once by the extension (ShareViewController) before any sheet shows; DeviceWord isn't
    /// in that target.
    nonisolated(unsafe) static var device = "iPhone"

    var message: String {
        let device = Self.device
        switch self {
        case .signedOut: return "Open Hermes HQ and sign in to your gateway, then share again."
        case .needsApp: return "Open Hermes HQ once to finish updating, then share again."
        case .noRoster: return "Open Hermes HQ once so your bots appear here, then share again."
        case .sessionEnded: return "Your gateway ended this \(device)’s session. Open Hermes HQ to sign in again."
        case .otherAccount: return "Hermes HQ switched gateways. Open Hermes HQ so your bots appear here, then share again."
        case .locked: return "Unlock your \(device) to share."
        case .keychain: return "Hermes HQ couldn’t read your sign-in. Open Hermes HQ, then share again."
        case .tailscaleOff: return "Turn on Tailscale to reach the computer running Hermes."   // UX study #24: HostWord.phrase (not in this target)
        case .noChat: return "Open this bot in Hermes HQ once, then share to it."
        case .tooLarge(let name): return "“\(name)” is larger than your attachment limit."
        case .unreadable(let name): return "Hermes HQ couldn’t read “\(name)”."
        case .nothingToSend: return "There’s nothing to send."
        case .refused(let detail): return detail.isEmpty ? "Your gateway didn’t accept this share." : detail
        case .gateway(let status):
            return status == 429 ? "Your gateway is busy. Try again in a minute." : "Your gateway had a problem with this share. Try again in a minute."
        case .transport(let domain, let code): return ShareReach.failureMessage(domain: domain, code: code)
        case .timedOut: return "Your gateway took too long to answer. It may be busy — try again."
        case .cancelled: return "Sending was cancelled."
        case .unconfirmed: return "Hermes HQ couldn’t confirm the share arrived. Check the chat before sending again."
        }
    }

    /// Worth a Try Again (the same share may go through later); the rest need the app or a change first.
    var retryable: Bool {
        switch self {
        case .tailscaleOff, .gateway, .transport, .timedOut, .locked: return true
        default: return false
        }
    }

    /// Replaces the whole sheet ("Can’t Share Yet"): nothing here can fix it, the app can.
    var blocksSheet: Bool {
        switch self {
        case .signedOut, .needsApp, .noRoster, .sessionEnded, .otherAccount: return true
        default: return false
        }
    }

    /// The case without its payload: the name `debug.json` uses (spec D14), and what a log may carry.
    var name: String {
        switch self {
        case .signedOut: return "signedOut"
        case .needsApp: return "needsApp"
        case .noRoster: return "noRoster"
        case .sessionEnded: return "sessionEnded"
        case .otherAccount: return "otherAccount"
        case .locked: return "locked"
        case .keychain: return "keychain"
        case .tailscaleOff: return "tailscaleOff"
        case .noChat: return "noChat"
        case .tooLarge: return "tooLarge"
        case .unreadable: return "unreadable"
        case .nothingToSend: return "nothingToSend"
        case .refused: return "refused"
        case .gateway: return "gateway"
        case .transport: return "transport"
        case .timedOut: return "timedOut"
        case .cancelled: return "cancelled"
        case .unconfirmed: return "unconfirmed"
        }
    }

    /// A failure by its case name, with stand-in payloads (DEBUG screenshots of states the simulator cannot reach).
    static func named(_ name: String) -> ShareFailure? {
        switch name {
        case "signedOut": return .signedOut
        case "needsApp": return .needsApp
        case "noRoster": return .noRoster
        case "sessionEnded": return .sessionEnded
        case "otherAccount": return .otherAccount
        case "locked": return .locked
        case "keychain": return .keychain(-25291)
        case "tailscaleOff": return .tailscaleOff
        case "noChat": return .noChat
        case "tooLarge": return .tooLarge("big.bin")
        case "unreadable": return .unreadable("broken.mov")
        case "nothingToSend": return .nothingToSend
        case "refused": return .refused("")
        case "gateway": return .gateway(500)
        case "transport": return .transport(NSURLErrorDomain, NSURLErrorCannotConnectToHost)
        case "timedOut": return .timedOut
        case "unconfirmed": return .unconfirmed
        default: return nil
        }
    }

    /// A gateway's JSON-RPC refusal in the sheet's words: never a stack trace, at most one short line of the gateway's.
    static func rpcCopy(code: Int, message: String) -> String {
        switch code {
        case 4001: return "Your gateway couldn’t find this bot’s chat. Open it in Hermes HQ, then share again."
        case 4009: return "This bot is busy. Try again in a moment."
        default:
            let line = message.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            return line.isEmpty || line.count > 160 ? "Your gateway didn’t accept this share." : "Your gateway said: " + line
        }
    }

    /// A URLSession (or socket) error as a failure: cancelled, timed out, or the transport's own domain and code.
    ///
    /// "Cancelled" is the person's own Cancel and nothing else. URLSession also reports a connection the SYSTEM dropped
    /// (the network changed, the session was torn down) as NSURLErrorCancelled; with nobody having pressed Cancel that
    /// is a transport failure with its own sentence and Try Again ("The connection changed before your gateway
    /// answered."), and during prompt.submit it is "not confirmed" like any other lost answer. The person's Cancel is
    /// always seen first: it cancels the sending task (checked here) and closes the socket with `.cancelled` recorded
    /// before the connection is torn down (`ShareSocket.close`).
    static func transport(_ error: Error) -> ShareFailure {
        if let failure = error as? ShareFailure { return failure }
        if error is CancellationError { return .cancelled }
        let failure = error as NSError
        if failure.domain == NSURLErrorDomain, failure.code == NSURLErrorCancelled, Task.isCancelled { return .cancelled }
        if failure.domain == NSURLErrorDomain, failure.code == NSURLErrorTimedOut { return .timedOut }
        return .transport(failure.domain, failure.code)
    }
}
