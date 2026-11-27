using System.Globalization;
using System.Text.Json.Nodes;
using Hermes.Core.Net;

namespace Hermes.Core.Kanban;

/// The Kanban plugin's REST calls (HermesKit/Pages/KanbanAPI.swift; docs/spec/1x-pages.md §4.1): `/api/plugins/kanban/*`,
/// with `?board=<slug>` only for a board other than the server's current one ('' = current). Every write names the
/// board it started on; a successful create/patch/delete/reassign/reclaim nudges the dispatcher 400 ms later.
public sealed class KanbanApi(IPagesRest rest, KanbanNudger? nudger = null)
{
    public const string Base = "/api/plugins/kanban";
    public IPagesRest Rest { get; } = rest;
    public KanbanNudger Nudger { get; } = nudger ?? new KanbanNudger(rest);

    private static string TaskPath(string id, string tail = "") => Base + "/tasks/" + KanbanRest.Segment(id) + tail;

    public async Task<KanbanBoards> BoardsAsync(TimeSpan? timeout = null, CancellationToken ct = default) =>
        KanbanBoards.From(await Rest.JsonAsync(HttpMethod.Get, Base + "/boards", timeout: timeout, ct: ct));

    public async Task<KanbanBoard> BoardAsync(string board, CancellationToken ct = default) =>
        KanbanBoard.From(await Rest.JsonAsync(HttpMethod.Get, Base + "/board", KanbanRest.Query(board), ct: ct));

    public async Task<KanbanTaskDetail> TaskAsync(string id, string board, CancellationToken ct = default) =>
        KanbanTaskDetail.From(await Rest.JsonAsync(HttpMethod.Get, TaskPath(id), KanbanRest.Query(board), ct: ct))
        ?? throw new PagesMessageException("The gateway sent a task this app can’t read.");

    public async Task<(bool Exists, string Content)> LogAsync(string id, string board, CancellationToken ct = default)
    {
        var json = await Rest.JsonAsync(HttpMethod.Get, TaskPath(id, "/log"), KanbanRest.Query(board, ("tail", "16384")), ct: ct);
        return (json.Bool("exists") ?? false, json.Str("content") ?? "");
    }

    public async Task<List<KanbanProfile>> ProfilesAsync(CancellationToken ct = default)
    {
        var json = await Rest.JsonAsync(HttpMethod.Get, Base + "/profiles", ct: ct);
        return [.. (json.Arr("profiles") ?? []).Select(r => r.Str("name") is { } n ? new KanbanProfile(n, r.Bool("is_default") ?? false) : null)
            .OfType<KanbanProfile>()];
    }

    /// The board's fallback for unassigned Ready cards (`default_assignee`, '' when unset) and New Task's preselection.
    public async Task<(string Fallback, string Resolved)> OrchestrationAsync(CancellationToken ct = default)
    {
        var json = await Rest.JsonAsync(HttpMethod.Get, Base + "/orchestration", ct: ct);
        var resolved = (json.Str("resolved_default_assignee") ?? "").Trim();
        return ((json.Str("default_assignee") ?? "").Trim(), resolved.Length == 0 ? "default" : resolved);
    }

    /// Saves an attachment's bytes to `file`.
    public Task AttachmentAsync(string id, string board, string file, CancellationToken ct = default) =>
        Rest.DownloadAsync(Base + "/attachments/" + KanbanRest.Segment(id), KanbanRest.Query(board), file,
            KanbanAttachmentUpload.MaxBytes * 4, ct);

    public sealed record Created(KanbanTask? Task, string? Warning);

    public async Task<Created> CreateAsync(JsonObject body, string board, CancellationToken ct = default)
    {
        var json = await Rest.JsonAsync(HttpMethod.Post, Base + "/tasks", KanbanRest.Query(board), body, ct: ct);
        Nudger.Nudge(board);
        return new Created(KanbanTask.From(json.Get("task")), json.Str("warning"));
    }

    public async Task<KanbanTask?> PatchAsync(string id, JsonObject body, string board, CancellationToken ct = default)
    {
        var json = await Rest.JsonAsync(HttpMethod.Patch, TaskPath(id), KanbanRest.Query(board), body, ct: ct);
        Nudger.Nudge(board);
        return KanbanTask.From(json.Get("task"));
    }

    public async Task DeleteAsync(string id, string board, CancellationToken ct = default)
    {
        await Rest.JsonAsync(HttpMethod.Delete, TaskPath(id), KanbanRest.Query(board), ct: ct);
        Nudger.Nudge(board);
    }

    public Task CommentAsync(string id, string body, string board, CancellationToken ct = default) =>
        Rest.JsonAsync(HttpMethod.Post, TaskPath(id, "/comments"), KanbanRest.Query(board),
            new JsonObject { ["author"] = "desktop", ["body"] = body }, ct: ct);

    public async Task ReassignAsync(string id, string profile, string board, CancellationToken ct = default)
    {
        await Rest.JsonAsync(HttpMethod.Post, TaskPath(id, "/reassign"), KanbanRest.Query(board),
            new JsonObject { ["profile"] = profile, ["reclaim_first"] = true }, ct: ct);
        Nudger.Nudge(board);
    }

    public async Task ReclaimAsync(string id, string board, CancellationToken ct = default)
    {
        await Rest.JsonAsync(HttpMethod.Post, TaskPath(id, "/reclaim"), KanbanRest.Query(board), new JsonObject(), ct: ct);
        Nudger.Nudge(board);
    }

    /// Makes a model call on the gateway: only on an explicit click.
    public async Task<string> EstimateAsync(string id, string board, CancellationToken ct = default)
    {
        var json = await Rest.JsonAsync(HttpMethod.Post, TaskPath(id, "/estimate"), KanbanRest.Query(board), new JsonObject(),
            TimeSpan.FromSeconds(120), ct);
        if (json.Bool("ok") != true) throw new PagesMessageException(json.Str("reason") ?? "Couldn’t estimate this task.");
        return EstimateWords(json.Num("est_tokens") ?? 0, json.Str("complexity") ?? "");
    }

    /// "About 12K tokens · medium".
    public static string EstimateWords(double tokens, string complexity)
    {
        string compact;
        if (tokens >= 1_000_000) compact = (Math.Round(tokens / 100_000) / 10).ToString("0.##", CultureInfo.InvariantCulture) + "M";
        else if (tokens >= 1000) compact = (Math.Round(tokens / 100) / 10).ToString("0.##", CultureInfo.InvariantCulture) + "K";
        else compact = ((int)tokens).ToString(CultureInfo.InvariantCulture);
        return $"About {compact} tokens{(complexity.Length == 0 ? "" : $" · {complexity}")}";
    }

    /// Uploads `file` as `filename` (KanbanAttachmentUpload.swift): a multipart body with the one part `file`, built in
    /// `scratch` and always removed.
    public async Task<KanbanAttachment?> AddAttachmentAsync(string id, string file, string filename, string board, string? scratch = null,
        long limit = KanbanAttachmentUpload.MaxBytes, Action<long, long>? progress = null, CancellationToken ct = default)
    {
        var built = KanbanAttachmentUpload.BuildFileOnly(file, filename, KanbanAttachmentUpload.ContentType(filename),
            Attachments.MultipartBody.NewBoundary(), scratch ?? Path.GetTempPath(), limit, ct);
        try
        {
            var answer = await Rest.UploadAsync(TaskPath(id, "/attachments"), KanbanRest.Query(board), built.ContentType, built.FilePath,
                TimeSpan.FromSeconds(300), progress, ct);
            var item = J.Parse(answer).Get("attachment");
            if (KanbanRest.Id(item, "id") is not { } aid) return null;
            return new KanbanAttachment(aid, item.Str("filename") ?? filename, item.Int("size"));
        }
        finally
        {
            try { File.Delete(built.FilePath); } catch (IOException) { }
        }
    }
}

/// The dispatcher nudge: one `POST /dispatch` per board, 400 ms after the last successful write to it.
public sealed class KanbanNudger(IPagesRest rest, TimeSpan? delay = null)
{
    private readonly Lock _lock = new();
    private readonly Dictionary<string, CancellationTokenSource> _timers = [];
    public TimeSpan Delay { get; } = delay ?? TimeSpan.FromMilliseconds(400);

    public void Nudge(string board)
    {
        CancellationTokenSource cts;
        lock (_lock)
        {
            if (_timers.TryGetValue(board, out var old)) old.Cancel();
            _timers[board] = cts = new CancellationTokenSource();
        }
        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(Delay, cts.Token);
                await rest.JsonAsync(HttpMethod.Post, KanbanApi.Base + "/dispatch", KanbanRest.Query(board), new JsonObject());
            }
            catch (Exception) { /* fire and forget */ }
        });
    }
}

/// Is Kanban on? (§4.2): the gateway's Kanban API answers and a board holds a task.
public enum KanbanAvailability { On, Unused, Absent }

public static class KanbanProbe
{
    /// null on a transport failure (keep the last decision).
    public static async Task<KanbanAvailability?> ProbeAsync(KanbanApi api, CancellationToken ct = default)
    {
        try
        {
            var boards = await api.BoardsAsync(TimeSpan.FromSeconds(10), ct);
            return boards.TaskCount > 0 ? KanbanAvailability.On : KanbanAvailability.Unused;
        }
        catch (GatewayException e) when (e.Code == "http" && e.Status is 404 or 403) { return KanbanAvailability.Absent; }
        catch (Exception) { return null; }
    }
}
