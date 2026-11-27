using System.Text.Json.Nodes;
using Hermes.Core.Chat;
using Hermes.Core.Model;
using Hermes.Core.Net;
using Hermes.Core.Rpc;

namespace Hermes.Core.Composer;

/// A slash command's output row (spec 1x §8.4): a local system row, never cached. `Command` is "/status" (null for an
/// alias's re-run or "empty slash command").
public sealed record SlashOutputPart(string? Command, string Output) : ChatPart;

/// A /btw or /bg result row: "By the way: …" or "Background task finished: …", then the answer.
public sealed record SideResultPart(string Kind, string Title, string Result) : ChatPart;

/// What the slash dispatcher asks of the chat screen (HermesKit ChatSlashHooks).
public sealed class SlashHooks
{
    /// A `prefill` directive's text for the message box (replaces the draft, focuses the field).
    public Action<string>? Prefill { get; set; }
    /// `/model [query]`: the Models list, its search filled.
    public Action<string?>? OpenModels { get; set; }
    /// `/help`: the Commands list.
    public Action? OpenCommands { get; set; }
    public Action<string, string>? Alert { get; set; }
    /// The title changed by `/title <name>`.
    public Action<string>? TitleApplied { get; set; }
    /// `/new`: a new chat with this bot in this one's place, the words after the command in its field. False: nothing
    /// could open it.
    public Func<string, bool>? NewChat { get; set; }
}

/// What a model switch shows: the "Change Model?" confirm, the failure alert, and the notice under the title.
public interface IModelSwitchUi
{
    Task<bool> ConfirmModelChange(string message);
    void ModelChangeFailed(string reason);
    /// `duration` null keeps it until replaced.
    void SwitchNotice(string text, TimeSpan? duration, bool spinner);
    void HideSwitchNotice();
}

/// The composer's side of one open chat: the queue, the model state and its menus, the commands catalog and the slash
/// dispatcher, the drawers' completions, and the reads behind Usage & Limits and Model Prices. The C# twin of the
/// composer and menus parts of HermesKit's LiveChatSession (+Menus, +Drawer, SlashRunner, ModelSwitcher).
public sealed partial class ChatComposer : IQueueHost, IDisposable
{
    private readonly ModelCatalogCache _models;
    private readonly CommandsCatalogCache _commands;
    private readonly object _lock = new();
    private ChatModelState _state = new();

    public ChatSession Session { get; }
    public HermesClient Client => Session.Client;
    public ModelPrefs Prefs { get; }
    public ComposerQueue Queue { get; }
    public SlashHooks Hooks { get; } = new();
    /// A bot's own chat ("Bot Chat"): no /title.
    public bool IsBotChat { get; }
    /// [attachments] A send carrying more than words (photos, files, links): the feature that put them there sends it.
    public Func<QueuedMessage, bool, Task<SendOutcome>>? Sender { get; set; }
    /// How long a slash command runs before its row shows "Running…".
    public TimeSpan RunningPlaceholderAfter { get; set; } = TimeSpan.FromMilliseconds(250);

    /// The model state, the usage or the folder changed (on a background thread).
    public event Action? StateChanged;
    /// A line under the title ("Couldn’t add this to the running reply…").
    public event Action<string>? Notice;

    public ChatComposer(ChatSession session, ModelPrefs prefs, bool isBotChat = false, ModelCatalogCache? models = null,
        CommandsCatalogCache? commands = null)
    {
        Session = session;
        Prefs = prefs;
        IsBotChat = isBotChat || session.Title == "Bot Chat";
        _models = models ?? ModelCatalogCache.Shared;
        _commands = commands ?? CommandsCatalogCache.Shared;
        Queue = new ComposerQueue(this);
        Queue.Notice += n => Notice?.Invoke(n);
        session.InfoChanged += ApplyInfo;
        session.TurnEnded += Queue.TurnEnded;
        session.Stopped += Queue.Stopped;
        Queue.Taken += MemoRowTaken;   // [WIN-MEMO-SEND-HOST] ChatComposer+Memo.cs
        Client.Rpc.Event += OnEvent;
    }

    public void Dispose()
    {
        Session.InfoChanged -= ApplyInfo;
        Session.TurnEnded -= Queue.TurnEnded;
        Session.Stopped -= Queue.Stopped;
        Queue.Taken -= MemoRowTaken;
        Client.Rpc.Event -= OnEvent;
    }

    public bool Offline => Client.Rpc.State != ConnectionState.Open;
    public bool Running => Session.Busy;

    // ------------------------------------------------------------------ IQueueHost

    bool IQueueHost.Busy => Session.Busy;
    bool IQueueHost.CanSteerNow => Session.CanSteerNow;

    Task<SendOutcome> IQueueHost.SendAsync(QueuedMessage message, bool queued) =>
        message.Payload is Voice.MemoFile memo ? Session.SendMemoAsync(memo, message.Text, queued)   // [WIN-MEMO-SEND-HOST]
        : message.Payload != null && Sender is { } sender ? sender(message, queued)
            : Session.SendAsync(message.Text, queued: queued, display: message.Display);

    void IQueueHost.Stop() => _ = Session.StopAsync();
    string IQueueHost.BeginSteer(string shown) => Session.BeginSteer(shown);
    Task<(SteerOutcome Outcome, bool Unsupported)> IQueueHost.FinishSteerAsync(string localId, string text) =>
        Session.RedirectAsync(localId, text);

    // ------------------------------------------------------------------ sending

    /// The composer's Send (Enter): a slash command runs through the dispatcher; anything else steers into a running
    /// reply, waits in the queue, or goes now. `queue`: Ctrl+Enter (it waits behind a running reply).
    public void Send(string text, bool queue = false)
    {
        var trimmed = ComposerText.SendText(text);
        if (trimmed.Length == 0) return;
        if (SlashCommand.Matches(trimmed))
        {
            _ = RunSlashAsync(trimmed, recordInput: true);
            return;
        }
        if (queue) Queue.QueuesNextSend = true;
        // [WIN-INFLIGHT-GRAFT] A titled request whose title came back to the main bot's field goes out as the request it
        // stands for, under its title, before the steer decision (`sendAfterOpen`): showing other words than it sends,
        // it waits in line behind a running reply rather than steering in as the bare title.
        if (Session.Profile == "default" && Session.SentTitles.Prompt(trimmed) is { } prompt)
        {
            Queue.Send(prompt, display: trimmed);
            return;
        }
        Queue.Send(trimmed);
    }

    // ------------------------------------------------------------------ model state (spec 1x §2.1)

    public ChatModelState ModelState { get { lock (_lock) return _state; } }

    private void SetState(Func<ChatModelState, ChatModelState> change)
    {
        bool changed;
        lock (_lock)
        {
            var next = change(_state);
            changed = next != _state;
            _state = next;
        }
        if (changed) StateChanged?.Invoke();
    }

    /// The chat's folder (`cwd`) as the gateway last reported it.
    public string? Cwd { get; private set; }
    /// `session.info`'s `usage` as last reported (replaced whole).
    public JsonNode? Usage { get; private set; }

    private volatile bool _switchPending;

    /// Copies `session.resume`'s `info` or a `session.info` payload into the model state, each field only when present.
    /// While this PC's own switch is in flight, model and provider are left alone (spec 1x §2.1 rule 3).
    public void ApplyInfo(JsonNode info)
    {
        if (info.Get("usage") is JsonObject usage) Usage = usage.DeepClone();
        if (info.Text("cwd") is { } cwd) Cwd = cwd;
        SetState(s =>
        {
            if (!_switchPending)
            {
                if (info.Str("model") is { } model) s = s with { Model = model };
                if (info.Str("provider") is { } provider) s = s with { Provider = provider };
            }
            if (info.Str("reasoning_effort") is { } effort) s = s with { ReasoningEffort = effort };
            if (info.Bool("fast") is { } fast) s = s with { Fast = fast };
            if (info.Bool("yolo") is { } yolo) s = s with { Yolo = yolo };
            if (info.Text("approval_mode") is { } mode) s = s with { ApprovalMode = mode.ToLowerInvariant() };
            return s;
        });
    }

    private async Task<JsonNode> Call(string method, JsonObject p, TimeSpan timeout, SessionNeed need, CancellationToken ct = default)
    {
        if (Offline && need != SessionNeed.Optional) throw new GatewayException("offline", MenusText.Offline);
        return await Session.CallAsync(method, p, timeout, need, ct);
    }

    // ------------------------------------------------------------------ side results (/btw, /bg)

    private readonly Dictionary<string, (string Kind, string? Asked, string? RowId)> _sideTasks = [];
    private readonly HashSet<string> _sideDone = [];

    private void OnEvent(RpcEvent e)
    {
        if (e.Type is not ("btw.complete" or "background.complete") || e.SessionId != Session.RuntimeId) return;
        var kind = e.Type == "btw.complete" ? "btw" : "bg";
        var taskId = e.Payload.Text("task_id") ?? "";
        (string Kind, string? Asked, string? RowId) task;
        lock (_lock)
        {
            _sideDone.Add(taskId);
            _sideTasks.Remove(taskId, out task);
        }
        var result = (e.Payload.Str("text") ?? "").Trim();
        var failed = result.StartsWith("error: ", StringComparison.Ordinal);
        if (failed) result = result["error: ".Length..].Trim();
        if (result.Length == 0) result = "No answer came back.";
        var asked = task.Asked ?? e.Payload.Str("question") ?? "";
        var part = new SideResultPart(kind, SideTitle(kind, asked, failed), result);
        if (task.RowId is { } row) Session.UpdateLocalRow(row, part);
        else Session.AddLocalRow(Role.System, part);
    }

    /// "By the way: what's the port?", "Background task finished: run the tests"; a failure says so.
    public static string SideTitle(string kind, string asked, bool failed)
    {
        var words = System.Text.RegularExpressions.Regex.Replace(asked.Trim(), @"\s+", " ");
        if (words.Length > 400) words = words[..400] + "…";
        var lead = kind == "btw" ? (failed ? "Couldn’t answer" : "By the way") : (failed ? "Background task failed" : "Background task finished");
        return words.Length == 0 ? lead : $"{lead}: {words}";
    }

    // ------------------------------------------------------------------ the drawers (docs/spec/3x-composer.md §9.3, §10.3)

    public static readonly TimeSpan CompletionTimeout = TimeSpan.FromSeconds(5);

    public async Task<ComposerDrawer.Answer> CompleteSlashAsync(string text, CancellationToken ct = default)
    {
        var res = await Call("complete.slash", new JsonObject { ["text"] = text }, CompletionTimeout, SessionNeed.Optional, ct);
        return ComposerDrawer.ParseAnswer(res, text);
    }

    public async Task<ComposerDrawer.Answer> CompletePathAsync(string word, CancellationToken ct = default)
    {
        var p = new JsonObject { ["word"] = word };
        if (Cwd is { } cwd) p["cwd"] = cwd;
        var res = await Call("complete.path", p, CompletionTimeout, SessionNeed.Optional, ct);
        return ComposerDrawer.ParseAnswer(res, word);
    }

    // ------------------------------------------------------------------ commands catalog (spec 1x §3.5)

    private string CommandsScope => Session.RuntimeId is { } rt ? $"session:{rt}" : $"profile:{Session.Profile}";

    /// The newest catalog this account and profile has seen (typed commands resolve against it).
    public CommandsCatalog? LatestCommands =>
        _commands.Cached(Client.AccountId, CommandsScope) ?? _commands.Latest(Client.AccountId, Session.Profile);

    /// `commands.catalog`, from the 1 h cache unless `fresh`. Offline, or when the read fails, this profile's newest
    /// list answers if there is one.
    public async Task<CommandsCatalog> LoadCommandsAsync(bool fresh = false, CancellationToken ct = default)
    {
        if (!fresh && _commands.Fresh(Client.AccountId, CommandsScope) is { } cached) return cached;
        var fallback = LatestCommands;
        if (Offline && fallback != null) return fallback;
        try
        {
            var res = await Call("commands.catalog", [], TimeSpan.FromSeconds(30), SessionNeed.Optional, ct);
            if (res is not JsonObject) throw new GatewayException("rpc", "Hermes sent its list of commands in a shape this app doesn't read.");
            var catalog = CommandsCatalog.Parse(res);
            _commands.Store(catalog, Client.AccountId, CommandsScope, Session.Profile);
            return catalog;
        }
        catch (GatewayException) when (fallback != null) { return fallback; }
    }

    // ------------------------------------------------------------------ Usage & Limits, Model Prices reads

    /// `session.usage`: the chat's tokens, cost and context, and Nous credits lines.
    public Task<JsonNode> SessionUsageAsync(CancellationToken ct = default) =>
        Call("session.usage", [], TimeSpan.FromSeconds(30), SessionNeed.ResumeFirst, ct);

    /// Hermes's own /usage report for this chat (`slash.exec usage`).
    public async Task<string> UsageReportAsync(CancellationToken ct = default)
    {
        var res = await Call("slash.exec", new JsonObject { ["command"] = "usage" }, TimeSpan.FromSeconds(60), SessionNeed.ResumeFirst, ct);
        return res.Str("output") ?? "";
    }

    /// `billing.state {profile}` (ProfileParams only: no session id).
    public Task<JsonNode> BillingStateAsync(CancellationToken ct = default) =>
        Client.Rpc.RequestAsync("billing.state", new JsonObject { ["profile"] = Session.Profile }, TimeSpan.FromSeconds(60), ct);
}
