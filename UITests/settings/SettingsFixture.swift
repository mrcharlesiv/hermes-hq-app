// The settings fixture as the UI tests see it (scripts/e2e-settings.sh starts it and passes the credentials files).

import XCTest

struct SettingsFixture {
    let url: String
    let username: String
    let password: String
    let isNous: Bool

    /// "127.0.0.1:9738": how the gateway rows and menus name this fixture (integration runs it on other ports).
    var hostPort: String {
        guard let parsed = URL(string: url), let host = parsed.host() else { return url }
        return parsed.port.map { "\(host):\($0)" } ?? host
    }
    var port: String { URL(string: url)?.port.map(String.init) ?? "" }

    static func load(_ variable: String) throws -> SettingsFixture {
        guard let path = ProcessInfo.processInfo.environment[variable], !path.isEmpty else {
            throw XCTSkip("Run scripts/e2e-settings.sh (it starts the settings fixture and sets \(variable)).")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let url = object["url"] as? String else {
            throw XCTSkip("Unreadable credentials file")
        }
        return SettingsFixture(url: url, username: object["username"] as? String ?? "", password: object["password"] as? String ?? "",
                               isNous: object["nous"] as? Bool ?? false)
    }

    /// A control (`/__settings/…` or `/__fixture/…`, no auth). Blocks for at most 10 s.
    @discardableResult
    func control(_ path: String, _ body: [String: Any]? = nil) throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url + path)!, timeoutInterval: 10)
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            box.data = data; box.status = (response as? HTTPURLResponse)?.statusCode; box.error = error
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 12)
        if let error = box.error { throw error }
        guard let status = box.status, (200..<300).contains(status) else {
            throw NSError(domain: "fixture", code: box.status ?? -1, userInfo: [NSLocalizedDescriptionKey: "\(path) answered \(box.status ?? -1)"])
        }
        return (box.data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
    }

    func state() -> [String: Any] { (try? control("/__settings/state")) ?? [:] }

    /// Writes of one method, oldest first: their params. [main-e2e] The synced documents' own writes (`hermes-hq-sync.*`
    /// on the default bot: pins, orders and settings travelling to the owner's other devices, b5d94705) are left out
    /// unless `synced`: the tests count what is written onto the bots.
    func writes(_ method: String, synced: Bool = false) -> [[String: Any]] {
        ((state()["writes"] as? [[String: Any]]) ?? []).filter { $0["method"] as? String == method }.compactMap { $0["params"] as? [String: Any] }
            .filter { write in
                guard !synced, let meta = write["ui_meta"] as? [String: Any], !meta.isEmpty else { return true }
                return meta.keys.contains { !$0.hasPrefix("hermes-hq-sync.") }
            }
    }

    func profile(_ name: String) -> [String: Any] { ((state()["profiles"] as? [String: Any])?[name] as? [String: Any]) ?? [:] }

    func botsMeta(_ name: String) -> [String: Any] {
        ((profile(name)["ui_meta"] as? [String: Any])?["hermes-bots"] as? [String: Any]) ?? [:]
    }

    private final class Box: @unchecked Sendable {
        var data: Data?
        var status: Int?
        var error: Error?
    }
}

/// JSON-ish equality for fixture dictionaries.
func same(_ a: Any?, _ b: Any?) -> Bool {
    guard let a, let b else { return a == nil && b == nil }
    return (a as AnyObject).isEqual(b)
}
