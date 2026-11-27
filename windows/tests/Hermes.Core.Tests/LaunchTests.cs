using System.Text.Json.Nodes;
using Hermes.Core.Gateways;
using Hermes.Core.Net;
using Hermes.Core.Offline;
using Hermes.Core.Onboarding;

namespace Hermes.Core.Tests;

/// The launch-chat decision, the launch screen's machine, the offline screen's words and the onboarding flow's rules
/// (HermesKit/Store/LaunchChatMemory.swift, HermesKit/Offline/*, App/Onboarding/*).
public class LaunchChatTests
{
    private static readonly RememberedChat BotChat = new(RememberedChat.Bots, "mail", null, true);
    private static readonly RememberedChat Listed = new(RememberedChat.Sessions, "default", "20261121_1", false);

    private static LaunchChatDecision D(RememberedChat? chat, bool crashed = false, bool resume = true, bool bot = true, bool listed = true) =>
        LaunchChatDecision.Decide(chat, crashed, resume, _ => bot, (_, _) => listed);

    [Fact]
    public void ReopensOnlyWhatIsStillThere()
    {
        Assert.Equal(LaunchChatDecision.Nothing, D(null).Skip);
        Assert.Equal(LaunchChatDecision.Crashed, D(BotChat, crashed: true).Skip);
        Assert.Equal(LaunchChatDecision.ResumeOff, D(BotChat, resume: false).Skip);
        Assert.Equal(BotChat, D(BotChat).Reopen);
        Assert.Equal(LaunchChatDecision.BotGone, D(BotChat, bot: false).Skip);
        Assert.Equal(Listed, D(Listed, bot: false).Reopen); // a listed chat is checked by its listing, not its bot
        Assert.Equal(LaunchChatDecision.SessionGone, D(Listed, listed: false).Skip);
        Assert.Equal(LaunchChatDecision.SessionGone, D(Listed with { StoredId = null }).Skip);
    }

    [Fact]
    public void MemoryDropsAChatThatWasOnScreenWhenTheRunEnded()
    {
        var path = Path.Combine(Path.GetTempPath(), $"hq-launch-{Guid.NewGuid():N}.json");
        try
        {
            var first = new LaunchChatMemory(path);
            first.Launch();
            first.Remember(BotChat, "other", foreground: false);
            first.Remember(Listed, "acct", foreground: true);
            // The run ends without Closed (a crash): the chat on screen isn't reopened next time.
            var second = new LaunchChatMemory(path);
            second.Launch();
            Assert.Null(second.Recall("acct"));
            Assert.True(second.CrashedFor("acct"));
            Assert.Equal(BotChat, second.Recall("other"));
            second.Remember(Listed, "acct", foreground: true);
            second.Closed();
            var third = new LaunchChatMemory(path);
            third.Launch();
            Assert.Equal(Listed, third.Recall("acct"));
            Assert.False(third.CrashedFor("acct"));
            Assert.True(third.Resume("acct"));
            third.SetResume(false, "acct");
            Assert.False(new LaunchChatMemory(path).Resume("acct"));
            third.Forget("acct");
            Assert.Null(third.Recall("acct"));
            Assert.True(third.Resume("acct"));
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void OnlyFalseTurnsReopenOff()
    {
        Assert.False(LaunchChatMemory.ResumeFrom(JsonNode.Parse("""{"display":{"resume_last_session":false}}""")));
        Assert.True(LaunchChatMemory.ResumeFrom(JsonNode.Parse("""{"display":{"resume_last_session":true}}""")));
        Assert.True(LaunchChatMemory.ResumeFrom(JsonNode.Parse("""{"display":{"resume_last_session":"false"}}""")));
        Assert.True(LaunchChatMemory.ResumeFrom(JsonNode.Parse("{}")));
        Assert.True(LaunchChatMemory.ResumeFrom(null));
    }
}

public class LaunchGateTests
{
    private static (LaunchGate, ManualClock, List<LaunchGate.View>, Func<LaunchBlocker?> get, Action<LaunchBlocker?> set) Gate()
    {
        var clock = new ManualClock();
        LaunchBlocker? blocker = LaunchBlocker.Cover;
        var views = new List<LaunchGate.View>();
        var gate = new LaunchGate(clock, () => blocker, views.Add);
        return (gate, clock, views, () => blocker, b => blocker = b);
    }

    [Fact]
    public void IconThenSpinnerThenCaptionThenTheUsualCause()
    {
        var (gate, clock, _, _, _) = Gate();
        Assert.Equal(new LaunchGate.View(), gate.Current);
        clock.Advance(TimeSpan.FromSeconds(0.8));
        Assert.False(gate.Current.Spinner);
        clock.Advance(TimeSpan.FromSeconds(0.2));
        Assert.True(gate.Current.Spinner);
        clock.Advance(TimeSpan.FromSeconds(3));
        Assert.Equal("Connecting to Hermes…", gate.Current.Status);
        clock.Advance(TimeSpan.FromSeconds(8));
        Assert.Equal("Still connecting. Check that the computer running Hermes is on and awake.", gate.Current.Status);
        Assert.True(gate.Current.Actions);
        gate.Retry();
        Assert.Equal("Connecting to Hermes…", gate.Current.Status);
        Assert.False(gate.Current.Actions);
    }

    [Fact]
    public void LeavesOnceConnectedWithContentOrAfterFiveSecondsOfLoading()
    {
        var (gate, clock, _, _, set) = Gate();
        gate.Mount();
        clock.Advance(TimeSpan.FromSeconds(2));
        set(LaunchBlocker.Loading);
        gate.Check();
        clock.Advance(TimeSpan.FromSeconds(2.5));
        Assert.Equal("Loading…", gate.Current.Status);
        Assert.Equal(LaunchGate.Phase.Shown, gate.Current.Phase);
        clock.Advance(TimeSpan.FromSeconds(2.6)); // 5 s since the gateway opened, then the 0.1 s settle
        Assert.Equal(LaunchGate.Phase.Leaving, gate.Current.Phase);
        clock.Advance(TimeSpan.FromSeconds(0.2));
        Assert.Equal(LaunchGate.Phase.Gone, gate.Current.Phase);

        var (quick, qclock, _, _, qset) = Gate();
        quick.Mount();
        qset(null);
        quick.Check();
        qclock.Advance(TimeSpan.FromSeconds(0.11));
        Assert.Equal(LaunchGate.Phase.Leaving, quick.Current.Phase);
    }

    [Fact]
    public void AFailureStopsTheTimersUntilTryAgain()
    {
        var (gate, clock, _, _, _) = Gate();
        gate.Fail(StartupProblems.CouldNotStart);
        Assert.Equal("Hermes HQ couldn’t start. Click Try Again.", gate.Current.Status);
        Assert.True(gate.HasFailed);
        clock.Advance(TimeSpan.FromSeconds(20));
        Assert.Equal("Hermes HQ couldn’t start. Click Try Again.", gate.Current.Status);
        gate.Mount();
        Assert.False(gate.HasFailed);
        Assert.Equal("Still connecting. Your Nous agent may be stopped or still starting.", LaunchGate.StatusWords.StalledFor(true, nous: true));
    }
}

public class OfflineCopyTests
{
    [Fact]
    public void ScreensByReason()
    {
        Assert.Equal("Hermes Isn’t Answering", OfflineCopy.ScreenFor("timeout", true).Title);
        Assert.Equal(OfflineCopy.NousRecovery, OfflineCopy.ScreenFor("timeout", true, nous: true).Recovery);
        Assert.Equal(new OfflineCopy.Screen(OfflineCopy.DefaultTitle, OfflineCopy.DefaultRecovery), OfflineCopy.ScreenFor("unreachable", true));
        Assert.Equal("Click Try Again to recover your saved connection before changing sign-in. Your local drafts are being kept.",
            OfflineCopy.ScreenFor(null, false).Recovery);
        Assert.Equal("Can’t Open Your Saved Sign-In", OfflineCopy.ScreenFor("keychain-unavailable", false).Title);
        Assert.True(OfflineCopy.NousHosted(new Uri("https://abc.agents.nousresearch.com")));
    }

    [Fact]
    public void TheCardNamesTheGatewayNeverAnAddressInASentence()
    {
        Assert.Equal(new OfflineCopy.Card("Studio", "studio.tail1.ts.net · qa"),
            OfflineCopy.CardFor("timeout", new Uri("https://studio.tail1.ts.net"), null, "qa"));
        Assert.Equal(new OfflineCopy.Card("The computer running Hermes", "100.64.0.9:9119 · Nous account"),
            OfflineCopy.CardFor(null, new Uri("http://100.64.0.9:9119"), null, "Nous account"));
        Assert.Equal("Home", OfflineCopy.CardFor(null, new Uri("http://100.64.0.9:9119"), " Home ", "qa")!.Name);
        Assert.Null(OfflineCopy.CardFor("keychain-locked", null, null, null));
        Assert.Null(OfflineCopy.CardFor("keychain-unreadable", null, null, null));
        Assert.Equal(new OfflineCopy.Card(OfflineCopy.UnnamedCard, OfflineCopy.UnreadableDetail), OfflineCopy.CardFor(null, null, null, null));
        Assert.True(OfflineCopy.ShowsSignInAgain("keychain-unreadable"));
        Assert.False(OfflineCopy.ShowsSignInAgain("keychain-unavailable", 2));
        Assert.True(OfflineCopy.ShowsSignInAgain("keychain-unavailable", 3));
    }

    [Fact]
    public void CountdownAndLadder()
    {
        Assert.Equal("Trying Again in 3 s", OfflineCopy.Countdown(TimeSpan.FromSeconds(2.1)));
        Assert.Equal("Trying Again in 1 s", OfflineCopy.Countdown(TimeSpan.Zero));
        Assert.Equal([3, 6, 12, 24, 30, 30], Enumerable.Range(0, 6).Select(i => RetryLadder.Wait(i).TotalSeconds));
        Assert.Equal(TimeSpan.FromSeconds(50), RetryLadder.Wait(0, TimeSpan.FromSeconds(50)));
        Assert.Equal(TimeSpan.FromSeconds(120), RetryLadder.Wait(0, TimeSpan.FromSeconds(500)));
        Assert.Equal(TimeSpan.FromSeconds(3), RetryLadder.Wait(0, TimeSpan.FromSeconds(-1)));
    }

    [Fact]
    public void StatusLineAndWhatNarratorHears()
    {
        var m = new OfflineScreenModel { Reason = "timeout", Url = new Uri("https://studio.tail1.ts.net") };
        var now = DateTimeOffset.UnixEpoch;
        m.SetStatus(now + TimeSpan.FromSeconds(6), connecting: false);
        Assert.Equal("Trying Again in 6 s", m.StatusText(now));
        Assert.Equal("Trying Again in 2 s", m.StatusText(now + TimeSpan.FromSeconds(4.5)));
        Assert.Equal(OfflineCopy.RetryingSpoken, m.SpokenStatus);
        m.SetStatus(null, connecting: true);
        Assert.Equal("Connecting…", m.StatusText(now));
        Assert.False(m.TryAgainEnabled);
        m.SetStatus(now + TimeSpan.FromSeconds(12), connecting: false);
        Assert.Equal(["Trying again automatically", "Connecting…", "Trying again automatically"], m.Announced);
        m.Problem = StartupProblems.Storage;
        Assert.Equal(StartupProblems.Storage, m.StatusText(now));
        var network = new OfflineScreenModel { Reason = "network" };
        Assert.Equal("Waiting for a connection…", network.StatusText(now));
    }

    [Fact]
    public void HeaderAndReconnectWords()
    {
        Assert.Null(HeaderLink.Words(Rpc.ConnectionState.Open, true, null));
        Assert.Null(HeaderLink.Words(Rpc.ConnectionState.Connecting, false, null));
        Assert.Equal("Reconnecting…", HeaderLink.Words(Rpc.ConnectionState.Offline, true, TimeSpan.FromSeconds(30)));
        Assert.Equal("Offline", HeaderLink.Words(Rpc.ConnectionState.Offline, true, TimeSpan.FromSeconds(121)));
        Assert.Equal("Signed Out", HeaderLink.Words(Rpc.ConnectionState.SignedOut, true, null));
        Assert.Equal("Reconnecting to the computer running Hermes…", ReconnectNotice.Text(false, "timeout", failed: false));
        Assert.Equal("The computer running Hermes is slow to answer — still trying…", ReconnectNotice.Text(false, "timeout"));
        Assert.Equal("Can’t reach the computer running Hermes. Check your network or VPN connection. Reconnecting…", ReconnectNotice.Text(false, "unreachable"));
        Assert.Equal("Can’t reach the computer running Hermes. Check your network or VPN connection. Hermes HQ keeps trying.",
            ReconnectNotice.Text(false, null, offline: true));
        Assert.Equal(ReconnectNotice.NetworkDown, ReconnectNotice.Text(true));
    }
}

public class OnboardingTests
{
    [Fact]
    public void FirstRunsStartOnTheWelcomeReturningOnesOnTheForm()
    {
        Assert.Equal(OnboardingGate.Entry.Welcome, OnboardingGate.EntryFor(null, null, null, false));
        Assert.Equal(OnboardingGate.Entry.Form, OnboardingGate.EntryFor(null, "https://a", null, false));
        Assert.Equal(OnboardingGate.Entry.Form, OnboardingGate.EntryFor(null, " ", "Sign in again.", false));
        Assert.Equal(OnboardingGate.Entry.Form, OnboardingGate.EntryFor(null, null, null, true));
        Assert.Equal(OnboardingGate.Entry.Welcome, OnboardingGate.EntryFor("  ", "", "", false));
    }

    [Fact]
    public void TheStackPushesPopsToAKnownStepAndHoldsWhileBusy()
    {
        var s = new OnboardingStack(root: true, OnboardingGate.Entry.Welcome);
        Assert.Equal([OnboardingStep.Welcome], s.Steps);
        Assert.True(s.Go(OnboardingStep.Start, out _));
        Assert.True(s.Go(OnboardingStep.Hermes, out _));
        Assert.Equal(OnboardingStep.Hermes, s.HelpStep); // the message was seen: help goes back to it
        Assert.True(s.Go(OnboardingStep.Where, out _));
        Assert.True(s.Go(OnboardingStep.Mac1, out _));
        Assert.True(s.Go(OnboardingStep.Connect, out _));
        Assert.False(s.Go(OnboardingStep.Connect, out _)); // the step on show
        Assert.True(s.Go(OnboardingStep.Hermes, out var leftForm)); // on the stack: pops to it
        Assert.True(leftForm);
        Assert.Equal([OnboardingStep.Welcome, OnboardingStep.Start, OnboardingStep.Hermes], s.Steps);
        s.Busy = true;
        Assert.False(s.Go(OnboardingStep.Where, out _));
        Assert.False(s.Back());
        s.Busy = false;
        Assert.True(s.Back());
        Assert.Equal(OnboardingStep.Start, s.Current);

        var sheet = new OnboardingStack(root: false, OnboardingGate.Entry.Welcome);
        Assert.Equal([OnboardingStep.Connect], sheet.Steps);
        Assert.False(sheet.CanGoBack);
        Assert.Equal(OnboardingStep.Start, sheet.HelpStep);
        var returning = new OnboardingStack(root: true, OnboardingGate.Entry.Form);
        Assert.Equal([OnboardingStep.Welcome, OnboardingStep.Connect], returning.Steps);
        Assert.Equal("Step 2 of 3", OnboardingStack.Eyebrow(OnboardingStep.Linux2));
        Assert.Equal("Without Hermes’s help", OnboardingStack.Eyebrow(OnboardingStep.Manual));
    }

    [Fact]
    public void GuideMarkupAndWords()
    {
        var spans = GuideText.Parse("Open **Terminal**: press [[⌘ Space]], type `hermes serve` (<<guide|https://x.example>>).");
        Assert.Equal([GuideText.Kind.Plain, GuideText.Kind.Bold, GuideText.Kind.Plain, GuideText.Kind.Key, GuideText.Kind.Plain,
            GuideText.Kind.Code, GuideText.Kind.Plain, GuideText.Kind.Link, GuideText.Kind.Plain], spans.Select(s => s.Kind));
        Assert.Equal("https://x.example", spans[7].Address);
        Assert.Equal("Open Terminal: press ⌘ Space, type hermes serve (guide).", GuideText.Plain(
            "Open **Terminal**: press [[⌘ Space]], type `hermes serve` (<<guide|https://x.example>>)."));
        Assert.Equal("Chat with your agents, see what they’re working on, and get a ping when they’re done, right from your PC.",
            OnboardingCopy.Welcome.Lead);
        Assert.Equal("After you install it, come back here and click **I’ve Installed Hermes**.", OnboardingCopy.GetHermes.After);
        Assert.EndsWith(OnboardingCopy.Setup.Env + "\n\n3. Start Hermes and leave it running:\nhermes dashboard --no-open\n(Restart it whenever you change those lines.)\n\n"
            + "4. In Hermes HQ, enter the address from step 1 and the username and password from step 2.\n\n"
            + "More on sign-in, including a hashed password: https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard\n",
            OnboardingCopy.SetupStepsText);
        Assert.Contains("--agent --private", OnboardingCopy.Tailnet.Prompt);
        Assert.Contains("over Tailscale", OnboardingCopy.Tailnet.Prompt);
        Assert.Equal(OnboardingCopy.Tailnet.Command, OnboardingCopy.Text(OnboardingCopy.FeedbackKind.Connect, tailnetOnly: true));
    }

    [Fact]
    public void QuickSetupWordsChangeForATailnet()
    {
        var mac = OnboardingCopy.QuickFor(OnboardingCopy.QuickKind.Mac);
        Assert.Equal("Get the setup command onto your Mac.", mac.Heading1);
        Assert.Contains("which gives your Mac an address this PC can reach from anywhere", mac.Steps2[2]);
        var tail = OnboardingCopy.QuickFor(OnboardingCopy.QuickKind.Mac, tailnetOnly: true);
        Assert.Contains("**Tailscale**, with the same Tailscale account as this PC", tail.Steps2[2]);
        Assert.EndsWith("Leave Tailscale connected on this PC too: the address works only on your Tailscale network.", tail.Note3);
        var linux = OnboardingCopy.QuickFor(OnboardingCopy.QuickKind.Linux, tailnetOnly: true);
        Assert.Contains("with the same Tailscale account as this PC", linux.Steps2[2]);
        Assert.Equal(7, linux.Troubles.Length);
        Assert.Equal("If the terminal shows a problem", linux.TroubleTitle);
    }

    [Fact]
    public void TheFormsWords()
    {
        Assert.Equal("auth-rejected", SignInCopy.Code(new GatewayException("bad-password", "x", 401)));
        Assert.Equal("auth-rejected", SignInCopy.Code(new GatewayException("http", "x", 403)));
        Assert.Equal("rate-limited", SignInCopy.Code(new GatewayException("http", "x", 429)));
        Assert.Equal("unreachable", SignInCopy.Code(new GatewayException("offline", "Can't reach the gateway. Connection refused")));
        Assert.Equal("tls", SignInCopy.Code(new GatewayException("offline", "Can't reach the gateway. The SSL connection could not be established")));
        Assert.Equal("insecure-url", SignInCopy.Code(new GatewayException("insecure-url", "x")));
        Assert.Equal("gateway-error", SignInCopy.Code(new GatewayException("weird", "x")));
        Assert.Equal("nous-cancelled", SignInCopy.Code(new OperationCanceledException()));
        Assert.Equal("", SignInCopy.Message(new OperationCanceledException()));
        Assert.True(SignInCopy.MarksAddress("unreachable"));
        Assert.True(SignInCopy.MarksPassword("auth-rejected"));
        Assert.Equal(SignInCopy.UnreachableNote, SignInCopy.ProbeNote(Auth.SignIn.Probe.Unknown));
        Assert.Equal(SignInCopy.UnansweredWaysNote, SignInCopy.ProbeNote(Auth.SignIn.Probe.Unknown with { Answered = true }));
        Assert.Null(SignInCopy.ProbeNote(new Auth.SignIn.Probe(true, false, null)));
        Assert.Equal(SignInWays.Nous, SignInWaysExtensions.From(new Auth.SignIn.Probe(true, false, null)));
        Assert.Equal(SignInWays.Both, SignInWaysExtensions.From(Auth.SignIn.Probe.Unknown));
        Assert.Equal("This Hermes uses Nous sign-in. Use the Nous account it was set up with.", SignInCopy.Subtitle(SignInWays.Nous));
        Assert.Equal("Hermes HQ keeps your session in Windows Credential Locker to reconnect. Your password is never stored.", SignInCopy.Footnote(SignInWays.Both));
    }

    [Fact]
    public void PastedAddresses()
    {
        Assert.Equal("https://my-mac.tail1234.ts.net", SignInAddress.Pasted("Here it is: https://my-mac.tail1234.ts.net. Paste it into Hermes HQ."));
        Assert.Equal("my-mac.tail1234.ts.net", SignInAddress.Pasted("Use my-mac.tail1234.ts.net now"));
        Assert.Equal("studio.local:9119", SignInAddress.Pasted("  studio.local:9119 "));
        Assert.True(SignInAddress.LooksLikeAddress("studio.local"));
        Assert.False(SignInAddress.LooksLikeAddress("studio"));
        Assert.Equal("https://a.ts.net", SignInAddress.FromConnectLink("hermes://connect?url=https%3A%2F%2Fa.ts.net"));
        Assert.Null(SignInAddress.FromConnectLink("https://connect?url=x"));
        Assert.Equal("http://box.lan:9119/", GatewayAddress.FromTyped("box.lan:9119").Base.ToString());
    }
}
