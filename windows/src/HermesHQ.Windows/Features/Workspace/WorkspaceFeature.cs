using System.Runtime.CompilerServices;
using Hermes.Core;
using Hermes.Core.Chat;
using Hermes.Core.Model;
using Hermes.Core.Workspace;
using HermesHQ.Features.Transcript;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.Workspace;

/// The Workspace pages (PARITY.md Pages: Files, Changes (Review), Terminal): the gateway computer's folders, a
/// project's uncommitted changes, and a shell there. Also the chat inspector's Files tab (the chat's own folder), and
/// remembering the chat last on screen, whose folder Files and Changes show when none was chosen.
public static class WorkspaceFeature
{
    public static void Register()
    {
        Places.Register("files", typeof(FilesPage));
        Places.Register("review", typeof(ChangesPage));
        Places.Register("terminal", typeof(TerminalPage));
        ChatExtensions.OnOpen.Add(ChatFolders.Note);
        ChatInspector.FilesView = InspectorFiles.For;
    }
}

/// The chat last on screen and each open chat's folder (MoreChatFolder in MoreWorkspacePages.swift). A chat learns its
/// folder from `session.resume` / `session.info` (`cwd`), often after it has opened.
internal static class ChatFolders
{
    private sealed class Box { public string? Cwd; }
    private static readonly ConditionalWeakTable<ChatSession, Box> Folders = new();
    private static readonly object Gate = new();
    private static ChatFolderRecord? _live;
    private static string? _liveAccount;

    /// A chat's folder changed (raised on any thread).
    public static event Action<ChatSession>? FolderChanged;

    public static string? FolderOf(ChatSession session) => Folders.TryGetValue(session, out var box) ? WorkspaceRoot.Folder(box.Cwd) : null;

    public static void Note(ChatContext ctx)
    {
        var session = ctx.Session;
        var account = AppState.Client?.AccountId;
        if (account == null) return;
        var bots = AppState.Client?.Bots ?? [];
        var isBotChat = session.Title == Bot.BotChatTitle || bots.Any(b => b.Name == session.Profile && b.DisplayName == session.Title);
        var box = Folders.GetOrCreateValue(session);
        ChatFolderRecord Record() => new(session.Profile.Length == 0 ? "default" : session.Profile, session.StoredId,
            WorkspaceRoot.Folder(box.Cwd), isBotChat ? null : session.Title);
        lock (Gate)
        {
            _live = Record();
            _liveAccount = account;
        }
        _live.Write(FilePreferences.Shared, account);
        void OnInfo(System.Text.Json.Nodes.JsonNode info)
        {
            if (info.Text("cwd") is not { } cwd || cwd == box.Cwd) return;
            box.Cwd = cwd;
            var now = Record();
            lock (Gate)
            {
                if (_live != null && _live.SessionId == now.SessionId) _live = now;
            }
            var saved = ChatFolderRecord.Read(FilePreferences.Shared, account);
            if (saved != null) ChatFolderRecord.Merge(saved, now).Write(FilePreferences.Shared, account);
            FolderChanged?.Invoke(session);
        }
        session.InfoChanged += OnInfo;
        ctx.Closed += () => session.InfoChanged -= OnInfo;
    }

    /// The saved record of the chat last on screen, with the live chat's newer word on it.
    public static ChatFolderRecord? Current(string account)
    {
        var saved = ChatFolderRecord.Read(FilePreferences.Shared, account);
        lock (Gate)
        {
            if (saved == null || _live == null || _liveAccount != account) return saved;
            var merged = ChatFolderRecord.Merge(saved, _live);
            if (merged != saved) merged.Write(FilePreferences.Shared, account);
            return merged;
        }
    }
}

/// Small drawing helpers the Workspace pages share.
internal static class W
{
    public static T Res<T>(string key) => ThemeBrushes.Res<T>(key);
    public static Brush Secondary => Res<Brush>("TextFillColorSecondaryBrush");
    public static Brush Tertiary => Res<Brush>("TextFillColorTertiaryBrush");
    public static Brush Accent => Res<Brush>("AccentTextFillColorPrimaryBrush");
    public static Brush Green => Res<Brush>("SystemFillColorSuccessBrush");
    public static Brush Red => Res<Brush>("SystemFillColorCriticalBrush");
    public static Brush Orange => Res<Brush>("SystemFillColorCautionBrush");
    public static FontFamily Mono => Res<FontFamily>("CodeFont");

    public static TextBlock Text(string text, double size = 14, Brush? color = null, bool bold = false, bool wrap = false) => new()
    {
        Text = text, FontSize = size, Foreground = color ?? Res<Brush>("HQLabelBrush"), FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal,
        TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap, TextTrimming = wrap ? TextTrimming.None : TextTrimming.CharacterEllipsis,
        VerticalAlignment = VerticalAlignment.Center,
    };

    public static FontIcon Glyph(string glyph, double size = 16, Brush? color = null) =>
        new() { Glyph = glyph, FontSize = size, Foreground = color ?? Res<Brush>("HQLabelBrush"), VerticalAlignment = VerticalAlignment.Center };

    /// An icon button in a page's bar, named for Narrator and with its tip under the pointer.
    public static Button BarButton(string glyph, string label, string id)
    {
        var b = new Button { Content = Glyph(glyph, 15), Style = Res<Style>("QuietButtonStyle"), Padding = new Thickness(8, 6, 8, 6) };
        ToolTipService.SetToolTip(b, label);
        AutomationProperties.SetName(b, label);
        AutomationProperties.SetAutomationId(b, id);
        return b;
    }

    /// The Mac's SF Symbol names, as Segoe Fluent Icons glyphs.
    public static string Symbol(string name) => name switch
    {
        "folder" or "folder.badge.questionmark" => "",
        "arrow.triangle.branch" => "",
        "checkmark.circle" => "",
        "terminal" => "",
        "lock" or "lock.fill" => "",
        "arrow.down.circle" => "",
        "rectangle.on.rectangle" => "",
        "square.stack.3d.up" => "",
        "shield.lefthalf.filled" or "checkmark.shield" => "",
        _ => "",   // exclamationmark.triangle
    };

    /// A page's state: its symbol, title and words in the middle of the room, with its buttons (Try Again, Choose
    /// Folder…). `primary` is the accent button; `secondary` a plain one.
    public static FrameworkElement State(string symbol, string title, string body, (string Title, Action Act)? primary = null,
        (string Title, Action Act)? secondary = null, string id = "workspace.state", Brush? ink = null, Brush? ink2 = null)
    {
        var panel = new StackPanel { Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 520, Margin = new Thickness(24) };
        AutomationProperties.SetAutomationId(panel, id);
        panel.Children.Add(new FontIcon { Glyph = Symbol(symbol), FontSize = 40, Foreground = ink2 ?? Secondary, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 6) });
        panel.Children.Add(new TextBlock { Text = title, FontSize = 20, FontWeight = FontWeights.SemiBold, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, Foreground = ink ?? Res<Brush>("HQLabelBrush"), HorizontalAlignment = HorizontalAlignment.Center });
        if (body.Length > 0)
            panel.Children.Add(new TextBlock { Text = body, FontSize = 14, Foreground = ink2 ?? Secondary, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, HorizontalAlignment = HorizontalAlignment.Center });
        var buttons = new StackPanel { Orientation = Orientation.Vertical, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 8, 0, 0) };
        if (primary is { } p)
        {
            var b = new Button { Content = p.Title, Style = Res<Style>("AccentButtonStyle"), HorizontalAlignment = HorizontalAlignment.Center };
            AutomationProperties.SetAutomationId(b, id + ".primary");
            b.Click += (_, _) => p.Act();
            buttons.Children.Add(b);
        }
        if (secondary is { } s)
        {
            var b = new Button { Content = s.Title, HorizontalAlignment = HorizontalAlignment.Center };
            AutomationProperties.SetAutomationId(b, id + ".secondary");
            b.Click += (_, _) => s.Act();
            buttons.Children.Add(b);
        }
        if (buttons.Children.Count > 0) panel.Children.Add(buttons);
        return panel;
    }

    public static FrameworkElement Loading(string? words = null)
    {
        var panel = new StackPanel { Spacing = 10, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetAutomationId(panel, "workspace.loading");
        panel.Children.Add(new ProgressRing { IsActive = true, Width = 28, Height = 28 });
        if (words != null) panel.Children.Add(new TextBlock { Text = words, Foreground = Secondary, HorizontalAlignment = HorizontalAlignment.Center });
        return panel;
    }

    /// An alert with one button (OK) or a question with Cancel and an action; true when the action was chosen.
    public static async Task<bool> AskAsync(XamlRoot? root, string title, string message, string? action = null, bool destructive = false,
        Microsoft.UI.Xaml.Controls.TextBox? field = null)
    {
        if (root == null) return false;
        var content = new StackPanel { Spacing = 10 };
        if (message.Length > 0) content.Children.Add(new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap });
        if (field != null) content.Children.Add(field);
        var dialog = new ContentDialog
        {
            Title = title, Content = content, XamlRoot = root,
            CloseButtonText = action == null ? "OK" : "Cancel",
            PrimaryButtonText = action ?? "",
            DefaultButton = action == null || destructive ? ContentDialogButton.Close : ContentDialogButton.Primary,
        };
        try { return await dialog.ShowAsync() == ContentDialogResult.Primary; }
        catch (Exception e) when (e is InvalidOperationException or System.Runtime.InteropServices.COMException) { return false; }
    }
}
