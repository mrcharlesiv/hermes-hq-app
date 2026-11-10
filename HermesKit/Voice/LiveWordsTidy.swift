// Live Words' tidy pass (docs/spec/3x-live-words.md §2.1): what Apple's engine heard, made ready to show and send.
//
// - "uh" and "um" go (the gateway's speech to text dropped them; Apple's keeps them: "create a, uh, clawed code").
// - The person's own fixes are written ("Kua" → "CUA"). They are learned when a memo's words are corrected in review
//   (`WordFixes.learn`), and listed in Settings › Voice › Word Fixes.
// - A name from the person's vocabulary (bots, the app's own words) is written where the heard words sound the same,
//   word for word ("clawed code" → "Claude Code"), or spell it with spaces ("test flight" → "TestFlight").
//
// Why after the engine rather than in it: `SpeechTranscriber` ignores `AnalysisContext.contextualStrings`. Run on the
// owner's own memos (2026-11-02), a list of names changed none of its words; `DictationTranscriber` took them but
// heard everything else worse ("cooler" for CUA, no punctuation). Its alternative transcriptions held no better words.
//
// Pure and `Sendable`: a listener takes a snapshot when it starts and tidies on any thread.

import Foundation

/// One fix the person taught: the words heard, and the words meant.
nonisolated struct WordFix: Codable, Hashable, Sendable {
    var heard: String
    var meant: String
}

nonisolated struct LiveWordsTidy: Sendable {
    /// Learned fixes, applied before anything else matches names.
    var fixes: [WordFix] = []
    /// Names to write as spelled when the heard words sound the same (bots, the app's own words).
    var names: [String] = []

    /// The app's own words, always known.
    static let builtInNames = [
        "Hermes", "Hermes HQ", "Claude Code", "Codex", "Composio", "TestFlight", "Nous Research", "Home Assistant",
        "GitHub", "OpenAI", "ChatGPT", "Tailscale", "Telegram", "iPhone", "iPad", "macOS", "Kanban",
    ]

    /// The fillers dropped. Not "hmm" or "uh-huh" (they answer something), not "er" (ER).
    static let fillers: Set<String> = ["uh", "uhh", "uhhh", "um", "umm", "ummm", "uhm", "erm"]

    func apply(_ words: LiveWordsText) -> LiveWordsText {
        LiveWordsText(settled: apply(words.settled), pending: apply(words.pending))
    }

    func apply(_ text: String) -> String {
        var tokens = Self.tokens(text)
        guard !tokens.isEmpty else { return text }
        tokens = Self.droppingFillers(tokens)
        for fix in fixes.sorted(by: { Self.tokens($0.heard).count > Self.tokens($1.heard).count }) {
            tokens = Self.replacing(Self.tokens(fix.heard).map(\.core), with: fix.meant, in: tokens, match: Self.same)
        }
        for name in names where !name.isEmpty {
            let parts = Self.tokens(name).map(\.core)
            guard !parts.isEmpty else { continue }
            // Spelled with spaces, or its casing lost: "test flight", "cua" (only a name with its own casing: "home"
            // stays "home" even with a bot called Home).
            tokens = Self.joined(name, parts, in: tokens)
            // Sounds the same word for word, in another spelling: "clawed code". Names of two words or more only: one
            // word alone sounds like too much ("Ivy" and "some").
            if parts.count >= 2 {
                tokens = Self.replacing(parts, with: name, in: tokens) { heard, wanted in
                    let a = Phonetic.key(heard), b = Phonetic.key(wanted)
                    return !a.isEmpty && a == b
                }
            }
        }
        return tokens.map(\.text).joined(separator: " ")
    }

    // MARK: Tokens

    /// One word as heard, with what stands around it ("a," → "", "a", ",").
    struct Token: Equatable {
        var lead: String
        var core: String
        var trail: String
        var text: String { lead + core + trail }
        /// It ends a sentence.
        var endsSentence: Bool { trail.contains(where: { ".?!…".contains($0) }) }
    }

    static func tokens(_ text: String) -> [Token] {
        text.split(whereSeparator: { $0.isWhitespace }).map { piece in
            let chars = Array(piece)
            let inWord: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" || $0 == "-" }
            guard let first = chars.firstIndex(where: { $0.isLetter || $0.isNumber }),
                  let last = chars.lastIndex(where: { $0.isLetter || $0.isNumber }) else {
                return Token(lead: String(piece), core: "", trail: "")
            }
            var end = last
            while end + 1 < chars.count, inWord(chars[end + 1]), chars[end + 1] != "-" { end += 1 }
            return Token(lead: String(chars[..<first]), core: String(chars[first...end]), trail: String(chars[(end + 1)...]))
        }
    }

    private static func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }

    // MARK: Fillers

    /// "create a, uh, clawed" → "create a clawed"; "Uh, toy that" → "Toy that"; "I think, um." → "I think."
    static func droppingFillers(_ input: [Token]) -> [Token] {
        var out: [Token] = []
        var capitalizeNext = false
        for (index, token) in input.enumerated() {
            guard fillers.contains(token.core.lowercased()), token.lead.isEmpty else {
                var token = token
                if capitalizeNext, let first = token.core.first {
                    token.core = first.uppercased() + token.core.dropFirst()
                }
                capitalizeNext = false
                out.append(token)
                continue
            }
            let startsSentence = out.last.map(\.endsSentence) ?? true
            let ending = token.trail.filter { ".?!…".contains($0) }
            if !ending.isEmpty, var previous = out.last {
                // "I think, um." → "I think."
                if !previous.endsSentence {
                    previous.trail = String(previous.trail.reversed().drop(while: { $0 == "," }).reversed()) + ending
                    out[out.count - 1] = previous
                }
            } else if var previous = out.last, previous.trail == ",", index + 1 < input.count, gluedToNext.contains(previous.core.lowercased()) {
                // "of, um, a rainbow": the commas were only the filler's.
                previous.trail = ""
                out[out.count - 1] = previous
            }
            if startsSentence, ending.isEmpty { capitalizeNext = true }
        }
        return out
    }

    /// Words a sentence doesn't pause after: a comma right after one was put there for the filler that followed.
    private static let gluedToNext: Set<String> = [
        "a", "an", "the", "of", "to", "for", "with", "and", "or", "but", "in", "on", "at", "my", "your", "our", "their",
        "his", "her", "its", "is", "are", "was", "were", "be", "by", "from", "into", "about", "some", "this", "these",
        "those", "can", "could", "would", "should", "will", "just", "like",
    ]

    // MARK: Matching

    /// Every run of tokens whose words match `parts` (by `match`), written as `replacement`: the first token's lead and
    /// the last one's trail kept. A run never crosses a comma or a sentence's end.
    static func replacing(_ parts: [String], with replacement: String, in tokens: [Token],
                          match: (String, String) -> Bool) -> [Token] {
        guard !parts.isEmpty, tokens.count >= parts.count else { return tokens }
        let wanted = Self.tokens(replacement)
        guard !wanted.isEmpty else { return tokens }
        var out: [Token] = []
        var i = 0
        while i < tokens.count {
            let end = i + parts.count
            if end <= tokens.count,
               tokens[i..<end].enumerated().allSatisfy({ k, t in match(t.core, parts[k]) && (k == parts.count - 1 || t.trail.isEmpty) && (k == 0 || t.lead.isEmpty) }),
               tokens[i..<end].map(\.core) != wanted.map(\.core) {
                var words = wanted
                words[0].lead = tokens[i].lead + words[0].lead
                words[words.count - 1].trail += tokens[end - 1].trail
                if startsSentence(at: i, in: tokens), let first = words[0].core.first, first.isLowercase, tokens[i].core.first?.isUppercase == true {
                    words[0].core = first.uppercased() + words[0].core.dropFirst()
                }
                out.append(contentsOf: words)
                i = end
            } else {
                out.append(tokens[i])
                i += 1
            }
        }
        return out
    }

    private static func startsSentence(at index: Int, in tokens: [Token]) -> Bool {
        index == 0 || tokens[index - 1].endsSentence
    }

    /// `name` spelled with spaces ("test flight", "Test Flight") or, for a name with its own casing ("TestFlight",
    /// "CUA", "iPhone"), its casing lost ("testflight", "cua").
    private static func joined(_ name: String, _ parts: [String], in tokens: [Token]) -> [Token] {
        let squashed = parts.joined().lowercased()
        // Its own casing: a capital after the first letter (TestFlight, iPhone, CUA). "Hermes" heard as "hermes" is
        // left alone: a one-word name without one may be an everyday word too.
        let ownCasing = parts.contains { $0.dropFirst().contains(where: \.isUppercase) }
        var result = tokens
        for count in (1...3).reversed() where count > 1 || ownCasing {
            result = replacingRuns(of: count, squashed: squashed, with: name, in: result)
        }
        return result
    }

    private static func replacingRuns(of count: Int, squashed: String, with name: String, in tokens: [Token]) -> [Token] {
        guard tokens.count >= count else { return tokens }
        let wanted = Self.tokens(name)
        var out: [Token] = []
        var i = 0
        while i < tokens.count {
            let end = i + count
            if end <= tokens.count,
               tokens[i..<end].enumerated().allSatisfy({ k, t in (k == count - 1 || t.trail.isEmpty) && (k == 0 || t.lead.isEmpty) && !t.core.isEmpty }),
               tokens[i..<end].map(\.core).joined().replacingOccurrences(of: "-", with: "").lowercased() == squashed,
               tokens[i..<end].map(\.core) != wanted.map(\.core) {
                var words = wanted
                words[0].lead = tokens[i].lead + words[0].lead
                words[words.count - 1].trail += tokens[end - 1].trail
                out.append(contentsOf: words)
                i = end
            } else {
                out.append(tokens[i])
                i += 1
            }
        }
        return out
    }
}

// MARK: - Sounds alike

/// A word's sound, roughly (Lawrence Philips' Metaphone, with a vowel-following W or Y silent: "clawed" and "Claude"
/// both KLT). Only used to compare a heard word with a name's.
nonisolated enum Phonetic {
    static func key(_ word: String) -> String {
        let letters = Array(word.uppercased().unicodeScalars.filter { $0.properties.isAlphabetic && $0.isASCII }.map(Character.init))
        guard !letters.isEmpty else { return "" }
        var w = letters
        // Starts that drop a letter.
        let start = String(w.prefix(2))
        if ["AE", "GN", "KN", "PN", "WR"].contains(start) { w.removeFirst() }
        if w.first == "X" { w[0] = "S" }
        if start == "WH" { w.remove(at: 1) }
        // Doubles, except C.
        var deduped: [Character] = []
        for c in w where c != deduped.last || c == "C" { deduped.append(c) }
        w = deduped
        let vowels: Set<Character> = ["A", "E", "I", "O", "U"]
        func at(_ i: Int) -> Character? { i >= 0 && i < w.count ? w[i] : nil }
        func isVowel(_ i: Int) -> Bool { at(i).map { vowels.contains($0) } ?? false }
        var out = ""
        var i = 0
        while i < w.count {
            let c = w[i]
            let next = at(i + 1), prev = at(i - 1)
            switch c {
            case "A", "E", "I", "O", "U":
                if i == 0 { out.append(c) }
            case "B":
                if !(prev == "M" && i == w.count - 1) { out.append("B") }
            case "C":
                if next == "I" && at(i + 2) == "A" { out.append("X") }
                else if next == "H" { out.append(prev == "S" ? "K" : "X"); i += 1 }
                else if let n = next, "IEY".contains(n) { if prev != "S" { out.append("S") } }
                else { out.append("K") }
            case "D":
                if next == "G", let n = at(i + 2), "EIY".contains(n) { out.append("J"); i += 1 } else { out.append("T") }
            case "G":
                if next == "H" && !(i + 2 >= w.count || isVowel(i + 2)) { break }
                if next == "N" && (i + 2 == w.count || (at(i + 2) == "E" && at(i + 3) == "D" && i + 4 == w.count)) { break }
                if let n = next, "IEY".contains(n), prev != "G" { out.append("J") } else { out.append("K") }
            case "H":
                if let p = prev, "CSPTG".contains(p) { break }
                if isVowel(i - 1) && !isVowel(i + 1) { break }
                out.append("H")
            case "K":
                if prev != "C" { out.append("K") }
            case "P":
                if next == "H" { out.append("F"); i += 1 } else { out.append("P") }
            case "Q": out.append("K")
            case "S":
                if next == "H" { out.append("X"); i += 1 }
                else if next == "I", let n = at(i + 2), "OA".contains(n) { out.append("X") }
                else { out.append("S") }
            case "T":
                if next == "I", let n = at(i + 2), "OA".contains(n) { out.append("X") }
                else if next == "H" { out.append("0"); i += 1 }
                else if !(next == "C" && at(i + 2) == "H") { out.append("T") }
            case "V": out.append("F")
            case "W", "Y":
                if isVowel(i + 1) && (i == 0 || !isVowel(i - 1)) { out.append(c) }
            case "X": out.append("KS")
            case "Z": out.append("S")
            default: out.append(c)
            }
            i += 1
        }
        return out
    }
}

// MARK: - The person's fixes (Settings › Voice › Word Fixes)

/// Fixes taught by correcting a memo's words in review, newest first, kept on this device. Every listening starts with
/// them (`LiveWords.listen`), so a word fixed once is written right in later memos, Dictate and Talk.
@MainActor enum WordFixes {
    static let key = "hq.voice.wordFixes"
    /// Posted when the list changes.
    static let changed = Notification.Name("hq.voice.wordFixes.changed")
    /// The most kept; the oldest go first.
    static let limit = 200

    static var all: [WordFix] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let fixes = try? JSONDecoder().decode([WordFix].self, from: data) else { return [] }
        return fixes
    }

    private static func save(_ fixes: [WordFix]) {
        if fixes.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(Array(fixes.prefix(limit))) {
            UserDefaults.standard.set(data, forKey: key)
        }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// Adds `fix` first; one already kept for the same heard words is replaced.
    static func add(_ fix: WordFix) {
        let heard = fix.heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let meant = fix.meant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty, !meant.isEmpty, heard != meant else { return }
        var fixes = all.filter { $0.heard.caseInsensitiveCompare(heard) != .orderedSame }
        fixes.insert(WordFix(heard: heard, meant: meant), at: 0)
        save(fixes)
    }

    static func remove(heard: String) {
        save(all.filter { $0.heard != heard })
    }

    static func removeAll() { save([]) }

    /// Learns what a correction teaches (`lessons`), and says how many fixes it kept.
    @discardableResult static func learn(from heard: String, to meant: String) -> Int {
        let lessons = lessons(from: heard, to: meant)
        for fix in lessons.reversed() { add(fix) }
        return lessons.count
    }

    /// What correcting `heard` into `meant` teaches: each run of one to three heard words replaced by one to four
    /// others, when at least one heard word isn't an everyday word ("Kua" → "CUA", "from mountain" → "for Robin").
    /// Everyday swaps ("you" → "we") are edits of one memo, not fixes for every memo. Words only: no punctuation.
    nonisolated static func lessons(from heard: String, to meant: String) -> [WordFix] {
        let a = LiveWordsTidy.tokens(heard).map(\.core).filter { !$0.isEmpty }
        let b = LiveWordsTidy.tokens(meant).map(\.core).filter { !$0.isEmpty }
        guard !a.isEmpty, !b.isEmpty, a.count <= 400, b.count <= 400 else { return [] }
        // Longest common run of words (case-insensitive), then the stretches between the shared words.
        let la = a.map { $0.lowercased() }, lb = b.map { $0.lowercased() }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = la[i] == lb[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var lessons: [WordFix] = []
        var i = 0, j = 0, runA: [String] = [], runB: [String] = []
        func close() {
            defer { runA = []; runB = [] }
            guard (1...3).contains(runA.count), (1...4).contains(runB.count),
                  runA.contains(where: { !everyday.contains($0.lowercased()) }),
                  runA.joined(separator: " ") != runB.joined(separator: " ") else { return }
            lessons.append(WordFix(heard: runA.joined(separator: " "), meant: runB.joined(separator: " ")))
        }
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, la[i] == lb[j] {
                // A casing fix ("kua" → "CUA") is a change too; a word made lowercase is a sentence rejoined, not a fix.
                if a[i] != b[j], b[j] != lb[j] { runA.append(a[i]); runB.append(b[j]); close() } else { close() }
                i += 1; j += 1
            } else if j < b.count, i == a.count || table[i][j + 1] >= table[i + 1][j] {
                runB.append(b[j]); j += 1
            } else {
                runA.append(a[i]); i += 1
            }
        }
        close()
        return lessons
    }

    /// Words too common to fix in every memo.
    nonisolated static let everyday: Set<String> = [
        "a", "about", "after", "again", "all", "also", "am", "an", "and", "any", "are", "as", "at", "back", "be", "because",
        "been", "before", "but", "by", "can", "can't", "come", "could", "did", "do", "does", "don't", "down", "even",
        "for", "from", "get", "give", "go", "going", "good", "got", "had", "has", "have", "he", "her", "here", "him",
        "his", "how", "i", "i'm", "if", "in", "into", "is", "it", "it's", "its", "just", "know", "let", "like", "look",
        "make", "me", "more", "my", "need", "new", "no", "not", "now", "of", "off", "ok", "okay", "on", "one", "only",
        "or", "other", "our", "out", "over", "please", "right", "said", "say", "see", "send", "she", "should", "so",
        "some", "take", "tell", "than", "that", "that's", "the", "their", "them", "then", "there", "there's", "these",
        "they", "thing", "think", "this", "those", "time", "to", "two", "up", "us", "use", "want", "was", "way", "we",
        "well", "were", "what", "when", "where", "which", "who", "why", "will", "with", "would", "yeah", "yes", "you",
        "your", "you're",
    ]
}

/// The words every listening knows: the app's own, the bots' names, the person's fixes.
@MainActor enum LiveWordsVocabulary {
    /// The signed-in account's bot names (the app model sets it).
    static var botNames: () -> [String] = { [] }

    static func tidy() -> LiveWordsTidy {
        var names = LiveWordsTidy.builtInNames
        for name in botNames() where !names.contains(name) { names.append(name) }
        return LiveWordsTidy(fixes: WordFixes.all, names: names)
    }
}

/// A listening whose words are tidied (`LiveWordsTidy`) as they're shown and when they settle.
nonisolated final class TidiedLiveWords: LiveWordsListening, Sendable {
    let inner: any LiveWordsListening
    let tidy: LiveWordsTidy

    init(_ inner: any LiveWordsListening, tidy: LiveWordsTidy) {
        self.inner = inner
        self.tidy = tidy
    }

    func feed(_ samples: UnsafeBufferPointer<Int16>) { inner.feed(samples) }
    func finish() async -> String { tidy.apply(await inner.finish()) }
    func cancel() { inner.cancel() }
}
