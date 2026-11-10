// [authority] A gateway-hosted Hermes (its own sign-in page, the browser Desktop, a Team Gateway) serves /api/ws from
// its session authority: `gateway.ready` says `session_authority: true` and `gateway/session_controls.py` answers, with
// a closed key set per verb (tester log 2026-11-06: every send "Invalid_params"; probed against Hermes v0.23.0):
//   - `prompt.submit` needs a request id (`submission_id`); the plain sidecar refuses that key as unknown (4000), so it
//     goes out only here. A caller names its own (one per send, so a retry replays the same admission rather than adding
//     a second turn); one is made here otherwise.
//   - `session.redirect` / `session.interrupt` / `approval.respond` name the running turn (`execution_generation`, from
//     the session's frames and snapshots); `approval.respond` names its prompt `prompt_id`, with no `request_id`/`all`.
//   - `session.activate` isn't served: `session.resume` takes the same params and answers the same snapshot.
//   - `session.create` takes the surface as `source: "gui"` (not "desktop"), a retry key as `request_id` (not
//     `idempotency_key`), and a room member's `room_plumbing` as `follow_profile_config` (the Hermes desktop app's
//     canonical adapter, `apps/desktop/src/api/canonical-protocol.ts` prepareCreate).

import Foundation

nonisolated enum AuthorityWire {
    /// Verbs that name the running turn on an authority socket.
    static let turnControls: Set<String> = ["session.redirect", "session.interrupt", "approval.respond"]

    /// The frame as this socket takes it: `generation` is the session's latest known turn (nil when none was seen).
    static func adapt(_ method: String, _ params: JSONValue, authority: Bool, generation: Int? = nil) -> (method: String, params: JSONValue) {
        guard var object = params.object else { return (method, params) }
        guard authority else {
            if method == "prompt.submit", object["submission_id"] != nil { object["submission_id"] = nil; return (method, .object(object)) }
            return (method, params)
        }
        switch method {
        case "prompt.submit":
            if object["submission_id"]?.string?.isEmpty ?? true { object["submission_id"] = .string(UUID().uuidString.lowercased()) }
        case "session.activate":
            return ("session.resume", params)
        case "session.create":
            if object.removeValue(forKey: "room_plumbing")?.bool == true { object["follow_profile_config"] = true }
            if let key = object.removeValue(forKey: "idempotency_key"), object["request_id"] == nil { object["request_id"] = key }
            object["source"] = "gui"
            object["cols"] = nil   // a terminal width the create contract doesn't take
            // Anything else stays, so a create the owner can't do (a branch's copied `messages`) is refused, never made empty.
        case "approval.respond":
            if object["prompt_id"] == nil, let request = object["request_id"] { object["prompt_id"] = request }
            object["request_id"] = nil
            object["all"] = nil
        default:
            break
        }
        if turnControls.contains(method), object["execution_generation"] == nil, let generation {
            object["execution_generation"] = .number(Double(generation))
        }
        return (method, .object(object))
    }

    /// The request id one send keeps through its retries.
    static func submissionId(for localId: String) -> JSONValue { .string("hq-" + localId) }
}
