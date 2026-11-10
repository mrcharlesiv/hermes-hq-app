// The display socket (docs/spec/3x-screen.md §2.2): `/api/display/ws?display_ticket=…`, binary frames carrying RFB.
// How it is closed matters: a close frame with 1000/1001 hands the lease back to the bot, so this type sends one only
// when asked (`close(handBack: true)`); every other ending is a plain cancel. URLSession then sends a close frame with
// no status (the gateway reads 1005, as it did for the web app's `socket.close()`), which the gateway treats as a
// dropped link and so keeps a person's control. (BrowserSocket sends 1001 from deinit: it must not be reused here.)

import Foundation

nonisolated enum ScreenSocketFrame: Sendable, Equatable {
    case binary(Data)
    case text
}

/// What a screen stream needs from its socket. `ScreenSocket` is the real one; tests use fakes.
nonisolated protocol ScreenSocketing: AnyObject, Sendable {
    func receive() async throws -> ScreenSocketFrame
    func send(_ data: Data) async throws
    /// true when the pong came back in time.
    func ping(timeout: Duration) async -> Bool
    /// `handBack`: a close frame with 1000 (the gateway gives the lease back to the bot). Otherwise never 1000/1001.
    func close(handBack: Bool)
    /// The code the gateway closed with (nil: no close frame was seen).
    var closeCode: Int? { get }
    var closeReason: String? { get }
}

/// A client that can open a bot's display socket. `LiveGatewayClient` adopts it.
nonisolated protocol GatewayDisplaySockets: AnyObject, Sendable {
    /// Dials `path` (which must be `/api/display/ws`) with the single-use `ticket`. Throws without dialling otherwise.
    func displaySocket(path: String, ticket: String) async throws -> any ScreenSocketing
}

nonisolated final class ScreenSocket: ScreenSocketing {
    private let task: URLSessionWebSocketTask
    private let closed = Locked(false)

    /// Takes a task that has not been resumed yet and starts it.
    init(_ task: URLSessionWebSocketTask) {
        self.task = task
        task.maximumMessageSize = ScreenWire.maxMessage
        task.resume()
    }

    deinit { if !closed.value { task.cancel() } }       // never a close frame by accident

    func receive() async throws -> ScreenSocketFrame {
        switch try await task.receive() {
        case .data(let data): return .binary(data)
        case .string: return .text
        @unknown default: return .text
        }
    }

    func send(_ data: Data) async throws { try await task.send(.data(data)) }

    func ping(timeout: Duration) async -> Bool {
        let answered = Locked(false)
        let task = self.task
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let finish: @Sendable (Bool) -> Void = { ok in
                let first = answered.mutate { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if first { continuation.resume(returning: ok) }
            }
            task.sendPing { error in finish(error == nil) }
            Task {
                try? await Task.sleep(for: timeout)
                finish(false)
            }
        }
    }

    func close(handBack: Bool) {
        guard !closed.mutate({ was -> Bool in defer { was = true }; return was }) else { return }
        if handBack { task.cancel(with: .normalClosure, reason: nil) } else { task.cancel() }
    }

    var closeCode: Int? {
        let code = task.closeCode.rawValue
        return code == 0 ? nil : code
    }

    var closeReason: String? { task.closeReason.flatMap { String(data: $0, encoding: .utf8) } }
}
