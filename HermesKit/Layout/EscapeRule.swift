// [morepages] 3x-morepages §9 (U8, D-M7): what hardware Escape does once the chat's own ladder (`EscapeAction`:
// a layer on top, Find, a recording, a search, a running reply, the focused field) has nothing left to do.
// Web `S/ui-nav/root-escape.ts`: "A tab root is persistent. Escape belongs to a transient layer or its search."
// Escape never selects another tab, never signs out, never closes a tab root.

import Foundation

nonisolated enum EscapeRule {
    enum Context: Equatable, Sendable { case layer, searching, pushedPage, tabRoot, chatTyping }
    enum Outcome: Equatable, Sendable { case dismissLayer, cancelSearch, goBack, nothing }

    static func outcome(_ context: Context) -> Outcome {
        switch context {
        case .layer: .dismissLayer
        case .searching: .cancelSearch
        case .pushedPage: .goBack
        case .tabRoot, .chatTyping: .nothing
        }
    }

    /// The facts, read top-down: the first that holds names the context.
    struct Facts: Equatable, Sendable {
        var presented = false      // a sheet, alert, menu, the media viewer, Quick Look
        var searching = false      // the visible page's search is open
        var chatDraft = false      // a chat is on show and its message field holds text
        var depth = 1              // screens on the selected tab's stack
    }

    static func context(_ facts: Facts) -> Context {
        if facts.presented { return .layer }
        if facts.searching { return .searching }
        if facts.chatDraft { return .chatTyping }
        return facts.depth > 1 ? .pushedPage : .tabRoot
    }

    /// A draft is text that is more than spaces and line breaks.
    static func isDraft(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
