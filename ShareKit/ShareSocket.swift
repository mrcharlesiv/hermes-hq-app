// [share] A gateway socket for a handful of JSON-RPC calls (docs/spec/3x-share.md §6.2 steps 5-10, §6.3).
// Port of build 240's `RPCSocket` (DispatchShareKit.swift:698-820).
//
// Events and server requests (a frame with both `method` and `id`, such as approval.request) are read and dropped:
// the share never answers one, and Hermes re-delivers an open request to the app when it resumes the chat. Ask Bot
// (Shortcuts) listens to them (`listen`) to wait for the reply; it never answers a request either.

import Foundation

/// What `ShareSender` needs from a socket (tests put a stub here).
nonisolated protocol ShareRPC: AnyObject, Sendable {
    func call(_ method: String, _ params: [String: Any], timeout: Double) async throws -> [String: Any]
    /// A call whose answer nobody waits for: its frame is written before this returns, so the next call follows it.
    func notify(_ method: String, _ params: [String: Any])
    func close()
    /// Ask Bot: every event and server request from now on, and `.closed` once when the socket ends.
    func listen(_ handler: @escaping @Sendable (ShareSocketEvent) -> Void)
    /// [authority] `gateway.ready` said `session_authority: true` (a gateway-hosted Hermes): a send names its own
    /// request id and photos go up as bytes (`image.attach_bytes`).
    var sessionAuthority: Bool { get }
}

extension ShareRPC {
    func listen(_ handler: @escaping @Sendable (ShareSocketEvent) -> Void) {}
    var sessionAuthority: Bool { false }
}

/// What the socket heard besides answers (Ask Bot waits on these).
nonisolated enum ShareSocketEvent: Sendable {
    /// `{"method":"event","params":{type, session_id, payload}}`.
    case event(type: String, session: String, payload: ShareJSON)
    /// A server request (approval.request, clarify.request…): the bot waits for the person.
    case request(method: String, session: String)
    case closed
}

nonisolated final class ShareSocket: ShareRPC, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let lock = NSLock()
    private var waiting: [String: CheckedContinuation<ShareJSON, Error>] = [:]
    private var ready: CheckedContinuation<Void, Never>?
    private var sawReady = false
    private var authority = false
    private var failure: Error?
    private var counter = 0
    private var listener: (@Sendable (ShareSocketEvent) -> Void)?

    private init(_ task: URLSessionWebSocketTask) { self.task = task }

    /// Opens the socket and waits up to `readyWait` seconds for the gateway's first frame (`gateway.ready`); a gateway
    /// that never sends it still gets its calls after that.
    static func open(session: URLSession, url: URL, readyWait: Double = 5) async throws -> ShareSocket {
        let task = session.webSocketTask(with: URLRequest(url: url))
        task.maximumMessageSize = ShareReach.maximumMessageSize
        let socket = ShareSocket(task)
        task.resume()
        socket.receive()
        await withTaskCancellationHandler {
            await socket.waitReady(seconds: readyWait)
        } onCancel: {
            socket.close()
        }
        if let failure = socket.currentFailure { throw failure }
        return socket
    }

    private var currentFailure: Error? { lock.withLock { failure } }

    var sessionAuthority: Bool { lock.withLock { authority } }

    private func waitReady(seconds: Double) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if sawReady || failure != nil { lock.unlock(); continuation.resume(); return }
            ready = continuation
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in self?.settleReady() }
        }
    }

    private func settleReady() {
        lock.lock(); let pending = ready; ready = nil; sawReady = true; lock.unlock()
        pending?.resume()
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.fail(ShareFailure.transport(error))
            case .success(let message):
                var text: String?
                switch message {
                case .string(let value): text = value
                case .data(let bytes): text = String(data: bytes, encoding: .utf8)
                @unknown default: break
                }
                if let text { self.handle(text) }
                self.receive()
            }
        }
    }

    private func handle(_ text: String) {
        guard let frame = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return }
        if frame["method"] as? String == "event" {
            let params = frame["params"] as? [String: Any] ?? [:]
            let type = params["type"] as? String ?? ""
            if type == "gateway.ready" {
                // [authority] read before the ready wait ends, so the first call already knows.
                let payload = params["payload"] as? [String: Any] ?? [:]
                lock.withLock { authority = payload["session_authority"] as? Bool == true }
                settleReady()
            }
            heard(.event(type: type, session: params["session_id"] as? String ?? "", payload: ShareJSON(params["payload"] as? [String: Any] ?? [:])))
            return
        }
        // A server request (it has a method): left for the app, never answered.
        if let method = frame["method"] as? String {
            let params = frame["params"] as? [String: Any] ?? [:]
            heard(.request(method: method, session: params["session_id"] as? String ?? ""))
            return
        }
        guard let id = frame["id"] as? String else { return }
        lock.lock(); let continuation = waiting.removeValue(forKey: id); lock.unlock()
        guard let continuation else { return }
        if let error = frame["error"] as? [String: Any] {
            let code = (error["code"] as? NSNumber)?.intValue ?? 0
            let message = error["message"] as? String ?? ""
            continuation.resume(throwing: ShareFailure.refused(ShareFailure.rpcCopy(code: code, message: message)))
        } else {
            continuation.resume(returning: ShareJSON(frame["result"] as? [String: Any] ?? [:]))
        }
    }

    private func fail(_ error: Error) {
        lock.lock()
        if failure == nil { failure = error }
        let pending = waiting; waiting.removeAll()
        let readyWaiter = ready; ready = nil
        let listener = self.listener; self.listener = nil
        lock.unlock()
        readyWaiter?.resume()
        pending.values.forEach { $0.resume(throwing: error) }
        listener?(.closed)
    }

    func listen(_ handler: @escaping @Sendable (ShareSocketEvent) -> Void) {
        lock.lock()
        let closed = failure != nil
        if !closed { listener = handler }
        lock.unlock()
        if closed { handler(.closed) }
    }

    private func heard(_ event: ShareSocketEvent) {
        lock.lock(); let listener = self.listener; lock.unlock()
        listener?(event)
    }

    /// One call and its answer. A cancelled caller closes the socket (every waiter fails as cancelled), so Cancel
    /// never waits on the gateway's answer and nothing is sent after it.
    func call(_ method: String, _ params: [String: Any], timeout: Double) async throws -> [String: Any] {
        if Task.isCancelled { close() }
        let id = try nextID()
        let frame = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let text = String(decoding: frame, as: UTF8.self)
        let answer: ShareJSON = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let failure { lock.unlock(); return continuation.resume(throwing: failure) }    // closed meanwhile: never sent
                waiting[id] = continuation
                lock.unlock()
                task.send(.string(text)) { [weak self] error in
                    if let error { self?.settle(id, ShareFailure.transport(error)) }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in self?.settle(id, ShareFailure.timedOut) }
            }
        } onCancel: { [weak self] in
            self?.close()
        }
        return answer.object
    }

    func notify(_ method: String, _ params: [String: Any]) {
        guard let id = try? nextID(),
              let frame = try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params]) else { return }
        // No waiter: its answer (or an older gateway's refusal) is read and dropped like an event.
        task.send(.string(String(decoding: frame, as: UTF8.self))) { _ in }
    }

    private func nextID() throws -> String {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
        counter += 1
        return "hq-share-\(counter)"
    }

    private func settle(_ id: String, _ error: Error) {
        lock.lock(); let continuation = waiting.removeValue(forKey: id); lock.unlock()
        continuation?.resume(throwing: error)
    }

    /// The reason is recorded before the connection is torn down: the receive loop then ends with the system's own
    /// "cancelled" (-999), which must never replace it (see `ShareFailure.transport`).
    func close() {
        fail(ShareFailure.cancelled)
        task.cancel(with: .normalClosure, reason: nil)
    }
}

/// A decoded JSON object handed across a continuation: built once from `JSONSerialization` and never changed.
nonisolated struct ShareJSON: @unchecked Sendable {
    let object: [String: Any]
    init(_ object: [String: Any]) { self.object = object }
}
