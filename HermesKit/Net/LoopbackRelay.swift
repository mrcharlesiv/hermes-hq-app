// One-shot loopback listeners that catch an OAuth redirect (spec 01 §6.3; port of the web app's DispatchOAuthRelay,
// HermesPlatformExtras.swift): IPv4 127.0.0.1 only, OS-chosen port, ≤ 8 listeners alive, ≤ 4 connections per sign-in,
// a 10 s / 8 KiB request-head limit, every connection answered with a small "Signed in" page, and only
// `GET /callback?…code|error…` settles. Loopback never leaves the phone.

import Foundation
import Network

nonisolated final class LoopbackRelay: @unchecked Sendable { // State lives on `queue`.
    struct Failure: Error, Sendable { let message: String }

    struct Callback: Sendable, Equatable {
        var code: String? = nil
        var error: String? = nil
        var iss: String? = nil
        var state: String? = nil
    }

    private final class Entry: @unchecked Sendable { // Touched only on `queue`.
        let listener: NWListener
        let closeBrowser: @Sendable () -> Void
        var result: Callback?
        var waiters: [(Callback) -> Void] = []
        var connections: [ObjectIdentifier: NWConnection] = [:]
        init(_ listener: NWListener, closeBrowser: @escaping @Sendable () -> Void) {
            self.listener = listener; self.closeBrowser = closeBrowser
        }
    }

    private final class Once: @unchecked Sendable { var done = false }

    static let shared = LoopbackRelay()
    static let connectionLimit = 4
    static let listenerLimit = 8
    static let page = "<!doctype html><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\"><title>Signed in</title><body style=\"font:17px -apple-system,system-ui;margin:3rem 1.5rem;text-align:center\"><h2>&#10003; Signed in</h2><p>Return to Hermes HQ to finish connecting.</p>"

    private let headDeadline: TimeInterval
    private let queue = DispatchQueue(label: "ai.hermes.hqnative.oauth-relay")
    private var entries: [String: Entry] = [:]
    private var next = 1

    init(headDeadline: TimeInterval = 10) { self.headDeadline = headDeadline }

    /// Starts a listener; returns its id and `http://127.0.0.1:<port>/callback`. `lifetime` bounds a listener nobody
    /// waits on. `closeBrowser` runs when the provider's redirect arrives (not on cancel or timeout).
    func listen(closeBrowser: @escaping @Sendable () -> Void = {}, lifetime: TimeInterval = 900) async throws -> (id: String, redirectURI: String) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        guard let listener = try? NWListener(using: parameters) else { throw Failure(message: "Couldn't start the sign-in callback listener") }
        let id: String = try queue.sync {
            guard entries.count < Self.listenerLimit else { throw Failure(message: "Too many sign-ins are already waiting") }
            defer { next += 1 }
            let id = String(next)
            entries[id] = Entry(listener, closeBrowser: closeBrowser)
            queue.asyncAfter(deadline: .now() + lifetime) { [weak self] in self?.close(id, Callback(error: "timeout waiting for OAuth callback")) }
            return id
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection, id: id) }
        let port: UInt16? = await withCheckedContinuation { continuation in
            let resumed = Once()
            listener.stateUpdateHandler = { state in
                guard !resumed.done else { return }
                switch state {
                case .ready: resumed.done = true; continuation.resume(returning: listener.port?.rawValue)
                case .failed, .cancelled: resumed.done = true; continuation.resume(returning: nil)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        guard let port, port > 0 else { cancel(id); throw Failure(message: "Couldn't start the sign-in callback listener") }
        return (id, "http://127.0.0.1:\(port)/callback")
    }

    /// Resolves with the callback (at once if already settled); timeout clamped to 1…900 s.
    func wait(_ id: String, timeout: TimeInterval) async -> Callback {
        await withCheckedContinuation { continuation in
            queue.async {
                guard let entry = self.entries[id] else { return continuation.resume(returning: Callback(error: "listener not found")) }
                if let result = entry.result { self.entries[id] = nil; return continuation.resume(returning: result) }
                entry.waiters.append { result in self.entries[id] = nil; continuation.resume(returning: result) }
                self.queue.asyncAfter(deadline: .now() + min(max(timeout, 1), 900)) {
                    self.settle(id, Callback(error: "timeout waiting for OAuth callback"))
                }
            }
        }
    }

    func cancel(_ id: String) { queue.async { self.close(id, Callback(error: "cancelled")) } }

    func cancelAll() { queue.async { Array(self.entries.keys).forEach { self.close($0, Callback(error: "cancelled")) } } }

    var liveListeners: Int { queue.sync { entries.count } }

    // MARK: On `queue`

    private func close(_ id: String, _ result: Callback) {
        settle(id, result)
        entries[id] = nil
    }

    private func settle(_ id: String, _ result: Callback) {
        guard let entry = entries[id], entry.result == nil else { return }
        entry.result = result
        entry.listener.cancel()
        let open = entry.connections.values
        entry.connections.removeAll()
        open.forEach { $0.cancel() }
        let waiters = entry.waiters
        entry.waiters.removeAll()
        waiters.forEach { $0(result) }
        // Only the provider's redirect closes the browser; a cancel or timeout leaves what the user sees alone.
        if result.state != nil || result.code != nil { entry.closeBrowser() }
    }

    private func serve(_ connection: NWConnection, id: String) {
        guard let entry = entries[id], entry.result == nil, entry.connections.count < Self.connectionLimit else { return connection.cancel() }
        let key = ObjectIdentifier(connection)
        entry.connections[key] = connection
        connection.stateUpdateHandler = { [weak entry, weak connection] state in
            switch state {
            case .failed: entry?.connections[key] = nil; connection?.cancel()
            case .cancelled: entry?.connections[key] = nil
            default: break
            }
        }
        queue.asyncAfter(deadline: .now() + headDeadline) { [weak connection] in connection?.cancel() }
        connection.start(queue: queue)
        read(connection, id: id, buffer: Data())
    }

    private func read(_ connection: NWConnection, id: String, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            let head = String(decoding: buffer.prefix(8192), as: UTF8.self)
            guard head.contains("\r\n\r\n") || complete || error != nil || buffer.count >= 8192 else {
                return self.read(connection, id: id, buffer: buffer)
            }
            // Answered: it closes itself once the page is sent, so settling below never cuts its response off.
            self.entries[id]?.connections[ObjectIdentifier(connection)] = nil
            let body = Data(Self.page.utf8)
            let response = Data(("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\n"
                + "Cache-Control: no-store\r\nConnection: close\r\n\r\n").utf8) + body
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            // A favicon or preconnect gets the page too; only the redirect itself settles the listener.
            if let callback = Self.callback(fromRequestHead: head) { self.settle(id, callback) }
        }
    }

    /// The callback a request head carries: only `GET /callback?…` with `code` or `error` (pure; tested).
    static func callback(fromRequestHead head: String) -> Callback? {
        let line = head.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let target = String(parts[1])
        guard let url = URLComponents(string: "http://127.0.0.1" + target), url.path == "/callback",
              let items = url.queryItems, items.contains(where: { $0.name == "code" || $0.name == "error" }) else { return nil }
        let value = { (name: String) in items.first(where: { $0.name == name })?.value }
        return Callback(code: value("code"), error: value("error"), iss: value("iss"), state: value("state"))
    }
}
