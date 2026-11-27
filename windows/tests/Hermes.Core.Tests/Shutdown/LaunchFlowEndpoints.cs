// Inert endpoints for the complete production LaunchFlow. No account store, HTTP, socket or WinUI timer.
using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Gateways;
using Hermes.Core.Net;
using Hermes.Core.Offline;
using Hermes.Core.Onboarding;
using Hermes.Core.Rpc;
using HermesHQ.Features.Gateways;
using HermesHQ.Services;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace HermesHQ
{
    public sealed class MainWindow
    {
        internal WindowShutdown Lifetime { get; } = new();
        internal DispatcherQueue DispatcherQueue { get; } = new();
        internal UIElement? Content { get; private set; }
        internal List<UIElement> Roots { get; } = [];
        internal void ShowRoot(UIElement view)
        {
            (Content as OfflineView)?.CaptureUnload()();
            Content = view; Roots.Add(view);
            (view as OfflineView)?.CaptureLoad()();
        }
        internal void ShowShell() => throw new NotSupportedException();
        internal void DismissSheet() => throw new NotSupportedException();
        internal int Sheets;
        internal UIElement? Sheet { get; private set; }
        internal void PresentSheet(UIElement view) { Sheets++; Sheet = view; }
    }
    internal sealed partial record HermesClient
    {
        internal FixtureRpc Rpc { get; } = new();
        internal FixtureSession Session { get; } = new();
        internal object? Bots { get; set; }
        internal int FirstReads;
        internal void StartFirstRead() => FirstReads++;
        internal event Action? BotsChanged;
        internal int BotObservers => BotsChanged?.GetInvocationList().Length ?? 0;
        internal Action CaptureBots() => BotsChanged ?? (() => { });
    }
    internal sealed class FixtureRpc
    {
        internal ConnectionState State { get; set; } = ConnectionState.Connecting;
        internal DateTimeOffset? NextRetry => null;
        internal string? LastFailure => null;
        internal event Action<ConnectionState>? StateChanged;
        internal event Action? RetryChanged;
        internal int Observers => (StateChanged?.GetInvocationList().Length ?? 0) + (RetryChanged?.GetInvocationList().Length ?? 0);
        internal Action CaptureRetry() => RetryChanged ?? (() => { });
        internal Action CaptureState() { var delivery = StateChanged; return () => delivery?.Invoke(State); }
        internal void ReconnectNow() => throw new NotSupportedException();
        internal readonly TaskCompletionSource Ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal readonly TaskCompletionSource<CancellationToken> Waiting = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal Task WhenReadyAsync(CancellationToken ct) { Waiting.TrySetResult(ct); return Ready.Task.WaitAsync(ct); }
    }
    internal sealed class FixtureSession
    {
        internal GatewayAddress Address => throw new NotSupportedException();
        internal int Reads;
        internal readonly TaskCompletionSource<CancellationToken> Reading = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal readonly TaskCompletionSource<JsonNode> Reply = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal Task<JsonNode> GetJsonAsync(string path, CancellationToken ct = default)
        {
            Assert.Equal("/api/config", path); Reads++; Reading.TrySetResult(ct);
            return Reply.Task; // can deliberately finish after cancellation
        }
    }
}
namespace HermesHQ.Services
{
    internal static class AppPaths
    {
        // A file cannot own a subdirectory. Even a broken route cannot create a profile or open a saved hint.
        internal static readonly string Root = Path.Combine(typeof(AppPaths).Assembly.Location, "absent-fixture-profile");
    }
    internal static partial class AppState
    {
        internal static StoredAccount? Account => null;
        internal static FixtureSignIn SignIn { get; } = new();
        internal static FixtureLaunchChat LaunchChat { get; } = new();
        internal static HermesClient Adopt(GatewaySession s) => throw new NotSupportedException();
        private static void ParkRoster() => throw new NotSupportedException();
        internal static Task EndedAsync() => throw new NotSupportedException();
        internal static Task<StoredAccount?> SignOutAsync() => throw new NotSupportedException();
    }
    internal sealed class FixtureSignIn
    {
        internal int Reads;
        internal SignIn.RestoreState Restore() { Reads++; return new SignIn.RestoreState.Unavailable("keychain-unavailable"); }
        internal int Resumes;
        internal GatewaySession? Resume(StoredAccount account) { Resumes++; return null; }
    }
    internal sealed class FixtureLaunchChat
    {
        internal readonly TaskCompletionSource<bool> Preference = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal Action? BeforePersist;
        internal void SetResume(bool enabled, string account) { BeforePersist?.Invoke(); Preference.SetResult(enabled); }
        internal void Launch() { }
        internal void Closed() { }
    }
    internal sealed partial class FixtureNews
    {
        internal IReadOnlyList<GatewayRow> Rows { get; set; } = [];
        internal string? SwitchingTo { get; private set; }
        internal readonly List<bool> SwitchResults = [];
        internal StoredAccount BeginSwitch(string key) { SwitchingTo = key; return new("https://example.com", "fixture"); }
        internal void EndSwitch(bool switched) { SwitchingTo = null; SwitchResults.Add(switched); }
        internal bool IsRemoving(string key) => false;
        internal SavedAccounts Saved() => throw new NotSupportedException();
        internal void AccountsChanged() => throw new NotSupportedException();
    }
    internal static class SafeDialog
    {
        internal static Task<Microsoft.UI.Xaml.Controls.ContentDialogResult?> ShowAsync(
            Microsoft.UI.Xaml.XamlRoot? root, Microsoft.UI.Xaml.Controls.ContentDialog dialog) =>
            throw new NotSupportedException();
    }
}
namespace Microsoft.UI.Xaml
{
    internal sealed class RoutedEventArgs;
    internal sealed class DispatcherTimer
    {
        internal TimeSpan Interval { get; init; }
        internal bool IsEnabled { get; private set; }
        internal int Starts, Stops;
        internal event Action<object, object>? Tick;
        internal int Observers => Tick?.GetInvocationList().Length ?? 0;
        internal Action CaptureTick() { var cb = Tick; return () => cb?.Invoke(this, EventArgs.Empty); }
        internal void Start() { IsEnabled = true; Starts++; }
        internal void Stop() { IsEnabled = false; Stops++; }
    }
}
namespace Microsoft.UI.Xaml.Controls
{
    internal enum ContentDialogResult { Primary }
    internal enum ContentDialogButton { Close, Primary }
    internal sealed class ContentDialog
    {
        internal string? Title, Content, CloseButtonText, PrimaryButtonText;
        internal ContentDialogButton DefaultButton;
        internal XamlRoot? XamlRoot;
        internal Task<ContentDialogResult> ShowAsync() => throw new NotSupportedException();
    }
}
namespace HermesHQ.Features.Onboarding
{
    internal sealed class OnboardingView : UIElement
    {
        internal sealed class Options
        {
            internal OnboardingGate.Entry Entry;
            internal string? Address, Username, Notice, SheetTitle;
            internal IReadOnlyList<(string, string)>? OtherGateways;
        }
        internal OnboardingView(Options options) { }
        internal event Action<GatewaySession, SignInOutcome>? SignedIn;
        internal void Return(GatewaySession session) => SignedIn!.Invoke(session, SignInOutcome.Enter);
        internal event Action<string>? SwitchTo { add { } remove { } }
        internal event Action? Cancelled { add { } remove { } }
        internal void PushLocked(UIElement view) => throw new NotSupportedException();
    }
}
namespace HermesHQ.Features.Gateways
{
    internal sealed class UpdateHermesView : UIElement { internal UpdateHermesView(UpdateHermesModel model) => throw new NotSupportedException(); }
    internal sealed class LaunchView(Action retry, Action different) : UIElement
    {
        internal Action Retry => retry;
        internal Action Different => different;
        internal bool OffersDifferentGateway { get; init; }
        internal List<LaunchGate.View> Frames { get; } = [];
        internal void Render(LaunchGate.View frame) => Frames.Add(frame);
    }
    public sealed partial class OfflineView : UIElement
    {
        private readonly OfflineScreenModel _model;
        internal OfflineView(OfflineScreenModel model, Action retry, Action different, Action again, Action<string> change)
        { _model = model; ObserveCountdown(); Render(); }
        private event Action<object, RoutedEventArgs>? Loaded, Unloaded;
        internal Action CaptureLoad() { var cb = Loaded; return () => cb?.Invoke(this, new()); }
        internal Action CaptureUnload() { var cb = Unloaded; return () => cb?.Invoke(this, new()); }
        internal int Observers => (Loaded?.GetInvocationList().Length ?? 0) + (Unloaded?.GetInvocationList().Length ?? 0) + _tick.Observers;
        internal DispatcherTimer Clock => _tick;
        internal Action<string> Announcement => _model.Announce;
        internal int Announcements;
        private void AnnounceStatus(string words) => Announcements++;
        internal int Paints;
        internal void Render() => RenderStatus();
        private void RenderStatus() => Paints++;
        internal void FocusStatus() { }
    }
    public static partial class LaunchFlow
    {
        internal static Task PendingPreferences => Task.WhenAll(PendingWork);
        // Same entry points as launch/restore, but without OS discovery, real persistence or a network client.
        internal static void ShowFixture(MainWindow window, HermesClient? client)
        {
            AttachWindow(window); Cover();
            if (client == null) { Restore(); return; }
            AppState.Client = client; Watch(client); _stage = Stage.Waiting; _gate!.Mount(); StateChanged();
        }
    }
}
