using System.Text.Json.Nodes;
using Hermes.Core.Bots;
using Hermes.Core.Chat;
using Hermes.Core.Groups;
using Hermes.Core.Model;
using Hermes.Core.Rpc;
using Hermes.Core.Sessions;
using Hermes.Core.Settings;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Tests;

public class ThreadsBotExchangesAndFallbackTests
{
    private static ChatMessage Msg(string id, Role role, string text, DateTimeOffset? at = null, long? rowId = null,
        bool streaming = false, string? error = null, ChatSender? sender = null, bool replyToOurDm = false,
        string? job = null, DateTimeOffset? latest = null, IReadOnlyList<ChatPart>? extraParts = null)
    {
        var parts = new List<ChatPart>();
        if (extraParts != null) parts.AddRange(extraParts);
        if (text.Length > 0) parts.Add(new TextPart(text));
        return new ChatMessage(id, role, parts, at, rowId, IsStreaming: streaming, Error: error, LatestTimestamp: latest)
        {
            Sender = sender,
            ReplyToOurDM = replyToOurDm,
            Job = job,
        };
    }

    // ------------------------------------------------------------------ 1. Session Threads & ThreadStore

    [Fact]
    public void ThreadRules_ComposerAnchor_HasNewFinishedReply_Unanchored_And_ShortTitle()
    {
        var t0 = DateTimeOffset.Parse("2026-11-28T10:00:00Z");
        var u1 = Msg("u1", Role.User, "Check the deploy status", t0, rowId: 10);
        var aStreaming = Msg("a1", Role.Assistant, "Checking…", t0.AddSeconds(2), rowId: 11, streaming: true);
        var aDone = Msg("a2", Role.Assistant, "All green.", t0.AddSeconds(5), rowId: 12);

        // Skips streaming reply so a composer thread anchors under the user's request.
        Assert.Equal("u1", ThreadRules.ComposerAnchor([u1, aStreaming], running: true)?.Id);
        // Once finished, anchors under the finished reply.
        Assert.Equal("a2", ThreadRules.ComposerAnchor([u1, aDone], running: false)?.Id);

        // HasNewFinishedReply detects newly landed finished assistant reply.
        Assert.False(ThreadRules.HasNewFinishedReply([u1], [u1, aStreaming]));
        Assert.True(ThreadRules.HasNewFinishedReply([u1], [u1, aDone]));
        Assert.False(ThreadRules.HasNewFinishedReply([u1, aDone], [u1, aDone]));
        Assert.True(ThreadRules.HasNewFinishedReply([u1, aDone], [u1, aDone, Msg("a3", Role.Assistant, "Follow-up", t0.AddSeconds(10), rowId: 15)]));

        // Unanchored threads appear only on empty (no non-system) chats.
        var unanchored = new ChatThread("t-1", "s-1", null, t0, null, null, [], Running: true);
        var anchored = new ChatThread("t-2", "s-2", "Deploy", t0.AddSeconds(1), "u1", 10, [], Running: false);
        Assert.Single(ThreadRules.Unanchored([unanchored, anchored], []));
        Assert.Empty(ThreadRules.Unanchored([unanchored, anchored], [u1]));

        // ShortTitle.IsPlaceholder & ThreadRules.Name reject gateway-cut excerpts and inherited "Bot Chat #N".
        const string first = "Can you compare the deployment logs from staging and production across all clusters?";
        Assert.True(ShortTitle.IsPlaceholder("New Chat", first));
        Assert.True(ShortTitle.IsPlaceholder("Can you compare the deployment logs...", first));
        Assert.True(ShortTitle.IsPlaceholder("MEDIA:\"/tmp/voice.m4a\"", first));
        Assert.False(ShortTitle.IsPlaceholder("Staging vs production logs", first));

        var placeholderThread = new ChatThread("t-p", "s-p", "Can you compare the deployment logs…", t0, "u1", 10,
            [Msg("tu1", Role.User, first, t0)], Running: false);
        Assert.Equal(ThreadRules.DefaultTitle, ThreadRules.Name(placeholderThread));

        var inheritedThread = placeholderThread with { Title = "Bot Chat #2" };
        Assert.Equal(ThreadRules.DefaultTitle, ThreadRules.Name(inheritedThread));

        var namedThread = placeholderThread with { Title = "Deploy Logs" };
        Assert.Equal("Deploy Logs", ThreadRules.Name(namedThread));
        Assert.Equal("1 message", ThreadRules.FoldedTail(namedThread));

        // ProactiveBanner with OwnerWait reason.
        var banner = ThreadRules.ProactiveBanner("Scout", null, null, OwnerWait.MessagingTurn("Telegram"));
        Assert.Equal("Sending to Thread", banner.Title);
        Assert.Equal("Busy with a Telegram message", banner.Note);
        var continuing = ThreadRules.ProactiveBanner("Scout", "Deploy Logs", "t-1", OwnerWait.RunningReply);
        Assert.Equal("Replying in Thread", continuing.Title);
        Assert.Equal("Continuing “Deploy Logs”", continuing.Note);
    }

    [Fact]
    public void ThreadFetch_ReadsHiddenSeedAndHealsLegacySeedBranchRow()
    {
        var anchorText = ThreadSeed.ClosingNote(running: true, anchorRow: 42, busyReason: "a background task");
        var hiddenRows = new JsonNode?[]
        {
            new JsonObject { ["id"] = 1, ["role"] = "user", ["content"] = "Earlier main prompt", ["display_kind"] = "hidden" },
            new JsonObject { ["id"] = 2, ["role"] = "assistant", ["content"] = anchorText, ["display_kind"] = "hidden" },
            new JsonObject { ["id"] = 3, ["role"] = "user", ["content"] = "Quick side question" },
            new JsonObject { ["id"] = 4, ["role"] = "assistant", ["content"] = "Quick side answer" },
        };
        var read = ThreadFetch.Read(hiddenRows);
        Assert.Equal(42, read.AnchorRow);
        Assert.Equal(2, read.Messages.Count);
        Assert.Equal("Quick side question", read.Messages[0].Text);

        // Legacy gateway stripped `display_kind: "hidden"` via `_seed_branch_row`: closing note trims leaked prefix.
        var leakedRows = new JsonNode?[]
        {
            new JsonObject { ["id"] = 1, ["role"] = "user", ["content"] = "Leaked main prompt" },
            new JsonObject { ["id"] = 2, ["role"] = "assistant", ["content"] = anchorText },
            new JsonObject { ["id"] = 3, ["role"] = "user", ["content"] = "Actual thread message" },
        };
        var healed = ThreadFetch.Read(leakedRows);
        Assert.Equal(42, healed.AnchorRow);
        Assert.Single(healed.Messages);
        Assert.Equal("Actual thread message", healed.Messages[0].Text);
    }

    [Fact]
    public void ThreadStore_PersistsLinks_FiltersThreadSessions_AndFormatsContextNote()
    {
        var disk = new MemoryDeviceStore();
        var store = new ThreadStore("acct-1", disk);
        store.RecordBotThread(new BotThreadLink("thr-1", "scout", "bot-main", 1700000100, AnchorRow: 12));

        // Reload from persistent IDeviceStore.
        var reloaded = new ThreadStore("acct-1", disk);
        Assert.Single(reloaded.Links);
        Assert.Equal("thr-1", reloaded.Links[0].StoredId);
        Assert.Equal(12, reloaded.Links[0].AnchorRow);

        // Thread-session filtering hides linked threads and legacy parent_session_id children of canonical chats.
        var rows = new[]
        {
            new SidebarSessionRow { Id = "thr-1", Profile = "scout", Title = "Side thread" },
            new SidebarSessionRow { Id = "thr-legacy", Profile = "scout", ParentSessionId = "bot-main", Title = "Bot Chat #2" },
            new SidebarSessionRow { Id = "sess-regular", Profile = "scout", Title = "Regular chat" },
        };
        var filtered = reloaded.FilterOutThreads(rows, new Dictionary<string, string> { ["scout"] = "bot-main" });
        Assert.Single(filtered);
        Assert.Equal("sess-regular", filtered[0].Id);

        // ThreadContextNote formatting and stripping.
        var note = ThreadContextNote.Format([("Deploy Logs", [
            Msg("u1", Role.User, "Should we roll back?"),
            Msg("a1", Role.Assistant, "No, latency recovered."),
        ])]);
        Assert.NotNull(note);
        Assert.Contains("Thread “Deploy Logs”:", note);
        var combined = ThreadContextNote.Appended("Continue the release.", note!);
        Assert.True(ThreadContextNote.HasNote(combined));
        Assert.Equal("Continue the release.", ThreadContextNote.Stripped(combined));
    }

    // ------------------------------------------------------------------ 2. BotDMs & HistoryFold

    [Fact]
    public void BotDMs_ParsesDeliveries_SpeaksTo_IsInternalAck_AndResolves()
    {
        var roster = new List<DeliveryMessages.Seat>
        {
            new("otto", "Otto", null),
            new("default", "Hermes", null),
        };

        var runnerNote =
            "[IMPORTANT: Background process proc_9 completed normally (exit code 0).\n" +
            "Command: /usr/bin/python3 /opt/hermes/tools/bot_mode_dm.py --run-delivery peer dm otto\n" +
            "Output:\n{\"reply\": \"Checked the logs, all clear.\", \"status\": \"settled\"}\n]";

        Assert.True(BotDMs.IsDelivery(runnerNote));
        Assert.Equal("otto", BotDMs.Target(runnerNote));
        var outcome = BotDMs.OutcomeOf(runnerNote);
        Assert.Equal(BotDMs.OutcomeKind.Replied, outcome.Kind);
        Assert.Equal("Checked the logs, all clear.", outcome.Text);

        // Silent stand-in / empty-turn placeholder become Delivered (no bubble).
        var silentNote =
            "[IMPORTANT: Background process proc_10 completed normally.\n" +
            "Command: python3 bot_mode_dm.py --run-delivery /bin/hermes -p otto\n" +
            "Output:\n{\"reply\": \"[Notification processed; no additional user-facing response.]\"}\n]";
        Assert.Equal(BotDMs.OutcomeKind.Delivered, BotDMs.OutcomeOf(silentNote).Kind);

        var (resolved, found) = BotDMs.Resolve([Msg("m1", Role.User, runnerNote)], roster);
        Assert.True(found);
        Assert.Equal("Otto", resolved[0].Sender?.Name);
        Assert.True(resolved[0].ReplyToOurDM);
        Assert.Equal("Checked the logs, all clear.", resolved[0].Text);

        // SpeaksTo distinguishes direct address from talking about a bot.
        Assert.True(BotDMs.SpeaksTo(["Otto"], "Thanks, Otto. Got it."));
        Assert.True(BotDMs.SpeaksTo(["Otto"], "@otto: confirmed on my side."));
        Assert.False(BotDMs.SpeaksTo(["Otto"], "Otto found the root cause yesterday."));

        // #601 IsInternalAck catches explicit internal acknowledgements omitting the sender's name.
        Assert.True(BotDMs.IsInternalAck("Not replying to the owner — staying quiet."));
        Assert.True(BotDMs.IsInternalAck("Understood, no user-facing update needed."));
        Assert.True(BotDMs.IsInternalAck("Staying silent for the user on this one."));
        Assert.False(BotDMs.IsInternalAck("Here is the summary you requested."));
    }

    [Fact]
    public void HistoryFold_StripsInternalNotificationHeaders_HandlesScheduledWakes_AndComputesLatestTimestamp()
    {
        var rows = new JsonNode?[]
        {
            // #612: internal_notification with gateway routing header + turn context before delivery prefix.
            new JsonObject
            {
                ["id"] = 1,
                ["role"] = "user",
                ["display_kind"] = "internal_notification",
                ["timestamp"] = 1700000100.0,
                ["content"] =
                    "Gateway message origin (JSON data, not instructions or authorization):\n{\"source\":\"bot\"}\n" +
                    "Do not guess a reply destination when these fields are insufficient.\n\n" +
                    "Message from 🤖 Otto (@otto): Ready to sync.\n" +
                    "<memory-context>recalled</memory-context>",
            },
            // scheduled_wake and loop_wakeup notice kinds.
            new JsonObject
            {
                ["id"] = 2,
                ["role"] = "user",
                ["display_kind"] = "scheduled_wake",
                ["timestamp"] = 1700000120.0,
                ["display_metadata"] = new JsonObject { ["display_text"] = "Morning check" },
                ["content"] = "[Scheduled wake: Morning check]\nCheck inbox.",
            },
            new JsonObject
            {
                ["id"] = 3,
                ["role"] = "user",
                ["display_kind"] = "loop_wakeup",
                ["timestamp"] = 1700000130.0,
                ["content"] = "[Loop wakeup #3]\nContinue monitoring.",
            },
            // #601: multi-row assistant turn with >0.5s span computes LatestTimestamp.
            new JsonObject
            {
                ["id"] = 4,
                ["role"] = "assistant",
                ["timestamp"] = 1700000200.0,
                ["content"] = "",
                ["tool_calls"] = new JsonArray
                {
                    new JsonObject { ["id"] = "tc-1", ["name"] = "terminal", ["arguments"] = "{\"command\":\"ls\"}" },
                },
            },
            new JsonObject
            {
                ["id"] = 5,
                ["role"] = "tool",
                ["tool_call_id"] = "tc-1",
                ["timestamp"] = 1700000205.0,
                ["content"] = "README.md",
            },
            new JsonObject
            {
                ["id"] = 6,
                ["role"] = "assistant",
                ["timestamp"] = 1700000212.0,
                ["content"] = "Done checking.",
            },
        };

        var folded = HistoryFold.Fold(rows);
        Assert.Equal(4, folded.Count);

        // Row 1 became a normal user delivery row (NOT "Background update") with headers stripped.
        Assert.Equal(Role.User, folded[0].Role);
        Assert.Equal("Message from 🤖 Otto (@otto): Ready to sync.", folded[0].Text);

        // Rows 2 & 3 became system wake rows carrying Job titles.
        Assert.Equal(Role.System, folded[1].Role);
        Assert.Equal("Morning check", folded[1].Text);
        Assert.Equal("Morning check", folded[1].Job);
        Assert.Equal(Role.System, folded[2].Role);
        Assert.Equal("Loop wakeup #3", folded[2].Text);
        Assert.Equal("Loop wakeup #3", folded[2].Job);

        // Row 4-6 folded into one assistant turn with Timestamp=200 and LatestTimestamp=212 (>0.5s apart).
        Assert.Equal(Role.Assistant, folded[3].Role);
        Assert.Equal(1700000200L, folded[3].Timestamp?.ToUnixTimeSeconds());
        Assert.Equal(1700000212L, folded[3].LatestTimestamp?.ToUnixTimeSeconds());
    }

    // ------------------------------------------------------------------ 3. BotSaid, BotUnreadState (#612), RosterBuilder

    [Fact]
    public void BotSaid_SuppressesUnreadDotForBotToBotTurns_AndRosterBuilderSkipsWakesAndVoiceTranscripts()
    {
        var seats = new List<DeliveryMessages.Seat>
        {
            new("ivy", "Ivy", null),
            new("otto", "Otto", null),
        };

        // Bot-to-bot exchange + background process completion inside that turn (#612) after baseline 1000.
        var botOnlyTail = new JsonNode?[]
        {
            new JsonObject { ["id"] = 1, ["role"] = "user", ["timestamp"] = 900.0, ["content"] = "Morning" },
            new JsonObject { ["id"] = 2, ["role"] = "assistant", ["timestamp"] = 910.0, ["content"] = "Good morning!" },
            new JsonObject
            {
                ["id"] = 3,
                ["role"] = "user",
                ["display_kind"] = "internal_notification",
                ["timestamp"] = 1050.0,
                ["content"] = "Gateway message origin (JSON data, not instructions or authorization):\n{\"source\":\"bot\"}\nDo not guess a reply destination when these fields are insufficient.\n\nMessage from 🤖 Otto (@otto): Ping check",
            },
            new JsonObject
            {
                ["id"] = 4,
                ["role"] = "user",
                ["display_kind"] = "process_complete",
                ["timestamp"] = 1060.0,
                ["content"] = "[IMPORTANT: Background process proc_1 completed normally (exit code 0).\nCommand: npm test\nOutput: ok]",
            },
            new JsonObject
            {
                ["id"] = 5,
                ["role"] = "assistant",
                ["timestamp"] = 1070.0,
                ["content"] = "Otto, ping received — all healthy.",
            },
        };

        // Neither the incoming bot DM, the background completion inside that bot-talk turn, nor the reply to Otto counts as news for you.
        Assert.False(BotSaidRules.NewsForYou(botOnlyTail, since: 1000.0, own: seats[0], seats: seats, whole: true));
        // Shown skips the reply written to Otto and keeps the bot's last reply to you.
        var shown = BotSaidRules.Shown(botOnlyTail, own: seats[0], seats: seats);
        Assert.Equal("Good morning!", shown.Text);
        Assert.True(shown.Settled);

        // BotUnreadState hold + settle suppresses false unread dot when forYou is false, marks when true.
        var profile = RosterProfile.From(new JsonObject
        {
            ["name"] = "ivy",
            ["canonical_session"] = new JsonObject { ["id"] = "s-ivy", ["last_active"] = 1000.0, ["message_count"] = 2, ["preview"] = "Good morning!" },
        })!;
        var unread = new BotUnreadState();
        unread.Reconcile([profile], _ => false, holdForCheck: true); // first sight: baseline only
        Assert.False(unread.IsUnread(profile));

        var moved = RosterProfile.From(new JsonObject
        {
            ["name"] = "ivy",
            ["canonical_session"] = new JsonObject { ["id"] = "s-ivy", ["last_active"] = 1070.0, ["message_count"] = 5, ["preview"] = "Otto, ping received" },
        })!;
        unread.Reconcile([moved], _ => false, holdForCheck: true);
        Assert.Equal(1000.0, unread.HeldSince("ivy"));
        Assert.False(unread.IsUnread(moved));

        unread.Settle(moved, forYou: false);
        Assert.Null(unread.HeldSince("ivy"));
        Assert.False(unread.IsUnread(moved));

        // RosterBuilder skips scheduled wake and [Voice chat transcript previews.
        var wakeProfile = RosterProfile.From(new JsonObject
        {
            ["name"] = "cronbot",
            ["description"] = "Ops helper",
            ["canonical_session"] = new JsonObject { ["id"] = "s-cron", ["last_active"] = 1100.0, ["message_count"] = 3, ["preview"] = "[Scheduled wake: Daily check]\nRun diagnostics" },
        })!;
        var voiceProfile = RosterProfile.From(new JsonObject
        {
            ["name"] = "voicebot",
            ["description"] = "Voice assistant",
            ["canonical_session"] = new JsonObject { ["id"] = "s-voice", ["last_active"] = 1100.0, ["message_count"] = 3, ["preview"] = "[Voice chat transcript · 1:15]\nUser: hello" },
        })!;
        var layout = RosterBuilder.Build(new RosterBuilder.Input { Profiles = [wakeProfile, voiceProfile] });
        var cronRow = layout.Flat.First(r => r.Id == "cronbot");
        var voiceRow = layout.Flat.First(r => r.Id == "voicebot");
        Assert.True(cronRow.Preview.IsFallback);
        Assert.Equal("Ops helper", cronRow.Preview.Text);
        Assert.True(voiceRow.Preview.IsFallback);
        Assert.Equal("Voice assistant", voiceRow.Preview.Text);

        // BotStore NoteBotSaid + WithBotSaid override roster preview.
        var gw = new FakeGateway();
        var store = new BotStore(gw, new MemoryDeviceStore());
        Assert.True(store.NoteBotSaid("ivy", "s-ivy", "Fresh answer for you", 1200.0, serverTime: true));
        var overlaid = store.WithBotSaid([moved]);
        Assert.Equal("Fresh answer for you", overlaid[0].CanonicalSession?.Preview);
        Assert.Equal(1200.0, overlaid[0].CanonicalSession?.LastActive);
    }

    // ------------------------------------------------------------------ 4. UpdateGroups Folding

    [Fact]
    public void UpdateGroups_FoldsBotExchange_ExcludesVoiceTranscript_AndUsesLatestTimestamp()
    {
        var t0 = DateTimeOffset.Parse("2026-11-28T09:00:00Z");
        var otto = new ChatSender("delivery:otto", "Otto", null, "otto", null);
        var seats = new List<DeliveryMessages.Seat> { new("otto", "Otto", null), new("ivy", "Ivy", null) };

        Assert.True(UpdateGroups.IsVoiceTranscript("[Voice chat transcript · 2:05]\nHello"));
        Assert.True(UpdateGroups.IsVoiceTranscript("[Voice chat transcript]\nHello"));
        Assert.False(UpdateGroups.IsVoiceTranscript("Regular message"));

        var askOttoTool = new ToolPart(new ToolCall("dm1", BotDMs.Tool, "otto", null, ToolState.Done,
            ArgsJson: """{"target":"otto","message":"Can you check the build?"}"""));

        var messages = new List<ChatMessage>
        {
            Msg("u1", Role.User, "Is the release green?", t0),
            // Bot asks Otto and posts an interim note ("I've asked Otto…").
            Msg("a1", Role.Assistant, "I've asked Otto to verify.", t0.AddSeconds(5), latest: t0.AddSeconds(20), extraParts: [askOttoTool]),
            // Otto responds.
            Msg("d1", Role.User, "Build #42 passed.", t0.AddSeconds(30), sender: otto, replyToOurDm: true),
            // Final answer to the user stays ungrouped!
            Msg("a2", Role.Assistant, "Release is green — build #42 passed.", t0.AddSeconds(40)),
            // Standalone voice transcript never joins a group.
            Msg("v1", Role.User, "[Voice chat transcript · 0:42]\nQuick voice note", t0.AddMinutes(5)),
        };

        var input = new UpdateGroups.Input { Messages = messages, BotName = "Ivy", Bots = seats, Now = t0.AddMinutes(10) };
        var rows = new UpdateGroups.Rows(input);
        var plan = UpdateGroups.BuildPlan(input, existingRows: rows);

        // The interim exchange between u1 and a2 folds into "With Otto · 3 messages" (To Otto, interim reply, From Otto).
        var exchange = plan.Groups.FirstOrDefault(g => g.Members.Count > 1);
        Assert.NotNull(exchange);
        var summary = UpdateGroups.Summary(exchange!, rows);
        Assert.NotNull(summary);
        Assert.Equal("With Otto · 3 messages", summary!.Value.Line);

        // Opened sheet uses m.LatestTimestamp ?? m.Timestamp for member times.
        var opened = UpdateGroups.Opened(exchange!, rows);
        Assert.NotNull(opened);
        Assert.Equal("With Otto", opened!.Title);
        Assert.Contains(opened.Members, m => m.Time == t0.AddSeconds(20));

        // Final answer a2 is NOT interim and NOT in the group.
        Assert.False(rows.Interim(new UpdateGroups.Member(3, 0)));
        Assert.Null(plan.GroupOf(new UpdateGroups.Member(3, 0)));

        // Voice transcript stands alone (single-member group, never merged).
        var voiceGroup = plan.GroupOf(new UpdateGroups.Member(4, 0));
        Assert.NotNull(voiceGroup);
        Assert.Single(voiceGroup!.Members);
    }

    // ------------------------------------------------------------------ 5. ModelFallback & Transcript status.update

    [Fact]
    public void ModelFallback_ParsesShapes_Categories_Commands_EnvVars_AndTranscriptSurfacing()
    {
        var authLine =
            "Model fallback: claude-opus-4-6 via claude-subscription-directsdk unavailable " +
            "(HTTP 401 Invalid bearer token: run `claude auth login` or set `CLAUDE_CODE_OAUTH_TOKEN`, see `claude setup-to...`); " +
            "using openai/gpt-5.4 via openrouter.";

        var parsed = ModelFallback.Parse(authLine);
        Assert.NotNull(parsed);
        Assert.Equal("claude-opus-4-6", parsed!.Primary);
        Assert.Equal("claude-subscription-directsdk", parsed.PrimaryProvider);
        Assert.Equal("openai/gpt-5.4", parsed.Fallback);
        Assert.Equal("openrouter", parsed.FallbackProvider);
        Assert.Equal(ModelFallbackCategory.Auth, parsed.Category);
        Assert.True(parsed.IsActionable);
        Assert.Equal("HTTP 401", parsed.HttpStatus);
        Assert.Equal(["claude auth login"], parsed.ExtractedCommands); // truncated `claude setup-to...` skipped!
        Assert.Equal(["CLAUDE_CODE_OAUTH_TOKEN"], parsed.MentionedEnvVars);

        var cardRow = ModelFallbackRow.FromFallback(parsed);
        Assert.Equal(ModelFallbackRow.PresentationKind.Card, cardRow.Presentation);
        Assert.Equal("claude auth login", cardRow.Detail?.RunnableCommand);
        Assert.Equal("CLAUDE_CODE_OAUTH_TOKEN", cardRow.Detail?.PrimaryEnvVar);
        Assert.Equal("Sign-in required · HTTP 401", cardRow.Detail?.Kicker);

        // SafeTerminalCommand rejects chaining/metacharacters.
        Assert.Equal("claude auth login", ModelFallbackRow.DetailModel.SafeTerminalCommand("claude auth login"));
        Assert.Null(ModelFallbackRow.DetailModel.SafeTerminalCommand("claude auth login; rm -rf /"));
        Assert.Null(ModelFallbackRow.DetailModel.SafeTerminalCommand("claude auth login\nwhoami"));

        // Transient rate-limit pill with retryAfterSeconds.
        var rateLine = "Model fallback: anthropic/claude-sonnet-4-6 via anthropic failed (HTTP 429 rate limit exceeded); using gpt-5 via openai. Primary retry eligible in ~45s.";
        var rate = ModelFallback.Parse(rateLine)!;
        Assert.Equal(ModelFallbackCategory.RateLimit, rate.Category);
        Assert.False(rate.IsActionable);
        Assert.Equal(45, rate.RetryAfterSeconds);
        Assert.Equal(ModelFallbackRow.PresentationKind.Pill, ModelFallbackRow.FromFallback(rate).Presentation);

        // Provider fallback shape.
        var provLine = "Provider fallback: anthropic unavailable (HTTP 503 provider overloaded); using openrouter for this response.";
        var prov = ModelFallback.Parse(provLine)!;
        Assert.True(prov.IsProviderShape);
        Assert.Equal(ModelFallbackCategory.Busy, prov.Category);
        Assert.Equal("anthropic", prov.Primary);
        Assert.Equal("openrouter", prov.Fallback);

        // Billing / NotFound / Timeout / Other categories.
        Assert.Equal(ModelFallbackCategory.Billing, ModelFallback.Parse("Model fallback: a via p failed (HTTP 402 insufficient quota); using b.")!.Category);
        Assert.Equal(ModelFallbackCategory.NotFound, ModelFallback.Parse("Model fallback: a via p failed (HTTP 404 unknown model); using b.")!.Category);
        Assert.Equal(ModelFallbackCategory.Timeout, ModelFallback.Parse("Model fallback: a via p failed (request timed out); using b.")!.Category);
        Assert.Equal(ModelFallbackCategory.Other, ModelFallback.Parse("Model fallback: a via p failed (unexpected error); using b.")!.Category);

        // Restored line.
        var restoredLine = "Primary model restored: claude-opus-4-6.";
        Assert.True(ModelFallback.Restores(restoredLine));
        Assert.Equal("claude-opus-4-6", ModelFallback.RestoredModel(restoredLine));
        var restoredRow = ModelFallbackRow.Parse(restoredLine);
        Assert.Equal(ModelFallbackRow.PresentationKind.Restored, restoredRow?.Presentation);

        // ProviderWait.FallbackNotice + Transcript.Apply `status.update` surfaces fallback & restored notices.
        Assert.Equal(authLine, ProviderWait.FallbackNotice("fallback", authLine));
        Assert.Equal(restoredLine, ProviderWait.FallbackNotice("info", restoredLine));
        Assert.Null(ProviderWait.FallbackNotice("info", "Compacting messages…"));

        var transcript = new Transcript();
        var o1 = transcript.Apply(new RpcEvent("status.update", "s1", new JsonObject { ["kind"] = "fallback", ["text"] = authLine }, 1));
        Assert.Equal(Transcript.Outcome.Changed, o1);
        Assert.Equal("claude-opus-4-6", transcript.ActiveFallback?.Primary);
        Assert.Single(transcript.Messages);
        Assert.StartsWith(ProviderWait.NoticeIdPrefix, transcript.Messages[0].Id);

        // Fallback notices survive history refresh (ReplaceWithHistory).
        transcript.ReplaceWithHistory([Msg("stored-1", Role.User, "Hello")]);
        Assert.Equal(2, transcript.Messages.Count);
        Assert.Equal(authLine, transcript.Messages[1].Text);

        // Primary model restored clears ActiveFallback and appends notice.
        var o2 = transcript.Apply(new RpcEvent("status.update", "s1", new JsonObject { ["kind"] = "info", ["text"] = restoredLine }, 2));
        Assert.Equal(Transcript.Outcome.Changed, o2);
        Assert.Null(transcript.ActiveFallback);
        Assert.Equal(restoredLine, transcript.Messages[^1].Text);
    }

    // ------------------------------------------------------------------ 6. EnvKeys CLAUDE_CODE_OAUTH_TOKEN guard & SanitizeInitialCommand

    [Fact]
    public void EnvKeys_ClaudeOAuthTokenGuard_And_SanitizeInitialCommand()
    {
        // Rejects one-time `code#state` OAuth callback paste.
        var codeStateWarning = EnvKeys.ValueProblem("CLAUDE_CODE_OAUTH_TOKEN", "abc123def456#state789");
        Assert.NotNull(codeStateWarning);
        Assert.Contains("code#state", codeStateWarning);
        Assert.Contains("claude auth login", codeStateWarning);

        // Rejects arbitrary non-sk-ant- values.
        var wrongPrefixWarning = EnvKeys.ValueProblem("CLAUDE_CODE_OAUTH_TOKEN", "not-a-valid-token");
        Assert.NotNull(wrongPrefixWarning);
        Assert.Contains("sk-ant-", wrongPrefixWarning);
        Assert.Contains("claude setup-token", wrongPrefixWarning);

        // Accepts valid `sk-ant-` token and empty (unset).
        Assert.Null(EnvKeys.ValueProblem("CLAUDE_CODE_OAUTH_TOKEN", "sk-ant-oat01-validtoken"));
        Assert.Null(EnvKeys.ValueProblem("CLAUDE_CODE_OAUTH_TOKEN", "   "));
        Assert.Contains("claude setup-token", EnvKeys.FallbackDescription("CLAUDE_CODE_OAUTH_TOKEN"));

        // SanitizeInitialCommand enforces single-line non-empty commands without \n, \r, \0, or Unicode line separators.
        Assert.Equal("claude auth login", ModelFallbackRow.DetailModel.SanitizeInitialCommand("  claude auth login  "));
        Assert.Null(ModelFallbackRow.DetailModel.SanitizeInitialCommand(null));
        Assert.Null(ModelFallbackRow.DetailModel.SanitizeInitialCommand("   "));
        Assert.Null(ModelFallbackRow.DetailModel.SanitizeInitialCommand("claude auth login\nrm -rf /"));
        Assert.Null(ModelFallbackRow.DetailModel.SanitizeInitialCommand("claude auth login\rid"));
        Assert.Null(ModelFallbackRow.DetailModel.SanitizeInitialCommand("claude auth login\0id"));
        Assert.Null(ModelFallbackRow.DetailModel.SanitizeInitialCommand("claude auth login\u2028id"));
    }
}
