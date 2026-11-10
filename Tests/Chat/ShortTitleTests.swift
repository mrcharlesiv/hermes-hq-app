import Testing
@testable import HermesHQNative

@Suite struct ShortTitleTests {
    let hue = "I just added another Philips hue ceiling light in the bonus/play room. Set it up."

    @Test func openingWordsArePlaceholders() {
        #expect(ShortTitle.isPlaceholder("I just added another…", firstMessage: hue))
        #expect(ShortTitle.isPlaceholder("I just added another Philips hue ceiling light in", firstMessage: hue))
        #expect(ShortTitle.isPlaceholder(hue, firstMessage: hue))                       // a long message used whole
        #expect(ShortTitle.isPlaceholder("New Chat", firstMessage: hue))
        #expect(ShortTitle.isPlaceholder("", firstMessage: ""))
    }

    @Test func realNamesAreKept() {
        #expect(!ShortTitle.isPlaceholder("Set up bonus room Hue light", firstMessage: hue))
        #expect(!ShortTitle.isPlaceholder("Weather in Austin", firstMessage: "Weather in Austin"))   // short, used whole
        #expect(!ShortTitle.isPlaceholder("Bot Chat", firstMessage: hue))
    }

    @Test func wordRuleKeepsTheTopic() {
        #expect(ShortTitle.fallback(for: hue) == "Added Philips hue ceiling light")
        #expect(ShortTitle.fallback(for: "Can you please check why the Postgres pool keeps running out?")
                == "Check Postgres pool keeps running")
        #expect(ShortTitle.fallback(for: "hi there!") == "Hi there")
        let long = ShortTitle.fallback(for: "Refactor HermesKit/Chat/LiveChatSession+Events.swift onComplete settlement")
        #expect(long.count <= ShortTitle.maxCharacters)
    }

    @Test func modelAnswersMustLookLikeNames() {
        #expect(ShortTitle.accepted("\"Set up bonus room Hue light.\"", message: hue) == "Set up bonus room Hue light")
        #expect(ShortTitle.accepted("Title: hue ceiling light setup", message: hue) == "Hue ceiling light setup")
        #expect(ShortTitle.accepted("Sure! I'll set up the new Philips Hue ceiling light in your bonus room right away for you.",
                                    message: hue) == nil)                                                    // a reply
        #expect(ShortTitle.accepted("I just added another", message: hue) == nil)                          // its own opening
        #expect(ShortTitle.accepted("", message: hue) == nil)
    }
}
