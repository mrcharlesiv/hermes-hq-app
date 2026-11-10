// [authority] A model pick on a gateway-hosted Hermes (tester report 2026-11-07: "Can't change the model in an existing
// session (use_session_mutation_model)"): the revision-fenced `session.mutate` operation=model, not `config.set`.

import Foundation
import Testing
@testable import HermesHQNative

@MainActor @Suite("Menus · a model pick on the session authority", .serialized)
struct ModelMutationTests {
    nonisolated static let authorityReady: JSONValue = ["heartbeat": true, "replay_epoch": "fixture-epoch", "session_authority": true]

    /// The fixture chat on a gateway whose snapshot reads `revision` / `generation`.
    func fixture(authority: Bool = true, revision: Int = 4, generation: Int = 2) -> MenusFixtureChat {
        let f = MenusFixtureChat()
        if authority { f.client.setReady(Self.authorityReady) }
        f.client.onRest { path, _ in
            guard path.hasSuffix("/mutation-snapshot") else { return Data("{}".utf8) }
            return encodeJSON(["session_id": "x", "exists": true, "runtime_revision": .number(Double(revision)),
                               "runtime_generation": .number(Double(generation))])
        }
        f.script.on("config.set") { p, _ in
            if p["key"]?.string == "model" { throw RPCError(code: 4001, message: ModelMutation.refusal, data: ["reason": "use_session_mutation_model"]) }
            return ["value": p["value"] ?? ""]
        }
        return f
    }

    func mutations(_ f: MenusFixtureChat) -> [[String: JSONValue]] { f.params("session.mutate") }

    @Test func thePickIsASessionMutation() async {
        let f = fixture()
        f.script.on("session.mutate") { p, _ in ["session_id": p["session_id"] ?? "", "operation": "model", "model": "gpt-5.5", "revision": 5] }
        #expect(await f.switcher.switchModel(f.choice("gpt-5.5", "openai-codex")))
        let sent = try? #require(mutations(f).first)
        #expect(sent?["session_id"] == .string(f.rid1) && sent?["profile"] == "default")
        #expect(sent?["operation"] == "model")
        #expect(sent?["payload"] == ["model": "gpt-5.5", "provider": "openai-codex"])
        #expect(sent?["expected_revision"]?.int == 4 && sent?["expected_generation"]?.int == 2)
        #expect(UUID(uuidString: sent?["request_id"]?.string ?? "") != nil)
        #expect(f.params("config.set").allSatisfy { $0["key"] != "model" }, "the refused write is never sent to an authority")
        #expect(f.params("config.set").map { $0["key"] } == ["reasoning"], "reasoning still goes as config.set")
        #expect(f.session.modelState.model == "gpt-5.5" && f.session.modelState.provider == "openai-codex")
        #expect(f.ui.notices.contains("Model changed to GPT-5.5."))
        #expect(f.ui.failures.isEmpty)
    }

    @Test func aRefusedConfigWriteIsSentAgainAsTheMutation() async {
        let f = fixture(authority: false)
        f.script.on("session.mutate") { _, _ in ["operation": "model", "model": "claude-haiku-4-5"] }
        #expect(await f.switcher.switchModel(f.choice("claude-haiku-4-5", "anthropic")))
        #expect(f.params("config.set").filter { $0["key"] == "model" }.count >= 1)
        // The 4001 refusal first reads as a stale runtime (resume once, send once more), then goes as the mutation.
        #expect(mutations(f).first?["session_id"] == .string(f.rid2))
        #expect(f.session.modelState.model == "claude-haiku-4-5")
        #expect(f.ui.failures.isEmpty, "never shown as use_session_mutation_model")
    }

    @Test func aGuardedTargetAsksThenSendsTheOwnersToken() async {
        let f = fixture()
        f.script.on("session.mutate") { p, _ in
            if p["payload"]?["confirm"]?.string == "tok-1" { return ["operation": "model", "model": "claude-opus-4-5-20251101"] }
            return ["operation": "model", "status": "confirmation_required", "confirm_required": true, "confirm": "tok-1",
                    "confirm_message": "Opus costs more."]
        }
        #expect(await f.switcher.switchModel(f.choice("claude-opus-4-5-20251101", "anthropic")))
        #expect(f.ui.confirms == ["Opus costs more."])
        let sent = mutations(f)
        #expect(sent.count == 2)
        #expect(sent.first?["payload"]?["confirm"] == nil)
        #expect(sent.last?["payload"]?["confirm"] == "tok-1")
        #expect(f.session.modelState.model == "claude-opus-4-5-20251101")
    }

    @Test func aPickDuringAReplyIsForTheNextMessage() async {
        let f = fixture()
        f.script.on("session.mutate") { _, _ in ["operation": "model", "status": "deferred", "model": "claude-haiku-4-5"] }
        #expect(await f.switcher.switchModel(f.choice("claude-haiku-4-5", "anthropic")))
        #expect(f.ui.notices.last == "Haiku 4.5 will be used for your next message.")
        #expect(f.session.modelState.model == "claude-haiku-4-5")
    }

    @Test func aMovedChatIsSentAgainAtTheFencesTheRefusalNames() async {
        let f = fixture()
        f.script.on("session.mutate") { _, attempt in
            if attempt == 1 {
                throw RPCError(code: 4001, message: "revision_conflict",
                               data: ["reason": "revision_conflict", "revision": 9, "execution_generation": 3])
            }
            return ["operation": "model", "model": "claude-haiku-4-5"]
        }
        #expect(await f.switcher.switchModel(f.choice("claude-haiku-4-5", "anthropic")))
        let sent = mutations(f)
        #expect(sent.count == 2)
        #expect(sent.last?["expected_revision"]?.int == 9 && sent.last?["expected_generation"]?.int == 3)
        #expect(sent.first?["request_id"] != sent.last?["request_id"])
        #expect(f.ui.failures.isEmpty)
    }
}
