// Answers to server→client requests (spec 1x §2.3): a JSON-RPC response with the request's string id and `result` or
// `error`, never a `method` key. Plus the `open_requests` interception of resume/activate/events.since results (§2.4).

import Foundation

nonisolated extension RPCFrame {
    /// `{"jsonrpc":"2.0","id":"srq-…","result":<result>}`.
    static func response(id: String, result: JSONValue) -> String {
        encodeAnswer(["jsonrpc": "2.0", "id": .string(id), "result": result])
    }

    /// `{"jsonrpc":"2.0","id":"srq-…","error":{"code":<code>,"message":<message>}}`.
    static func errorResponse(id: String, code: Int, message: String) -> String {
        encodeAnswer(["jsonrpc": "2.0", "id": .string(id),
                      "error": ["code": .number(Double(code)), "message": .string(message)]])
    }

    private static func encodeAnswer(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// `open_requests` re-delivery (spec 1x §2.4): what the connection yields, in order, before the caller of a
/// `session.resume` / `session.activate` / `session.events.since` sees its result. Pure, so it is unit-tested.
nonisolated enum OpenRequestsIntercept {
    static let methods: Set<String> = ["session.resume", "session.activate", "session.events.since"]

    /// One replayed `hq.server_request` per `open_requests` entry, then one `hq.open_requests`. `epoch` is the socket's.
    /// A result that isn't an object (an error answer never reaches here) yields nothing.
    static func events(method: String, params: JSONValue, result: JSONValue, epoch: Int) -> [GatewayEvent] {
        guard methods.contains(method), result.object != nil else { return [] }
        let session = result["session_id"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            ?? params["session_id"]?.string ?? ""
        guard !session.isEmpty else { return [] }
        var out: [GatewayEvent] = []
        var ids: [JSONValue] = []
        for item in result["open_requests"]?.array ?? [] {
            guard let id = item["id"]?.string, let requestMethod = item["method"]?.string else { continue }
            let requestParams = item["params"] ?? .object([:])
            let owner = requestParams["session_id"]?.string ?? session
            ids.append(.string(id))
            out.append(GatewayEvent(type: LocalEvent.serverRequest, sessionId: owner, seq: nil,
                                    payload: ["id": .string(id), "method": .string(requestMethod), "params": requestParams,
                                              "replayed": true, "epoch": .number(Double(epoch))]))
        }
        // [authority] A session authority's snapshot lists its shared questions as `prompts`: each comes back as the
        // `clarify.request` event that asked it, and their ids confirm or prune the ones on screen (approvals there are
        // read from `approval.pending`, as everywhere).
        var promptIds: [JSONValue]?
        if let prompts = result["prompts"]?.array {
            promptIds = []
            for prompt in prompts where prompt["kind"]?.string == "clarify" {
                guard let id = prompt["prompt_id"]?.string, !id.isEmpty else { continue }
                promptIds?.append(.string(id))
                out.append(GatewayEvent(type: "clarify.request", sessionId: session, seq: nil, payload: prompt))
            }
        }
        let pending = result["pending_approval"].flatMap { $0.object != nil ? $0 : nil } ?? .null
        var payload: JSONValue = ["session_id": .string(session), "ids": .array(ids), "pending_approval": pending,
                                  "method": .string(method), "epoch": .number(Double(epoch))]
        if let promptIds, case .object(var o) = payload { o["prompt_ids"] = .array(promptIds); payload = .object(o) }
        out.append(GatewayEvent(type: LocalEvent.openRequests, sessionId: session, seq: nil, payload: payload))
        return out
    }
}

/// [questions] The live client answers server requests on its current socket (LiveGatewayClient.swift).
extension LiveGatewayClient: ServerRequestAnswering {}
