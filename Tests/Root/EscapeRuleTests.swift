// 3x-morepages §9 (U8): hardware Escape after the chat's own ladder.
import Testing
@testable import HermesHQNative

struct EscapeRuleTests {
    @Test func theTable() {
        #expect(EscapeRule.outcome(.layer) == .dismissLayer)
        #expect(EscapeRule.outcome(.searching) == .cancelSearch)
        #expect(EscapeRule.outcome(.pushedPage) == .goBack)
        #expect(EscapeRule.outcome(.tabRoot) == .nothing)
        #expect(EscapeRule.outcome(.chatTyping) == .nothing)
    }

    @Test func contextIsReadTopDown() {
        typealias Facts = EscapeRule.Facts
        #expect(EscapeRule.context(Facts()) == .tabRoot)
        #expect(EscapeRule.context(Facts(depth: 2)) == .pushedPage)
        #expect(EscapeRule.context(Facts(depth: 5)) == .pushedPage)
        #expect(EscapeRule.context(Facts(chatDraft: true, depth: 2)) == .chatTyping)
        #expect(EscapeRule.context(Facts(searching: true, chatDraft: true, depth: 2)) == .searching)
        #expect(EscapeRule.context(Facts(presented: true, searching: true, chatDraft: true, depth: 3)) == .layer)
        #expect(EscapeRule.context(Facts(searching: true)) == .searching)
        #expect(EscapeRule.context(Facts(depth: 0)) == .tabRoot)
    }

    @Test func aTabRootIsNeverClosed() {
        // whatever the facts, depth 1 never yields Back
        for presented in [false, true] { for searching in [false, true] { for draft in [false, true] {
            let facts = EscapeRule.Facts(presented: presented, searching: searching, chatDraft: draft, depth: 1)
            #expect(EscapeRule.outcome(EscapeRule.context(facts)) != .goBack)
        } } }
    }

    @Test func aDraftIsMoreThanSpace() {
        #expect(!EscapeRule.isDraft(""))
        #expect(!EscapeRule.isDraft("  \n\t "))
        #expect(EscapeRule.isDraft(" a "))
    }
}
