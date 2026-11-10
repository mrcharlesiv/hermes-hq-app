// [update-flow] The one Update sheet's pure parts (HermesKit/Pages/More/HermesUpdateFlow.swift): the check's and the
// receipt's lenient decoding, the drain line parser, step derivation from status polls (including the restart gap, a
// refusal and a version that didn't change) and how gateway and Nous updates end.

import Foundation
import Testing
@testable import HermesHQNative

private nonisolated func json(_ text: String) -> JSONValue { try! JSONValue.parse(Data(text.utf8)) }

struct HermesUpdateDecodingTests {
    @Test func decodesTheCheckWithCommits() {
        let check = HermesUpdateCheck(json: json("""
        {"install_method": "git", "current_version": "0.22.5", "behind": 3, "update_available": true, "can_apply": true,
         "update_command": "hermes update", "channel": "stable", "source_version": "0.23.0", "held": null,
         "commits": [{"sha": "2bd378e", "summary": "Gateways drain first", "author": "teknium", "at": 1762300000},
                     {"sha": "", "summary": ""}, {"summary": "No sha"}]}
        """))
        #expect(check.installMethod == "git")
        #expect(check.currentVersion == "0.22.5")
        #expect(check.sourceVersion == "0.23.0")
        #expect(check.behind == 3)
        #expect(check.updateAvailable)
        #expect(check.commits.map(\.summary) == ["Gateways drain first", "No sha"])
        #expect(check.commits.first?.author == "teknium")
    }

    @Test func anOlderCheckStillDecodes() {
        let check = HermesUpdateCheck(json: json(#"{"behind": 0, "update_available": false, "current_version": ""}"#))
        #expect(check.currentVersion == nil)
        #expect(check.commits.isEmpty)
        #expect(check.installMethod == nil)
        #expect(!check.updateAvailable)
    }

    @Test func decodesTheReceipt() {
        let receipt = HermesUpdateReceipt(json: json("""
        {"outcome": "Partial", "action_id": "a1", "pre_sha": "aaa", "post_sha": "bbb", "post_version": "0.23.0",
         "followups": [{"step": "restart_dashboard", "reason": "Restart the dashboard"}, {"reason": "no step"}],
         "user_action": {"step": "node", "reason": "Install Node 22, then run hermes update again"}}
        """))
        #expect(receipt?.outcome == "partial")
        #expect(receipt?.succeeded == true)
        #expect(receipt?.postVersion == "0.23.0")
        #expect(receipt?.followups.count == 1)
        #expect(receipt?.owed == "Install Node 22, then run hermes update again")
        #expect(HermesUpdateReceipt(json: json("[]")) == nil)
        #expect(HermesUpdateReceipt(json: nil) == nil)
    }

    @Test func theStatusCarriesItsReceipt() {
        let status = GatewayActionStatus(json: json("""
        {"name": "hermes-update", "running": false, "exit_code": 0, "lines": ["✓ Update complete! (v0.22.5 → v0.23.0)"],
         "receipt": {"outcome": "success", "post_version": "0.23.0"}}
        """), fallbackName: "hermes-update")
        #expect(status.receipt?.succeeded == true)
        #expect(HermesUpdateLog.completed(status.lines)! == ("0.22.5", "0.23.0"))
    }

    @Test func decodesARefusal() {
        let refusal = HermesUpdateRefusal(json: json("""
        {"ok": false, "error": "docker_update_unsupported", "message": "Pull the new image.", "update_command": "docker compose pull"}
        """))
        #expect(refusal?.code == "docker_update_unsupported")
        #expect(refusal?.command == "docker compose pull")
        #expect(HermesUpdateRefusal(json: json(#"{"ok": true, "name": "hermes-update"}"#)) == nil)
        #expect(HermesInstallWords.method(refusal?.code) == "Hermes runs in a Docker container here")
    }
}

struct HermesUpdateDrainTests {
    @Test func profilesFromLabels() {
        #expect(HermesUpdateLog.profile("ai.hermes.gateway") == "default")
        #expect(HermesUpdateLog.profile("ai.hermes.gateway-finance") == "finance")
        #expect(HermesUpdateLog.profile("hermes-gateway-gym.service") == "gym")
        #expect(HermesUpdateLog.profile("hermes-gateway.service") == "default")
        #expect(HermesUpdateLog.profile("gateway PID 4012") == nil)
    }

    @Test func readsThePosixPause() {
        let lines = ["→ Checking for updates…",
                     "  ⏳ Waiting up to 1905s for in-flight turns on ai.hermes.gateway, ai.hermes.gateway-finance to finish before the update...",
                     "    ⏳ still draining — 1875s left before the forced restart",
                     "    waiting on 2 active work unit(s):",
                     "      • finance: telegram turn"]
        let drain = HermesUpdateLog.drain(lines)
        #expect(drain?.profiles == ["default", "finance"])
        #expect(drain?.budget == 1905)
        #expect(drain?.left == 1875)
        #expect(drain?.units == 2)
        #expect(drain?.over == false)
        #expect(HermesUpdateLog.stage(lines) == .drain)
    }

    @Test func readsTheFleetDrain() {
        let lines = ["→ ai.hermes.gateway: draining (up to 600s)...", "→ ai.hermes.gateway-gym: draining (up to 900s)..."]
        let drain = HermesUpdateLog.drain(lines)
        #expect(drain?.profiles == ["default", "gym"])
        #expect(drain?.budget == 900)
    }

    @Test func theDrainEndsWhenOtherWorkFollows() {
        let lines = ["  ⏳ Waiting up to 60s for in-flight turns on ai.hermes.gateway to finish before the update...",
                     "⏸ Paused for the update: ai.hermes.gateway", "Installing Python dependencies…"]
        #expect(HermesUpdateLog.drain(lines)?.over == true)
        #expect(HermesUpdateLog.stage(lines) == .install)
    }

    @Test func noDrainLineMeansNoWait() {
        #expect(HermesUpdateLog.drain(["⏸ Paused for the update: none busy", "Installing"]) == nil)
    }

    @Test func drainWords() {
        var progress = HermesUpdateProgress()
        let now = Date(timeIntervalSince1970: 1000)
        progress.read(GatewayActionStatus(name: "hermes-update", running: true, exitCode: nil,
                                          lines: ["  ⏳ Waiting up to 1905s for in-flight turns on ai.hermes.gateway-finance, ai.hermes.gateway-gym to finish"]), at: now)
        let names = ["finance": "Finance", "gym": "Gym"]
        #expect(progress.drainDetail(names: { names[$0] ?? $0 }, now: now) == "Finishing replies on Finance and Gym · up to 32 min")
        #expect(progress.state(.drain) == .active)
    }
}

struct HermesUpdateStepTests {
    private func status(_ lines: [String], running: Bool = true, exit: Int? = nil, receipt: String? = nil) -> GatewayActionStatus {
        GatewayActionStatus(name: "hermes-update", running: running, exitCode: exit, lines: lines,
                            receipt: receipt.flatMap { HermesUpdateReceipt(json: json($0)) })
    }

    @Test func walksThroughEveryStep() {
        var progress = HermesUpdateProgress()
        var lines = ["→ Checking for updates…"]
        progress.read(status(lines))
        #expect(progress.state(.check) == .done)
        #expect(progress.state(.drain) == .waiting)
        lines.append("  ⏳ Waiting up to 600s for in-flight turns on ai.hermes.gateway to finish before the update...")
        progress.read(status(lines))
        #expect(progress.state(.drain) == .active)
        lines.append("⏸ Paused for the update: ai.hermes.gateway")
        lines.append("Installing Python dependencies…")
        progress.read(status(lines))
        #expect(progress.state(.drain) == .done)
        #expect(progress.state(.install) == .active)
        lines.append("▶ Restarted paused gateway(s): ai.hermes.gateway")
        progress.read(status(lines))
        #expect(progress.state(.install) == .done)
        #expect(progress.state(.restart) == .active)
        lines.append("✓ Update complete! (v0.22.5 → v0.23.0)")
        progress.read(status(lines, running: false, exit: 0))
        #expect(progress.finished)
        #expect(progress.state(.restart) == .done)
        #expect(progress.state(.confirm) == .active)
    }

    @Test func theRestartGapMovesOnToRestart() {
        var progress = HermesUpdateProgress()
        progress.read(status(["⏸ Paused for the update: ai.hermes.gateway", "Installing Python dependencies…"]))
        #expect(progress.state(.drain) == .skipped)
        progress.unanswered()
        progress.unanswered()
        #expect(progress.sawGap)
        // Back, with the same lines: the gateway went down and came back, so it restarted.
        progress.read(status(["⏸ Paused for the update: ai.hermes.gateway", "Installing Python dependencies…"]))
        #expect(progress.state(.install) == .done)
        #expect(progress.state(.restart) == .active)
    }

    @Test func aGapBeforeTheInstallIsNotARestart() {
        var progress = HermesUpdateProgress()
        progress.read(status(["→ Checking for updates…"]))
        progress.unanswered()
        #expect(!progress.sawGap)
    }

    @Test func aFinalReceiptEndsTheRunWithoutAnExitCode() {
        var progress = HermesUpdateProgress()
        progress.read(status(["Installing"], running: false, receipt: #"{"outcome": "failed", "user_action": {"reason": "Fix the conflicts"}}"#))
        #expect(progress.finished)
        #expect(progress.exitCode == 1)
    }
}

struct HermesUpdateEndTests {
    private let ok = HermesUpdateReceipt(json: json(#"{"outcome": "success", "pre_sha": "a", "post_sha": "b", "post_version": "0.23.0"}"#))

    @Test func updatedOnlyWhenTheVersionChanged() {
        #expect(HermesUpdateEnd.gateway(exitCode: 0, receipt: ok, before: "0.22.5", after: "v0.23.0", lines: []) == .updated(to: "v0.23.0"))
        #expect(HermesUpdateEnd.gateway(exitCode: 0, receipt: ok, before: "0.22.5", after: "v0.22.5", lines: []) == .unchanged(version: "v0.22.5"))
        #expect(HermesUpdateEnd.gateway(exitCode: 0, receipt: ok, before: "0.22.5", after: nil, lines: []) == .unconfirmed)
    }

    @Test func noVersionBeforeTrustsOnlyAReceiptThatMoved() {
        #expect(HermesUpdateEnd.gateway(exitCode: 0, receipt: ok, before: nil, after: "0.23.0", lines: []) == .updated(to: "0.23.0"))
        #expect(HermesUpdateEnd.gateway(exitCode: 0, receipt: nil, before: nil, after: "0.23.0", lines: []) == .unconfirmed)
    }

    @Test func aFailureSaysWhy() {
        let lines = ["Installing", "✗ Update pulled new code, but restoring local changes hit conflicts.", "=== hermes-update failed ==="]
        #expect(HermesUpdateEnd.gateway(exitCode: 1, receipt: nil, before: "0.22.5", after: "0.22.5", lines: lines)
                == .failed(reason: "Update pulled new code, but restoring local changes hit conflicts."))
        let owed = HermesUpdateReceipt(json: json(#"{"outcome": "failed", "user_action": {"reason": "Install Node 22"}}"#))
        #expect(HermesUpdateEnd.gateway(exitCode: 1, receipt: owed, before: "0.22.5", after: nil, lines: lines) == .failed(reason: "Install Node 22"))
    }

    /// Audit 06-5: a run whose progress the gateway stopped reporting (no exit code) reads the version for the whole
    /// minute and a half; only a failure Hermes reported gives up after four reads.
    @Test func onlyAReportedFailureStopsReadingEarly() {
        #expect(!HermesUpdateEnd.stopsReading(attempt: 3, exitCode: nil))
        #expect(!HermesUpdateEnd.stopsReading(attempt: 17, exitCode: nil))
        #expect(!HermesUpdateEnd.stopsReading(attempt: 3, exitCode: 0))
        #expect(!HermesUpdateEnd.stopsReading(attempt: 2, exitCode: 1))
        #expect(HermesUpdateEnd.stopsReading(attempt: 3, exitCode: 1))
    }

    @Test func nousEndings() {
        #expect(HermesUpdateEnd.cloud(before: "0.22.5", after: "0.22.5") == .unchanged(version: "0.22.5"))
        #expect(HermesUpdateEnd.cloud(before: "0.22.5", after: "0.23.0") == .updated(to: "0.23.0"))
        #expect(HermesUpdateEnd.cloud(before: "0.22.5", after: nil) == .unconfirmed)
        #expect(HermesUpdateEnd.cloud(before: nil, after: "0.23.0") == .unconfirmed)
    }

    @Test func theNousUnchangedLine() {
        #expect(HermesUpdate.cloudUnchanged(name: "Research Bot", version: "v0.22.5")
                == "Nous restarted Research Bot on 0.22.5. Nous hasn’t released a newer Hermes yet.")
    }

    @Test func words() {
        #expect(HermesUpdateWords.versions(from: "v0.22.5", to: "0.23.0") == "0.22.5 → 0.23.0")
        #expect(HermesUpdateWords.list(["A", "B", "C"]) == "A, B and C")
        #expect(HermesUpdateWords.minutes(3900) == "1 hr 5 min")
        #expect(HermesUpdateWords.minutes(20) == "1 min")
    }

    @Test func latestOnlyWhenPortalOffersIt() {
        let agent = CloudField(name: "agent_id", title: "Agent", detail: "", choices: [], required: true, kind: .text)
        let image = CloudField(name: "image_version", title: "Version", detail: "", choices: ["latest", "0.22.5"], required: false, kind: .choice)
        #expect(CloudUpdateImage.latest([agent]).isEmpty)
        #expect(CloudUpdateImage.latest([agent, image]) == ["image_version": .string("latest")])
    }
}
