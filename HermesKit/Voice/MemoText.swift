// The only memo "format" on the wire (spec 1x-voice §4.1, W:src/voice-memo.ts:162-234, `memoParts`): a user turn whose
// text opens with `MEDIA:"<gateway path>"` and a "Voice memo transcript: …" line. Hermes has no notion of memos; the
// convention is client-side. `VoiceMemo` parses a stored message (moved here from App/Chat/VoiceMemo.swift, same API);
// `MemoText` builds the text a send submits.

import Foundation

nonisolated struct VoiceMemo: Equatable, Sendable {
    enum Transcript: Equatable, Sendable { case text(String), off, failed, pending }

    var path: String
    var transcript: Transcript
    /// Anything typed with the memo (the next bubble).
    var rest: String

    /// The memo's title: "Voice Memo" for a recorded memo (`voice-memo.wav`, `voice-memo-3.m4a`), else the audio
    /// file's name (`memoTitle`, never the gateway's copy name).
    var title: String {
        let name = (path as NSString).lastPathComponent
        return VoiceMemo.isRecordedMemoName(name) ? "Voice Memo" : name
    }

    /// `voice-memo.m4a`, `voice-memo-3.wav`: how clients recognise a recorded memo (W:src/voice-memo.ts:12).
    static func isRecordedMemoName(_ name: String) -> Bool {
        name.range(of: #"^voice-memo(?:-\d+)?\.[a-z0-9]+$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The transcript as the bubble shows it.
    var transcriptText: String {
        switch transcript {
        case .text(let t): return t
        case .off: return "No transcript: speech-to-text is off on your gateway."
        case .failed, .pending: return "No transcript"
        }
    }

    var hasTranscript: Bool { if case .text = transcript { return true } else { return false } }

    /// [menus] What Copy and Select Text take from your memo message: the transcript, then anything typed with it; the
    /// transcript line ("Voice Memo: (no transcript)") when there are no words.
    var copyText: String {
        let words = [hasTranscript ? transcriptText : "", rest].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return words.isEmpty ? transcriptLine : words
    }

    /// One line for a plain-text transcript ("Voice memo: …").
    var transcriptLine: String {
        let said = hasTranscript ? transcriptText : "(no transcript)"
        return ["\(title): \(said)", rest].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static let off = "(unavailable: speech-to-text is off on the gateway)"
    static let failed = "(unavailable)"
    static let noSpeech = "(No speech detected)"
    static let audioExtensions = ["m4a", "mp3", "wav", "aac", "ogg", "opus", "flac", "aiff", "caf"]
    private static let audio = #"\.(?:m4a|mp3|wav|aac|ogg|opus|flac|aiff|caf)$"#
    private static let directive = try! NSRegularExpression(pattern: #"^\s*MEDIA:"([^"\r\n]+)"[ \t]*(?:\r?\n|$)"#)
    private static let transcriptLineRE = try! NSRegularExpression(pattern: #"^Voice memo transcript: ([^\r\n]*)"#)

    /// `gatewayMemoPath`: an absolute POSIX path (no backslash) or a Windows drive path, to an audio file.
    static func isMemoPath(_ path: String) -> Bool {
        guard !path.isEmpty, path.rangeOfCharacter(from: CharacterSet(charactersIn: "\r\n\"")) == nil,
              path.range(of: audio, options: [.regularExpression, .caseInsensitive]) != nil else { return false }
        if path.hasPrefix("/") { return !path.contains("\\") }
        return path.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil
    }

    /// A message that opens with a voice memo, else nil.
    static func parse(_ text: String) -> VoiceMemo? {
        guard text.contains("MEDIA:\"") else { return nil }
        let ns = text as NSString
        guard let match = directive.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let path = ns.substring(with: match.range(at: 1))
        guard isMemoPath(path) else { return nil }
        var rest = ns.substring(from: match.range.location + match.range.length)
        while let first = rest.first, first == "\n" || first == "\r" || first == " " || first == "\t" {
            // Blank lines between the directive and the transcript (`^(?:[ \t]*\r?\n)+`).
            guard let newline = rest.firstIndex(where: { $0 == "\n" }),
                  rest[..<newline].allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\r" }) else { break }
            rest = String(rest[rest.index(after: newline)...])
        }
        var transcript = Transcript.pending
        let restNS = rest as NSString
        if let line = transcriptLineRE.firstMatch(in: rest, range: NSRange(location: 0, length: restNS.length)) {
            let said = restNS.substring(with: line.range(at: 1)).trimmingCharacters(in: .whitespaces)
            transcript = said == off ? .off : said == failed ? .failed : said.isEmpty ? .pending : .text(said)
            rest = restNS.substring(from: line.range.location + line.range.length)
        }
        return VoiceMemo(path: path, transcript: transcript, rest: rest.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Building a memo's message text (spec §4.1).
nonisolated enum MemoText {
    /// How the transcript step ended.
    enum Said: Equatable, Sendable {
        case text(String)
        /// The gateway answered with no words.
        case empty
        /// Speech-to-text is off on the gateway.
        case off
        /// The call failed (the memo still goes).
        case failed
    }

    /// `MEDIA:"<gateway path>"\n\nVoice memo transcript: <said>`.
    static func reference(path: String, said: Said) -> String {
        let words: String
        switch said {
        case .text(let t):
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            words = trimmed.isEmpty ? VoiceMemo.noSpeech : trimmed
        case .empty: words = VoiceMemo.noSpeech
        case .off: words = VoiceMemo.off
        case .failed: words = VoiceMemo.failed
        }
        return "MEDIA:\"\(path)\"\n\nVoice memo transcript: \(words)"
    }

    /// `[reference, typed].filter(nonEmpty).joined("\n\n")` (V:…/submit.ts:200-209).
    static func prompt(reference: String, typed: String) -> String {
        [reference, typed.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// The optimistic bubble before the upload: `MEDIA:"<local path>"` (+ "\n\n" + typed).
    static func optimistic(localPath: String, typed: String) -> String {
        prompt(reference: "MEDIA:\"\(localPath)\"", typed: typed)
    }

    /// The memo's gateway path as the directive quotes it, or nil when the directive can't carry it (a quote or a line
    /// break, a relative path, a backslash in a POSIX path, or not audio): then the gateway's `ref_text` goes instead.
    static func gatewayMemoPath(_ path: String?) -> String? {
        guard let path, VoiceMemo.isMemoPath(path) else { return nil }
        return path
    }

    /// A reference sent without its transcript (STT off, or the call failed): a later send of the same memo may still
    /// get one, so it is not reused (W:src/voice-memo.ts `memoTranscriptMissing`).
    static func transcriptMissing(_ reference: String) -> Bool {
        reference.hasSuffix("Voice memo transcript: " + VoiceMemo.off) || reference.hasSuffix("Voice memo transcript: " + VoiceMemo.failed)
    }
}
