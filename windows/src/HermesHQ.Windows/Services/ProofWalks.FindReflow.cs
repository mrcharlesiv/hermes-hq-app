namespace HermesHQ.Services;

using Hermes.Core.Transcripts;

#if WINDOWS
using Hermes.Core.Bots;
using Hermes.Core.Shell;
using HermesHQ.Features.ChatFind;
using HermesHQ.Pages;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Windows.UI.ViewManagement;
using static FindPaneEvidence;

internal static partial class ProofWalks
{
    // ChatFindBar.Attach installs Find beside the transcript, not on the window or inspector. Never
    // fall back to an arbitrary ancestor with room to resize. Recheck these identities at each reading.
    private static Grid FindPaneFor(string tag, Control transcript, FrameworkElement bar, TextBox field)
    {
        Page? page = tag switch
        {
            "chat-find" or "text-scale-chat-find" => ChatPage.Current,
            "group-room-find" => GroupRoomPage.Current,
            _ => null,
        };
        static bool InCell(FrameworkElement e, int row) => Grid.GetRow(e) == row && Grid.GetRowSpan(e) == 1
            && Grid.GetColumn(e) == 0 && Grid.GetColumnSpan(e) == 1;
        if (page is not { IsLoaded: true } || Root.XamlRoot is not { } root || !ReferenceEquals(page.XamlRoot, root) || !Within(page, Root)
            || !ReferenceEquals(transcript.XamlRoot, root) || !ReferenceEquals(bar.XamlRoot, root) || !ReferenceEquals(field.XamlRoot, root)
            || !ReferenceEquals(FindIn(page, "chat.transcript"), transcript) || !ReferenceEquals(FindIn(page, "chatfind.bar"), bar)
            || !ReferenceEquals(FindIn(bar, "chatfind.field"), field) || VisualTreeHelper.GetParent(transcript) is not Grid pane
            || !ReferenceEquals(VisualTreeHelper.GetParent(bar), pane) || !InCell(transcript, 1) || !InCell(bar, 1))
            throw new InvalidOperationException($"{tag}: missing the installed Find and transcript in the same active pane cell");

        return page switch
        {
            ChatPage chat when transcript is ListView && ReferenceEquals(chat.FindName("Messages"), transcript)
                && chat.Content is Grid outer && ReferenceEquals(VisualTreeHelper.GetParent(pane), outer) && InCell(pane, 0) => pane,
            GroupRoomPage room when transcript is ScrollViewer && ReferenceEquals(room.Content, pane) => pane,
            _ => throw new InvalidOperationException($"{tag}: missing the chat content column or room root"),
        };
    }

    private static async Task FindReflowAsync(Control transcript, Thickness original, FrameworkElement bar, TextBox field,
        Func<string, Task> shot, string tag = "chat-find")
    {
        var pane = FindPaneFor(tag, transcript, bar, field);
        var root = pane.XamlRoot;
        var finder = ChatFindBar.ForTranscript(transcript);
        if (finder is not { IsOpen: true }) throw new InvalidOperationException($"{tag}: missing this transcript's open Find");
        var query = tag switch { "group-room-find" => GroupRoomWalkProof.FindQuery, "chat-find" => WalkProof.FindWord, _ => "example" };
        if (field.Text != query || !ReferenceEquals(FocusedIn(), field)) throw new InvalidOperationException($"{tag}: missing the focused fixture query");
        var matches = finder.MatchCount;
        var count = finder.CountText;
        var hadEarlier = FindIn(bar, "chatfind.earlier") != null;
        var settings = new UISettings();
        var scale = settings.TextScaleFactor;
        var wideStacked = UndoPillClock.AccessibilityTextScale(scale);
        var priorSelection = (field.SelectionStart, field.SelectionLength);
        // Neither an empty caret nor SelectAll: either accidental reset must be observable.
        var selection = (Start: 1, Length: query.Length - 2);
        var disturbed = false;
        void FocusLeft(object sender, RoutedEventArgs e) => disturbed = true;
        void SelectionMoved(object sender, RoutedEventArgs e) => disturbed |= (field.SelectionStart, field.SelectionLength) != selection;

        pane.UpdateLayout();
        Widths MeasureWidths() => new(pane.ActualWidth, transcript.ActualWidth, bar.ActualWidth);
        var wide = MeasureWidths();
        var narrow = Widths.Narrow(bar.Margin.Left, bar.Margin.Right);
        if (wide.Bar < 420 || !wide.WiderThan(narrow)) throw new InvalidOperationException($"{tag}: missing a wide starting pane: {wide}");

        async Task WaitForWidths(string phase, Widths target, bool closed = false)
        {
            try
            {
                await Until(() =>
                {
                    pane.UpdateLayout();
                    var actual = MeasureWidths();
                    // SizeChanged updates the padding after measure/arrange. Let that update arrive
                    // rather than mistaking a single in-flight layout pass for the target frame.
                    var ready = closed ? actual.SamePane(target) && bar.Visibility == Visibility.Collapsed && transcript.Padding.Equals(original)
                        : actual.Matches(target) && bar.ActualHeight > 0 && Math.Abs(transcript.Padding.Top - original.Top - bar.ActualHeight - 8) <= 1;
                    return ready ? pane : null;
                }, $"{tag} {phase} pane, transcript and Find");
            }
            catch (TimeoutException e)
            {
                throw new InvalidOperationException($"{tag}/{phase}: missing target {target}; measured {MeasureWidths()}, "
                    + $"bar height={bar.ActualHeight}, transcript top={original.Top}->{transcript.Padding.Top}", e);
            }
        }

        Box Bounds(FrameworkElement e)
        {
            var r = e.TransformToVisual(pane).TransformBounds(new Rect(0, 0, e.ActualWidth, e.ActualHeight));
            return new(r.X, r.Y, r.Width, r.Height);
        }
        void RequireSamePane()
        {
            if (!ReferenceEquals(FindPaneFor(tag, transcript, bar, field), pane) || !ReferenceEquals(pane.XamlRoot, root)
                || (Automation.ShotOf is { } capture && !ReferenceEquals(capture, Root)))
                throw new InvalidOperationException($"{tag}: Find changed panes, windows or capture roots");
        }
        void Check(string phase, Widths target, bool stacked, bool checkSelection = true)
        {
            pane.UpdateLayout();
            RequireSamePane();
            var actualScale = settings.TextScaleFactor;
            if (Math.Abs(actualScale - scale) > 0.0001 || (tag == "text-scale-chat-find" && (!wideStacked || TextScaleWalkProof.Scale(actualScale) != null)))
                throw new InvalidOperationException($"{tag}/{phase}: missing the original text scale (measured {actualScale})");
            var earlier = FindIn(bar, "chatfind.earlier");
            if (!finder.IsOpen || !ReferenceEquals(FocusedIn(), field) || field.Text != query || (checkSelection && (disturbed || (field.SelectionStart, field.SelectionLength) != selection))
                || finder.MatchCount != matches || finder.CountText != count || Need(bar, "chatfind.count") is not TextBlock label || label.Text != count
                || count.Length == 0 || (earlier != null) != hadEarlier)
                throw new InvalidOperationException($"{tag}/{phase}: Find lost its focused query, selection, count or paging action");
            var p = transcript.Padding;
            var margin = bar.Margin;
            var widths = MeasureWidths();
            var frame = new FindPaneEvidence(Bounds(pane), Bounds(transcript), Bounds(bar), Bounds(field),
                ControlIds.Select(id => Bounds(Need(bar, id))).ToArray(), earlier == null ? null : Bounds(earlier));
            // Only fixture geometry in pane-relative DIPs, never the query or any message text.
            AppLog.Note("automation", $"{tag}/{phase}: {(tag == "group-room-find" ? "GroupRoomPage.Content" : "ChatPage.Content/column 0")}, "
                + $"row {Grid.GetRow(transcript)} column {Grid.GetColumn(transcript)}, scale={actualScale:0.###}; {widths}; {frame.Describe()}; "
                + $"bar margins={margin.Left},{margin.Top},{margin.Right}; transcript top={original.Top}->{p.Top}");
            if (!widths.Matches(target) || p.Left != original.Left || p.Right != original.Right || p.Bottom != original.Bottom)
                throw new InvalidOperationException($"{tag}/{phase}: pane widths or transcript side/bottom insets changed unexpectedly");
            if (frame.Problem(stacked, margin.Left, margin.Top, margin.Right, bar.MaxWidth, original.Top, p.Top) is { } problem)
                throw new InvalidOperationException($"{tag}/{phase}: {problem}");
        }

        // A binding takes precedence over even a numeric ReadLocalValue. Clearing just our override
        // reveals the original style/default; restoring an effective double would mask it.
        var dp = FrameworkElement.MaxWidthProperty;
        var limit = new FindPaneLimit(DependencyProperty.UnsetValue, () => (object?)pane.GetBindingExpression(dp) ?? pane.ReadLocalValue(dp),
            width => pane.MaxWidth = width, () => pane.ClearValue(dp));
        Task WhileNarrow(Func<Task> observe)
        {
            RequireSamePane();
            return limit.UseAsync(narrow.Pane, async () =>
            {
                await WaitForWidths("narrow", narrow);
                await observe();
            }, () => WaitForWidths("restored", wide, closed: !finder.IsOpen));
        }

        try
        {
            field.Select(selection.Start, selection.Length);
            field.LostFocus += FocusLeft;
            field.SelectionChanged += SelectionMoved;
            await WaitForWidths("wide", wide);
            Check("wide", wide, wideStacked);
            await WhileNarrow(async () =>
            {
                Check("narrow", narrow, true);
                await shot(tag + "-narrow");
            });
            Check("expanded", wide, wideStacked);
            await shot(tag + "-expanded");

            // Close at the *other* width: reusing the last open size must fail the reopened comparison.
            await WhileNarrow(() =>
            {
                Check("before-close", narrow, true);
                finder.Close();
                pane.UpdateLayout();
                if (finder.IsOpen || bar.Visibility != Visibility.Collapsed || field.Text.Length != 0 || !transcript.Padding.Equals(original))
                    throw new InvalidOperationException($"{tag}: closing Find did not clear the query and restore padding");
                return Task.CompletedTask;
            });
            if (!ReferenceEquals(transcript.XamlRoot, root) || !Within(transcript, Root))
                throw new InvalidOperationException($"{tag}: the restored fixture is no longer attached");
            finder.Open();
            await Until(() => ReferenceEquals(FocusedIn(), field) && ReferenceEquals(FindIn(bar, "chatfind.field"), field) ? field : null,
                $"{tag} reopened Find to focus the same field");
            // Insert into the empty edit. Wait for the ordinary TextChanged search rather than
            // AutomationFind's immediate result (its pending typing timer could reset the caller's next F3).
            RequireSamePane();
            if (field.GetBindingExpression(TextBox.TextProperty) != null) throw new InvalidOperationException($"{tag}: fixture query is bound; reopened search missing");
            field.SelectedText = query;
            await Until(() => finder.CountText == count && finder.MatchCount == matches ? field : null, $"{tag} reopened query to finish searching");
            await WaitForWidths("reopened", wide);
            Check("reopened", wide, wideStacked, checkSelection: false);
        }
        finally
        {
            field.LostFocus -= FocusLeft;
            field.SelectionChanged -= SelectionMoved;
            if (field.Text == query) field.Select(priorSelection.SelectionStart, priorSelection.SelectionLength);
        }
    }

    private static async Task LargeTextFindAsync(ChatPage page, Control transcript, Func<string, Task> shot)
    {
        if (TextScaleWalkProof.Scale(new UISettings().TextScaleFactor) is { } missing) throw new InvalidOperationException(missing);
        var finder = ChatFindBar.ForTranscript(transcript) ?? throw new InvalidOperationException("no Find installed on the fixture chat");
        if (finder.IsOpen) throw new InvalidOperationException("the fixture Find was already open");
        var original = transcript.Padding;
        try
        {
            finder.AutomationFind("example");
            var field = (TextBox)await Until(() => FindIn(page, "chatfind.field") is TextBox f && ReferenceEquals(FocusedIn(), f) ? f : null, "large-text Find to focus its field");
            await FindReflowAsync(transcript, original, Need(page, "chatfind.bar"), field, shot, "text-scale-chat-find");
        }
        finally { finder.Close(); }
        if (!transcript.Padding.Equals(original)) throw new InvalidOperationException("large-text Find did not restore the transcript");
    }
}
#endif

// Borrow only an unset pane MaxWidth. Re-read ownership after awaits: a new expression belongs to
// the page, even if it resolves to our number. Check actual restored sizes on success *and* failure.
internal sealed record FindPaneLimit(object Unset, Func<object?> ReadLocal, Action<double> Set, Action Clear)
{
    internal async Task UseAsync(double width, Func<Task> observe, Func<Task> checkRestored)
    {
        if (!ReferenceEquals(ReadLocal(), Unset)) throw new InvalidOperationException("Find pane MaxWidth already owned; narrow geometry missing");
        try { Set(width); await observe(); }
        finally
        {
            var local = ReadLocal();
            if (local is double cap && cap == width) Clear();
            if (!ReferenceEquals(ReadLocal(), Unset)) throw new InvalidOperationException("Find pane MaxWidth changed ownership or was not restored");
            await checkRestored();
        }
    }
}

// The portable tests link this file and feed the same judge deliberate bad measurements. Only the
// Windows walk above can supply observations; neither the requested width nor a PNG is a measurement.
internal sealed record FindPaneEvidence(FindPaneEvidence.Box Pane, FindPaneEvidence.Box Transcript, FindPaneEvidence.Box Bar,
    FindPaneEvidence.Box Field, FindPaneEvidence.Box[] Controls, FindPaneEvidence.Box? Earlier)
{
    internal static readonly string[] ControlIds = ["chatfind.count", "chatfind.previous", "chatfind.next", "chatfind.done"];
    private const double Tolerance = 1; // a rounded DIP at fractional display scales
    private static bool Near(double a, double b) => Math.Abs(a - b) <= Tolerance;

    internal readonly record struct Widths(double Pane, double Transcript, double Bar)
    {
        internal static Widths Narrow(double left, double right)
        {
            const double bar = 220; // the Mac comparison's outer Find width, not the width of the pane
            var pane = left + bar + right;
            return new(pane, pane, bar);
        }
        internal bool WiderThan(Widths other) => Pane > other.Pane + Tolerance && Transcript > other.Transcript + Tolerance && Bar > other.Bar + Tolerance;
        internal bool SamePane(Widths other) => Near(Pane, other.Pane) && Near(Transcript, other.Transcript);
        internal bool Matches(Widths other) => SamePane(other) && Near(Bar, other.Bar);
    }

    internal readonly record struct Box(double X, double Y, double Width, double Height)
    {
        internal double Right => X + Width;
        internal double Bottom => Y + Height;
        private bool Drawn => double.IsFinite(X) && double.IsFinite(Y) && double.IsFinite(Right) && double.IsFinite(Bottom) && Width > 0 && Height > 0;
        internal bool Contains(Box b) => Drawn && b.Drawn && b.X >= X - Tolerance && b.Y >= Y - Tolerance && b.Right <= Right + Tolerance && b.Bottom <= Bottom + Tolerance;
        public override string ToString() => FormattableString.Invariant($"({X:0.##},{Y:0.##},{Width:0.##},{Height:0.##})");
    }

    internal string Describe() => $"pane={Pane} transcript={Transcript} bar={Bar} field={Field} "
        + string.Join(" ", ControlIds.Zip(Controls, (id, b) => $"{id}={b}")) + (Earlier is { } e ? $" earlier={e}" : "");

    internal string? Problem(bool stacked, double left, double top, double right, double barLimit, double originalTop, double paddedTop)
    {
        if (!Pane.Contains(Transcript) || !Near(Transcript.X, Pane.X) || !Near(Transcript.Width, Pane.Width)) return "transcript does not fill the pane column";
        // The Mac guide is centred even when capped. Within the pane, account for both real side
        // margins and split only the spare room left by the existing (untouched) Find cap.
        var available = Transcript.Width - left - right;
        var drawn = Math.Min(barLimit, available);
        var spareSide = (available - drawn) / 2;
        if (!Transcript.Contains(Bar) || !(left > 0 && right > 0) || !Near(Bar.Width, drawn) || !Near(Bar.Y, Transcript.Y + top)
            || !Near(Bar.X, Transcript.X + left + spareSide) || !Near(Bar.Right, Transcript.Right - right - spareSide))
            return "bar does not fit the transcript row and its side margins";
        // ChatViewController.showFindBar(_:) at Mac 1240: findInset = height + 8, not the last row's height.
        if (!Near(paddedTop - originalTop, Bar.Height + 8) || Transcript.Y + paddedTop < Bar.Bottom - Tolerance)
            return "transcript inset does not clear the drawn bar by its measured height and gap";
        if (!Pane.Contains(Field) || !Bar.Contains(Field) || Field.Width < ChatFindLayout.MinimumField) return "field is clipped or too narrow";
        if (Controls.Length != ControlIds.Length) return "missing Find control";
        for (var i = 0; i < Controls.Length; i++)
        {
            var c = Controls[i];
            if (!Pane.Contains(c) || !Bar.Contains(c) || (i > 0 && c.X < Controls[i - 1].Right - Tolerance)) return $"{ControlIds[i]} is clipped or out of order";
            if (stacked ? c.Y < Field.Bottom - Tolerance : c.X < Field.Right - Tolerance || c.Bottom <= Field.Y || c.Y >= Field.Bottom)
                return $"{ControlIds[i]} is on the wrong row";
        }
        if (Controls.Max(c => c.Y) >= Controls.Min(c => c.Bottom)) return "Find controls do not share a row";
        if (Earlier is { } earlier && (!Pane.Contains(earlier) || !Bar.Contains(earlier) || earlier.Y < Math.Max(Field.Bottom, Controls.Max(c => c.Bottom)) - Tolerance))
            return "Search Earlier Messages is clipped or overlaps the controls";
        return null;
    }
}
