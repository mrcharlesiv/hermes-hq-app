import Foundation
import NaturalLanguage
import os

// [updates] Some models write a bot-to-bot message, a report or a subagent's goal with most of its spaces gone:
// "Newrepeatvalidationalertdiagnosed/fixed locally(myownedscript): validation_pending returnedTrue despite
// previouslyverifieddeliveryreceipt…". Hermes stores it as written, so every user of the app sees it that way. The app
// puts the spaces back for display (owner, 2026-10-27: "I need this to work for everyone using the app. Either we fix
// it or we do nothing").
//
// Only a message that is plainly broken is touched: three or more runs that split wholly into known words. Normal
// text, names, code (`…`, snake_case, files, paths, addresses, numbers) stay exactly as written. Words come from the
// system's English word list (`NLEmbedding`, ~57k common words: thread-safe, no download), so rare words don't win a
// split ("then stopped", not "thens topped"); a short list of very common words settles ties ("downloads now", not
// "download snow"). Checked against 1,313 real messages from the owner's bots: only broken ones changed.

nonisolated enum SpacedText {
    /// `text` with lost spaces put back, or `text` itself when it isn't broken. Markdown code spans and blocks keep
    /// their words as written.
    static func repair(_ text: String) -> String {
        guard text.utf16.count >= 40, text.utf16.count <= 20_000 else { return text }
        let key = text as NSString
        if let done = repaired.object(forKey: key) { return done as String }
        let fixed = fix(text)
        repaired.setObject(fixed as NSString, forKey: key)
        return fixed
    }

    nonisolated(unsafe) private static let repaired: NSCache<NSString, NSString> = {   // NSCache is thread-safe
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 400
        return cache
    }()

    // MARK: Words

    private static let words = OSAllocatedUnfairLock(initialState: Lexicon())

    private struct Lexicon: @unchecked Sendable {   // only touched under the lock
        let embedding = NLEmbedding.wordEmbedding(for: .english)
        var known: [String: Bool] = [:]
    }

    /// The system's common-English word list; three letters and under only from `short` (scraps like "ed", "doe").
    static func isWord(_ w: String) -> Bool {
        let lower = w.lowercased()
        if lower.count <= 3 { return short.contains(lower) }
        return words.withLock { lexicon in
            if let k = lexicon.known[lower] { return k }
            let k = lexicon.embedding?.contains(lower) ?? false
            if lexicon.known.count > 20_000 { lexicon.known.removeAll(keepingCapacity: true) }
            lexicon.known[lower] = k
            return k
        }
    }

    private static func set(_ s: String) -> Set<String> { Set(s.split(whereSeparator: \.isWhitespace).map(String.init)) }

    /// Short words a split may use.
    private static let short = set("""
    a i an as at be by do go he if in is it me my no of on or so to up us we ok am
    the and for not are but you all any can had has her him his how its may new now old one our out own per see she too
    two use was way who why yet did get got let put set run few off end via due top far key low big lot sub log app job
    fix bug add ask try met yes web raw row max min bot say saw ago act age aim air art bad bit box buy cut day eye fit fun
    hit hot law lay led lie map mix net nor pay pop red sat sit six sum tax ten tie tip win won zip etc doc ids mac
    """)

    /// Very common words, which win a tie with a rarer short word ("downloads now", not "download snow").
    private static let common = set("""
    then than that this with from have been were will when what also only just more most some them they into over each
    both does done made make need test user used uses data file code same time work live real push poll auth sent last
    next good here there these those which while where after before about again still even such very much many well back
    down like path
    """)

    /// Little words that make a short two-word run a real split ("Howmany", "foruser"), not a compound ("subagent").
    private static let glue = set("""
    a i an as at be by do go he if in is it me my no of on or so to us we am the and for not are but you all any can had
    has her him his how its may new now our own per see she too two was way who why yet did get got let put via due then
    than that this with from have been were will when what also only just more most some them they into each both does
    done made make need user many much
    """)

    // MARK: Splitting

    /// The fewest, most common words; an unknown stretch (a name) costs about six words, so a name is never cut into
    /// word scraps, and an unknown scrap under four letters is never cut off at all.
    static func segment(_ s: String) -> [String] {
        let chars = Array(s), n = chars.count
        guard n > 0 else { return [] }
        var best = [Double](repeating: .infinity, count: n + 1), back = [Int](repeating: 0, count: n + 1)
        best[0] = 0
        for i in 1...n {
            for j in max(0, i - 24)..<i where best[j] < .infinity {
                let piece = String(chars[j..<i])
                let lower = piece.lowercased()
                let cost: Double = isWord(piece)
                    ? (lower.count > 4 || common.contains(lower) || short.contains(lower) ? 1 : 1.8)
                    : piece.count < 4 ? .infinity : 5 + Double(piece.count) * 0.4
                if best[j] + cost < best[i] { best[i] = best[j] + cost; back[i] = j }
            }
        }
        var out: [String] = [], i = n
        while i > 0 { out.append(String(chars[back[i]..<i])); i = back[i] }
        return out.reversed()
    }

    /// A run cut where a lowercase letter meets a capital ("returnedTrue") and after an acronym ("STOPGOG|authorization").
    static func pieces(_ run: String) -> [String] {
        var out: [String] = [], cur = ""
        for ch in run {
            if ch.isUppercase, let last = cur.last, last.isLowercase, cur.count >= 2 { out.append(cur); cur = "" }
            if ch.isLowercase, cur.count >= 2, cur.allSatisfy(\.isUppercase) { out.append(cur); cur = "" }
            cur.append(ch)
        }
        if !cur.isEmpty { out.append(cur) }
        return acronyms(out)
    }

    /// "HQT|estFlight" → "HQ|TestFlight" when the acronym's last capital starts the word; "STOPGOG|authorization"
    /// stays; a lowercase tail under three letters ("IDs") stays with its capitals. Two capitals come off only before
    /// real words ("HQ|desktopapp"); "OAuth" stays whole.
    private static func acronyms(_ parts: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < parts.count {
            let p = parts[i]
            if p.count == 2, p.allSatisfy(\.isUppercase), i + 1 < parts.count, let f = parts[i + 1].first, f.isLowercase {
                let next = parts[i + 1]
                if next.count >= 4, segment(next).allSatisfy(isWord) { out.append(p); out.append(next) } else { out.append(p + next) }
                i += 2
                continue
            }
            if p.count >= 3, p.allSatisfy(\.isUppercase), i + 1 < parts.count, let f = parts[i + 1].first, f.isLowercase {
                let next = parts[i + 1]
                let lowerRun = String(next.prefix { $0.isLowercase })
                if lowerRun.count < 3 { out.append(p + next); i += 2; continue }
                let moved = String(p.last!) + next
                let movedWord = String(moved.prefix { $0.isLetter })
                func known(_ s: String) -> Bool { segment(s).allSatisfy(isWord) }
                if (!known(lowerRun) && known(String(moved.prefix(lowerRun.count + 1)))) || (!isWord(lowerRun) && isWord(movedWord)) {
                    out.append(String(p.dropLast())); out.append(moved)
                } else {
                    out.append(p); out.append(next)
                }
                i += 2
                continue
            }
            out.append(p)
            i += 1
        }
        return out
    }

    private static func repairRun(_ run: String) -> String {
        pieces(run).map { p in
            // Capitals alone ("INPRODUCTION") and words stay as written.
            guard p.count >= 6, !isWord(p), p.contains(where: \.isLowercase) else { return p }
            let split = segment(p)
            // A short run that splits in two is most often a compound ("subagent", "webhook"), unless one half is a
            // little word ("Howmany", "foruser").
            let little = split.contains { glue.contains($0.lowercased()) }
            return split.count == 2 && p.count < 9 && !little ? p : split.joined(separator: " ")
        }.joined(separator: " ")
    }

    // MARK: The message

    /// 8+ letters, not a word, splitting wholly into known words ("previouslyverified").
    private static func glued(_ p: String) -> Bool {
        guard p.count >= 8, p.contains(where: \.isLowercase), !isWord(p) else { return false }
        let split = segment(p)
        return split.count >= 2 && split.allSatisfy(isWord)
    }

    private static func untouchable(_ tok: Substring) -> Bool {
        tok.contains("@") || tok.contains("_") || tok.contains("://") || tok.contains("`")
            || tok.range(of: #"\.[A-Za-z]"#, options: .regularExpression) != nil
    }

    /// Plainly broken: at least three glued words, and at least one word in twenty.
    static func isBroken(_ text: String) -> Bool {
        let toks = text.split(whereSeparator: \.isWhitespace)
        let bad = toks.filter { tok in
            !untouchable(tok) && tok.split(whereSeparator: { !$0.isLetter }).flatMap { pieces(String($0)) }.contains(where: glued)
        }.count
        return bad >= 3 && Double(bad) >= Double(toks.count) * 0.05
    }

    private static func fix(_ text: String) -> String {
        guard isBroken(text) else { return text }
        // Code spans and blocks (between backticks) keep their words.
        let parts = text.components(separatedBy: "`")
        return parts.enumerated().map { $0.offset.isMultiple(of: 2) ? fixProse($0.element) : $0.element }.joined(separator: "`")
    }

    private static func fixProse(_ text: String) -> String {
        var out = ""
        var start = text.startIndex
        for tok in text.split(whereSeparator: \.isWhitespace) {
            out += text[start..<tok.startIndex]
            start = tok.endIndex
            let chars = Array(tok)
            // A slash is a path's only in something that looks like one ("cron/output/x.md"); in prose it joins words.
            let pathy = tok.hasPrefix("/") || tok.hasPrefix("~") || tok.contains("_")
                || tok.range(of: #"\.[A-Za-z]"#, options: .regularExpression) != nil || tok.contains("://") || tok.contains("@")
            var code: Set<Character> = ["_", ".", "@"]
            if pathy { code.insert("/") }
            func letter(_ k: Int) -> Bool {
                chars[k].isLetter || ((chars[k] == "'" || chars[k] == "’") && k > 0 && k + 1 < chars.count
                                      && chars[k - 1].isLetter && chars[k + 1].isLetter)
            }
            var i = 0
            while i < chars.count {
                guard letter(i) else { out.append(chars[i]); i += 1; continue }
                var j = i
                while j < chars.count, letter(j) { j += 1 }
                let run = String(chars[i..<j])
                let before: Character = i > 0 ? chars[i - 1] : " ", after: Character = j < chars.count ? chars[j] : " "
                // Letters against code marks or digits are names, files and addresses ("tick_phase.json", "tests3PASS");
                // a sentence's own full stop doesn't count.
                let endStop = after == "." && j + 1 == chars.count
                let touchesCode = code.contains(before) || (code.contains(after) && !endStop) || before.isNumber || after.isNumber
                out += touchesCode || isWord(run) ? run : repairRun(run)
                i = j
            }
        }
        return out + text[start...]
    }
}
