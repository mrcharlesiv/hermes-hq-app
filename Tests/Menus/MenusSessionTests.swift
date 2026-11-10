// Model switching and the slash dispatcher against a scripted gateway (spec docs/spec/1x-menus.md §14.1 checks 6 and 9).

import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

/// Scripted RPC answers by method; every call is recorded by the fake client.
nonisolated final class MenusScript: Sendable {
    typealias Answer = @Sendable (_ params: JSONValue, _ attempt: Int) async throws -> JSONValue
    private let answers = Mutex<[String: Answer]>([:])
    private let counts = Mutex<[String: Int]>([:])

    func on(_ method: String, _ answer: @escaping Answer) { answers.withLock { $0[method] = answer } }

    func answer(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        let attempt = counts.withLock { c -> Int in c[method, default: 0] += 1; return c[method]! }
        guard let a = answers.withLock({ $0[method] }) else { return [:] }
        return try await a(params, attempt)
    }
}

/// A gate a scripted answer waits on until the test opens it.
nonisolated final class MenusGate: Sendable {
    private let open = Mutex(false)
    func release() { open.withLock { $0 = true } }
    func wait() async { while !open.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(5)) } }
}

@MainActor
final class MenusSwitchUI: ModelSwitchUI {
    var confirmAnswer = true
    var confirms: [String] = []
    var failures: [String] = []
    var notices: [String] = []
    func confirmModelChange(_ message: String) async -> Bool { confirms.append(message); return confirmAnswer }
    func modelChangeFailed(_ reason: String) { failures.append(reason) }
    func switchNotice(_ text: String, duration: TimeInterval?, spinner: Bool) { notices.append(text) }
    func hideSwitchNotice() { notices.append("<hidden>") }
}

@MainActor
struct MenusFixtureChat {
    let client = FakeGatewayClient()
    let script = MenusScript()
    let session: LiveChatSession
    let prefs: ModelPrefs
    let ui = MenusSwitchUI()
    let switcher: ModelSwitcher

    nonisolated static let options: JSONValue = ["model": "claude-sonnet-5", "provider": "anthropic", "providers": [
        ["slug": "anthropic", "name": "Anthropic", "models": ["claude-sonnet-5", "claude-opus-4-5-20251101", "claude-haiku-4-5"],
         "capabilities": ["claude-sonnet-5": ["fast": true, "reasoning": true, "can_disable_reasoning": true],
                          "claude-haiku-4-5": ["fast": false, "reasoning": false]]],
        ["slug": "openai-codex", "name": "ChatGPT or Codex Subscription (Experimental)", "aliases": ["codex"],
         "models": ["gpt-5.5", "gpt-5.5-fast", "gpt-5.5-mini"],
         "capabilities": ["gpt-5.5": ["fast": false, "reasoning": true, "can_disable_reasoning": false]]],
        ["slug": "moa", "name": "Mixture of Agents", "models": ["default"]],
    ]]

    /// Runtime ids and the account are unique per fixture: the catalog caches and the pending-switch set are app-wide.
    let rid1 = String(UUID().uuidString.prefix(8)).lowercased()
    let rid2 = String(UUID().uuidString.prefix(8)).lowercased()

    init() {
        let account = GatewayAccount(id: "menus-tests-\(UUID().uuidString)", baseURL: URL(string: "http://127.0.0.1:9729")!,
                                     kind: .password, username: "tester", label: "fixture")
        session = LiveChatSession(client: client, account: account, profile: "default", storedSessionId: "20261005_090000_menus001",
                                  title: "Trip planning", head: nil, cache: makeTempCache(), resolveSessionId: nil, frameMode: .manual)
        session.runtimeSessionId = rid1
        session.connection = .ready
        session.menus.modelState = ChatModelState(model: "claude-sonnet-5", provider: "anthropic")
        session.menus.runningPlaceholderAfter = .seconds(30)
        let defaults = UserDefaults(suiteName: "menus-session-\(UUID().uuidString)")!
        prefs = ModelPrefs(accountId: account.id, defaults: defaults)
        let context = ModelMenuContext(chat: session, prefs: prefs)
        switcher = ModelSwitcher(context: context, ui: ui)
        let script = self.script
        client.onCall { method, params in try await script.answer(method, params) }
        script.on("model.options") { _, _ in MenusFixtureChat.options }
        // The profile's own reasoning default (config.yaml unset → the gateway's "medium").
        script.on("config.get") { _, _ in ["value": "medium", "display": "show"] }
        let resumed = rid2
        script.on("session.resume") { _, _ in ["session_id": .string(resumed), "session_key": "20261005_090000_menus001",
                                               "info": ["model": "claude-sonnet-5", "provider": "anthropic"]] }
        ModelCatalogCache.shared.store(ModelOptions(json: Self.options), for: context.key)
    }

    var context: ModelMenuContext { switcher.context }

    func choice(_ id: String, _ provider: String) -> ModelChoice { context.describe(id: id, provider: provider) }

    func params(_ method: String) -> [[String: JSONValue]] { client.calls(method).map { $0.params.object ?? [:] } }
}

@MainActor @Suite("Menus · switching the model (spec 1x §5)", .serialized)
struct MenusSwitchTests {
    @Test func liveSwitchSendsExactParams() async {
        let f = MenusFixtureChat()
        f.script.on("config.set") { p, _ in
            p["key"]?.string == "model" ? ["key": "model", "value": "gpt-5.5", "confirm_required": false, "scope": "session"] : ["value": p["value"] ?? ""]
        }
        let ok = await f.switcher.switchModel(f.choice("gpt-5.5", "openai-codex"))
        #expect(ok)
        let sent = f.params("config.set")
        #expect(sent.first == ["key": "model", "session_id": .string(f.rid1), "value": "gpt-5.5 --provider openai-codex", "profile": "default"])
        #expect(f.session.modelState.model == "gpt-5.5" && f.session.modelState.provider == "openai-codex")
        #expect(f.ui.notices.first == "Switching to GPT-5.5…")
        #expect(f.ui.notices.contains("Model changed to GPT-5.5."))
        #expect(f.prefs.recents.map(\.id) == ["gpt-5.5", "claude-sonnet-5"])
        // gpt-5.5 can't turn reasoning off but reasons: the preset's effort (default medium) is sent; no Fast (caps.fast false).
        #expect(sent.dropFirst().map { $0["key"]?.string } == ["reasoning"])
        #expect(sent.dropFirst().first?["value"] == "medium")
        #expect(Set(sent.flatMap(\.keys)).isSubset(of: ["key", "value", "session_id", "profile", "confirm_expensive_model", "scope"]))
    }

    /// The model panel's Approvals (owner 2026-10-31): the bot's mode through config.set approvals.mode, shown at once and
    /// put back on a refusal; this chat's skip through config.set yolo; an older Hermes's mode read with config.get.
    @Test func approvalsFromThePanel() async {
        let f = MenusFixtureChat()
        f.script.on("config.set") { p, _ in ["key": p["key"] ?? "", "value": p["value"] ?? ""] }
        f.script.on("config.get") { p, _ in p["key"] == "approvals.mode" ? ["value": "smart"] : ["value": "medium"] }
        await f.switcher.loadApprovalMode()
        #expect(f.session.modelState.approvalMode == "smart")
        #expect(f.params("config.get").last == ["key": "approvals.mode", "session_id": .string(f.rid1), "profile": "default"])
        await f.switcher.loadApprovalMode()
        #expect(f.params("config.get").filter { $0["key"] == "approvals.mode" }.count == 1, "read once")
        try? await f.switcher.setApprovalMode("manual")
        #expect(f.params("config.set").last == ["key": "approvals.mode", "value": "manual", "session_id": .string(f.rid1), "profile": "default"])
        #expect(f.session.modelState.approvalMode == "manual")
        try? await f.switcher.setYolo(true)
        #expect(f.params("config.set").last == ["key": "yolo", "value": "1", "session_id": .string(f.rid1), "profile": "default"])
        #expect(f.session.modelState.yolo)
        f.script.on("config.set") { _, _ in throw RPCError(code: 4002, message: "unknown approval mode", data: nil) }
        await #expect(throws: (any Error).self) { try await f.switcher.setApprovalMode("off") }
        #expect(f.session.modelState.approvalMode == "manual", "a refused change goes back")
    }

    @Test func moaAddsSession() async {
        let f = MenusFixtureChat()
        _ = await f.switcher.switchModel(f.choice("default", "moa"), restorePreset: false)
        #expect(f.params("config.set").first?["value"] == "default --provider moa --session")
    }

    @Test func fastSiblingFromPreset() async {
        let f = MenusFixtureChat()
        f.prefs.setPreset(provider: "openai-codex", model: "gpt-5.5", ModelPreset(fast: true))
        _ = await f.switcher.switchModel(f.choice("gpt-5.5", "openai-codex"))
        #expect(f.params("config.set").first?["value"] == "gpt-5.5-fast --provider openai-codex")
        #expect(f.session.modelState.model == "gpt-5.5-fast")
    }

    @Test func confirmThenResend() async {
        let f = MenusFixtureChat()
        f.script.on("config.set") { p, _ in
            if p["key"]?.string != "model" { return ["value": p["value"] ?? ""] }
            if p["confirm_expensive_model"]?.bool == true { return ["key": "model", "value": "claude-opus-4-5-20251101"] }
            return ["key": "model", "confirm_required": true, "confirm_message": "Opus costs more.", "warning": "Opus costs more."]
        }
        f.ui.confirmAnswer = false
        #expect(await f.switcher.switchModel(f.choice("claude-opus-4-5-20251101", "anthropic")) == false)
        #expect(f.ui.confirms == ["Opus costs more."])
        #expect(f.params("config.set").count == 1)
        #expect(f.session.modelState.model == "claude-sonnet-5")
        #expect(f.prefs.recents.isEmpty)
        f.ui.confirmAnswer = true
        #expect(await f.switcher.switchModel(f.choice("claude-opus-4-5-20251101", "anthropic")))
        let models = f.params("config.set").filter { $0["key"] == "model" }
        #expect(models.count == 3)
        #expect(models.last?["confirm_expensive_model"] == true)
        #expect(models[1]["confirm_expensive_model"] == nil)
        #expect(f.session.modelState.model == "claude-opus-4-5-20251101")
    }

    @Test func deferredKeepsPaint() async {
        let f = MenusFixtureChat()
        f.script.on("config.set") { p, _ in p["key"]?.string == "model" ? ["key": "model", "value": "claude-haiku-4-5", "deferred": true] : [:] }
        #expect(await f.switcher.switchModel(f.choice("claude-haiku-4-5", "anthropic")))
        #expect(f.session.modelState.model == "claude-haiku-4-5")
        #expect(f.ui.notices.last == "Haiku 4.5 will be used for your next message.")
        // Haiku can't reason: no reasoning write after the switch.
        #expect(f.params("config.set").count == 1)
    }

    @Test func busySwitchOnOldGatewaysIsDeferred() async {
        let f = MenusFixtureChat()
        f.script.on("config.set") { p, _ in
            if p["key"]?.string == "model" { throw RPCError(code: 4009, message: "session busy — finish or stop the current turn before switching models", data: nil) }
            return [:]
        }
        #expect(await f.switcher.switchModel(f.choice("claude-haiku-4-5", "anthropic")))
        #expect(f.session.modelState.model == "claude-haiku-4-5")
        #expect(f.ui.notices.last == "Haiku 4.5 will be used for your next message.")
        #expect(f.ui.failures.isEmpty)
    }

    @Test func failureRollsBackAndReports() async {
        let f = MenusFixtureChat()
        f.script.on("config.set") { _, _ in
            throw RPCError(code: 5001, message: "Model switch to broken-model failed (fixture provider refused); staying on claude-sonnet-5.", data: nil)
        }
        #expect(await f.switcher.switchModel(f.choice("broken-model", "anthropic")) == false)
        #expect(f.session.modelState.model == "claude-sonnet-5")
        #expect(f.ui.failures == ["Model switch to broken-model failed (fixture provider refused); staying on claude-sonnet-5."])
        #expect(f.ui.notices.last == "<hidden>")
        #expect(f.prefs.recents.isEmpty)
    }

    @Test func secondPickWhilePendingSendsNothing() async {
        let f = MenusFixtureChat()
        let gate = MenusGate()
        f.script.on("config.set") { p, _ in
            if p["key"]?.string == "model" { await gate.wait() }
            return ["key": "model", "value": p["value"] ?? ""]
        }
        let first = Task { await f.switcher.switchModel(f.choice("gpt-5.5", "openai-codex"), restorePreset: false) }
        #expect(await waitUntil { ModelSwitcher.isPending(f.rid1) })
        #expect(await f.switcher.switchModel(f.choice("claude-haiku-4-5", "anthropic")) == false)
        // An end-of-turn session.info with the old model doesn't repaint the pick meanwhile.
        f.session.receive(GatewayEvent(type: "session.info", sessionId: f.rid1, seq: nil,
                                       payload: ["model": "claude-sonnet-5", "provider": "anthropic", "reasoning_effort": "low"]))
        #expect(f.session.modelState.model == "gpt-5.5")
        #expect(f.session.modelState.reasoningEffort == "low")
        gate.release()
        #expect(await first.value)
        #expect(f.params("config.set").count == 1)
        #expect(!ModelSwitcher.isPending(f.rid1))
    }

    @Test func staleRuntimeResumesOnceAndResendsOnce() async {
        let f = MenusFixtureChat()
        f.script.on("config.set") { _, attempt in
            if attempt == 1 { throw RPCError(code: 4001, message: "session not found", data: nil) }
            return ["key": "model", "value": "gpt-5.5"]
        }
        #expect(await f.switcher.switchModel(f.choice("gpt-5.5", "openai-codex"), restorePreset: false))
        let sent = f.params("config.set")
        #expect(sent.count == 2)
        #expect(sent[0]["session_id"]?.string == f.rid1 && sent[1]["session_id"]?.string == f.rid2)
        #expect(f.client.calls("session.resume").count == 1)
        // The resume's info (the old model) doesn't stay painted over the pick.
        #expect(f.session.runtimeSessionId == f.rid2)
        #expect(f.session.modelState.model == "gpt-5.5" && f.session.modelState.provider == "openai-codex")
        #expect(f.context.current().id == "gpt-5.5")
        // A Reasoning pick made now is saved for the new model, not the old one.
        #expect(await f.switcher.setReasoning("high"))
        #expect(f.prefs.preset(provider: "openai-codex", model: "gpt-5.5").effort == "high")
        #expect(f.prefs.preset(provider: "anthropic", model: "claude-sonnet-5").effort == nil)
    }

    @Test func staleRuntimeResumeInfoWaitsForTheSwitch() async {
        let f = MenusFixtureChat()
        let gate = MenusGate()
        f.script.on("config.set") { _, attempt in
            if attempt == 1 { throw RPCError(code: 4001, message: "session not found", data: nil) }
            await gate.wait()
            return ["key": "model", "value": "gpt-5.5"]
        }
        let run = Task { await f.switcher.switchModel(f.choice("gpt-5.5", "openai-codex"), restorePreset: false) }
        // Resumed under the new id, the resend in flight: the resume's info and an end-of-turn info leave the pick.
        #expect(await waitUntil { f.session.runtimeSessionId == f.rid2 && f.params("config.set").count == 2 })
        #expect(f.session.modelState.model == "gpt-5.5")
        f.session.receive(GatewayEvent(type: "session.info", sessionId: f.rid2, seq: nil,
                                       payload: ["model": "claude-sonnet-5", "provider": "anthropic"]))
        #expect(f.session.modelState.model == "gpt-5.5")
        gate.release()
        #expect(await run.value)
        #expect(!ModelSwitcher.isPending(chat: f.session))
    }

    @Test func noPresetUsesTheProfileDefault() async {
        let f = MenusFixtureChat()
        f.script.on("config.get") { p, _ in
            p["session_id"] == nil ? ["value": "high", "display": "show"] : ["value": "low", "display": "show"]
        }
        f.script.on("config.set") { p, _ in ["value": p["value"] ?? ""] }
        #expect(await f.switcher.switchModel(f.choice("claude-opus-4-5-20251101", "anthropic")))
        let reasoning = f.params("config.set").filter { $0["key"] == "reasoning" }
        #expect(reasoning.map { $0["value"] } == ["high"], "the profile's high, not Hermes' medium")
        // Read without a session id: the gateway then answers the profile's config.yaml.
        #expect(f.params("config.get") == [["key": "reasoning", "profile": "default"]])
        #expect(f.context.profileDefaultEffort == "high")
        // The menu's check mark falls back to it too when the chat reports no effort.
        f.session.menus.modelState.reasoningEffort = ""
        #expect(f.context.input().reasoningCurrent == "high")
        // A model with its own saved effort keeps it; the default is read once.
        f.prefs.setPreset(provider: "anthropic", model: "claude-sonnet-5", ModelPreset(effort: "low"))
        #expect(await f.switcher.switchModel(f.choice("claude-sonnet-5", "anthropic")))
        #expect(f.params("config.set").filter { $0["key"] == "reasoning" }.last?["value"] == "low")
        #expect(f.params("config.get").count == 1)
    }

    @Test func unreadableProfileDefaultLeavesReasoningAlone() async {
        let f = MenusFixtureChat()
        f.script.on("config.get") { _, _ in throw RPCError(code: 5000, message: "config unreadable (fixture)", data: nil) }
        f.script.on("config.set") { p, _ in ["value": p["value"] ?? ""] }
        #expect(await f.switcher.switchModel(f.choice("claude-opus-4-5-20251101", "anthropic")))
        #expect(f.params("config.set").map { $0["key"]?.string } == ["model"], "no guessed medium")
        #expect(f.ui.failures.isEmpty)
    }

    @Test func profileDefaultNormalised() {
        #expect(ModelNames.normalizeConfigEffort(" High ") == "high")
        #expect(ModelNames.normalizeConfigEffort(false) == "none")
        #expect(ModelNames.normalizeConfigEffort("disabled") == "none")
        #expect(ModelNames.normalizeConfigEffort("") == nil)
        #expect(ModelNames.normalizeConfigEffort(nil) == nil)
    }

    @Test func offlineAndLoadingFail() async {
        let f = MenusFixtureChat()
        f.session.connection = .offline(reason: "x")
        #expect(await f.switcher.switchModel(f.choice("gpt-5.5", "openai-codex")) == false)
        #expect(f.ui.failures == ["You’re offline."])
        f.session.connection = .ready
        f.session.runtimeSessionId = nil
        f.switcher.openingWait = .milliseconds(300)
        #expect(await f.switcher.switchModel(f.choice("gpt-5.5", "openai-codex")) == false)
        #expect(f.ui.failures.last == "This chat is still loading. Try again when it is ready.")
        #expect(f.client.calls("config.set").isEmpty)
    }

    /// [phone-logs] Hermes's terminal banner and settings lines leave the phone's "Change Model?" alert.
    @Test func theLargeContextWarningReadsPlainly() {
        let raw = "!!! LARGE CONTEXT MODEL SWITCH !!!\n\nThis session holds ~206,628 tokens of context.\nSwitching to claude-opus-5-5[1m] "
            + "makes the next reply re-read all of it uncached (providers key prompt caches per model) — a one-time full-price input cost."
            + "\n\nThreshold: model.switch_context_confirm_tokens (currently 100,000; 0 disables this check).\nConfirm only if you intend to switch now."
        #expect(ModelSwitchWording.plain(raw) == "This chat holds ~206,628 tokens of context.\nSwitching to claude-opus-5-5[1m] makes the "
            + "next reply read all of it again without the cache — a one-time full-price input cost.")
        #expect(ModelSwitchWording.plain("This model costs more.") == "This model costs more.")
        #expect(ModelSwitchWording.plain("") == "")
    }

    /// [phone-logs] A pick made while the chat is still opening waits for it and goes ahead (build 910's "still
    /// loading" 6 s after launch, a slow gateway resuming the chat).
    @Test func aPickWhileTheChatOpensWaitsForIt() async {
        let f = MenusFixtureChat()
        f.script.on("config.set") { p, _ in
            p["key"]?.string == "model" ? ["key": "model", "value": "gpt-5.5", "confirm_required": false, "scope": "session"] : ["value": p["value"] ?? ""]
        }
        f.session.runtimeSessionId = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            f.session.runtimeSessionId = f.rid1
        }
        #expect(await f.switcher.switchModel(f.choice("gpt-5.5", "openai-codex")) == true)
        #expect(f.ui.failures.isEmpty)
        #expect(f.params("config.set").first?["session_id"]?.string == f.rid1)
    }

    @Test func reasoningAndFast() async {
        let f = MenusFixtureChat()
        f.script.on("config.set") { p, _ in ["value": p["value"] ?? ""] }
        #expect(await f.switcher.setReasoning("high"))
        #expect(f.params("config.set").last == ["key": "reasoning", "value": "high", "session_id": .string(f.rid1), "profile": "default"])
        #expect(f.session.modelState.reasoningEffort == "high")
        #expect(f.prefs.preset(provider: "anthropic", model: "claude-sonnet-5").effort == "high")
        #expect(await f.switcher.setFast(true))
        #expect(f.params("config.set").last == ["key": "fast", "value": "fast", "session_id": .string(f.rid1), "profile": "default"])
        #expect(f.session.modelState.fast)
        // A failed write rolls the value and the preset back.
        f.script.on("config.set") { _, _ in throw RPCError(code: 4002, message: "unknown reasoning value: zz", data: nil) }
        #expect(await f.switcher.setReasoning("zz") == false)
        #expect(f.session.modelState.reasoningEffort == "high")
        #expect(f.prefs.preset(provider: "anthropic", model: "claude-sonnet-5").effort == "high")
    }

    @Test func quickListFromContext() {
        let f = MenusFixtureChat()
        f.prefs.toggleFavorite(provider: "openai-codex", model: "gpt-5.5")
        let node = ModelMenuModel.build(f.context.input())
        #expect(node.subtitle == "Sonnet 5 · Medium")
        #expect(node.quick.map(\.title) == ["Sonnet 5", "GPT-5.5", "More Models…"])
        #expect(node.quick[1].subtitle == "ChatGPT or Codex Subscription")
        #expect(node.fast != nil)
        // Fast's sibling route on GPT-5.5 (no tier of its own, a -fast id listed).
        f.session.menus.modelState = ChatModelState(model: "gpt-5.5", provider: "openai-codex")
        let control = f.context.fastControl()
        #expect(control.supported && !control.on && control.variant?.sibling == "gpt-5.5-fast")
        #expect(ModelMenuModel.build(f.context.input()).reasoning?.items.first?.title == "Minimal")
    }
}

@MainActor @Suite("Menus · slash dispatcher (spec 1x §8)", .serialized)
struct MenusSlashTests {
    private func rows(_ f: MenusFixtureChat) -> [String] {
        f.session.messages.filter { SlashOutputRow.isSlashRow($0) }.map(\.plainText)
    }

    private func userBubbles(_ f: MenusFixtureChat) -> [String] {
        f.session.messages.filter { $0.role == .user }.map(\.plainText)
    }

    @Test func rpcStatusSaveAndFallback() async {
        let f = MenusFixtureChat()
        f.script.on("session.status") { _, attempt in
            if attempt == 2 { throw RPCError(code: -32601, message: "unknown method: session.status", data: nil) }
            return ["output": "Session 5cc537d1 · idle · claude-sonnet-5"]
        }
        f.script.on("session.save") { _, _ in ["file": "/fixture/sessions/x.json"] }
        f.script.on("slash.exec") { p, _ in ["output": .string("exec: \(p["command"]?.string ?? "")")] }
        await f.session.performSlash("/status", recordInput: true)
        await f.session.performSlash("/save", recordInput: true)
        await f.session.performSlash("/status", recordInput: true)
        #expect(rows(f) == ["slash:/status\nSession 5cc537d1 · idle · claude-sonnet-5", "slash:/save\nSaved transcript to /fixture/sessions/x.json",
                            "slash:/status\nexec: status"])
        #expect(f.params("session.status").first == ["session_id": .string(f.rid1), "profile": "default"])
        #expect(userBubbles(f).isEmpty)
    }

    @Test func execOutputsAndErrors() async {
        let f = MenusFixtureChat()
        f.script.on("slash.exec") { p, _ in
            switch p["command"]?.string ?? "" {
            case "usage": return ["output": "Usage: 12 calls\nContext: 31%", "warning": "estimated"]
            case "empty": return ["output": ""]
            case "fail": throw RPCError(code: 5030, message: "slash worker crashed (fixture)", data: nil)
            default: throw RPCError(code: 4018, message: "skill command: use command.dispatch", data: nil)
            }
        }
        f.script.on("command.dispatch") { p, _ in
            switch p["name"]?.string ?? "" {
            case "fail": throw RPCError(code: 5001, message: "not a quick/plugin/bundle/skill command: fail", data: nil)
            case "weird": return ["type": "nope"]
            default: throw RPCError(code: 4018, message: "something else broke", data: nil)
            }
        }
        await f.session.performSlash("/usage", recordInput: true)
        await f.session.performSlash("/empty", recordInput: true)
        await f.session.performSlash("/fail", recordInput: true)
        await f.session.performSlash("/weird", recordInput: true)
        await f.session.performSlash("/other", recordInput: true)
        #expect(rows(f) == ["slash:/usage\nwarning: estimated\nUsage: 12 calls\nContext: 31%", "slash:/empty\n/empty: no output",
                            "slash:/fail\nerror: /fail failed: slash worker crashed (fixture)",
                            "slash:/weird\nerror: invalid response: command.dispatch", "slash:/other\nerror: something else broke"])
        #expect(f.params("command.dispatch").first == ["name": "fail", "arg": "", "session_id": .string(f.rid1), "profile": "default"])
    }

    @Test func directives() async {
        let f = MenusFixtureChat()
        var prefills: [String] = []
        f.session.slashHooks.prefill = { prefills.append($0) }
        f.script.on("slash.exec") { p, _ in
            let line = p["command"]?.string ?? ""
            if line.hasPrefix("plan") { return ["type": "send", "message": "[plan] x", "display": "/plan x"] }
            if line.hasPrefix("goal") { return ["type": "send", "message": "ship it", "notice": "⊙ Goal set: ship it"] }
            if line == "undo" { return ["type": "prefill", "message": "last thing I said"] }
            if line == "ex" { return ["type": "exec"] }
            if line.hasPrefix("al") { return ["type": "alias", "target": "status"] }
            throw RPCError(code: 4018, message: "skill command: use command.dispatch for /gif-search", data: nil)
        }
        f.script.on("session.status") { _, _ in ["output": "fine"] }
        let body = "[IMPORTANT: The user has invoked the \"gif-search\" skill. The full skill content is loaded below.]\n\nbody\n\nThe user has provided the following instruction alongside the skill invocation: cats\n\n[Runtime note: fixture]"
        f.script.on("command.dispatch") { _, _ in ["type": "skill", "name": "gif-search", "message": .string(body)] }
        f.script.on("prompt.submit") { _, _ in ["status": "streaming", "user_row_id": 7] }
        await f.session.performSlash("/undo", recordInput: true)
        #expect(prefills == ["last thing I said"])
        await f.session.performSlash("/ex", recordInput: true)
        await f.session.performSlash("/al now", recordInput: true)
        await f.session.performSlash("/gif-search cats", recordInput: true)
        #expect(userBubbles(f) == ["/gif-search cats"])
        #expect(await waitUntil { !f.client.calls("prompt.submit").isEmpty })
        #expect(f.params("prompt.submit").first?["text"]?.string == body)
        #expect(rows(f) == ["slash:/ex\n(no output)", "fine"])
        // A reply is running now: /plan queues, with the notice; /goal's notice shows first.
        await f.session.performSlash("/plan x", recordInput: true)
        await f.session.performSlash("/goal ship it", recordInput: true)
        #expect(f.session.queuedMessages.map(\.text) == ["[plan] x", "ship it"])
        #expect(f.session.queuedMessages.map { $0.display ?? $0.text } == ["/plan x", "ship it"])
        #expect(rows(f).suffix(3) == ["slash:/plan\n\(SlashResults.queuedLine)", "slash:/goal\n⊙ Goal set: ship it",
                                      "slash:/goal\n\(SlashResults.queuedLine)"])
        #expect(f.session.removeQueued(f.session.queuedMessages[0].id) == "/plan x")
    }

    @Test func localDecisions() async {
        let f = MenusFixtureChat()
        var opened: [String] = []
        f.session.slashHooks.openModels = { opened.append("models:\($0 ?? "")") }
        f.session.slashHooks.openCommands = { opened.append("commands") }
        f.session.slashHooks.prefill = { opened.append("prefill:\($0)") }
        CommandsCatalogCache.shared.store(MenusCommandsTests.fixtureCatalog(), for: f.session.commandsCatalogKey, profile: "default")
        await f.session.performSlash("/model kimi", recordInput: true)
        await f.session.performSlash("/help", recordInput: true)
        await f.session.performSlash("/commands", recordInput: true)
        await f.session.performSlash("/branch", recordInput: true)
        await f.session.performSlash("/config", recordInput: true)
        await f.session.performSlash("/fast", recordInput: true)
        await f.session.performSlash("/ hello", recordInput: true)
        #expect(opened == ["models:kimi", "commands", "commands", "prefill:/ hello"])
        #expect(rows(f) == ["slash:/branch\n/branch isn't available in \(AppIdentity.current.displayName) yet.",
                            "slash:/config\n/config is only available in the terminal interface.",
                            "slash:/fast\n/fast is not shown in the desktop slash palette. Use the relevant desktop control or terminal interface instead.",
                            "empty slash command"])
        #expect(f.client.calls("slash.exec").isEmpty)
    }

    /// /new, /reset, /clear (docs/spec/3x-composer.md §8.2): the new-chat hook with the words after the command, no
    /// output row, nothing sent; without a way to open one, the one line.
    @Test func newChat() async {
        let f = MenusFixtureChat()
        var drafts: [String] = []
        f.session.slashHooks.newChat = { drafts.append($0); return true }
        await f.session.performSlash("/new", recordInput: true)
        await f.session.performSlash("/reset hello there", recordInput: true)
        await f.session.performSlash("/clear", recordInput: true)
        #expect(drafts == ["", "hello there", ""])
        #expect(rows(f).isEmpty)
        #expect(f.client.calls("slash.exec").isEmpty && f.client.calls("command.dispatch").isEmpty)
        f.session.slashHooks.newChat = { _ in false }
        await f.session.performSlash("/new", recordInput: true)
        #expect(rows(f) == ["slash:/new\n\(SlashResults.newChatFailed)"])
        #expect(!SlashCatalog.nativeUnsupported.contains("new") && !SlashCatalog.nativeUnsupported.contains("compress"))
    }

    /// /compress (§8.3): `session.compress` with the topic, the summary's lines as the row, the meter's usage follows.
    @Test func compress() async {
        let f = MenusFixtureChat()
        f.script.on("session.compress") { _, _ in
            ["status": "compressed", "removed": 40, "before_messages": 52, "after_messages": 12,
             "summary": ["headline": "Compressed: 52 → 12 messages", "token_line": "Approx request size: ~187,000 → ~21,000 tokens",
                         "noop": false, "aborted": false],
             "info": ["usage": ["input": 21000, "output": 10, "total": 21010, "context_used": 21000, "context_max": 400000]],
             "messages": []]
        }
        await f.session.performSlash("/compress", recordInput: true)
        await f.session.performSlash("/compact the login bug", recordInput: true)
        let params = f.params("session.compress")
        #expect(params.count == 2)
        #expect(params.first?["focus_topic"] == nil)
        #expect(params.last?["focus_topic"]?.string == "the login bug")
        #expect(params.allSatisfy { $0["session_id"]?.string == f.rid1 })
        let line = "Compressed: 52 → 12 messages\nApprox request size: ~187,000 → ~21,000 tokens"
        #expect(rows(f) == ["slash:/compress\n\(line)", "slash:/compact\n\(line)"])
        #expect(f.client.calls("slash.exec").isEmpty)
        #expect(!f.session.menus.compressing)
    }

    /// /compress's other answers and failures (§8.3 step 5-6), and the running row's words.
    @Test func compressAnswers() {
        #expect(SlashResults.compressing(topic: "") == "Compressing context…")
        #expect(SlashResults.compressing(topic: " login ") == "Compressing context for: login…")
        #expect(SlashResults.compressText(["status": "pending", "turn_isolation": true]) == SlashResults.compressPending)
        #expect(SlashResults.compressText(["compressed": false, "lock_held": true, "message": "Compression skipped: busy"])
                == "Compression skipped: busy")
        #expect(SlashResults.compressText(["status": "aborted", "summary": ["headline": "Compression aborted: 9 messages preserved",
                                                                           "aborted": true]])
                == "Compression aborted: 9 messages preserved")
        #expect(SlashResults.compressText(["status": "aborted"]) == "Compression was stopped.")
        #expect(SlashResults.compressText(["status": "compressed", "summary": ["headline": "No changes from compression: 3 messages",
                                                                              "token_line": "~1 tokens", "noop": true]])
                == "No changes from compression: 3 messages")
        #expect(SlashResults.compressText(["status": "compressed", "removed": 0]) == "Nothing to compress.")
        #expect(SlashResults.compressText(["status": "compressed", "host_ack": ["output": " Compressed on host \n"]]) == "Compressed on host")
        #expect(SlashResults.compressText(["status": "compressed", "removed": 1]) == "Compressed 1 message.")
        #expect(SlashResults.compressText(["status": "compressed", "removed": 7]) == "Compressed 7 messages.")
        #expect(SlashResults.compressError(RPCError(code: 4009, message: "busy", data: nil)) == SlashResults.compressWait)
        #expect(SlashResults.compressError(RPCError(code: 5005, message: "boom", data: nil)) == "Couldn’t compress: boom")
    }

    /// /compress while a reply runs says so and calls nothing; an old gateway (-32601) takes the exec path.
    @Test func compressBusyAndOldGateway() async {
        let f = MenusFixtureChat()
        f.session.menus.compressing = true
        await f.session.performSlash("/compress", recordInput: true)
        #expect(rows(f).isEmpty, "a second /compress while one is out is ignored")
        f.session.menus.compressing = false
        f.script.on("session.compress") { _, _ in throw RPCError(code: -32601, message: "method not found", data: nil) }
        f.script.on("slash.exec") { _, _ in ["output": "compressed via worker"] }
        await f.session.performSlash("/compress", recordInput: true)
        #expect(rows(f) == ["slash:/compress\ncompressed via worker"])
        #expect(f.params("slash.exec").first?["command"]?.string == "compress")
        #expect(f.client.calls("session.compress").count == 1)
    }

    @Test func actions() async {
        let f = MenusFixtureChat()
        var alerts: [String] = []
        f.session.slashHooks.alert = { title, message in alerts.append("\(title): \(message)") }
        f.script.on("config.set") { p, _ in
            if p["key"] == "yolo" { return ["key": "yolo", "value": p["value"] ?? "", "scope": "session"] }
            return ["value": p["value"] ?? ""]
        }
        f.script.on("config.get") { _, _ in ["value": "", "display": "show"] }
        f.script.on("session.title") { p, _ in ["pending": false, "title": p["title"] ?? ""] }
        f.script.on("process.stop") { _, _ in ["killed": 0] }
        f.script.on("session.interrupt") { _, _ in ["status": "interrupted"] }
        await f.session.performSlash("/yolo", recordInput: true)
        await f.session.performSlash("/yolo", recordInput: true)
        await f.session.performSlash("/reasoning", recordInput: true)
        await f.session.performSlash("/reasoning high --global", recordInput: true)
        await f.session.performSlash("/title Trip to Lisbon", recordInput: true)
        await f.session.performSlash("/stop", recordInput: true)
        #expect(rows(f) == ["slash:/yolo\nYOLO on for this session", "slash:/yolo\nYOLO off for this session",
                            "slash:/reasoning\nreasoning: medium · display show", "slash:/reasoning\nreasoning: high",
                            "slash:/title\nSession title set: Trip to Lisbon",
                            "slash:/stop\nStopped the active turn.\nNo background processes to stop."])
        #expect(f.session.title == "Trip to Lisbon")
        #expect(f.session.modelState.reasoningEffort == "high")
        #expect(f.params("config.set").first(where: { $0["key"] == "reasoning" }) == ["key": "reasoning", "value": "high", "scope": "global",
                                                                                     "session_id": .string(f.rid1), "profile": "default"])
        #expect(f.params("config.get").first == ["key": "reasoning", "session_id": .string(f.rid1), "profile": "default"])
        #expect(f.params("process.stop").first == ["session_id": .string(f.rid1), "profile": "default"])
        f.script.on("config.set") { _, _ in throw RPCError(code: 5000, message: "nope", data: nil) }
        await f.session.performSlash("/yolo", recordInput: true)
        #expect(alerts == ["YOLO: Couldn’t turn YOLO on or off."])
        #expect(rows(f).count == 6)
    }

    @Test func commandsCatalogFallsBackToThisProfilesList() async throws {
        let f = MenusFixtureChat()
        f.script.on("commands.catalog") { _, attempt in
            if attempt == 1 { return ["pairs": [["/status", "Show session info"]], "commands": ["/status": ["argument_mode": nil]]] }
            throw RPCError(code: 5020, message: "commands catalog failed (fixture)", data: nil)
        }
        let first = try await f.session.loadCommandsCatalog()
        #expect(first.pairs?.first?.0 == "/status")
        // A resumed chat (a new runtime id) whose read fails still has this profile's list.
        f.session.runtimeSessionId = "resumed-\(f.rid2)"
        let again = try await f.session.loadCommandsCatalog()
        #expect(again.pairs?.first?.0 == "/status")
        // Offline: the cached list at once, no call.
        f.session.runtimeSessionId = "offline-\(f.rid2)"
        f.session.connection = .offline(reason: "x")
        let calls = f.client.calls("commands.catalog").count
        let offline = try await f.session.loadCommandsCatalog()
        #expect(offline.pairs?.first?.0 == "/status")
        #expect(f.client.calls("commands.catalog").count == calls)
    }

    @Test func botChatKeepsItsTitle() async {
        let f = MenusFixtureChat()
        f.session.menus.isBotChat = true
        await f.session.performSlash("/title New name", recordInput: true)
        #expect(rows(f) == ["slash:/title\n\(SlashResults.botChatTitle)"])
        #expect(f.client.calls("session.title").isEmpty)
    }

    @Test func runningPlaceholderReplacedInPlace() async {
        let f = MenusFixtureChat()
        f.session.menus.runningPlaceholderAfter = .milliseconds(10)
        let gate = MenusGate()
        f.script.on("slash.exec") { _, _ in await gate.wait(); return ["output": "done"] }
        let run = Task { await f.session.performSlash("/usage", recordInput: true) }
        #expect(await waitUntil { rows(f) == ["slash:/usage\nRunning…"] })
        let id = f.session.messages.last?.id
        gate.release()
        await run.value
        #expect(rows(f) == ["slash:/usage\ndone"])
        #expect(f.session.messages.last?.id == id)
    }

    @Test func noRuntimeResumesFirstOrSaysSo() async {
        let f = MenusFixtureChat()
        f.session.runtimeSessionId = nil
        f.script.on("slash.exec") { _, _ in ["output": "ok"] }
        await f.session.performSlash("/version", recordInput: true)
        #expect(f.params("slash.exec").first?["session_id"]?.string == f.rid2)
        f.session.runtimeSessionId = nil
        f.script.on("session.resume") { _, _ in throw RPCError(code: 5000, message: "down", data: nil) }
        await f.session.performSlash("/version", recordInput: true)
        #expect(rows(f).last == "slash:/version\nerror: Couldn’t reach this chat.")
    }

    @Test func renameRpcThenRestFallback() async {
        let f = MenusFixtureChat()
        var rowTitles: [String?] = []
        f.session.menus.onTitleApplied = { rowTitles.append($0) }
        f.script.on("session.title") { p, _ in
            if p["title"] == "Taken" { throw RPCError(code: 4022, message: "Title 'Taken' is already in use", data: nil) }
            return ["pending": false, "title": p["title"] ?? ""]
        }
        f.client.onRest { path, _ in
            if path.hasSuffix("/mutation-snapshot") { return Data(#"{"session_id":"20261005_090000_menus001","exists":true,"runtime_revision":4,"runtime_generation":1}"#.utf8) }
            throw HTTPError(status: 400, body: "{\"detail\":\"Title 'Taken' is already in use\"}")
        }
        let stored = try? await f.session.rename(to: "Trip to Lisbon")
        #expect(stored == "Trip to Lisbon")
        #expect(f.session.title == "Trip to Lisbon")
        do {
            try await f.session.rename(to: "Taken")
            Issue.record("Taken should fail")
        } catch {
            #expect(MenusError.text(error) == "Title 'Taken' is already in use")
        }
        #expect(f.session.title == "Trip to Lisbon")
        #expect(rowTitles == ["Trip to Lisbon", "Trip to Lisbon", "Taken", "Trip to Lisbon"])
        let rest = f.client.restLog.last
        #expect(rest?.path == "/api/sessions/20261005_090000_menus001")
        #expect(rest?.query.first?.name == "profile")
    }
}
