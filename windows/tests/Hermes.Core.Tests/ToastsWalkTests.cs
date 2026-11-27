using System.Text.Json.Nodes;
using Hermes.Core.Model;
using Hermes.Core.Notifications;
using Hermes.Core.Questions;
using Hermes.Core.Rpc;
using Hermes.Core.Settings;
using Hermes.Core.Shell;

namespace Hermes.Core.Tests;

/// [WIN-56] The app's own toast log (Hermes.Core.Notifications.ToastLog) and the toasts walk's checks
/// (Hermes.Core.Shell.ToastsWalkProof): every toast the app decides on is recorded with whether Windows showed it, and
/// the exact reason when it didn't, so the walk can tell a shown toast from the unpackaged fallback (an open gap).
public class ToastsWalkTests
{
    private const string StoredA = "20260929_120000_aabbcc02";

    /// Read-only examples of integrity facts the SDK can report; the proof never changes them.
    private static readonly ProcessElevation Medium = new(3, 0x2000);
    private static readonly ProcessElevation Elevated = new(1, 0x3000);

    private static LocalAlerts Alerts(bool inFront = false) =>
        new(() => NotificationPrefs.Default, () => true, _ => false, () => inFront, () => true);

    private static LocalAlertEntry SamChat() => new(new NotificationWho("Sam", "", "", true), StoredA, "sam");

    private static LocalToast Reply(LocalAlerts? alerts = null) =>
        (alerts ?? Alerts()).ObserveTurnEnd(StoredA, 7, false, ToastsWalkProof.ReplyText, SamChat()).Toast!;

    private static LocalToast Failure()
    {
        var end = TurnEnd.From(new RpcEvent("error", StoredA, ToastsWalkProof.FailurePayload(), 8))!;
        return Alerts().ObserveTurnEnd(StoredA, 8, end.Failed, end.Text, SamChat()).Toast!;
    }

    private static LocalToast Approval()
    {
        var p = new JsonObject { ["command"] = ToastsWalkProof.ApprovalCommand, ["description"] = "Synthetic display sample" };
        return Alerts().ObserveRequest("srq-0001", PromptKind.Approval, StoredA, p, SamChat()).Toast!;
    }

    // ------------------------------------------------------------------ the Mac's words, decided by the app

    [Fact]
    public void TheThreeToastsCarryTheMacsWords()
    {
        Assert.Null(ToastsWalkProof.Raised(Record(Reply()), "message.complete", ToastsWalkProof.Reply, StoredA, buttons: false));
        Assert.Null(ToastsWalkProof.Raised(Record(Failure()), "turnError", ToastsWalkProof.Failure, StoredA, buttons: false));
        Assert.Null(ToastsWalkProof.Raised(Record(Approval()), "approval.request", ToastsWalkProof.Approval, StoredA, buttons: true));
        Assert.Equal("Sam", ToastsWalkProof.Reply.Title);
        Assert.Equal("The draft is ready for review.", ToastsWalkProof.Reply.Body);
        Assert.Equal("Couldn’t finish: the reply timed out", ToastsWalkProof.Failure.Body);
        Assert.Equal("Wants to run: Sample preview", ToastsWalkProof.Approval.Body);
    }

    [Fact]
    public void RaisedSaysWhatIsWrong()
    {
        Assert.Equal("no message.complete toast was raised for chat A", ToastsWalkProof.Raised(null, "message.complete", ToastsWalkProof.Reply, StoredA, false));
        var other = Record(Reply() with { Body = "Something else" });
        Assert.Contains("body", ToastsWalkProof.Raised(other, "message.complete", ToastsWalkProof.Reply, StoredA, false));
        var wrongChat = Record(Reply() with { Group = "elsewhere" });
        Assert.Contains("chat A's group", ToastsWalkProof.Raised(wrongChat, "message.complete", ToastsWalkProof.Reply, StoredA, false));
        var noButtons = Record(Approval() with { Buttons = [] });
        Assert.Contains("Approve Once", ToastsWalkProof.Raised(noButtons, "approval.request", ToastsWalkProof.Approval, StoredA, true));
    }

    // ------------------------------------------------------------------ the log: shown, or the exact reason it wasn't

    [Fact]
    public void BlockedNamesTheReason()
    {
        Assert.Null(ToastLog.Blocked(true, null, "Enabled"));
        Assert.Equal("toasts unavailable: COMException 0x80070490: Element not found.",
            ToastLog.Blocked(false, "COMException 0x80070490: Element not found.", "Enabled"));
        Assert.Equal("toasts unavailable: not registered", ToastLog.Blocked(false, null, "Unsupported"));
        Assert.Equal("not allowed (DisabledForUser)", ToastLog.Blocked(true, null, "DisabledForUser"));
    }

    [Fact]
    public void ErrorIsTypeHresultAndOneLine()
    {
        var x = new System.Runtime.InteropServices.COMException("Element\r\nnot found.", unchecked((int)0x80070490));
        Assert.Equal("COMException 0x80070490: Element not found.", ToastLog.Error(x));
    }

    [Fact]
    public void LogKeepsDeliveryAndFindsTheNewest()
    {
        var log = new ToastLog();
        var reply = Reply();
        log.Note(reply, ToastDelivery.NotShown, "toasts unavailable: not registered");
        log.Note(Approval(), ToastDelivery.Shown, "");
        Assert.Equal(ToastDelivery.NotShown, log.Newest("message.complete", StoredA)!.Delivery);
        Assert.Equal(ToastDelivery.Shown, log.Newest("approval.request", StoredA)!.Delivery);
        Assert.Null(log.Newest("turnError", StoredA));
        log.Clear();
        Assert.Empty(log.All());
        for (var i = 0; i < 80; i++) log.Note(reply with { Id = $"r{i}" }, ToastDelivery.Shown, "");
        Assert.Equal(ToastLog.Capacity, log.All().Count);
        Assert.Equal("r79", log.Newest("message.complete", StoredA)!.Toast.Id);
    }

    [Fact]
    public void ListOnlyWhenTheWindowIsInFront()
    {
        // The Mac's present(_:): in front, with Bot Activity Banners on, another chat's reply goes to the list only.
        Assert.True(Reply(Alerts(inFront: true)).SuppressDisplay);
        Assert.False(Reply(Alerts(inFront: false)).SuppressDisplay);
        Assert.Equal(ToastDelivery.ListOnly, ToastLog.Posted(Reply(Alerts(inFront: true))));
        Assert.Equal(ToastDelivery.Shown, ToastLog.Posted(Approval()));
    }

    [Fact]
    public void GapIsNeverAPass()
    {
        var shown = new ToastRecord(Reply(), ToastDelivery.Shown, "", DateTimeOffset.UnixEpoch);
        var notShown = new ToastRecord(Approval(), ToastDelivery.NotShown, "toasts unavailable: not registered", DateTimeOffset.UnixEpoch);
        Assert.Null(ToastsWalkProof.Gap([shown], Medium));
        Assert.Equal("open gap (MSIX needed): Windows didn't show approval.request: toasts unavailable: not registered",
            ToastsWalkProof.Gap([shown, notShown], Medium));
        Assert.Equal("open gap (MSIX needed): no toast was decided", ToastsWalkProof.Gap([], Medium));
    }

    // ------------------------------------------------------------------ read back from Windows, and acted on

    [Fact]
    public void PayloadShowsTheWordsXmlEscaped()
    {
        var copy = new NotificationCopy("Sam", "", "Couldn’t finish: a <b> & \"c\"");
        const string xml = "<toast><visual><binding template=\"ToastGeneric\"><text>Sam</text><text>Couldn’t finish: a &lt;b&gt; &amp; &quot;c&quot;</text></binding></visual></toast>";
        Assert.Null(ToastsWalkProof.PayloadShows(xml, copy));
        Assert.Contains("body", ToastsWalkProof.PayloadShows("<toast><text>Sam</text></toast>", copy));
        Assert.Equal("Windows has no toast to read back", ToastsWalkProof.PayloadShows(null, copy));
    }

    [Fact]
    public void ClickArgumentsRoundTripAsTheSdkHandsThemBack()
    {
        var approval = Approval();
        var approve = approval.Buttons.Single(b => b.Title == "Approve Once");
        var response = NotificationResponse.From(ToastsWalkProof.AsActivated(approve.Arguments));
        Assert.Equal("srq-0001", response.Request);
        Assert.True(response.Approve);
        Assert.Equal(StoredA, response.Target!.Stored);
        var click = NotificationResponse.From(ToastsWalkProof.AsActivated(Reply().Arguments));
        Assert.Null(click.Approve);
        Assert.Equal("sam", click.Target!.Profile);
    }

    [Fact]
    public void ChatOpenedNamesWhatIsOnScreen()
    {
        Assert.Null(ToastsWalkProof.ChatOpened(StoredA, StoredA));
        Assert.Equal("the reply toast's click left other on screen, not chat A", ToastsWalkProof.ChatOpened("other", StoredA));
        Assert.Equal("the reply toast's click left no chat on screen, not chat A", ToastsWalkProof.ChatOpened(null, StoredA));
    }

    private static ToastRecord Record(LocalToast t) => new(t, ToastLog.Posted(t), "", DateTimeOffset.UnixEpoch);

    // ------------------------------------------------------------------ [WIN-10 review] away banner, OS click, cold launch

    [Fact]
    public void AReplyWhileTheWindowIsMinimizedIsABannerWithItsOwnWords()
    {
        var away = new LocalAlerts(() => NotificationPrefs.Default, () => true, _ => false, () => false, () => false);
        var toast = away.ObserveTurnEnd(StoredA, 9, false, ToastsWalkProof.ReplyAwayText, SamChat()).Toast!;
        Assert.False(toast.SuppressDisplay);
        Assert.Null(ToastsWalkProof.Raised(new ToastRecord(toast, ToastLog.Posted(toast), "", DateTimeOffset.UtcNow),
            "message.complete", ToastsWalkProof.ReplyAway, StoredA, buttons: false));
        Assert.Equal(new NotificationCopy("Sam", "", ToastsWalkProof.ReplyAwayText), ToastsWalkProof.ReplyAway);
    }

    [Fact]
    public void TheAwayReplyPassesOnlyAsABannerAndAListOnlyOneIsABug()
    {
        var toast = Reply();
        Assert.Null(ToastsWalkProof.AwayDelivered(new ToastRecord(toast, ToastDelivery.Shown, "", DateTimeOffset.UtcNow), Medium));
        Assert.StartsWith("bug: ", ToastsWalkProof.AwayDelivered(new ToastRecord(toast, ToastDelivery.ListOnly, "", DateTimeOffset.UtcNow), Medium));
        var gap = ToastsWalkProof.AwayDelivered(new ToastRecord(toast, ToastDelivery.NotShown, "toasts unavailable: COMException 0x80070490: Element not found.", DateTimeOffset.UtcNow), Medium);
        Assert.Equal("open gap (MSIX needed): Windows didn't show the away reply: toasts unavailable: COMException 0x80070490: Element not found.", gap);
        Assert.StartsWith("bug: ", ToastsWalkProof.AwayDelivered(null, Medium));
    }

    [Fact]
    public void WarmNavigationRequiresExactlyOneNewCallbackAndTheLoadedFixtureChat()
    {
        Assert.True(ToastsWalkProof.WarmOpened(2, 3, true, StoredA));
        Assert.False(ToastsWalkProof.WarmOpened(2, 2, true, StoredA));
        Assert.False(ToastsWalkProof.WarmOpened(2, 4, true, StoredA));
        Assert.False(ToastsWalkProof.WarmOpened(2, 3, false, StoredA));
        Assert.False(ToastsWalkProof.WarmOpened(2, 3, true, "another"));
        Assert.StartsWith("open gap: banner pixels not verified", ToastsWalkProof.BannerObservation([Record(Reply())], "Enabled"));
    }

    [Fact]
    public void TheColdLaunchLineNamesTheChatByAShortKeyNotItsId()
    {
        var key = ToastLog.ChatKey(StoredA);
        Assert.Matches("^[0-9a-f]{8}$", key);
        Assert.Equal(key, ToastLog.ChatKey(StoredA));
        Assert.NotEqual(key, ToastLog.ChatKey(StoredA + "x"));
        Assert.Equal($"toast cold launch opened chat key {key}", ToastLog.ColdLaunchOpened(StoredA));
        Assert.DoesNotContain(StoredA, ToastLog.ColdLaunchOpened(StoredA));
        // windows/ci/windows.yml finds the cold toast in Notification Center by these words.
        Assert.StartsWith("Cold launch check", ToastsWalkProof.ColdText);
    }

    // ------------------------------------------------------------------ [WIN-10 review] why Windows won't take a toast

    [Fact]
    public void ProcessElevationNamesTheTokenAsTheSdkJudgesIt()
    {
        // Windows App SDK Security::IntegrityLevel::IsElevated: integrity at or above High (0x3000), whatever the
        // elevation type; AppNotificationManager.IsSupported() is false for such a process, packaged or not.
        Assert.False(Medium.Elevated);
        Assert.True(Elevated.Elevated);
        Assert.True(new ProcessElevation(2, 0x3000).Elevated);
        Assert.True(new ProcessElevation(1, 0x4000).Elevated);
        Assert.False(new ProcessElevation(1, 0x2100).Elevated);
        Assert.Equal("TokenElevationTypeLimited (3), integrity Medium (0x2000)", Medium.Describe());
        Assert.Equal("TokenElevationTypeDefault (1), integrity High (0x3000)", Elevated.Describe());
        Assert.Equal("TokenElevationTypeFull (2), integrity System (0x4000)", new ProcessElevation(2, 0x4000).Describe());
        Assert.Equal("TokenElevationType 7 (7), integrity 0x1234 (0x1234)", new ProcessElevation(7, 0x1234).Describe());
    }

    [Fact]
    public void TheGapLabelIsElevatedProcessNotMsixWhenTheTokenIsElevated()
    {
        Assert.Equal("open gap (elevated process)", ProcessElevation.GapLabel(Elevated));
        Assert.Equal("open gap (MSIX needed)", ProcessElevation.GapLabel(Medium));
        Assert.Equal("open gap (elevation unknown)", ProcessElevation.GapLabel(null));
        var notShown = new ToastRecord(Reply(), ToastDelivery.NotShown,
            "toasts unavailable: AppNotificationManager.IsSupported() is false (TokenElevationTypeDefault (1), integrity High (0x3000))", DateTimeOffset.UnixEpoch);
        Assert.Equal("open gap (elevated process): Windows didn't show message.complete: toasts unavailable: AppNotificationManager.IsSupported() is false (TokenElevationTypeDefault (1), integrity High (0x3000))",
            ToastsWalkProof.Gap([notShown], Elevated));
        Assert.Equal("open gap (elevated process): no toast was decided", ToastsWalkProof.Gap([], Elevated));
        Assert.StartsWith("open gap (elevated process): Windows didn't show the away reply: ", ToastsWalkProof.AwayDelivered(notShown, Elevated));
        Assert.StartsWith("open gap (elevation unknown): ", ToastsWalkProof.AwayDelivered(notShown, null));
    }

    [Fact]
    public void TheUnsupportedReasonCarriesTheTokenFacts()
    {
        Assert.Equal("AppNotificationManager.IsSupported() is false (TokenElevationTypeDefault (1), integrity High (0x3000))",
            ProcessElevation.Unsupported(Elevated));
        Assert.Equal("AppNotificationManager.IsSupported() is false (token unreadable)", ProcessElevation.Unsupported(null));
        // The line windows.yml's cold-launch step copies into toast-cold.log.
        Assert.Equal("process token: TokenElevationTypeLimited (3), integrity Medium (0x2000); elevated: no", ProcessElevation.LogLine(Medium));
        Assert.Equal("process token: TokenElevationTypeDefault (1), integrity High (0x3000); elevated: yes", ProcessElevation.LogLine(Elevated));
        Assert.Equal("process token: unreadable", ProcessElevation.LogLine(null));
    }
}
