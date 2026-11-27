using System.Text.Json.Nodes;
using Hermes.Core.Chat;
using Hermes.Core.Model;
using Hermes.Core.Net;
using Hermes.Core.Questions;
using Hermes.Core.Rpc;

namespace Hermes.Core;

/// [WIN-EXTERNAL-TURN] NewestStoredAt / NewestRowId: the newest stored row's time and id among the rows read (a folded
/// turn carries its first row's time, so the messages alone understate them).
public sealed record HistoryPage(IReadOnlyList<ChatMessage> Messages, long NextOffset, bool PossiblyTruncated,
    DateTimeOffset? NewestStoredAt = null, long? NewestRowId = null);

/// Everything for one signed-in account: REST, the socket, bots, sessions, history.
public sealed class HermesClient : IAsyncDisposable
{
    private readonly SemaphoreSlim _rosterGate = new(1, 1);
    private int _pageSeq;

    public GatewaySession Session { get; }
    public RpcConnection Rpc { get; }
    public ITranscriptCache? Cache { get; }
    /// [questions] The account's open approvals, questions and password prompts (spec 1x §3.2). Wired before the socket
    /// starts, so nothing the gateway asks arrives before it listens.
    public QuestionCenter Questions { get; }
    public string AccountId => Session.Account.Key;

    public HermesClient(GatewaySession session, ITranscriptCache? cache = null)
    {
        Session = session;
        Cache = cache;
        Rpc = new RpcConnection(session);
        Questions = new QuestionCenter(new RpcQuestionTransport(Rpc, session));
        Questions.Attach(Rpc);
        Rpc.Start();
    }

    /// The last roster read (null until the first answer), and when it came. The launch screen waits on it, and a read
    /// that queued behind one that just finished takes its answer instead of asking again.
    public IReadOnlyList<Bot>? Bots { get; private set; }
    public DateTimeOffset BotsReadAt { get; private set; }
    /// A roster read answered (on a background thread).
    public event Action? BotsChanged;

    /// profiles.list: can take 18–107 s on a busy gateway, so 120 s and single flight.
    public async Task<IReadOnlyList<Bot>> BotsAsync(CancellationToken ct = default)
    {
        var asked = DateTimeOffset.UtcNow;
        await _rosterGate.WaitAsync(ct);
        try
        {
            // Another read finished while this one waited (the launch's first read): its answer is this one's.
            if (Bots is { } fresh && BotsReadAt >= asked) return fresh;
            var bots = Roster.Parse(await Rpc.RequestAsync("profiles.list", new JsonObject(), TimeSpan.FromSeconds(120), ct));
            Bots = bots;
            BotsReadAt = DateTimeOffset.UtcNow;
            BotsChanged?.Invoke();
            return bots;
        }
        finally { _rosterGate.Release(); }
    }

    /// [launch] One roster read once the socket is open, for the launch screen (it starts the first list's 5 s).
    public void StartFirstRead()
    {
        if (_firstRead) return;
        _firstRead = true;
        _ = Task.Run(async () =>
        {
            try { await BotsAsync(); } catch (Exception) { /* the sidebar's own poll reads and reports */ }
        });
    }
    private bool _firstRead;

    public async Task<Sidebar> SessionsAsync(CancellationToken ct = default) =>
        Sidebar.Parse(await Session.GetJsonAsync("/api/profiles/sessions/sidebar", Sidebar.Query, ct: ct));

    /// The bot's own chat: canonical_session, else the "Bot Chat" lookup, else create it.
    public async Task<string> BotChatIdAsync(Bot bot, CancellationToken ct = default)
    {
        if (bot.Canonical is { } c) return c.OpenId;
        var list = await Rpc.RequestAsync("session.list", new JsonObject
        {
            ["profile"] = bot.Name, ["title"] = Bot.BotChatTitle, ["limit"] = 200, ["include_hidden"] = true,
        }, TimeSpan.FromSeconds(30), ct);
        var hit = list.Arr("sessions")?.FirstOrDefault(s => (s.Text("root_title") ?? s.Text("title")) == Bot.BotChatTitle);
        if (hit != null) return hit.Text("resolved_id") ?? hit.Text("id")!;

        var made = await Settings.SessionCreate.CallAsync(Rpc.RequestAsync, new JsonObject
        {
            ["profile"] = bot.Name, ["title"] = Bot.BotChatTitle, ["hidden"] = true, ["follow_profile_config"] = true,
        }, bot.Name, TimeSpan.FromSeconds(60), ct: ct);
        var stored = made.Text("stored_session_id") ?? made.Text("session_id")!;
        if (made.Text("session_id") is { } runtime)
        {
            try
            {
                await Rpc.RequestAsync("session.title", new JsonObject
                { ["session_id"] = runtime, ["title"] = Bot.BotChatTitle, ["profile"] = bot.Name }, TimeSpan.FromSeconds(30), ct);
            }
            catch (GatewayException e) when (e.Message.Contains("already in use"))
            {
                return await BotChatIdAsync(bot, ct); // another device made it first
            }
        }
        return stored;
    }

    /// GET /api/sessions/{id}/messages, newest first page, always with order and include_compacted.
    public async Task<HistoryPage> HistoryAsync(string profile, string storedId, int limit, long offset,
        CancellationToken ct = default)
    {
        var q = new List<KeyValuePair<string, string>> { new("profile", profile), new("limit", limit.ToString()) };
        if (offset > 0) q.Add(new("offset", offset.ToString()));
        q.Add(new("order", "latest"));
        q.Add(new("include_compacted", "true"));
        var j = await Session.GetJsonAsync($"/api/sessions/{Uri.EscapeDataString(storedId)}/messages", q, ct: ct);
        var rows = j.Arr("messages") ?? [];
        var p = j.Obj("pagination");
        var returned = p.Int("returned") ?? rows.Count;
        var off = p.Int("offset") ?? offset;
        var truncated = j.Bool("has_more") ?? p.Bool("has_more")
            ?? ((j.Int("total") ?? p.Int("total")) is { } total ? off + returned < total : returned * 2 >= limit);
        var next = j.Int("next_offset") ?? p.Int("next_offset") ?? off + rows.Count;
        DateTimeOffset? newest = null;
        long? newestRow = null;
        foreach (var row in rows)
        {
            if (row.UnixTime("timestamp") is { } at && (newest is not { } n || at > n)) newest = at;
            if ((row.Int("row_id") ?? row.Int("id")) is { } id && (newestRow is not { } r || id > r)) newestRow = id;
        }
        return new HistoryPage(HistoryFold.Fold(rows, Interlocked.Increment(ref _pageSeq)), next, truncated, newest, newestRow);
    }

    /// [WIN-MEMO-SEND-WIRE] The memo pipeline's REST over this account's session (the Mac's chat `client` as
    /// GatewayClient/GatewayTransfers): every chat this client opens sends its memos through it.
    public Voice.HermesMemoGateway MemoGateway => _memoGateway ??= new Voice.HermesMemoGateway(this);
    private Voice.HermesMemoGateway? _memoGateway;

    /// [WIN-LOST-SEND-MARKER] Where this account's chats keep sends that may never have arrived (the app's one store,
    /// AppModel's `chat.lostSends = LostSends.shared`); null keeps nothing.
    public Sessions.LostSends? LostSends { get; init; }

    /// [WIN-SENT-TITLES] Requests sent with a short title for their bubble (the Mac's `LiveChatSession.sentTitles`
    /// static): the app passes its one list (SentTitles.Shared); a client made without one keeps its own.
    public SentTitles SentTitles { get; init; } = new();

    public ChatSession OpenChat(string profile, string storedId, string title) =>
        new(this, profile, storedId, title) { MemoGateway = MemoGateway, LostSends = LostSends };

    public async ValueTask DisposeAsync()
    {
        Questions.Dispose();
        await Rpc.DisposeAsync();
        Session.Dispose();
    }
}

/// The on-disk transcript cache (newest 40 messages per chat). The app supplies a file-backed one.
public interface ITranscriptCache
{
    IReadOnlyList<ChatMessage>? Read(string account, string profile, string storedId);
    void Write(string account, string profile, string storedId, IReadOnlyList<ChatMessage> messages);
    void Purge(string account);
}
