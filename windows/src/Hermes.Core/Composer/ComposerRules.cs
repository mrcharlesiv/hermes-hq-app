using System.Text.RegularExpressions;

namespace Hermes.Core.Composer;

/// The queue card's words (HermesKit/Chat/QueueWords.swift; docs/spec/3x-composer.md §15.3, §16), the web's strings.
public static class QueueWords
{
    /// The card's header for `count` waiting messages.
    public static string Header(int count, bool paused, bool running)
    {
        var one = count <= 1;
        if (paused) return one ? "Queue Paused" : $"Queue Paused · {count} Messages";
        if (running) return one ? "Queued · Sends After This Reply" : $"{count} Queued · Send After This Reply";
        return one ? "Queued" : $"{count} Queued";
    }

    /// What Narrator reads for the header ("Queue paused, 2 messages").
    public static string SpokenHeader(int count, bool paused, bool running)
    {
        var messages = count == 1 ? "1 message" : $"{count} messages";
        if (paused) return $"Queue paused, {messages}";
        if (running) return $"{messages} queued, {(count == 1 ? "sends" : "send")} after this reply";
        return $"{messages} queued";
    }

    /// Resume shows only while the queue is paused and something waits.
    public static bool ShowsResume(int count, bool paused) => paused && count > 0;

    /// The caption under a row: "Sending…" while it goes into the reply, "Editing" while its words are in the composer.
    public static string? Caption(bool sending, bool editing, string? attached)
    {
        if (sending) return "Sending…";
        if (editing) return attached is { } a ? $"Editing · {a}" : "Editing";
        return attached;
    }

    /// The name of a row's ⋯: "More, " and the row's opening words.
    public static string MoreLabel(string words)
    {
        var flat = string.Join(" ", words.Split('\n', '\r').Where(l => l.Length > 0)).Trim();
        if (flat.Length == 0) return "More";
        var shortText = flat.Length > 40 ? flat[..40].Trim() + "…" : flat;
        return "More, " + shortText;
    }

    /// The message field when a queued edit's row is gone by Save: the edited words over whatever the field held.
    public static string EditedField(string current, string queued)
    {
        if (current.Trim().Length == 0) return queued;
        if (queued.Trim().Length == 0) return current;
        return current.TrimEnd() + "\n" + queued;
    }

    /// The row's words as the card shows them (ChatQueueCard.swift `words`): the display, else the text, else
    /// "Empty Message"; a hidden goal continuation reads its display or "Continue toward goal".
    public static (string Text, bool Quiet) RowWords(QueuedMessage item)
    {
        if (item.Hidden)
            return (string.IsNullOrEmpty(item.Display) ? "Continue toward goal" : item.Display.Replace("\n", " "), true);
        var words = (item.Display ?? item.Text).Trim();
        if (words.Length == 0) return ("Empty Message", true);
        return (words.Replace("\n", " "), false);
    }

    public const string CannotSteer = "This can’t be added to the current reply";
    public const string SendNowSubtitle = "Adds it to the current reply";
    public const string StopAndSendSubtitle = "Stops the reply, then sends this";
}

/// L463: whether a queued message may be steered into the running reply (HermesKit/Contracts+composer.swift).
public static class SteerRule
{
    private static readonly Regex Slash = new(@"^\/[^\s/]*(?:\s|$)", RegexOptions.Compiled);

    /// `^\/[^\s/]*(?:\s|$)`: a slash command.
    public static bool IsSlashCommand(string text) => Slash.IsMatch(text);

    /// Steerable: visible text, nothing attached, not a slash command.
    public static bool Steerable(QueuedMessage m)
    {
        var t = m.Text.Trim();
        return !m.Hidden && t.Length > 0 && m.AttachmentCount == 0 && !IsSlashCommand(t);
    }

    public const string FailedNotice = "Couldn’t add this to the running reply. It’ll send after this reply.";
}

/// A Return in the empty field (HermesKit/Layout/KeyRules.swift EmptyReturn).
public enum EmptyReturn
{
    Nothing, SendNext, SendNowHead,
}

public static class EmptyReturnRule
{
    public static EmptyReturn Decide(bool running, int waiting, bool paused, bool canAct)
    {
        if (!canAct || waiting <= 0 || paused) return EmptyReturn.Nothing;
        return running ? EmptyReturn.SendNowHead : EmptyReturn.SendNext;
    }
}

/// The message field's text rules (HermesKit/Chat/ComposerKeyboard.swift).
public static class ComposerText
{
    /// Only line breaks (with or without spaces around them): the leftover of a Return in an empty field.
    public static bool IsLeftoverLineBreaks(string text) =>
        text.Any(c => c is '\n' or '\r') && text.Trim().Length == 0;

    /// What a send carries: no leading or trailing white space or line breaks; blank lines inside stay.
    public static string SendText(string text) => text.Trim();

    /// A saved prompt put in the field (ComposerView.swift `insertPrompt`): an empty or blank field takes it whole;
    /// otherwise it goes in at the caret, over any selection, with a space before it when the text there does not end
    /// in white space (`dictationInsert`). The caret ends after it. Nothing is sent.
    public static (string Text, int Caret) InsertPrompt(string text, int selectionStart, int selectionLength, string prompt)
    {
        if (string.IsNullOrWhiteSpace(text)) return (prompt, prompt.Length);
        var start = Math.Clamp(selectionStart, 0, text.Length);
        var length = Math.Clamp(selectionLength, 0, text.Length - start);
        var before = text[..start];
        var insert = (before.Length == 0 || char.IsWhiteSpace(before[^1]) ? "" : " ") + prompt;
        return (before + insert + text[(start + length)..], start + insert.Length);
    }
}

/// The Link… dialog's text rules (HermesKit/Chat/LinkText.swift; docs/spec/3x-composer.md §4.2).
public static class LinkText
{
    private static readonly Regex Scheme = new(@"^[a-z][a-z\d+.-]*://", RegexOptions.IgnoreCase);
    private static readonly Regex Host = new(@"^(?:[a-z\d](?:[a-z\d-]*[a-z\d])?\.)+[a-z]{2,}(?::\d{1,5})?$", RegexOptions.IgnoreCase);
    private static readonly Regex Ip = new(@"^\d{1,3}(?:\.\d{1,3}){3}(?::\d{1,5})?$");
    private static readonly Regex Http = new(@"^https?://.", RegexOptions.IgnoreCase);

    public const string Title = "Add Link";
    public const string Message = "The page is fetched and included with your next message.";
    public const string NotALink = "Include the full URL, e.g. https://…";
    public const string Placeholder = "https://example.com/post";

    /// What was typed, with `https://` added when it is a bare host ("example.com/post"). Nothing else changes.
    public static string Normalised(string text)
    {
        var t = text.Trim();
        if (t.Length == 0 || t.Any(char.IsWhiteSpace) || Scheme.IsMatch(t)) return t;
        var lower = t.ToLowerInvariant();
        foreach (var prefix in new[] { "mailto:", "tel:", "data:", "blob:", "file:" })
            if (lower.StartsWith(prefix, StringComparison.Ordinal)) return t;
        var host = new string(t.TakeWhile(c => c is not ('/' or '?' or '#')).ToArray());
        return Host.IsMatch(host) || Ip.IsMatch(host) ? "https://" + t : t;
    }

    /// http(s) with at least one character after the slashes.
    public static bool IsLink(string text) => Http.IsMatch(text);

    /// "https://example.com/a" → "example.com/a" for the tray chip.
    public static string Display(string url)
    {
        foreach (var prefix in new[] { "https://", "http://" })
            if (url.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) return url[prefix.Length..];
        return url;
    }
}

public static class RefValue
{
    /// `formatRefValue`: bare unless the value has white space or one of ()[]{}<>"'` ; backticks preferred, else
    /// double quotes, else single quotes.
    public static string Format(string value)
    {
        if (!value.Any(c => char.IsWhiteSpace(c) || "()[]{}<>\"'`".Contains(c))) return value;
        if (!value.Contains('`')) return $"`{value}`";
        if (!value.Contains('"')) return $"\"{value}\"";
        if (!value.Contains('\'')) return $"'{value}'";
        return value;
    }

    public static string UrlRef(string url) => "@url:" + Format(url);
}
