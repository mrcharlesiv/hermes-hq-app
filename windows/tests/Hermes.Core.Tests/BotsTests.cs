using System.Text.Json.Nodes;
using Hermes.Core.Bots;
using Hermes.Core.Net;

namespace Hermes.Core.Tests;

/// A scripted gateway: each call or REST request is answered by the first handler that takes it, and recorded.
internal sealed class FakeGateway : IListsGateway
{
    public string AccountId => "acct";
    public List<(string Method, JsonObject Params)> Calls { get; } = [];
    public List<(string Method, string Path, string Query, JsonNode? Body)> Rest { get; } = [];
    public Func<string, JsonObject, JsonNode?>? OnCall { get; set; }
    public Func<string, string, string, JsonNode?, RestAnswer?>? OnRest { get; set; }

    public Task<JsonNode> CallAsync(string method, JsonObject parameters, TimeSpan timeout, CancellationToken ct = default)
    {
        lock (Calls) Calls.Add((method, (JsonObject)parameters.DeepClone()));
        var answer = OnCall?.Invoke(method, parameters);
        return answer == null ? throw new GatewayException("rpc", $"no handler for {method}", rpcCode: -32601) : Task.FromResult(answer);
    }

    public Task<RestAnswer> RestAsync(HttpMethod method, string path, IEnumerable<KeyValuePair<string, string>>? query = null,
        JsonNode? body = null, CancellationToken ct = default)
    {
        var q = string.Join("&", (query ?? []).Select(kv => kv.Key + "=" + kv.Value));
        lock (Rest) Rest.Add((method.Method, path, q, body?.DeepClone()));
        return Task.FromResult(OnRest?.Invoke(method.Method, path, q, body) ?? new RestAnswer(404, """{"detail":"Not Found"}"""));
    }
}

public class BotsWireTests
{
    private static JsonNode Roster() => Fixture.Load("demo-profiles-list.json") is var j && j["result"] is { } r ? r : j;

    [Fact]
    public void DecodesTheDemoRoster()
    {
        var snap = RosterSnapshot.Decode(Roster());
        Assert.Equal(9, snap.Profiles.Count);
        var inbox = snap.Profiles.First(p => p.Name == "inbox");
        var meta = BotMeta.From(inbox.ServerMeta);
        Assert.Equal("Inbox", RosterRules.DisplayName(inbox, meta));
        Assert.Equal("Triage, replies and follow-ups", RosterRules.RoleLine(inbox, meta, "Inbox"));
        Assert.Equal("sec-work", meta.SectionId);
        Assert.False(meta.EffectivePinned);
        Assert.Equal("inbox", inbox.Handle);
        Assert.Equal("hermes", snap.Profiles.First(p => p.Name == "default").Handle);
    }

    [Fact]
    public void CleansTextFieldsThatArriveAsNumbers()
    {
        var p = RosterProfile.From(JsonNode.Parse(
            """{"name":"n1","display_name":2025,"description":{"x":1},"ui_meta":{"hermes-bots":{"title":true,"pinned":1}}}"""))!;
        Assert.Equal("2025", p.DisplayName);
        Assert.Null(p.Description);
        var meta = BotMeta.From(p.ServerMeta);
        Assert.Equal("true", meta.Title);
        Assert.True(meta.Pinned);
        Assert.Null(RosterProfile.From(JsonNode.Parse("""{"name":"  "}""")));
        Assert.Null(RosterProfile.From(JsonNode.Parse("""{"name":"x","ui_meta":[1]}"""))!.ServerMeta);
    }

    [Theory]
    [InlineData("research-buddy", "Research Buddy")]
    [InlineData("my__bot", "My Bot")]
    [InlineData("a1b", "A1b")]
    public void TitleCasesProfileNames(string raw, string want) => Assert.Equal(want, RosterRules.TitleCase(raw));

    [Fact]
    public void ComposesThePinnedSectionsAndUserSections()
    {
        var store = new BotStore(new FakeGateway(), new MemoryDeviceStore());
        store.ApplyFull(Roster(), DateTimeOffset.UtcNow);
        var tiles = store.Layout.Tiles.Select(b => b.Id).ToList();
        Assert.Equal(["default", "deploys", "research"], tiles.Order().ToList());
        Assert.Equal(["Work", "Home"], store.Device.Sections.Select(s => s.Name).ToList());
        var groups = BotList.SidebarGroups(store.Sections);
        Assert.Equal(["Pinned", "Work", "Home"], groups.Select(g => g.Title).ToList());
        Assert.Equal(new[] { "finance", "inbox", "writing" }, groups[1].Bots.Select(b => b.Id).Order());
        Assert.All(groups[2].Bots, b => Assert.Equal("Home", b.SectionName));
        // Newest first inside a section.
        var work = groups[1].Bots;
        Assert.True(work.Zip(work.Skip(1)).All(p => p.First.Time >= p.Second.Time));
    }

    [Fact]
    public void UnassignedIsTitledBotsWithoutSectionsAndUnassignedWithThem()
    {
        var layout = new RosterLayout();
        var p = RosterProfile.From(JsonNode.Parse("""{"name":"ivy"}"""))!;
        var row = new BotRow { Id = "ivy", Name = "Ivy", Profile = p, Model = p.ToModel("Ivy", new BotMeta()) };
        layout.Unassigned.Add(row);
        Assert.Equal("Bots", BotList.SidebarGroups(BotList.Compose(layout, []))[0].Title);
        var withSection = BotList.SidebarGroups(BotList.Compose(layout, [new RosterSectionRecord("s1", "Work")]));
        Assert.Equal(["Work", "Unassigned"], withSection.Select(g => g.Title).ToList());
        Assert.Empty(withSection[0].Bots);      // an empty user section stays
    }

    [Fact]
    public void RowPreviewsRewordMachineNotes()
    {
        Assert.Equal("Model changed to claude-opus-5-5",
            RosterPreview.RowPreview("[System: The active model for this chat has changed to claude-opus-5-5.] go on"));
        Assert.Equal("Model changed", RosterPreview.RowPreview("[System: The active model for this chat has changed to claude-op..."));
        Assert.Equal("Kanban task", RosterPreview.RowPreview("work kanban task t_522444de"));
        Assert.Equal("Checking in", RosterPreview.RowPreview("[System note: Checking in]"));
    }

    [Fact]
    public void DeliveriesNameTheirSender()
    {
        var text = "Message from agent 'ivy': here is **the** `plan`";
        Assert.Equal("ivy", RosterPreview.DeliveryHandle(text));
        var parts = RosterPreview.BotPreview(text, "Ivy", false, "Research");
        Assert.Equal("From Ivy:", parts.Prefix);
        Assert.Equal("here is the plan", parts.Text);
        Assert.Equal("Research", RosterPreview.BotPreview("[SILENT]", null, false, "Research").Text);
        Assert.Equal("No messages yet", RosterPreview.BotPreview("", null, false, null).Text);
        Assert.Equal("Draft:", RosterPreview.BotPreview("half typed", null, true, null).Prefix);
    }

    [Fact]
    public void StripsMarkdownAndTableRules()
    {
        Assert.Equal("Name · Age · Ada · 36", RosterPreview.StripMarkdown("| Name | Age |\n|---|---|\n| Ada | 36 |"));
        Assert.Equal("Name · Age · Ada · 36", BotList.WithoutTableRules("Name · Age --- · --- Ada · 36"));
        Assert.Equal("see clip.mov", BotList.WithFileNames("see MEDIA:/fixture/media/clip.mov"));
    }

    [Fact]
    public void PinnedSectionPatchesFollowTheTable()
    {
        static string? Name(string id) => id == "sec-work" ? "Work" : null;
        // pinned, sectionId elsewhere → filed in Pinned with its home
        var p1 = PinnedSection.PinnedSectionPatch(JsonNode.Parse("""{"pinned":true,"sectionId":"sec-work","sectionName":"Work"}""")!.AsObject(), Name)!;
        Assert.Equal("hermes-hq-pinned", p1["sectionId"]!.GetValue<string>());
        Assert.Equal("sec-work", p1["pinnedFrom"]!["id"]!.GetValue<string>());
        // not pinned, in Pinned, has a home → back home
        var p2 = PinnedSection.PinnedSectionPatch(JsonNode.Parse("""{"pinned":false,"sectionId":"hermes-hq-pinned","pinnedFrom":{"id":"sec-work","name":"Work"}}""")!.AsObject(), Name)!;
        Assert.Equal("sec-work", p2["sectionId"]!.GetValue<string>());
        Assert.False(p2["pinnedFrom"]!.GetValue<bool>());
        // not pinned, in Pinned by hand → treated as a pin
        var p3 = PinnedSection.PinnedSectionPatch(JsonNode.Parse("""{"sectionId":"hermes-hq-pinned"}""")!.AsObject(), Name)!;
        Assert.True(p3["pinned"]!.GetValue<bool>());
        // agreeing meta → nothing
        Assert.Null(PinnedSection.PinnedSectionPatch(JsonNode.Parse("""{"pinned":false}""")!.AsObject(), Name));
        // pin from no section
        var pin = PinnedSection.PinPatch(new JsonObject(), true, Name);
        Assert.True(pin.ContainsKey("pinnedFrom") && pin["pinnedFrom"] is null);
        // undo of a patch puts back what it replaced (pinnedFrom → false when absent)
        var undo = PinnedSection.UndoOf(JsonNode.Parse("""{"pinned":false}""")!.AsObject(), pin);
        Assert.False(undo["pinned"]!.GetValue<bool>());
        Assert.False(undo["pinnedFrom"]!.GetValue<bool>());
    }

    [Fact]
    public void UnreadDotsFollowActivity()
    {
        static RosterProfile Row(double at, long count = 4) => RosterProfile.From(JsonNode.Parse(
            "{\"name\":\"ivy\",\"canonical_session\":{\"id\":\"c1\",\"resolved_id\":\"c2\",\"last_active\":" + at + ",\"message_count\":" + count + "}}"))!;
        var state = new BotUnreadState();
        state.Reconcile([Row(100)], _ => false);
        Assert.False(state.IsUnread(Row(100)));           // first sight records the baseline only
        state.Reconcile([Row(200)], _ => false);
        Assert.True(state.IsUnread(Row(200)));
        Assert.False(state.IsUnread(Row(200, 0)));        // an empty chat is "untouched"
        state.Reconcile([Row(300)], _ => true);            // on screen: read
        Assert.False(state.IsUnread(Row(300)));
        state.Mark(Row(300));
        Assert.Equal(["c1"], state.Markers["ivy"]);
        state.Acknowledge(Row(300));
        Assert.False(state.IsMarked(Row(300)));
    }

    [Fact]
    public void NewBotNamesAndDuplicates()
    {
        Assert.Equal(("cafe-bot", "Café Bot"), BotIdentity.ProfileIdentity("Café Bot", ""));
        Assert.Equal(("ivy", ""), BotIdentity.ProfileIdentity("Ivy", ""));
        Assert.Equal("u65e5-u672c", BotIdentity.ProfileIdentity("日本", "").Slug);
        Assert.Equal("日本", BotIdentity.ProfileIdentity("日本", "").Title);
        Assert.True(BotIdentity.IsValidProfileId("ivy-2"));
        Assert.False(BotIdentity.IsValidProfileId("-ivy"));
        Assert.Equal("ivy-3", BotIdentity.DuplicateName("ivy", new HashSet<string> { "ivy", "ivy-2" }));
        var meta = BotIdentity.DuplicateMeta(JsonNode.Parse("""{"title":"Ivy","created":1,"chat":"x","pinned":true}""")!.AsObject());
        Assert.Equal("Ivy (copy)", meta["title"]!.GetValue<string>());
        Assert.False(meta.ContainsKey("created") || meta.ContainsKey("chat"));
        Assert.Matches("^sec-[0-9a-z]+-[0-9a-z]{5}$", BotIdentity.NewSectionId());
        Assert.Equal("Research — Finds papers", BotIdentity.DescriptionText("Research", "Finds papers "));
        Assert.StartsWith("# Ivy\n", BotIdentity.ComposeSoul("ivy", "", "", true));
    }

    [Fact]
    public void SectionNamesThatReadAsHeadingsAreRefused()
    {
        Assert.Equal("“Hidden” is already a heading in the Bots list. Choose another name.", BotList.SectionNameProblem("hidden", []));
        Assert.Equal("There’s already a section named “Work”.", BotList.SectionNameProblem("work", ["Work"]));
        Assert.Null(BotList.SectionNameProblem("Clients", ["Work"]));
        Assert.Equal("Its 3 bots move to Unassigned.", BotList.DeleteSectionMessage(3));
        Assert.Null(BotList.DeleteSectionMessage(0));
    }

    [Fact]
    public void ListTimeReadsLikeTheMac()
    {
        var utc = TimeZoneInfo.Utc;
        var now = new DateTimeOffset(2026, 11, 21, 18, 0, 0, TimeSpan.Zero);
        double S(DateTimeOffset d) => d.ToUnixTimeSeconds();
        Assert.Equal("9:05 AM", ListTime.Format(S(new DateTimeOffset(2026, 11, 21, 9, 5, 0, TimeSpan.Zero)), now, utc));
        Assert.Equal("Yesterday", ListTime.Format(S(now.AddDays(-1)), now, utc));
        Assert.Equal("Tue", ListTime.Format(S(new DateTimeOffset(2026, 11, 17, 9, 0, 0, TimeSpan.Zero)), now, utc));
        Assert.Equal("Aug 7", ListTime.Format(S(new DateTimeOffset(2026, 8, 7, 9, 0, 0, TimeSpan.Zero)), now, utc));
        Assert.Equal("Aug 7, 2025", ListTime.Format(S(new DateTimeOffset(2025, 8, 7, 9, 0, 0, TimeSpan.Zero)), now, utc));
        Assert.Equal("", ListTime.Format(0, now, utc));
    }

    [Fact]
    public void MuteWords()
    {
        var now = new DateTimeOffset(2026, 11, 21, 18, 0, 0, TimeSpan.Zero);
        Assert.Equal("Off", BotMutes.Value(null, now));
        Assert.Equal("Always", BotMutes.Value(BotMute.Forever, now));
        Assert.Equal("Until 7:00 PM", BotMutes.Value(BotMutes.Mute(MuteChoice.Hour, now), now, TimeZoneInfo.Utc));
        Assert.Equal("Until Sat, Nov 28", BotMutes.Value(BotMutes.Mute(MuteChoice.Week, now), now, TimeZoneInfo.Utc));
        Assert.Equal(["Off", "For 1 Hour", "For 8 Hours", "For 1 Week", "Always"], Enum.GetValues<MuteChoice>().Select(BotMutes.Title));
        Assert.False(BotMutes.Mute(MuteChoice.Hour, now)!.Live(now.AddHours(2)));
    }

    [Fact]
    public void SecondLineRanksTheBotsState()
    {
        var p = RosterProfile.From(JsonNode.Parse("""{"name":"ivy"}"""))!;
        var b = new BotRow { Id = "ivy", Name = "Ivy", Profile = p, Model = p.ToModel("Ivy", new BotMeta()), Role = "Research" };
        Assert.Equal("Research", BotList.SecondLine(b).Text);
        Assert.Equal("Working…", BotList.SecondLine(b with { IsWorking = true }).Text);
        Assert.Equal("Reading package.json…", BotList.SecondLine(b with { IsWorking = true, Step = "Reading package.json…" }).Text);
        Assert.Equal(BotList.Tone.Attention, BotList.SecondLine(b with { NeedsInput = "Waiting for you", IsWorking = true }).Tone);
        Assert.Equal("Waking up…", BotList.SecondLine(b with { Waking = true }).Text);
        Assert.Equal("Ivy. Research. 9:05 AM. Unread. Pinned", BotList.AccessibilityLabel(b with { Unread = true, Pinned = true }, "9:05 AM"));
    }
}

public class BotStoreTests
{
    private static JsonNode Roster() => Fixture.Load("demo-profiles-list.json") is var j && j["result"] is { } r ? r : j;

    private static (BotStore Store, FakeGateway Gw) Make(Func<string, JsonObject, JsonNode?>? onCall = null)
    {
        var gw = new FakeGateway();
        var roster = Roster();
        gw.OnCall = (m, p) =>
        {
            if (m == "profiles.list") lock (roster) return roster.DeepClone();
            var answer = onCall?.Invoke(m, p);
            // The gateway keeps an applied meta write, as Hermes does.
            if (m == "profiles.configure" && answer?["applied"]?["ui_meta"]?.GetValue<bool>() == true
                && p["ui_meta"]?["hermes-bots"] is JsonObject written)
                lock (roster)
                    if ((roster["profiles"] as JsonArray)!.FirstOrDefault(r => r!["name"]!.GetValue<string>() == p["name"]!.GetValue<string>()) is JsonObject row)
                    {
                        if (row["ui_meta"] is not JsonObject ui) row["ui_meta"] = ui = new JsonObject();
                        ui["hermes-bots"] = written.DeepClone();
                    }
            return answer;
        };
        var store = new BotStore(gw, new MemoryDeviceStore());
        store.ApplyFull(roster, DateTimeOffset.UtcNow);
        return (store, gw);
    }

    [Fact]
    public async Task PinSendsTheWholeMergedMeta()
    {
        var (store, gw) = Make((m, _) => m == "profiles.configure"
            ? JsonNode.Parse("""{"ok":true,"applied":{"ui_meta":true,"ui_meta_revisions":{"hermes-bots":3}}}""") : null);
        await store.SetPinnedAsync("inbox", "Inbox", true);
        var (_, p) = gw.Calls.Last(c => c.Method == "profiles.configure");
        Assert.Equal("inbox", p["name"]!.GetValue<string>());
        var meta = p["ui_meta"]!["hermes-bots"]!;
        Assert.True(meta["pinned"]!.GetValue<bool>());
        Assert.Equal("hermes-hq-pinned", meta["sectionId"]!.GetValue<string>());
        Assert.Equal("sec-work", meta["pinnedFrom"]!["id"]!.GetValue<string>());
        Assert.Equal("Inbox", meta["title"]!.GetValue<string>());          // the whole object, not the patch
        Assert.Contains(store.Layout.Tiles, b => b.Id == "inbox");
    }

    [Fact]
    public async Task ARefusedWriteRollsBack()
    {
        // The undo write runs after the refusal is thrown, on its own task: this scenario waits for that second
        // configure call itself instead of guessing how long the thread pool takes to start it.
        var configures = 0;
        var undoSent = new TaskCompletionSource<JsonObject>(TaskCreationOptions.RunContinuationsAsynchronously);
        var (store, gw) = Make((m, p) =>
        {
            if (m != "profiles.configure") return null;
            if (Interlocked.Increment(ref configures) == 2) undoSent.TrySetResult((JsonObject)p.DeepClone());
            return JsonNode.Parse("""{"ok":false,"applied":{"ui_meta":false}}""");
        });
        var before = (JsonObject)store.Bot("inbox")!.Profile.ServerMeta!.DeepClone();
        var e = await Assert.ThrowsAsync<BotWriteException>(() => store.SetHiddenAsync("inbox", "Inbox", true));
        Assert.Equal("Couldn’t Hide Inbox", e.Title);
        Assert.Equal(BotWriteException.NotSavedReason, e.Reason);
        Assert.False(store.Bot("inbox")!.Hidden);

        var undo = await undoSent.Task.WaitAsync(TimeSpan.FromSeconds(30));  // a bound for a lost undo, not a wait
        Assert.Equal("inbox", undo["name"]!.GetValue<string>());
        var sent = undo["ui_meta"]!["hermes-bots"]!.AsObject();
        Assert.False(sent["hidden"]!.GetValue<bool>());                        // the refused hide, taken back
        foreach (var (k, v) in before)
            if (k is not ("hidden" or "image" or "pet" or "chat"))
                Assert.True(JsonNode.DeepEquals(v, sent[k]), $"undo changed {k}");
        Assert.DoesNotContain("image", sent.Select(kv => kv.Key));
        Assert.DoesNotContain("pet", sent.Select(kv => kv.Key));

        var calls = gw.Calls.Select(c => c.Method).ToList();
        Assert.Equal(["profiles.list", "profiles.configure", "profiles.configure"], calls);
        Assert.True(gw.Calls[1].Params["ui_meta"]!["hermes-bots"]!["hidden"]!.GetValue<bool>());
        Assert.False(store.Bot("inbox")!.Hidden);                             // the rollback holds after the undo
    }

    [Fact]
    public async Task AnOlderGatewayIsSaidPlainly()
    {
        var (store, _) = Make((m, _) => m == "profiles.configure" ? JsonNode.Parse("""{"ok":true}""") : null);
        var e = await Assert.ThrowsAsync<BotWriteException>(() => store.MoveAsync("inbox", "Inbox", null));
        Assert.Equal(BotWriteException.UnsupportedReason, e.Reason);
    }

    [Fact]
    public async Task SectionsAreMadeRenamedMovedAndDeletedWithUndo()
    {
        var (store, gw) = Make((m, _) => m == "profiles.configure" ? JsonNode.Parse("""{"applied":{"ui_meta":true}}""") : null);
        var clients = store.AppendSection("  Clients ");
        Assert.Equal("Clients", clients.Name);
        await store.MoveAsync("inbox", "Inbox", clients.Id);
        Assert.Equal("Clients", store.Bot("inbox")!.SectionName);
        Assert.True(store.CanMoveSection(clients.Id, -1));
        store.MoveSection(clients.Id, -1);
        Assert.Equal(clients.Id, store.Device.Sections[1].Id);
        await store.RenameSectionAsync(clients.Id, "Customers");
        Assert.Equal("Customers", store.Bot("inbox")!.SectionName);
        var deletion = store.BeginDeleteSection(clients.Id)!;
        Assert.Equal(["inbox"], deletion.Members);
        Assert.DoesNotContain(store.Device.Sections, s => s.Id == clients.Id);
        store.UndoDeleteSection(deletion);
        Assert.Contains(store.Device.Sections, s => s.Id == clients.Id);
        var again = store.BeginDeleteSection(clients.Id)!;
        await store.FinishDeleteSectionAsync(again);
        Assert.Null(store.Bot("inbox")!.SectionName);
        Assert.True(gw.Calls.Count(c => c.Method == "profiles.configure") >= 3);
    }

    [Fact]
    public async Task EditBotSavesTitleAndDescriptionInOneCall()
    {
        var (store, gw) = Make((m, _) => m == "profiles.configure"
            ? JsonNode.Parse("""{"applied":{"ui_meta":true,"description":true}}""") : null);
        var outcome = await store.SaveEditAsync("inbox", "Mailroom", "Sorts the post");
        Assert.True(outcome.Succeeded);
        var (_, p) = gw.Calls.Last(c => c.Method == "profiles.configure");
        Assert.Equal("Sorts the post", p["description"]!.GetValue<string>());
        Assert.Equal("Mailroom", p["ui_meta"]!["hermes-bots"]!["title"]!.GetValue<string>());
        Assert.Equal("Mailroom", store.Bot("inbox")!.Name);
    }

    [Fact]
    public async Task NewBotCreatesWritesChecksAndMints()
    {
        var (store, gw) = Make((m, _) => m switch
        {
            "profiles.create" => JsonNode.Parse("""{"ok":true}"""),
            "profiles.configure" => JsonNode.Parse("""{"applied":{"ui_meta":true}}"""),
            "setup.runtime_check" => JsonNode.Parse("""{"ok":false}"""),
            "session.list" => JsonNode.Parse("""{"sessions":[]}"""),
            "session.create" => JsonNode.Parse("""{"session_id":"rt1","stored_session_id":"st1"}"""),
            "session.title" => JsonNode.Parse("""{"title":"Bot Chat"}"""),
            _ => null,
        });
        var made = await store.CreateBotAsync("Scout", "", "Finds things");
        Assert.Equal("scout", made.Name);
        Assert.True(made.NeedsModel);
        var create = gw.Calls.First(c => c.Method == "profiles.create").Params;
        Assert.Equal("default", create["clone_from"]!.GetValue<string>());
        Assert.True(create["share_auth"]!.GetValue<bool>());
        Assert.Equal("Finds things", create["description"]!.GetValue<string>());
        Assert.Contains(gw.Calls, c => c.Method == "session.create" && c.Params["hidden"]!.GetValue<bool>());
        Assert.Equal("st1", store.Bot("scout")!.OpenId);
    }

    [Fact]
    public async Task DuplicateAndDelete()
    {
        var (store, gw) = Make((m, _) => m switch
        {
            "profiles.create" => JsonNode.Parse("""{"ok":true}"""),
            "profiles.configure" => JsonNode.Parse("""{"applied":{"ui_meta":true}}"""),
            _ => null,
        });
        gw.OnRest = (method, path, _, _) => method == "DELETE" && path == "/api/profiles/inbox" ? new RestAnswer(200, "{}") : null;
        var name = await store.DuplicateAsync("inbox", "Inbox");
        Assert.Equal("inbox-2", name);
        Assert.Equal("Inbox (copy)", store.Bot("inbox-2")!.Name);
        await store.DeleteAsync("inbox", "Inbox");
        Assert.Null(store.Bot("inbox"));
        var e = await Assert.ThrowsAsync<BotWriteException>(() => store.DeleteAsync("default", "Hermes"));
        Assert.Equal("The default profile cannot be deleted.", e.Reason);
    }

    [Fact]
    public void LiveWorkAndMuteShowOnTheRow()
    {
        var (store, _) = Make();
        var canonical = store.Bot("inbox")!.Profile.CanonicalIds[0];
        store.SetLive(new HashSet<string> { canonical }, new HashSet<string>());
        Assert.True(store.Bot("inbox")!.IsWorking);
        store.SetLive(new HashSet<string> { canonical }, new HashSet<string> { canonical });
        Assert.Equal("Waiting for you", BotList.SecondLine(store.Bot("inbox")!).Text);
        var now = DateTimeOffset.UtcNow;
        store.SetMute("inbox", MuteChoice.Hours8, now);
        Assert.NotNull(store.MuteOf("inbox", now));
        Assert.Null(store.MuteOf("inbox", now.AddHours(9)));
        store.MarkUnread("inbox");
        Assert.True(store.Bot("inbox")!.Unread);
        store.MarkRead("inbox");
        Assert.False(store.Bot("inbox")!.Unread);
    }

    [Fact]
    public void DeviceStateSurvivesARelaunch()
    {
        var disk = new MemoryDeviceStore();
        var gw = new FakeGateway();
        var first = new BotStore(gw, disk);
        first.ApplyFull(Roster(), DateTimeOffset.UtcNow);
        first.SetCollapsed("user:sec-home", true);
        var again = new BotStore(gw, disk);
        Assert.True(again.HasRoster);
        Assert.Equal(9, again.Rows.Count);
        Assert.Contains("user:sec-home", again.Device.Collapsed);
    }

    [Fact]
    public async Task TheBotChatComesFromTheRosterOrTheRegistry()
    {
        var (store, gw) = Make((m, _) => m == "session.list" ? Fixture.Load("demo-session-list-bot-chat.json") is var j && j["result"] is { } r ? r : j : null);
        var known = store.Bot("inbox")!.OpenId!;
        Assert.Equal(known, await store.BotChatIdAsync("inbox"));
        Assert.DoesNotContain(gw.Calls, c => c.Method == "session.list");
    }
}
