using System.Text.Json.Nodes;
using Hermes.Core.Net;

namespace Hermes.Core.Bots;

/// What this device keeps for the Bots list, per gateway account (HermesKit BotStore's device state).
public sealed class BotDeviceState
{
    /// The merged `hermes-bots` meta by profile (spec 02 §5.2).
    public Dictionary<string, JsonObject> Meta { get; set; } = [];
    /// User sections in display order (`hermes.plugin.hermes-bots.bot-sections-v1`).
    public List<RosterSectionRecord> Sections { get; set; } = [];
    /// Tile order: profile names.
    public List<string> PinOrder { get; set; } = [];
    public BotUnreadState Unread { get; set; } = new();
    /// Profile → mute.
    public Dictionary<string, BotMute> Mutes { get; set; } = [];
    /// The last full roster's rows (the next launch paints them before the gateway answers).
    public List<JsonObject> Rows { get; set; } = [];
    /// Collapsed sidebar groups (BotListSection.Key).
    public List<string> Collapsed { get; set; } = [];
    public bool ShowHidden { get; set; }
    /// What each bot lists under its row ([chats-under]): "off", "active", "pinned", "recent:2"; "*" is every bot's.
    public Dictionary<string, string> ChatsUnder { get; set; } = [];
    /// [botsaid] Per-bot cached preview of the bot's newest words to you, persisted per gateway account.
    public Dictionary<string, BotSaidEntry> BotSaid { get; set; } = [];
}

/// A section deletion in flight: the Undo pill puts it back.
public sealed class SectionDeletion(RosterSectionRecord record, int index, IReadOnlyList<string> members)
{
    public RosterSectionRecord Record { get; } = record;
    public int Index { get; } = index;
    public IReadOnlyList<string> Members { get; } = members;
    public bool Undone { get; internal set; }
}

/// The Bots list's data: `profiles.list`, the device's meta snapshot, sections, tiles, unread dots and mutes, and every
/// bot write (pin, hide, section, edit, New Bot, Duplicate, Delete). Port of HermesKit/Store/BotStore*.swift.
public sealed partial class BotStore
{
    public const string BotsKey = "hermes-bots";
    private readonly IListsGateway _gw;
    private readonly IDeviceStore _disk;
    private readonly string _diskKey;
    private readonly object _gate = new();
    private readonly SemaphoreSlim _rosterGate = new(1, 1);
    private readonly Dictionary<string, SemaphoreSlim> _serial = [];
    private readonly Dictionary<string, DateTimeOffset> _metaWriteAt = [];
    private readonly Dictionary<string, JsonObject> _createdRows = [];
    private readonly Dictionary<string, DateTimeOffset> _deletedAt = [];
    private readonly Dictionary<string, string> _minted = [];
    private readonly Dictionary<string, string> _descriptions = [];
    /// [WIN-LIVE-STEPS] Each heard chat's step, by bot and stored id ("" not stored yet): the Mac's BotStore `steps`.
    private Dictionary<string, Dictionary<string, string>> _steps = [];
    /// [botslist] A bot's standing problem, display only and never saved (the Mac's BotStore `attention`).
    private readonly Dictionary<string, Attention> _attention = [];
    private readonly HashSet<string> _pendingSectionDeletes = [];
    private List<JsonObject> _rows;
    private HashSet<string> _workingIds = [];
    private HashSet<string> _waitingIds = [];
    private readonly Dictionary<string, HashSet<string>> _workingChats = [];   // [WIN-EXTERNAL-SURFACES]

    public BotDeviceState Device { get; }
    public RosterLayout Layout { get; private set; } = new();
    public IReadOnlyList<BotListSection> Sections { get; private set; } = [];
    public IReadOnlyList<BotRow> Rows { get; private set; } = [];
    public bool? BotModeProtocol { get; private set; }
    /// True once a roster (cached or live) has been read.
    public bool HasRoster { get; private set; }
    /// Refuses every write (automated runs against a real gateway).
    public bool ReadOnly { get; set; }
    /// The bot whose chat is on screen (its unread dot clears as rosters come in).
    public string? VisibleBot { get; set; }
    /// Raised after every change to Rows/Sections (on whatever thread made it).
    public event Action? Changed;
    /// How long a full `profiles.list` may take (18–107 s seen under load).
    public TimeSpan FullTimeout { get; set; } = TimeSpan.FromSeconds(120);
    public TimeSpan SlimTimeout { get; set; } = TimeSpan.FromSeconds(20);
    public TimeSpan LastReadTook { get; private set; }

    public BotStore(IListsGateway gateway, IDeviceStore disk)
    {
        _gw = gateway;
        _disk = disk;
        _diskKey = "bots-" + gateway.AccountId;
        Device = DeviceJson.Load<BotDeviceState>(disk, _diskKey);
        _rows = Device.Rows;
        if (_rows.Count > 0) { HasRoster = true; Rebuild(); }
    }

    private void Persist()
    {
        lock (_gate) Device.Rows = _rows;
        DeviceJson.Save(_disk, _diskKey, Device);
    }

    // ---------------------------------------------------------------- reads

    /// The profiles the list draws: the roster's rows, plus bots made here the roster doesn't list yet, minus deleted ones.
    private List<RosterProfile> Profiles()
    {
        lock (_gate)
        {
            var rows = _rows.Where(r => RosterText.Trimmed(r["name"]) is { } n && !_deletedAt.ContainsKey(n)).ToList();
            var names = rows.Select(r => RosterText.Trimmed(r["name"])).ToHashSet();
            rows.AddRange(_createdRows.Where(kv => !names.Contains(kv.Key)).Select(kv => kv.Value));
            return rows.Select(r => RosterProfile.From(r)).OfType<RosterProfile>().Select(p =>
                _descriptions.TryGetValue(p.Name, out var d) ? RosterProfile.From(WithDescription(p.Raw, d))! : p).ToList();
        }
    }

    private static JsonObject WithDescription(JsonObject row, string description)
    {
        var c = (JsonObject)row.DeepClone();
        c["description"] = description;
        return c;
    }

    /// One read: the slim answer first when nothing is on screen yet, then the full answer (single flight).
    public async Task RefreshAsync(CancellationToken ct = default)
    {
        await _rosterGate.WaitAsync(ct);
        try
        {
            var issued = DateTimeOffset.UtcNow;
            if (!HasRoster)
            {
                try
                {
                    var slim = await _gw.CallAsync("profiles.list", new JsonObject { ["include_sessions"] = false }, SlimTimeout, ct);
                    if (slim["profiles"] is JsonArray rows)
                    {
                        lock (_gate) _rows = RosterSnapshot.MergeSlim(rows.OfType<JsonNode>(), _rows).OfType<JsonObject>().ToList();
                        HasRoster = true;
                        Rebuild();
                    }
                }
                catch (GatewayException) { }
            }
            var started = DateTimeOffset.UtcNow;
            var result = await _gw.CallAsync("profiles.list", new JsonObject(), FullTimeout, ct);
            LastReadTook = DateTimeOffset.UtcNow - started;
            ApplyFull(result, issued);
        }
        finally { _rosterGate.Release(); }
    }

    /// A full roster answer (also used by tests with captured fixtures).
    public void ApplyFull(JsonNode result, DateTimeOffset issued)
    {
        var snapshot = RosterSnapshot.Decode(result);
        NoteRosterMarks(snapshot.Profiles);
        var activeProfiles = WithChatActivity(snapshot.Profiles);
        lock (_gate)
        {
            BotModeProtocol = snapshot.BotModeProtocol ?? BotModeProtocol;
            _rows = activeProfiles.Select(p => p.Raw).ToList();
            foreach (var p in activeProfiles) _createdRows.Remove(p.Name);
            foreach (var (name, at) in _deletedAt.ToList())
                if (at < issued || activeProfiles.All(p => p.Name != name)) _deletedAt.Remove(name);
            foreach (var p in activeProfiles.Where(p => p.CanonicalSession != null)) _minted.Remove(p.Name);
            _descriptions.Clear();
            // A bot written here since the request went out keeps this device's meta (the write fence, 60 s).
            Device.Meta = BotMetaMerge.Merge(Device.Meta, activeProfiles,
                name => _metaWriteAt.TryGetValue(name, out var at) && at > issued && DateTimeOffset.UtcNow - at < TimeSpan.FromSeconds(60));
            Device.Sections = RosterBuilder.AdoptSections(Device.Sections, activeProfiles, Device.Meta)
                .Where(s => !_pendingSectionDeletes.Contains(s.Id)).ToList();
            var beforeHeld = new HashSet<string>(Device.Unread.Held.Keys, StringComparer.Ordinal);
            Device.Unread.Reconcile(activeProfiles, p => p.Name == VisibleBot, holdForCheck: ReadsBotSaid);
            foreach (var heldName in Device.Unread.Held.Keys)
                if (!beforeHeld.Contains(heldName)) _unreadHeldAt[heldName] = DateTimeOffset.UtcNow;
            HasRoster = true;
        }
        Persist();
        Rebuild();
        if (ReadsBotSaid) _ = RefreshBotSaidAsync();
    }

    /// Recompose the list from what is held (cheap; called after every change).
    public void Rebuild()
    {
        var profiles = WithBotSaid(Profiles());
        RosterLayout layout;
        lock (_gate)
        {
            var working = new HashSet<string>();
            var needs = new Dictionary<string, string>();
            foreach (var p in profiles)
            {
                var ids = p.CanonicalIds.Concat(_minted.TryGetValue(p.Name, out var m) ? [m] : []).ToList();
                if (ids.Any(_waitingIds.Contains)) needs[p.Name] = "Waiting for you";
                if (ids.Any(_workingIds.Contains) || _workingChats.ContainsKey(p.Name)) working.Add(p.Name);
            }
            layout = RosterBuilder.Build(new RosterBuilder.Input
            {
                Profiles = profiles, Meta = Device.Meta, Sections = Device.Sections, PinOrder = Device.PinOrder,
                Unread = Device.Unread, Working = working, NeedsInput = needs, Steps = OwnSteps(profiles),
                Waking = WakingInput(),   // [botslist] input.waking = wakingBots (BotStore+Opening.cs)
                Attention = _attention.ToDictionary(kv => kv.Key, kv => kv.Value.Words()),
                MintedChats = new Dictionary<string, string>(_minted),
            });
            Layout = layout;
            Sections = BotList.Compose(layout, Device.Sections);
            Rows = layout.Flat.ToList();
        }
        Changed?.Invoke();
    }

    public BotRow? Bot(string name) => Rows.FirstOrDefault(b => b.Id == name);
    /// [groups] The default profile's row as last read (the group chats mirror rides its `ui_meta`, GroupSync.Pulled):
    /// the profile named "default", else the `is_default` one; null before a roster.
    public JsonObject? DefaultProfileRow()
    {
        lock (_gate)
        {
            var row = _rows.FirstOrDefault(r => RosterText.Trimmed(r["name"]) == "default")
                ?? _rows.FirstOrDefault(r => RosterText.Bool(r["is_default"]) == true);
            return (JsonObject?)row?.DeepClone();
        }
    }

    public string? SectionName(string id) => Device.Sections.FirstOrDefault(s => s.Id == id)?.Name;
    public JsonObject CurrentMeta(string name)
    {
        lock (_gate)
        {
            var profile = Profiles().FirstOrDefault(p => p.Name == name);
            return profile == null ? Device.Meta.GetValueOrDefault(name) ?? [] : RosterBuilder.MetaObject(profile, Device.Meta);
        }
    }

    // ---------------------------------------------------------------- live state fed by the app

    /// The gateway's live registry (LiveStatusWatch): stored ids running a turn, and those waiting on a person.
    public void SetLive(IReadOnlySet<string> working, IReadOnlySet<string> waiting)
    {
        lock (_gate) { _workingIds = [.. working]; _waitingIds = [.. waiting]; }
        Rebuild();
    }

    /// [WIN-EXTERNAL-SURFACES] The bot's chats this device sees working, a turn of ours or another Hermes process's
    /// (the Mac's `botStore.setWorkingChats`): any of them puts Working… on its row.
    public void SetWorkingChats(string profile, IReadOnlySet<string> chats)
    {
        lock (_gate)
        {
            if (chats.Count == 0) { if (!_workingChats.Remove(profile)) return; }
            else if (_workingChats.TryGetValue(profile, out var had) && had.SetEquals(chats)) return;
            else _workingChats[profile] = [.. chats];
        }
        Rebuild();
    }

    /// [botsaid] When true, each Bot Chat whose roster mark moved has its tail read via REST to compute the bot's own
    /// newest words to you and suppress false unread dots after bot-to-bot tool calls (#612). Defaults to false so unit
    /// tests without mocked history endpoints remain deterministic; runtime hubs enable it.
    public bool ReadsBotSaid { get; set; } = false;

    /// A turn in a bot's own chat ended, seen by this device (its chat on screen, or a turn the device watched that ended
    /// off screen): the row shows that reply and its time now instead of after the next roster read, and gets the dot
    /// when nobody was looking (`unseen`). The next full roster replaces the patch with the gateway's own values. Port of
    /// HermesKit/Store/BotStore.swift `noteChatActivity(profile:sessionId:preview:at:unseen:said:)` at 93f984bb1.
    public void NoteChatActivity(string name, string? sessionId, string? preview, DateTimeOffset time, bool unseen, bool said = true)
    {
        RosterProfile patched;
        var reread = false;
        lock (_gate)
        {
            var index = _rows.FindIndex(r => RosterText.Trimmed(r["name"]) == name);
            var row = index >= 0 ? _rows[index] : _createdRows.GetValueOrDefault(name);
            if (row == null || _deletedAt.ContainsKey(name) || RosterProfile.From(row) is not { } profile
                || profile.CanonicalSession is not { } canonical) return;
            if (sessionId != null && !profile.CanonicalIds.Contains(sessionId) && _minted.GetValueOrDefault(name) != sessionId) return;
            var changed = false;
            var stamp = time.ToUnixTimeMilliseconds() / 1000.0;
            var copy = (JsonObject)row.DeepClone();
            if (copy["canonical_session"] is not JsonObject session) return;
            if (stamp > (canonical.LastActive ?? 0))
            {
                session["last_active"] = stamp;
                changed = true;
            }
            if ((said || !ReadsBotSaid) && preview is { } words
                && Transcripts.RunSummary.CompactPreview(words, 80) is { Length: > 0 } text && text != canonical.Preview)
            {
                session["preview"] = text;
                changed = true;
            }
            if ((canonical.MessageCount ?? 0) == 0)
            {
                session["message_count"] = (double)Math.Max(1, canonical.MessageCount ?? 0);   // a wire number (RosterText.Number)
                changed = true;
            }
            if (!changed) return;
            if (index >= 0) _rows[index] = copy; else _createdRows[name] = copy;
            patched = RosterProfile.From(copy)!;
            var watched = VisibleBot == name;
            if (unseen && !watched)
            {
                if (ReadsBotSaid && !said)
                {
                    var baseline = Device.Unread.Baselines.GetValueOrDefault(name);
                    Device.Unread.Hold(patched, baseline);
                    _unreadHeldAt[name] = DateTimeOffset.UtcNow;
                    reread = true;
                }
                else
                {
                    Device.Unread.Mark(patched);
                }
            }
            else if (ReadsBotSaid && !said)
            {
                reread = true;
            }
        }
        if (said && preview is { Length: > 0 } saidWords
            && Transcripts.RunSummary.CompactPreview(saidWords, 80) is { Length: > 0 } compactSaid
            && patched.CanonicalSession is { } cs)
            NoteBotSaid(name, sessionId ?? cs.OpenId, compactSaid, time.ToUnixTimeMilliseconds() / 1000.0);
        Persist();
        Rebuild();
        if (reread) RereadBotSaid(name);
    }

    /// [WIN-LIVE-STEPS] Each heard chat's step as its row's line ("Reading package.json…"), by bot and stored id ("" for a
    /// chat not stored yet): the Mac's `setSteps(_:)` (93f984bb1 HermesKit/Store/BotStore.swift), handed over whole by
    /// TurnRows.PushSteps. The bot row says its own Bot Chat's (OwnSteps): a side chat's step never overwrites it.
    public void SetSteps(IReadOnlyDictionary<string, IReadOnlyDictionary<string, string>> byBot)
    {
        lock (_gate)
        {
            if (Same(_steps, byBot)) return;
            _steps = byBot.ToDictionary(kv => kv.Key, kv => kv.Value.ToDictionary(c => c.Key, c => c.Value));
        }
        Rebuild();
    }

    private static bool Same(Dictionary<string, Dictionary<string, string>> held, IReadOnlyDictionary<string, IReadOnlyDictionary<string, string>> next) =>
        held.Count == next.Count && next.All(kv => held.TryGetValue(kv.Key, out var chats) && chats.Count == kv.Value.Count
            && kv.Value.All(c => chats.TryGetValue(c.Key, out var words) && words == c.Value));

    /// The running Bot Chat's step as its row's line ("Reading package.json…"); null clears it.
    public void SetStep(string profile, string? step)
    {
        lock (_gate)
        {
            if (step == null) _steps.Remove(profile);
            else _steps[profile] = new Dictionary<string, string> { [""] = step };
        }
        Rebuild();
    }

    /// [toolnow] The step of each bot's own Bot Chat, by profile (the Mac's `ownSteps`). Call under `_gate`.
    private Dictionary<string, string> OwnSteps(IReadOnlyList<RosterProfile> profiles)
    {
        var o = new Dictionary<string, string>();
        foreach (var (profile, chats) in _steps)
        {
            var own = OwnChatIds(profiles.FirstOrDefault(p => p.Name == profile), profile);
            foreach (var (id, words) in chats)
                if (own.Contains(id)) { o[profile] = words; break; }
        }
        return o;
    }

    /// The ids of a bot's own Bot Chat: its canonical ids, the one minted here, and "" (not stored yet).
    private HashSet<string> OwnChatIds(RosterProfile? profile, string name)
    {
        var own = new HashSet<string>(profile?.CanonicalIds ?? []) { "" };
        if (_minted.TryGetValue(name, out var minted)) own.Add(minted);
        return own;
    }

    /// [WIN-OFFSCREEN-END-REST] A turn of this bot's ended (`offScreenTurnEnded` → `liveSteps.clear(runtime)`): the step
    /// it was on goes. A chat with no stored id yet is the Bot Chat not stored yet (the Mac's "" key); any of the Bot
    /// Chat's ids ends the Bot Chat's step, and a side chat's end only its own.
    public void EndStep(string profile, string? storedId)
    {
        lock (_gate)
        {
            if (!_steps.TryGetValue(profile, out var chats)) return;
            var own = OwnChatIds(Profiles().FirstOrDefault(p => p.Name == profile), profile);
            var ending = storedId == null || own.Contains(storedId) ? chats.Keys.Where(own.Contains).ToList() : [storedId];
            if (!ending.Any(chats.ContainsKey)) return;
            foreach (var id in ending) chats.Remove(id);
            if (chats.Count == 0) _steps.Remove(profile);
        }
        Rebuild();
    }

    // MARK: Standing problem (L185; HermesKit/Store/BotStore+RowStatus.swift at 93f984bb1)

    /// A turn in a bot's chat ended in an error. A standing problem (sign-in, quota, no provider, blocked) becomes the
    /// row's status; a passing one (rate limit, 5xx, timeout) leaves the row as it was.
    public void NoteTurnFailed(string profile, string? message, string? reason = null)
    {
        if (AttentionReason.From(message, reason) is not { } kind) return;
        lock (_gate)
        {
            if (_attention.TryGetValue(profile, out var had) && had == kind) return;
            _attention[profile] = kind;
        }
        Rebuild();
    }

    /// The bot answered: whatever stood in its way is over.
    public void NoteTurnSucceeded(string profile)
    {
        lock (_gate) { if (!_attention.Remove(profile)) return; }
        Rebuild();
    }

    // ---------------------------------------------------------------- unread and mute (device-local)

    public void MarkRead(string name)
    {
        if (Profiles().FirstOrDefault(p => p.Name == name) is not { } p) return;
        lock (_gate) Device.Unread.Acknowledge(p);
        Persist(); Rebuild();
    }

    public void MarkUnread(string name)
    {
        if (Profiles().FirstOrDefault(p => p.Name == name) is not { } p) return;
        lock (_gate) Device.Unread.Mark(p);
        Persist(); Rebuild();
    }

    /// The person left the bot's chat having seen it through now.
    public void Left(string name, double seenThrough)
    {
        lock (_gate) Device.Unread.Left(name, seenThrough);
        Persist();
    }

    public BotMute? MuteOf(string name, DateTimeOffset now) =>
        Device.Mutes.TryGetValue(name, out var m) && m.Live(now) ? m : null;

    public void SetMute(string name, MuteChoice choice, DateTimeOffset now)
    {
        lock (_gate)
        {
            if (BotMutes.Mute(choice, now) is { } m) Device.Mutes[name] = m; else Device.Mutes.Remove(name);
            foreach (var key in Device.Mutes.Where(kv => !kv.Value.Live(now)).Select(kv => kv.Key).ToList()) Device.Mutes.Remove(key);
        }
        Persist(); Rebuild();
    }

    public void SetCollapsed(string key, bool collapsed)
    {
        lock (_gate) { Device.Collapsed.Remove(key); if (collapsed) Device.Collapsed.Add(key); }
        Persist(); Changed?.Invoke();
    }

    public void SetShowHidden(bool on)
    {
        lock (_gate) Device.ShowHidden = on;
        Persist(); Changed?.Invoke();
    }

    public void SetChatsUnder(string bot, string? choice)
    {
        lock (_gate) { if (choice == null) Device.ChatsUnder.Remove(bot); else Device.ChatsUnder[bot] = choice; }
        Persist(); Changed?.Invoke();
    }

    /// A tile one place up (-1) or down (+1) among the tiles.
    public void MovePin(string name, int delta)
    {
        var order = Layout.Tiles.Select(b => b.Id).ToList();
        var from = order.IndexOf(name);
        if (from < 0 || from + delta < 0 || from + delta >= order.Count) return;
        order.RemoveAt(from);
        order.Insert(from + delta, name);
        lock (_gate) Device.PinOrder = order;
        Persist(); Rebuild();
    }

    // ---------------------------------------------------------------- meta writes (spec 02 §5.3)

    private async Task<T> Serial<T>(string name, Func<Task<T>> run)
    {
        SemaphoreSlim gate;
        lock (_gate) { if (!_serial.TryGetValue(name, out gate!)) _serial[name] = gate = new SemaphoreSlim(1, 1); }
        await gate.WaitAsync();
        try { return await run(); }
        finally { gate.Release(); }
    }

    private void SetLocalMeta(string name, JsonObject meta)
    {
        lock (_gate) Device.Meta[name] = meta;
        Persist();
        Rebuild();
    }

    /// `profiles.configure` takes the whole `hermes-bots` object, never `image` or `pet` (avatars travel apart).
    public static JsonObject Sendable(JsonObject meta)
    {
        var c = (JsonObject)meta.DeepClone();
        c.Remove("image");
        c.Remove("pet");
        c.Remove("chat");
        return c;
    }

    /// `profiles.list {"include_sessions": false}`: the bot's `hermes-bots` merged over `local`.
    private async Task<JsonObject> FreshMetaAsync(string name, JsonObject local)
    {
        var result = await _gw.CallAsync("profiles.list", new JsonObject { ["include_sessions"] = false }, SlimTimeout);
        var raw = (result["profiles"] as JsonArray)?.FirstOrDefault(r => RosterText.Trimmed(r?["name"]) == name);
        if (raw == null)
        {
            lock (_gate) if (_createdRows.ContainsKey(name)) return local;
            throw new BotWriteException("", "Your gateway no longer lists this bot.");
        }
        var row = (JsonObject)RosterText.CleanRow(raw);
        lock (_gate)
        {
            var at = _rows.FindIndex(r => RosterText.Trimmed(r["name"]) == name);
            if (at >= 0)
            {
                var held = (JsonObject)_rows[at].DeepClone();
                held["ui_meta"] = row["ui_meta"]?.DeepClone();
                held["ui_meta_revisions"] = row["ui_meta_revisions"]?.DeepClone();
                _rows[at] = held;
            }
        }
        var server = row["ui_meta"]?["hermes-bots"] as JsonObject;
        if (server == null) return local;
        var merged = (JsonObject)local.DeepClone();
        foreach (var (k, v) in server) merged[k] = v?.DeepClone();
        return merged;
    }

    /// `applied.ui_meta === true` → persisted; an `applied` object without it → failed; none → older gateway.
    public static string? MetaOutcome(JsonNode result)
    {
        if (result["applied"] is not JsonObject applied) return BotWriteException.UnsupportedReason;
        return RosterText.Bool(applied["ui_meta"]) == true ? null : BotWriteException.NotSavedReason;
    }

    /// The write path every meta change takes: show it now, read the gateway's meta, send the whole merged object, and
    /// put it back (here and, best effort, there) if the gateway refuses it. Returns the meta written, or null when
    /// there was nothing to write.
    public Task<JsonObject?> WriteMetaAsync(string name, string failureTitle, Func<JsonObject, JsonObject?> patch,
        Func<JsonObject, JsonObject, JsonObject>? undo = null)
    {
        if (ReadOnly) throw new BotWriteException(failureTitle, BotWriteException.ReadOnlyReason);
        return Serial(name, async () =>
        {
            var before = CurrentMeta(name);
            if (patch(before) is not { Count: > 0 } first) return null;
            lock (_gate) _metaWriteAt[name] = DateTimeOffset.UtcNow;
            SetLocalMeta(name, PinnedSection.Apply(first, before));
            JsonObject baseMeta;
            try { baseMeta = await FreshMetaAsync(name, before); }
            catch (Exception e) when (e is GatewayException or BotWriteException)
            {
                SetLocalMeta(name, before);
                throw new BotWriteException(failureTitle, BotWriteException.ReasonOf(e), e.Message);
            }
            var final = patch(baseMeta) ?? [];
            var next = PinnedSection.Apply(final, baseMeta);
            SetLocalMeta(name, next);
            if (final.Count == 0) return next;
            string? failed;
            try
            {
                var result = await _gw.CallAsync("profiles.configure", new JsonObject
                {
                    ["name"] = name, ["ui_meta"] = new JsonObject { [BotsKey] = Sendable(next) },
                }, TimeSpan.FromSeconds(30));
                failed = MetaOutcome(result);
            }
            catch (GatewayException e) { failed = BotWriteException.ReasonOf(e); }
            lock (_gate) _metaWriteAt[name] = DateTimeOffset.UtcNow;
            if (failed == null)
            {
                PatchRowMeta(name, next);
                Persist(); Rebuild();
                return next;
            }
            var back = undo?.Invoke(baseMeta, final) ?? PinnedSection.UndoOf(baseMeta, final);
            var restored = PinnedSection.Apply(back, next);
            SetLocalMeta(name, restored);
            _ = Task.Run(async () =>
            {
                try
                {
                    await _gw.CallAsync("profiles.configure", new JsonObject
                    { ["name"] = name, ["ui_meta"] = new JsonObject { [BotsKey] = Sendable(restored) } }, TimeSpan.FromSeconds(10));
                }
                catch (GatewayException) { }
            });
            throw new BotWriteException(failureTitle, failed);
        });
    }

    /// The held row takes the meta the gateway just stored (its next answer will say the same).
    private void PatchRowMeta(string name, JsonObject meta)
    {
        lock (_gate)
        {
            var at = _rows.FindIndex(r => RosterText.Trimmed(r["name"]) == name);
            if (at < 0) return;
            var row = (JsonObject)_rows[at].DeepClone();
            if (row["ui_meta"] is JsonObject ui) ui[BotsKey] = Sendable(meta);
            else row["ui_meta"] = new JsonObject { [BotsKey] = Sendable(meta) };
            _rows[at] = row;
        }
    }

    public Task SetPinnedAsync(string name, string display, bool pinned) =>
        WriteMetaAsync(name, pinned ? $"Couldn’t Pin {display}" : $"Couldn’t Unpin {display}",
            meta => PinnedSection.PinPatch(meta, pinned, SectionName));

    public Task SetHiddenAsync(string name, string display, bool hidden) =>
        WriteMetaAsync(name, hidden ? $"Couldn’t Hide {display}" : $"Couldn’t Show {display}",
            meta => RosterText.Truthy(meta["hidden"]) == hidden ? null : new JsonObject { ["hidden"] = hidden },
            (_, _) => new JsonObject { ["hidden"] = !hidden });

    /// Move to Section (null: Remove from Section). A pinned bot stays in Pinned; the pick is where an unpin puts it.
    public Task MoveAsync(string name, string display, string? target) =>
        WriteMetaAsync(name, $"Couldn’t Move {display}", meta =>
        {
            if (PinnedSection.SectionMovePatch(meta, target, SectionName) is { } special) return special.Count == 0 ? null : special;
            var sectionName = target == null ? null : SectionName(target);
            if (PinnedSection.Current(meta) == target && RosterText.Text(meta["sectionName"]) == (sectionName ?? "")) return null;
            return new JsonObject { ["sectionId"] = target, ["sectionName"] = sectionName };
        });

    // ---------------------------------------------------------------- sections

    public RosterSectionRecord AppendSection(string name)
    {
        var clean = name.Trim();
        if (clean.Length > 40) clean = clean[..40];
        var record = new RosterSectionRecord(BotIdentity.NewSectionId(), clean);
        lock (_gate) Device.Sections.Add(record);
        Persist(); Rebuild();
        return record;
    }

    public List<string> Members(string sectionId) =>
        Profiles().Select(p => p.Name).Where(n => PinnedSection.Current(CurrentMeta(n)) == sectionId).ToList();

    public async Task RenameSectionAsync(string id, string name)
    {
        var clean = name.Trim();
        if (clean.Length > 40) clean = clean[..40];
        int index;
        lock (_gate) index = Device.Sections.FindIndex(s => s.Id == id);
        if (clean.Length == 0 || index < 0) return;
        var members = Members(id);
        var old = Device.Sections[index].Name;
        if (ReadOnly && members.Count > 0) throw new BotWriteException($"Couldn’t Rename {old}", BotWriteException.ReadOnlyReason);
        lock (_gate) Device.Sections[index] = Device.Sections[index] with { Name = clean };
        Persist(); Rebuild();
        var landed = 0;
        foreach (var member in members)
        {
            try
            {
                var written = await WriteMetaAsync(member, $"Couldn’t Move {Bot(member)?.Name ?? member}", meta =>
                    PinnedSection.Current(meta) == id && RosterText.Text(meta["sectionName"]) != clean
                        ? new JsonObject { ["sectionId"] = id, ["sectionName"] = clean } : null);
                if (written != null) landed++;
            }
            catch (BotWriteException)
            {
                if (landed == 0)
                {
                    lock (_gate)
                    {
                        var i = Device.Sections.FindIndex(s => s.Id == id);
                        if (i >= 0 && Device.Sections[i].Name == clean) Device.Sections[i] = Device.Sections[i] with { Name = old };
                    }
                    Persist(); Rebuild();
                }
                throw;
            }
        }
    }

    public bool CanMoveSection(string id, int delta)
    {
        var i = Device.Sections.FindIndex(s => s.Id == id);
        return i >= 0 && i + delta >= 0 && i + delta < Device.Sections.Count;
    }

    public void MoveSection(string id, int delta)
    {
        lock (_gate)
        {
            var list = Device.Sections;
            var from = list.FindIndex(s => s.Id == id);
            if (from < 0 || from + delta < 0 || from + delta >= list.Count) return;
            var moved = list[from];
            list.RemoveAt(from);
            list.Insert(from + delta, moved);
        }
        Persist(); Rebuild();
    }

    /// The section goes now; `FinishDeleteSectionAsync` unfiles its members; `UndoDeleteSection` puts it back.
    public SectionDeletion? BeginDeleteSection(string id)
    {
        int index;
        RosterSectionRecord record;
        lock (_gate)
        {
            index = Device.Sections.FindIndex(s => s.Id == id);
            if (index < 0) return null;
            record = Device.Sections[index];
        }
        var members = Members(id);
        if (ReadOnly && members.Count > 0) throw new BotWriteException($"Couldn’t Delete “{record.Name}”", BotWriteException.ReadOnlyReason);
        lock (_gate) { _pendingSectionDeletes.Add(id); Device.Sections.RemoveAt(index); }
        Persist(); Rebuild();
        return new SectionDeletion(record, index, members);
    }

    public async Task FinishDeleteSectionAsync(SectionDeletion deletion)
    {
        var id = deletion.Record.Id;
        try
        {
            foreach (var member in deletion.Members)
            {
                if (deletion.Undone) break;
                await WriteMetaAsync(member, $"Couldn’t Move {Bot(member)?.Name ?? member}", meta =>
                    !deletion.Undone && PinnedSection.Current(meta) == id ? new JsonObject { ["sectionId"] = null, ["sectionName"] = null } : null);
            }
        }
        catch (BotWriteException)
        {
            if (deletion.Undone) return;
            PutBack(deletion);
            throw;
        }
        lock (_gate) if (!deletion.Undone) _pendingSectionDeletes.Remove(id);
    }

    public void UndoDeleteSection(SectionDeletion deletion)
    {
        if (deletion.Undone) return;
        deletion.Undone = true;
        PutBack(deletion);
        var (id, name) = (deletion.Record.Id, deletion.Record.Name);
        foreach (var member in deletion.Members)
            _ = Task.Run(async () =>
            {
                try
                {
                    await WriteMetaAsync(member, $"Couldn’t Move {member}", meta =>
                        PinnedSection.Current(meta) == null ? new JsonObject { ["sectionId"] = id, ["sectionName"] = name } : null);
                }
                catch (BotWriteException) { }
            });
    }

    private void PutBack(SectionDeletion deletion)
    {
        lock (_gate)
        {
            _pendingSectionDeletes.Remove(deletion.Record.Id);
            if (Device.Sections.Any(s => s.Id == deletion.Record.Id)) return;
            Device.Sections.Insert(Math.Min(deletion.Index, Device.Sections.Count), deletion.Record);
        }
        Persist(); Rebuild();
    }

    // ---------------------------------------------------------------- Edit Bot (name, description)

    public sealed record EditOutcome(bool? TitleApplied, bool? DescriptionApplied, string? Reason)
    {
        public bool Succeeded => TitleApplied != false && DescriptionApplied != false;
    }

    /// One `profiles.configure` with the merged meta (title) and/or the profile's description.
    public Task<EditOutcome> SaveEditAsync(string name, string? title, string? description)
    {
        if (ReadOnly) throw new BotWriteException("Couldn’t Save Changes", BotWriteException.ReadOnlyReason);
        return Serial(name, async () =>
        {
            var p = new JsonObject { ["name"] = name };
            var baseMeta = CurrentMeta(name);
            var metaPatch = new JsonObject();
            if (title != null) metaPatch["title"] = title;
            string? oldDescription = Profiles().FirstOrDefault(x => x.Name == name)?.Description;
            lock (_gate) _metaWriteAt[name] = DateTimeOffset.UtcNow;
            if (metaPatch.Count > 0)
            {
                var before = baseMeta;
                SetLocalMeta(name, PinnedSection.Apply(metaPatch, before));
                try { baseMeta = await FreshMetaAsync(name, before); }
                catch (Exception e) when (e is GatewayException or BotWriteException)
                {
                    SetLocalMeta(name, before);
                    throw new BotWriteException("Couldn’t Save Changes", BotWriteException.ReasonOf(e));
                }
                var next = PinnedSection.Apply(metaPatch, baseMeta);
                SetLocalMeta(name, next);
                p["ui_meta"] = new JsonObject { [BotsKey] = Sendable(next) };
            }
            if (description != null)
            {
                lock (_gate) _descriptions[name] = description;
                Rebuild();
                p["description"] = description;
            }
            bool? titleApplied = null, descriptionApplied = null;
            string? reason = null;
            try
            {
                var result = await _gw.CallAsync("profiles.configure", p, TimeSpan.FromSeconds(30));
                var applied = result["applied"] as JsonObject;
                if (metaPatch.Count > 0)
                {
                    reason = MetaOutcome(result);
                    titleApplied = reason == null;
                    if (titleApplied == true) PatchRowMeta(name, CurrentMeta(name) is var held ? PinnedSection.Apply(metaPatch, held) : metaPatch);
                }
                if (description != null)
                {
                    descriptionApplied = RosterText.Bool(applied?["description"]) == true;
                    if (descriptionApplied == false)
                        reason ??= applied == null ? BotWriteException.UnsupportedReason : BotWriteException.NotSavedReason;
                }
            }
            catch (GatewayException e)
            {
                if (title != null) titleApplied = false;
                if (description != null) descriptionApplied = false;
                reason = BotWriteException.ReasonOf(e);
            }
            lock (_gate) _metaWriteAt[name] = DateTimeOffset.UtcNow;
            if (titleApplied == false) SetLocalMeta(name, PinnedSection.Apply(PinnedSection.UndoOf(baseMeta, metaPatch), CurrentMeta(name)));
            lock (_gate)
            {
                if (descriptionApplied == false) { if (oldDescription != null) _descriptions[name] = oldDescription; else _descriptions.Remove(name); }
                if (descriptionApplied == true)
                {
                    var at = _rows.FindIndex(r => RosterText.Trimmed(r["name"]) == name);
                    if (at >= 0) _rows[at] = WithDescription(_rows[at], description!);
                }
            }
            Persist(); Rebuild();
            return new EditOutcome(titleApplied, descriptionApplied, reason);
        });
    }

    // ---------------------------------------------------------------- New Bot, Duplicate, Delete

    public sealed record NewBotResult(string Name, string DisplayName, bool NeedsModel);

    /// `profiles.create` refused the name (4062: exists or invalid): shown under the Name field.
    public sealed class NewBotNameException(string message) : Exception(message);

    public bool IsTaken(string slug) => Profiles().Any(p => p.Name == slug);

    public bool IsDefaultBot(string name) =>
        name.Equals("default", StringComparison.OrdinalIgnoreCase) || Profiles().FirstOrDefault(p => p.Name == name)?.IsDefault == true;

    private async Task<bool> ProfileExistsAsync(string name)
    {
        try
        {
            var r = await _gw.CallAsync("profiles.list", new JsonObject { ["include_sessions"] = false }, SlimTimeout);
            return (r["profiles"] as JsonArray)?.Any(x => RosterText.Trimmed(x?["name"]) == name) == true;
        }
        catch (GatewayException) { return false; }
    }

    /// Steps 1–5 of New Bot (spec 1x-settings §8.2): create the profile, write its meta, check its runtime, mint its Bot Chat.
    public async Task<NewBotResult> CreateBotAsync(string typedName, string typedTitle, string description)
    {
        var (slug, title) = BotIdentity.ProfileIdentity(typedName, typedTitle);
        var display = BotIdentity.DisplayName(slug, title);
        var failTitle = $"Couldn’t Create {display}";
        if (ReadOnly) throw new BotWriteException(failTitle, BotWriteException.ReadOnlyReason);
        if (!BotIdentity.IsValidProfileId(slug)) throw new BotWriteException(failTitle, "Give the bot a name with letters or numbers.");
        var descriptionText = BotIdentity.DescriptionText(title, description);
        var teammates = Profiles().Select(p => (p.Name, p.Description)).ToList();
        var soul = BotIdentity.ComposeSoul(slug, title, description, BotModeProtocol ?? true, teammates);
        try
        {
            await _gw.CallAsync("profiles.create", new JsonObject
            {
                ["name"] = slug, ["description"] = descriptionText, ["clone_from"] = "default",
                ["no_skills"] = false, ["share_auth"] = true, ["soul"] = soul,
            }, TimeSpan.FromSeconds(90));
        }
        catch (GatewayException e) when (e.RpcCode == 4062) { throw new NewBotNameException(e.Message); }
        catch (GatewayException e)
        {
            if (e.Code != "timeout" || !await ProfileExistsAsync(slug))
                throw new BotWriteException(failTitle, BotWriteException.ReasonOf(e), e.Message);
        }
        var created = Math.Floor(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() * 1.0);
        var meta = new JsonObject { ["shape"] = "blobatar", ["imageKind"] = "shape", ["title"] = title, ["created"] = created };
        lock (_gate)
        {
            _createdRows[slug] = new JsonObject
            {
                ["name"] = slug, ["description"] = descriptionText, ["is_default"] = false,
                ["ui_meta"] = new JsonObject { [BotsKey] = meta.DeepClone() }, ["ui_meta_revisions"] = new JsonObject(),
            };
            Device.Meta[slug] = (JsonObject)meta.DeepClone();
        }
        Persist(); Rebuild();
        try { await WriteMetaAsync(slug, failTitle, _ => (JsonObject)meta.DeepClone()); } catch (BotWriteException) { }
        var needsModel = false;
        try
        {
            var readiness = await _gw.CallAsync("setup.runtime_check", new JsonObject { ["profile"] = slug }, TimeSpan.FromSeconds(30));
            needsModel = RosterText.Bool(readiness["ok"]) == false;
        }
        catch (GatewayException) { }
        try { await MintFreshChatAsync(slug, display); } catch (GatewayException) { }
        return new NewBotResult(slug, display, needsModel);
    }

    /// Duplicate Bot: `profiles.create {name: "<base>-N", clone_from, description}`, then the original's look.
    public async Task<string> DuplicateAsync(string baseName, string display)
    {
        var failTitle = $"Couldn’t Duplicate {display}";
        if (ReadOnly) throw new BotWriteException(failTitle, BotWriteException.ReadOnlyReason);
        var name = BotIdentity.DuplicateName(baseName, Profiles().Select(p => p.Name).ToHashSet())
            ?? throw new BotWriteException(failTitle, "No free name for the duplicate.");
        var description = Profiles().FirstOrDefault(p => p.Name == baseName)?.Description ?? "";
        var meta = BotIdentity.DuplicateMeta(CurrentMeta(baseName));
        try
        {
            await _gw.CallAsync("profiles.create", new JsonObject
            { ["name"] = name, ["clone_from"] = baseName, ["description"] = description }, TimeSpan.FromSeconds(90));
        }
        catch (GatewayException e)
        {
            if (e.Code != "timeout" || !await ProfileExistsAsync(name))
                throw new BotWriteException(failTitle, BotWriteException.ReasonOf(e), e.Message);
        }
        lock (_gate)
        {
            _createdRows[name] = new JsonObject
            {
                ["name"] = name, ["description"] = description, ["is_default"] = false,
                ["ui_meta"] = new JsonObject { [BotsKey] = Sendable(meta) }, ["ui_meta_revisions"] = new JsonObject(),
            };
            Device.Meta[name] = (JsonObject)meta.DeepClone();
        }
        Persist(); Rebuild();
        if (meta.Count > 0) { try { await WriteMetaAsync(name, failTitle, _ => (JsonObject)meta.DeepClone()); } catch (BotWriteException) { } }
        return name;
    }

    /// `DELETE /api/profiles/<name>`: its memory, skills, settings and chats. Never the default profile.
    public async Task DeleteAsync(string name, string display)
    {
        var failTitle = $"Couldn’t Delete {display}";
        if (ReadOnly) throw new BotWriteException(failTitle, BotWriteException.ReadOnlyReason);
        if (IsDefaultBot(name)) throw new BotWriteException(failTitle, "The default profile cannot be deleted.");
        RestAnswer answer;
        try { answer = await _gw.RestAsync(HttpMethod.Delete, "/api/profiles/" + Uri.EscapeDataString(name)); }
        catch (GatewayException e) { throw new BotWriteException(failTitle, BotWriteException.ReasonOf(e), e.Message); }
        if (!answer.Ok && answer.Status != 404)
            throw new BotWriteException(failTitle, RestReason(answer), $"HTTP {answer.Status}");
        lock (_gate)
        {
            _deletedAt[name] = DateTimeOffset.UtcNow;
            _createdRows.Remove(name);
            Device.Meta.Remove(name);
            Device.Mutes.Remove(name);
            Device.PinOrder.Remove(name);
        }
        Persist(); Rebuild();
    }

    /// The gateway's `detail` for a refused REST call, else plain words.
    public static string RestReason(RestAnswer a) =>
        a.Json?["detail"] is JsonValue v && RosterText.Text(v) is { Length: > 0 } d ? d : $"Your gateway answered {a.Status}.";

    // ---------------------------------------------------------------- the bot's own chat (spec 02 §8)

    /// The registry lookup: `session.list {profile, title:"Bot Chat", limit:200, include_hidden:true}`; null = absent.
    public async Task<RosterSessionRef?> RegistryLookupAsync(string name, CancellationToken ct = default)
    {
        var list = await _gw.CallAsync("session.list", new JsonObject
        {
            ["profile"] = name, ["title"] = RosterRules.BotChatTitle, ["limit"] = 200, ["include_hidden"] = true,
        }, TimeSpan.FromSeconds(30), ct);
        return (list["sessions"] as JsonArray)?.Select(RosterSessionRef.From).OfType<RosterSessionRef>()
            .FirstOrDefault(s => s.Id.Length > 0 && s.IsBotChat);
    }

    /// The stored id to open for a bot (§8.5): the roster's known chat at once; else the lookup, which may mint.
    public async Task<string> BotChatIdAsync(string name, CancellationToken ct = default)
    {
        var bot = Bot(name);
        if (bot?.OpenId is { } known) return known;
        var display = bot?.Name ?? name;
        return await MintFreshChatAsync(name, display, ct);
    }

    private async Task<string> MintFreshChatAsync(string name, string display, CancellationToken ct = default)
    {
        lock (_gate) if (_minted.TryGetValue(name, out var m)) return m;
        if (await RegistryLookupAsync(name, ct) is { } found)
        {
            lock (_gate) _minted[name] = found.OpenId;
            Rebuild();
            return found.OpenId;
        }
        if (ReadOnly) throw new BotWriteException($"Couldn’t Open {display}", BotWriteException.ReadOnlyReason);
        var created = await Hermes.Core.Settings.SessionCreate.CallAsync(_gw.CallAsync, new JsonObject
        {
            ["profile"] = name, ["title"] = RosterRules.BotChatTitle, ["hidden"] = true, ["follow_profile_config"] = true,
        }, name, TimeSpan.FromSeconds(30), ct: ct);
        var stored = RosterText.Trimmed(created["stored_session_id"]) ?? RosterText.Trimmed(created["session_id"])
            ?? throw new GatewayException("rpc", $"Could not open {display}’s chat: the gateway returned no session id");
        if (RosterText.Trimmed(created["session_id"]) is { } runtime)
        {
            try
            {
                await _gw.CallAsync("session.title", new JsonObject
                { ["session_id"] = runtime, ["title"] = RosterRules.BotChatTitle, ["profile"] = name }, TimeSpan.FromSeconds(30), ct);
            }
            catch (GatewayException e) when (e.Message.Contains("already in use", StringComparison.OrdinalIgnoreCase))
            {
                if (await RegistryLookupAsync(name, ct) is { } winner) stored = winner.OpenId;
            }
            catch (GatewayException) { }
        }
        lock (_gate) _minted[name] = stored;
        Rebuild();
        return stored;
    }
}

/// [botslist] A bot's standing problem, as its row says it in orange (parity §3 L185, docs/spec/3x-botslist.md §9). Port
/// of HermesKit/Model/Attention.swift at 93f984bb1: the classes and patterns are the desktop plugin's
/// (`V/plugins/hermes-bots/data.ts:54-166`). A passing failure (rate limit, 429, 5xx, overloaded, timeout) is not a
/// standing problem and says nothing. Display only, never saved: the latest failure wins and the bot's next good turn
/// clears it.
public enum Attention { ProviderAuthOrAccess, ProviderQuotaLimit, MissingConfig, AgentBlocked }

public static class AttentionReason
{
    /// The gateway's names for the classes (the Swift enum's raw values).
    public static string RawValue(this Attention kind) => kind switch
    {
        Attention.ProviderAuthOrAccess => "provider_auth_or_access",
        Attention.ProviderQuotaLimit => "provider_quota_limit",
        Attention.MissingConfig => "missing_config",
        _ => "agent_blocked",
    };

    /// The row's words. DECISION (spec §9): "bot", not "profile", and no Terminal command (the owner runs none); the
    /// chat's own error message says what failed.
    public static string Words(this Attention kind) => kind switch
    {
        Attention.ProviderAuthOrAccess => "Sign in again for this bot",
        Attention.ProviderQuotaLimit => "Quota or balance exhausted",
        Attention.MissingConfig => "Provider not set up",
        _ => "Bot is blocked — see its last message",
    };

    private const System.Text.RegularExpressions.RegexOptions I =
        System.Text.RegularExpressions.RegexOptions.IgnoreCase | System.Text.RegularExpressions.RegexOptions.CultureInvariant;
    private static readonly System.Text.RegularExpressions.Regex Transient = new(@"rate.?limit|too many requests|\b429\b|\b5\d\d\b|server error|overloaded|timed?.?out|timeout|temporar", I);
    private static readonly System.Text.RegularExpressions.Regex Missing = new(@"no llm provider|no access token|not configured|no api key|missing api key", I);
    private static readonly System.Text.RegularExpressions.Regex Auth = new(@"\b401\b|\b403\b|unauthorized|forbidden|authentication|invalid.?api.?key|credentials? (are )?(invalid|expired)", I);
    private static readonly System.Text.RegularExpressions.Regex Quota = new(@"quota|out of funds|insufficient (credits?|funds|balance)|payment required|\b402\b|billing", I);
    private static readonly System.Text.RegularExpressions.Regex Blocked = new(@"\bblocked\b", I);

    /// The class of a failed turn: the gateway's own `reason` when it names one, else read from the message; null for a
    /// passing failure or anything unrecognised.
    public static Attention? From(string? message, string? reason = null)
    {
        if (reason != null)
        {
            var named = reason.Trim().ToLowerInvariant();
            foreach (var kind in Enum.GetValues<Attention>())
                if (kind.RawValue() == named) return kind;
        }
        if (string.IsNullOrEmpty(message)) return null;
        if (Transient.IsMatch(message)) return null;
        if (Missing.IsMatch(message)) return Attention.MissingConfig;
        if (Auth.IsMatch(message)) return Attention.ProviderAuthOrAccess;
        if (Quota.IsMatch(message)) return Attention.ProviderQuotaLimit;
        if (Blocked.IsMatch(message)) return Attention.AgentBlocked;
        return null;
    }
}
