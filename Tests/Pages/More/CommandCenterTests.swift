// Command Center (docs/spec/3x-morepages.md §15 acceptance 1): the lenient decoders against the stand-in gateway's
// answers (golden JSON from scripts/fixtures/morepages/actions.py), a trimmed "old gateway" variant and bad data; the
// exact queries and bodies; the action polling state machine, including failed reads while the gateway restarts.

import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

private nonisolated func json(_ text: String) -> JSONValue { try! JSONValue.parse(Data(text.utf8)) }

struct CommandCenterStatusTests {
    nonisolated static let golden = """
    {"version": "0.21.5", "release_date": "2026.10.01", "config_version": 17, "latest_config_version": 17, "can_update_hermes": true,
     "gateway_running": true, "gateway_state": "running", "gateway_pid": 4242, "gateway_updated_at": "2026-10-13T19:18:09-05:00",
     "gateway_exit_reason": null, "gateway_heartbeat_stale_s": null, "active_agents": 1, "active_sessions": 3,
     "hermes_home": "/home/hermes/.hermes", "overall": "degraded", "auth_required": true,
     "gateway_platforms": {"telegram": {"state": "connected", "updated_at": "2026-10-13T19:18:09-05:00"},
       "discord": {"state": "error", "updated_at": "2026-10-13T19:18:09-05:00", "error_message": "Login failed: the bot token was refused."},
       "slack": {"state": "disconnected", "updated_at": "2026-10-13T19:18:09-05:00"}}}
    """

    @Test func decodesTheGatewaysStatus() {
        let status = GatewayStatusReport(json: json(Self.golden))
        #expect(status.versionWords == "Hermes 0.21.5")
        #expect(status.gatewayWords == "Running")
        #expect(status.sessionsWords == "3")
        #expect(status.canUpdate)
        #expect(status.platforms.map(\.name) == ["Discord", "Slack", "Telegram"])
        #expect(status.platforms.map(\.words) == ["Error", "Disconnected", "Connected"])
        #expect(status.platforms[0].error == "Login failed: the bot token was refused.")
        #expect(status.platforms[0].isDown && !status.platforms[0].isUp)
        #expect(status.platforms[2].isUp)
    }

    @Test func aTrimmedOldGatewayStillReads() {
        let status = GatewayStatusReport(json: json(#"{"version": "0.19.0", "gateway_running": false, "active_sessions": "2"}"#))
        #expect(status.versionWords == "Hermes 0.19.0")
        #expect(status.gatewayWords == "Stopped")
        #expect(status.sessionsWords == "2")
        #expect(status.platforms.isEmpty)
        #expect(status.canUpdate, "an older gateway has no can_update_hermes: the update check decides")
    }

    @Test(arguments: ["{}", "[]", "null", "7", #""text""#, #"{"version": null, "gateway_running": "yes", "active_sessions": {}, "gateway_platforms": []}"#,
                      #"{"version": 21, "gateway_platforms": {"": {"state": "x"}, "sms": "connected", "api_server": {"state": 3}, "x": null}}"#])
    func badDataNeverCrashes(_ text: String) {
        let status = GatewayStatusReport(json: json(text))
        #expect(status.gatewayWords == "—")
        #expect(status.sessionsWords == "—")
        if text.contains("sms") {
            #expect(status.versionWords == "Hermes 21")
            #expect(status.platforms.map(\.name) == ["API Server", "SMS", "X"])
            #expect(status.platforms.map(\.words) == ["3", "Connected", "—"])
        } else {
            #expect(status.versionWords == "—")
            #expect(status.platforms.isEmpty)
        }
    }

    @Test func platformNamesAndStates() {
        #expect(GatewayStatusReport.platformName("whatsapp") == "WhatsApp")
        #expect(GatewayStatusReport.platformName("home_assistant") == "Home Assistant")
        #expect(GatewayStatusReport.platformName("matrix") == "Matrix")
        #expect(GatewayStatusReport.stateWords("retrying") == "Connecting…")
        #expect(GatewayStatusReport.stateWords("rate_limited") == "Rate limited")
        #expect(GatewayStatusReport.stateWords("") == "—")
    }
}

struct CommandCenterUpdateCheckTests {
    @Test func words() {
        let behind3 = HermesUpdateCheck(json: json(#"{"install_method":"git","current_version":"0.21.5","behind":3,"update_available":true,"can_apply":true,"update_command":"hermes update","message":null,"commits":[{"sha":"abc1230","summary":"x","author":"y","at":1}]}"#))
        #expect(behind3.words == "3 Updates Available")
        #expect(behind3.canUpdateNow)
        #expect(HermesUpdateCheck(json: json(#"{"behind":1,"update_available":true,"can_apply":true}"#)).words == "1 Update Available")
        let current = HermesUpdateCheck(json: json(#"{"behind":0,"update_available":false,"can_apply":true,"message":"You're on the latest version."}"#))
        #expect(current.words == "Up to Date")
        #expect(!current.canUpdateNow)
        #expect(HermesUpdateCheck(json: json(#"{"behind":-1,"update_available":true,"can_apply":true}"#)).words == "Update Available")
        let unknown = HermesUpdateCheck(json: json(#"{"behind":null,"update_available":false,"can_apply":true,"message":"Couldn't reach the update source — try again later."}"#))
        #expect(unknown.words == "Couldn’t Check")
        #expect(!unknown.canUpdateNow)
        #expect(unknown.couldNotCheck, "an answer whose check couldn't run offers Check Again")
        #expect(!current.couldNotCheck)
        #expect(!behind3.couldNotCheck)
        let docker = HermesUpdateCheck(json: json(#"{"install_method":"docker","behind":"2","update_available":true,"can_apply":false,"message":"Pull the new image."}"#))
        #expect(docker.words == "2 Updates Available")
        #expect(!docker.canUpdateNow, "only an in-place install can be updated from the phone")
        #expect(docker.message == "Pull the new image.")
        for bad in ["{}", "[]", "null", #"{"behind":{},"can_apply":"yes","message":""}"#] {
            let check = HermesUpdateCheck(json: json(bad))
            #expect(check.words == "Couldn’t Check")
            #expect(!check.canUpdateNow)
            #expect(check.couldNotCheck)
            #expect(check.message == nil)
        }
    }
}

struct CommandCenterLogsTests {
    @Test func linesLoseTheirEndingsAndBadOnesAreSkipped() {
        let lines = LogLines.parse(json(#"{"file":"agent","lines":["a ERROR x\n","b\r\n",7,null,"", {"x":1}, "c"]}"#))
        #expect(lines == ["a ERROR x", "b", "", "c"])
        #expect(LogLines.parse(json("{}")).isEmpty)
        #expect(LogLines.parse(json(#"{"lines":"nope"}"#)).isEmpty)
        #expect(LogLines.parse(json("[]")).isEmpty)
    }

    @Test func levelOfALine() {
        #expect(LogLines.level(of: "2026-10-13 19:16:26,793 ERROR gateway.platforms.telegram: Tool terminal exited") == .error)
        #expect(LogLines.level(of: "2026-10-13 19:16:26,793 WARNING agent.loop: Slow provider answer") == .warning)
        #expect(LogLines.level(of: "2026-10-13 19:16:26,793 CRITICAL x: y") == .error)
        #expect(LogLines.level(of: "2026-10-13 19:16:26,793 INFO agent.loop: an ERROR in the message is not the level") == nil)
        #expect(LogLines.level(of: "Traceback (most recent call last):") == nil)
        #expect(LogLines.level(of: "") == nil)
        #expect(LogLines.level(of: String(repeating: "x", count: 4000)) == nil)
    }

    @Test func theLevelMenuSendsTheGatewaysOwnValues() {
        func query(_ level: LogLevelFilter) -> [String: String] {
            Dictionary(uniqueKeysWithValues: CommandCenterAPI.logsQuery(level: level).map { ($0.name, $0.value ?? "") })
        }
        #expect(query(.all) == ["file": "agent", "lines": "200"], "All leaves level out")
        #expect(query(.errors) == ["file": "agent", "lines": "200", "level": "ERROR"])
        #expect(query(.warnings) == ["file": "agent", "lines": "200", "level": "WARNING"])
        #expect(LogLevelFilter.allCases.map(\.title) == ["All", "Errors", "Warnings"])
    }
}

struct CommandCenterUsageTests {
    nonisolated static let golden = """
    {"daily": [{"input_tokens": 167271, "output_tokens": 17577, "cache_read_tokens": 55757, "reasoning_tokens": 3515, "estimated_cost": 0.7655,
                "actual_cost": 0, "sessions": 3, "api_calls": 18, "day": "2026-10-07"},
               {"input_tokens": 47826, "output_tokens": 7270, "cache_read_tokens": 15942, "reasoning_tokens": 1454, "estimated_cost": 0.2525,
                "actual_cost": 0, "sessions": 2, "api_calls": 10, "day": "2026-10-08"},
               {"input_tokens": 707895, "output_tokens": 76140, "cache_read_tokens": 235965, "reasoning_tokens": 15228, "estimated_cost": 3.2658,
                "actual_cost": 0, "sessions": 15, "api_calls": 90, "day": "2026-10-09"}],
     "by_model": [{"model": "hermes-4", "input_tokens": 572055, "output_tokens": 62611, "estimated_cost": 2.6559, "sessions": 12, "api_calls": 73},
                  {"model": "claude-opus-5", "input_tokens": 249117, "output_tokens": 27266, "estimated_cost": 1.1566, "sessions": 5, "api_calls": 31}],
     "by_task": [], "period_days": 7,
     "totals": {"total_input": 922992, "total_output": 100987, "total_cache_read": 307664, "total_reasoning": 20197,
                "total_estimated_cost": 4.2838, "total_actual_cost": 0, "total_sessions": 20, "total_api_calls": 118},
     "skills": {"summary": {"total_skill_loads": 6, "total_skill_edits": 0, "total_skill_actions": 6, "distinct_skills_used": 2},
                "top_skills": [{"skill": "release-notes", "view_count": 3, "manage_count": 1, "total_count": 4, "percentage": 66.7, "last_used_at": 1791900000.5},
                               {"skill": "inbox-triage", "view_count": 2, "manage_count": 0, "total_count": 2, "percentage": 33.3, "last_used_at": null}]},
     "tools": [{"tool": "terminal", "count": 120, "percentage": 60.0}]}
    """

    @Test func decodesTheGatewaysUsage() {
        let usage = UsageReport(json: json(Self.golden), asked: 30)
        #expect(usage.periodDays == 7)
        #expect(usage.tokens == 1_023_979)
        #expect(usage.sessions == 20)
        #expect(UsageFormat.cost(usage.cost) == "$4.28")
        #expect(usage.daily.map(\.id) == ["2026-10-07", "2026-10-08", "2026-10-09"])
        #expect(usage.daily.map(\.tokens) == [184_848, 55_096, 784_035])
        #expect(usage.models.map(\.id) == ["hermes-4", "claude-opus-5"])
        #expect(usage.models[0].tokens == 634_666)
        #expect(usage.skills == [.init(id: "release-notes", count: 4), .init(id: "inbox-triage", count: 2)])
        #expect(!usage.isEmpty)
        #expect(usage.chartSummary().hasPrefix("Daily tokens, 3 days. Most on October 9: 784K."))
    }

    @Test func aTrimmedOldGatewayStillReads() {
        // No skills, no tools, totals as text or null, a day without a date, a model without a name, a number as text.
        let usage = UsageReport(json: json("""
        {"daily": [{"day": "2026-10-09", "input_tokens": "1200", "output_tokens": 300, "sessions": 1}, {"sessions": 1},
                   {"day": "2026-10-09", "input_tokens": 9}, {"day": "soon"}, "x", null],
         "by_model": [{"model": "hermes-4", "input_tokens": null, "output_tokens": "1200"}, {"sessions": 2}, {"model": "hermes-4"}, 4],
         "totals": {"total_input": "1200", "total_output": null, "total_sessions": "1"}}
        """), asked: 30)
        #expect(usage.periodDays == 30, "the asked period when the answer names none")
        #expect(usage.tokens == 1200)
        #expect(usage.sessions == 1)
        #expect(UsageFormat.cost(usage.cost) == "—")
        #expect(usage.daily.map(\.tokens) == [1500], "a day with no date, a repeated day and a bad date are skipped")
        #expect(usage.models == [.init(id: "hermes-4", tokens: 1200, sessions: nil, cost: nil)])
        #expect(usage.skills.isEmpty)
    }

    @Test func nobodyUsedItYet() {
        let usage = UsageReport(json: json("""
        {"daily": [], "by_model": [], "period_days": 90, "skills": {"summary": {}, "top_skills": []},
         "totals": {"total_input": null, "total_output": null, "total_estimated_cost": 0, "total_sessions": 0, "total_api_calls": null}}
        """), asked: 90)
        #expect(usage.isEmpty)
        #expect(usage.tokens == nil)
        #expect(UsageFormat.compact(usage.tokens) == "—")
        #expect(usage.chartSummary() == "Daily tokens, 0 days")
    }

    @Test(arguments: ["{}", "[]", #"{"daily": {}, "by_model": "x", "totals": [], "skills": 4}"#,
                      #"{"daily": [[1]], "totals": {"total_input": {}, "total_estimated_cost": "abc"}, "skills": {"top_skills": [{"skill": ""}, {"skill": 3}]}}"#])
    func badDataNeverCrashes(_ text: String) {
        let usage = UsageReport(json: json(text), asked: 7)
        #expect(usage.isEmpty)
        #expect(usage.periodDays == 7)
        #expect(usage.daily.isEmpty && usage.models.isEmpty && usage.skills.isEmpty)
    }

    @Test func numbersInWords() {
        #expect(UsageFormat.compact(0) == "0")
        #expect(UsageFormat.compact(950) == "950")
        #expect(UsageFormat.compact(1000) == "1K")
        #expect(UsageFormat.compact(12_340) == "12.3K")
        #expect(UsageFormat.compact(999_949) == "1000K")
        #expect(UsageFormat.compact(999_950) == "1M")
        #expect(UsageFormat.compact(1_234_567) == "1.2M")
        #expect(UsageFormat.compact(184_848) == "185K")
        #expect(UsageFormat.compact(2_500_000_000) == "2.5B")
        #expect(UsageFormat.cost(12.3456) == "$12.35")
        #expect(UsageFormat.cost(0.004) == "<$0.01")
        #expect(UsageFormat.cost(0) == "$0.00")
        #expect(UsageFormat.cost(.nan) == "—")
        #expect(UsageFormat.cost(nil) == "—")
        #expect(UsageFormat.cost(12_345.6) == "$12.3K")
        #expect(UsageFormat.sessions(1) == "1 session")
        #expect(UsageFormat.sessions(nil) == "—")
        #expect(UsageFormat.actions(1) == "1 action")
        #expect(UsageFormat.actions(4) == "4 actions")
    }

    @Test func aDayIsReadInTheLocalCalendar() {
        let date = UsageReport.date("2026-10-09")
        #expect(date.map { Calendar.current.dateComponents([.year, .month, .day], from: $0) } == DateComponents(year: 2026, month: 10, day: 9))
        #expect(UsageReport.date("2026-13-01") == nil)
        #expect(UsageReport.date("") == nil)
        #expect(UsageReport.date("2026-10-09T10:00:00") != nil)
    }
}

struct CommandCenterAPITests {
    @Test func readsSendExactlyTheirKeys() async throws {
        let client = MoreFakeClient { request in
            switch request.path {
            case "/api/logs": return json(#"{"file":"agent","lines":["one\n","two\n"]}"#)
            case "/api/analytics/usage": return json(CommandCenterUsageTests.golden)
            case "/api/status": return json(CommandCenterStatusTests.golden)
            default: return json(#"{"behind":0,"update_available":false,"can_apply":true}"#)
            }
        }
        let api = CommandCenterAPI(client: client)
        #expect(try await api.status().versionWords == "Hermes 0.21.5")
        #expect(try await api.logs(level: .errors) == ["one", "two"])
        #expect(try await api.usage(days: 7).sessions == 20)
        #expect(try await api.updateCheck().words == "Up to Date")
        _ = try await api.updateCheck(force: true)
        #expect(client.logLines == ["GET /api/status", "GET /api/logs?file=agent&level=ERROR&lines=200", "GET /api/analytics/usage?days=7",
                                    "GET /api/hermes/update/check", "GET /api/hermes/update/check?force=true"])
    }

    @Test func aUsageAnswerThatIsNotAnObjectIsAFailure() async {
        let api = CommandCenterAPI(client: MoreFakeClient { _ in .array([]) })
        await #expect(throws: PagesMessageError.self) { _ = try await api.usage(days: 30) }
    }

    @Test func actionsPostWhatTheGatewayExpects() async throws {
        let client = MoreFakeClient { request in
            request.path == "/api/ops/backup" ? json(#"{"ok":true,"pid":9,"name":"backup","archive":"/x.zip"}"#) : json(#"{"ok":true,"pid":9}"#)
        }
        let actions = GatewayActionsAPI(client: client)
        #expect(try await MaintenanceAction.doctor.start(actions) == "doctor", "the fallback name when the answer names none")
        #expect(try await MaintenanceAction.securityAudit.start(actions) == "security-audit")
        #expect(try await MaintenanceAction.backup.start(actions) == "backup")
        #expect(client.logLines == ["POST /api/ops/doctor", "POST /api/ops/security-audit", "POST /api/ops/backup"])
        #expect(client.log.map(\.body) == [.object([:]), nil, .object([:])], "no output path is sent: the gateway picks its own backups folder")
        #expect(MaintenanceAction.allCases.map(\.title) == ["Run Doctor", "Security Audit", "Create Backup"])
    }

    @Test func aRefusedUpdateSaysTheGatewaysReason() async {
        let client = MoreFakeClient { _ in json(#"{"ok":false,"pid":null,"name":"hermes-update","error":"docker_update_unsupported","message":"Pull the new image."}"#) }
        do {
            _ = try await GatewayActionsAPI(client: client).update()
            Issue.record("a refused update must throw")
        } catch {
            #expect(PagesREST.reason(error) == "Pull the new image.")
        }
    }

    @Test func actionStatusIsLenient() {
        let running = GatewayActionStatus(json: json(#"{"name":"doctor","running":true,"exit_code":null,"pid":5,"lines":["a",1,null,"b"]}"#), fallbackName: "x")
        #expect(running == GatewayActionStatus(name: "doctor", running: true, exitCode: nil, lines: ["a", "1", "b"]))
        let done = GatewayActionStatus(json: json(#"{"exit_code":"1","lines":["oops",""," "]}"#), fallbackName: "doctor")
        #expect(done.name == "doctor" && !done.running && done.exitCode == 1 && done.lastLine == "oops")
        let empty = GatewayActionStatus(json: json("[]"), fallbackName: "doctor")
        #expect(empty.running && empty.lines.isEmpty, "no exit code and no running flag reads as still running")
    }
}

/// Answers scripted one read at a time; the last one repeats.
private nonisolated final class StatusScript: Sendable {
    enum Step: Sendable { case status(running: Bool, exit: Int?, lines: [String]), fail, notFound }
    private let steps: Mutex<[Step]>
    private let count = Mutex(0)
    init(_ steps: [Step]) { self.steps = Mutex(steps) }
    var reads: Int { count.withLock { $0 } }

    func next(_ name: String) throws -> GatewayActionStatus {
        count.withLock { $0 += 1 }
        let step = steps.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }
        switch step {
        case .fail: throw URLError(.networkConnectionLost)
        case .notFound: throw HTTPError(status: 404, body: "Not Found")
        case .status(let running, let exit, let lines): return GatewayActionStatus(name: name, running: running, exitCode: exit, lines: lines)
        }
    }
}

@MainActor
struct GatewayActionRunTests {
    private func run(_ script: StatusScript, patience: Duration = .seconds(30)) -> GatewayActionRun {
        let run = GatewayActionRun(status: { try script.next($0) })
        run.interval = .milliseconds(15)
        run.patience = patience
        return run
    }

    private func wait(_ seconds: Double = 5, until done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func aRestartRunsThroughFailedReadsToItsEnd() async {
        // The gateway restarts: the status answers, then nothing for a while (the link is down), then the end.
        let script = StatusScript([.status(running: true, exit: nil, lines: ["Stopping gateway…"]), .fail, .fail, .fail,
                                   .status(running: true, exit: nil, lines: ["Stopping gateway…", "Starting gateway…"]),
                                   .status(running: false, exit: 0, lines: ["Stopping gateway…", "Starting gateway…", "✓ Gateway restarted", ""])])
        let run = run(script)
        var finished: [Bool] = []
        run.onFinish = { finished.append($0) }
        run.start { "gateway-restart" }
        #expect(run.phase == .running && run.isBusy)
        #expect(GatewayRestart.words(run.phase)?.text == "Restarting…")
        await wait { !run.isBusy }
        #expect(run.phase == .finished(ok: true, lastLine: "✓ Gateway restarted"))
        #expect(GatewayRestart.words(run.phase)?.text == "Gateway Restarted")
        #expect(run.lines.count == 4)
        #expect(finished == [true])
        #expect(script.reads == 6, "failed reads are not the end")
    }

    @Test func linesAreKeptWhileReadsFail() async {
        let script = StatusScript([.status(running: true, exit: nil, lines: ["one"]), .fail])
        let run = run(script)
        run.start { "hermes-update" }
        await wait { script.reads >= 4 }
        #expect(run.phase == .running)
        #expect(run.lines == ["one"], "the last lines stay on screen through the drop")
        run.reset()
        #expect(run.phase == .idle && run.lines.isEmpty)
    }

    @Test func afterItsPatienceItSaysSoAndStillResolves() async {
        let script = StatusScript([.fail, .fail, .fail, .fail, .fail, .fail, .status(running: false, exit: 0, lines: ["✓ Gateway restarted"])])
        let run = run(script, patience: .milliseconds(40))
        run.start { "gateway-restart" }
        await wait { run.phase == .stalled }
        #expect(run.phase == .stalled && run.isBusy)
        #expect(GatewayRestart.words(run.phase)?.text == "Still restarting. This page updates when your gateway is back.")
        await wait { !run.isBusy }
        #expect(run.phase == .finished(ok: true, lastLine: "✓ Gateway restarted"))
    }

    @Test func aStatusRouteNotFoundIsSaidOnceAndNotPolled() async {
        // Stress test 2026-10-28 #10: a Hermes without the status route answered 404 to every read, polled into
        // "Still restarting". The first 404 ends the poll with words saying it can't be followed.
        let script = StatusScript([.notFound])
        let run = run(script, patience: .milliseconds(40))
        var finished: [Bool] = []
        run.onFinish = { finished.append($0) }
        run.start { "gateway-restart" }
        await wait { !run.isBusy }
        #expect(run.phase == .untracked)
        let words = GatewayRestart.words(run.phase)
        #expect(words?.text == GatewayRestart.untrackedText && words?.isError == false && words?.isBusy == false)
        let reads = script.reads
        try? await Task.sleep(for: .milliseconds(100))
        #expect(script.reads == reads && reads == 1, "no more reads after the 404")
        #expect(finished.isEmpty, "its end is unknown: no success or failure")
    }

    @Test func anActionNotRegisteredYetIsNotItsEnd() async {
        // Before the process is registered the status says "not running, no exit code": that is not a finished action.
        let script = StatusScript([.status(running: false, exit: nil, lines: []), .status(running: false, exit: nil, lines: []),
                                   .status(running: true, exit: nil, lines: ["🩺 Hermes Doctor"]),
                                   .status(running: false, exit: 1, lines: ["🩺 Hermes Doctor", "Found 1 issue(s) to address."])])
        let run = run(script)
        var finished: [Bool] = []
        run.onFinish = { finished.append($0) }
        run.start { "doctor" }
        await wait { !run.isBusy }
        #expect(run.phase == .finished(ok: false, lastLine: "Found 1 issue(s) to address."))
        #expect(ActionWords.maintenance(run.phase) == ActionWords(text: "Finished with Problems", isError: true))
        #expect(finished == [false])
        #expect(script.reads == 4)
    }

    @Test func anUpdateThatLosesItsExitCodeAfterRunningIsStillItsEnd() async {
        // The update restarts the dashboard, which forgets the process: "not running", no exit code, after it was seen running.
        let script = StatusScript([.status(running: true, exit: nil, lines: ["→ Fetching origin…"]), .fail,
                                   .status(running: false, exit: nil, lines: ["→ Fetching origin…", "✓ Hermes updated to 0.22.0"])])
        let run = run(script)
        run.start { "hermes-update" }
        await wait { !run.isBusy }
        #expect(run.phase == .finished(ok: true, lastLine: "✓ Hermes updated to 0.22.0"))
        #expect(ActionWords.update(run.phase)?.text == "Hermes Updated")
    }

    @Test func aStartThatFailsNeverPolls() async {
        let script = StatusScript([.fail])
        let run = run(script)
        var finished: [Bool] = []
        run.onFinish = { finished.append($0) }
        run.start { throw PagesMessageError("Hermes is managed by Docker here.") }
        await wait { !run.isBusy }
        #expect(run.phase == .failed("Hermes is managed by Docker here."))
        #expect(ActionWords.update(run.phase) == ActionWords(text: "Hermes is managed by Docker here.", isError: true))
        #expect(GatewayRestart.words(run.phase)?.isError == true)
        #expect(finished == [false])
        #expect(script.reads == 0)
    }

    @Test func aSecondStartWhileBusyIsIgnored() async {
        let script = StatusScript([.status(running: true, exit: nil, lines: []), .status(running: true, exit: nil, lines: []),
                                   .status(running: false, exit: 0, lines: ["done"])])
        let run = run(script)
        let starts = Mutex(0)
        for _ in 0..<5 { run.start { starts.withLock { $0 += 1 }; return "gateway-restart" } }
        await wait { !run.isBusy }
        #expect(starts.withLock { $0 } == 1, "rapid taps restart once")
        #expect(run.phase == .finished(ok: true, lastLine: "done"))
        // After its end it can be started again.
        run.start { starts.withLock { $0 += 1 }; return "gateway-restart" }
        await wait { !run.isBusy }
        #expect(starts.withLock { $0 } == 2)
    }

    @Test func words() {
        #expect(ActionWords.update(.idle) == nil && ActionWords.maintenance(.idle) == nil)
        #expect(ActionWords.update(.running) == ActionWords(text: "Updating…", isBusy: true))
        #expect(ActionWords.update(.stalled)?.text == "Still updating. This page updates when your gateway is back.")
        #expect(ActionWords.update(.finished(ok: false, lastLine: "x")) == ActionWords(text: "The update didn’t finish.", isError: true))
        #expect(ActionWords.maintenance(.finished(ok: true, lastLine: nil)) == ActionWords(text: "Finished"))
        #expect(ActionWords.maintenance(.running) == ActionWords(text: "Running…", isBusy: true))
        #expect(ActionWords.tail(["=== hermes-update started ===", "a", "", "  ", "b", "c", "d", "e"], 3) == ["c", "d", "e"])
        #expect(ActionWords.tail([]) == [])
    }
}
