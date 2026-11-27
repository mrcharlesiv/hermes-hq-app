// [WIN-SCREEN-SETUP-SEND] "Set up with Hermes" end to end over the app's seams (App/Screen/AppModel+Screen.swift at
// 93f984bb1, `requestScreenSetup` and `runScreenSetup`). The Mac has no unit test of these; its
// UITests/screen/ScreenEndToEndTests.swift test14_setupCardRequestCheckAndAutoOpen walks them on a simulator, and each
// of its steps is a case here: a refused attach is an alert over the bot's chat with nothing sent, a failed request is
// not a requested one, the request closes the Screen and opens the chat, attaches the installer once and sends the
// prompt with its three installer lines, and a reopened card says "Continue with Hermes". The rest are the Swift's
// branches one by one (not connected, chat did not open, already queued, already submitted, changed before start,
// not queued, an unexpected throw). Fakes only.

using Hermes.Core.Screen;

namespace Hermes.Core.Tests.Screen;

public sealed class ScreenSetupRequestTests
{
    private sealed class FakeChat(string profile, bool botChat = true) : IScreenSetupChat
    {
        public object Session { get; set; } = new();
        public string Profile { get; } = profile;
        public bool IsBotChat { get; } = botChat;
        public string? RuntimeId { get; set; } = "rt-1";
        public bool HasQueuedSetup { get; set; }
        public List<(string Name, string DataUrl)> Attached { get; } = [];
        public List<(string RefText, ScreenSetupBundle Bundle)> Sent { get; } = [];
        public Func<Task<(string, string)>>? OnAttach { get; set; }
        public Action? OnSend { get; set; }

        public async Task<(string RefText, string Runtime)> AttachAsync(string name, string dataUrl)
        {
            Attached.Add((name, dataUrl));
            if (OnAttach != null) return await OnAttach();
            return ("@file:/tmp/fixture/hermes-hq-screen-setup.zip", RuntimeId!);
        }

        public void Send(string refText, ScreenSetupBundle bundle)
        {
            OnSend?.Invoke();
            Sent.Add((refText, bundle));
        }
    }

    private sealed class FakeHost : IScreenSetupHost
    {
        public string? AccountId { get; set; } = "acct-1";
        public IScreenSetupChat? Pane { get; set; }
        /// What OpenBotChat puts in the pane (after `ShowsAfter` more looks).
        public IScreenSetupChat? Opens { get; set; }
        public int ShowsAfter { get; set; }
        public List<string> Steps { get; } = [];
        public List<(ScreenSetupError Failure, IScreenSetupChat? Chat)> Failures { get; } = [];
        public List<string> Notes { get; } = [];
        public Func<Task<ScreenSetupBundle>> Bundle { get; set; } = () => Task.FromResult(Synthetic);
        public int Looks;
        private int _openedAt = -1;

        public Task CloseCoversAsync() { Steps.Add("close"); return Task.CompletedTask; }

        public IScreenSetupChat? OpenChat()
        {
            Looks++;
            if (_openedAt >= 0 && Looks - _openedAt > ShowsAfter) { Pane = Opens; _openedAt = -1; }
            return Pane;
        }

        public void OpenBotChat(string profile)
        {
            Steps.Add("open " + profile);
            _openedAt = Looks;
        }

        public IDisposable? ShowOpening(IScreenSetupChat chat) { Steps.Add("opening"); return new Hud(Steps); }
        private sealed class Hud(List<string> steps) : IDisposable { public void Dispose() => steps.Add("opening gone"); }

        public void Failed(ScreenSetupError failure, IScreenSetupChat? chat) { Steps.Add("alert"); Failures.Add((failure, chat)); }
        public Task<ScreenSetupBundle> LoadBundleAsync() => Bundle();
        public void Note(string line) => Notes.Add(line);
    }

    private static readonly ScreenSetupBundle Synthetic = new(ScreenSetupBundle.Filename, "data:application/zip;base64,UEsDBA==",
        ScreenSetupBundle.ExpectedSha256, ScreenSetupBundle.HelperAppPath);

    /// A requester that counts its looks instead of sleeping (the app looks 200 times, 50 ms apart: 10 s).
    private static ScreenSetupRequester Requester(FakeHost host, ScreenSetupLedger ledger) =>
        new(host, ledger) { Sleep = _ => Task.CompletedTask };

    [Fact]
    public async Task SignedOutIsNotConnectedAndNothingCloses()
    {
        var host = new FakeHost { AccountId = null };
        var failure = await Requester(host, new()).RequestAsync("otto", resume: false);
        Assert.Equal(new ScreenSetupError(ScreenSetupFailure.NotConnected), failure);
        Assert.Equal("This bot’s gateway is no longer connected.", failure!.Message);
        Assert.Empty(host.Steps);
        Assert.Equal(new ScreenSetupError(ScreenSetupFailure.NotConnected), await Requester(host, new()).RunAsync("otto", false));
    }

    // test14: "The request: the installer attached once, then the prompt with its three installer lines."
    [Fact]
    public async Task TheRequestClosesTheScreenOpensTheBotsChatAttachesOnceAndSends()
    {
        var chat = new FakeChat("otto");
        var host = new FakeHost { Opens = chat, ShowsAfter = 3 };
        var ledger = new ScreenSetupLedger();

        var failure = await Requester(host, ledger).RequestAsync("otto", resume: false);

        Assert.Null(failure);
        Assert.Equal(["close", "open otto", "opening", "opening gone"], host.Steps);
        var (name, dataUrl) = Assert.Single(chat.Attached);
        Assert.Equal("hermes-hq-screen-setup.zip", name);
        Assert.StartsWith("data:application/zip;base64,", dataUrl, StringComparison.Ordinal);
        var sent = Assert.Single(chat.Sent);
        Assert.Equal("@file:/tmp/fixture/hermes-hq-screen-setup.zip", sent.RefText);
        Assert.Equal(Synthetic, sent.Bundle);
        Assert.True(ledger.Submitted(ScreenSetupLedger.Key("acct-1", "otto")));
        Assert.Equal(["setup requested"], host.Notes);
        Assert.Empty(host.Failures);
    }

    [Fact]
    public async Task TheBotsChatAlreadyOpenIsUsedAsItIs()
    {
        var chat = new FakeChat("otto");
        var host = new FakeHost { Pane = chat };
        Assert.Null(await Requester(host, new()).RequestAsync("otto", false));
        Assert.Equal(["close", "opening", "opening gone"], host.Steps);
        Assert.Single(chat.Sent);
    }

    [Fact]
    public async Task AnotherBotsChatOrOneOfThisBotsSessionsIsNotTheBotsChat()
    {
        foreach (var other in new[] { new FakeChat("ivy"), new FakeChat("otto", botChat: false) })
        {
            var chat = new FakeChat("otto");
            var host = new FakeHost { Pane = other, Opens = chat };
            Assert.Null(await Requester(host, new()).RequestAsync("otto", false));
            Assert.Contains("open otto", host.Steps);
            Assert.Empty(other.Attached);
            Assert.Single(chat.Sent);
        }
    }

    [Fact]
    public async Task AChatThatNeverOpensIsSaidOverTheBotsAfterTenSecondsOfLooking()
    {
        var host = new FakeHost();
        var slept = TimeSpan.Zero;
        var requester = new ScreenSetupRequester(host, new()) { Sleep = t => { slept += t; return Task.CompletedTask; } };
        Assert.Null(await requester.RequestAsync("otto", false));   // said as an alert, not on the card
        var (failure, on) = Assert.Single(host.Failures);
        Assert.Equal(new ScreenSetupError(ScreenSetupFailure.ChatDidNotOpen), failure);
        Assert.Equal("Hermes could not open this bot’s chat. Try again.", failure.Message);
        Assert.Null(on);
        Assert.Equal(TimeSpan.FromSeconds(10), slept);
        Assert.Equal(["setup failed"], host.Notes);
        Assert.DoesNotContain("opening", host.Steps);
    }

    // test14: "A refused attach: an alert on the chat, nothing queued." and "a failed request is not a requested one".
    [Fact]
    public async Task ARefusedAttachIsAnAlertOverTheChatWithNothingSentAndNotRequested()
    {
        var chat = new FakeChat("otto")
        {
            OnAttach = () => throw new ScreenSetupError(ScreenSetupFailure.Installer, "No space left on the gateway"),
        };
        var host = new FakeHost { Pane = chat };
        var ledger = new ScreenSetupLedger();
        Assert.Null(await Requester(host, ledger).RequestAsync("otto", false));
        var (failure, on) = Assert.Single(host.Failures);
        Assert.Same(chat, on);
        Assert.Equal("No space left on the gateway", failure.Message);
        var alert = ScreenInfoRowWords.SetupFailed(failure);
        Assert.Equal(("Couldn’t Start Screen Setup", "No space left on the gateway", "OK"), alert);
        Assert.Empty(chat.Sent);
        Assert.False(ledger.Requested(ScreenSetupLedger.Key("acct-1", "otto")));
        // The HUD is gone before the alert shows.
        Assert.Equal(["close", "opening", "opening gone", "alert"], host.Steps);
    }

    [Fact]
    public async Task AMissingInstallerIsTheInstallerLineAndNothingIsAttached()
    {
        var chat = new FakeChat("otto");
        var nowhere = Path.Combine(Path.GetTempPath(), $"hq-no-installer-{Guid.NewGuid():N}", ScreenSetupBundle.Filename);
        var host = new FakeHost { Pane = chat, Bundle = () => ScreenSetupBundle.Load(nowhere) };
        Assert.Null(await Requester(host, new()).RequestAsync("otto", false));
        Assert.Equal("Hermes could not receive the Mac screen installer. Try again.", Assert.Single(host.Failures).Failure.Message);
        Assert.Empty(chat.Attached);
    }

    [Fact]
    public async Task AQueuedRequestIsNotAttachedAgainAndCountsAsRequested()
    {
        var chat = new FakeChat("otto") { HasQueuedSetup = true };
        var host = new FakeHost { Pane = chat };
        var ledger = new ScreenSetupLedger();
        Assert.Null(await Requester(host, ledger).RequestAsync("otto", resume: true));
        Assert.Empty(chat.Attached);
        Assert.Empty(host.Failures);
        Assert.True(ledger.Submitted(ScreenSetupLedger.Key("acct-1", "otto")));
        Assert.DoesNotContain("opening", host.Steps);
    }

    // test14: "Reopened: Continue with Hermes" — a submitted request is sent again only when it is being continued.
    [Fact]
    public async Task ASubmittedRequestGoesAgainOnlyWhenContinued()
    {
        var chat = new FakeChat("otto");
        var host = new FakeHost { Pane = chat };
        var ledger = new ScreenSetupLedger();
        var key = ScreenSetupLedger.Key("acct-1", "otto");
        ledger.MarkSubmitted(key);
        Assert.Null(await Requester(host, ledger).RequestAsync("otto", resume: false));
        Assert.Empty(chat.Attached);
        Assert.Null(await Requester(host, ledger).RequestAsync("otto", resume: true));
        Assert.Single(chat.Attached);
        Assert.Single(chat.Sent);
    }

    [Fact]
    public async Task AChatThatChangedDuringTheAttachIsRefusedBeforeTheSend()
    {
        // The pane moved to another chat object, or the same chat rebound to a new runtime, while the file went up.
        var moved = new FakeChat("otto");
        var host = new FakeHost { Pane = moved };
        moved.OnAttach = () => { host.Pane = new FakeChat("otto"); return Task.FromResult(("@file:/h/x.zip", "rt-1")); };
        Assert.Null(await Requester(host, new()).RequestAsync("otto", false));
        Assert.Equal(new ScreenSetupError(ScreenSetupFailure.ChangedBeforeStart), Assert.Single(host.Failures).Failure);
        Assert.Empty(moved.Sent);

        var rebound = new FakeChat("otto");
        var host2 = new FakeHost { Pane = rebound };
        rebound.OnAttach = () => { rebound.RuntimeId = "rt-9"; return Task.FromResult(("@file:/h/x.zip", "rt-1")); };
        Assert.Null(await Requester(host2, new()).RequestAsync("otto", false));
        var failure = Assert.Single(host2.Failures).Failure;
        Assert.Equal("The chat connection changed before setup could start. Try again.", failure.Message);
        Assert.Empty(rebound.Sent);
    }

    [Fact]
    public async Task ARequestNeitherSentNorQueuedIsSaidAndNotRequested()
    {
        var chat = new FakeChat("otto") { OnSend = () => throw new ScreenSetupError(ScreenSetupFailure.NotQueued) };
        var host = new FakeHost { Pane = chat };
        var ledger = new ScreenSetupLedger();
        Assert.Null(await Requester(host, ledger).RequestAsync("otto", false));
        Assert.Equal("Hermes could not queue the setup request in this chat. Try again.", Assert.Single(host.Failures).Failure.Message);
        Assert.False(ledger.Submitted(ScreenSetupLedger.Key("acct-1", "otto")));
    }

    [Fact]
    public async Task AnUnexpectedThrowIsTheInstallerLine()
    {
        var chat = new FakeChat("otto") { OnAttach = () => throw new InvalidOperationException("synthetic") };
        var host = new FakeHost { Pane = chat };
        Assert.Null(await Requester(host, new()).RequestAsync("otto", false));
        Assert.Equal(new ScreenSetupError(ScreenSetupFailure.Installer), Assert.Single(host.Failures).Failure);
        Assert.Contains("opening gone", host.Steps);
    }

    [Fact]
    public async Task ASecondTapWhileTheFirstRunsJoinsIt()
    {
        var gate = new TaskCompletionSource<(string, string)>();
        var chat = new FakeChat("otto") { OnAttach = () => gate.Task };
        var host = new FakeHost { Pane = chat };
        var ledger = new ScreenSetupLedger();
        var requester = Requester(host, ledger);
        var first = requester.RequestAsync("otto", false);
        var second = requester.RequestAsync("otto", false);
        Assert.True(ledger.InFlight(ScreenSetupLedger.Key("acct-1", "otto")));
        Assert.True(ledger.Requested(ScreenSetupLedger.Key("acct-1", "otto")));
        gate.SetResult(("@file:/h/x.zip", "rt-1"));
        Assert.Null(await first);
        Assert.Null(await second);
        Assert.Single(chat.Attached);
        Assert.False(ledger.InFlight(ScreenSetupLedger.Key("acct-1", "otto")));
    }

    // The app's wiring: the viewer the ledger configures asks through the requester's unledgered run, once.
    [Fact]
    public async Task TheLedgersViewerRunsTheRequestOnceThroughTheRequester()
    {
        var chat = new FakeChat("otto");
        var host = new FakeHost { Pane = chat };
        var ledger = new ScreenSetupLedger();
        var requester = Requester(host, ledger);
        Func<bool, Task<ScreenSetupError?>> request = resume => requester.RunAsync("otto", resume);
        var key = ScreenSetupLedger.Key("acct-1", "otto");
        var answer = await ledger.Request(key, () => request(false)).WaitAsync(TimeSpan.FromSeconds(10));
        Assert.Null(answer);
        Assert.Single(chat.Sent);
        Assert.True(ledger.Requested(key));
    }
}
