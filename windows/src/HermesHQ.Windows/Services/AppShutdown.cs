using Hermes.Core.Shell;
using HermesHQ.Features.Artifacts;
using HermesHQ.Features.Attachments;
using HermesHQ.Features.Browser;
using HermesHQ.Features.Gateways;
using HermesHQ.Features.Jobs;
using HermesHQ.Features.Notifications;
using HermesHQ.Features.PhoneCalls;
using HermesHQ.Features.Screen;
using HermesHQ.Features.Settings;
using HermesHQ.Features.Voice;
using HermesHQ.Pages;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Services;

/// One bounded teardown for a walk exit and a user close. As in AppDelegate.applicationWillTerminate at d60cdb0ca,
/// milestones are on disk before exit; a last milestone is progress, not the cause of a fault. Exit() stays unwrapped.
internal static class AppShutdown
{
    private static readonly ShutdownPlan Plan = Build();

    // Started describes physical teardown. Admission closes synchronously, even if a walk log or
    // the undo on its still-owned fixture gateway must finish before the first teardown step.
    private static volatile bool _stopRequested;
    internal static bool Started => Plan.Started;
    internal static bool Stopping => _stopRequested || Started;
    internal static void StopNewWork() => _stopRequested = true;
    internal static bool Finished { get; private set; }

    public static async Task RunAsync(string why)
    {
        // The app log already records begin, done, timeout or failure for each owner. No collector or
        // extra file in the walk's screenshot directory is needed for the app to shut down.
        await Plan.RunAsync(why, line => AppLog.Note("shutdown", line));
        Finished = true;
    }

    internal static ShutdownPlan Build()
    {
        var plan = new ShutdownPlan();

        // Timers: nothing fires into what the later steps take apart.
        plan.Add(ShutdownStage.Timers, "open chat (its features' timers, its view model)",
            () => ChatPage.Current is { } page ? page.EndForQuitAsync() : Task.CompletedTask);
        plan.Add(ShutdownStage.Timers, "shell, lists and row steps", ShellPage.StopForQuit);
        plan.Add(ShutdownStage.Timers, "launch flow timers", LaunchFlow.StopTimersForQuit);
        plan.Add(ShutdownStage.Timers, "gateway news timer", GatewaysFeature.StopNewsForQuit);
        plan.Add(ShutdownStage.Timers, "jobs badge timer", JobsSidebarBadge.StopTimerForQuit);

        // The gateway's socket and session.
        plan.Add(ShutdownStage.Gateway, "gateway socket", AppState.CloseGatewayForQuitAsync);

        // Media and speech.
        plan.Add(ShutdownStage.Media, "read aloud", () => ReadAloudFeature.Center.Stop());
        plan.Add(ShutdownStage.Media, "memo player", Features.Composer.MemoApp.StopForQuit);
        plan.Add(ShutdownStage.Media, "completion cue player", CompletionCue.StopForQuit);

        // The other windows, each with its own Closed teardown (their WebView2s go with them).
        plan.Add(ShutdownStage.Windows, "settings window", SettingsWindow.CloseOpen);
        plan.Add(ShutdownStage.Windows, "screen window", ScreenWindow.CloseOpen);
        plan.Add(ShutdownStage.Windows, "browser window", BrowserWindow.CloseOpen);
        plan.Add(ShutdownStage.Windows, "preview tab window", PreviewTabWindow.CloseOpen);
        plan.Add(ShutdownStage.Windows, "phone call window", PhoneCallsFeature.CloseForQuit);
        plan.Add(ShutdownStage.Windows, "image viewer window", ArtifactImageWindow.CloseOpen);
        plan.Add(ShutdownStage.Windows, "chat photo viewer", MediaViewerWindow.CloseOpen);
        plan.Add(ShutdownStage.Windows, "file and page windows", () =>
            AppLog.Note("shutdown", $"file and page windows closed: {ArtifactFileWindow.CloseAllForQuit()}"));

        // The main window's web views (tiles, page cards, the artifacts' viewers): Close() each one,
        // and stop active ProgressRings so no Lottie/compositor callback fires into ShutdownQueue.
        plan.Add(ShutdownStage.WebViews, "main window's web views", CloseWebViews);

        plan.Add(ShutdownStage.Notifications, "toast registration", () =>
            AppLog.Note("shutdown", $"toast registration: {NotificationsFeature.UnregisterForQuit()}"));

        // What the steps above ended (a cancelled request's continuation) runs now, while XAML still dispatches.
        plan.Add(ShutdownStage.Drain, "let the UI thread settle", () => Task.Delay(300));
        return plan;
    }

    private static void CloseWebViews()
    {
        if (App.Window?.Content is not DependencyObject root) return;
        UiTree.DeactivateProgressRings(root);
        var found = new List<WebView2>();
        Collect(root, found);
        if (App.Window.Content.XamlRoot is { } xamlRoot)
            foreach (var popup in VisualTreeHelper.GetOpenPopupsForXamlRoot(xamlRoot))
                if (popup.Child is { } child)
                {
                    UiTree.DeactivateProgressRings(child);
                    Collect(child, found);
                }
        var count = ShutdownPlan.CloseEach(found, view => view.Close());
        AppLog.Note("shutdown", $"web views closed: {count}");
    }

    private static void Collect(DependencyObject node, List<WebView2> found)
    {
        if (node is WebView2 view) { found.Add(view); return; }
        var count = VisualTreeHelper.GetChildrenCount(node);
        for (var i = 0; i < count; i++) Collect(VisualTreeHelper.GetChild(node, i), found);
    }
}
