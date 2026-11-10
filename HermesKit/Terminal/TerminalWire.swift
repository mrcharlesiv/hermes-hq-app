// [terminal] The Terminal page's socket (docs/spec/terminal.md): hermes-hq-push 0.9.25's
// `/api/plugins/hermes-hq-push/terminal?ticket=…&session=<32 hex>&cols=&rows=&since=`, one socket per open page.
// Computer → app: binary frames are what the shell printed, in order; text frames are JSON: `ready` first (the bytes
// after it start at byte `offset` of everything that shell printed), `exit` when the shell ends, `ping` after 20 s of
// quiet. App → computer: binary frames are keys and pastes as typed; text frames `resize`, `end` and `ping`.
// A shell outlives its socket for 15 minutes, so the page dials again with `since` (the bytes it has shown) and gets
// only what it missed. Each phone keeps its own session id per computer, so two devices never take each other's shell.

import Foundation

nonisolated enum TerminalWire {
    static let path = PushPolicy.route + "/terminal"
    /// The add-on sends frames of at most 64 KB; room for a burst of them and the JSON.
    static let maxMessage = 4 << 20

    /// `wss://<gateway>/api/plugins/hermes-hq-push/terminal?…&ticket=…`, nil for a gateway address that isn't http(s).
    static func socketURL(base: URL, query: [URLQueryItem], ticket: String) -> URL? {
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        switch parts.scheme?.lowercased() {
        case "https": parts.scheme = "wss"
        case "http": parts.scheme = "ws"
        default: return nil
        }
        let prefix = parts.path.hasSuffix("/") ? String(parts.path.dropLast()) : parts.path
        parts.path = prefix + path
        parts.user = nil
        parts.password = nil
        parts.fragment = nil
        parts.queryItems = query.filter { $0.name != "ticket" && $0.name != "token" } + [URLQueryItem(name: "ticket", value: ticket)]
        return parts.url
    }

    static func query(session: String, cols: Int, rows: Int, since: Int) -> [URLQueryItem] {
        [URLQueryItem(name: "session", value: session), URLQueryItem(name: "cols", value: String(cols)),
         URLQueryItem(name: "rows", value: String(rows)), URLQueryItem(name: "since", value: String(since))]
    }

    /// A new shell's name: 32 lowercase hex characters, as the add-on checks.
    static func newSession() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func isSession(_ text: String) -> Bool {
        text.count == 32 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    // MARK: Text frames

    enum Message: Equatable, Sendable {
        case ready(offset: Int, shell: String, resumed: Bool)
        case exit(code: Int?)
        case ping
        case pong
        case other
    }

    static func parse(_ text: String) -> Message {
        guard let data = text.data(using: .utf8),
              let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .other }
        switch body["type"] as? String {
        case "ready":
            return .ready(offset: (body["offset"] as? NSNumber)?.intValue ?? 0, shell: body["shell"] as? String ?? "",
                          resumed: (body["resumed"] as? NSNumber)?.boolValue ?? false)
        case "exit":
            return .exit(code: (body["code"] as? NSNumber)?.intValue)
        case "ping": return .ping
        case "pong": return .pong
        default: return .other
        }
    }

    static func resize(cols: Int, rows: Int) -> String { #"{"type":"resize","cols":\#(cols),"rows":\#(rows)}"# }
    static let end = #"{"type":"end"}"#
    static let ping = #"{"type":"ping"}"#

    // MARK: How a socket ended

    /// What the page does after its socket closed with `code` (nil: no close frame, the link dropped).
    enum Ending: Equatable, Sendable {
        /// The link dropped: dial again.
        case retry
        /// The shell ended (its `exit` came first).
        case ended
        /// Opened again from this device (another page took the shell): don't dial back.
        case replaced
        /// plugin-data's terminal.off on the computer.
        case off
        /// No terminal on that computer (Windows without Hermes's pywinpty, or no Python to start a shell with).
        case unsupported
        /// Eight shells are open there already.
        case full
        /// The shell couldn't start, or the add-on refused the request: its reason.
        case refused(String)
        /// Something on the way answered the socket 404 though the add-on has the Terminal: a Hermes HQ edge from
        /// before it let /terminal through (or another relay that only passes the sockets it knows).
        case blocked
        /// The first dial never reached the shell after `TerminalConnection.giveUpAfter` tries.
        case unreachable
    }

    static func ending(code: Int?, reason: String?, refused status: Int? = nil) -> Ending {
        if code == nil, status == 404 { return .blocked }
        return switch code {
        case 1000: .ended
        case 4409: .replaced
        case 4403: .off
        case 4501: .unsupported
        case 4429: .full
        case 4400, 4500: .refused(reason?.isEmpty == false ? reason! : "The computer refused the terminal.")
        default: .retry
        }
    }
}
