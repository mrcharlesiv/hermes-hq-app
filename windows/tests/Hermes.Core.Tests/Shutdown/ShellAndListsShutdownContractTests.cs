namespace Hermes.Core.Tests;

/// Guardrails preventing DispatcherQueue shutdown stowed exceptions (0xC000027B / 0x8000FFFF in DeferInvokeCallback):
/// shell listeners, ListsHub background pollers, ConnectionNotice timers, ChatRowsWorking timers, UISettings handlers,
/// and NotificationsFeature timers must all tear down before gateway disposal and XAML Exit, and ToolTip dismissal must
/// never forcibly mutate WinUI's private ToolTip host Popup.IsOpen.
public class ShellAndListsShutdownContractTests
{
    private static string Read(params string[] parts)
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir != null && !File.Exists(Path.Combine(dir.FullName, "HermesHQ.sln"))) dir = dir.Parent;
        Assert.NotNull(dir);
        return File.ReadAllText(Path.Combine([dir.FullName, "src", "HermesHQ.Windows", .. parts]));
    }

    [Fact]
    public void AppShutdownStopsShellListsAndRowStepsBeforeGatewayDisposal()
    {
        var shutdown = Read("Services", "AppShutdown.cs");
        var shellStop = shutdown.IndexOf("ShellPage.StopForQuit", StringComparison.Ordinal);
        var gatewayClose = shutdown.IndexOf("AppState.CloseGatewayForQuitAsync", StringComparison.Ordinal);
        Assert.True(shellStop > 0, "AppShutdown must register ShellPage.StopForQuit.");
        Assert.True(gatewayClose > shellStop, "ShellPage.StopForQuit must run before AppState.CloseGatewayForQuitAsync.");
    }

    [Fact]
    public void ShellPageDetachesOnUnloadedAndStopsListsAndRowStepsForQuit()
    {
        var shell = Read("Pages", "ShellPage.xaml.cs");
        Assert.Contains("Unloaded += (_, _) => DetachShell();", shell);
        Assert.Contains("ListsHub.StopForQuit();", shell);
        Assert.Contains("ChatRowsWorking.StopForQuit();", shell);
        Assert.Contains("QuestionsFeature.StopForQuit();", shell);
        Assert.Contains("SettingsFeature.StopForQuit();", shell);
    }

    [Fact]
    public void ListsHubGuardsPollingAndPostAgainstShutdown()
    {
        var hub = Read("Features", "Bots", "ListsHub.cs");
        Assert.Contains("internal static void StopForQuit()", hub);
        Assert.Contains("if (AppShutdown.Stopping)", hub);
        Assert.Contains("while (!ct.IsCancellationRequested && !AppShutdown.Stopping)", hub);
    }

    [Fact]
    public void NotificationsUnregisterForQuitStopsTimersEvenWhenUnregistered()
    {
        var notify = Read("Features", "Notifications", "NotificationsFeature.cs");
        var start = notify.IndexOf("internal static string UnregisterForQuit()", StringComparison.Ordinal);
        var notRegistered = notify.IndexOf("if (!_registered) return \"not registered\";", start, StringComparison.Ordinal);
        Assert.True(start > 0 && notRegistered > start);
        var beforeReturn = notify[start..notRegistered];
        Assert.Contains("_waitForShell?.Stop();", beforeReturn);
        Assert.Contains("_coldWatch?.Stop();", beforeReturn);
        Assert.Contains("AppState.ClientChanged -= OnClient;", beforeReturn);
        Assert.Contains("Opener.Ready(null);", beforeReturn);
    }

    [Fact]
    public void MainWindowDismissToolTipsGuardsShutdownAndNeverMutatesPopupIsOpen()
    {
        var main = Read("MainWindow.xaml.cs");
        var start = main.IndexOf("internal void DismissToolTips()", StringComparison.Ordinal);
        Assert.True(start > 0);
        var method = main[start..(start + 450)];
        Assert.Contains("AppShutdown.Stopping", method);
        Assert.Contains("tip.IsOpen = false;", method);
        Assert.DoesNotContain("popup.IsOpen = false;", method);
    }

    [Fact]
    public void GroupRoomAndJobsPagesUnsubscribeUiSettingsOnUnloaded()
    {
        var groupRoom = Read("Pages", "GroupRoomPage.cs");
        Assert.Contains("_ui.AnimationsEnabledChanged -= OnAnimationsChanged;", groupRoom);
        Assert.Contains("_ui.TextScaleFactorChanged -= OnTextScaleChanged;", groupRoom);

        var jobs = Read("Features", "Jobs", "JobsPage.cs");
        Assert.Contains("_uiSettings.TextScaleFactorChanged -= OnTextScaleChanged;", jobs);
    }

    [Fact]
    public void AutomationWalkClosesMainWindowInsteadOfCallingApplicationExit()
    {
        var auto = Read("Services", "Automation.cs");
        Assert.DoesNotContain("Application.Current.Exit()", auto);
        Assert.Contains("window.Close);", auto);
    }

    [Fact]
    public void MainWindowDetachesBackdropAndRootBeforeDrainAndLinkChipUnsubscribesOnQuit()
    {
        var main = Read("MainWindow.xaml.cs");
        Assert.Contains("internal void DetachForQuit()", main);
        Assert.Contains("SystemBackdrop = null;", main);
        Assert.Contains("Root.Navigate(typeof(EmptyPane)", main);

        var shell = Read("Pages", "ShellPage.xaml.cs");
        Assert.Contains("App.Window?.DetachForQuit();", shell);
        Assert.Contains("LinkChipView.StopForQuit();", shell);

        var linkChip = Read("Features", "Transcript", "LinkChipView.cs");
        Assert.Contains("internal static void StopForQuit()", linkChip);
        Assert.Contains("Settings.TextScaleFactorChanged -= OnSystemTextScaleChanged;", linkChip);
        Assert.Contains("if (Services.AppShutdown.Stopping || !_onScreen) return;", linkChip);

        var quick = Read("Features", "QuickActions", "QuickActionsPage.cs");
        Assert.Contains("if (AppShutdown.Stopping) return;", quick);
    }
}
