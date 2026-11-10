// [toolnow] The Bots and Sessions rows name the running step instead of "Working…" (owner, 2026-10-30: "Instead of
// working, I want to stream the current tool call"): "Reading package.json…" under Otto while its turn runs. Each chat's
// newest step comes from the socket's frames by the thinking row's rule (ToolNowRows.latest): named from its start,
// through the thinking after it, until the next step or the reply writes; gone when the turn ends. A turn with no step
// yet, or one writing its reply, keeps "Working…". Only chats this run hears (sent from here, or open) have frames.

import Foundation

nonisolated struct LiveSteps: Equatable {
    /// Runtime id → its newest step in a few words ("reading package.json", ToolNow.phrase).
    private(set) var byRuntime: [String: String] = [:]

    /// Folds one frame of its runtime's chat; true when that chat's words changed. `roster` names a bot a
    /// `message_agent` call writes to ("messaging Ivy", not its handle).
    mutating func handle(_ event: GatewayEvent, roster: [DeliveryMessages.Seat] = []) -> Bool {
        let runtime = event.sessionId
        guard !runtime.isEmpty else { return false }
        let p = event.payload
        switch event.type {
        case "tool.start":
            // A silent step (todo, a reaction) leaves the one before it named, as the thinking row does.
            guard let name = p["name"]?.nonEmptyString, !ToolPresentation.isSilent(name) else { return false }
            return set(runtime, Self.phrase(name, payload: p, roster: roster))
        case "message.delta":
            guard byRuntime[runtime] != nil, !LiveChatText.isBlank(p["text"]) else { return false }
            return set(runtime, nil)                                   // the reply writes
        case "message.start", "message.complete", "error", "session.interrupt":
            return set(runtime, nil)
        case "session.info":
            return p["running"]?.bool == false ? set(runtime, nil) : false
        default:
            return false
        }
    }

    /// The turn ended (heard another way, or its chat went): its words go.
    mutating func clear(_ runtime: String) -> Bool { set(runtime, nil) }

    mutating func reset() { byRuntime = [:] }

    /// "Reading package.json…": a step's words as a row's live line.
    static func line(_ phrase: String) -> String { phrase.prefix(1).uppercased() + phrase.dropFirst() + "…" }

    /// A `tool.start` frame's few words: its arguments as the chat reads them (`args`, `arguments`, else `args_text`).
    static func phrase(_ name: String, payload p: JSONValue, roster: [DeliveryMessages.Seat]) -> String {
        var args = Hydration.firstNonEmptyObject([p["args"], p["arguments"]])
        if args.isEmpty { args = ToolArgs.parse(p["args_text"]?.string) }
        if args.isEmpty, let context = p["context"]?.nonEmptyString { args["context"] = .string(context) }
        if name == BotDMs.tool, !roster.isEmpty, let target = args["target"]?.string {
            return "messaging " + ToolNow.short(BotDMs.sender(target, roster: roster).name)
        }
        return ToolNow.phrase(name, args: args)
    }

    private mutating func set(_ runtime: String, _ words: String?) -> Bool {
        guard byRuntime[runtime] != words else { return false }
        byRuntime[runtime] = words
        return true
    }
}

private nonisolated enum LiveChatText {
    /// A delta's text is empty or only spaces (a string, or the parts list some relays send).
    static func isBlank(_ value: JSONValue?) -> Bool {
        switch value {
        case .string(let s)?: return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .array(let items)?:
            return items.allSatisfy { item in
                let text = item.string ?? item["text"]?.string ?? item["output_text"]?.string ?? ""
                return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        default: return true
        }
    }
}
