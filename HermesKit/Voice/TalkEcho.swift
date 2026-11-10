// The echo guard (docs/spec/3x-talk.md §4.1): a barge-in utterance whose words are the bot's own speech, picked up
// by the microphone, is dropped. Ported from `vendor/hermes/apps/desktop/src/lib/voice-tts-echo.ts`, which itself is
// Python's difflib.SequenceMatcher.ratio().

import Foundation

nonisolated enum TalkEcho {
    static let similarity = 0.6
    /// Fragments shorter than this are never treated as an echo of part of the reply.
    static let minFragment = 10

    private static func normalize(_ text: String) -> [Character] {
        Array(text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// difflib's ratio: 2 × matches / total, with the same "popular character" pruning for long texts.
    static func ratio(_ a: [Character], _ b: [Character]) -> Double {
        let total = a.count + b.count
        if total == 0 { return 1 }
        var places: [Character: [Int]] = [:]
        for (index, character) in b.enumerated() { places[character, default: []].append(index) }
        if b.count >= 200 {
            let limit = b.count / 100 + 1
            places = places.filter { $0.value.count <= limit }
        }
        func longest(_ alo: Int, _ ahi: Int, _ blo: Int, _ bhi: Int) -> (Int, Int, Int) {
            var besti = alo, bestj = blo, bestsize = 0
            var lengths: [Int: Int] = [:]
            for i in alo..<ahi {
                var next: [Int: Int] = [:]
                for j in places[a[i]] ?? [] {
                    if j < blo { continue }
                    if j >= bhi { break }
                    let k = (lengths[j - 1] ?? 0) + 1
                    next[j] = k
                    if k > bestsize { besti = i - k + 1; bestj = j - k + 1; bestsize = k }
                }
                lengths = next
            }
            while besti > alo, bestj > blo, a[besti - 1] == b[bestj - 1] { besti -= 1; bestj -= 1; bestsize += 1 }
            while besti + bestsize < ahi, bestj + bestsize < bhi, a[besti + bestsize] == b[bestj + bestsize] { bestsize += 1 }
            return (besti, bestj, bestsize)
        }
        var matches = 0
        var queue = [(0, a.count, 0, b.count)]
        while let (alo, ahi, blo, bhi) = queue.popLast() {
            guard alo < ahi, blo < bhi else { continue }
            let (i, j, k) = longest(alo, ahi, blo, bhi)
            guard k > 0 else { continue }
            matches += k
            if alo < i, blo < j { queue.append((alo, i, blo, j)) }
            if i + k < ahi, j + k < bhi { queue.append((i + k, ahi, j + k, bhi)) }
        }
        return Double(2 * matches) / Double(total)
    }

    /// True when `transcript` is (part of) `spoken`: the whole texts are alike, or the transcript matches a window of
    /// the same length somewhere in what was spoken.
    static func isEcho(_ transcript: String, of spoken: String, threshold: Double = similarity) -> Bool {
        let a = normalize(transcript), b = normalize(spoken)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if ratio(a, b) >= threshold { return true }
        guard a.count >= minFragment, a.count < b.count else { return false }
        // The vendor slides one character at a time. On a very long reply that is too slow for the main thread, so the
        // window moves an eighth of the fragment there (the ratio changes little over so small a shift).
        let step = b.count > 1_500 ? max(1, a.count / 8) : 1
        var start = 0
        while start <= b.count - a.count {
            if ratio(a, Array(b[start..<start + a.count])) >= threshold { return true }
            start += step
        }
        if step > 1, ratio(a, Array(b[(b.count - a.count)...])) >= threshold { return true }
        return false
    }
}
