// The Mac screen plugin's health (docs/spec/3x-screen.md §2.4, §5.10, §5.13): the route under its current name and
// the one from before the rename (an older install still answers there), what the answer means for control, and the
// one line "Check setup" shows. The old route's name is in code only, never on screen.

import Foundation

/// What a live Mac screen needs to know about control.
nonisolated struct MacScreen: Equatable, Sendable {
    var control = false
    var inputReady = false
    var locked = false
    var secureInput = false

    /// nil unless the plugin is installed (`installed === true`).
    static func parse(_ health: JSONValue?) -> MacScreen? {
        guard let health, health["installed"]?.bool == true else { return nil }
        let helper = health["helper"]
        let control = health["control"]?.bool == true
        return MacScreen(control: control, inputReady: control && helper?["tcc"]?["events"]?.bool == true,
                         locked: helper?["locked"]?.bool == true, secureInput: helper?["secure_input"]?.bool == true)
    }
}

/// Reads the health route, remembering which name answered. One per account.
actor MacScreenHealthReader {
    enum Route: String, Sendable {
        case current = "/api/plugins/hermes-hq-screen/health"
        case legacy = "/api/plugins/dispatch-screen/health"
    }

    private let rest: any GatewayClient
    private(set) var remembered: Route?
    private var inFlight: Task<JSONValue?, Error>?

    init(rest: any GatewayClient) { self.rest = rest }

    /// The health answer, nil when neither route exists (404). Never more than one request at a time: a second
    /// caller joins the first. Throws on any other failure (the caller keeps its last value).
    func read() async throws -> JSONValue? {
        if let inFlight { return try await inFlight.value }
        let task = Task { try await self.fetch() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    private func fetch() async throws -> JSONValue? {
        let order: [Route] = remembered == .legacy ? [.legacy, .current] : [.current, .legacy]
        for route in order {
            do {
                let data = try await ScreenTimeout.run(.seconds(8)) { [rest] in try await rest.rest("GET", route.rawValue, query: [], body: nil) }
                remembered = route
                return (try? JSONValue.parse(data)) ?? .null
            } catch let error as HTTPError where error.status == 404 {
                continue
            }
        }
        remembered = nil
        return nil
    }
}

nonisolated enum ScreenTimeout {
    struct Expired: Error {}

    /// `work`, or `Expired` when it takes longer than `limit` (the work is cancelled).
    static func run<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let job = Task { try await work() }
        let timer = Task {
            try? await Task.sleep(for: limit)
            if !Task.isCancelled { job.cancel() }
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            do { return try await job.value } catch {
                if job.isCancelled, !Task.isCancelled { throw Expired() }
                throw error
            }
        } onCancel: { job.cancel() }
    }
}

/// "Check setup": the first line that applies (the web's macScreenReadiness, in its order).
nonisolated enum MacScreenReadiness {
    static let ready = "Viewing and control are ready. Open Screen, then \(DeviceWord.tap) Take Control to use the pointer and keyboard."

    static func message(health: JSONValue?, status: ScreenStatus?) -> String {
        func text(_ value: JSONValue?) -> String? {
            guard let text = value?.string.map(ScreenWire.plain), !text.isEmpty else { return nil }
            return text
        }
        if health?["installed"]?.bool != true { return "The Mac screen plugin is not loaded in this gateway yet." }
        if health?["platform"]?.string != "darwin" { return "Live Mac screen sharing needs a Mac gateway." }
        if health?["ok"]?.bool != true || health?["drift"]?.array?.isEmpty != true {
            return "The screen plugin could not verify compatibility with this Hermes version."
        }
        if health?["enabled"]?.bool != true { return "Screen sharing is not enabled on the Mac yet." }
        if let blocker = text(health?["blocker"]) ?? status?.blocker.flatMap({ $0.isEmpty ? nil : $0 }) { return blocker }
        if status?.supported != true { return "This bot does not have access to the Mac’s screen." }
        if status?.installed != true || status?.missing.isEmpty == false || status?.isMac != true {
            return "This gateway has not finished loading the Mac screen setup."
        }
        let helper = health?["helper"]
        if (helper?.object ?? [:]).isEmpty { return "The Mac screen helper has not answered yet. Open Screen to start it." }
        if helper?["ok"]?.bool != true { return "The Mac screen helper has not reported a healthy status yet." }
        if helper?["tcc"]?["screen"]?.bool != true { return "Allow Screen Recording for Hermes HQ Screen on the Mac." }
        if health?["control"]?.bool != true { return "Viewing is ready. Finish setup with Hermes to enable pointer, clicks, and typing." }
        if helper?["tcc"]?["events"]?.bool != true { return "Allow Accessibility for Hermes HQ Screen on the Mac to use control." }
        if helper?["paused"]?.bool == true { return "Resume sharing from Hermes HQ Screen’s menu on the Mac." }
        if let capture = text(helper?["capture_error"]) { return capture }
        if status?.running != true { return "The Mac screen helper is ready. Open Screen to start sharing." }
        return ready
    }
}
