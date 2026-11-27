// These are the event publishers and native endpoints, not copies of the three production owners.
using Hermes.Core.Jobs;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Windows.Media.Core;
using Windows.Storage.Streams;

namespace Microsoft.UI.Dispatching
{
    internal sealed class DispatcherQueue : QueuedUi
    {
        public static DispatcherQueue GetForCurrentThread() => HermesHQ.App.Window!.DispatcherQueue;
        public List<DispatcherQueueTimer> Timers { get; } = [];
        public DispatcherQueueTimer CreateTimer() { var timer = new DispatcherQueueTimer(); Timers.Add(timer); return timer; }
    }
    internal sealed partial class DispatcherQueueTimer
    {
        public TimeSpan Interval { get; set; }
        public bool IsRepeating { get; set; }
        public int Starts { get; private set; }
        public int Stops { get; private set; }
        public int Subscribers => Tick?.GetInvocationList().Length ?? 0;
    }
}
namespace Microsoft.UI.Xaml
{
    internal enum WindowActivationState { CodeActivated, Deactivated }
    internal sealed record WindowActivatedEventArgs(WindowActivationState WindowActivationState);
    internal sealed partial class Window
    {
        public DispatcherQueue DispatcherQueue { get; } = new();
        public event Action<object, WindowActivatedEventArgs>? Activated;
        public int Subscribers => Activated?.GetInvocationList().Length ?? 0;
        public Action CaptureActivation(WindowActivationState state = WindowActivationState.CodeActivated)
        {
            var subscribers = Activated;
            return () => subscribers?.Invoke(this, new(state));
        }
    }
}
namespace HermesHQ
{
    // Never construct a real HermesClient: its constructor starts a socket.
    internal sealed partial record HermesClient(string AccountId);
}
namespace HermesHQ.Services
{
    internal static partial class AppState
    {
        public static HermesClient? Client { get; set; }
        public static event Action<HermesClient?>? ClientChanged;
        public static int Subscribers => ClientChanged?.GetInvocationList().Length ?? 0;
        public static void NotifyClient() => ClientChanged?.Invoke(Client);
        public static FixtureNews Gateways { get; } = new();
    }
    internal sealed partial class FixtureNews
    {
        public Hermes.Core.Gateways.GatewayHub? Inner { get; set; }
        public bool IsShown => Inner?.IsShown ?? true;
        public int Checks, Activations;
        public Task CheckAsync(bool force) { Checks++; return Inner?.CheckAsync(force) ?? Task.CompletedTask; }
        public void CheckSoon(bool force) { Activations++; Inner?.CheckSoon(force); }
        public Task StopNewsForQuitAsync() => Inner?.StopNewsForQuitAsync() ?? Task.CompletedTask;
    }
}
namespace HermesHQ.Features.Transcript
{
    internal sealed class FilePreferences
    {
        public static readonly FilePreferences Shared = new();
        public string? Get(string key) => null;
    }
}
namespace HermesHQ.Shell { internal static class Places { public static void InvalidateBadges() { } } }
namespace HermesHQ.Features.Jobs
{
    internal static partial class JobsSidebarBadge { private static void RegisterAppearance() { } }
    internal static class JobsServices
    {
        public static readonly JobsStore Store = new();
        public static JobsStore For(HermesClient client) => Store;
        // The real JobsBadgeHistory can read this absent synthetic directory; the fixture never marks anything seen.
        public static string CacheDirectory(string key) => Path.Combine(Path.GetTempPath(), "absent-" + key);
    }
    internal sealed class JobsStore
    {
        public IReadOnlyList<CronJob> Jobs { get; } = [new("fixture") { LastStatus = "ok", NextRunAt = DateTimeOffset.UtcNow.AddHours(1).ToString("O") }];
        public int WorkingCount => 0;
        public bool IsShowing => false;
        public event Action? Changed;
        public int Subscribers => Changed?.GetInvocationList().Length ?? 0;
        public void Notify() => Changed?.Invoke();
        public int Refreshes;
        public Task RefreshAsync() { Refreshes++; return Task.CompletedTask; }
    }
}
namespace HermesHQ.Features.Settings
{
    internal static class CompletionSoundSynth
    {
        public static ManualResetEventSlim? Hold;
        public static int Renders;
        public static byte[] Wav(int id)
        {
            if (Hold is { } wait && !wait.Wait(TimeSpan.FromSeconds(10))) throw new TimeoutException();
            Interlocked.Increment(ref Renders);
            return [(byte)id];
        }
    }
}
namespace Windows.Storage.Streams
{
    internal interface IRandomAccessStream : IDisposable { Stream Bytes { get; } }
    internal sealed class FixtureStream(Stream bytes) : IRandomAccessStream
    {
        public static int Opened, Closed;
        public Stream Bytes { get; } = bytes;
        public void Dispose() { Bytes.Dispose(); Closed++; }
    }
    internal static class StreamAdapter
    {
        public static IRandomAccessStream AsRandomAccessStream(this Stream stream) { FixtureStream.Opened++; return new FixtureStream(stream); }
    }
}
namespace Windows.Media.Core
{
    internal sealed class MediaSource(IRandomAccessStream stream) : IDisposable
    {
        public static int Created, Disposals;
        public static bool RefuseCreate;
        public bool Open => stream.Bytes.CanRead && !_closed;
        private bool _closed;
        public static MediaSource CreateFromStream(IRandomAccessStream stream, string type)
        {
            if (RefuseCreate || type != "audio/wav" || stream.Bytes.CanWrite) throw new InvalidOperationException();
            Created++; return new(stream);
        }
        internal int Sample() => stream.Bytes.ReadByte();
        public void Dispose() { _closed = true; Disposals++; }
    }
}
namespace Windows.Media.Playback
{
    internal enum MediaPlayerAudioCategory { SoundEffects }
    internal sealed class MediaPlayer : IDisposable
    {
        public static int Created, Plays, Disposals;
        public static bool RefuseBind;
        public static MediaPlayer? Current;
        public MediaPlayer() { Created++; Current = this; }
        public MediaPlayerAudioCategory AudioCategory { get; set; }
        private MediaSource? _source;
        public MediaSource? Source
        {
            get => _source;
            set { if (RefuseBind) throw new InvalidOperationException(); _source = value; }
        }
        public static List<int> Variants { get; } = [];
        public void Play() { Variants.Add(Source!.Sample()); Plays++; }
        public void Dispose() => Disposals++;
    }
}
