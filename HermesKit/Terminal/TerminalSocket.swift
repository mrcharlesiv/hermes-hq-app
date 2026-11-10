// [terminal] The Terminal page's socket over URLSessionWebSocketTask, behind a protocol so the connection's tests can
// stand in for it. Closing from this side is always a plain cancel: the add-on keeps the shell for the page to come
// back to whatever code a dropped page sends (only the page's `end` message ends a shell).

import Foundation

nonisolated enum TerminalFrame: Sendable, Equatable {
    case binary(Data)
    case text(String)
}

nonisolated protocol TerminalSocketing: AnyObject, Sendable {
    func receive() async throws -> TerminalFrame
    /// Queued in call order (keys must reach the shell in the order typed). A failed send shows up as `receive` failing.
    func send(_ frame: TerminalFrame)
    func close()
    /// The code the computer closed with (nil: no close frame was seen).
    var closeCode: Int? { get }
    var closeReason: String? { get }
    /// The HTTP status the upgrade was answered with when it never became a socket (a relay's 404; nil once open).
    var refusedStatus: Int? { get }
}

/// A client that can open the Terminal socket. `LiveGatewayClient` adopts it.
nonisolated protocol GatewayTerminalSockets: AnyObject, Sendable {
    func terminalSocket(query: [URLQueryItem]) async throws -> any TerminalSocketing
}

nonisolated final class TerminalSocket: TerminalSocketing {
    private let task: URLSessionWebSocketTask
    private let closed = Locked(false)

    /// Takes a task that has not been resumed yet and starts it.
    init(_ task: URLSessionWebSocketTask) {
        self.task = task
        task.maximumMessageSize = TerminalWire.maxMessage
        task.resume()
    }

    deinit { if !closed.value { task.cancel() } }

    func receive() async throws -> TerminalFrame {
        switch try await task.receive() {
        case .data(let data): return .binary(data)
        case .string(let text): return .text(text)
        @unknown default: return .text("")
        }
    }

    func send(_ frame: TerminalFrame) {
        switch frame {
        case .binary(let data): task.send(.data(data)) { _ in }
        case .text(let text): task.send(.string(text)) { _ in }
        }
    }

    func close() {
        guard !closed.mutate({ was -> Bool in defer { was = true }; return was }) else { return }
        task.cancel()
    }

    var closeCode: Int? {
        let code = task.closeCode.rawValue
        return code == 0 ? nil : code
    }

    var closeReason: String? { task.closeReason.flatMap { String(data: $0, encoding: .utf8) } }

    var refusedStatus: Int? {
        guard let status = (task.response as? HTTPURLResponse)?.statusCode, status != 101 else { return nil }
        return status
    }
}
