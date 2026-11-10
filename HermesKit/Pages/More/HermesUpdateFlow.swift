// [update-flow] Owner 2026-11-05: Command Center › Update Hermes "updated" the Studio gateway (he thought it was a Nous
// agent) and then sat for ~30 min in Hermes's bot drain ("⏳ Waiting up to 1905s for in-flight turns on … to finish
// before the update...") with nothing on screen and no version change. "We need a better update process all around."
// The pure half of the one Update sheet (App/Pages/More/CommandCenter/HermesUpdate.swift): what the update check and the
// action's receipt say (decoded leniently, additive keys), what an update's log lines say about where it is (the drain,
// the install, the restart), how a run of status answers turns into steps, and how it ends — "Updated to 0.23.0" only
// when the version really changed. Server: `AG/hermes_cli/web_routers/actions.py` (check ~289, status ~385, receipt
// ~456-505), `update_cmd_posix_pause.py:475` and `update_cmd_fleet.py:968,1145` (the drain lines).

import Foundation

// MARK: - The check's extra keys

/// One commit the update brings (`commits` on `GET /api/hermes/update/check`, git installs that are behind).
nonisolated struct HermesUpdateCommit: Sendable, Equatable, Identifiable {
    var sha: String
    var summary: String
    var author: String?
    /// Seconds since the epoch.
    var at: Double?
    var id: String { sha.isEmpty ? summary : sha }

    init(sha: String, summary: String, author: String? = nil, at: Double? = nil) {
        self.sha = sha; self.summary = summary; self.author = author; self.at = at
    }

    init?(json: JSONValue) {
        guard let summary = json["summary"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty else { return nil }
        self.summary = summary
        sha = json["sha"]?.pgString ?? ""
        author = json["author"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        at = json["at"]?.pgSeconds
    }
}

/// What an install method (or a refusal code from `POST /api/hermes/update`) means, in plain words.
nonisolated enum HermesInstallWords {
    /// "docker" → "Hermes runs in Docker here". Nil for a method that updates in place (git) or isn't known.
    static func method(_ code: String?) -> String? {
        switch (code ?? "").lowercased() {
        case "docker", "image-marker", "image-marker-invalid", "docker_update_unsupported": "Hermes runs in a Docker container here"
        case "apt", "apt_update_required": "Hermes was installed with the system’s package manager (APT)"
        case "nix", "nixos", "nix_update_unsupported": "Hermes was installed with Nix"
        case "commit-build", "desktop-app": "Hermes here is a fixed build that came with an app"
        case "managed-runtime", "dashboard_update_managed_externally": "Hermes here is updated by whatever runs it"
        case "update_not_in_place": "Hermes here wasn’t installed in a way it can update itself"
        default: nil
        }
    }
}

// MARK: - The action's receipt

/// The receipt summary on `GET /api/actions/hermes-update/status` (`receipt`) and `GET /api/hermes/update/receipt`
/// (`summary`): the durable truth about the last update (written by every run, refused and failed ones too).
nonisolated struct HermesUpdateReceipt: Sendable, Equatable {
    struct Followup: Sendable, Equatable { var step: String; var reason: String }

    /// running | success | partial | failed | refused | interrupted.
    var outcome: String?
    var actionId: String?
    var preSha: String?
    var postSha: String?
    var postVersion: String?
    var followups: [Followup]
    /// Something the person still has to do (`user_action`: `{step, reason}`).
    var userAction: String?

    init?(json: JSONValue?) {
        guard let json, json.object != nil else { return nil }
        outcome = json["outcome"]?.string?.lowercased()
        actionId = json["action_id"]?.pgString
        preSha = json["pre_sha"]?.pgString ?? json["pre_update"]?["sha"]?.pgString
        postSha = json["post_sha"]?.pgString ?? json["post_update"]?["sha"]?.pgString
        postVersion = (json["post_version"]?.pgString ?? json["post_update"]?["version"]?.pgString).flatMap { $0.isEmpty ? nil : $0 }
        followups = (json["followups"]?.array ?? []).compactMap { item in
            guard let step = item["step"]?.pgString, !step.isEmpty else { return nil }
            return Followup(step: step, reason: item["reason"]?.string ?? "")
        }
        let action = json["user_action"]
        userAction = (action?["reason"]?.string ?? action?.string).flatMap { $0.isEmpty ? nil : $0 }
    }

    var succeeded: Bool { outcome == "success" || outcome == "partial" }
    var failed: Bool { outcome == "failed" || outcome == "interrupted" }
    var refused: Bool { outcome == "refused" }

    /// What's still owed after a committed run, in one line: the person's own step first.
    var owed: String? {
        if let userAction { return userAction }
        return followups.first.map { $0.reason.isEmpty ? $0.step : $0.reason }
    }
}

// MARK: - Refusals

/// `POST /api/hermes/update` answered `ok:false`: the gateway won't update itself here. `command` is what to run instead
/// (`update_command`; empty when nothing on that computer can, e.g. a Docker image).
nonisolated struct HermesUpdateRefusal: Error, LocalizedError, Sendable, Equatable {
    var code: String
    var message: String
    var command: String?

    init(code: String, message: String, command: String?) {
        self.code = code; self.message = message; self.command = command.flatMap { $0.isEmpty ? nil : $0 }
    }

    init?(json: JSONValue) {
        guard json["ok"]?.bool == false else { return nil }
        self.init(code: json["error"]?.string ?? "", message: json["message"]?.string ?? json["error"]?.string ?? "The gateway couldn’t start the update.",
                  command: json["update_command"]?.string)
    }

    var errorDescription: String? { message }
}

// MARK: - The log's words

/// The bots an update is waiting on before it may stop their gateway.
nonisolated struct HermesUpdateDrain: Sendable, Equatable {
    /// Profile names where the gateway's label names one ("ai.hermes.gateway-finance" → "finance", the bare
    /// "ai.hermes.gateway" → "default"); a label that names none stays as Hermes wrote it.
    var profiles: [String]
    /// The longest Hermes waits, in seconds ("Waiting up to 1905s").
    var budget: Int
    /// What the newest "still draining — 1875s left" line said, when there is one.
    var left: Int?
    /// "waiting on 2 active work unit(s)".
    var units: Int?
    /// A later line says the wait is over (the gateway paused or restarted, or the install went on).
    var over: Bool
}

nonisolated enum HermesUpdateLog {
    /// Where an update is, from its own lines.
    enum Stage: Int, Comparable, Sendable {
        case check, drain, install, restart, done
        static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
    }

    /// A gateway's label in a drain line → its profile name, nil when the label names none ("gateway PID 4012").
    static func profile(_ label: String) -> String? {
        var name = label.trimmingCharacters(in: .whitespaces)
        for suffix in [".service", ".plist"] where name.hasSuffix(suffix) { name.removeLast(suffix.count) }
        for prefix in ["ai.hermes.gateway", "hermes-gateway"] where name.hasPrefix(prefix) {
            let rest = name.dropFirst(prefix.count)
            if rest.isEmpty { return "default" }
            if rest.first == "-" || rest.first == "@" || rest.first == "." {
                let profile = String(rest.dropFirst())
                return profile.isEmpty ? "default" : profile
            }
        }
        return nil
    }

    private static func isDrainDetail(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces)
        return text.isEmpty || text.hasPrefix("•") || text.contains("still draining") || text.hasPrefix("waiting on ")
            || text.hasPrefix("finish or kill") || text.contains("draining (up to") || text.contains("for in-flight turns on")
    }

    /// The wait for bots, if one started: the POSIX pause's line (`⏳ Waiting up to Ns for in-flight turns on <labels>
    /// to finish before the update...`) or the fleet restart's (`→ <label>: draining (up to Ns)...`).
    static func drain(_ lines: [String]) -> HermesUpdateDrain? {
        var drain: HermesUpdateDrain?
        var lastDrainLine = -1
        for (index, line) in lines.enumerated() {
            if let match = line.firstMatch(of: #/Waiting up to (\d+)s for in-flight turns on (.+?) to finish/#) {
                let labels = match.2.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                let profiles = labels.map { profile($0) ?? $0 }
                drain = HermesUpdateDrain(profiles: merge(drain?.over == false ? drain?.profiles ?? [] : [], profiles),
                                          budget: Int(match.1) ?? 0, left: nil, units: nil, over: false)
                lastDrainLine = index
            } else if let match = line.firstMatch(of: #/→ (\S+): draining \(up to (\d+)s\)/#) {
                let name = profile(String(match.1)) ?? String(match.1)
                let budget = Int(match.2) ?? 0
                if var open = drain, !open.over {
                    open.profiles = merge(open.profiles, [name])
                    open.budget = max(open.budget, budget)
                    drain = open
                } else {
                    drain = HermesUpdateDrain(profiles: [name], budget: budget, left: nil, units: nil, over: false)
                }
                lastDrainLine = index
            } else if drain != nil, let match = line.firstMatch(of: #/still draining\D+(\d+)s left/#) {
                drain?.left = Int(match.1)
                lastDrainLine = index
            } else if drain != nil, let match = line.firstMatch(of: #/waiting on (\d+) active work unit/#) {
                drain?.units = Int(match.1)
                lastDrainLine = index
            }
        }
        if drain != nil, lines.dropFirst(lastDrainLine + 1).contains(where: { !isDrainDetail($0) }) { drain?.over = true }
        return drain
    }

    private static func merge(_ a: [String], _ b: [String]) -> [String] {
        var out = a
        for name in b where !out.contains(name) { out.append(name) }
        return out
    }

    private static let installSigns = ["⏸ Paused", "Restoring local changes", "Preparing Node", "Building the", "Syncing bundled skills",
                                       "Checking configuration", "stale __pycache__", "Installing", "dependencies", "Refreshed installer",
                                       "Updating config format", "Model catalog cache"]
    private static let restartSigns = ["Restarted paused gateway", "Restarting gateway", "Restarted ", "⟲ Stopping", "=== hermes-update completed",
                                       "Update complete!", "Fleet version check", "Handed gateway profile"]

    /// The furthest stage the lines show.
    static func stage(_ lines: [String]) -> Stage {
        var stage = Stage.check
        if let drain = drain(lines) { stage = drain.over ? .install : .drain }
        for line in lines {
            if restartSigns.contains(where: line.contains) { stage = max(stage, .restart) }
            else if installSigns.contains(where: line.contains) { stage = max(stage, .install) }
        }
        return stage
    }

    /// "✓ Update complete! (v0.22.2 → v0.22.5)" → ("0.22.2", "0.22.5").
    static func completed(_ lines: [String]) -> (from: String, to: String)? {
        for line in lines.reversed() {
            if let match = line.firstMatch(of: #/Update complete!\s*\(v?([^\s)]+)\s*→\s*v?([^\s)]+)\)/#) {
                return (String(match.1), String(match.2))
            }
        }
        return nil
    }

    /// Why a run failed, in Hermes's own words: its last "✗" line, else its last line.
    static func failure(_ lines: [String]) -> String? {
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("===") }
        if let cross = trimmed.last(where: { $0.hasPrefix("✗") || $0.hasPrefix("✘") || $0.hasPrefix("Error") }) {
            return String(cross.drop { $0 == "✗" || $0 == "✘" || $0 == " " })
        }
        return trimmed.last
    }
}

// MARK: - Steps

nonisolated enum HermesUpdateStepID: String, Sendable, CaseIterable {
    /// A gateway's own update.
    case check, drain, install, restart, confirm
    /// A Nous agent's: Ask Nous → Nous Reinstalls → Hermes Answers → Confirm Version.
    case ask, reinstall, answer, version

    static let gateway: [HermesUpdateStepID] = [.check, .drain, .install, .restart, .confirm]
    static let cloud: [HermesUpdateStepID] = [.ask, .reinstall, .answer, .version]
}

/// `failed`: the step the update stopped on.
nonisolated enum HermesUpdateStepState: Equatable, Sendable { case waiting, active, done, skipped, failed }

/// How a run of status answers turns into the gateway update's steps. Fed each poll of
/// `GET /api/actions/hermes-update/status` (or a read that got no answer: the gateway restarting).
nonisolated struct HermesUpdateProgress: Sendable, Equatable {
    private(set) var stage: HermesUpdateLog.Stage = .check
    private(set) var drain: HermesUpdateDrain?
    /// When the drain line was first read (its deadline counts from here, or from the newest "s left").
    private(set) var drainSeenAt: Date?
    private(set) var drainDeadline: Date?
    /// A read went unanswered after the install began: the gateway went down to restart.
    private(set) var sawGap = false
    private(set) var exitCode: Int?
    private(set) var finished = false
    private(set) var receipt: HermesUpdateReceipt?
    private(set) var lines: [String] = []

    init() {}

    mutating func read(_ status: GatewayActionStatus, at now: Date = Date()) {
        if !status.lines.isEmpty { lines = status.lines }
        if let receipt = status.receipt { self.receipt = receipt }
        var next = HermesUpdateLog.stage(lines)
        if let found = HermesUpdateLog.drain(lines) {
            if drain == nil || drain?.budget != found.budget || drain?.profiles != found.profiles { drainSeenAt = now; drainDeadline = now.addingTimeInterval(Double(found.budget)) }
            if let left = found.left, left != drain?.left { drainDeadline = now.addingTimeInterval(Double(left)) }
            drain = found
        }
        // Back after a gap the install had started: the restart happened.
        if sawGap, next >= .install || stage >= .install { next = max(next, .restart) }
        if !status.running, status.exitCode != nil || status.receipt?.outcome.map({ $0 != "running" }) == true {
            finished = true
            exitCode = status.exitCode ?? (status.receipt?.succeeded == true ? 0 : 1)
            next = .done
        }
        stage = max(stage, next)
    }

    mutating func unanswered() {
        if stage >= .install || drain?.over == true { sawGap = true }
    }

    /// The drain didn't happen: skipped once the install is under way without one.
    var drainSkipped: Bool { drain == nil && stage >= .install }

    func state(_ step: HermesUpdateStepID) -> HermesUpdateStepState {
        let order: [HermesUpdateStepID: HermesUpdateLog.Stage] = [.check: .check, .drain: .drain, .install: .install, .restart: .restart, .confirm: .done]
        guard let mine = order[step] else { return .waiting }
        if step == .drain, drainSkipped { return .skipped }
        if step == .confirm { return finished ? .active : .waiting }
        if stage > mine { return .done }
        // The check is done as soon as the update was started.
        if step == .check { return .done }
        return stage == mine ? .active : .waiting
    }

    /// The drain step's line: "Finishing replies on Finance, Gym · up to 32 min". `names` maps profile → bot name.
    func drainDetail(names: (String) -> String, now: Date = Date()) -> String? {
        guard let drain, !drain.over else { return nil }
        let who = HermesUpdateWords.list(drain.profiles.map(names))
        var line = who.isEmpty ? "Finishing replies" : "Finishing replies on \(who)"
        if let deadline = drainDeadline {
            line += " · up to \(HermesUpdateWords.minutes(max(0, deadline.timeIntervalSince(now))))"
        }
        return line
    }
}

// MARK: - Endings

nonisolated enum HermesUpdateEnd: Equatable, Sendable {
    /// The version really changed (read back from `/api/status`).
    case updated(to: String)
    case upToDate(version: String?)
    /// This gateway can't update itself: what it is in plain words, and what to run instead (nil: nothing there can).
    case cantUpdateHere(method: String, command: String?)
    /// It finished, but the version is the same as before.
    case unchanged(version: String?)
    /// It finished, but the version couldn't be read afterwards.
    case unconfirmed
    case failed(reason: String)

    /// How a finished gateway update ended. `before`: the version before (the check's or the status's); `after`: what
    /// `/api/status` says now (nil: no answer).
    static func gateway(exitCode: Int?, receipt: HermesUpdateReceipt?, before: String?, after: String?, lines: [String]) -> HermesUpdateEnd {
        if let after, let before, !versionsMatch(after, before) { return .updated(to: after) }
        let ok = receipt.map(\.succeeded) ?? (exitCode == 0)
        if ok, receipt?.failed != true {
            guard let after else { return .unconfirmed }
            guard before != nil else {
                // No version from before: only the receipt can say the code moved and landed on this version.
                if let receipt, let pre = receipt.preSha, let post = receipt.postSha, pre != post,
                   receipt.postVersion.map({ versionsMatch($0, after) }) == true { return .updated(to: after) }
                return .unconfirmed
            }
            return .unchanged(version: after)
        }
        let reason = receipt?.owed ?? HermesUpdateLog.failure(lines) ?? exitCode.map { "Hermes stopped with an error (exit \($0))." }
        return .failed(reason: reason ?? "The update didn’t finish.")
    }

    /// Reading the version after the run ended, still the old one: give up early (after 4 reads, ~20 s) only when Hermes
    /// said the update failed. An unknown exit (the gateway stopped reporting the update) may still be Hermes waiting
    /// for bots or restarting, so it reads on for the whole minute and a half.
    static func stopsReading(attempt: Int, exitCode: Int?) -> Bool {
        guard let exitCode else { return false }
        return attempt >= 3 && exitCode != 0
    }

    /// How a Nous agent's update ended: its own Hermes's version before and after (nil: couldn't be read).
    static func cloud(before: String?, after: String?) -> HermesUpdateEnd {
        guard let after else { return .unconfirmed }
        if let before, versionsMatch(before, after) { return .unchanged(version: after) }
        guard before != nil else { return .unconfirmed }
        return .updated(to: after)
    }

    /// "v0.22.5" and "0.22.5" are the same.
    static func versionsMatch(_ a: String, _ b: String) -> Bool { normalized(a) == normalized(b) }

    static func normalized(_ version: String) -> String {
        var text = version.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasPrefix("hermes ") { text.removeFirst(7) }
        if text.hasPrefix("v") { text.removeFirst() }
        return text
    }
}

nonisolated enum HermesUpdateWords {
    /// "Finance", "Finance and Gym", "Finance, Gym and Home".
    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        default: names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    /// "32 min", "1 hr 5 min", "under a minute".
    static func minutes(_ seconds: TimeInterval) -> String {
        let total = Int((seconds / 60).rounded(.up))
        if total < 1 { return "under a minute" }
        if total < 60 { return "\(total) min" }
        let hours = total / 60, rest = total % 60
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }

    /// "0.22.5 → 0.23.0" (either side may be missing).
    static func versions(from: String?, to: String?) -> String? {
        let from = from.map(HermesUpdateEnd.normalized), to = to.map(HermesUpdateEnd.normalized)
        switch (from, to) {
        case let (a?, b?) where a != b: return "\(a) → \(b)"
        case let (a?, _): return a
        case let (nil, b?): return "→ \(b)"
        default: return nil
        }
    }
}

// MARK: - Talking to the gateway

/// One gateway to update: the one in use (its live client) or a saved one that isn't (`AccountProbe`, REST only).
nonisolated protocol HermesUpdateEndpoint: Sendable {
    func json(_ method: String, _ path: String, query: [URLQueryItem], body: JSONValue?, timeout: TimeInterval) async throws -> JSONValue
    /// Done with it (a probe settles a renewal and closes).
    func finish()
}

nonisolated struct ClientUpdateEndpoint: HermesUpdateEndpoint {
    let client: any GatewayClient
    func json(_ method: String, _ path: String, query: [URLQueryItem], body: JSONValue?, timeout: TimeInterval) async throws -> JSONValue {
        try await PagesREST.json(client, method, path, query: query, json: body, timeout: timeout)
    }
    func finish() {}
}

extension AccountProbe: HermesUpdateEndpoint {}

/// The update's routes, on any endpoint.
nonisolated struct HermesUpdateAPI: Sendable {
    let endpoint: any HermesUpdateEndpoint

    func check(force: Bool) async throws -> HermesUpdateCheck {
        let check = HermesUpdateCheck(json: try await endpoint.json("GET", "/api/hermes/update/check",
                                                                  query: force ? [URLQueryItem(name: "force", value: "true")] : [], body: nil, timeout: 45))
        AppLog.trace("config", "update flow: check \(check.words), method \(check.installMethod ?? "?"), \(check.commits.count) commits")
        return check
    }

    /// `POST /api/hermes/update` → the action's name; throws `HermesUpdateRefusal` for `ok:false`.
    func start() async throws -> String {
        let answer = try await endpoint.json("POST", "/api/hermes/update", query: [], body: nil, timeout: 30)
        if let refusal = HermesUpdateRefusal(json: answer) {
            AppLog.note("config", "update flow: refused (\(refusal.code)): \(refusal.message)")
            throw refusal
        }
        return answer["name"]?.string ?? "hermes-update"
    }

    func status(_ name: String = "hermes-update") async throws -> GatewayActionStatus {
        let answer = try await endpoint.json("GET", "/api/actions/\(PagesREST.segment(name))/status",
                                             query: [URLQueryItem(name: "lines", value: "200")], body: nil, timeout: 10)
        return GatewayActionStatus(json: answer, fallbackName: name)
    }

    /// `GET /api/hermes/update/receipt` → its summary (nil: none yet, or an older Hermes).
    func receipt() async -> HermesUpdateReceipt? {
        guard let answer = try? await endpoint.json("GET", "/api/hermes/update/receipt", query: [], body: nil, timeout: 10) else { return nil }
        return HermesUpdateReceipt(json: answer["summary"]) ?? HermesUpdateReceipt(json: answer["receipt"])
    }

    /// `GET /api/status`'s version (nil: no answer).
    func version() async -> String? {
        guard let answer = try? await endpoint.json("GET", "/api/status", query: [], body: nil, timeout: 10) else { return nil }
        return answer["version"]?.pgString.flatMap { $0.isEmpty ? nil : $0 }
    }
}

// MARK: - Nous's update_image

nonisolated enum CloudUpdateImage {
    /// The fields to send with `update_image`: a version / image / tag field whose choices include "latest", set to it.
    /// Nothing when Portal's schema has no such field (it takes only the agent's id today).
    static func latest(_ fields: [CloudField]) -> [String: JSONValue] {
        for field in fields {
            let name = field.name.lowercased()
            guard ["version", "image", "tag", "release"].contains(where: name.contains) else { continue }
            if field.choices.contains(where: { $0.lowercased() == "latest" }) { return [field.name: .string("latest")] }
        }
        return [:]
    }
}
