import Darwin
import Foundation
import Testing
@testable import HermesHQNative

/// Stand-in gateways started by hand (docs/spec/05-fixtures-release.md Part A) and their credentials files, found
/// under this worktree's build/fixtures/ (0700 folder, 0600 files). Tests that need one skip when its port is closed.
nonisolated enum Fixtures {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    static let folder = root.appending(path: "build/fixtures")
    static let perfPort: UInt16 = 9711
    static let nousPort: UInt16 = 9713

    struct Credentials: Sendable { let url: String; let username: String; let password: String }

    static func credentials(_ name: String) -> Credentials? {
        guard let data = try? Data(contentsOf: folder.appending(path: name)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = object["url"] as? String, let username = object["username"] as? String,
              let password = object["password"] as? String else { return nil }
        return Credentials(url: url, username: username, password: password)
    }

    static let plaidPort: UInt16 = 9716

    static var perfAvailable: Bool { portOpen(perfPort) && credentials("perf.json") != nil }
    static var plaidAvailable: Bool { portOpen(plaidPort) && credentials("plaid.json") != nil }

    /// A Plaid fixture control (`/__plaid/…`, GET, no auth).
    @discardableResult
    static func plaid(_ path: String) async throws -> JSONValue { try await control(plaidPort, path, method: "GET") }
    static var nousAvailable: Bool { portOpen(nousPort) }
    static var nousPasswordAvailable: Bool { nousAvailable && credentials("nous.json") != nil }

    /// A plain TCP connect to 127.0.0.1:port (loopback answers or refuses at once).
    static func portOpen(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0
    }

    /// A fixture-only control request (never authenticated).
    @discardableResult
    static func control(_ port: UInt16, _ path: String, method: String = "POST", json: [String: Any]? = nil) async throws -> JSONValue {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!, timeoutInterval: 10)
        request.httpMethod = method
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, _) = try await session.data(for: request)
        return (try? JSONValue.parseFast(data)) ?? .null
    }

    /// The Nous fixture's counters (`GET /__fixture/nous`).
    static func nousCounts() async throws -> [String: Int] {
        let value = try await control(nousPort, "/__fixture/nous", method: "GET")
        return (value["counts"]?.object ?? [:]).compactMapValues(\.int)
    }

    static func testVault(_ name: String) -> AccountVault {
        AccountVault(service: "ai.hermes.hqnative.gateway.tests.\(name)", signedOutKey: "hqnative.tests.\(name).signedOut")
    }
}

nonisolated struct TimedOut: Error, CustomStringConvertible {
    let what: String
    var description: String { "timed out waiting for \(what)" }
}

/// The first element matching `match`, or TimedOut. Consumes `stream` (subscribe before triggering).
nonisolated func first<T: Sendable>(_ stream: AsyncStream<T>, within seconds: Double, _ what: String,
                                    where match: @escaping @Sendable (T) -> Bool) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask {
            for await item in stream where match(item) { return item }
            return nil
        }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            return nil
        }
        let found = try await group.next() ?? nil
        group.cancelAll()
        guard let found else { throw TimedOut(what: what) }
        return found
    }
}

/// Everything up to and including the first element matching `until`.
nonisolated func collect<T: Sendable>(_ stream: AsyncStream<T>, within seconds: Double, _ what: String,
                                      until done: @escaping @Sendable (T) -> Bool) async throws -> [T] {
    try await withThrowingTaskGroup(of: [T]?.self) { group in
        group.addTask {
            var seen: [T] = []
            for await item in stream {
                seen.append(item)
                if done(item) { return seen }
            }
            return nil
        }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            return nil
        }
        let found = try await group.next() ?? nil
        group.cancelAll()
        guard let found else { throw TimedOut(what: what) }
        return found
    }
}

/// Waits until the client reports `state`.
nonisolated func waitFor(_ client: LiveGatewayClient, _ state: ConnectionState, within seconds: Double = 15) async throws {
    _ = try await first(client.connectionStates(), within: seconds, "\(state)") { $0 == state }
}

/// Drives the Nous fixture's pages the way the system sheet would: authorize → Portal page → "Continue as owner" →
/// the gateway's callback → its redirect to the app's loopback listener. Redirects are followed by hand, the PKCE
/// cookie carried by hand, so nothing here relies on a browser.
@MainActor final class FixtureBrowser: NousBrowser {
    let choice: String
    private(set) var closed = false
    private(set) var steps: [String] = []
    private var task: Task<Void, Never>?

    init(choice: String = "Continue as owner") { self.choice = choice }

    func open(_ url: URL, userCancelled: @escaping @MainActor () -> Void) -> Bool {
        task = Task { await drive(url, userCancelled) }
        return true
    }

    func close() { closed = true }

    private func drive(_ url: URL, _ userCancelled: @escaping @MainActor () -> Void) async {
        let transport = HTTPTransport(cookies: false)
        defer { transport.invalidate() }
        func get(_ url: URL, cookie: String? = nil) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.httpShouldHandleCookies = false
            if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
            return try await transport.data(for: request, pool: .bulk, ceiling: 1 << 20)
        }
        do {
            let (_, authorize) = try await get(url)
            steps.append("authorize \(authorize.statusCode)")
            guard authorize.statusCode == 302, let portal = authorize.value(forHTTPHeaderField: "Location").flatMap(URL.init(string:)),
                  let pkce = authorize.value(forHTTPHeaderField: "Set-Cookie")?.split(separator: ";").first.map(String.init) else {
                return userCancelled()
            }
            let (page, _) = try await get(portal)
            let html = String(decoding: page, as: UTF8.self)
            let pattern = #"href="([^"]+)">"# + NSRegularExpression.escapedPattern(for: choice) + "<"
            guard let match = html.range(of: pattern, options: .regularExpression) else { return userCancelled() }
            let link = String(html[match]).replacingOccurrences(of: #"^href=""#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"">.*$"#, with: "", options: .regularExpression)
            steps.append("portal")
            guard let callbackURL = URL(string: link.replacingOccurrences(of: "&amp;", with: "&")) else { return userCancelled() }
            let (_, callback) = try await get(callbackURL, cookie: pkce)
            steps.append("callback \(callback.statusCode)")
            guard callback.statusCode == 302, let loopback = callback.value(forHTTPHeaderField: "Location").flatMap(URL.init(string:)) else {
                return userCancelled()
            }
            let (_, relayed) = try await get(loopback)
            steps.append("loopback \(relayed.statusCode)")
        } catch {
            steps.append("error \(error)")
            userCancelled()
        }
    }
}

/// Runs a `call` expected to fail without reaching a gateway; returns why (nil when it succeeded or failed otherwise).
/// `call` throws only RPCError (the contract): a call that never went out is `isNotConnected` with a reason.
nonisolated func notSentReason(_ body: @Sendable () async throws -> Void) async -> GatewayFailure? {
    do {
        try await body()
        Issue.record("expected the call to fail")
        return nil
    } catch let error as RPCError {
        #expect(error.isNotConnected, "not a not-sent error: \(error)")
        #expect(!error.message.isEmpty)
        return error.notSentBecause
    } catch {
        Issue.record("call threw a non-RPCError: \(error)")
        return nil
    }
}

/// Polls `condition` every 50 ms until it holds, or throws TimedOut.
nonisolated func eventually(within seconds: Double, _ what: String, _ condition: @Sendable () -> Bool) async throws {
    let end = ContinuousClock.now + .seconds(seconds)
    while !condition() {
        guard ContinuousClock.now < end else { throw TimedOut(what: what) }
        try await Task.sleep(for: .milliseconds(50))
    }
}
