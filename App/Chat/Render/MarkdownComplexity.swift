import Foundation

// Markdown parsers are super-linear or deeply recursive on a few shapes no real reply has: quotes or lists nested
// hundreds deep, paragraphs of unmatched emphasis delimiters, thousands of unclosed brackets, very long runs of one
// character. swift-markdown converts cmark's tree recursively, so a long `>>>>…` line overflows a 512 KB thread stack.
// One linear pass finds them first and such a text is drawn as plain text (spec 03 §9.3; a port of the renderer's
// `src/markdown/complexity.ts`, same limits, same scan).

nonisolated enum MarkdownComplexity {
    /// Container markers ('- ', '> ', '1. ') opening one line.
    static let maxNesting = 32
    /// Leading spaces before a list marker.
    static let maxListIndent = 128
    /// Emphasis delimiters that can open ('*' before a non-space, '_' starting a word) in one paragraph.
    static let maxDelimiters = 500
    /// '[' or '<' in one paragraph.
    static let maxBrackets = 1000
    /// One character repeated: '*'/'_' runs outside fences, and any space/tab/backtick/tilde/'*'/'_' run.
    static let maxDelimiterRun = 256
    static let maxRun = 1000

    enum Verdict: Equatable {
        /// Parse on the calling thread.
        case simple
        /// Within the limits but deep enough that the recursive conversion wants a big stack.
        case deep
        /// Past a limit: draw as plain text.
        case tooComplex
    }

    /// Below these, parsing needs well under the 512 KB of a GCD worker's stack.
    private static let deepNesting = 12
    private static let deepRun = 24
    private static let deepDelimiters = 64

    static func isTooComplex(_ text: String) -> Bool { verdict(text) == .tooComplex }

    static func verdict(_ text: String) -> Verdict {
        var copy = text
        return copy.withUTF8 { scan($0) }
    }

    // Byte scan over UTF-8. Every test is on ASCII, and a non-ASCII byte counts as a word character, exactly as the
    // JS scan treats UTF-16 units above 127.
    private static func scan(_ b: UnsafeBufferPointer<UInt8>) -> Verdict {
        let n = b.count
        func at(_ i: Int) -> Int { i >= 0 && i < n ? Int(b[i]) : -1 }
        func space(_ c: Int) -> Bool { c == 32 || c == 9 }
        func word(_ c: Int) -> Bool { (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c > 127 }

        var fence: (Int, Int, Int)? = nil       // the opener's three bytes
        var delimiters = 0, brackets = 0
        var deep = false
        var start = 0
        while start <= n {
            var end = start
            while end < n && b[end] != 10 { end += 1 }
            // Leading indentation, then container markers.
            var cursorAt = start, indent = 0
            while cursorAt < end && space(Int(b[cursorAt])) { indent += b[cursorAt] == 9 ? 4 : 1; cursorAt += 1 }
            // The next three bytes (a newline or the text's end among them never matches a fence).
            let opener = (at(cursorAt), at(cursorAt + 1), at(cursorAt + 2))
            let isFence = opener == (96, 96, 96) || opener == (126, 126, 126)
            if let f = fence {
                if opener == f { fence = nil }
            } else if isFence {
                fence = opener
            } else if cursorAt == end {
                delimiters = 0; brackets = 0
            } else {
                var depth = 0, cursor = cursorAt
                while true {
                    let code = at(cursor)
                    if cursor >= end { break }
                    if code == 62 { depth += 1; cursor += 1 }
                    else if (code == 45 || code == 42 || code == 43) && space(at(cursor + 1)) { depth += 1; cursor += 2 }
                    else if code >= 48 && code <= 57 {
                        var digit = cursor + 1
                        while digit < end && digit - cursor < 9 && at(digit) >= 48 && at(digit) <= 57 { digit += 1 }
                        let mark = at(digit)
                        if (mark == 46 || mark == 41) && space(at(digit + 1)) { depth += 1; cursor = digit + 2 } else { break }
                    } else { break }
                    while cursor < end && space(at(cursor)) { cursor += 1 }
                    if depth > maxNesting { return .tooComplex }
                }
                if depth > deepNesting { deep = true }
                if depth > 0 && indent > maxListIndent { return .tooComplex }
                // A list item or heading starts its own run of inline text.
                if depth > 0 || at(cursor) == 35 { delimiters = 0; brackets = 0 }
                // A table row's cells are parsed one at a time, so nothing in them adds up across the paragraph.
                let row = at(cursorAt) == 124
                if !row {
                    var index = cursor
                    while index < end {
                        let code = Int(b[index])
                        if code == 42 || code == 95 {
                            if code == 42 ? (index + 1 < end && !space(at(index + 1))) : !word(at(index - 1)) { delimiters += 1 }
                        } else if code == 91 || code == 60 {
                            brackets += 1
                        }
                        if delimiters > maxDelimiters || brackets > maxBrackets { return .tooComplex }
                        index += 1
                    }
                    if delimiters > deepDelimiters { deep = true }
                }
            }
            // Runs of one character, fenced code included (the preprocessors read it too).
            var runCode = -1, run = 0
            var index = start
            while index < end {
                let code = Int(b[index])
                if code == runCode {
                    run += 1
                    if run > maxRun || (run > maxDelimiterRun && fence == nil && (code == 42 || code == 95)) { return .tooComplex }
                    if run > deepRun && (code == 42 || code == 95) { deep = true }
                } else {
                    runCode = (code == 32 || code == 9 || code == 42 || code == 95 || code == 96 || code == 126) ? code : -1
                    run = 1
                }
                index += 1
            }
            start = end + 1
        }
        return deep ? .deep : .simple
    }
}

/// Runs work on one long-lived thread with a 16 MB stack: the backstop for parsing markdown whose shape is within the
/// limits but nests deeply. Callers block until their work is done (it is short, and only odd texts come here).
nonisolated final class BigStackRunner: @unchecked Sendable {
    static let shared = BigStackRunner()

    private let condition = NSCondition()
    private var jobs: [() -> Void] = []
    private var thread: Thread?

    private init() {
        let thread = Thread { [unowned self] in self.loop() }
        thread.stackSize = 16 << 20
        thread.qualityOfService = .userInitiated
        thread.name = "hq.chat.markdown-deep"
        self.thread = thread
        thread.start()
    }

    private func loop() {
        while true {
            condition.lock()
            while jobs.isEmpty { condition.wait() }
            let job = jobs.removeFirst()
            condition.unlock()
            job()
        }
    }

    private final class Box<T>: @unchecked Sendable { var value: T?; init() {} }

    func run<T>(_ body: @escaping () -> T) -> T {
        if Thread.current === thread { return body() }
        let box = Box<T>()
        let done = DispatchSemaphore(value: 0)
        condition.lock()
        jobs.append { box.value = body(); done.signal() }
        condition.signal()
        condition.unlock()
        done.wait()
        return box.value!
    }
}
