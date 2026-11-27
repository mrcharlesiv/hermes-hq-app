using Hermes.Core;
using Hermes.Core.Jobs;
using Hermes.Core.Model;
using Hermes.Core.Rpc;
using HermesHQ.Controls;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.Jobs;

/// Jobs (PARITY.md Pages: list, detail, run / pause / delete, history, New / Edit Job, templates, schedule, delivery,
/// model). The Mac's App/Pages/Jobs on the Windows shell: the "jobs" sidebar place is JobsPage.
public static class JobsFeature
{
    public static void Register()
    {
        Places.Register("jobs", typeof(JobsPage));
        AppState.ClientChanged += JobsServices.Use;
        JobsSidebarBadge.Register();
    }

    /// Sign Out, Remove Gateway: this PC's copy of the gateway's jobs goes.
    public static void SignedOut(string accountKey)
    {
        JobsServices.Drop();
        try { Directory.Delete(JobsServices.CacheDirectory(accountKey), true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }
}

/// One JobsStore for the gateway in use: it hears `cron.changed` and `gateway.ready` from the socket, and keeps its
/// backstop reads going with the page off screen (the Mac's JobsStore lives as long as the account).
public static class JobsServices
{
    private static readonly object Gate = new();
    private static JobsStore? _store;
    private static HermesClient? _client;
    /// The scope chosen per account ("all" or a profile), for this run of the app.
    private static readonly Dictionary<string, string> Scopes = [];

    public static string CacheDirectory(string accountKey) =>
        Path.Combine(AppPaths.Root, "pages", string.Concat(accountKey.Select(c => char.IsLetterOrDigit(c) ? c : '_')));

    public static JobsStore? Store => For(AppState.Client);

    public static JobsStore? For(HermesClient? client)
    {
        if (client == null) return null;
        lock (Gate)
        {
            if (_client == client && _store != null) return _store;
            DropLocked();
            _client = client;
            _store = new JobsStore(new JobsApi(client.Session), new JobsDiskCache(CacheDirectory(client.AccountId)));
            client.Rpc.Event += OnEvent;
            client.Rpc.Reconnected += OnReconnected;
            _store.StartBackstop();
            AppLog.Note("jobs", "store ready");
            return _store;
        }
    }

    public static void Use(HermesClient? client)
    {
        if (client == null) Drop();
        else For(client);
    }

    public static void Drop() { lock (Gate) DropLocked(); }

    private static void DropLocked()
    {
        if (_client != null)
        {
            _client.Rpc.Event -= OnEvent;
            _client.Rpc.Reconnected -= OnReconnected;
        }
        _store?.Dispose();
        _store = null;
        _client = null;
    }

    private static void OnEvent(RpcEvent e)
    {
        if (e.Type == "cron.changed") _store?.CronChanged();
    }

    private static void OnReconnected(bool _)
    {
        var changeEvents = _client?.Rpc.ReadyPayload.Bool("change_events") ?? true;
        _store?.GatewayReady(changeEvents);
    }

    public static string Scope(string account) => Scopes.GetValueOrDefault(account, "all");
    public static void SetScope(string account, string scope) => Scopes[account] = scope;

    /// The bots the page offers: the default bot first, then the roster's order.
    public static List<Bot> Bots()
    {
        var bots = AppState.Client?.Bots ?? [];
        return [.. bots.Where(b => b.IsDefault), .. bots.Where(b => !b.IsDefault && !b.Hidden)];
    }

    public static string BotName(string profile) =>
        Bots().FirstOrDefault(b => b.Name == profile)?.DisplayName ?? (profile == "default" ? "Hermes" : profile);

    public static Bot? Bot(string profile) => Bots().FirstOrDefault(b => b.Name == profile);
}

/// Small builders the Jobs screens share.
internal static class JobsUi
{
    public static T Res<T>(string key) => ThemeBrushes.Res<T>(key);
    public static Brush Brush(string key) => Res<Brush>(key);

    public static Brush Secondary => Brush("TextFillColorSecondaryBrush");
    public static Brush Tertiary => Brush("TextFillColorTertiaryBrush");
    public static Brush Red => Brush("SystemFillColorCriticalBrush");
    public static Brush Orange => Brush("SystemFillColorCautionBrush");
    public static Brush Accent => Brush("AccentTextFillColorPrimaryBrush");

    public static TextBlock Text(string text, double size = 14, Brush? color = null, bool bold = false, bool wrap = true, int maxLines = 0) => new()
    {
        Text = text,
        FontSize = size,
        FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal,
        Foreground = color ?? Brush("HQLabelBrush"),
        TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap,
        TextTrimming = TextTrimming.CharacterEllipsis,
        MaxLines = maxLines,
    };

    /// A group's card: the Mac's inset-grouped rows on a filled surface.
    public static Border Card(UIElement child, Thickness? padding = null) => new()
    {
        Child = child,
        Background = Brush("CardBackgroundFillColorDefaultBrush"),
        BorderBrush = Brush("CardStrokeColorDefaultBrush"),
        BorderThickness = new Thickness(1),
        CornerRadius = new CornerRadius(10),
        Padding = padding ?? new Thickness(16, 10, 16, 10),
    };

    public static TextBlock Header(string text) => new()
    {
        Text = text, FontSize = 13, FontWeight = FontWeights.SemiBold, Margin = new Thickness(16, 16, 0, 6),
    };

    public static Button Quiet(UIElement content, string name, RoutedEventHandler click)
    {
        var b = new Button { Content = content, Style = Res<Style>("QuietButtonStyle") };
        ToolTipService.SetToolTip(b, name);
        AutomationProperties.SetName(b, name);
        b.Click += click;
        return b;
    }

    public static FontIcon Glyph(string glyph, double size = 14, Brush? color = null)
    {
        var icon = new FontIcon { Glyph = glyph, FontSize = size };
        if (color != null) icon.Foreground = color;
        return icon;
    }

    public static UIElement Face(string profile, double size)
    {
        var head = new BotHead { Width = size, Height = size, VerticalAlignment = VerticalAlignment.Top };
        if (JobsServices.Bot(profile) is { } bot) head.Bot = bot; else head.DisplayName = JobsServices.BotName(profile);
        AutomationProperties.SetAccessibilityView(head, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        return head;
    }

    /// A label and its value on one row ("Repeats    Every day at 6:00 AM").
    public static Grid Labeled(string label, string value, Brush? valueColor = null)
    {
        var g = new Grid { ColumnSpacing = 12, Padding = new Thickness(0, 6, 0, 6) };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.Children.Add(Text(label, 14));
        var v = Text(value, 14, valueColor ?? Secondary);
        v.HorizontalAlignment = HorizontalAlignment.Right;
        v.TextAlignment = TextAlignment.Right;
        v.IsTextSelectionEnabled = true;
        Grid.SetColumn(v, 1);
        g.Children.Add(v);
        return g;
    }

    public static Border Separator() => new() { Height = 1, Background = Brush("DividerStrokeColorDefaultBrush"), Margin = new Thickness(0, 2, 0, 2) };
}
