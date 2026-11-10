// [context-window] A bot's context window, as Settings › Model › Context Window, Bot Info › Brain and the model panel's
// Context fact set it (owner 2026-11-01, after asking where max context was set: "If I have to ask you, then I'm sure
// others may not ever even find it"; it was one field among Main Model's, named "Main Model Context Window").
// Hermes' `model_context_length` (config.yaml's `model.context_length`; 0 = the model's own, which
// `GET /api/model/info` reports as `auto_context_length`). Hermes reads it as a chat starts, for the bot's default model
// only (a chat on another model keeps that model's own, agent_init `_context_route_mismatch`), and won't start a chat
// in a window under 64K (agent/model_metadata.py `MINIMUM_CONTEXT_LENGTH`).

import Foundation

nonisolated enum ContextWindow {
    static let key = "model_context_length"
    /// Hermes won't start a chat in a smaller window.
    static let minimum = 64_000
    /// The sizes offered, largest first.
    static let sizes = [1_000_000, 400_000, 256_000, 200_000, 128_000, 64_000]

    /// The sizes worth offering for a model whose own window is `own`: those under it (its own size is Automatic).
    /// All of them while it isn't known.
    static func sizes(below own: Int?) -> [Int] {
        guard let own, own > 0 else { return sizes }
        return sizes.filter { $0 < own }
    }

    /// The size a config value sets; nil for Automatic (0, missing or not a number).
    static func override(_ value: JSONValue?) -> Int? {
        guard let number = value?.double, number.isFinite, number >= 1 else { return nil }
        return Int(number)
    }

    /// "64K", "200K", "1M", "1.5M".
    static func label(_ tokens: Int) -> String { SessionInfoRows.count(tokens) }

    /// What a row naming the setting shows: "Automatic" or the size.
    static func summary(_ value: JSONValue?) -> String { override(value).map(label) ?? "Automatic" }

    /// A typed size: "300000", "300,000", "300K", "300k tokens", "1M", "1.5m". Nil when it isn't a number of tokens.
    static func parse(_ text: String) -> Int? {
        var typed = text.lowercased().filter { !$0.isWhitespace && $0 != "," && $0 != "_" }
        if typed.hasSuffix("tokens") { typed.removeLast(6) }
        var scale = 1.0
        if typed.hasSuffix("k") { scale = 1_000; typed.removeLast() } else if typed.hasSuffix("m") { scale = 1_000_000; typed.removeLast() }
        guard let number = Double(typed), number.isFinite, number > 0 else { return nil }
        let tokens = (number * scale).rounded()
        guard tokens <= 100_000_000 else { return nil }
        return Int(tokens)
    }

    /// A size over the model's own window is kept (it is how a model whose window was misreported is put right), with a
    /// word that a chat the model can't hold fails. Nil when it fits or the model's own isn't known.
    static func caution(_ tokens: Int?, own: Int?) -> String? {
        guard let tokens, let own, own > 0, tokens > own else { return nil }
        return "That’s more than the model’s own \(label(own)). If the model really can’t hold that much, long chats can fail before Hermes sums them up."
    }

    /// Why a typed size can't be saved, or nil when it can.
    static func problem(_ text: String) -> String? {
        guard let tokens = parse(text) else { return "Type a size, such as 300K." }
        return tokens < minimum ? "Hermes needs at least \(label(minimum))." : nil
    }
}
