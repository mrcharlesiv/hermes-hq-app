using System.Text.Json.Nodes;
using Hermes.Core.Model;
using Hermes.Core.Notifications;
using Hermes.Core.Questions;
using Hermes.Core.Rpc;
using Hermes.Core.Settings;

namespace Hermes.Core.Tests;

/// Local reply and failure toasts (App/Notifications/NotificationHub.swift observeTurnEnd + post + present,
/// HermesKit/Push/NotificationText.swift, NotificationPrefs.swift NotificationRules): which turn ends alert, the words,
/// the thread (group), and the arguments a tap brings back into a chat.
public class NotificationsTests
{
    private static JsonNode Cases() =>
        JsonNode.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "push", "notification-preview-cases.json")))!;

    // ------------------------------------------------------------------ the shared cases (web, Swift, add-on)

    [Fact]
    public void SharedRedactionCasesMatch()
    {
        var failures = new List<string>();
        foreach (var c in Cases()["redactions"]!.AsArray())
        {
            var got = NotificationText.Redact(c!["input"]!.GetValue<string>());
            if (got != c["output"]!.GetValue<string>()) failures.Add($"{c["name"]}: got «{got}»");
        }
        Assert.Empty(failures);
        Assert.True(Cases()["redactions"]!.AsArray().Count >= 59);
    }

    [Fact]
    public void SharedPreviewCasesMatch()
    {
        var failures = new List<string>();
        foreach (var c in Cases()["previews"]!.AsArray())
        {
            var got = NotificationText.Preview(c!["input"]!.GetValue<string>());
            if (got != c["output"]!.GetValue<string>()) failures.Add($"{c["name"]}: got «{got}»");
        }
        Assert.Empty(failures);
    }

    [Fact]
    public void SharedCommandAndErrorCasesMatch()
    {
        foreach (var c in Cases()["commands"]!.AsArray())
            Assert.Equal(c!["output"]!.GetValue<string>(), NotificationText.CommandSummary(c["input"]!.GetValue<string>()));
        foreach (var c in Cases()["errors"]!.AsArray())
            Assert.Equal(c!["output"]!.GetValue<string>(), NotificationText.ErrorSentence(c["input"]!.GetValue<string>()));
    }

    // ------------------------------------------------------------------ the words (NotificationText.notification)

    private static readonly NotificationWho Ivy = new("Ivy", "", "", true);

    [Fact]
    public void ReplyCopyReadsLikeMessages()
    {
        // A bot's own chat: titled by the bot, the reply's first words as plain text.
        Assert.Equal(new NotificationCopy("Ivy", "", "Done. Tests pass"),
            NotificationText.Notification("message.complete", Ivy, "**Done.** Tests pass"));
        // A named chat that isn't a bot's: titled by the chat itself, no subtitle repeating it.
        Assert.Equal(new NotificationCopy("Fix the build", "", "On it"),
            NotificationText.Notification("message.complete", new NotificationWho("Otto", "Fix the build", "", false), "On it"));
        // A chat nobody named ("New Chat"): the sender's name instead.
        Assert.Equal(new NotificationCopy("Wren", "", "Hi"),
            NotificationText.Notification("message.complete", new NotificationWho("Wren", "New Chat", "", false), "Hi"));
        // A bot's other chat: the bot's name, the chat as the subtitle.
        Assert.Equal(new NotificationCopy("Juno", "Trip ideas", "Here you go"),
            NotificationText.Notification("message.complete", new NotificationWho("Juno", "Trip ideas", "", true), "Here you go"));
        // Nothing said, nobody named.
        Assert.Equal(new NotificationCopy("New reply", "", "New reply"), NotificationText.Notification("message.complete", null, ""));
    }

    [Fact]
    public void FailureCopySaysWhyInOneSentence()
    {
        var reason = NotificationText.ErrorReason("The reply timed out. Try again later please.");
        Assert.Equal("the reply timed out", NotificationText.ErrorSentence(reason));
        Assert.Equal(new NotificationCopy("Ivy", "", "Couldn’t finish: the reply timed out"),
            NotificationText.Notification("turnError", Ivy, reason));
        Assert.Equal("out of credits", NotificationText.ErrorReason("402", code: "billing"));
        Assert.Equal("this chat is open somewhere else", NotificationText.ErrorReason("SESSION_NOT_OWNED by another"));
        Assert.Equal("the disk on the computer running Hermes is full", NotificationText.ErrorReason("", code: "disk_full"));
        Assert.Equal("Codex usage limit reached", NotificationText.ErrorReason("HTTP 429", provider: "codex"));
        Assert.Equal(new NotificationCopy("Reply failed", "", "Couldn’t finish this reply"), NotificationText.Notification("turnError", null, ""));
    }

    [Fact]
    public void UsageLimitSaysWhenItLifts()
    {
        var now = new DateTimeOffset(2026, 11, 21, 14, 0, 0, TimeSpan.Zero);
        var en = System.Globalization.CultureInfo.GetCultureInfo("en-US");
        // ICU may put a narrow no-break space before PM (the Mac's own formatter does too); the words are what's compared.
        static string Plain(string s) => s.Replace('\u202F', ' ').Replace('\u00A0', ' ');
        Assert.Equal("usage limit reached until 3:00 PM",
            Plain(NotificationText.ErrorReason("rate limit", code: "rate_limit", resetsAt: now.AddHours(1).ToUnixTimeSeconds(),
                now: now, culture: en, zone: TimeZoneInfo.Utc)));
        Assert.Equal("usage limit reached until Sun, Nov 22, 3:00 PM",
            Plain(NotificationText.ErrorReason("usage_limit; retry after 90000 s", now: now, culture: en, zone: TimeZoneInfo.Utc)));
        Assert.Equal("usage limit reached", NotificationText.ErrorReason("429 Too Many Requests", now: now));
        // A time already past says no time.
        Assert.Equal("usage limit reached", NotificationText.ErrorReason("x", code: "rate_limit", resetsAt: now.AddHours(-1).ToUnixTimeSeconds(), now: now));
    }

    [Fact]
    public void PreviewsOffSayOnlyWhoNeedsYou()
    {
        Assert.Equal(new NotificationCopy("", "", "New reply from Ivy"), NotificationText.Notification("message.complete", Ivy, "secret words", previews: false));
        Assert.Equal(new NotificationCopy("", "", "Ivy couldn’t finish a reply"), NotificationText.Notification("turnError", Ivy, "boom", previews: false));
        Assert.Equal(new NotificationCopy("", "", "New reply"), NotificationText.Notification("message.complete", null, "x", previews: false));
        Assert.Equal(new NotificationCopy("", "", "A reply couldn’t finish"), NotificationText.Notification("turnError", null, "x", previews: false));
    }

    [Fact]
    public void LongRepliesClipAtAWordAndSecretsAreMasked()
    {
        var words = string.Join(" ", Enumerable.Repeat("alpha", 60));
        var body = NotificationText.Notification("message.complete", Ivy, words).Body;
        Assert.True(body.Length <= 180, body.Length.ToString());
        Assert.EndsWith("alpha…", body);
        Assert.Equal("Use password=••••", NotificationText.Notification("message.complete", Ivy, "Use password=hunter2").Body);
        // Names are one line, masked and bounded (60 characters for a sender).
        var long_ = new NotificationWho(new string('n', 100), "", "", true);
        Assert.Equal(60, NotificationText.Notification("message.complete", long_, "x").Title.Length);
    }

    // ------------------------------------------------------------------ turn ends (AppModel+Notifications notificationsTurnEnded)

    [Fact]
    public void TurnEndsReadFromGatewayFrames()
    {
        var done = new RpcEvent("message.complete", "rt1", JsonNode.Parse("""{"text":"All set","status":"complete"}"""), 7);
        Assert.Equal(new TurnEnd(false, "All set"), TurnEnd.From(done));
        var rendered = new RpcEvent("message.complete", "rt1", JsonNode.Parse("""{"rendered":"Shown"}"""), 8);
        Assert.Equal(new TurnEnd(false, "Shown"), TurnEnd.From(rendered));
        var failed = new RpcEvent("message.complete", "rt1",
            JsonNode.Parse("""{"status":"error","error":"boom","error_surface":{"code":"timeout"}}"""), 9);
        Assert.Equal(new TurnEnd(true, "the reply timed out"), TurnEnd.From(failed));
        var error = new RpcEvent("error", "rt1", JsonNode.Parse("""{"message":"Context window exceeded. Start a new chat."}"""), null);
        Assert.Equal(new TurnEnd(true, "Context window exceeded"), TurnEnd.From(error));
        Assert.Null(TurnEnd.From(new RpcEvent("message.delta", "rt1", null, 1)));
    }

    // ------------------------------------------------------------------ the decision table

    private sealed class Env
    {
        public NotificationPrefs Prefs = NotificationPrefs.Default;
        public bool Banners = true, Front = true, Active = true;
        public HashSet<string> Muted = [];
        public LocalAlerts Make() => new(() => Prefs, () => Banners, p => Muted.Contains(p), () => Front, () => Active);
    }

    private static readonly LocalAlertEntry IvyChat = new(Ivy, "20261121_ivy_chat", "ivy");
    private static readonly LocalAlertEntry OttoChat = new(new NotificationWho("Otto", "Fix the build", "", false), "20261121_fix_build", "otto");

    [Fact]
    public void AnotherChatsReplyAlertsAndTheChatOnScreenDoesNot()
    {
        var env = new Env();
        var alerts = env.Make();
        alerts.Focus("rt-otto", OttoChat.Stored);
        // In front: another chat's reply goes to Notification Center without a banner (the Mac's peek + list).
        var inFront = alerts.ObserveTurnEnd("rt-ivy", 1, false, "Done", IvyChat).Toast!;
        Assert.True(inFront.SuppressDisplay);
        Assert.Equal("message.complete", inFront.Kind);
        // Another app in front: the banner.
        env.Front = false;
        var away = alerts.ObserveTurnEnd("rt-ivy", 2, false, "Done", IvyChat).Toast!;
        Assert.False(away.SuppressDisplay);
        // The chat on screen never alerts, by runtime or by stored id.
        Assert.Equal("chat on screen", alerts.ObserveTurnEnd("rt-otto", 3, false, "x", OttoChat).Skipped);
        Assert.Equal("chat on screen", alerts.ObserveTurnEnd("rt-otto-2", 4, false, "x", OttoChat).Skipped);
        // Minimized (not active): the stored id on screen no longer counts, only the runtime does.
        env.Active = false;
        Assert.NotNull(alerts.ObserveTurnEnd("rt-otto-2", 5, false, "x", OttoChat).Toast);
        Assert.Equal("chat on screen", alerts.ObserveTurnEnd("rt-otto", 6, false, "x", OttoChat).Skipped);
        // Back on a list: every chat alerts.
        env.Active = true;
        alerts.Focus(null, null);
        Assert.NotNull(alerts.ObserveTurnEnd("rt-otto", 7, false, "x", OttoChat).Toast);
    }

    [Fact]
    public void FailuresKeepTheBannerInFront()
    {
        var alerts = new Env().Make();
        var toast = alerts.ObserveTurnEnd("rt-ivy", 1, true, "the reply timed out", IvyChat).Toast!;
        Assert.False(toast.SuppressDisplay);
        Assert.Equal("turnError", toast.Kind);
        Assert.Equal("Couldn’t finish: the reply timed out", toast.Body);
        // Bot Activity Banners off: in front, a reply keeps the system's banner too.
        var env = new Env { Banners = false };
        Assert.False(env.Make().ObserveTurnEnd("rt-ivy", 1, false, "Done", IvyChat).Toast!.SuppressDisplay);
    }

    [Fact]
    public void SettingsSwitchesAndMuteDecide()
    {
        var env = new Env { Prefs = NotificationPrefs.Default with { Enabled = false } };
        Assert.Equal("preference off", env.Make().ObserveTurnEnd("rt", 1, false, "x", IvyChat).Skipped);
        Assert.Equal("preference off", env.Make().ObserveTurnEnd("rt", 1, true, "x", IvyChat).Skipped);

        env.Prefs = NotificationPrefs.Default.WithKind("turnDone", false);
        Assert.Equal("preference off", env.Make().ObserveTurnEnd("rt", 1, false, "x", IvyChat).Skipped);
        Assert.NotNull(env.Make().ObserveTurnEnd("rt", 1, true, "x", IvyChat).Toast);

        env.Prefs = NotificationPrefs.Default.WithKind("turnError", false);
        Assert.NotNull(env.Make().ObserveTurnEnd("rt", 1, false, "x", IvyChat).Toast);
        Assert.Equal("preference off", env.Make().ObserveTurnEnd("rt", 1, true, "x", IvyChat).Skipped);

        // A muted bot's replies are quiet; its failures still alert (Shared/BotMutes.swift silenced kinds).
        env.Prefs = NotificationPrefs.Default;
        env.Muted.Add("ivy");
        Assert.Equal("muted", env.Make().ObserveTurnEnd("rt", 1, false, "x", IvyChat).Skipped);
        Assert.NotNull(env.Make().ObserveTurnEnd("rt", 1, true, "x", IvyChat).Toast);

        // Show Previews off: the words say only who.
        env.Muted.Clear();
        env.Prefs = NotificationPrefs.Default with { Previews = false };
        var quiet = env.Make().ObserveTurnEnd("rt", 1, false, "the plan", IvyChat).Toast!;
        Assert.Equal(("", "New reply from Ivy"), (quiet.Title, quiet.Body));
    }

    [Fact]
    public void EachTurnEndAlertsOnceAndSignOutDropsWhatWasInFlight()
    {
        var alerts = new Env().Make();
        var first = alerts.ObserveTurnEnd("rt", 4, false, "x", IvyChat).Toast!;
        Assert.Equal("already alerted", alerts.ObserveTurnEnd("rt", 4, false, "x", IvyChat).Skipped);
        Assert.NotNull(alerts.ObserveTurnEnd("rt", 4, true, "x", IvyChat).Toast); // the same seq's failure is its own alert
        Assert.True(alerts.MayPost(first));
        alerts.Clear();
        Assert.False(alerts.MayPost(first));
        Assert.NotNull(alerts.ObserveTurnEnd("rt", 4, false, "x", IvyChat).Toast);
    }

    [Fact]
    public void ToastIsGroupedByTheChatsThread()
    {
        var alerts = new Env().Make();
        var toast = alerts.ObserveTurnEnd("rt-ivy", 12, false, "Done", IvyChat).Toast!;
        Assert.Equal(IvyChat.Stored, toast.Group);          // threadIdentifier = the stored id
        Assert.Equal("rt-ivy:12:message.complete", toast.Tag); // the request identifier
        // Windows caps a tag and a group at 64 characters: a longer id is shortened the same way every time.
        var longId = new string('a', 150);
        var t2 = alerts.ObserveTurnEnd(longId, 1, false, "x", new LocalAlertEntry(Ivy, longId, "ivy")).Toast!;
        Assert.True(t2.Group.Length <= 64 && t2.Tag.Length <= 64);
        Assert.Equal(t2.Group, LocalToast.Key(longId));
        Assert.NotEqual(LocalToast.Key(longId), LocalToast.Key(longId + "b"));
        // No directory entry: the runtime is the session (Mac: entry?.stored ?? runtime).
        var bare = alerts.ObserveTurnEnd("rt-bare", 1, false, "x", null).Toast!;
        Assert.Equal("rt-bare", bare.Group);
        Assert.Equal(("New reply", "x"), (bare.Title, bare.Body));
    }

    // ------------------------------------------------------------------ the tap (localInfo → target → chat)

    [Fact]
    public void ActivationArgumentsRoundTripIntoTheChat()
    {
        var alerts = new Env().Make();
        var toast = alerts.ObserveTurnEnd("rt-ivy", 1, false, "Done", IvyChat).Toast!;
        Assert.Equal(["session", "stored", "request", "kind", "profile"], toast.Arguments.Select(a => a.Key));
        var raw = NotificationArguments.Encode(toast.Arguments);
        var target = NotificationTarget.From(NotificationArguments.Decode(raw))!;
        Assert.Equal(new NotificationTarget(IvyChat.Stored, "ivy"), target);

        // A plain chat opens by its listed title; a bot's own chat opens as the bot.
        var bots = new List<Bot>
        {
            new("ivy", "Ivy", null, null, true, false, false, null, false, new SessionRef("old_ivy", IvyChat.Stored, null, null, null, null, null), null),
            new("otto", "Otto", null, null, false, false, false, null, false, new SessionRef("otto_own", null, null, null, null, null, null), null),
            new("wren", "Wren", null, null, false, false, false, null, false, null, null),
        };
        Assert.Equal(new ChatRoute("ivy", IvyChat.Stored, "Ivy", "ivy"), NotificationOpen.Route(target, bots, _ => null));
        var otto = NotificationTarget.From(NotificationArguments.Decode(NotificationArguments.Encode(
            alerts.ObserveTurnEnd("rt-otto", 1, true, "x", OttoChat).Toast!.Arguments)))!;
        Assert.Equal(new ChatRoute("otto", OttoChat.Stored, "Fix the build", null),
            NotificationOpen.Route(otto, bots, id => id == OttoChat.Stored ? new ListedChat("otto", "Fix the build") : null));
        // Not listed: no name to show yet (the chat reads its own).
        Assert.Equal(new ChatRoute("otto", OttoChat.Stored, "", null), NotificationOpen.Route(otto, bots, _ => null));
        // A bot with no chat of its own yet: the alert's chat is the one it is making, so the bot opens.
        Assert.Equal(new ChatRoute("wren", "wren_new", "Wren", "wren"), NotificationOpen.Route(new NotificationTarget("wren_new", "wren"), bots, _ => null));
        // No profile and nothing listed: nothing to open it with.
        Assert.Null(NotificationOpen.Route(new NotificationTarget("nobody_1", null), bots, _ => null));
    }

    [Fact]
    public void ArgumentsSurviveTheSeparatorsAndBadTargetsOpenNothing()
    {
        var pairs = new List<KeyValuePair<string, string>> { new("profile", "a=b;c%d"), new("stored", "s_1") };
        Assert.Equal(pairs, NotificationArguments.Decode(NotificationArguments.Encode(pairs)).ToList());
        Assert.Null(NotificationTarget.From(NotificationArguments.Decode("kind=message.complete;stored=../etc")));
        Assert.Null(NotificationTarget.From(NotificationArguments.Decode("")));
        // The stored id wins over the runtime session; an empty profile is none.
        Assert.Equal(new NotificationTarget("st_1", null), NotificationTarget.From(NotificationArguments.Decode("session=rt_1;stored=st_1;profile=")));
        Assert.Equal(new NotificationTarget("rt_1", null), NotificationTarget.From(NotificationArguments.Decode("session=rt_1;stored=bad id")));
    }

    [Fact]
    public void DirectoryNamesTheSenderAndTheChat()
    {
        var bots = new List<Bot>
        {
            new("ivy", "Ivy", null, null, true, false, false, null, false, new SessionRef("ivy_own", null, null, null, null, null, null), null),
            new("wren", "Wren", null, null, false, false, false, null, false, null, null),
        };
        Assert.Equal(new LocalAlertEntry(new NotificationWho("Ivy", "", "", true), "ivy_own", "ivy"),
            NotificationDirectory.Entry("ivy", "ivy_own", "Bot Chat", bots));
        Assert.Equal(new LocalAlertEntry(new NotificationWho("Ivy", "Trip ideas", "", false), "ivy_trip", "ivy"),
            NotificationDirectory.Entry("ivy", "ivy_trip", "Trip ideas", bots));
        // A bot with no chat of its own yet: this one is it.
        Assert.True(NotificationDirectory.Entry("wren", "wren_1", "New Chat", bots)!.Who.Bot);
        // A bot not (yet) listed: no name is guessed.
        Assert.Equal(new NotificationWho("", "Notes", "", false), NotificationDirectory.Entry("otto", "otto_1", "Notes", bots)!.Who);
        Assert.Equal(new NotificationWho("", "Notes", "", false), NotificationDirectory.Entry("otto", "otto_1", "Notes", null)!.Who);
        Assert.Null(NotificationDirectory.Entry("ivy", "not valid", "x", bots));
        // Its words: "Ivy" with "Trip ideas" beneath, as the Mac's alert.
        var copy = NotificationText.Notification("message.complete", NotificationDirectory.Entry("ivy", "ivy_trip", "Trip ideas", bots)!.Who, "Booked");
        Assert.Equal(new NotificationCopy("Trip ideas", "", "Booked"), copy);
    }

    [Fact]
    public void PendingTapWaitsForTheSignedInApp()
    {
        var opener = new NotificationOpener();
        var target = new NotificationTarget("st_1", "ivy");
        opener.Tapped(target);
        Assert.Equal(target, opener.TakePending());
        Assert.Null(opener.TakePending());
        NotificationTarget? opened = null;
        opener.Tapped(target);
        opener.Ready(t => opened = t);
        Assert.Equal(target, opened);
        Assert.Null(opener.TakePending());
    }

    // ------------------------------------------------------------------ held requests (NotificationHub.observeRequest)

    private static JsonObject P(string json) => (JsonObject)JsonNode.Parse(json)!;
    private static string Arg(IEnumerable<KeyValuePair<string, string>> args, string key) =>
        args.FirstOrDefault(a => a.Key == key).Value ?? "";

    [Fact]
    public void ApprovalAlertOffersApproveOnceAndDeny()
    {
        var alerts = new Env().Make();
        var toast = alerts.ObserveRequest("srq-a", PromptKind.Approval, "rt-ivy",
            P("""{"command":"git status","description":"Look at the tree"}"""), IvyChat).Toast!;
        Assert.Equal("approval.request", toast.Kind);
        Assert.Equal("request-srq-a", toast.Id);
        Assert.Equal(LocalAlerts.RequestTag("srq-a"), toast.Tag);
        Assert.Equal(IvyChat.Stored, toast.Group);
        Assert.Equal(("Ivy", "Wants to run: git status"), (toast.Title, toast.Body));
        // Approvals keep the banner in front (present(_:): only a finished reply borrows the peek).
        Assert.False(toast.SuppressDisplay);
        Assert.Equal("srq-a", Arg(toast.Arguments, "request"));
        // The Mac's DISPATCH_APPROVAL_LOCAL category: "approve" → Approve Once, "deny" → Deny, in that order.
        Assert.Equal(["Approve Once", "Deny"], toast.Buttons.Select(b => b.Title));
        Assert.Equal(["approve", "deny"], toast.Buttons.Select(b => Arg(b.Arguments, "action")));

        // A click on Approve Once comes back as its own arguments: the request, the choice and the chat it opens.
        var approve = NotificationResponse.From(NotificationArguments.Decode(NotificationArguments.Encode(toast.Buttons[0].Arguments)));
        Assert.Equal(new NotificationResponse(new NotificationTarget(IvyChat.Stored, "ivy"), "srq-a", true), approve);
        var deny = NotificationResponse.From(NotificationArguments.Decode(NotificationArguments.Encode(toast.Buttons[1].Arguments)));
        Assert.Equal(("srq-a", (bool?)false), (deny.Request, deny.Approve));
        // A click elsewhere on it only opens the chat.
        var body = NotificationResponse.From(NotificationArguments.Decode(NotificationArguments.Encode(toast.Arguments)));
        Assert.Equal(new NotificationResponse(new NotificationTarget(IvyChat.Stored, "ivy"), null, null), body);
    }

    [Fact]
    public void ApproveIsOfferedOnlyWhenTheWholeCommandShows()
    {
        var alerts = new Env().Make();
        // More than one line, clipped, or masked: the alert only opens the chat, where the whole command is.
        Assert.Empty(alerts.ObserveRequest("r1", PromptKind.Approval, "rt-ivy", P("""{"command":"cd /tmp\nrm -rf build"}"""), IvyChat).Toast!.Buttons);
        Assert.Empty(alerts.ObserveRequest("r2", PromptKind.Approval, "rt-ivy", P($$"""{"command":"echo {{new string('x', 200)}}"}"""), IvyChat).Toast!.Buttons);
        var masked = alerts.ObserveRequest("r3", PromptKind.Approval, "rt-ivy", P("""{"command":"API_KEY=abcdef0123456789abcdef curl https://example.com"}"""), IvyChat).Toast!;
        Assert.Contains(NotificationText.Redacted, masked.Body);
        Assert.Empty(masked.Buttons);
        // No command: the description says what it wants, and there is nothing to approve from the alert.
        var described = alerts.ObserveRequest("r4", PromptKind.Approval, "rt-ivy", P("""{"description":"Open a page"}"""), IvyChat).Toast!;
        Assert.Equal("Open a page", described.Body);
        Assert.Empty(described.Buttons);
        // Show Previews off: only who needs you, and no buttons.
        var quiet = new Env { Prefs = NotificationPrefs.Default with { Previews = false } }.Make()
            .ObserveRequest("r5", PromptKind.Approval, "rt-ivy", P("""{"command":"git status"}"""), IvyChat).Toast!;
        Assert.Equal(("", "Ivy needs your approval"), (quiet.Title, quiet.Body));
        Assert.Empty(quiet.Buttons);
        Assert.True(NotificationText.Approvable("git status"));
        Assert.False(NotificationText.Approvable(""));
        Assert.False(NotificationText.Approvable("cd /tmp …"));
    }

    [Fact]
    public void QuestionsAndPasswordsAlertWithTheirOwnWords()
    {
        var alerts = new Env().Make();
        var clarify = alerts.ObserveRequest("q1", PromptKind.Clarify, "rt-ivy",
            P("""{"questions":[{"qid":"q0","question":"Which **branch**?"},{"qid":"q1","question":"Name?"}]}"""), IvyChat).Toast!;
        Assert.Equal(("input", "Ivy", "Which branch?"), (clarify.Kind, clarify.Title, clarify.Body));
        Assert.Equal("", Arg(clarify.Arguments, "request")); // only an approval is answered from its alert
        Assert.Empty(clarify.Buttons);
        Assert.Equal("Shared question", alerts.ObserveRequest("q2", PromptKind.Clarify, "rt-ivy", P("""{"question":"Shared question"}"""), IvyChat).Toast!.Body);
        Assert.Equal("Your administrator password is needed",
            alerts.ObserveRequest("s1", PromptKind.Sudo, "rt-ivy", P("""{"command":"apt update"}"""), IvyChat).Toast!.Body);
        Assert.Equal("Paste the key", alerts.ObserveRequest("s2", PromptKind.Secret, "rt-ivy", P("""{"prompt":" Paste the key "}"""), IvyChat).Toast!.Body);
        Assert.Equal("A password or secret is needed", alerts.ObserveRequest("s3", PromptKind.Secret, "rt-ivy", P("{}"), IvyChat).Toast!.Body);
        Assert.Equal("Unlock Vaultly to continue", alerts.ObserveRequest("v1", PromptKind.VaultUnlock, "rt-ivy", P("""{"display_name":"Vaultly","backend":"vb"}"""), IvyChat).Toast!.Body);
        Assert.Equal("Unlock your password manager to continue", NotificationText.ValueRequestLine(PromptKind.VaultUnlock, P("{}")));
        Assert.Equal("Save your example.com login?", NotificationText.ValueRequestLine(PromptKind.VaultSaveLogin, P("""{"origin":"example.com"}""")));
        Assert.Equal("Save a login?", NotificationText.ValueRequestLine(PromptKind.VaultSaveLogin, P("{}")));
        Assert.Equal("A verification code for example.com is needed", NotificationText.ValueRequestLine(PromptKind.VaultCode, P("""{"site":"example.com"}""")));
        Assert.Equal("A verification code is needed", NotificationText.ValueRequestLine(PromptKind.VaultCode, null));
        // Previews off: a question only says who is waiting.
        var quiet = new Env { Prefs = NotificationPrefs.Default with { Previews = false } }.Make()
            .ObserveRequest("q3", PromptKind.Clarify, "rt-ivy", P("""{"question":"x"}"""), IvyChat).Toast!;
        Assert.Equal("Ivy is waiting for your answer", quiet.Body);
    }

    [Fact]
    public void RequestAlertsFollowScreenSwitchesAndMute()
    {
        var env = new Env();
        var alerts = env.Make();
        // The chat on screen never alerts for its own requests, by runtime or stored id.
        alerts.Focus("rt-ivy", IvyChat.Stored);
        Assert.Equal("chat on screen", alerts.ObserveRequest("a1", PromptKind.Approval, "rt-ivy", P("""{"command":"ls"}"""), IvyChat).Skipped);
        Assert.Equal("chat on screen", alerts.ObserveRequest("a2", PromptKind.Clarify, "rt-ivy-2", P("""{"question":"x"}"""), IvyChat).Skipped);
        // Another chat's request alerts; each request once.
        Assert.NotNull(alerts.ObserveRequest("a3", PromptKind.Approval, "rt-otto", P("""{"command":"ls"}"""), OttoChat).Toast);
        Assert.Equal("already alerted", alerts.ObserveRequest("a3", PromptKind.Approval, "rt-otto", P("""{"command":"ls"}"""), OttoChat).Skipped);
        alerts.Focus(null, null);
        // Per-bot Mute: approvals and questions still alert.
        env.Muted.Add("ivy");
        Assert.NotNull(env.Make().ObserveRequest("m1", PromptKind.Approval, "rt-ivy", P("""{"command":"ls"}"""), IvyChat).Toast);
        Assert.NotNull(env.Make().ObserveRequest("m2", PromptKind.Clarify, "rt-ivy", P("""{"question":"x"}"""), IvyChat).Toast);
        // Their own switches: Approvals ("approval") and Questions ("input").
        env.Prefs = NotificationPrefs.Default.WithKind("approval", false);
        Assert.Equal("preference off", env.Make().ObserveRequest("p1", PromptKind.Approval, "rt-ivy", P("""{"command":"ls"}"""), IvyChat).Skipped);
        Assert.NotNull(env.Make().ObserveRequest("p2", PromptKind.Clarify, "rt-ivy", P("""{"question":"x"}"""), IvyChat).Toast);
        env.Prefs = NotificationPrefs.Default.WithKind("input", false);
        Assert.Equal("preference off", env.Make().ObserveRequest("p3", PromptKind.Sudo, "rt-ivy", P("{}"), IvyChat).Skipped);
        // No directory entry: the runtime is the thread and still a valid chat, so Approve is offered.
        env.Prefs = NotificationPrefs.Default;
        var bare = env.Make().ObserveRequest("b1", PromptKind.Approval, "rt_bare", P("""{"command":"ls"}"""), null).Toast!;
        Assert.Equal(("rt_bare", "Approval needed", 2), (bare.Group, bare.Title, bare.Buttons.Count));
    }

    [Fact]
    public void PendingAnswerWaitsForTheSignedInApp()
    {
        var answers = new LocalAnswerQueue();
        answers.Answered("srq-a", true);
        Assert.Equal(("srq-a", true), answers.TakePending());
        Assert.Null(answers.TakePending());
        (string, bool)? got = null;
        answers.Answered("srq-b", false);
        answers.Ready((r, a) => got = (r, a));
        Assert.Equal(("srq-b", false), got);
        answers.Answered("srq-c", true);
        Assert.Equal(("srq-c", true), got);
        answers.Ready(null);
        answers.Answered("srq-d", true);
        Assert.Equal(("srq-c", true), got);
        Assert.Equal(("srq-d", true), answers.TakePending());
    }

    [Fact]
    public void LocalApprovalWordsMatchTheMac()
    {
        Assert.Equal("Approved", LocalApprovalWords.Sent(true));
        Assert.Equal("Denied", LocalApprovalWords.Sent(false));
        Assert.Equal("Couldn’t Approve", LocalApprovalWords.Title(true));
        Assert.Equal("Couldn’t Deny", LocalApprovalWords.Title(false));
        Assert.Equal("That request was already answered or had expired.", LocalApprovalWords.Gone);
        Assert.Equal("Your answer didn’t reach Hermes. Click Run or Reject on the card in the chat to try again.", LocalApprovalWords.NotSent);
        Assert.Equal(QuestionCenter.ApprovalOffline, LocalApprovalWords.Reason(new PromptAnswerException(QuestionCenter.ApprovalOffline, true)));
        Assert.Equal(LocalApprovalWords.NotSent, LocalApprovalWords.Reason(new PromptAnswerException(QuestionCenter.ApprovalFailed, false)));
        Assert.Equal(LocalApprovalWords.NotSent, LocalApprovalWords.Reason(new InvalidOperationException()));
    }

    // A notification action is never delivered to QuestionCenter by a proof. ToastCenterTests compares the
    // production labels and decoded routes in a recording-only receiver, including missing and mutated requests.
}
