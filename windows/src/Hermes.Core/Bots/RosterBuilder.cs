using System.Text.Json.Nodes;

namespace Hermes.Core.Bots;

/// A user section as this device knows it (display order is the list order). Membership lives on each bot's meta.
public sealed record RosterSectionRecord(string Id, string Name);

/// One Bots row (HermesKit's `Bot` plus `BotRowDetail`).
public sealed record BotRow
{
    public required string Id { get; init; }                 // profile name
    public required string Name { get; init; }               // display name
    public string? Role { get; init; }
    public RosterPreview.Parts Preview { get; init; } = new(null, "No messages yet", true);
    /// Seconds since the epoch; 0 for a bot with nothing said yet.
    public double Time { get; init; }
    public DateTimeOffset? LastActive => Time > 0 ? DateTimeOffset.FromUnixTimeMilliseconds((long)(Time * 1000)) : null;
    public bool IsWorking { get; init; }
    public bool Unread { get; init; }
    public bool Pinned { get; init; }
    /// 0…5 for a tile, else null.
    public int? PinOrder { get; init; }
    /// The block's name ("Pinned", a user section's) or null for unassigned.
    public string? SectionName { get; init; }
    /// The section it goes back to when unpinned (menus show this one).
    public string? HomeSectionId { get; init; }
    public bool Hidden { get; init; }
    public string? RegistryId { get; init; }
    public string? OpenId { get; init; }
    public long? MessageCount { get; init; }
    /// "Waiting for your approval" / "Waiting for your reply" / "Waiting for you" while the chat waits on the person.
    public string? NeedsInput { get; init; }
    public bool Waking { get; init; }
    public string? Attention { get; init; }
    /// The working Bot Chat's step in a few words ("Reading package.json…").
    public string? Step { get; init; }
    public bool IsDefault { get; init; }
    public string? ModelName { get; init; }
    public required RosterProfile Profile { get; init; }
    /// The shared model other features draw from (BotHead, BotChatDestination).
    public required Hermes.Core.Model.Bot Model { get; init; }

    public string Handle => Profile.Handle;
}

/// The Bots list top to bottom (§7.5).
public sealed class RosterLayout
{
    public sealed record Section(string Id, string Name, List<BotRow> Bots)
    {
        public bool IsPinned => Id == RosterRules.PinnedSectionId;
    }

    public List<BotRow> Tiles { get; } = [];
    /// The Pinned section (pins past the tiles), then user sections with rows.
    public List<Section> Sections { get; } = [];
    public List<BotRow> Unassigned { get; } = [];
    public List<BotRow> Hidden { get; } = [];

    public IEnumerable<BotRow> Flat => Tiles.Concat(Sections.SelectMany(s => s.Bots)).Concat(Unassigned).Concat(Hidden);
}

public static class RosterBuilder
{
    public sealed class Input
    {
        public required IReadOnlyList<RosterProfile> Profiles { get; init; }
        /// Merged local meta snapshot by profile (§5.2).
        public IReadOnlyDictionary<string, JsonObject> Meta { get; init; } = new Dictionary<string, JsonObject>();
        public IReadOnlyList<RosterSectionRecord> Sections { get; init; } = [];
        /// Tile order: profile names, first tile first.
        public IReadOnlyList<string> PinOrder { get; init; } = [];
        public BotUnreadState Unread { get; init; } = new();
        /// Profiles whose own Bot Chat runs a turn.
        public IReadOnlySet<string> Working { get; init; } = new HashSet<string>();
        public IReadOnlyDictionary<string, string> NeedsInput { get; init; } = new Dictionary<string, string>();
        public IReadOnlyDictionary<string, string> Steps { get; init; } = new Dictionary<string, string>();
        public IReadOnlyDictionary<string, string> Drafts { get; init; } = new Dictionary<string, string>();
        public IReadOnlyDictionary<string, string> Lost { get; init; } = new Dictionary<string, string>();
        public IReadOnlySet<string> Waking { get; init; } = new HashSet<string>();
        public IReadOnlyDictionary<string, string> Attention { get; init; } = new Dictionary<string, string>();
        /// Bot Chats this device created since the last roster named them: profile → stored id.
        public IReadOnlyDictionary<string, string> MintedChats { get; init; } = new Dictionary<string, string>();
    }

    /// The meta a row is drawn with: `{...snapshot, ...server}` when the row carries its own object, else the snapshot.
    public static JsonObject MetaObject(RosterProfile profile, IReadOnlyDictionary<string, JsonObject> snapshot)
    {
        snapshot.TryGetValue(profile.Name, out var local);
        if (profile.ServerMeta is not { } server) return local == null ? [] : (JsonObject)local.DeepClone();
        if (local is null || local.Count == 0) return (JsonObject)server.DeepClone();
        var merged = (JsonObject)local.DeepClone();
        foreach (var (k, v) in server) merged[k] = v?.DeepClone();
        return merged;
    }

    /// Strips/skips scheduled wake lines and saved `[Voice chat transcript` headers from a bot's latest-message preview
    /// so automated wake boilerplate and voice transcripts never leak into the Bots list preview.
    public static string CleanLatestPreview(string? raw, bool holdsMessages = false)
    {
        if (string.IsNullOrWhiteSpace(raw)) return "";
        var trimmed = raw.Trim();
        if (Transcripts.TimelineNotes.IsScheduledWake(trimmed) || Transcripts.UpdateGroups.IsVoiceTranscript(trimmed))
            return holdsMessages ? BotSaidRules.NothingShown : "";
        return raw;
    }

    public static RosterLayout Build(Input input)
    {
        var profiles = input.Profiles;
        var metas = profiles.Select(p => BotMeta.From(MetaObject(p, input.Meta))).ToList();
        var names = profiles.Select((p, i) => RosterRules.DisplayName(p, metas[i])).ToList();
        var nameByHandle = new Dictionary<string, string>();
        for (var i = 0; i < profiles.Count; i++) nameByHandle.TryAdd(profiles[i].Handle, names[i]);

        // Sort (§7.2): pinned first, then newest first; ties keep profiles.list order.
        var order = Enumerable.Range(0, profiles.Count).OrderBy(i => metas[i].EffectivePinned ? 0 : 1)
            .ThenByDescending(i => RosterRules.SortTime(profiles[i], metas[i])).ThenBy(i => i).ToList();

        // Tiles (§7.3): the first six visible pins, dragged order first.
        var rank = new Dictionary<string, int>();
        for (var i = 0; i < input.PinOrder.Count; i++) rank.TryAdd(input.PinOrder[i], i);
        var pins = order.Where(i => metas[i].EffectivePinned && !metas[i].Hidden).ToList();
        var tileIndices = pins.Select((p, offset) => (p, offset))
            .OrderBy(x => rank.TryGetValue(profiles[x.p].Name, out var r) ? r : int.MaxValue).ThenBy(x => x.offset)
            .Take(RosterRules.MaxTiles).Select(x => x.p).ToList();
        var tileSet = tileIndices.ToHashSet();
        var known = input.Sections.Where(s => s.Id != RosterRules.PinnedSectionId).ToList();
        var knownIds = known.Select(s => s.Id).ToHashSet();

        BotRow Row(int i, string? sectionName, int? pinOrder)
        {
            var profile = profiles[i];
            var meta = metas[i];
            var name = names[i];
            var role = RosterRules.RoleLine(profile, meta, name);
            var source = RosterRules.RosterPreviewOf(profile);
            var rawSource = RosterPreview.SourcePreview(profile, source.Preview);
            var holds = RosterRules.HoldsMessages(profile.CanonicalSession);
            var text = CleanLatestPreview(rawSource, holds);
            var ignored = text == BotSaidRules.NothingShown || (text.Length == 0 && rawSource.Length > 0);
            var handle = ignored ? null : RosterPreview.DeliveryHandle(source.Preview);
            var fromBot = handle == null ? null : nameByHandle.TryGetValue(handle, out var n) ? n : handle;
            var parts = RosterPreview.BotPreview(text, fromBot, false, role);
            if (input.Lost.TryGetValue(profile.Name, out var lost))
                parts = RosterPreview.BotPreview(lost, null, true, role) with { Prefix = RosterPreview.NotDeliveredPrefix };
            else if (input.Drafts.TryGetValue(profile.Name, out var draft))
                parts = RosterPreview.BotPreview(draft, null, true, role);
            var canonical = profile.CanonicalSession;
            var registryId = canonical is { Id.Length: > 0 } ? canonical.Id : null;
            var openId = registryId != null ? canonical!.OpenId : input.MintedChats.GetValueOrDefault(profile.Name);
            return new BotRow
            {
                Id = profile.Name, Name = name, Role = role, Preview = parts, Time = source.Time,
                IsWorking = input.Working.Contains(profile.Name), Unread = input.Unread.IsUnread(profile),
                Pinned = meta.EffectivePinned, PinOrder = pinOrder, SectionName = sectionName,
                HomeSectionId = meta.HomeSectionId, Hidden = meta.Hidden, RegistryId = registryId, OpenId = openId,
                MessageCount = canonical?.MessageCount, NeedsInput = input.NeedsInput.GetValueOrDefault(profile.Name),
                Waking = input.Waking.Contains(profile.Name), Attention = input.Attention.GetValueOrDefault(profile.Name),
                Step = input.Steps.GetValueOrDefault(profile.Name), IsDefault = profile.IsDefault, ModelName = profile.Model,
                Profile = profile, Model = profile.ToModel(name, meta),
            };
        }

        var layout = new RosterLayout();
        for (var t = 0; t < tileIndices.Count; t++) layout.Tiles.Add(Row(tileIndices[t], null, t));
        var pinnedRows = new List<BotRow>();
        var bySection = new Dictionary<string, List<BotRow>>();
        foreach (var i in order)
        {
            if (tileSet.Contains(i)) continue;
            var meta = metas[i];
            if (meta.Hidden) layout.Hidden.Add(Row(i, null, null));
            else if (meta.EffectivePinned) pinnedRows.Add(Row(i, RosterRules.PinnedSectionName, null));
            else if (meta.HomeSectionId is { } id && knownIds.Contains(id))
            {
                var section = known.First(s => s.Id == id);
                if (!bySection.TryGetValue(id, out var list)) bySection[id] = list = [];
                list.Add(Row(i, section.Name, null));
            }
            else layout.Unassigned.Add(Row(i, null, null));
        }
        if (pinnedRows.Count > 0) layout.Sections.Add(new(RosterRules.PinnedSectionId, RosterRules.PinnedSectionName, pinnedRows));
        foreach (var s in known)
            if (bySection.TryGetValue(s.Id, out var rows) && rows.Count > 0) layout.Sections.Add(new(s.Id, s.Name, rows));
        return layout;
    }

    /// Section adoption (`HB/user-sections.ts:159-191`): a section id this device does not know is added with the name
    /// its members carry; a known section takes its members' name when they all agree on one.
    public static List<RosterSectionRecord> AdoptSections(IReadOnlyList<RosterSectionRecord> local, IEnumerable<RosterProfile> profiles,
        IReadOnlyDictionary<string, JsonObject> snapshot)
    {
        var names = new List<(string Id, List<string> Names)>();
        foreach (var profile in profiles)
        {
            var meta = BotMeta.From(MetaObject(profile, snapshot));
            if (meta.SectionId is not { } id || id == RosterRules.PinnedSectionId || meta.SectionName is not { } name) continue;
            var at = names.FindIndex(n => n.Id == id);
            if (at >= 0) { if (!names[at].Names.Contains(name)) names[at].Names.Add(name); }
            else names.Add((id, [name]));
        }
        var current = local.Where(r => r.Id != RosterRules.PinnedSectionId).ToList();
        var knownIds = current.Select(r => r.Id).ToHashSet();
        var next = current.Select(r =>
        {
            var entry = names.FirstOrDefault(n => n.Id == r.Id);
            return entry.Names is { Count: 1 } ? r with { Name = entry.Names[0] } : r;
        }).ToList();
        foreach (var entry in names) if (!knownIds.Contains(entry.Id)) next.Add(new RosterSectionRecord(entry.Id, entry.Names[0]));
        return next;
    }
}

/// The list's blocks (HermesKit's BotListSectionID). [groups] `Groups`: the Group Chats block; `GroupSection`: a user
/// section's sub-block inside it (`SectionId` its id); `Everything`: Group By › None's one block (App/Bots/BotListModel.swift).
public enum BotBlock { Tiles, Pinned, User, Unassigned, Hidden, Groups, GroupSection, Everything }

/// One block of the Bots list (tiles, Pinned, a user section, the unassigned rows, Hidden; [groups] Group Chats and its
/// sub-blocks). `Rooms`: the block's group chats, drawn among its bots (`BotListRooms.Rows`).
public sealed record BotListSection(BotBlock Block, string? SectionId, string? Title, IReadOnlyList<BotRow> Bots)
{
    public IReadOnlyList<Groups.GroupRowModel> Rooms { get; init; } = [];
    /// [groups] The heads in the sidebar's drawing order when a merge set it (the tiles then the Pinned rows, each bots
    /// then rooms: `MacBotsRail.groups`); null: `BotListRooms.Rows`.
    public IReadOnlyList<BotListHead>? Order { get; init; }

    /// "tiles", "pinned", "user:<id>", "unassigned", "hidden", "groups", "group-section:<id>", "everything": what a
    /// collapsed set keeps (`MacSidebarHeading.key(for:)` for the group chats' blocks).
    public string Key => Block switch
    {
        BotBlock.User => "user:" + SectionId,
        BotBlock.GroupSection => "group-section:" + SectionId,
        _ => Block.ToString().ToLowerInvariant(),
    };

    /// The block's bots and group chats in drawing order.
    public IReadOnlyList<BotListHead> Heads => Order ?? BotListRooms.Rows(this);
}

/// What the Bots list shows (App/Bots/BotListModel.swift, BotListSections.swift, App/Mac/MacBotsRail.swift). Pure.
public static class BotList
{
    public const string UnassignedName = "Unassigned";

    /// tiles → Pinned (only when pins overflow the tiles) → user sections (empty ones included) → unassigned → Hidden.
    public static List<BotListSection> Compose(RosterLayout layout, IReadOnlyList<RosterSectionRecord> records)
    {
        var o = new List<BotListSection>();
        if (layout.Tiles.Count > 0) o.Add(new(BotBlock.Tiles, null, null, layout.Tiles));
        if (layout.Sections.FirstOrDefault(s => s.IsPinned) is { } pinned)
            o.Add(new(BotBlock.Pinned, RosterRules.PinnedSectionId, RosterRules.PinnedSectionName, pinned.Bots));
        var shown = new HashSet<string>();
        foreach (var r in records.Where(r => r.Id != RosterRules.PinnedSectionId))
        {
            o.Add(new(BotBlock.User, r.Id, r.Name, layout.Sections.FirstOrDefault(s => s.Id == r.Id)?.Bots ?? []));
            shown.Add(r.Id);
        }
        foreach (var s in layout.Sections.Where(s => !s.IsPinned && !shown.Contains(s.Id)))
            o.Add(new(BotBlock.User, s.Id, s.Name, s.Bots));
        if (layout.Unassigned.Count > 0) o.Add(new(BotBlock.Unassigned, null, null, layout.Unassigned));
        if (layout.Hidden.Count > 0) o.Add(new(BotBlock.Hidden, null, "Hidden", layout.Hidden));
        return o;
    }

    /// The Mac sidebar's titled groups (MacBotsRail.titledGroups / groups): the tiles and the Pinned rows one "Pinned"
    /// group (the bots then the group chats of each, in the order the person set), each user section (an empty one too),
    /// the rest under "Unassigned" when there is a user section else "Bots", [groups] Group Chats and its sub-blocks
    /// ("Group Chats" when untitled), Group By › None's one block with no heading, and Hidden last only with Show Hidden
    /// Bots. Hidden rooms only in Hidden.
    public static List<BotListSection> SidebarGroups(IReadOnlyList<BotListSection> sections, bool showHidden = false)
    {
        var o = new List<BotListSection>();
        var anyUser = sections.Any(s => s.Block == BotBlock.User);
        foreach (var raw in sections)
        {
            if (raw.Block == BotBlock.Hidden && !showHidden) continue;
            var s = raw.Block == BotBlock.Hidden ? raw : raw with { Rooms = [.. raw.Rooms.Where(r => !r.Hidden)] };
            switch (s.Block)
            {
                case BotBlock.Tiles:
                    o.Add(s with { Title = RosterRules.PinnedSectionName, Order = PinsOrder(s) });
                    break;
                case BotBlock.Pinned when o.LastOrDefault()?.Block == BotBlock.Tiles:
                    o[^1] = o[^1] with { Bots = [.. o[^1].Bots, .. s.Bots], Rooms = [.. o[^1].Rooms, .. s.Rooms], Order = [.. o[^1].Heads, .. PinsOrder(s)] };
                    break;
                case BotBlock.Pinned:
                    if (s.Bots.Count > 0 || s.Rooms.Count > 0) o.Add(s with { Order = PinsOrder(s) });
                    break;
                case BotBlock.Unassigned:
                    if (s.Bots.Count > 0 || s.Rooms.Count > 0) o.Add(s with { Title = NonEmpty(s.Title) ?? (anyUser ? UnassignedName : "Bots") });
                    break;
                case BotBlock.Groups or BotBlock.GroupSection:
                    if (s.Rooms.Count > 0) o.Add(s with { Title = NonEmpty(s.Title) ?? BotListRooms.GroupChatsTitle });
                    break;
                case BotBlock.Everything:
                    if (s.Bots.Count > 0 || s.Rooms.Count > 0) o.Add(s with { Title = "" });   // Mac polish #130: no heading
                    break;
                default:
                    if (s.Bots.Count > 0 || s.Rooms.Count > 0 || s.Block == BotBlock.User) o.Add(s);
                    break;
            }
        }
        return o;
    }

    private static string? NonEmpty(string? s) => string.IsNullOrEmpty(s) ? null : s;

    /// [macpass-sidebar] The pins hold the order the person set: the bots in their tile order, then the pinned rooms.
    private static List<BotListHead> PinsOrder(BotListSection s) => [.. s.Bots.Select(b => new BotListHead(b, null)), .. s.Rooms.Select(r => new BotListHead(null, r))];

    /// Search: display name, profile, role and preview, every word, hidden bots included.
    public static List<BotRow> Search(IEnumerable<BotRow> bots, string query)
    {
        var words = query.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        if (words.Length == 0) return [];
        return bots.Where(b =>
        {
            var hay = string.Join('\n', b.Name, b.Id, "@" + b.Handle, b.Role ?? "", b.Preview.IsFallback ? "" : b.Preview.Line);
            return words.All(w => hay.Contains(w, StringComparison.CurrentCultureIgnoreCase));
        }).ToList();
    }

    public enum Tone { Secondary, Tint, Attention }
    public enum RowStatus { Attention, Waking, NeedsInput, Working, Idle }

    public static RowStatus StatusOf(BotRow bot)
    {
        if (bot.Attention != null && !bot.Waking) return RowStatus.Attention;
        if (bot.Waking) return RowStatus.Waking;
        if (bot.NeedsInput != null) return RowStatus.NeedsInput;
        return bot.IsWorking ? RowStatus.Working : RowStatus.Idle;
    }

    /// A row's second line (spec 02 §6.5): waiting for an answer, "Working…" (or its step), else the preview with its
    /// prefix, the role, or "No messages yet".
    public static (string? Prefix, string Text, Tone Tone) SecondLine(BotRow bot) => StatusOf(bot) switch
    {
        RowStatus.Attention => (null, bot.Attention ?? "", Tone.Attention),
        RowStatus.Waking => (null, "Waking up…", Tone.Secondary),
        RowStatus.NeedsInput => (null, bot.NeedsInput ?? "", Tone.Attention),
        RowStatus.Working => (null, bot.Step ?? "Working…", Tone.Tint),
        _ => !bot.Preview.IsFallback && bot.Preview.Text.Trim().Length > 0 ? (bot.Preview.Prefix, WithFileNames(WithoutTableRules(bot.Preview.Text)), Tone.Secondary)
            : (null, RosterText.NonBlank(bot.Role) ?? "No messages yet", Tone.Secondary),
    };

    /// A table's divider row left in a preview ("Name · Age --- · --- Ada · 36") goes.
    public static string WithoutTableRules(string text)
    {
        if (!text.Contains("---")) return text;
        static bool IsRule(string w) => w.Count(c => c == '-') >= 3 && w.All(c => c is '-' or ':' or '|');
        var kept = new List<string>();
        foreach (var word in text.Split(' ', StringSplitOptions.RemoveEmptyEntries))
        {
            if (IsRule(word)) continue;
            if (word == "·" && (kept.Count == 0 || kept[^1] == "·")) continue;
            kept.Add(word);
        }
        while (kept.Count > 0 && kept[^1] == "·") kept.RemoveAt(kept.Count - 1);
        return string.Join(' ', kept);
    }

    /// "MEDIA:/fixture/media/clip.mov" reads as its file's name.
    public static string WithFileNames(string text)
    {
        if (!text.Contains("MEDIA:")) return text;
        return string.Join(' ', text.Split(' ').Select(word =>
        {
            if (!word.StartsWith("MEDIA:")) return word;
            var path = word["MEDIA:".Length..].Trim('`', '\'', '"');
            var name = path.Split('/').LastOrDefault() ?? "";
            return name.Length == 0 ? word : name;
        }));
    }

    /// [botslist] [WIN-WAKING-SPINNER] "Waking up…" has a small spinner before the words (BotRowViews.swift `bottomLine`
    /// at 93f984bb1, `bot-row.tsx:198`), hidden from UI Automation: the row's name says the words.
    public static bool RowShowsSpinner(BotRow bot) => StatusOf(bot) == RowStatus.Waking;

    /// [working-ring] A pinned tile's corner (`status`: its `StatusOf`): a standing problem lasts until the bot's next good
    /// reply, so a bot asked to try again wore the orange badge with only the ring saying it works. With the ring off, the
    /// working dots take the corner while it works; the badge is back if the turn fails again (BotListModel.swift).
    public static bool TileShowsWorkingOverProblem(BotRow bot, RowStatus status, bool ringOn) =>
        !ringOn && status == RowStatus.Attention && bot.IsWorking;

    /// What a face's bottom-right corner shows (BotRowViews.swift `BotAvatar`).
    public enum FaceBadge { None, Attention, Waking, Waiting, Working, Unread }

    /// A face's corner, first match first (`BotAvatar.body` at 93f984bb1). `tile`: a face with no line beside it (a pinned
    /// tile, the rail): its standing problem (the orange badge, unless the working dots take it), "Waking up…" (a small
    /// spinner) and waiting on you (the orange dot) show there; a row's face reads idle, its second line says them. Then
    /// the working dots (`rowBadge`: a running turn; Windows has no browser or computer presence yet), then the unread
    /// dot where the face carries presence.
    public static FaceBadge FaceBadgeOf(BotRow bot, bool tile, bool ringOn, bool presence)
    {
        var status = tile ? StatusOf(bot) : RowStatus.Idle;
        if (status == RowStatus.Attention && !TileShowsWorkingOverProblem(bot, status, ringOn)) return FaceBadge.Attention;
        if (status == RowStatus.Waking) return FaceBadge.Waking;
        if (status == RowStatus.NeedsInput) return FaceBadge.Waiting;
        if (RowBadgeOf(bot) == RowBadge.Working) return FaceBadge.Working;
        return presence && bot.Unread ? FaceBadge.Unread : FaceBadge.None;
    }

    /// What a face's badges sit on, so what they are ringed in (BotRowViews.swift `hqBadgeRing`).
    public enum BadgeGround { Page, SidebarPanel }

    /// [WIN-ROW-FACE-RING-PANEL] Every face badge (unread and waiting dots, working dots, attention, the waking spinner) has
    /// a ring this wide round it (`.background(Circle().fill(ring ?? Color.hqPage).padding(-2))`).
    public const double BadgeRingWidth = 2;

    /// [WIN-ROW-FACE-RING-PANEL] The ring's colour: the page by default (`hqBadgeRing` nil → `Color.hqPage`); the Mac's
    /// sidebar, both the open sidebar's rows and the folded rail (MacBotsRail.swift `MacRailHead.configuration`), sets it
    /// to the sidebar panel's (`MacSidebar.panelColor`), where a page-white ring showed as a halo round every dot.
    public static Hermes.Core.Settings.Rgba BadgeRing(BadgeGround ground, Hermes.Core.Settings.ThemeTokens t) =>
        ground == BadgeGround.SidebarPanel ? t.SidebarPanel : t.Page;

    /// The brush the app paints the ring with (Features/Settings/ThemeService.cs maps each to its token).
    public static string BadgeRingBrushKey(BadgeGround ground) =>
        ground == BadgeGround.SidebarPanel ? "HQSidebarPanelBrush" : "HQPageBrush";

    /// `clamp(14, 0.36 × head, 22)`: 20 on a 56 head (`BotAvatar.badgeSize`).
    public static double BadgeSize(double size) => Math.Round(Math.Min(22, Math.Max(14, size * 0.36)), MidpointRounding.AwayFromZero);

    /// `clamp(8, 0.24 × head, 16)`: 12 on a 50 head (`BotAvatar.presenceSize`).
    public static double PresenceSize(double size) => Math.Round(Math.Min(16, Math.Max(8, size * 0.24)), MidpointRounding.AwayFromZero);

    /// [WIN-ROW-FACE-CORNER] `clamp(8, 0.24 × head, 16) + 2`: the orange waiting dot on a tile (`WaitingBadge`'s height).
    public static double WaitingSize(double size) => PresenceSize(size) + 2;

    /// [WIN-ROW-FACE-CORNER] The working badge's three dots (`WorkingBadge.dots`): each `max(2, round(0.15 × h))` across,
    /// `max(1, round(0.1 × h))` apart, on an accent circle `h` across.
    public static (double Dot, double Gap) WorkingDots(double badge) =>
        (Math.Max(2, Math.Round(badge * 0.15, MidpointRounding.AwayFromZero)), Math.Max(1, Math.Round(badge * 0.1, MidpointRounding.AwayFromZero)));

    /// The face's corner badge for a row and a tile alike (`BotList.RowBadge`): the working dots for a running turn.
    /// Windows has no browser or computer presence yet, so the Mac's `.computer` has no case here.
    public enum RowBadge { Working }

    /// `BotList.rowBadge`: any status with a running turn wears the working dots (a waiting or failed bot's too).
    public static RowBadge? RowBadgeOf(BotRow bot) => bot.IsWorking ? RowBadge.Working : null;

    /// The unread circle: not while the face shows the working dots (`showsUnread`: `unread && rowBadge == nil`).
    public static bool ShowsUnread(BotRow bot) => bot.Unread && RowBadgeOf(bot) == null;

    /// "<name>. <line>. <time>. Unread. Pinned. Muted. Hidden" (present parts only).
    public static string AccessibilityLabel(BotRow bot, string time, bool muted = false)
    {
        var (prefix, text, _) = SecondLine(bot);
        var parts = new List<string> { bot.Name, prefix is null ? text : $"{prefix} {text}" };
        if (time.Length > 0) parts.Add(time);
        if (ShowsUnread(bot)) parts.Add("Unread");
        if (bot.Pinned) parts.Add("Pinned");
        if (muted) parts.Add("Muted");
        if (bot.Hidden) parts.Add("Hidden");
        return Spoken(parts);
    }

    public static string Spoken(IEnumerable<string> parts)
    {
        var line = "";
        foreach (var raw in parts)
        {
            var part = raw.Trim();
            if (part.Length == 0) continue;
            if (line.Length == 0) { line = part; continue; }
            var closed = ".…!?。！？".Contains(line[^1]);
            line += (closed ? " " : ". ") + part;
        }
        return line;
    }

    /// Bots counted on the badge: unread (and not working) and not hidden.
    public static int UnreadCount(IEnumerable<BotRow> bots) => bots.Count(b => ShowsUnread(b) && !b.Hidden);

    // ---------------------------------------------------------------- sections' words (BotListSections.swift)

    public const string EmptyHint = "Drag a bot or group chat here, or right-click one and choose Move to Section.";

    /// Delete Section's question; null: nothing is filed there, so it goes at once.
    public static string? DeleteSectionMessage(int bots) => bots switch
    {
        0 => null,
        1 => "Its bot moves to Unassigned.",
        _ => $"Its {bots} bots move to Unassigned.",
    };

    public static readonly string[] ReservedSectionNames = [UnassignedName, "Hidden", RosterRules.PinnedSectionName, "Group Chats"];

    /// Why New Section / Rename can't take `name`, or null.
    public static string? SectionNameProblem(string name, IEnumerable<string> others)
    {
        var clean = name.Trim();
        if (clean.Length == 0) return null;
        if (ReservedSectionNames.FirstOrDefault(r => string.Equals(r, clean, StringComparison.OrdinalIgnoreCase)) is { } reserved)
            return $"“{reserved}” is already a heading in the Bots list. Choose another name.";
        if (others.FirstOrDefault(o => string.Equals(o.Trim(), clean, StringComparison.OrdinalIgnoreCase)) is { } taken)
            return $"There’s already a section named “{taken}”.";
        return null;
    }

    /// Bot Info's status line under the role: the live status in the row's own words, else how long ago it was active.
    public static string? InfoStatus(BotRow bot, DateTimeOffset now)
    {
        if (StatusOf(bot) != RowStatus.Idle) return SecondLine(bot).Text;
        if (bot.LastActive is not { } last) return null;
        var seconds = Math.Max(0, (now - last).TotalSeconds);
        if (seconds < 60) return "Active now";
        if (seconds < 3600) return $"Active {(int)(seconds / 60)} min ago";
        if (seconds < 86_400) return $"Active {(int)(seconds / 3600)} hr ago";
        var days = (now.LocalDateTime.Date - last.LocalDateTime.Date).Days;
        return days <= 1 ? "Active yesterday" : $"Active {days} days ago";
    }
}
