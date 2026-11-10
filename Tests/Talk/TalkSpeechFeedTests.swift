// What is sent to be spoken, a piece at a time (docs/spec/3x-talk.md §3.3, §3.4): the written reply goes to the speech
// socket as it was written (the gateway cleans each sentence), the clip fallback cleans each sentence after cutting it,
// and PCM that arrives in frames of any length is put back together sample for sample.

import Foundation
import Testing
@testable import HermesHQNative

@Suite("Talk speech feed")
struct TalkSpeechFeedTests {
    static let reply = """
    Run `npm install` to start the server. You can read [the docs](https://example.com/guide) for more detail.

    Here is the command:

    ```sh
    ls -la. It lists every file! Even hidden ones.
    ```

    That lists every file. **Done** and dusted, with `one more` span to finish it.
    """

    /// The reply as it grows, `step` characters at a time.
    static func growing(_ text: String, step: Int) -> [String] {
        let characters = Array(text)
        var out: [String] = []
        var end = step
        while end < characters.count {
            out.append(String(characters[0..<end]))
            end += step
        }
        out.append(text)
        return out
    }

    static func words(_ text: String) -> [String] { text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init) }

    @Test("The stream is given the reply as written, every character once, however it is cut")
    func streamSendsTheWrittenReply() {
        for step in [1, 3, 5, 7, 40] {
            var feed = SpeechFeed()
            var sent = ""
            for prefix in Self.growing(Self.reply, step: step) {
                feed.set(prefix)
                sent += feed.nextStreamText(finished: false) ?? ""
            }
            sent += feed.nextStreamText(finished: true) ?? ""
            #expect(sent == Self.reply, "step \(step)")
            #expect(feed.nextStreamText(finished: true) == nil)
        }
    }

    @Test("A reply that is whole when first asked for (Read Aloud) is cleaned whole")
    func aWholeReplyIsCleanedWhole() {
        var feed = SpeechFeed()
        feed.set(Self.reply)
        let sent = feed.nextStreamText(finished: true)
        #expect(sent == SpeechText.sanitizeForSpeech(Self.reply))
        #expect(sent?.contains("`") == false && sent?.contains("https") == false && sent?.contains("ls -la") == false)
        // No full stop is left standing alone where the code block was.
        #expect(sent?.contains("Here is the command. That lists every file.") == true)
        #expect(SpeechText.sanitizeForSpeech("Wait... what? Yes. Done.") == "Wait... what? Yes. Done.")
        var nothing = SpeechFeed()
        nothing.set("```\ncode only\n```")
        #expect(nothing.nextStreamText(finished: true) == nil)
    }

    @Test("A grapheme that grows across two pieces (an emoji with a joiner, an accent) is sent once and whole")
    func scalarsNotCharacters() {
        let text = "Family: \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} and cafe\u{301} au lait."
        let scalars = Array(text.unicodeScalars)
        var feed = SpeechFeed()
        var sent = String.UnicodeScalarView()
        for end in 1...scalars.count {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[0..<end])
            feed.set(String(view))
            if let next = feed.nextStreamText(finished: false) { sent.append(contentsOf: next.unicodeScalars) }
        }
        #expect(String(sent) == text)
    }

    @Test("The clip fallback says the same words whether the reply came whole or five characters at a time")
    func clipsSayTheSameWords() {
        var whole = SpeechFeed()
        whole.set(Self.reply)
        let once = whole.nextSentences(finished: true)
        #expect(whole.sentencesFlushed)
        #expect(Self.words(once.joined(separator: " ")) == Self.words(SpeechText.sanitizeForSpeech(Self.reply)))
        for step in [1, 5, 9, 33] {
            var feed = SpeechFeed()
            var said: [String] = []
            for prefix in Self.growing(Self.reply, step: step) {
                feed.set(prefix)
                said += feed.nextSentences(finished: false)
            }
            #expect(!said.isEmpty, "step \(step): sentences are ready before the reply ends")
            said += feed.nextSentences(finished: true)
            #expect(feed.sentencesFlushed)
            let spoken = said.joined(separator: " ")
            #expect(Self.words(spoken) == Self.words(once.joined(separator: " ")), "step \(step): \(spoken)")
            #expect(!spoken.contains("`") && !spoken.contains("[") && !spoken.contains("https") && !spoken.contains("*"), "step \(step)")
            #expect(!spoken.contains("ls -la") && !spoken.contains("hidden"), "step \(step): a code block is never spoken")
            #expect(feed.nextSentences(finished: true).isEmpty)
        }
    }

    @Test("A code block that never closes is not spoken, and what came before it is")
    func anOpenCodeBlock() {
        var feed = SpeechFeed()
        feed.set("Here is the start of it all. ```swift\nlet a = 1. let b = 2. ")
        let early = feed.nextSentences(finished: false)
        #expect(early == ["Here is the start of it all."])
        feed.set("Here is the start of it all. ```swift\nlet a = 1. let b = 2. let c = 3.")
        #expect(feed.nextSentences(finished: false).isEmpty)
        #expect(feed.nextSentences(finished: true).isEmpty)
    }

    @Test("PCM split at any byte is scheduled sample for sample: an odd byte waits for the next frame")
    func pcmIsCarried() {
        var tone = Data()
        for index in 0..<2_400 {
            let sample = Int16(7_000 * sin(2 * Double.pi * 440 * Double(index) / 24_000))
            withUnsafeBytes(of: sample.littleEndian) { tone.append(contentsOf: $0) }
        }
        for (size, frame) in [(1, 2), (3, 2), (1_001, 2), (4_800, 2), (5, 4), (1_001, 4), (7, 4)] {
            var carry = Data(), out = Data(), offset = 0
            while offset < tone.count {
                let piece = tone.subdata(in: offset..<min(tone.count, offset + size))
                let whole = PCMCarry.take(&carry, adding: piece, frameBytes: frame)
                #expect(whole.count % frame == 0)
                out.append(whole)
                offset += size
            }
            #expect(out == tone, "frames of \(size) bytes, \(frame) bytes a sample frame")
            #expect(carry.isEmpty)
        }
        // A lone trailing byte is never played.
        var carry = Data()
        #expect(PCMCarry.take(&carry, adding: Data([1, 2, 3]), frameBytes: 2) == Data([1, 2]))
        #expect(carry == Data([3]))
        #expect(PCMCarry.take(&carry, adding: Data([4]), frameBytes: 2) == Data([3, 4]))
        #expect(carry.isEmpty)
    }
}
