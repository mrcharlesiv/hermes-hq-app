// [WIN-SENT-TITLES] A request sent with a short title for its bubble (docs/spec/3x-presence.md §10; 93f984bb1
// HermesKit/Presence/SentTitles.swift). The stored row holds the whole prompt, so wherever the chat reads its transcript
// (from its cache when it opens, at every history read, and when older rows load) the bubble would swap its title for
// the long prompt. This maps the stored prompt back to its title. The app's fixed pairs are noted at sign-in
// (AppState.Adopt, the Mac's AppModel.startPresence), so the title also shows after a relaunch and on a device that did
// not send it; others last for the run. A handful of entries, matched on the exact prompt (whitespace flattened).
//
// The other direction too: a refused send hands the bubble's words (the title) back to the field, and a queue row taken
// out to edit does the same. Sent again from the main bot's field, the title goes out as the request it stands for
// (`Prompt`), never as its bare sentence (ChatSession.SendAsync).
//
// Windows' titled requests: the Bot Screen setup request (ChatComposer.SendScreenSetup). The Mac's fixed pairs (the
// browser plugin's request and its update, the notification add-on offer) have no Windows counterpart yet, so
// FixedPairs is empty. Not ported: the Mac's title(forStored:) extras for a goal's Plan With ask and phone-call
// messages (GoalBots.planBubble, PhoneChatNote, PhoneResultMessage), which Windows does not send.
//
// The Mac keeps one static (`LiveChatSession.sentTitles`); Windows keeps one per app (Shared, which AppState hands
// every HermesClient), and a client made without it keeps its own (tests). Locked: chats read it from their own threads.

using Hermes.Core.Model;

namespace Hermes.Core.Chat;

public sealed class SentTitles
{
    public const int Limit = 8;

    /// The app's one list (the Mac's static `LiveChatSession.sentTitles`).
    public static SentTitles Shared { get; } = new();

    /// The app's fixed requests and their titles, noted at every sign-in. None on Windows yet (see above).
    public static IReadOnlyList<(string Text, string Title)> FixedPairs { get; } = [];

    private readonly object _lock = new();
    /// The prompt as stored (whitespace flattened) → the title its bubble shows.
    private readonly Dictionary<string, string> _titles = [];
    /// The same key → the prompt as it was sent (line breaks and all), for sending it again.
    private readonly Dictionary<string, string> _prompts = [];
    private readonly List<string> _order = [];

    public bool IsEmpty { get { lock (_lock) return _titles.Count == 0; } }

    public void Note(string text, string title)
    {
        var key = Flat(text);
        if (key.Length == 0 || title.Length == 0 || key == Flat(title)) return;
        lock (_lock)
        {
            if (!_titles.ContainsKey(key)) _order.Add(key);
            _titles[key] = title;
            _prompts[key] = text;
            while (_order.Count > Limit)
            {
                var dropped = _order[0];
                _order.RemoveAt(0);
                _titles.Remove(dropped);
                _prompts.Remove(dropped);
            }
        }
    }

    /// Signed in: the fixed pairs (noting the same pair again changes nothing).
    public void NoteFixedPairs()
    {
        foreach (var (text, title) in FixedPairs) Note(text, title);
    }

    /// The title a stored user row shows, when it is one of the titled prompts (the whole prompt, whitespace aside).
    public string? Title(string stored)
    {
        lock (_lock) return _titles.GetValueOrDefault(Flat(stored));
    }

    /// The request a title stands for, when `typed` is exactly one of the titles (whitespace aside).
    public string? Prompt(string typed)
    {
        var wanted = Flat(typed);
        if (wanted.Length == 0) return null;
        lock (_lock)
        {
            for (var i = _order.Count - 1; i >= 0; i--)
                if (Flat(_titles[_order[i]]) == wanted) return _prompts[_order[i]];
            return null;
        }
    }

    /// Stored rows as the chat shows them: a user row that is one of the titled prompts shows its title (its other
    /// parts, a photo, stay; its words become the title). Nothing noted: the same list back.
    public IReadOnlyList<ChatMessage> Applied(IReadOnlyList<ChatMessage> messages)
    {
        if (IsEmpty) return messages;
        var shown = new List<ChatMessage>(messages.Count);
        foreach (var m in messages)
        {
            if (m.Role != Role.User || Title(m.Text) is not { } title) { shown.Add(m); continue; }
            shown.Add(m with { Parts = [.. m.Parts.Where(p => p is not TextPart), new TextPart(title)] });
        }
        return shown;
    }

    /// ChatText.flat: whitespace runs folded to one space, ends trimmed (`text.replace(/\s+/g, ' ').trim()`).
    public static string Flat(string text) =>
        string.Join(' ', text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
}
