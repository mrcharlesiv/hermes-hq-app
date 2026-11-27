using HermesHQ.Services;
using Microsoft.UI.Xaml;

namespace HermesHQ;

public partial class App : Application
{
    public static MainWindow? Window { get; private set; }

    public App()
    {
        AppLog.Note("app", $"starting {typeof(App).Assembly.GetName().Version}");
        InitializeComponent();
        Features.Settings.ThemeService.ApplyStartupTheme(this);
        UnhandledException += (_, e) =>
        {
            if (AppShutdown.Started || Window?.Lifetime.IsClosing == true)
            {
                // Quit is not a recoverable UI action. Observe it without handling it or substituting a status.
                AppLog.Note("unhandled", $"shutdown: {Hermes.Core.Shell.ShutdownPlan.Threw(e.Exception)}");
                return;
            }
            AppLog.Note("unhandled", $"{e.Exception?.GetType().Name ?? "Unknown"}: {e.Message}\n{e.Exception?.StackTrace}");
            e.Handled = true; // keep the app up; the failing action reports its own error
        };
        // Throws the XAML handler above never sees (a background thread, a task nobody awaited, or a stowed exception
        // while the app shuts down: CI run 45068215194 exited 0xC000027B after its walk's "done"). Logged only, so
        // the process still ends with its real code and the CI step still fails.
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
            AppLog.Note("unhandled", $"domain{(e.IsTerminating ? " (terminating)" : "")}: {e.ExceptionObject}");
        TaskScheduler.UnobservedTaskException += (_, e) =>
            AppLog.Note("unhandled", $"unobserved task: {e.Exception}");
    }

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        AppLog.Note("app", "launched");
        try { Shell.FeatureRegistry.RegisterAll(); }
        catch (Hermes.Core.Notifications.QuietWalkStopped stop)
        {
            AppLog.Note("automation", "walk toasts: " + stop.StopLine);
            // Some app owners registered before the duplicate route was refused. Stop those only;
            // never create a window, start the walk or fall through to normal launch.
            await AppShutdown.RunAsync("registration refused");
            Exit();
            return; // duplicate registration: never create a window or start another route
        }
        Features.Composer.MemoApp.Start();   // [WIN-MEMO-APP-STORES] on the UI thread, before any chat opens
        Window = new MainWindow();
        Window.Activate();
        await Window.StartAsync(); // otherwise a managed Exit failure stays on a discarded Task
    }
}
