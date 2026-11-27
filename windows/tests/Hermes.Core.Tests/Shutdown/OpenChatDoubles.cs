// The page's actual open continuation, teardown, ChatContext and shutdown plan run here. Only the
// gateway wait, rendering/dispatcher endpoints and bot-list notification are inert; there is no connection.
using System.ComponentModel;
using HermesHQ.Features.Bots;
using HermesHQ.Shell;
using HermesHQ.ViewModels;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Microsoft.UI.Xaml { public enum Visibility { Collapsed, Visible } }
namespace Microsoft.UI.Xaml.Controls
{
    public class Page;
    public sealed class StackPanel;
    public sealed class Grid;
    public sealed class ContentControl;
    public sealed class MenuFlyout;
    public sealed class TextBox;
    public sealed class ListView;
}
namespace Microsoft.UI.Xaml.Input { public sealed class KeyRoutedEventArgs; }
namespace Microsoft.UI.Dispatching
{
    internal enum DispatcherQueuePriority { Low }
    internal sealed partial class DispatcherQueueTimer
    {
        internal event Action<DispatcherQueueTimer, object>? Tick;
        internal bool IsRunning { get; private set; }
        internal void Start() { Starts++; IsRunning = true; }
        internal void Stop() { Stops++; IsRunning = false; }
        internal Action TakeTick()
        {
            Assert.True(IsRunning);
            IsRunning = false;
            return CaptureTick();
        }
        // Keep a handed-off callback without consuming the timer's currently armed interval.
        internal Action CaptureTick()
        {
            var posted = Tick;
            return () => posted?.Invoke(this, EventArgs.Empty);
        }
    }
    internal class QueuedUi
    {
        private readonly Queue<Action> _work = new();
        internal int Count => _work.Count;
        internal bool TryEnqueue(Action run) { _work.Enqueue(run); return true; }
        internal bool TryEnqueue(DispatcherQueuePriority priority, Action run) => TryEnqueue(run);
        internal void Drain() { while (_work.TryDequeue(out var run)) run(); }
    }
}
namespace HermesHQ.Features.Bots
{
    internal sealed class ListsHub
    {
        internal static ListsHub? Current { get; set; }
        internal sealed class BotList
        {
            internal List<(string, bool)> Changes { get; } = [];
            internal void NoteBotOpening(string profile, bool opening) => Changes.Add((profile, opening));
        }
        internal BotList Bots { get; } = new();
    }
}
namespace HermesHQ.ViewModels
{
    internal sealed class PendingSession
    {
        internal TaskCompletionSource Result { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal Task OpenAsync() => Result.Task;
        internal event Action<string>? TitleChanged;
        internal event Action? OpenRecovered;
        internal void NotifyTitleAndRecovery() { TitleChanged?.Invoke("fixture"); OpenRecovered?.Invoke(); }
        internal event Action? Changed;
        internal void NotifyChange() => Changed?.Invoke();
        internal Func<Task> Dispose { get; set; } = () => Task.CompletedTask;
        internal int Disposals { get; private set; }
        internal ValueTask DisposeAsync() { Disposals++; return new(Dispose()); }
    }
    public sealed partial class ChatViewModel
    {
        private readonly QueuedUi _ui = new();
        private readonly DispatcherQueueTimer _timer = new();
        internal ChatViewModel() => ObserveChanges();
        internal QueuedUi RenderQueue => _ui;
        internal DispatcherQueueTimer RenderTimer => _timer;
        internal int Paints { get; private set; }
        private void Apply() { _dirty = false; Paints++; NotifyRows(); }
        internal PendingSession Session { get; } = new();
        internal List<int> Items { get; } = [];
        internal event PropertyChangedEventHandler? PropertyChanged;
        internal event Action? ItemsChanged;
        internal void NotifyRows() { PropertyChanged?.Invoke(this, new(nameof(Items))); ItemsChanged?.Invoke(); }
        internal int Disposals => Session.Disposals;
        internal Func<Task> Dispose { init => Session.Dispose = value; }
    }
}
namespace HermesHQ.Pages
{
    public sealed partial class ChatPage : Page, IDisposable
    {
        internal sealed class Ring { internal bool IsActive { get; set; } = true; }
        internal sealed class Problem { internal string? Text { get; set; } internal Visibility Visibility { get; set; } }
        internal sealed class FitStub { internal void SetTitle(string title) { } }
        internal Ring LoadingRing { get; } = new();
        internal Problem LoadProblem { get; } = new();
        internal Problem TitleText { get; } = new();
        public string ChatTitle { get; private set; } = "";
        private readonly FitStub _composerFit = new();
        internal Microsoft.UI.Dispatching.QueuedUi DispatcherQueue { get; } = new();
        private readonly bool _stickToEnd = true;
        internal int Landings { get; private set; }
        internal int ComposerUpdates { get; private set; }
        private void LandOrScrollToEnd() => Landings++;
        private void ScrollToEnd() => Landings++;
        private void UpdateComposer() => ComposerUpdates++;
        private void StopActionsForClose() { }

        internal (ChatContext Context, Task Opened) OpenFixture(ChatViewModel vm)
        {
            ListsHub.Current ??= new();
            var opening = new ChatContext
            {
                // The view model supplies the deliberately pending open in lieu of a gateway session.
                Session = null!, Page = this, Shelf = new(), ComposerLeading = new(), ComposerTrailing = new(),
                Dock = new(), MoreMenu = new(), HeaderTrailing = new(), Inspector = new(), ShowInspector = _ => { },
                Composer = new(), TranscriptFooter = new(), TranscriptOverlay = new(), Transcript = new(),
                SetStatus = _ => { }, TranscriptEmpty = new(), RowCount = () => vm.Items.Count,
            };
            var args = new Args("ivy", "fixture-chat", "Fixture chat", BotChat: true);
            AttachOpening(opening, vm, args);
            return (opening, FinishOpeningAsync(opening, vm, args));
        }

        public void Dispose() { if (Current == this) Current = null; ListsHub.Current = null; }
        internal Task LeaveFixtureAsync() => DetachAsync(leaving: true);
    }
}
