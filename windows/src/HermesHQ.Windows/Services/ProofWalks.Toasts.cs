using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;
using Hermes.Core.Notifications;
using Hermes.Core.Shell;
using HermesHQ.Features.Notifications;
using HermesHQ.Pages;
using HermesHQ.Shell;
using Microsoft.UI.Windowing;
using Microsoft.Windows.AppNotifications;

namespace HermesHQ.Services;

/// Real reply activation only. The fixture can't ask a question. The recording-only action check has no transport.
/// A decision, a screenshot of the app and a reply actually opened by Windows are three different observations.
internal static partial class ProofWalks
{
    private static void RegisterToastsWalks()
    {
        try { Automation.BoundWalks.Add("toasts", ToastsAsync); }
        catch (ArgumentException) { throw QuietWalkStopped.RouteNotUnique(); }
    }

    private static async Task ToastsAsync(Func<string, Task> shot, ToastQuietProbe quiet)
    {
        var proof = Automation.Desktop ?? throw new InvalidOperationException("requires the opted-in Windows runner");
        var client = AppState.Client ?? throw new InvalidOperationException("not signed in");
        if (Automation.AppOnly || client.Session.Address.ToString() != DesktopProof.Fixture
            || DesktopProof.ForRunner(Environment.GetEnvironmentVariable, OperatingSystem.IsWindows())?.Stamp != proof.Stamp)
            throw new InvalidOperationException("wrong fixture for the desktop reply walk");
        RecordedToastActions.Verify(RecordedToastActions.Sample());
        Note("sensitive labels and routing verified in memory only; no action sent");
        quiet.RequireChat(QuietChat.B);
        var bots = await client.BotsAsync();
        var a = bots.Single(b => b.Name == DesktopProof.Profile);
        var b = bots.Single(b => b.Name == "default");
        quiet.RequireChat(QuietChat.B);
        var storedA = await client.BotChatIdAsync(a);
        quiet.RequireChat(QuietChat.B);
        var storedB = await client.BotChatIdAsync(b);
        if (storedA != DesktopProof.Chat || storedB != "20260929_120000_aabbcc01") throw new InvalidOperationException("wrong fixture chats");
        quiet.RequireChat(QuietChat.B);
        Navigator.Go(new ChatDestination(a.Name, storedA, a.DisplayName));
        await Showing(storedA);
        await Until(() => NotificationsFeature.Tracks(storedA) ? a : null, "chat A's runtime id");
        async Task GoToB(QuietChat source)
        {
            quiet.RequireChat(source);
            Navigator.Go(new ChatDestination(b.Name, storedB, b.DisplayName));
            await Showing(storedB);
            await Task.Delay(1000);
        }
        await GoToB(QuietChat.A);
        quiet.RequireChat(QuietChat.B);
        ToastLog.Shared.Clear();
        var window = App.Window ?? throw QuietWalkStopped.Incomplete();
        var sourceB = ChatPage.Current ?? throw QuietWalkStopped.Incomplete();
        var presenter = window.AppWindow.Presenter as OverlappedPresenter ?? throw QuietWalkStopped.Incomplete();
        void RequireOwnMinimizedWindow()
        {
            quiet.RequireAwayLifetime();
            if (App.Window != window || !window.DispatcherQueue.HasThreadAccess || window.AppWindow.Presenter != presenter
                || presenter.State != OverlappedPresenterState.Minimized || window.SheetShown || AppState.Client != client
                || ChatPage.Current != sourceB || !sourceB.IsLoaded || sourceB.StoredId != storedB || !NotificationsFeature.Tracks(storedB))
                throw QuietWalkStopped.Incomplete();
        }
        using var http = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false, UseProxy = false })
            { BaseAddress = new Uri(DesktopProof.Fixture), Timeout = TimeSpan.FromSeconds(10) };
        async Task<(ToastRecord Record, string? Gap)> Raise(string path, string kind, NotificationCopy copy, ReplyPhase? phase = null)
        {
            void CheckSource() { if (path == "/__toast/away") RequireOwnMinimizedWindow(); else quiet.RequireChat(QuietChat.B); }
            CheckSource();
            using var sent = await http.PostAsync(path, null);
            sent.EnsureSuccessStatusCode();
            var record = await Until(() => ToastLog.Shared.Newest(kind, storedA) is { } r && r.Toast.Body == copy.Body ? r : null, "fixture notification", 15);
            if (ToastsWalkProof.Raised(record, kind, copy, storedA, false) != null) throw new InvalidOperationException("wrong fixture notification wording or route");
            if (!proof.MayShow(record.Toast)) throw new InvalidOperationException("unexpected fixture notification");
            CheckSource();
            var gap = await ReadBackAsync(record, copy, proof, phase);
            if (gap != null) Note($"{kind} read-back gap: {gap}");
            return (record, gap);
        }

        quiet.RequireChat(QuietChat.B);
        await shot("toast-before-reply"); // baseline: chat B, not the target of the click
        quiet.Checkpoint(QuietPoint.BeforeFirst);
        var reply = await Raise("/__toast/warm", "message.complete", proof.Copy(ReplyPhase.Warm), ReplyPhase.Warm);
        quiet.RequireChat(QuietChat.B);
        await shot("toast-reply");
        var failure = await Raise("/__toast/failure", "turnError", ToastsWalkProof.Failure);
        quiet.RequireChat(QuietChat.B);
        await shot("toast-failure");
        quiet.RequireChat(QuietChat.B);
        if (App.Window != window || window.AppWindow.Presenter != presenter) throw QuietWalkStopped.Incomplete();
        quiet.Checkpoint(QuietPoint.BeforeAway);
        presenter.Minimize();
        await Until(() => presenter.State == OverlappedPresenterState.Minimized ? presenter : null, "the window minimized");
        await Task.Delay(500);
        var (away, _) = await Raise("/__toast/away", "message.complete", ToastsWalkProof.ReplyAway);
        RequireOwnMinimizedWindow();
        presenter.Restore(); // no Activate/focus repair if the restored composer isn't actually in front
        await Showing(storedB);
        quiet.Checkpoint(QuietPoint.AfterAway);
        await shot("toast-reply-away"); // restored app window, NOT a picture of a shell banner
        quiet.RequireChat(QuietChat.B);
        if (ToastsWalkProof.AwayDelivered(away, NotificationsFeature.Elevation) is { } verdict)
        {
            if (verdict.StartsWith("bug:", StringComparison.Ordinal)) throw new InvalidOperationException(verdict);
            Note(verdict);
        }
        var registration = NotificationsFeature.Registration;
        string setting = registration.Error ?? "not registered";
        if (registration.Registered)
        {
            try { setting = AppNotificationManager.Default.Setting.ToString(); }
            catch (Exception e) { setting = $"unavailable ({e.GetType().Name})"; }
        }
        Note(ToastsWalkProof.BannerObservation([reply.Record, failure.Record, away], setting));

        // No simulated click if the shell can't give us the one exact reply. The OS must deliver a fresh
        // NotificationInvoked and the loaded chat must change from B to A; a helper exit or an app screenshot isn't that.
        await Showing(storedB);
        var before = NotificationsFeature.WarmActivations;
        quiet.RequireChat(QuietChat.B);
        var warmGap = reply.Gap ?? await InvokeWarmAsync();
        var afterWarm = QuietChat.B;
        if (warmGap == null)
        {
            await Until(() => ChatPage.Current is { } p && ToastsWalkProof.WarmOpened(before, NotificationsFeature.WarmActivations, p.IsLoaded, p.StoredId) ? p : null, "a new NotificationInvoked opening chat A", 15);
            afterWarm = QuietChat.A;
            quiet.RequireChat(QuietChat.A);
            await shot("toast-warm-opened"); // conditional proof: the chat Windows actually opened
            Note("warm: NotificationInvoked opened chat A");
        }
        else
        {
            if (NotificationsFeature.WarmActivations != before || ChatPage.Current?.StoredId != storedB)
                throw new InvalidOperationException("unexpected navigation without a verified reply invocation");
            Note($"warm: open gap: {warmGap}; chat B remains selected");
        }
        quiet.RequireChat(afterWarm);
        await shot("toasts");
        await GoToB(afterWarm);
        var cold = await Raise("/__toast/cold", "message.complete", proof.Copy(ReplyPhase.Cold), ReplyPhase.Cold);
        quiet.RequireChat(QuietChat.B);
        if (cold.Gap == null)
        {
            // A previous writer is a stop, not permission to refresh its receipt. The receiver still consumes it once.
            using (var receipt = new FileStream(NotificationsFeature.ColdReceipt, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                receipt.Write(Encoding.ASCII.GetBytes(proof.Stamp));
            quiet.RequireChat(QuietChat.B);
            Note($"cold toast left for chat key {ToastLog.ChatKey(storedA)} run {proof.Stamp}");
        }
        else Note($"cold: open gap: {cold.Gap}");
    }

    private static Task<ChatPage> Showing(string stored) => Until(() => ChatPage.Current is { IsLoaded: true } p && p.StoredId == stored ? p : null, "the fixture chat");
    private static void Note(string what) => AppLog.Note("automation", "walk toasts: " + what);

    private static async Task<string?> ReadBackAsync(ToastRecord record, NotificationCopy copy, DesktopProof proof, ReplyPhase? phase)
    {
        if (record.Delivery == ToastDelivery.NotShown)
        {
            Note($"{ProcessElevation.GapLabel(NotificationsFeature.Elevation)}: {record.Toast.Kind}: {record.Why}");
            return record.Why;
        }
        IList<AppNotification> list;
        try { list = await AppNotificationManager.Default.GetAllAsync(); }
        catch (Exception e) { return $"own notification history unavailable: {e.GetType().Name} 0x{e.HResult:X8}"; }
        var found = list.Where(n => n.Tag == record.Toast.Tag && n.Group == record.Toast.Group).ToArray();
        if (found.Length != 1) return "missing or ambiguous fixture notification in this app's history";
        if (ToastsWalkProof.PayloadShows(found[0].Payload, copy) != null) throw new InvalidOperationException("unexpected words in own fixture notification");
        if (phase is { } p && !proof.IsReplyPayload(found[0].Payload, p)) throw new InvalidOperationException("unsafe or unexpected reply payload; not invoking");
        Note($"{record.Toast.Kind} read back from Windows ({record.Delivery})");
        return null;
    }

    private static async Task<string?> InvokeWarmAsync()
    {
        var start = new ProcessStartInfo(Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "reply-probe", "ReplyProbe.exe")))
            { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true };
        start.ArgumentList.Add("warm");
        using var process = Process.Start(start) ?? throw new InvalidOperationException("reply probe did not start");
        var output = process.StandardOutput.ReadToEndAsync();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(35));
        try { await process.WaitForExitAsync(timeout.Token); }
        catch (OperationCanceledException) { process.Kill(); throw new TimeoutException("reply probe timed out"); }
        var line = (await output).Trim();
        if (process.ExitCode == 2 && line.StartsWith("reply probe: gap: ", StringComparison.Ordinal)) return line["reply probe: gap: ".Length..];
        if (process.ExitCode != 0 || line != "reply probe: invoked") throw new InvalidOperationException($"reply probe failed ({process.ExitCode})");
        return null;
    }

    // Shared by the ordinary group and star-map walks, not by the notification proof.
    private static async Task StandInPost(string url, string path, JsonObject body)
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
        using var content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");
        using var response = await http.PostAsync(url.TrimEnd('/') + path, content);
        if (!response.IsSuccessStatusCode) throw new InvalidOperationException($"the stand-in's {path} answered {(int)response.StatusCode}");
    }
}
