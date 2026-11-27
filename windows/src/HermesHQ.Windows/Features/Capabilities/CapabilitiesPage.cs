using Hermes.Core.Capabilities;
using HermesHQ.Controls;
using HermesHQ.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace HermesHQ.Features.Capabilities;

/// The Capabilities place: the four rows (Skills, Tools, Connectors, Plugins) and Composio's, each list its own page
/// with its own Bot row, search and ⋯ (App/Capabilities/CapabilitiesHub.swift, CapabilitiesViewController.swift).
[Microsoft.UI.Xaml.Data.Bindable]
public sealed partial class CapabilitiesPage : Page
{
    private readonly StackHost _host = new();

    public CapabilitiesPage()
    {
        Content = _host;
        NavigationCacheMode = NavigationCacheMode.Disabled;
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        var target = (e.Parameter as PlaceArgs)?.Argument as CapabilitiesTarget;
        var hub = new HubScreen(target?.Profile, target?.BotLocked ?? false);
        _host.Reset(hub);
        if (target?.Tab is { } tab) hub.Open(tab, target.Focus);
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        _host.Top?.Hidden();
    }
}

/// Capabilities' four rows (CapabilitiesHubView): Connectors says "1 Issue" in red when a connector needs the owner,
/// and then opens on the bot of the newest issue, scrolled to it (3x §8.5).
internal sealed class HubScreen(string? profile, bool botLocked) : Screen
{
    public override string Title => botLocked ? $"{CapabilitiesServices.BotName(profile ?? "default")}’s Capabilities" : "Capabilities";

    public override void Shown() => CapabilitiesServices.Issues.Changed += Redraw;
    public override void Hidden() => CapabilitiesServices.Issues.Changed -= Redraw;
    private void Redraw() => Render();

    public static string GlyphOf(CapabilitiesTab tab) => tab switch
    {
        CapabilitiesTab.Skills => Kit.Sparkles,
        CapabilitiesTab.Tools => Kit.Hammer,
        CapabilitiesTab.Connectors => Kit.Plug,
        _ => Kit.Puzzle,
    };

    public void Open(CapabilitiesTab tab, string? focus = null)
    {
        var issues = CapabilitiesServices.Issues;
        // Connectors with an issue opens on the newest issue's bot, scrolled to it; otherwise this page's bot.
        if (tab == CapabilitiesTab.Connectors && !botLocked && focus == null && issues.Issues.FirstOrDefault() is { } newest)
            Push(new ListScreen(tab, newest.Profile, botLocked, newest.Name));
        else Push(new ListScreen(tab, profile, botLocked, focus));
    }

    public override void Build(StackPanel page)
    {
        var issues = CapabilitiesServices.Issues;
        var rows = CapabilitiesTabs.All.Select(tab =>
        {
            UIElement? value = null;
            if (tab == CapabilitiesTab.Connectors && issues.RowText is { } text)
                value = Kit.Text(text, 14, color: Kit.Critical, wrap: false);
            var row = Kit.Row(tab.Title(), leading: Kit.Tile(GlyphOf(tab), 28), trailing: value, click: () => Open(tab), chevron: true);
            if (tab == CapabilitiesTab.Connectors && issues.Summary is { } spoken) AutomationProperties.SetHelpText(row, spoken);
            AutomationProperties.SetAutomationId(row, $"capabilities.row.{tab.Id()}");
            return row;
        });
        page.Children.Add(Kit.Section(null, rows, CapabilitiesWords.HubFooter));
        // Composio's row (Connect Apps with your own Composio key) waits for the Composio port; see PARITY.md.
    }
}

/// The Bot row at the top of each list (`MoreBotPicker`): the bot whose list this is; a picker unless the page was
/// opened from the bot's own page.
internal static class BotRow
{
    public static UIElement Make(string profile, bool locked, Action<string> pick)
    {
        var bots = CapabilitiesServices.Bots();
        var current = bots.FirstOrDefault(b => b.Name == profile);
        var head = new BotHead { Width = 24, Height = 24 };
        if (current != null) head.Bot = current; else head.DisplayName = CapabilitiesServices.BotName(profile);
        UIElement trailing;
        if (locked || bots.Count == 0) trailing = Kit.Text(CapabilitiesServices.BotName(profile), 14, secondary: true, wrap: false);
        else
        {
            var box = new ComboBox { MinWidth = 160 };
            var names = bots.Select(b => b.Name).ToList();
            if (!names.Contains(profile)) { names.Insert(0, profile); box.Items.Add(CapabilitiesServices.BotName(profile)); }
            foreach (var b in bots) box.Items.Add(b.DisplayName);
            box.SelectedIndex = names.IndexOf(profile);
            AutomationProperties.SetName(box, "Bot");
            box.SelectionChanged += (_, _) => { if (box.SelectedIndex >= 0 && names[box.SelectedIndex] != profile) pick(names[box.SelectedIndex]); };
            trailing = box;
        }
        return Kit.Section(null, [Kit.Row("Bot", leading: head, trailing: trailing)]);
    }
}
