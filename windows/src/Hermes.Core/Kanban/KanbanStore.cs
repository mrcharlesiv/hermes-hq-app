using System.Text.Json.Nodes;
using Hermes.Core.Net;

namespace Hermes.Core.Kanban;

public sealed record KanbanStoreTiming
{
    public TimeSpan Poll { get; init; } = TimeSpan.FromSeconds(30);
    public TimeSpan BoardsStale { get; init; } = TimeSpan.FromSeconds(30);
    public TimeSpan ProfilesStale { get; init; } = TimeSpan.FromSeconds(60);
    /// The wait before a failed board read is asked once more (one quick retry, none after a timeout).
    public TimeSpan RetryDelay { get; init; } = TimeSpan.FromMilliseconds(1500);
    public static KanbanStoreTiming Standard { get; } = new();
}

/// Where the chosen board is kept between launches (one per account).
public interface IKanbanPrefs
{
    string? Get(string key);
    void Set(string key, string? value);
}

public sealed class MemoryKanbanPrefs : IKanbanPrefs
{
    private readonly Dictionary<string, string?> _values = [];
    public string? Get(string key) => _values.GetValueOrDefault(key);
    public void Set(string key, string? value) => _values[key] = value;
}

/// The Kanban page's data (HermesKit/Pages/KanbanStore.swift; docs/spec/1x-pages.md §4): the chosen board, boards, bots
/// and the fallback assignee; optimistic writes that undo only the failed task (R21, §4.5); a read every 30 s while the
/// page shows, after each write and on a board switch.
///
/// One thread only, as the Mac's KanbanStore is @MainActor: call it from a thread with a SynchronizationContext that
/// runs posted work one at a time (the app's UI thread; MainLoop in the tests), and nothing here awaits with
/// ConfigureAwait(false), so every answer is put away on that thread and `Changed`, `WriteFailed` and `Notice` are raised
/// there. Its state (the optimistic board, the board generation, the count of writes on their way) is plain fields:
/// called from a thread with no such context, two quick moves have their answers handled on pool threads, along with
/// the board reads that follow them and their `Changed` (KanbanStoreThreadTests). The dispatcher nudge after a write is
/// KanbanNudger's own, off this thread, and touches nothing here.
public sealed class KanbanStore
{
    public KanbanApi Api { get; }
    public string AccountId { get; }
    private readonly IKanbanPrefs _prefs;
    private readonly KanbanStoreTiming _timing;
    public bool ReadOnlyGateway { get; set; }

    /// The board the user picked ('' = the server's current board).
    public string Slug { get; private set; }
    public KanbanBoards? Boards { get; private set; }
    /// The shown board's snapshot (optimistic edits applied).
    public KanbanBoard? Board { get; private set; }
    public string? BoardError { get; private set; }
    public bool LoadingBoard { get; private set; }
    public IReadOnlyList<KanbanProfile> Profiles { get; private set; } = [];
    /// `default_assignee` ('' when unset: an unassigned Ready task never runs).
    public string Fallback { get; private set; } = "";
    /// `resolved_default_assignee` (New Task's preselection).
    public string ResolvedDefault { get; private set; } = "default";

    public event Action? Changed;
    /// A write failed: the gateway's detail (the board puts back only that task).
    public event Action<string>? WriteFailed;
    /// A write was refused before sending (read-only gateway, a locked status).
    public event Action<string>? Notice;

    private int _boardGeneration;
    private int _nextToken = 1;
    private int _writesInFlight;
    private DateTimeOffset? _boardsReadAt, _profilesReadAt;
    private bool _boardsInFlight, _profilesInFlight, _visible;
    private CancellationTokenSource? _poll;

    public static string SlugKey(string accountId) => "pages.kanbanBoard." + accountId;

    public KanbanStore(KanbanApi api, string accountId, IKanbanPrefs? prefs = null, KanbanStoreTiming? timing = null)
    {
        Api = api;
        AccountId = accountId;
        _prefs = prefs ?? new MemoryKanbanPrefs();
        _timing = timing ?? KanbanStoreTiming.Standard;
        Slug = _prefs.Get(SlugKey(accountId)) ?? "";
    }

    // ------------------------------------------------------------------ derived

    /// The board key ('' resolves to the server's current slug when known).
    public string BoardKey => Slug.Length == 0 ? Boards?.Current ?? "" : Slug;
    public KanbanBoardMeta? CurrentMeta => Boards?.Boards.FirstOrDefault(b => b.Slug == BoardKey);
    public string BoardTitle => KanbanModel.BoardTitle(CurrentMeta?.Slug ?? BoardKey, CurrentMeta?.Name);
    /// The board button's picker: a menu up to eight boards, the pushed list beyond.
    public KanbanBoardPickerStyle BoardPickerStyle => KanbanBoardPicker.StyleFor(Boards?.Boards.Count ?? 0);
    public IReadOnlyList<KanbanBoardChoice> BoardChoices => KanbanBoardPicker.Choices(Boards, BoardKey);

    private void Raise() => Changed?.Invoke();

    // ------------------------------------------------------------------ visibility and polling

    public void SetVisible(bool shown)
    {
        _visible = shown;
        _poll?.Cancel();
        _poll = null;
        if (!shown) return;
        RefreshAll(force: false);
        var cts = _poll = new CancellationTokenSource();
        _ = PollAsync(cts.Token);
    }

    private async Task PollAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try { await Task.Delay(_timing.Poll, ct); } catch (OperationCanceledException) { return; }
            if (_visible) await ReadBoardAsync();
        }
    }

    public void Stop() { _poll?.Cancel(); _poll = null; }

    // ------------------------------------------------------------------ reads

    /// Board now; boards if > 30 s old; bots and fallback if > 60 s old (`force`: all of them).
    public void RefreshAll(bool force)
    {
        _ = ReadBoardAsync();
        RefreshLists(force);
    }

    /// Refresh (F5): every list again, and the board read awaited. The reason when that read failed while a board is
    /// still shown (it stays as saved), else null.
    public async Task<string?> RefreshAsync()
    {
        RefreshLists(force: true);
        var failure = await ReadBoardAsync();
        return Board != null ? failure : null;
    }

    private void RefreshLists(bool force)
    {
        var now = DateTimeOffset.UtcNow;
        if (force || (!_boardsInFlight && (_boardsReadAt is not { } b || now - b > _timing.BoardsStale))) _ = ReadBoardsAsync();
        if (force || (!_profilesInFlight && (_profilesReadAt is not { } p || now - p > _timing.ProfilesStale))) _ = ReadProfilesAsync();
    }

    /// The reason when this read failed; null when it landed or a newer read superseded it.
    public async Task<string?> ReadBoardAsync()
    {
        var generation = ++_boardGeneration;
        var slug = Slug;
        LoadingBoard = true;
        Raise();
        try
        {
            KanbanBoard fresh;
            try { fresh = await Api.BoardAsync(slug); }
            catch (GatewayException e) when (e is { Code: "http", Status: 502 or 503 or 504 })
            {
                // One quick retry for a gateway that hiccuped; none after a timeout or while it can't be reached.
                await Task.Delay(_timing.RetryDelay);
                fresh = await Api.BoardAsync(slug);
            }
            if (generation != _boardGeneration || slug != Slug) return null;
            Board = fresh;
            BoardError = null;
            LoadingBoard = false;
            Raise();
            return null;
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            if (generation != _boardGeneration || slug != Slug) return null;
            BoardError = KanbanRest.Reason(e);
            LoadingBoard = false;
            Raise();
            return BoardError;
        }
    }

    public async Task ReadBoardsAsync()
    {
        _boardsInFlight = true;
        try
        {
            var fresh = await Api.BoardsAsync();
            Boards = fresh;
            _boardsReadAt = DateTimeOffset.UtcNow;
            // A picked board that no longer exists falls back to the current one.
            if (Slug.Length > 0 && !fresh.Boards.Any(b => b.Slug == Slug)) Select("");
            Raise();
        }
        catch (Exception) { }
        finally { _boardsInFlight = false; }
    }

    public async Task ReadProfilesAsync()
    {
        _profilesInFlight = true;
        try
        {
            var people = Api.ProfilesAsync();
            var orchestration = Api.OrchestrationAsync();
            try { Profiles = await people; _profilesReadAt = DateTimeOffset.UtcNow; } catch (Exception) { }
            try { (Fallback, ResolvedDefault) = await orchestration; } catch (Exception) { }
            Raise();
        }
        finally { _profilesInFlight = false; }
    }

    /// A board pick: the server's current board stores ''.
    public void Select(string next)
    {
        var stored = next == Boards?.Current ? "" : next;
        if (stored == Slug) return;
        Slug = stored;
        _prefs.Set(SlugKey(AccountId), stored);
        _boardGeneration++;
        BoardError = null;
        Board = null;
        Raise();
        _ = ReadBoardAsync();
    }

    // ------------------------------------------------------------------ writes (optimistic, §4.5)

    private bool Refused()
    {
        if (!ReadOnlyGateway) return false;
        Notice?.Invoke(KanbanRest.ReadOnlyNotice);
        return true;
    }

    /// Apply `edit`, send `write` on the board it started on, then read the board and the boards list again whatever
    /// happens. A failure puts back only this task (R21). `failed`: the caller tells the failure itself (an alert with
    /// Try Again) in place of `WriteFailed`.
    private async Task<bool> Optimistic(string id, Func<KanbanBoard, int, KanbanBoard> edit, Func<string, Task> write,
        Action<string>? failed = null)
    {
        var started = Slug;
        _boardGeneration++;
        var token = ++_nextToken;
        var before = Board;
        var after = before == null ? null : edit(before, token);
        if (after != null) { Board = after; Raise(); }
        _writesInFlight++;
        try
        {
            await write(started);
            return true;
        }
        catch (Exception e)
        {
            if (before != null && after != null && Board is { } now && Slug == started)
            {
                Board = KanbanModel.RestoreTask(now, before, after, id);
                Raise();
            }
            var reason = KanbanRest.Reason(e);
            if (failed != null) failed(reason); else WriteFailed?.Invoke(reason);
            return false;
        }
        finally
        {
            // The board is read again once the last of quick writes has landed.
            if (--_writesInFlight == 0) _ = ReadBoardAsync();
            _ = ReadBoardsAsync();
        }
    }

    public async Task MoveAsync(KanbanTask task, string to, Action<string>? failed = null)
    {
        if (task.Status == to) return;
        if (KanbanModel.IsLocked(to)) { Notice?.Invoke(KanbanModel.LockedReason(to)); return; }
        if (Refused()) return;
        await Optimistic(task.Id, (b, t) => KanbanModel.MoveCard(b, task.Id, to, t),
            board => Api.PatchAsync(task.Id, new JsonObject { ["status"] = to }, board), failed);
    }

    /// "" unassigns (the gateway's reassign takes an empty profile as none).
    public async Task AssignAsync(KanbanTask task, string profile, Action<string>? failed = null)
    {
        var next = profile.Length == 0 ? null : profile;
        if (task.Assignee == next) return;
        if (Refused()) return;
        await Optimistic(task.Id, (b, t) => KanbanModel.EditCard(b, task.Id, t, x => x with { Assignee = next }),
            board => Api.ReassignAsync(task.Id, profile, board), failed);
    }

    /// Archive: removed at once; on success the caller shows the Undo pill. Returns the board it left (for Undo).
    public async Task<string?> ArchiveAsync(KanbanTask task, Action<string>? failed = null)
    {
        if (Refused()) return null;
        var started = Slug;
        var ok = await Optimistic(task.Id, (b, _) => KanbanModel.RemoveCard(b, task.Id),
            board => Api.PatchAsync(task.Id, new JsonObject { ["status"] = "archived" }, board), failed);
        return ok ? started : null;
    }

    /// Undo an archive on the board it left. Returns the gateway's reason when it failed (the caller offers Try Again).
    public async Task<string?> UnarchiveAsync(KanbanTask task, string status, string board)
    {
        string? failure = null;
        try { await Api.PatchAsync(task.Id, new JsonObject { ["status"] = status }, board); }
        catch (Exception e) { failure = KanbanRest.Reason(e); }
        await ReadBoardAsync();
        await ReadBoardsAsync();
        return failure;
    }

    public async Task<bool> DeleteAsync(KanbanTask task, Action<string>? failed = null)
    {
        if (Refused()) return false;
        return await Optimistic(task.Id, (b, _) => KanbanModel.RemoveCard(b, task.Id), board => Api.DeleteAsync(task.Id, board), failed);
    }

    /// New Task (§4.7). Throws with the gateway's reason; returns a warning to show, if any. `board`: the board New Task
    /// was opened on (default: the board showing now); the create and its move to Start In both go there.
    public async Task<string?> CreateAsync(string title, string body, string? assignee, int priority, IReadOnlyList<string> skills,
        string start, bool goalMode, string? board = null)
    {
        if (ReadOnlyGateway) throw new PagesMessageException(KanbanRest.ReadOnlyNotice);
        var fields = new JsonObject
        {
            ["title"] = title.Trim(), ["priority"] = priority, ["triage"] = start == "triage", ["goal_mode"] = goalMode,
        };
        if (body.Trim() is { Length: > 0 } details) fields["body"] = details;
        if (!string.IsNullOrEmpty(assignee)) fields["assignee"] = assignee;
        if (skills.Count > 0) fields["skills"] = new JsonArray([.. skills.Select(s => (JsonNode)JsonValue.Create(s)!)]);
        var started = board ?? Slug;
        var created = await Api.CreateAsync(fields, started);
        if (created.Task is { } made && made.Status != start)
        {
            try { await Api.PatchAsync(made.Id, new JsonObject { ["status"] = start }, started); } catch (Exception) { }
        }
        _ = ReadBoardAsync();
        _ = ReadBoardsAsync();
        return created.Warning;
    }

    public void Reset() { Stop(); Board = null; Boards = null; }
}
