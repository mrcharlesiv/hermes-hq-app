// [WIN-LOST-SEND-MARKER] Sends that may never have arrived, kept beyond the chat's screen (93f984bb1
// HermesKit/Chat/LostSends.swift; docs/spec/3x-sessions.md §9.4): a message whose `prompt.submit` got no answer is marked
// "Delivery unconfirmed" in its chat; this keeps its words per chat so the Sessions row can say "Not Delivered: <words>"
// (the web's `row-pending.ts`). One per app (as the Mac's `LostSends.shared`); tests make their own over a temporary
// folder. On disk: one small JSON file per account, `{"v":1,"chats":{"<profile>\u001F<stored id>":[{id,text,at,after}]}}`,
// written 0.3 s after the last change, off the caller's thread. At most 20 entries per chat, 2,000 characters each.
// Thread-safe: chats note and clear from background threads, the list reads from the UI thread.

using System.Text.Json;
using System.Text.Json.Nodes;
using Hermes.Core.Voice;

namespace Hermes.Core.Sessions;

public sealed class LostSends
{
    /// `Id`: the local message id of the marked bubble. `After`: the newest stored row the chat knew when it was sent
    /// (a row with the same words past it means the send did arrive).
    public sealed record Entry(string Id, string Text, DateTimeOffset At, long? After = null);

    public const int MaxEntries = 20;
    public const int MaxCharacters = 2_000;

    /// A chat's entries changed (the Sessions rows read their pending lines again). Raised on the changing thread.
    public event Action? Changed;

    private readonly object _gate = new();
    private readonly object _writeGate = new();
    private readonly Dictionary<string, Dictionary<string, List<Entry>>> _accounts = [];
    private readonly HashSet<string> _loaded = [];
    private readonly Dictionary<string, int> _writeGeneration = [];
    private readonly string _base;

    /// `baseFolder`: where `lost-sends/` goes (the app's data folder; tests pass their own).
    public LostSends(string baseFolder) => _base = baseFolder;

    public static string Key(string profile, string chatId) => profile + "\u001F" + chatId;

    // ------------------------------------------------------------------ entries

    /// A send was marked: kept (an entry with the same id is replaced; the oldest goes past twenty).
    public void Note(string accountId, string profile, string chatId, Entry entry)
    {
        var text = entry.Text.Trim();
        if (chatId.Length == 0 || text.Length == 0) return;
        lock (_gate)
        {
            var chats = Chats(accountId);
            var key = Key(profile, chatId);
            var list = chats.TryGetValue(key, out var had) ? had : [];
            list.RemoveAll(e => e.Id == entry.Id);
            list.Add(entry with { Text = Cut(text) });
            if (list.Count > MaxEntries) list.RemoveRange(0, list.Count - MaxEntries);
            chats[key] = list;
        }
        Did(accountId);
    }

    /// The mark cleared (delivered after all, sent again, deleted).
    public void Clear(string accountId, string profile, string chatId, string id)
    {
        lock (_gate)
        {
            var chats = Chats(accountId);
            var key = Key(profile, chatId);
            if (!chats.TryGetValue(key, out var list) || list.RemoveAll(e => e.Id == id) == 0) return;
            if (list.Count == 0) chats.Remove(key);
        }
        Did(accountId);
    }

    /// The chat itself is gone (deleted): none of its entries stay behind, on disk either.
    public void Clear(string accountId, string profile, string chatId)
    {
        lock (_gate)
        {
            if (!Chats(accountId).Remove(Key(profile, chatId))) return;
        }
        Did(accountId);
    }

    /// The chat put an entry's bubble back under a new message id (said to no one: the row's words are the same).
    public void Rekey(string accountId, string profile, string chatId, string from, string to)
    {
        lock (_gate)
        {
            if (!Chats(accountId).TryGetValue(Key(profile, chatId), out var list)) return;
            var index = list.FindIndex(e => e.Id == from);
            if (index < 0) return;
            list[index] = list[index] with { Id = to };
        }
        Did(accountId, tell: false);
    }

    /// The oldest lost send of a chat: what its row names.
    public Entry? First(string accountId, string profile, string chatId) => Entries(accountId, profile, chatId).FirstOrDefault();

    public IReadOnlyList<Entry> Entries(string accountId, string profile, string chatId)
    {
        lock (_gate) return Chats(accountId).TryGetValue(Key(profile, chatId), out var list) ? [.. list] : [];
    }

    /// Every lost send the account's chats keep (Sign Out and Remove say how many they delete).
    public int Count(string accountId)
    {
        lock (_gate) return Chats(accountId).Values.Sum(l => l.Count);
    }

    // ------------------------------------------------------------------ account lifecycle

    /// Sign-out / gateway removal: the account's entries go, on disk too.
    public void Purge(string accountId)
    {
        lock (_gate)
        {
            _accounts.Remove(accountId);
            _loaded.Add(accountId);
            _writeGeneration[accountId] = _writeGeneration.GetValueOrDefault(accountId) + 1;
        }
        lock (_writeGate)
        {
            try { File.Delete(FilePath(accountId, _base)); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
        Changed?.Invoke();
    }

    /// Background (and tests): what is kept reaches the disk now.
    public void Flush()
    {
        string[] accounts;
        lock (_gate) accounts = [.. _accounts.Keys];
        foreach (var accountId in accounts) Save(accountId, TimeSpan.Zero);
        lock (_writeGate) { }   // a debounced write already running has finished
    }

    // ------------------------------------------------------------------ disk

    public static string FilePath(string accountId, string baseFolder) =>
        Path.Combine(baseFolder, "lost-sends", MemoPaths.AccountKey(accountId) + ".json");

    /// Everything kept for an account. A file this build cannot read (a newer shape, a torn write) reads as nothing.
    public static Dictionary<string, List<Entry>> Load(string accountId, string baseFolder)
    {
        var o = new Dictionary<string, List<Entry>>();
        JsonNode? root;
        try { root = JsonNode.Parse(File.ReadAllText(FilePath(accountId, baseFolder))); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException) { return o; }
        if (root is not JsonObject shape || shape["v"] is not JsonValue v || !v.TryGetValue<int>(out var version) || version != 1
            || shape["chats"] is not JsonObject chats) return o;
        foreach (var (key, node) in chats)
        {
            var list = new List<Entry>();
            foreach (var item in node as JsonArray ?? [])
            {
                if (item is not JsonObject e || e["id"]?.GetValueKind() != JsonValueKind.String) continue;
                var text = e["text"]?.GetValueKind() == JsonValueKind.String ? e["text"]!.GetValue<string>() : "";
                if (text.Length == 0) continue;
                var at = e["at"] is JsonValue a && a.TryGetValue<double>(out var seconds) ? seconds : 0;
                long? after = e["after"] is JsonValue r && r.TryGetValue<long>(out var row) ? row : null;
                list.Add(new Entry(e["id"]!.GetValue<string>(), Cut(text), DateTimeOffset.FromUnixTimeMilliseconds((long)Math.Round(at * 1000)), after));
            }
            if (list.Count > MaxEntries) list.RemoveRange(0, list.Count - MaxEntries);
            if (list.Count > 0) o[key] = list;
        }
        return o;
    }

    private static string Cut(string text) => text.Length > MaxCharacters ? text[..MaxCharacters] : text;

    /// The account's chats, read from disk the first time (under `_gate`).
    private Dictionary<string, List<Entry>> Chats(string accountId)
    {
        if (!_accounts.TryGetValue(accountId, out var chats)) _accounts[accountId] = chats = [];
        if (_loaded.Add(accountId))
            foreach (var (key, list) in Load(accountId, _base)) chats.TryAdd(key, list);
        return chats;
    }

    private void Did(string accountId, bool tell = true)
    {
        Save(accountId, TimeSpan.FromMilliseconds(300));
        if (tell) Changed?.Invoke();
    }

    private void Save(string accountId, TimeSpan delay)
    {
        int generation;
        lock (_gate)
        {
            generation = _writeGeneration[accountId] = _writeGeneration.GetValueOrDefault(accountId) + 1;
        }
        if (delay <= TimeSpan.Zero) { Write(accountId, generation); return; }
        _ = Task.Run(async () =>
        {
            await Task.Delay(delay);
            Write(accountId, generation);
        });
    }

    private void Write(string accountId, int generation)
    {
        lock (_writeGate)
        {
            JsonObject? shape = null;
            lock (_gate)
            {
                if (_writeGeneration.GetValueOrDefault(accountId) != generation) return;   // a later change writes
                var chats = new JsonObject();
                foreach (var (key, list) in _accounts.GetValueOrDefault(accountId) ?? [])
                {
                    if (list.Count == 0) continue;
                    chats[key] = new JsonArray([.. list.Select(e =>
                    {
                        var o = new JsonObject { ["id"] = e.Id, ["text"] = e.Text, ["at"] = e.At.ToUnixTimeMilliseconds() / 1000.0 };
                        if (e.After is { } after) o["after"] = after;
                        return (JsonNode)o;
                    })]);
                }
                if (chats.Count > 0) shape = new JsonObject { ["v"] = 1, ["chats"] = chats };
            }
            var file = FilePath(accountId, _base);
            try
            {
                if (shape == null) { File.Delete(file); return; }
                Directory.CreateDirectory(Path.GetDirectoryName(file)!);
                var temp = file + ".tmp";
                File.WriteAllText(temp, shape.ToJsonString());
                File.Move(temp, file, overwrite: true);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { /* the next change writes again */ }
        }
    }
}

/// What a chat's row says before its last message (93f984bb1 Contracts+sessions.swift `SessionPending`): a send that may
/// never have arrived, else words waiting in the field.
public sealed record SessionPending(bool Failed, string Text)
{
    public const string NotDeliveredPrefix = "Not Delivered:";
    public const string DraftPrefix = "Draft:";

    /// `rowPending` (`S/ui-lists/row-pending.ts:15-20`): the lost send first, then a non-empty trimmed draft.
    public static SessionPending? Pending(string? lost, string? draft)
    {
        if (lost != null) return new SessionPending(true, lost.Trim());
        var typed = (draft ?? "").Trim();
        return typed.Length == 0 ? null : new SessionPending(false, typed);
    }

    public string Prefix => Failed ? NotDeliveredPrefix : DraftPrefix;
}
