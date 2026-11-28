using System.Text.Json;
using System.Text.Json.Nodes;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Shell;

/// Kind of open chat represented by a workspace tab (HermesKit/Layout/WorkspaceTabs.swift `WorkspaceTabRecord.Kind`).
/// Only open sessions and bot chats appear on the top bar; sidebar sections are never workspace tabs.
public enum WorkspaceTabKind
{
    Session,
    Bot,
}

/// Pure state record for one open workspace tab (HermesKit/Layout/WorkspaceTabs.swift `WorkspaceTabRecord`).
public sealed record WorkspaceTabRecord(WorkspaceTabKind Kind, string Profile, string Id, string Title)
{
    public string TabId => Kind == WorkspaceTabKind.Session ? $"session:{Profile}:{Id}" : $"bot:{Id}";

    internal JsonObject ToJson() => new()
    {
        ["kind"] = Kind == WorkspaceTabKind.Bot ? "bot" : "session",
        ["profile"] = Profile,
        ["id"] = Id,
        ["title"] = Title,
    };

    internal static WorkspaceTabRecord? FromJson(JsonNode? node)
    {
        if (node is not JsonObject obj) return null;
        var kindText = obj["kind"] is JsonValue kv && kv.TryGetValue(out string? ks) ? ks : null;
        WorkspaceTabKind kind;
        if (string.Equals(kindText, "session", StringComparison.OrdinalIgnoreCase)) kind = WorkspaceTabKind.Session;
        else if (string.Equals(kindText, "bot", StringComparison.OrdinalIgnoreCase)) kind = WorkspaceTabKind.Bot;
        else return null;
        var profile = obj["profile"] is JsonValue pv && pv.TryGetValue(out string? ps) ? ps : "";
        var id = obj["id"] is JsonValue iv && iv.TryGetValue(out string? ids) ? ids : "";
        var title = obj["title"] is JsonValue tv && tv.TryGetValue(out string? ts) ? ts : "";
        if (string.IsNullOrEmpty(id)) return null;
        return new WorkspaceTabRecord(kind, profile, id, title);
    }
}

/// Pure state & persistence rules for browser-style open-chats-only workspace tabs (HermesKit/Layout/WorkspaceTabs.swift):
/// - Opened sessions and bot chats append on the right and stay until explicitly closed (no auto-eviction cap).
/// - Re-opening an already-open tab updates its title in place without moving it (stable spatial order).
/// - Closing the active tab selects the neighboring tab (right if present, otherwise left; null if last tab).
/// - Closing an inactive tab leaves the current view untouched.
/// - Open tabs persist per gateway account under `HQMacWorkspaceTabs.<gatewayId>`.
public sealed class WorkspaceTabList
{
    private readonly List<WorkspaceTabRecord> _tabs = [];

    public WorkspaceTabList(IEnumerable<WorkspaceTabRecord>? tabs = null)
    {
        if (tabs == null) return;
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var tab in tabs)
            if (seen.Add(tab.TabId)) _tabs.Add(tab);
    }

    public IReadOnlyList<WorkspaceTabRecord> Tabs => _tabs;

    /// Ensures `record` is present in the strip. If already open, updates its title in place without moving it;
    /// otherwise appends it on the right (stable spatial order, no cap).
    public bool Open(WorkspaceTabRecord record)
    {
        var idx = _tabs.FindIndex(t => t.TabId == record.TabId);
        if (idx >= 0)
        {
            if (!string.IsNullOrEmpty(record.Title) && _tabs[idx].Title != record.Title)
            {
                _tabs[idx] = _tabs[idx] with { Title = record.Title };
                return true;
            }
            return false;
        }
        _tabs.Add(record);
        return true;
    }

    /// Updates title in place for an already-open tab. Returns true if changed.
    public bool UpdateTitle(string tabId, string title)
    {
        if (string.IsNullOrEmpty(title)) return false;
        var idx = _tabs.FindIndex(t => t.TabId == tabId);
        if (idx < 0 || _tabs[idx].Title == title) return false;
        _tabs[idx] = _tabs[idx] with { Title = title };
        return true;
    }

    /// Closes the tab with `tabId`. When closing the active tab, returns the adjacent tab to activate next
    /// (the tab that shifts into the same slot on the right, or the tab to its left if it was rightmost, or null if empty).
    public (bool Removed, WorkspaceTabRecord? NextActive) Close(string tabId, string? activeTabId)
    {
        var idx = _tabs.FindIndex(t => t.TabId == tabId);
        if (idx < 0) return (false, null);
        _tabs.RemoveAt(idx);
        if (!string.Equals(activeTabId, tabId, StringComparison.Ordinal)) return (true, null);
        if (_tabs.Count == 0) return (true, null);
        var nextIdx = idx < _tabs.Count ? idx : _tabs.Count - 1;
        return (true, _tabs[nextIdx]);
    }

    /// Closes every tab except `keepingTabId`. Returns true if any tab was removed.
    public bool CloseOthers(string keepingTabId)
    {
        var before = _tabs.Count;
        _tabs.RemoveAll(t => t.TabId != keepingTabId);
        return _tabs.Count != before;
    }

    /// Closes every tab to the right of `tabId`. Returns true if any tab was removed.
    public bool CloseToRight(string tabId)
    {
        var idx = _tabs.FindIndex(t => t.TabId == tabId);
        if (idx < 0 || idx + 1 >= _tabs.Count) return false;
        _tabs.RemoveRange(idx + 1, _tabs.Count - (idx + 1));
        return true;
    }

    /// Closes all open tabs. Returns true if any tab was removed.
    public bool CloseAll()
    {
        if (_tabs.Count == 0) return false;
        _tabs.Clear();
        return true;
    }

    /// The slot Show Next Tab (`step` 1) or Show Previous Tab (`step` -1) lands on in a row of `count` tabs,
    /// wrapping round at either end. With no active tab (a page that has no tab of its own), starts at the first tab
    /// going forward or the last tab going backwards. Null when there is nowhere else to go.
    public static int? CycledIndex(int count, int? active, int step)
    {
        if (count <= 0 || step == 0) return null;
        if (active is not { } current || current < 0 || current >= count)
            return step > 0 ? 0 : count - 1;
        if (count <= 1) return null;
        var next = ((current + step) % count + count) % count;
        return next == current ? null : next;
    }

    /// Returns the tab id that must be suppressed from re-recording during an async detail-pane transition after
    /// closing tab(s): only set when `activeId` itself was removed (App/Mac/MacWorkspaceBar.swift `closingGuardId`).
    public static string? ClosingGuardId(IReadOnlySet<string> removedIds, string? activeId) =>
        activeId != null && removedIds.Contains(activeId) ? activeId : null;

    // ------------------------------------------------------------------ Persistence (per gateway)

    public const string StoragePrefix = "HQMacWorkspaceTabs.";

    public static string StorageKey(string? gatewayId)
    {
        var clean = (gatewayId ?? "").Trim();
        return StoragePrefix + (clean.Length == 0 ? "default" : clean);
    }

    public static WorkspaceTabList Load(string? gatewayId, IPreferences? prefs)
    {
        if (prefs == null) return new WorkspaceTabList();
        var raw = prefs.Get(StorageKey(gatewayId));
        if (string.IsNullOrWhiteSpace(raw)) return new WorkspaceTabList();
        try
        {
            if (JsonNode.Parse(raw) is not JsonArray arr) return new WorkspaceTabList();
            var records = new List<WorkspaceTabRecord>(arr.Count);
            foreach (var item in arr)
                if (WorkspaceTabRecord.FromJson(item) is { } rec) records.Add(rec);
            return new WorkspaceTabList(records);
        }
        catch (JsonException)
        {
            return new WorkspaceTabList();
        }
    }

    public void Save(string? gatewayId, IPreferences? prefs)
    {
        if (prefs == null) return;
        var key = StorageKey(gatewayId);
        if (_tabs.Count == 0)
        {
            prefs.Set(key, null);
            return;
        }
        var arr = new JsonArray();
        foreach (var tab in _tabs) arr.Add(tab.ToJson());
        prefs.Set(key, arr.ToJsonString());
    }
}

/// Destination entry tracked by the top workspace bar's Back/Forward navigation history
/// (App/Mac/MacWorkspaceBar.swift `Destination`).
public abstract record WorkspaceNavDestination
{
    public virtual string? TabId => null;
}

public sealed record WorkspacePlaceNav(string PlaceId, string? Argument = null) : WorkspaceNavDestination;

public sealed record WorkspaceBotNav(string BotId) : WorkspaceNavDestination
{
    public override string? TabId => $"bot:{BotId}";
}

public sealed record WorkspaceSessionNav(string Profile, string SessionId) : WorkspaceNavDestination
{
    public override string? TabId => $"session:{Profile}:{SessionId}";
}

public sealed record WorkspaceRoomNav(string RoomKey) : WorkspaceNavDestination;

/// Bounded Back/Forward navigation history stack (cap 40, App/Mac/MacWorkspaceBar.swift `history`).
public sealed class WorkspaceHistory
{
    public const int MaxEntries = 40;

    private readonly List<WorkspaceNavDestination> _entries = [];
    private int _index = -1;

    public int Count => _entries.Count;
    public int CurrentIndex => _index;
    public WorkspaceNavDestination? Current => _index >= 0 && _index < _entries.Count ? _entries[_index] : null;
    public bool CanGoBack => _index > 0;
    public bool CanGoForward => _index >= 0 && _index + 1 < _entries.Count;

    /// Records a newly visited destination, collapsing consecutive duplicates, dropping any truncated forward tail,
    /// and capping the stack at 40 entries.
    public void Record(WorkspaceNavDestination destination)
    {
        if (_index >= 0 && _index < _entries.Count && _entries[_index].Equals(destination)) return;
        if (_index + 1 < _entries.Count)
            _entries.RemoveRange(_index + 1, _entries.Count - (_index + 1));
        _entries.Add(destination);
        if (_entries.Count > MaxEntries)
            _entries.RemoveAt(0);
        _index = _entries.Count - 1;
    }

    public WorkspaceNavDestination? GoBack()
    {
        if (!CanGoBack) return null;
        _index--;
        return _entries[_index];
    }

    public WorkspaceNavDestination? GoForward()
    {
        if (!CanGoForward) return null;
        _index++;
        return _entries[_index];
    }

    public void Clear()
    {
        _entries.Clear();
        _index = -1;
    }
}
