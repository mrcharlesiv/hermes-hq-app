import Foundation
import Testing
@testable import HermesHQNative

/// UX study 2026-10-19 #27: an empty Sessions list with nothing on hand is loading or failed, never "No Sessions Yet".
@Suite struct SessionsLoadWordsTests {
    private let failed = SessionsLoadState.failed(message: "Your gateway couldn’t load your chats.", busy: false)

    @Test func nothingOnHandIsLoadingUntilTheReadAnswers() {
        #expect(SessionsEmptyState.choose(.idle, holdsRows: false, archived: false, retrying: false) == .loading)
        #expect(SessionsEmptyState.choose(.loading, holdsRows: false, archived: false, retrying: false) == .loading)
        #expect(SessionsEmptyState.choose(.ready, holdsRows: false, archived: false, retrying: false) == .usual)
    }

    @Test func aFailedReadWithNothingOnHandSaysSo() {
        #expect(SessionsEmptyState.choose(failed, holdsRows: false, archived: false, retrying: false)
                == .failed(title: "Couldn’t Load Chats", reason: "Your gateway couldn’t load your chats."))
        #expect(SessionsEmptyState.choose(failed, holdsRows: false, archived: true, retrying: false)
                == .failed(title: "Couldn’t Load Archived Chats", reason: "Your gateway couldn’t load your chats."))
        // Try Again in flight: Loading until its read answers.
        #expect(SessionsEmptyState.choose(failed, holdsRows: false, archived: false, retrying: true) == .loading)
    }

    @Test func chatsOnHandKeepTheUsualWords() {
        // Cached or filtered-away rows: the list was read once, so a failure or a read in flight changes nothing.
        for state in [SessionsLoadState.idle, .loading, .ready, failed] {
            #expect(SessionsEmptyState.choose(state, holdsRows: true, archived: false, retrying: false) == .usual)
            #expect(SessionsEmptyState.choose(state, holdsRows: true, archived: false, retrying: true) == .usual)
        }
    }

    @Test func reasonsAreWordsNeverAStatusOrADump() {
        #expect(SessionsLoadWords.reason(for: HTTPError(status: 503, body: nil)) == SessionsLoadWords.busyReason)
        #expect(SessionsLoadWords.reason(for: RPCError(code: -1, message: "request timed out after 30s: sessions.list", data: nil))
                == SessionsLoadWords.busyReason)
        #expect(SessionsLoadWords.reason(for: HTTPError(status: 500, body: #"{"detail":"disk full"}"#)) == SessionsLoadWords.defaultReason)
        #expect(SessionsLoadWords.reason(for: RPCError(code: -32000, message: "session not found", data: nil)) == SessionsLoadWords.defaultReason)
        #expect(SessionsLoadWords.reason(for: RPCError(code: -32000, message: "The chats folder can’t be read.", data: nil))
                == "The chats folder can’t be read.")
        #expect(SessionsLoadWords.reason(for: RPCError(code: RPCError.notConnectedCode, message: "not connected", data: nil))
                == RosterStateCopy.waitingReason)
    }
}
