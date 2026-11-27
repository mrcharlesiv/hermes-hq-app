using System.Globalization;
using System.Text.RegularExpressions;

namespace Hermes.Core.Voice;

// The only memo "format" on the wire (docs/spec/1x-voice.md §4.1; HermesKit/Voice/MemoText.swift at 93f984bb1): a user
// turn whose text opens with `MEDIA:"<gateway path>"` and a "Voice memo transcript: …" line. Hermes has no notion of
// memos; the convention is client-side. `VoiceMemo` parses a stored message; `MemoText` builds the text a send submits.
// Pure: no file, microphone, clipboard or network access.

public enum MemoTranscriptKind { Text, Off, Failed, Pending }

/// `VoiceMemo.Transcript`: `.text(words)`, `.off`, `.failed` or `.pending`. `Text` is empty except for `.text`.
public sealed record MemoTranscript(MemoTranscriptKind Kind, string Text = "")
{
    public static readonly MemoTranscript Off = new(MemoTranscriptKind.Off);
    public static readonly MemoTranscript Failed = new(MemoTranscriptKind.Failed);
    public static readonly MemoTranscript Pending = new(MemoTranscriptKind.Pending);
    public static MemoTranscript Words(string text) => new(MemoTranscriptKind.Text, text);
}

public sealed record VoiceMemo(string Path, MemoTranscript Transcript, string Rest)
{
    public const string OffMarker = "(unavailable: speech-to-text is off on the gateway)";
    public const string FailedMarker = "(unavailable)";
    public const string NoSpeech = "(No speech detected)";
    public static readonly IReadOnlyList<string> AudioExtensions = ["m4a", "mp3", "wav", "aac", "ogg", "opus", "flac", "aiff", "caf"];

    private static readonly Regex Audio = new(@"\.(?:m4a|mp3|wav|aac|ogg|opus|flac|aiff|caf)$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    private static readonly Regex DrivePath = new(@"^[A-Za-z]:[\\/]", RegexOptions.CultureInvariant);
    private static readonly Regex RecordedName = new(@"^voice-memo(?:-\d+)?\.[a-z0-9]+$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    // NSRegularExpression's `$` (no multiline) also matches before one final line terminator (\r\n, \n, \r, U+0085,
    // U+2028, U+2029); .NET's only before a final \n, so the lookahead spells the Mac's out.
    private static readonly Regex Directive = new(
        "^\\s*MEDIA:\"([^\"\\r\\n]+)\"[ \\t]*(?:\\r?\\n|(?=(?:\\r\\n|[\\n\\r\\u0085\\u2028\\u2029])?\\z))", RegexOptions.CultureInvariant);
    private static readonly Regex TranscriptLineRe = new(@"^Voice memo transcript: ([^\r\n]*)", RegexOptions.CultureInvariant);

    /// The memo's title: "Voice Memo" for a recorded memo (`voice-memo.wav`, `voice-memo-3.m4a`), else the audio file's
    /// name (never the gateway's copy name). Windows reads both separators, so `C:\memos\otter.wav` is "otter.wav".
    public string Title
    {
        get
        {
            var name = Path[(Path.LastIndexOfAny(['/', '\\']) + 1)..];
            return IsRecordedMemoName(name) ? "Voice Memo" : name;
        }
    }

    /// `voice-memo.m4a`, `voice-memo-3.wav`: how clients recognise a recorded memo.
    public static bool IsRecordedMemoName(string name) => RecordedName.IsMatch(name);

    public bool HasTranscript => Transcript.Kind == MemoTranscriptKind.Text;

    /// The transcript as the bubble shows it.
    public string TranscriptText => Transcript.Kind switch
    {
        MemoTranscriptKind.Text => Transcript.Text,
        MemoTranscriptKind.Off => "No transcript: speech-to-text is off on your gateway.",
        _ => "No transcript",
    };

    /// What Copy and Select Text take from your memo message: the transcript, then anything typed with it (a blank line
    /// between); the transcript line ("Voice Memo: (no transcript)") when there are no words.
    public string CopyText
    {
        get
        {
            var words = string.Join("\n\n", new[] { HasTranscript ? TranscriptText : "", Rest }.Where(s => s.Length > 0));
            return words.Length == 0 ? TranscriptLine : words;
        }
    }

    /// One line for a plain-text transcript ("Voice Memo: …"), then anything typed with it on the next line.
    public string TranscriptLine
    {
        get
        {
            var said = HasTranscript ? TranscriptText : "(no transcript)";
            return string.Join("\n", new[] { $"{Title}: {said}", Rest }.Where(s => s.Length > 0));
        }
    }

    /// `gatewayMemoPath`: an absolute POSIX path (no backslash) or a Windows drive path, to an audio file, with no quote
    /// or line break.
    public static bool IsMemoPath(string? path)
    {
        if (string.IsNullOrEmpty(path) || path.IndexOfAny(['\r', '\n', '"']) >= 0 || !Audio.IsMatch(path)) return false;
        if (path.StartsWith('/')) return !path.Contains('\\');
        return DrivePath.IsMatch(path);
    }

    /// A message that opens with a voice memo, else null.
    public static VoiceMemo? Parse(string? text)
    {
        if (text == null || !text.Contains("MEDIA:\"", StringComparison.Ordinal)) return null;
        var match = Directive.Match(text);
        if (!match.Success) return null;
        var path = match.Groups[1].Value;
        if (!IsMemoPath(path)) return null;
        var rest = text[(match.Index + match.Length)..];
        while (rest.Length > 0 && rest[0] is '\n' or '\r' or ' ' or '\t')
        {
            // Blank lines between the directive and the transcript (`^(?:[ \t]*\r?\n)+`).
            var newline = rest.IndexOf('\n');
            if (newline < 0 || rest[..newline].Any(c => c is not (' ' or '\t' or '\r'))) break;
            rest = rest[(newline + 1)..];
        }
        var transcript = MemoTranscript.Pending;
        var line = TranscriptLineRe.Match(rest);
        if (line.Success)
        {
            var said = TrimWhitespace(line.Groups[1].Value);
            transcript = said == OffMarker ? MemoTranscript.Off
                : said == FailedMarker ? MemoTranscript.Failed
                : said.Length == 0 ? MemoTranscript.Pending
                : MemoTranscript.Words(said);
            rest = rest[(line.Index + line.Length)..];
        }
        return new VoiceMemo(path, transcript, TrimWhitespaceAndNewlines(rest));
    }

    // Foundation's CharacterSet.whitespaces: tab and Unicode Zs.
    private static bool IsWhitespace(char c) => c == '\t' || char.GetUnicodeCategory(c) == UnicodeCategory.SpaceSeparator;

    // CharacterSet.whitespacesAndNewlines: the above plus U+000A–U+000D, U+0085, U+2028, U+2029.
    private static bool IsWhitespaceOrNewline(char c) => IsWhitespace(c) || c is (>= '\n' and <= '\r') or '\u0085' or '\u2028' or '\u2029';

    internal static string TrimWhitespace(string s) => Trim(s, IsWhitespace);
    internal static string TrimWhitespaceAndNewlines(string s) => Trim(s, IsWhitespaceOrNewline);

    private static string Trim(string s, Func<char, bool> drop)
    {
        int start = 0, end = s.Length;
        while (start < end && drop(s[start])) start++;
        while (end > start && drop(s[end - 1])) end--;
        return s[start..end];
    }
}

/// How the transcript step ended: words, the gateway answered with none, speech-to-text is off, or the call failed
/// (the memo still goes).
public enum MemoSaidKind { Text, Empty, Off, Failed }

public sealed record MemoSaid(MemoSaidKind Kind, string Text = "")
{
    public static readonly MemoSaid Empty = new(MemoSaidKind.Empty);
    public static readonly MemoSaid Off = new(MemoSaidKind.Off);
    public static readonly MemoSaid Failed = new(MemoSaidKind.Failed);
    public static MemoSaid Words(string text) => new(MemoSaidKind.Text, text);
}

/// Building a memo's message text (spec §4.1).
public static class MemoText
{
    private const string TranscriptPrefix = "Voice memo transcript: ";

    /// `MEDIA:"<gateway path>"\n\nVoice memo transcript: <said>`.
    public static string Reference(string path, MemoSaid said)
    {
        var words = said.Kind switch
        {
            MemoSaidKind.Text => VoiceMemo.TrimWhitespaceAndNewlines(said.Text) is { Length: > 0 } t ? t : VoiceMemo.NoSpeech,
            MemoSaidKind.Empty => VoiceMemo.NoSpeech,
            MemoSaidKind.Off => VoiceMemo.OffMarker,
            _ => VoiceMemo.FailedMarker,
        };
        return $"MEDIA:\"{path}\"\n\n{TranscriptPrefix}{words}";
    }

    /// `[reference, typed].filter(nonEmpty).joined("\n\n")`, typed trimmed.
    public static string Prompt(string reference, string typed) =>
        string.Join("\n\n", new[] { reference, VoiceMemo.TrimWhitespaceAndNewlines(typed) }.Where(s => s.Length > 0));

    /// The optimistic bubble before the upload: `MEDIA:"<local path>"` (+ "\n\n" + typed).
    public static string Optimistic(string localPath, string typed) => Prompt($"MEDIA:\"{localPath}\"", typed);

    /// The memo's gateway path as the directive quotes it, or null when the directive can't carry it (a quote or a line
    /// break, a relative path, a backslash in a POSIX path, or not audio): then the gateway's `ref_text` goes instead.
    public static string? GatewayMemoPath(string? path) => VoiceMemo.IsMemoPath(path) ? path : null;

    /// A reference sent without its transcript (STT off, or the call failed): a later send of the same memo may still
    /// get one, so it is not reused.
    public static bool TranscriptMissing(string reference) =>
        reference.EndsWith(TranscriptPrefix + VoiceMemo.OffMarker, StringComparison.Ordinal)
        || reference.EndsWith(TranscriptPrefix + VoiceMemo.FailedMarker, StringComparison.Ordinal);

    /// The memo bubble's words (App/Chat/Voice/MemoBubbleContent.swift `MemoBubbleInfo.make(…).wordsText`): `pending`,
    /// your memo is still sending; `failed`, its send failed before a transcript.
    public static string BubbleWords(VoiceMemo memo, bool pending, bool failed) => memo.Transcript.Kind switch
    {
        MemoTranscriptKind.Text => memo.Transcript.Text,
        MemoTranscriptKind.Off => "No transcript: speech-to-text is off on your gateway.",
        MemoTranscriptKind.Failed => "No transcript",
        _ => failed ? "Transcription unavailable. Check the memo’s delivery status." : pending ? "Transcribing…" : "No transcript",
    };
}
