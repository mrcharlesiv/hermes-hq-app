using System.Text.Json.Nodes;
using Hermes.Core.Notifications;
using static Hermes.Core.Tests.ToastQuietRunner;

namespace Hermes.Core.Tests;

/// Memory-only: never loads the Windows adapter, reads the process environment, signs in or drives a desktop.
public partial class ToastQuietProbeTests
{
    private const string Url = "http://127.0.0.1:9736", User = "toast-fixture";

    private sealed class Fixture
    {
        public readonly Dictionary<string, string?> Env = Push();
        public readonly JsonObject Extra = new() { ["url"] = Url, ["username"] = User, ["tag"] = "toasts", ["places"] = new JsonArray(), ["walks"] = new JsonArray("toasts") };
        public readonly JsonArray Extras;
        public readonly JsonObject Config;
        public JsonNode? Selected;
        public string? Walk = "toasts", LiveUrl = Url, LiveUser = User;
        public object? Bound = new(), Current;
        public int? Pending = 0;
        public int ContextReads;
        public bool TracksA = true;
        public readonly List<string> Lines = [];
        public readonly FakeReader Reader = new();
        public Fixture()
        {
            Current = Bound;
            Selected = Extra;
            Extras = new JsonArray(new JsonObject { ["tag"] = "jobs", ["url"] = "http://127.0.0.1:9800", ["walks"] = new JsonArray("quick-action-run") }, Extra);
            Config = new JsonObject { ["url"] = "http://127.0.0.1:9711", ["extras"] = Extras };
        }
        public ToastQuietProbe Bind(bool windows = true) => new(windows, key => Env.GetValueOrDefault(key), requireTrackedA =>
            {
                ContextReads++;
                return (!requireTrackedA || TracksA) && ToastQuietProbe.IsReplyWalk(Config, Selected, Walk, LiveUrl, LiveUser, Bound, Current, Pending);
            }, Reader, Lines.Add);
        public QuietReading Read(QuietPoint point = QuietPoint.BeforeFirst) => Bind().Read(point);
        public void RequirePlan(bool windows = true) => ToastQuietProbe.RequirePlan(windows, k => Env.GetValueOrDefault(k), Config);
        public void ExpectDenied(string reason, int contextReads)
        {
            var report = Read();
            Assert.Equal(reason, report.Reason);
            Assert.Equal(contextReads, ContextReads);
            Assert.Empty(Reader.Calls);
            Assert.Contains("quns=not-read focus=not-read app=not-read", report.Line);
        }
    }

    private sealed class FakeReader : IQuietReader
    {
        public readonly List<string> Calls = [];
        public bool Foreground = true;
        public QuietForeground? RawForeground;
        public QuietChat Chat = QuietChat.B;
        public int? Quns = 5;
        public QuietProfileRead? Profile = new(0, 4, 1, 0);
        public string? Setting = "Enabled", Throws;
        public Action? AfterSetting;
        private T Get<T>(string name, T value)
        {
            Calls.Add(name);
            if (Throws == name) throw new InvalidOperationException("fixture-private-canary");
            return value;
        }
        public QuietForeground ReadFixtureForeground(QuietChat expected) => Get("foreground", RawForeground ?? (!Foreground ? QuietForeground.ComposerNotFocused
            : expected != Chat ? QuietForeground.ChatIdMismatch : QuietForeground.Verified));
        public int? ReadQuns() => Get("quns", Quns);
        public QuietProfileRead? ReadFocus() => Get("focus", Profile);
        public string? ReadAppSetting() { var s = Get("app", Setting); AfterSetting?.Invoke(); return s; }
    }

    // The statement following the production gate must be unreachable, not merely preceded by a refusal log.
    private static QuietWalkStopped StopsBeforeAction(Action check)
    {
        int nextActions = 0;
        var error = Record.Exception(() => { check(); nextActions++; });
        Assert.Equal(0, nextActions);
        return Assert.IsType<QuietWalkStopped>(error);
    }

    [Theory]
    [InlineData(true, "runner-not-authorized")]
    [InlineData(false, "foreground-unverified")]
    public void RefusalStopsTheWalkBeforeItsNextAction(bool missingProjection, string reason)
    {
        var f = new Fixture();
        if (missingProjection) f.Env.Remove("HQW_QUIET_PUSH"); else f.Reader.Foreground = false;
        var quiet = f.Bind();
        Assert.Equal($"toast-quiet-stop/v1 phase=entry gap={reason}", StopsBeforeAction(() => quiet.Checkpoint(QuietPoint.Entry)).StopLine);
        Assert.EndsWith("gap=" + reason, f.Lines[0]);
        if (missingProjection) Assert.Single(f.Lines);
        else Assert.Equal(new[] { "fixture-foreground/v1 phase=entry clause=ComposerNotFocused" }, f.Lines.Skip(1));
        Assert.DoesNotContain("quns", f.Reader.Calls);
    }

    [Fact]
    public void PlanPreflightPrecedesEvenTheFirstSetupMarkerAndHasNoReader()
    {
        foreach (var (change, windows, reason) in new (Action<Fixture>, bool, string)[] {
            (_ => { }, false, "non-windows"), (f => f.Env.Remove("HQW_QUIET_PUSH"), true, "runner-not-authorized"),
            (f => f.Env["GITHUB_JOB"] = "other", true, "runner-not-authorized"), (f => f.Env["RUNNER_ENVIRONMENT"] = "self-hosted", true, "runner-not-authorized"),
            (f => f.Extra["username"] = "another-fixture", true, "not-reply-walk"), (f => f.Extras.Remove(f.Extra), true, "not-reply-walk"),
            (f => f.Extras.Insert(0, f.Extra.DeepClone()), true, "not-reply-walk"), (f => f.Config["extrasOnly"] = true, true, "not-reply-walk"),
            (f => f.Extra["places"] = new JsonArray("other"), true, "not-reply-walk"), (f => f.Extra["walks"] = new JsonArray(), true, "not-reply-walk"),
        })
        {
            var f = new Fixture(); change(f);
            var phase = reason == "not-reply-walk" ? "plan" : "runner";
            Assert.Equal($"toast-quiet-stop/v1 phase={phase} gap={reason}", StopsBeforeAction(() => f.RequirePlan(windows)).StopLine);
            Assert.Equal(0, f.ContextReads); Assert.Empty(f.Reader.Calls);
        }
    }

    [Fact]
    public void AValidPlanCannotAdmitAnotherSelectionOrSessionAtEntry()
    {
        foreach (var change in new Action<Fixture>[] { f => f.Selected = f.Config.DeepClone()["extras"]![1], f => f.Selected = f.Extras[0],
            f => f.Walk = "other", f => f.Current = new object(), f => f.Bound = null, f => f.Pending = 1 })
        {
            var f = new Fixture(); f.RequirePlan(); change(f);
            Assert.Equal("not-reply-walk", StopsBeforeAction(() => f.Bind().Checkpoint(QuietPoint.Entry)).Message);
            Assert.Empty(f.Reader.Calls);
        }
        var nonWindows = new Fixture();
        Assert.Equal("non-windows", StopsBeforeAction(() => nonWindows.Bind(false).Checkpoint(QuietPoint.Entry)).Message);
        Assert.Empty(nonWindows.Reader.Calls);
    }

    [Theory]
    [InlineData(QuietPoint.BeforeFirst, "before-first")]
    [InlineData(QuietPoint.BeforeAway, "before-away")]
    [InlineData(QuietPoint.AfterAway, "after-away")]
    public void LosingFocusStopsBeforePostMinimizeOrWarmAndCannotBeRetried(QuietPoint point, string phase)
    {
        var f = new Fixture(); var quiet = f.Bind(); quiet.Checkpoint(QuietPoint.Entry);
        if (point != QuietPoint.BeforeFirst) quiet.Checkpoint(QuietPoint.BeforeFirst);
        if (point == QuietPoint.AfterAway) quiet.Checkpoint(QuietPoint.BeforeAway);
        int reads = f.Reader.Calls.Count, records = f.Lines.Count;
        f.Reader.Foreground = false;
        var stop = StopsBeforeAction(() => quiet.Checkpoint(point));
        Assert.Equal($"toast-quiet-stop/v1 phase={phase} gap=foreground-unverified", stop.StopLine);
        Assert.Equal(new[] { "foreground" }, f.Reader.Calls.Skip(reads));
        f.Reader.Foreground = true;
        Assert.Same(stop, StopsBeforeAction(() => quiet.RequireChat(QuietChat.B)));
        Assert.Same(stop, StopsBeforeAction(() => quiet.Checkpoint(point)));
        Assert.Equal(records + 2, f.Lines.Count); Assert.Equal(reads + 1, f.Reader.Calls.Count);
        Assert.Equal($"fixture-foreground/v1 phase={phase} clause=ComposerNotFocused", f.Lines[^1]);
    }

    [Theory]
    [InlineData("session", "not-reply-walk")]
    [InlineData("request", "not-reply-walk")]
    [InlineData("job", "runner-not-authorized")]
    [InlineData("another-valid-run", "runner-not-authorized")]
    [InlineData("wrong-chat", "foreground-unverified")]
    public void EntryIsNotAPermitAfterAnAwait(string lost, string reason)
    {
        var f = new Fixture { TracksA = false }; var quiet = f.Bind();
        quiet.Checkpoint(QuietPoint.Entry); // Initial B is already focused; A's normal setup has not happened yet.
        int reads = f.Reader.Calls.Count;
        switch (lost)
        {
            case "session": f.Current = new object(); break;
            case "request": f.Pending = 1; break;
            case "job": f.Env.Remove("GITHUB_JOB"); break;
            case "another-valid-run": f.Env["GITHUB_RUN_ATTEMPT"] = "3"; break;
            case "wrong-chat": f.Reader.Chat = QuietChat.A; break;
        }
        Assert.Equal($"toast-quiet-stop/v1 phase=guard-b gap={reason}", StopsBeforeAction(() => quiet.RequireChat(QuietChat.B)).StopLine);
        Assert.All(f.Reader.Calls.Skip(reads), call => Assert.Equal("foreground", call));
    }

    [Fact]
    public void ExactEntryComposerAndTrackedReplyAreSeparateChecks()
    {
        var notB = new Fixture(); notB.Reader.Chat = QuietChat.A;
        Assert.Equal("foreground-unverified", StopsBeforeAction(() => notB.Bind().Checkpoint(QuietPoint.Entry)).Message);
        var f = new Fixture { TracksA = false }; var quiet = f.Bind();
        quiet.Checkpoint(QuietPoint.Entry); quiet.RequireChat(QuietChat.B);
        f.Reader.Chat = QuietChat.A; f.TracksA = true; quiet.RequireChat(QuietChat.A);
        f.Reader.Chat = QuietChat.B; f.TracksA = false;
        Assert.Equal("not-reply-walk", StopsBeforeAction(() => quiet.Checkpoint(QuietPoint.BeforeFirst)).Message);
        Assert.Single(f.Reader.Calls, c => c == "quns");
    }

    [Theory]
    [InlineData("focus", "focus-unknown")]
    [InlineData("quns", "shell-state-unknown")]
    [InlineData("app", "app-setting-unknown")]
    public void UnknownMeasurementStopsBeforeNavigationEvenIfAnotherSignalIsQuiet(string unknown, string reason)
    {
        var f = new Fixture(); f.Reader.Quns = 6; f.Reader.Profile = new(0, 4, 3, 1); f.Reader.Throws = unknown;
        Assert.Equal(reason, StopsBeforeAction(() => f.Bind().Checkpoint(QuietPoint.Entry)).Message);
        Assert.Contains("banner=unverified gap=" + reason, Assert.Single(f.Lines));
    }

    [Theory]
    [InlineData(1, 5, "Enabled", "focus-quiet")]
    [InlineData(0, 6, "Enabled", "shell-not-accepting")]
    [InlineData(0, 5, "DisabledForUser", "app-not-enabled")]
    [InlineData(0, 5, "Enabled", "banner-not-observed")]
    public void KnownStatePreservesButNeverGrantsIndependentActivation(uint profile, int quns, string app, string gap)
    {
        foreach (bool independentlyAuthorized in new[] { false, true })
        {
            var f = new Fixture { TracksA = false }; f.Reader.Quns = quns; f.Reader.Profile = new(0, 4, 1, profile); f.Reader.Setting = app;
            var quiet = f.Bind(); int entries = 0, minimizes = 0, activations = 0;
            f.RequirePlan(); quiet.Checkpoint(QuietPoint.Entry); entries++;
            f.TracksA = true; quiet.Checkpoint(QuietPoint.BeforeFirst); quiet.Checkpoint(QuietPoint.BeforeAway); minimizes++;
            quiet.Checkpoint(QuietPoint.AfterAway); quiet.RequireChat(QuietChat.B);
            if (independentlyAuthorized) activations++;
            Assert.Equal((1, 1, independentlyAuthorized ? 1 : 0), (entries, minimizes, activations));
            Assert.Equal(new[] { "phase=entry", "phase=before-first", "phase=before-away", "phase=after-away" }, f.Lines.Select(l => l.Split(' ')[3]));
            Assert.All(f.Lines, l => Assert.EndsWith("writes=0 restore=not-needed banner=unverified gap=" + gap, l));
        }
    }

    [Fact]
    public void AGuardCannotReplaceAdmissionOrSkipAnObservation()
    {
        var f = new Fixture(); var quiet = f.Bind();
        Assert.Equal("entry-required", StopsBeforeAction(() => quiet.RequireChat(QuietChat.B)).Message);
        Assert.Empty(f.Reader.Calls);
        var fresh = f.Bind(); fresh.Checkpoint(QuietPoint.Entry); int reads = f.Reader.Calls.Count;
        Assert.Equal("checkpoint-out-of-order", StopsBeforeAction(() => fresh.Checkpoint(QuietPoint.BeforeAway)).Message);
        Assert.Equal(reads, f.Reader.Calls.Count);
    }

    [Fact]
    public void LosingFocusInTheLogListenerStillStopsTheNextAction()
    {
        var f = new Fixture(); var quiet = new ToastQuietProbe(true, k => f.Env.GetValueOrDefault(k), _ => true, f.Reader,
            line => { f.Lines.Add(line); f.Reader.Foreground = false; });
        Assert.Equal("toast-quiet-stop/v1 phase=guard-b gap=foreground-unverified", StopsBeforeAction(() => quiet.Checkpoint(QuietPoint.Entry)).StopLine);
        Assert.Equal(3, f.Lines.Count); Assert.Single(f.Reader.Calls, c => c == "quns");
        Assert.Equal("fixture-foreground/v1 phase=guard-b clause=ComposerNotFocused", f.Lines[^1]);
    }

    [Fact]
    public void NoActionAfterAnUnrecordableObservation()
    {
        var f = new Fixture(); var quiet = new ToastQuietProbe(true, k => f.Env.GetValueOrDefault(k), _ => true, f.Reader,
            _ => throw new IOException("fixture-private-canary"));
        var stop = StopsBeforeAction(() => quiet.Checkpoint(QuietPoint.Entry));
        Assert.Equal("toast-quiet-stop/v1 phase=entry gap=readback-unrecorded", stop.StopLine);
        Assert.Same(stop, StopsBeforeAction(() => quiet.RequireChat(QuietChat.B)));
    }

    [Fact]
    public void NonWindowsShortCircuitsEvenCompleteRunnerClaims()
    {
        var f = new Fixture();
        var r = new ToastQuietProbe(false, _ => throw new Xunit.Sdk.XunitException("read env"),
            _ => throw new Xunit.Sdk.XunitException("read app"), f.Reader, f.Lines.Add).Read(QuietPoint.BeforeFirst);
        Assert.Equal("non-windows", r.Reason);
        Assert.Empty(f.Reader.Calls);
    }

    public static IEnumerable<object[]> RequiredFields() => Push().Keys.Select(k => new object[] { k });
    [Theory, MemberData(nameof(RequiredFields))]
    public void MissingOrBlankIdentityFieldCannotReachTheAppOrReader(string key)
    {
        foreach (var missing in new string?[] { null, "", " " })
        {
            var f = new Fixture(); f.Env[key] = missing;
            f.ExpectDenied("runner-not-authorized", 0);
        }
    }

    [Theory]
    [InlineData("GITHUB_ACTIONS", "TRUE")]
    [InlineData("RUNNER_OS", "Linux")]
    [InlineData("RUNNER_ENVIRONMENT", "self-hosted")]
    [InlineData("GITHUB_SERVER_URL", "https://example.com")]
    [InlineData("GITHUB_EVENT_NAME", "pull_request_target")]
    [InlineData("GITHUB_EVENT_NAME", "workflow_dispatch")]
    [InlineData("GITHUB_REPOSITORY", "example/hermes-hq-windows")]
    [InlineData("GITHUB_REF", "refs/tags/feat/windows")]
    [InlineData("GITHUB_WORKFLOW", "Windows app proof (search, chat, keyboard and accessible names)")]
    [InlineData("GITHUB_WORKFLOW_REF", "mrcharlesiv/hermes-hq-windows/.github/workflows/windows.yml@refs/heads/main")]
    [InlineData("GITHUB_JOB", "app-proof")]
    [InlineData("HQW_PRIVATE_MIRROR", "false")]
    [InlineData("HQW_DESKTOP_PROOF", "true")]
    [InlineData("HQW_APP_PROOF", "1")]
    [InlineData("HQW_APP_PROOF", "unexpected")]
    [InlineData("GITHUB_SHA", "ABC123")]
    [InlineData("GITHUB_WORKFLOW_SHA", "fedcba9876543210fedcba9876543210fedcba98")]
    [InlineData("HQW_QUIET_PUSH", Sha)]
    [InlineData("GITHUB_RUN_ID", "01")]
    [InlineData("GITHUB_RUN_ID", "2\n8")]
    [InlineData("GITHUB_RUN_ATTEMPT", "２")]
    public void WrongRunnerIdentityNeverReadsNotificationState(string key, string wrong)
    {
        var f = new Fixture(); f.Env[key] = wrong;
        f.ExpectDenied("runner-not-authorized", 0);
    }

    [Theory]
    [InlineData("0000000000000000000000000000000000000000")]
    [InlineData("0123456789abcdef0123456789abcdef0123456Z")]
    [InlineData("0123456789abcdef0123456789abcdef0123456")]
    public void ThreeAgreeingButInvalidRevisionsAreStillUnbound(string sha)
    {
        var f = new Fixture();
        f.Env["GITHUB_SHA"] = f.Env["GITHUB_WORKFLOW_SHA"] = sha;
        f.Env["HQW_QUIET_PUSH"] = $"{Repo}|true|false|{Ref}|{sha}|false";
        f.ExpectDenied("runner-not-authorized", 0);
    }

    [Theory]
    [InlineData(0, "example/hermes-hq-windows")]
    [InlineData(1, "false")]
    [InlineData(1, "null")]
    [InlineData(2, "true")]
    [InlineData(3, "refs/heads/main")]
    [InlineData(4, "fedcba9876543210fedcba9876543210fedcba98")]
    [InlineData(5, "true")]
    public void PushEventThatDisagreesWithRunnerOrPrivateFlagIsNotAuthority(int index, string wrong)
    {
        var f = new Fixture(); var fields = f.Env["HQW_QUIET_PUSH"]!.Split('|'); fields[index] = wrong;
        f.Env["HQW_QUIET_PUSH"] = string.Join('|', fields);
        f.ExpectDenied("runner-not-authorized", 0);
    }

    [Fact]
    public void ActionsFlagByItselfOrExactJobWithoutRealActiveWalkIsInsufficient()
    {
        var bare = new Fixture(); bare.Env.Clear(); bare.Env["GITHUB_ACTIONS"] = "true";
        bare.ExpectDenied("runner-not-authorized", 0);
        foreach (var change in new Action<Fixture>[] {
            f => f.Walk = "settings-file", f => f.Extra["tag"] = "questions", f => f.Extra.Remove("url"),
            f => f.Extra["walks"] = new JsonArray("toasts", "toasts"), f => f.Extra["walks"] = "toasts",
            f => f.Extra["places"] = new JsonArray("tasks"), f => f.Extra.Remove("places"),
            f => f.Extra["username"] = "other-fixture", f => f.LiveUser = "other-fixture",
            f => f.Current = new object(), f => f.Current = null, f => f.Bound = f.Current = null,
            f => f.Pending = 1, f => f.Pending = null, f => f.Config["extrasOnly"] = true,
            f => f.Config["extrasOnly"] = "false", f => f.Config["url"] = "http://localhost:9711",
            f => f.Extras.Remove(f.Extra), f => f.Extras.Add(new JsonObject { ["tag"] = "later" }),
            f => f.Extras.Insert(0, f.Extra.DeepClone()), f => f.Extras[0]!["tag"] = "toasts",
            f => f.Extras[0]!["url"] = Url, f => f.Extras[0]!["walks"] = new JsonArray("toasts"),
            f => f.Extras[0]!["url"] = Url + "/", f => f.Extras[0]!["url"] = "http://localhost:9736",
            f => f.Extras[0]!["url"] = "http://example.com:9736", f => f.Extras[0]!["walks"] = new JsonArray(42),
        })
        {
            var f = new Fixture(); change(f); f.ExpectDenied("not-reply-walk", 1);
        }
    }

    [Theory]
    [InlineData("http://localhost:9736")]
    [InlineData("http://127.0.0.1:9730")]
    [InlineData("http://127.0.0.1:9736/")]
    [InlineData("http://127.0.0.1:9736?extra")]
    [InlineData("http://fixture@127.0.0.1:9736")]
    [InlineData("https://example.com")]
    public void EitherRawReceiptOrActiveAddressWrongRefusesBeforeFocus(string url)
    {
        var declared = new Fixture(); declared.Extra["url"] = url; declared.ExpectDenied("not-reply-walk", 1);
        var current = new Fixture { LiveUrl = url }; current.ExpectDenied("not-reply-walk", 1);
    }

    [Fact]
    public void UnknownOrAmbiguousForegroundStopsBeforeOsReads()
    {
        foreach (var throws in new[] { false, true })
        {
            var f = new Fixture(); f.Reader.Foreground = false; if (throws) f.Reader.Throws = "foreground";
            Assert.Equal("foreground-unverified", f.Read().Reason);
            Assert.Equal(new[] { "foreground" }, f.Reader.Calls);
        }
    }

    [Theory]
    [InlineData(0)]
    [InlineData(-1)]
    [InlineData(int.MaxValue)]
    public void UndefinedOrDefaultForegroundCannotPublishItsNumericValueOrGrantEntry(int raw)
    {
        var f = new Fixture(); f.Reader.RawForeground = (QuietForeground)raw;
        var stop = StopsBeforeAction(() => f.Bind().Checkpoint(QuietPoint.Entry));
        Assert.Equal("toast-quiet-stop/v1 phase=entry gap=foreground-unverified", stop.StopLine);
        Assert.Equal("fixture-foreground/v1 phase=entry clause=Unreadable", f.Lines[1]);
        Assert.Equal(2, f.Lines.Count); Assert.Equal(new[] { "foreground" }, f.Reader.Calls);
    }

    [Theory]
    [InlineData(-1, 4, 1, 0, "unreadable")]
    [InlineData(0, 0, 1, 0, "unpublished")]
    [InlineData(0, 4, 0, 0, "unpublished")]
    [InlineData(0, 1, 1, 0, "invalid-size")]
    [InlineData(0, 3, 1, 0, "invalid-size")]
    [InlineData(0, 8, 1, 0, "invalid-size")]
    [InlineData(0, 4, 1, 3, "unknown-profile")]
    public void FailedEmptyShortOversizeAndUnknownFocusNeverMeanOff(int status, uint size, uint stamp, uint value, string name)
    {
        var f = new Fixture(); f.Reader.Profile = new(status, size, stamp, value);
        var r = f.Read(); Assert.Equal("focus-unknown", r.Reason); Assert.Contains($"focus={name} ", r.Line);
    }

    [Theory]
    [InlineData(1, "priority-only")]
    [InlineData(2, "alarms-only")]
    public void KnownQuietProfileReportsSuppressionWithoutChangingIt(uint profile, string name)
    {
        var f = new Fixture(); f.Reader.Profile = new(0, 4, 3, profile);
        var expected = f.Reader.Profile;
        var r = f.Read(); Assert.Equal("focus-quiet", r.Reason); Assert.Contains($"focus={name} ", r.Line);
        Assert.Equal(expected, f.Reader.Profile);
    }

    [Theory]
    [InlineData(1, "QUNS_NOT_PRESENT")]
    [InlineData(2, "QUNS_BUSY")]
    [InlineData(3, "QUNS_RUNNING_D3D_FULL_SCREEN")]
    [InlineData(4, "QUNS_PRESENTATION_MODE")]
    [InlineData(6, "QUNS_QUIET_TIME")]
    [InlineData(7, "QUNS_APP")]
    public void NamesTheShellStateRatherThanAssumingEverySuppressionIsDnd(int value, string name)
    {
        var f = new Fixture(); f.Reader.Quns = value;
        var r = f.Read(); Assert.Equal("shell-not-accepting", r.Reason); Assert.Contains($"quns={name} ", r.Line);
    }

    [Theory]
    [InlineData("DisabledForApplication")]
    [InlineData("DisabledForUser")]
    [InlineData("DisabledByGroupPolicy")]
    [InlineData("DisabledByManifest")]
    [InlineData("Unsupported")]
    [InlineData("Unregistered")]
    public void AppSettingIsObservedNotChanged(string setting)
    {
        var f = new Fixture(); f.Reader.Setting = setting;
        var r = f.Read(); Assert.Equal("app-not-enabled", r.Reason); Assert.Contains($"app={setting} ", r.Line);
    }

    [Fact]
    public void CompleteNonBlockingSampleIsStillNotABannerOrAnActivation()
    {
        var f = new Fixture();
        Assert.Equal($"toast-quiet/v1 run=28.2 sha={Sha} phase=before-first quns=QUNS_ACCEPTS_NOTIFICATIONS focus=off app=Enabled writes=0 restore=not-needed banner=unverified gap=banner-not-observed", f.Read().Line);
        Assert.Equal(new[] { "foreground", "quns", "focus", "app", "foreground" }, f.Reader.Calls);
        f.Reader.Profile = new(0, 4, 2, 1);
        Assert.Equal("focus-quiet", f.Read(QuietPoint.BeforeAway).Reason);
        f.Current = new object(); // a new session with the SAME address and fixture account
        Assert.Equal("not-reply-walk", f.Read(QuietPoint.AfterAway).Reason);
        Assert.Equal(5, f.ContextReads);
        Assert.Equal(2, f.Reader.Calls.Count(x => x == "focus"));
    }

    [Theory]
    [InlineData("session")]
    [InlineData("foreground")]
    [InlineData("runner")]
    public void ChangedContextDuringReadDiscardsValuesAndStopsWithoutRetry(string lost)
    {
        var f = new Fixture(); var quiet = f.Bind();
        f.Reader.AfterSetting = () => {
            if (lost == "session") f.Current = new object(); else if (lost == "runner") f.Env.Remove("HQW_QUIET_PUSH"); else f.Reader.Foreground = false;
        };
        Assert.Equal("sample-context-lost", StopsBeforeAction(() => quiet.Checkpoint(QuietPoint.Entry)).Message);
        Assert.Contains("quns=discarded focus=discarded app=discarded", f.Lines[0]);
        if (lost == "foreground") Assert.Equal(new[] { "fixture-foreground/v1 phase=entry clause=ComposerNotFocused" }, f.Lines.Skip(1));
        else Assert.Single(f.Lines);
        Assert.Single(f.Reader.Calls, c => c == "focus");
    }

    [Fact]
    public void AfterReadUsesCurrentStateNotAnInventedRestoreOrPreviouslyAuthorizedRun()
    {
        var f = new Fixture(); f.Reader.Quns = 6;
        Assert.Equal("shell-not-accepting", f.Read(QuietPoint.BeforeAway).Reason);
        f.Reader.Quns = 5; f.Reader.Setting = "DisabledForUser";
        var r = f.Read(QuietPoint.AfterAway);
        Assert.Contains("phase=after-away quns=QUNS_ACCEPTS_NOTIFICATIONS focus=off app=DisabledForUser writes=0 restore=not-needed banner=unverified gap=app-not-enabled", r.Line);
        f.Env.Remove("HQW_DESKTOP_PROOF");
        Assert.Contains("run=unbound sha=unbound", f.Read(QuietPoint.AfterAway).Line);
        Assert.Equal(2, f.Reader.Calls.Count(c => c == "quns"));
    }

    [Fact]
    public void InvalidCheckpointAndUnreadableDispatchReturnRedactedGaps()
    {
        var f = new Fixture(); Assert.Equal("invalid-phase", f.Read((QuietPoint)99).Reason);
        Assert.Equal(0, f.ContextReads);
        var r = new ToastQuietProbe(true, k => f.Env.GetValueOrDefault(k),
            _ => throw new InvalidOperationException("fixture-private-canary"), f.Reader, f.Lines.Add).Read(QuietPoint.BeforeFirst);
        Assert.Equal("not-reply-walk", r.Reason); Assert.DoesNotContain("canary", r.Line); Assert.Empty(f.Reader.Calls);
    }

    [Fact]
    public void UnreadableOrUnrecognizedReadbacksDoNotLeakMessagesOrBecomeSuccess()
    {
        foreach (var (name, reason) in new[] { ("quns", "shell-state-unknown"), ("focus", "focus-unknown"), ("app", "app-setting-unknown") })
        {
            var f = new Fixture(); f.Reader.Throws = name;
            var r = f.Read(); Assert.Equal(reason, r.Reason); Assert.DoesNotContain("canary", r.Line);
        }
        var unknown = new Fixture(); unknown.Reader.Setting = "fixture-private-canary\nShown";
        var u = unknown.Read(); Assert.Equal("app-setting-unknown", u.Reason); Assert.DoesNotContain("canary", u.Line);
        unknown.Reader.Setting = "Enabled"; unknown.Reader.Quns = 99;
        Assert.Equal("shell-state-unknown", unknown.Read().Reason);
        unknown.Reader.Profile = null; Assert.Equal("focus-unknown", unknown.Read().Reason);
    }
}
