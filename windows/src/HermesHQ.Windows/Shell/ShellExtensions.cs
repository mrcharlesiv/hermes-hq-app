using Hermes.Core;
using Hermes.Core.Model;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Shell;

/// What the window's shell lets a feature supply (the gateways feature fills these; see FeatureRegistry). Each is
/// optional: unset, ShellPage keeps its M1 behaviour.
public static class ShellExtensions
{
    /// The sidebar's foot line naming the gateway in use, with its connection dot (and, with several gateways, the
    /// switcher). Made once per shell.
    public static Func<HermesClient, FrameworkElement>? GatewayFoot { get; set; }

    /// Items for the foot's account menu, above Refresh (Add Gateway…, Manage Gateways…).
    public static readonly List<Func<MenuFlyoutItemBase>> AccountMenu = [];

    /// Sign out, with its confirmation (the gateway's name, where the app goes next). Null: ShellPage's own.
    public static Func<XamlRoot, Task>? SignOut { get; set; }

    /// Drives the connection notice at the sidebar's top for this client; disposed when the shell leaves.
    public static Func<HermesClient, InfoBar, IDisposable>? ConnectionNotice { get; set; }

    /// What the content pane opens first once the bots are known (the last chat, reopened at launch). Null: the first
    /// bot's chat.
    public static Func<IReadOnlyList<Bot>, Destination?>? FirstDestination { get; set; }

    /// The gateway ended this PC's session while the shell was on screen. Null: ShellPage signs out.
    public static Action? SessionEnded { get; set; }

    /// [bot-pages] What the sidebar's old search field found for a query, given the bots: More search's Go To, Bots,
    /// Sessions, Settings and Actions (Features/BotPages/MoreSearchHook.cs). Nothing reads it since the sidebar's Search
    /// became the Mac's button (WIN-15): Open Quickly searches the same groups. Left for the BotPages lane to retire
    /// with `MoreSearchHook.Results`, which still sets it.
    public static Func<string, IReadOnlyList<Bot>, IReadOnlyList<ShellSearchHit>>? Search { get; set; }

    /// [groups] A room row's right-click menu (App/Groups/GroupActions.swift `menuNodes`), filled from the row as it is
    /// now. Null: room rows have no menu. Features/Groups/GroupManageFeature.cs sets it.
    public static Action<IList<MenuFlyoutItemBase>, Hermes.Core.Groups.GroupRowModel, XamlRoot>? RoomMenu { get; set; }
}

/// One search result: its title, the line that says what it is ("Sidebar", "Bot", "Settings › About"), and what opening
/// it does. `IsStart`: Return opens this one (the row named exactly what was typed, else the first).
public sealed record ShellSearchHit(string Title, string Detail, Action Open, bool IsStart = false)
{
    public override string ToString() => Detail.Length > 0 ? $"{Title}  ·  {Detail}" : Title;
}
