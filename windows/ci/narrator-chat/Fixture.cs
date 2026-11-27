using System.Diagnostics;
using System.Text.Json;
using System.Text.RegularExpressions;
using Hermes.Core.Auth;
using Hermes.Core.Net;
using HermesHQ.Features.Gateways;
using HermesHQ.Services;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace HermesHQ;

// Classify the caught object, not text in a trace. An unlisted subtype need not even be named *Exception.
internal static class FixtureExceptionStop
{
    private static readonly HashSet<Type> Named = [
        typeof(Exception), typeof(ArgumentException), typeof(System.Runtime.InteropServices.COMException),
        typeof(GatewayException), typeof(System.Net.Http.HttpRequestException), typeof(InvalidCastException),
        typeof(InvalidOperationException), typeof(IOException), typeof(JsonException), typeof(KeyNotFoundException),
        typeof(NullReferenceException), typeof(ObjectDisposedException), typeof(OperationCanceledException),
        typeof(TaskCanceledException), typeof(TimeoutException), typeof(UnauthorizedAccessException),
        typeof(System.ComponentModel.Win32Exception)];

    internal static string From(Exception error)
    {
        var type = error.GetType();
        return Named.Contains(type) ? "fixture-" + type.Name : "fixture-other-exception";
    }
}

// Same compiled App resources, main window, shell, chat and event handlers. Only this separately published fixture
// selects this entry point. Seed a real sign-in to the owned loopback stand-in in memory; no canned focus events.
internal static class NarratorChatEntry
{
    internal sealed record Seed(string Folder, int Port, string Phrase, int Narrator);
    private static string Env(string key) => Environment.GetEnvironmentVariable(key) ?? "";

    internal static Seed Scope()
    {
        const string repo = "mrcharlesiv/hermes-hq-windows", branch = "refs/heads/feat/windows";
        if (!OperatingSystem.IsWindows() || !Environment.Is64BitProcess || !Environment.UserInteractive ||
            Env("HQW_NARRATOR_CHAT") != "1" || !Automation.AppOnly || Env("GITHUB_ACTIONS") != "true" ||
            Env("RUNNER_ENVIRONMENT") != "github-hosted" || Env("RUNNER_OS") != "Windows" ||
            Env("GITHUB_EVENT_NAME") != "push" || Env("GITHUB_REPOSITORY") != repo || Env("GITHUB_REF") != branch)
            throw new InvalidOperationException("runner-not-allowed");
        using var payload = JsonDocument.Parse(File.ReadAllText(Env("GITHUB_EVENT_PATH")));
        var push = payload.RootElement;
        var repository = push.GetProperty("repository");
        if (repository.GetProperty("private").ValueKind != JsonValueKind.True || repository.GetProperty("full_name").GetString() != repo ||
            push.GetProperty("ref").GetString() != branch || push.GetProperty("deleted").ValueKind != JsonValueKind.False ||
            !Regex.IsMatch(Env("GITHUB_SHA"), @"\A[0-9a-f]{40}\z") || push.GetProperty("after").GetString() != Env("GITHUB_SHA"))
            throw new InvalidOperationException("unexpected-push");
        var path = Path.GetFullPath(Env("HQW_AUTOMATION"));
        var dir = new DirectoryInfo(Path.GetDirectoryName(path)!);
        if (Path.GetFileName(path) != "seed.json" || !dir.Name.StartsWith("hq-narrator-", StringComparison.Ordinal) ||
            !string.Equals(dir.Parent?.FullName, Path.TrimEndingDirectorySeparator(Path.GetFullPath(Env("RUNNER_TEMP"))), StringComparison.OrdinalIgnoreCase) ||
            File.Exists(Path.Combine(dir.FullName, "trace.json")) || Directory.Exists(Path.Combine(dir.FullName, "app-data")) ||
            Directory.Exists(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "HermesHQ")))
            throw new InvalidOperationException("not-a-fresh-fixture");
        using var json = JsonDocument.Parse(File.ReadAllText(path));
        var root = json.RootElement;
        var port = root.GetProperty("port").GetInt32();
        var phrase = root.GetProperty("phrase").GetString() ?? "";
        if (port is < 1024 or > 65535 || !Regex.IsMatch(phrase, @"\A[0-9a-f]{32}\z")) throw new InvalidOperationException("invalid-seed");
        return new(dir.FullName, port, phrase, root.GetProperty("narratorPid").GetInt32());
    }

    [STAThread]
    public static int Main()
    {
        try
        {
            var seed = Scope(); // no XAML, system input, app data or clipboard access before admission
            using var reader = Process.GetProcessById(seed.Narrator);
            if (reader.HasExited || !string.Equals(reader.ProcessName, "Narrator", StringComparison.OrdinalIgnoreCase)) return 2;
            WinRT.ComWrappersSupport.InitializeComWrappers();
            Application.Start(_ =>
            {
                SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
                new App.NarratorFixture(seed, reader);
            });
            return 0;
        }
        catch { return 2; } // no credential, arbitrary window name, clipboard text or exception message in the job log
    }
}

public partial class App
{
    internal sealed class NarratorFixture(NarratorChatEntry.Seed seed, Process reader) : App
    {
        protected override async void OnLaunched(LaunchActivatedEventArgs args)
        {
            var walk = new NarratorChatWalk(seed.Folder, reader);
            try
            {
                if (AppState.Store is not MemoryTokenStore) throw new InvalidOperationException("not-isolated");
                Shell.FeatureRegistry.RegisterAll(); // AppOnly: no desktop notifications
                Features.Composer.MemoApp.Start();
                Window = new MainWindow();
                Window.Activate(); // once, as in App.OnLaunched. Never fight another foreground window.
                using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(10));
                var address = GatewayAddress.Validated($"http://127.0.0.1:{seed.Port}");
                using (await AppState.SignIn.PasswordAsync(address, "fixture", seed.Phrase, limit.Token)) { }
                LaunchFlow.AttachWindow(Window);
                await LaunchFlow.StartAsync(); // normal cold restore and first bot's real ChatPage; no Automation.RunAsync
                await walk.Run(Window);
            }
            catch (NarratorStop e) { walk.Stop = e.Code; }
            catch (Exception e) { walk.Stop = FixtureExceptionStop.From(e); }
            finally { try { walk.Save(); } finally { Exit(); } }
        }
    }
}
