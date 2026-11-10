// JSON-RPC 2.0 framing on /api/ws (spec 01 §11): one JSON object per text frame. Pure and nonisolated, so frames are
// parsed off the main thread.

import Foundation

nonisolated enum RPCFrame: Sendable {
    /// `{"method":"event","params":{type, session_id, payload?, seq?}}`
    case event(GatewayEvent)
    /// A response to one of our integer-id requests.
    case result(id: Int, JSONValue)
    case failure(id: Int, RPCError)
    /// A response to a string-id request of ours (`heartbeat-<n>`), result or error alike.
    case stringAnswer(id: String)
    /// A server→client request (string id, method ≠ "event"). M1 (D1) never answers these.
    case serverRequest(id: String, method: String, params: JSONValue)
    /// An error with `id: null` (the server could not parse something we sent).
    case orphanError(RPCError)
    /// Empty, unparseable, or a shape we don't use.
    case ignored

    static func parse(_ text: String) -> RPCFrame { parse(Data(text.utf8)) }

    static func parse(_ data: Data) -> RPCFrame {
        guard !data.isEmpty, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .ignored }
        let method = object["method"] as? String
        if method == "event" {
            guard let params = object["params"] as? [String: Any], let event = event(from: params) else { return .ignored }
            return .event(event)
        }
        let id = object["id"]
        if let method {
            if let stringId = id as? String {
                return .serverRequest(id: stringId, method: method, params: JSONValue(foundation: object["params"] ?? NSNull()))
            }
            return .ignored // Client→server notifications are not used; numeric-id requests from the server don't exist.
        }
        if let number = id as? NSNumber, !number.isBool {
            if let error = object["error"] as? [String: Any] { return .failure(id: number.intValue, rpcError(error)) }
            return .result(id: number.intValue, JSONValue(foundation: object["result"] ?? NSNull()))
        }
        if let stringId = id as? String { return .stringAnswer(id: stringId) }
        if let error = object["error"] as? [String: Any] { return .orphanError(rpcError(error)) }
        return .ignored
    }

    /// An event's `params` object (a live frame's, or one element of `session.events.since`'s `events`).
    static func event(from params: [String: Any]) -> GatewayEvent? {
        guard let type = params["type"] as? String, !type.isEmpty else { return nil }
        let session = params["session_id"] as? String ?? ""
        var seq: Int?
        if let number = params["seq"] as? NSNumber, !number.isBool { seq = number.intValue }
        var event = GatewayEvent(type: type, sessionId: session, seq: seq, payload: JSONValue(foundation: params["payload"] ?? NSNull()))
        if let number = params["execution_generation"] as? NSNumber, !number.isBool { event.generation = number.intValue }   // [authority]
        return event
    }

    static func event(from params: JSONValue) -> GatewayEvent? {
        guard let object = params.object, let type = object["type"]?.string, !type.isEmpty else { return nil }
        var event = GatewayEvent(type: type, sessionId: object["session_id"]?.string ?? "", seq: object["seq"]?.int,
                                 payload: object["payload"] ?? .null)
        event.generation = object["execution_generation"]?.int   // [authority]
        return event
    }

    private static func rpcError(_ error: [String: Any]) -> RPCError {
        let code = (error["code"] as? NSNumber)?.intValue ?? -32603
        let message = (error["message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Hermes RPC failed"
        return RPCError(code: code, message: message, data: error["data"].map(JSONValue.init(foundation:)))
    }

    // MARK: Outgoing

    /// `{"jsonrpc":"2.0","id":<id>,"method":<m>,"params":<object>}`; params that aren't an object are sent as `{}`.
    static func request(id: Int, method: String, params: JSONValue) -> String {
        encode(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": objectParams(params)])
    }

    static func request(id: String, method: String, params: JSONValue = [:]) -> String {
        encode(["jsonrpc": "2.0", "id": .string(id), "method": .string(method), "params": objectParams(params)])
    }

    private static func objectParams(_ params: JSONValue) -> JSONValue {
        if case .object = params { return params }
        return .object([:])
    }

    private static func encode(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Foundation JSON → JSONValue (faster than JSONDecoder for megabyte frames)

nonisolated extension JSONValue {
    init(foundation value: Any) {
        switch value {
        case let string as String: self = .string(string)
        case let number as NSNumber: self = number.isBool ? .bool(number.boolValue) : .number(number.doubleValue)
        case let object as [String: Any]: self = .object(object.mapValues { JSONValue(foundation: $0) })
        case let array as [Any]: self = .array(array.map { JSONValue(foundation: $0) })
        default: self = .null
        }
    }

    /// Parses JSON with JSONSerialization (fragments allowed). Throws on invalid JSON.
    static func parseFast(_ data: Data) throws -> JSONValue {
        JSONValue(foundation: try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }
}

nonisolated extension NSNumber {
    var isBool: Bool { CFGetTypeID(self) == CFBooleanGetTypeID() }
}
