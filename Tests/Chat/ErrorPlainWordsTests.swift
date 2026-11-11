// [error-words] Owner 2026-11-10 (design pick 7): Error Details says what happened in plain words.

import Testing
@testable import HermesHQNative

@Suite struct ErrorPlainWordsTests {
    @Test func theWordsFollowWhatTheErrorSays() {
        func title(_ details: String) -> String { ErrorPlainWords.explain(details).title }
        #expect(title("Gateway error 502: the provider closed the stream.\nrequest id 7f3a91c2") == "The Provider Had a Problem")
        #expect(title("HTTP 429 Too Many Requests") == "A Limit Was Reached")
        #expect(title("insufficient credits for this request") == "A Limit Was Reached")
        #expect(title("401 Unauthorized: invalid api key") == "The Provider Refused the Sign-In")
        #expect(title("This model's maximum context length is 200000 tokens") == "The Chat Is Too Long for This Model")
        #expect(title("model gpt-9 not found") == "The Model Wasn’t Found")
        #expect(title("request timed out after 120s") == "It Took Too Long")
        #expect(title("ECONNREFUSED 127.0.0.1:9119") == "A Connection Problem")
    }

    @Test func anythingElseSaysOnlyThatItWentWrong() {
        #expect(ErrorPlainWords.explain("ValueError: unexpected None") == ErrorPlainWords.unknown)
        #expect(ErrorPlainWords.explain("") == ErrorPlainWords.unknown)
        #expect(ErrorPlainWords.unknown.title == "Something Went Wrong")
    }

    /// A rate limit that arrives as a 5xx-looking gateway line is still a limit: the particular rule wins.
    @Test func theMoreParticularRuleWins() {
        #expect(ErrorPlainWords.explain("Gateway error 502: upstream said rate limit exceeded").title == "A Limit Was Reached")
    }
}
