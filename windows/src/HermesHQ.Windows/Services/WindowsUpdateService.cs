using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Hermes.Core.Updates;
using HermesHQ.Features.Settings;
using Microsoft.UI.Xaml;

namespace HermesHQ.Services;

public enum WindowsUpdateUiState
{
    Idle,
    Checking,
    UpToDate,
    Available,
    Downloading,
    Applying,
    Failed,
}

/// Coordinates checking GitHub Releases for newer unpackaged Windows builds, downloading and
/// SHA-256 verifying the matching architecture zip, and handing off to a self-cleaning PowerShell
/// swap script so Hermes HQ restarts seamlessly on the new version.
public static class WindowsUpdateService
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(180) };
    private static readonly object Gate = new();
    private static bool _backgroundStarted;
    private static Task<UpdateCheckResult>? _activeCheck;

    public static WindowsUpdateUiState State { get; private set; } = WindowsUpdateUiState.Idle;
    public static WindowsReleaseInfo? AvailableRelease { get; private set; }
    public static double Progress { get; private set; }
    public static string? StatusDetail { get; private set; }

    public static event Action? Changed;

    public static Version CurrentVersion => WindowsAppUpdater.ParseVersion(SettingsFeature.AppVersion);
    public static string InstallDirectory => AppContext.BaseDirectory;
    public static string UpdatesRoot => Path.Combine(AppPaths.Root, "updates");

    /// Starts one silent background check shortly after launch. Never runs during automated
    /// CI proof walks so walks stay offline and deterministic.
    public static void StartBackgroundCheckIfAllowed()
    {
        if (Automation.Enabled || AppShutdown.Stopping) return;
        lock (Gate)
        {
            if (_backgroundStarted) return;
            _backgroundStarted = true;
        }
        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(TimeSpan.FromSeconds(6));
                if (AppShutdown.Stopping || Automation.Enabled) return;
                await CheckAsync(silent: true);
            }
            catch (Exception ex)
            {
                AppLog.Error("update", ex);
            }
        });
    }

    public static Task<UpdateCheckResult> CheckAsync(bool silent = false)
    {
        lock (Gate)
        {
            if (_activeCheck != null && !_activeCheck.IsCompleted)
                return _activeCheck;
            _activeCheck = RunCheckAsync(silent);
            return _activeCheck;
        }
    }

    private static async Task<UpdateCheckResult> RunCheckAsync(bool silent)
    {
        if (!silent)
            SetState(WindowsUpdateUiState.Checking, AvailableRelease, 0, "Checking GitHub Releases…");

        var current = CurrentVersion;
        var arch = RuntimeInformation.ProcessArchitecture;
        var result = await WindowsAppUpdater.CheckForUpdateAsync(Http, current, arch);

        switch (result.Status)
        {
            case UpdateStatus.UpdateAvailable when result.Release != null:
                AppLog.Note("update", $"update available: {result.Release.Tag} (current {current.ToString(3)})");
                SetState(WindowsUpdateUiState.Available, result.Release, 0,
                    $"Version {result.Release.Version.ToString(3)} is available.");
                break;
            case UpdateStatus.UpToDate:
                AppLog.Note("update", $"up to date on {current.ToString(3)}");
                if (!silent || State != WindowsUpdateUiState.Available)
                    SetState(WindowsUpdateUiState.UpToDate, null, 0, $"You’re up to date ({current.ToString(3)}).");
                break;
            default:
                AppLog.Note("update", $"check failed: {result.ErrorMessage ?? "unknown error"}");
                if (!silent)
                    SetState(WindowsUpdateUiState.Failed, AvailableRelease, 0,
                        result.ErrorMessage ?? "Couldn’t check for updates.");
                break;
        }
        return result;
    }

    /// Downloads, verifies, and applies the available update in place, then quits cleanly so
    /// the swap script replaces the files and relaunches HermesHQ.exe.
    /// Returns (false, message) when the install directory is read-only or an error occurs.
    public static async Task<(bool Restarting, string? Error)> InstallAvailableAsync()
    {
        var release = AvailableRelease;
        if (release == null) return (false, "No update is currently available.");

        var installDir = InstallDirectory;
        if (!WindowsAppUpdater.IsDirectoryWritable(installDir))
        {
            const string msg = "This install folder isn’t writable without administrator rights. Use Open Release Page to download it manually.";
            SetState(WindowsUpdateUiState.Failed, release, 0, msg);
            return (false, msg);
        }

        try
        {
            SetState(WindowsUpdateUiState.Downloading, release, 0, $"Downloading {release.Version.ToString(3)}…");
            var reporter = new Progress<double>(p =>
            {
                var pct = (int)Math.Round(Math.Clamp(p, 0, 1) * 100);
                var label = p < 0.91 ? $"Downloading {release.Version.ToString(3)}… {pct}%"
                    : p < 0.95 ? "Verifying SHA-256 checksum…"
                    : "Extracting update…";
                SetState(WindowsUpdateUiState.Downloading, release, p, label);
            });

            var staged = await WindowsAppUpdater.DownloadAndStageAsync(Http, release, UpdatesRoot, reporter);

            SetState(WindowsUpdateUiState.Applying, release, 1.0, "Restarting to finish update…");
            var scriptPath = Path.Combine(staged.StagingDir, "apply-update.ps1");
            var script = WindowsAppUpdater.BuildApplyScript(
                waitPid: Environment.ProcessId,
                stagedDir: staged.ContentDir,
                installDir: installDir,
                stagingRoot: staged.StagingDir);
            await File.WriteAllTextAsync(scriptPath, script, Encoding.UTF8);

            var psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = $"-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"{scriptPath}\"",
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = staged.StagingDir,
            };
            Process.Start(psi);
            AppLog.Note("update", $"launched updater script for {release.Tag}; shutting down");

            // Gracefully shut down on the UI thread so the swap script can overwrite HermesHQ.exe
            App.Window?.DispatcherQueue.TryEnqueue(async () =>
            {
                await AppShutdown.RunAsync("app update");
                Application.Current.Exit();
            });
            return (true, null);
        }
        catch (Exception ex)
        {
            AppLog.Error("update", ex);
            var msg = ex is InvalidDataException ? ex.Message : "Update download failed. Try again or download from GitHub.";
            SetState(WindowsUpdateUiState.Failed, release, 0, msg);
            return (false, msg);
        }
    }

    private static void SetState(WindowsUpdateUiState state, WindowsReleaseInfo? release, double progress, string? detail)
    {
        State = state;
        AvailableRelease = release;
        Progress = progress;
        StatusDetail = detail;
        Changed?.Invoke();
    }
}
