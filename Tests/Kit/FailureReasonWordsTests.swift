import Foundation
import Testing
@testable import HermesHQNative

/// UX study 2026-10-19 #99 and #138: failure alerts say what happened in plain words, never Swift's debug text.
@Suite struct FailureReasonWordsTests {
    private struct Described: LocalizedError { var errorDescription: String? { "The file is too big." } }
    private struct Bare: Error {}

    @Test func commonNetworkFailuresAreInPlainWords() {
        #expect(FailureReasonWords.reason(for: URLError(.notConnectedToInternet)) == FailureReasonWords.offline)
        #expect(FailureReasonWords.reason(for: URLError(.networkConnectionLost)) == FailureReasonWords.offline)
        #expect(FailureReasonWords.reason(for: URLError(.cannotConnectToHost)) == FailureReasonWords.unreachable)
        #expect(FailureReasonWords.reason(for: URLError(.cannotFindHost)) == FailureReasonWords.unreachable)
        #expect(FailureReasonWords.reason(for: URLError(.timedOut)) == FailureReasonWords.timedOut)
    }

    @Test func otherErrorsUseTheirOwnDescriptionNeverTheDebugText() {
        #expect(FailureReasonWords.reason(for: Described()) == "The file is too big.")
        // No sentence of their own ("… (NSURLErrorDomain error -1011.)"): the plain fallback.
        #expect(FailureReasonWords.reason(for: Bare()) == FailureReasonWords.unknown)
        #expect(FailureReasonWords.reason(for: URLError(.badServerResponse)) == FailureReasonWords.unknown)
        let worded = NSError(domain: NSURLErrorDomain, code: -1011, userInfo: [NSLocalizedDescriptionKey: "The server sent a bad answer."])
        #expect(FailureReasonWords.reason(for: worded) == "The server sent a bad answer.")
    }

    @Test func aFailedLocalApprovalPointsBackToTheCard() {
        #expect(LocalApprovalWords.title(approve: true) == "Couldn’t Approve")
        #expect(LocalApprovalWords.title(approve: false) == "Couldn’t Deny")
        let offline = PromptAnswerError(message: "Hermes is offline right now.", offline: true)
        #expect(LocalApprovalWords.reason(for: offline) == "Hermes is offline right now.")
        #expect(LocalApprovalWords.reason(for: PromptAnswerError(message: "Couldn’t send your answer.", offline: false))
                == LocalApprovalWords.notSent)
        #expect(LocalApprovalWords.reason(for: URLError(.timedOut)) == LocalApprovalWords.notSent)
        #expect(LocalApprovalWords.gone == "That request was already answered or had expired.")
        #expect(LocalApprovalWords.sent(approve: true) == "Approved" && LocalApprovalWords.sent(approve: false) == "Denied")
    }
}
