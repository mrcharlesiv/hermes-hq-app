using System.Text.RegularExpressions;
using Xunit;

namespace Hermes.Core.Tests;

/// Regression guards for the Windows stability and bug-sweep fixes:
/// - Shutdown teardown (all secondary windows closed + active ProgressRings deactivated before ShutdownQueue).
/// - Audio native memory safety (WinMM worker join before freeing WaveHdrs; ReadAloud source detached before stream disposal).
/// - Picker safety (no legacy UWP Windows.Storage.Pickers anywhere in HermesHQ.Windows).
/// - Safe WebView2 environment creation (never permanently caching a faulted task).
/// - Chat, Inspector, Diff viewer, Phone Call, Link Dialog, Markdown, Voice Talk, and Notifications bug fixes.
public sealed class WindowsBugSweepSourceTests
{
    private static string WinRoot()
    {
        var dir = AppContext.BaseDirectory;
        while (dir != null && !File.Exists(Path.Combine(dir, "HermesHQ.sln")))
            dir = Directory.GetParent(dir)?.FullName;
        Assert.NotNull(dir);
        return Path.Combine(dir!, "src", "HermesHQ.Windows");
    }

    private static string WinSource(params string[] parts) =>
        File.ReadAllText(Path.Combine([WinRoot(), .. parts])).ReplaceLineEndings("\n");

    [Fact]
    public void AppShutdownClosesAllSecondaryWindowsAndDeactivatesProgressRings()
    {
        var src = WinSource("Services", "AppShutdown.cs");
        Assert.Contains("BrowserWindow.CloseOpen", src);
        Assert.Contains("PreviewTabWindow.CloseOpen", src);
        Assert.Contains("PhoneCallsFeature.CloseForQuit", src);
        Assert.Contains("UiTree.DeactivateProgressRings(root)", src);
        Assert.Contains("UiTree.DeactivateProgressRings(child)", src);
    }

    [Fact]
    public void NoLegacyUwpStoragePickersRemainInWindowsApp()
    {
        var legacy = new Regex(@"(?<!Microsoft\.)Windows\.Storage\.Pickers", RegexOptions.Compiled);
        var offenders = new List<string>();
        foreach (var file in Directory.EnumerateFiles(WinRoot(), "*.cs", SearchOption.AllDirectories))
        {
            var text = File.ReadAllText(file).ReplaceLineEndings("\n");
            if (legacy.IsMatch(text))
                offenders.Add(Path.GetRelativePath(WinRoot(), file));
        }
        Assert.Empty(offenders);
    }

    [Fact]
    public void WinMmWaveInCaptureJoinsWorkerBeforeFreeingHeadersAndReadAloudDetachesSourceBeforeStreamDispose()
    {
        var voice = WinSource("Features", "Voice", "WindowsVoiceAudio.cs");
        var stopAt = voice.IndexOf("public void Stop()", StringComparison.Ordinal);
        Assert.True(stopAt >= 0);
        var stopBody = voice[stopAt..voice.IndexOf("private void ReleaseResourcesLocked", stopAt, StringComparison.Ordinal)];
        var joinAt = stopBody.IndexOf("worker.Join(", StringComparison.Ordinal);
        var releaseAt = stopBody.IndexOf("ReleaseResourcesLocked(handle)", StringComparison.Ordinal);
        Assert.True(joinAt >= 0 && releaseAt > joinAt, "WinMmWaveInCapture.Stop must join worker before releasing unmanaged headers/GCHandles.");

        var readAloud = WinSource("Features", "Voice", "WindowsReadAloudVoice.cs");
        Assert.Contains("player.Pause();\n                    player.Source = null;", readAloud);
    }

    [Fact]
    public void WebViewEnvDoesNotCacheFaultedEnvironmentTasks()
    {
        var safety = WinSource("Services", "UiSafety.cs");
        Assert.Contains("if (task == null || task.IsFaulted || task.IsCanceled)", safety);
        Assert.Contains("AppPaths.Root, \"webview2\"", safety);
        foreach (var path in new[]
        {
            new[] { "Features", "Artifacts", "ArtifactViewers.cs" },
            new[] { "Features", "Browser", "PreviewTabView.cs" },
            new[] { "Features", "Insights", "TileWeb.cs" },
            new[] { "Features", "Transcript", "PagePictures.cs" },
        })
        {
            Assert.Contains("WebViewEnv.GetAsync()", WinSource(path));
        }
    }

    [Fact]
    public void ChatInspectorWiresFilesTabAndFingerprintsRefresh()
    {
        var src = WinSource("Features", "Transcript", "ChatInspector.cs");
        Assert.Contains("FilesView?.Invoke(_session)", src);
        Assert.Contains("ContentFingerprint()", src);
        Assert.Contains("if (!force && key == _lastKey && _page.Content != null) return;", src);
    }

    [Fact]
    public void DiffViewerNeverDrawsInvisibleNullForegroundText()
    {
        var src = WinSource("Features", "Workspace", "FileTextView.cs");
        Assert.DoesNotContain("Foreground = color,", src);
        Assert.Contains("if (color != null) block.Foreground = color;", src);
    }

    [Fact]
    public void LinkDialogRequiresExplicitSubmitNotCancelToAttach()
    {
        var src = WinSource("Features", "Composer", "LinkDialog.cs");
        Assert.Contains("var submittedByEnter = false;", src);
        Assert.Contains("(result == ContentDialogResult.Primary || submittedByEnter)", src);
    }

    [Fact]
    public void PhoneCallWindowUpdatesElapsedInPlaceWithoutRebuildingTextBoxes()
    {
        var src = WinSource("Features", "PhoneCalls", "PhoneCallWindow.cs");
        Assert.Contains("_tickTimer.Tick += (_, _) => UpdateActiveElapsed();", src);
        Assert.DoesNotContain("_tickTimer.Tick += (_, _) =>", src.Replace("_tickTimer.Tick += (_, _) => UpdateActiveElapsed();", ""));
    }

    [Fact]
    public void MarkdownRendererSupportsTaskListsNestedBlocksAndFormulaExpansion()
    {
        var src = WinSource("Controls", "MarkdownRenderer.cs");
        Assert.Contains("TaskList", src);
        Assert.Contains("case CodeBlock", src);
        Assert.Contains("case Table", src);
        Assert.Contains("CopyFormulasAsSource", src);
    }

    [Fact]
    public void TalkOffersLiveVoiceAndNotificationsUseCurrentEpoch()
    {
        var talk = WinSource("Features", "Voice", "TalkFeature.cs");
        Assert.Contains("liveOffered: true", talk);
        Assert.Contains("grokOffered: true", talk);

        var notify = WinSource("Features", "Notifications", "NotificationsFeature.cs");
        Assert.Contains("Alerts.Epoch", notify);
    }

    [Fact]
    public void ManagedAndPluginScreensDispatchContinueWithOntoUiThreadAndUnsubscribe()
    {
        var managed = WinSource("Features", "Capabilities", "ManagedScreens.cs");
        Assert.Contains("Unloaded +=", managed);
        Assert.Contains("nous.Changed -= OnNousChanged;", managed);
        Assert.Contains("TryEnqueue(", managed);

        var plugins = WinSource("Features", "Capabilities", "PluginScreens.cs");
        Assert.Contains("TryEnqueue(", plugins);
    }

    [Fact]
    public void ShellPageUsesNavGenerationGuardAndSessionsPageDisposesEmbeddedChat()
    {
        var shell = WinSource("Pages", "ShellPage.xaml.cs");
        Assert.Contains("_navGeneration", shell);

        var sessions = WinSource("Pages", "SessionsPage.xaml.cs");
        Assert.Contains("CloseEmbeddedChat()", sessions);
        Assert.Contains("OnNavigatedFrom", sessions);
    }

    [Fact]
    public void SettingsPageIgnoresStaleSearchClearTextChangedInEmbeddedAndStandaloneModes()
    {
        var settings = WinSource("Features", "Settings", "SettingsPage.cs");
        Assert.Contains("_search.TextChanged += (_, _) => { if (_inFrame && _search.Text != _paneQuery) ShowSearch(); };", settings);
        Assert.DoesNotContain("if (!ownWindow || (_inFrame && _search.Text != _paneQuery))", settings);
    }
}
