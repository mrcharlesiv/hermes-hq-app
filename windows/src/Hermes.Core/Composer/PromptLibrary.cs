using System.Text.Json;

namespace Hermes.Core.Composer;

/// One saved prompt (HermesKit/Chat/PromptLibrary.swift SavedPrompt).
public sealed record SavedPrompt(Guid Id, string Title, string Text, DateTimeOffset Updated)
{
    public static SavedPrompt New(string title, string text) => new(Guid.NewGuid(), title, text, DateTimeOffset.UtcNow);

    /// The list's name for it: its title, else its first line that has words.
    public string DisplayTitle
    {
        get
        {
            var title = Title.Trim();
            if (title.Length > 0) return title;
            var line = Text.Split('\n', '\r').Select(l => l.Trim()).FirstOrDefault(l => l.Length > 0);
            return line == null ? "Untitled Prompt" : line[..Math.Min(80, line.Length)];
        }
    }

    /// Under the title: the text on one line (the first line drops when it is the title already).
    public string Preview
    {
        get
        {
            var lines = Text.Split('\n', '\r').Select(l => l.Trim()).Where(l => l.Length > 0).ToList();
            if (Title.Trim().Length == 0 && lines.Count > 0) lines.RemoveAt(0);
            return string.Join(" ", lines);
        }
    }
}

/// A deleted prompt and the place it had in the list (for Undo).
public sealed record DeletedPrompt(int Index, SavedPrompt Prompt);

/// ⋯ › Prompts: a library kept on this PC, for every bot and chat. A click puts one in the message box.
/// Stored as JSON under "hq.prompts.library" (the Mac's defaults key).
public sealed class PromptLibrary
{
    public const string StoreKey = "hq.prompts.library";
    private readonly IKeyValueStore _store;
    private List<SavedPrompt> _prompts;

    public event Action? Changed;

    public PromptLibrary(IKeyValueStore store)
    {
        _store = store;
        _prompts = Load();
    }

    private List<SavedPrompt> Load()
    {
        try { return _store.Get(StoreKey) is { } text ? JsonSerializer.Deserialize<List<SavedPrompt>>(text) ?? [] : []; }
        catch (JsonException) { return []; }
    }

    public IReadOnlyList<SavedPrompt> Prompts => _prompts;

    /// Saves a new prompt at the top; blank text saves nothing. The same text twice keeps one (moved to the top).
    public SavedPrompt? Add(string text, string title = "")
    {
        var body = text.Trim();
        if (body.Length == 0) return null;
        var name = title.Trim();
        var at = _prompts.FindIndex(p => p.Text.Trim() == body);
        SavedPrompt saved;
        if (at >= 0)
        {
            var existing = _prompts[at];
            _prompts.RemoveAt(at);
            saved = existing with { Title = name.Length > 0 ? name : existing.Title, Updated = DateTimeOffset.UtcNow };
        }
        else saved = SavedPrompt.New(name, body);
        _prompts.Insert(0, saved);
        Save();
        return saved;
    }

    /// Edits one in place; blank text deletes it.
    public void Update(Guid id, string title, string text)
    {
        var at = _prompts.FindIndex(p => p.Id == id);
        if (at < 0) return;
        var body = text.Trim();
        if (body.Length == 0) { Delete([id]); return; }
        _prompts[at] = _prompts[at] with { Title = title.Trim(), Text = body, Updated = DateTimeOffset.UtcNow };
        Save();
    }

    /// Removes them; returns what went and where it was (for Undo, `Restore`).
    public IReadOnlyList<DeletedPrompt> Delete(IReadOnlyCollection<Guid> ids)
    {
        var gone = _prompts.Select((p, i) => new DeletedPrompt(i, p)).Where(d => ids.Contains(d.Prompt.Id)).ToList();
        if (gone.Count == 0) return gone;
        _prompts.RemoveAll(p => ids.Contains(p.Id));
        Save();
        return gone;
    }

    /// Undo of a delete: each prompt goes back at the place it had.
    public void Restore(IEnumerable<DeletedPrompt> deleted)
    {
        var changed = false;
        foreach (var item in deleted.OrderBy(d => d.Index))
        {
            if (_prompts.Any(p => p.Id == item.Prompt.Id)) continue;
            _prompts.Insert(Math.Min(item.Index, _prompts.Count), item.Prompt);
            changed = true;
        }
        if (changed) Save();
    }

    /// Moves one prompt to `to` (after it is taken out).
    public void Move(int from, int to)
    {
        if (from < 0 || from >= _prompts.Count) return;
        var p = _prompts[from];
        _prompts.RemoveAt(from);
        _prompts.Insert(Math.Max(0, Math.Min(to, _prompts.Count)), p);
        Save();
    }

    public bool Contains(string text) => _prompts.Any(p => p.Text.Trim() == text.Trim());

    /// Sign Out of the last gateway: the next person to sign in on this PC doesn't see them.
    public void RemoveAll()
    {
        _prompts = [];
        _store.Set(StoreKey, null);
        Changed?.Invoke();
    }

    private void Save()
    {
        _store.Set(StoreKey, JsonSerializer.Serialize(_prompts));
        Changed?.Invoke();
    }

    // The Mac's words (App/Chat/Menus/PromptsSheet.swift), "click" for its "tap".
    public const string Title = "Prompts";
    public const string EmptyTitle = "No Prompts Yet";
    public const string EmptyText = "Keep the prompts you use often here. A click puts one in the message box.";
    public const string Footer = "A click puts the prompt in the message box. Kept on this PC, for every bot and chat.";
    public const string NewPrompt = "New Prompt…";
    public const string EditPrompt = "Edit Prompt";
    public const string TitlePlaceholder = "Title (optional)";
    public const string TextPlaceholder = "Write the prompt…";
    public const string SaveCurrent = "Save Current Message";
    public const string PutInBox = "Put in Message Box";
    public const string Saved = "Saved to Prompts";

    /// The subtitle the ⋯ row shows ("3 saved"), null for none.
    public string? MenuSubtitle => _prompts.Count switch { 0 => null, 1 => "1 saved", var n => $"{n} saved" };
}
