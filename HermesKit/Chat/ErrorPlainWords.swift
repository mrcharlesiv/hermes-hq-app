// [error-words] Owner 2026-11-10 (design pick 7): the Error Details sheet says what happened in plain words before the
// raw text. The raw text is whatever Hermes or the provider reported, so the words are chosen from what it contains;
// anything not recognised says only that something went wrong and points at the details underneath.

import Foundation

nonisolated enum ErrorPlainWords {
    struct Words: Equatable, Sendable {
        var title: String
        var text: String
    }

    static let unknown = Words(title: "Something Went Wrong", text: "The details below are what Hermes reported.")

    /// The first rule that matches wins, so the more particular ones come first.
    static func explain(_ details: String) -> Words {
        let text = details.lowercased()
        func has(_ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
        if has(#"context (length|window)|maximum context|too many tokens|prompt is too long|context_length_exceeded"#) {
            return Words(title: "The Chat Is Too Long for This Model",
                         text: "The model can’t read this much at once. Start a new chat, or switch to a model with a larger context window.")
        }
        if has(#"\b429\b|rate.?limit|too many requests|quota|insufficient (credit|fund|balance)|billing|payment required|\b402\b"#) {
            return Words(title: "A Limit Was Reached",
                         text: "The provider says a rate or spending limit was hit. Wait a little and try again, or switch to another model.")
        }
        if has(#"\b401\b|\b403\b|unauthori[sz]ed|forbidden|invalid.{0,12}(api.?key|token|credential)|authentication|not signed in|expired (token|key|session)"#) {
            return Words(title: "The Provider Refused the Sign-In",
                         text: "The key or sign-in for this provider was not accepted. Check it in Settings › Providers.")
        }
        if has(#"model.{0,24}(not found|does not exist|unknown|unavailable|not available)|no such model|unknown model"#) {
            return Words(title: "The Model Wasn’t Found",
                         text: "The provider doesn’t offer this model under this name. Choose another model for the chat.")
        }
        if has(#"timed? ?out|timeout|deadline exceeded|took too long"#) {
            return Words(title: "It Took Too Long",
                         text: "Hermes or the model didn’t answer in time. Trying again usually works.")
        }
        if has(#"closed the (stream|connection)|stream (closed|ended|interrupted)|overloaded|service unavailable|bad gateway|internal server error|\b50[0234]\b|\b529\b"#) {
            return Words(title: "The Provider Had a Problem",
                         text: "The provider’s service failed or closed the connection part way through. This is usually brief.")
        }
        if has(#"network|connection (lost|refused|reset|failed)|econn|socket|dns|unreachable|offline|could not connect|couldn.t connect|no internet"#) {
            return Words(title: "A Connection Problem",
                         text: "One side couldn’t reach the other. Check the connection to the computer running Hermes, then try again.")
        }
        return unknown
    }
}
