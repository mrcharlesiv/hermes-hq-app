// [authority] A model pick on a gateway-hosted Hermes's session authority (Hermes 0.23+; tester report 2026-11-07:
// "Can't change the model in an existing session (use_session_mutation_model)"). The owner refuses the picker's
// `config.set key=model` by name (`gateway/session_busy_controls.py`): a pick is the revision-fenced
//
//     session.mutate {session_id, request_id, expected_revision, expected_generation, operation: "model",
//                     payload: {model, provider[, confirm]}}
//
// (the Hermes desktop app's `canonical-protocol.ts` `pickerModelMutation`). The fences are the chat's row as
// `GET /api/sessions/{id}/mutation-snapshot` reads it (the owner's runtime id is its stored id). Its answer is put in
// `config.set`'s shape so `ModelSwitcher` reads one: `confirm_required` + `confirm_message` for a guarded target (the
// owner's one-time `confirm` token is kept here for the confirmed resend), `deferred` for a pick made while a turn
// runs (the next turn takes it).

import Foundation

nonisolated enum ModelMutation {
    static let refusal = "use_session_mutation_model"

    /// The owner's refusal of `config.set key=model`.
    static func isRefusal(_ error: any Error) -> Bool {
        guard let error = error as? RPCError else { return false }
        return error.message == refusal || error.data?["reason"]?.string == refusal
    }

    /// This socket's `gateway.ready` named the session authority: a pick goes straight to `session.mutate`.
    static func isAuthority(_ client: any GatewayClient) -> Bool { client.latestReady?["session_authority"]?.bool == true }

    /// Tokens of guarded targets the owner asked about, by account, chat and target; spent by the confirmed resend.
    private static let tokens = Locked<[String: String]>([:])

    private static func tokenKey(_ client: any GatewayClient, session: String, model: String, provider: String) -> String {
        [client.account.id, session, provider, model].joined(separator: "\u{1F}")
    }

    /// One pick of `model` from `provider` for the chat `session` (its runtime id), in `config.set`'s answer shape.
    static func send(_ client: any GatewayClient, session: String, profile: String?, model: String, provider: String,
                     confirmed: Bool, timeout: Duration) async throws -> JSONValue {
        let key = tokenKey(client, session: session, model: model, provider: provider)
        var payload: [String: JSONValue] = ["model": .string(model)]
        if !provider.isEmpty { payload["provider"] = .string(provider) }
        if confirmed, let token = tokens.value[key] { payload["confirm"] = .string(token) }
        guard case .identity(var fences) = try await SessionWrite.snapshot(client, id: session, profile: profile),
              fences.generation != nil else {
            throw MenusError("This chat isn’t ready for a model change yet. Try again in a moment.")
        }
        for attempt in 0..<2 {
            var params: [String: JSONValue] = [
                "session_id": .string(session), "request_id": .string(fences.requestId),
                "expected_revision": .number(Double(fences.revision)), "operation": "model", "payload": .object(payload),
            ]
            if let generation = fences.generation { params["expected_generation"] = .number(Double(generation)) }
            if let profile { params["profile"] = .string(profile) }
            do {
                let answer = try await client.call("session.mutate", .object(params), timeout: timeout)
                if payload["confirm"] != nil { tokens.mutate { $0[key] = nil } }
                return reshaped(answer, key: key)
            } catch let error as RPCError where attempt == 0 && isFenceRefusal(error) {
                // Another client (or a turn) moved the chat on: the refusal names the fences now. A value pick is
                // harmless to send again at them.
                guard let revision = error.data?["revision"]?.int else { throw error }
                fences = SessionWrite.Identity(requestId: UUID().uuidString.lowercased(), revision: revision,
                                               generation: error.data?["execution_generation"]?.int ?? fences.generation)
                AppLog.trace("menus", "model pick on \(AppLog.tag(session)): \(error.message), sent again at revision \(revision)")
            } catch let error as RPCError {
                if payload["confirm"] != nil { tokens.mutate { $0[key] = nil } }   // answered: the token is spent
                throw error
            }
        }
        throw RPCError(code: 4001, message: "revision_conflict", data: nil)
    }

    static func isFenceRefusal(_ error: RPCError) -> Bool {
        let reason = error.data?["reason"]?.string ?? error.message
        return reason == "revision_conflict" || reason == "stale_generation"
    }

    /// The owner's receipt as `config.set` answered: a guard keeps its token and asks; a deferred pick says so.
    private static func reshaped(_ answer: JSONValue, key: String) -> JSONValue {
        guard var object = answer.object else { return answer }
        switch object["status"]?.string {
        case "confirmation_required":
            if let token = object["confirm"]?.string { tokens.mutate { $0[key] = token } }
            object["confirm_required"] = true
        case "deferred":
            object["deferred"] = true
        default:
            break
        }
        object["ok"] = true
        return .object(object)
    }
}
