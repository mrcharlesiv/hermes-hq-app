using System.Runtime.CompilerServices;
using Hermes.Core.Attachments;
using Hermes.Core.Chat;
using Hermes.Core.Workspace;
using HermesHQ.Features.Attachments;
using HermesHQ.Services;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.Workspace;

/// The chat inspector's Files tab (MacInspector `.files`, the chat's `WorkspacePage(kind: .files, panel: true)`): the
/// chat's own folder, its rows with their kinds, a folder opened in place with Back, a file's text in the panel, and
/// anything that isn't text opened in its own app. Until the chat names a folder it says the Mac's "No Folder".
internal sealed class InspectorFiles : Grid
{
    private static readonly ConditionalWeakTable<ChatSession, InspectorFiles> Views = new();

    public static FrameworkElement? For(ChatSession session) => Views.GetValue(session, s => new InspectorFiles(s));

    private readonly ChatSession _session;
    private readonly ContentControl _content = new() { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    /// [WIN-INSPECTOR-FILES-LIFETIME] Which lifetime, folder and read may show anything, or ask for an alert or an
    /// open: Hermes.Core.Workspace.InspectorFilesFlow. This view only draws what it holds.
    private readonly InspectorFilesFlow _flow;
    private InspectorFilesContent? _drawn;

    private InspectorFiles(ChatSession session)
    {
        _session = session;
        var ui = DispatcherQueue.GetForCurrentThread();
        _flow = new InspectorFilesFlow(() => ChatFolders.FolderOf(_session), MakeReader, work => ui.TryEnqueue(() => work()));
        _flow.Changed += Render;
        _flow.OpenExternally += (path, name) => _ = MediaActions.OpenAsync(path, name);
        _flow.OpenFailed += reason => _ = W.AskAsync(XamlRoot, "Couldn’t Open This File", reason);
        Children.Add(_content);
        AutomationProperties.SetAutomationId(this, "inspector.files");
        Render();
        // Subscribed only while on screen, so a closed chat's view isn't kept alive by the static event. Leaving
        // cancels what is out; coming back reads again only what was cut short (or failed), keeping what was shown.
        Loaded += (_, _) => { ChatFolders.FolderChanged += OnFolder; _flow.Attach(); };
        Unloaded += (_, _) => { ChatFolders.FolderChanged -= OnFolder; _flow.Detach(); };
    }

    private void OnFolder(ChatSession session)
    {
        if (session == _session) DispatcherQueue.TryEnqueue(_flow.FolderChanged);
    }

    private sealed class Reader(ChatWorkspace workspace) : IInspectorFilesReader
    {
        public Task<List<WorkspaceEntry>> ListAsync(string directory, CancellationToken ct) => workspace.ListAsync(directory, ct);
        public Task<WorkspaceFileText> ReadTextAsync(string path, CancellationToken ct) => workspace.ReadTextAsync(path, ct);

        public async Task<string> DownloadAsync(WorkspaceEntry entry, CancellationToken ct)
        {
            var target = Path.Combine(AppPaths.Root, "cache", "inspector-" + Guid.NewGuid().ToString("n")[..12], AttachmentCenter.SafeName(entry.Name));
            await workspace.DownloadAsync(entry.Path, target, ct);
            return target;
        }
    }

    private IInspectorFilesReader? MakeReader() =>
        AppState.Client is { } c ? new Reader(new ChatWorkspace(new SessionWorkspaceRest(c.Session), _session.Profile)) : null;

    private void Render()
    {
        var content = _flow.Content;
        if (ReferenceEquals(content, _drawn)) return;
        _drawn = content;
        _content.Content = content switch
        {
            InspectorFilesContent.Listing listing => Draw(listing),
            InspectorFilesContent.Loading loading => Page(loading.Folder, loading.Folder != _flow.Root, W.Loading()),
            InspectorFilesContent.Text text => new FileTextView(text.Name, text.File.Text, diff: false,
                text.File.Truncated ? WorkspaceRoot.TruncatedNotice(text.File.ByteSize) : null,
                WorkspaceRoot.IsMarkdown(text.Name) && !text.File.Truncated, null, () => _flow.Back()),
            _ => W.State("folder", "No Folder", "This chat isn’t working in a folder, so there are no files to show.", id: "inspector.files.none"),
        };
    }

    private FrameworkElement Draw(InspectorFilesContent.Listing listing)
    {
        FrameworkElement body;
        if (listing.Failure is { } failure)
            body = W.State("exclamationmark.triangle", failure.Title, failure.Body, ("Try Again", () => _flow.Retry()));
        else if (listing.Rows.Count == 0)
            body = W.State("folder", WorkspaceRoot.EmptyFolder.Title, WorkspaceRoot.EmptyFolder.Body);
        else
        {
            var list = new StackPanel { Padding = new Thickness(6, 0, 6, 12) };
            foreach (var entry in listing.Rows) list.Children.Add(Row(entry));
            body = new ScrollViewer { Content = list };
        }
        return Page(listing.Folder, listing.Up != null, body);
    }

    private Grid Page(string folder, bool back, FrameworkElement body)
    {
        var page = new Grid();
        page.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        page.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var head = new Grid { Padding = new Thickness(12, 10, 12, 8), ColumnSpacing = 6 };
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        if (back)
        {
            var button = W.BarButton("\uE72B", "Back", "inspector.files.back");
            button.Click += (_, _) => _flow.Back();
            head.Children.Add(button);
        }
        var words = new StackPanel();
        words.Children.Add(W.Text(WorkspaceRoot.Name(folder), 14, bold: true));
        var path = W.Text(folder, 12, W.Secondary);
        path.FontFamily = W.Mono;
        path.TextTrimming = TextTrimming.CharacterEllipsis;
        ToolTipService.SetToolTip(path, folder);
        words.Children.Add(path);
        Grid.SetColumn(words, 1);
        head.Children.Add(words);
        page.Children.Add(head);
        Grid.SetRow(body, 1);
        page.Children.Add(body);
        return page;
    }

    private Button Row(WorkspaceEntry entry)
    {
        var kind = WorkspaceRoot.KindWord(entry.Name, entry.IsDirectory);
        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(20) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(entry.IsDirectory ? W.Glyph("", 14, W.Accent) : W.Glyph(MediaKinds.Glyph(MediaKinds.Kind(entry.Name)), 14, W.Secondary));
        var name = W.Text(entry.Name, 13);
        Grid.SetColumn(name, 1);
        grid.Children.Add(name);
        var trailing = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        trailing.Children.Add(W.Text(kind, 12, W.Secondary));
        if (entry.IsDirectory) trailing.Children.Add(W.Glyph("", 9, W.Tertiary));
        Grid.SetColumn(trailing, 2);
        grid.Children.Add(trailing);
        var b = new Button
        {
            Content = grid, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0), Padding = new Thickness(6, 5, 6, 5),
        };
        AutomationProperties.SetName(b, $"{entry.Name}, {kind}");
        AutomationProperties.SetAutomationId(b, "workspace.entry." + entry.Name);
        b.Click += (_, _) => _flow.Open(entry);
        var copy = new MenuFlyoutItem { Text = "Copy Path", Icon = new FontIcon { Glyph = "" } };
        copy.Click += (_, _) => MediaActions.CopyText(entry.Path);
        b.ContextFlyout = new MenuFlyout { Items = { copy } };
        return b;
    }
}
