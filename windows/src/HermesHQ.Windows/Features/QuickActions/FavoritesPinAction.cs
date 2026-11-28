using Hermes.Core.QuickActions;
using HermesHQ.Features.Bots;
using HermesHQ.Services;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Features.QuickActions;

/// Shared `"Add to Favorites"` / `"Remove from Favorites"` `MenuFlyoutItem` factory
/// (`App/QuickActions/FavoritesPinAction.swift`), ready to drop into any page's context menu (Bots, Groups, Sessions,
/// Dashboard Tiles, Goals, Jobs, Tasks). Deduplication and persistence live in `FavoritesPinRules`.
public static class FavoritesPinAction
{
    public static MenuFlyoutItem ForBot(string profile, string name, Action<bool>? onToggled = null) =>
        Make(
            FavoritesPinRules.BotMatch(profile),
            () => QuickTile.Create(QuickTileKind.BotCard, name: name, size: QuickTileSize.Wide) with
            {
                Bot = profile,
                BotName = name,
            },
            onToggled);

    public static MenuFlyoutItem ForRoom(string roomKey, string name, Action<bool>? onToggled = null) =>
        Make(
            FavoritesPinRules.RoomMatch(roomKey),
            () => QuickTile.Create(QuickTileKind.GroupChat, name: name, size: QuickTileSize.Wide) with
            {
                RoomKey = roomKey,
                RoomName = name,
            },
            onToggled);

    public static MenuFlyoutItem ForSession(
        string profile,
        string sessionId,
        string title,
        string? botName = null,
        Action<bool>? onToggled = null) =>
        Make(
            FavoritesPinRules.SessionMatch(sessionId),
            () => QuickTile.Create(QuickTileKind.ChatSession, name: title, size: QuickTileSize.Wide) with
            {
                Bot = profile,
                BotName = botName,
                SessionId = sessionId,
                SessionTitle = title,
            },
            onToggled);

    public static MenuFlyoutItem ForDashboardTile(
        string pinId,
        string name,
        string? symbol = null,
        Action<bool>? onToggled = null) =>
        Make(
            FavoritesPinRules.DashboardTileMatch(pinId),
            () => QuickTile.Create(QuickTileKind.DashboardTile, name: name, symbol: symbol, size: QuickTileSize.Small) with
            {
                Pin = pinId,
                PinName = name,
            },
            onToggled);

    public static MenuFlyoutItem ForGoal(string goalId, string title, Action<bool>? onToggled = null) =>
        Make(
            FavoritesPinRules.GoalMatch(goalId),
            () => QuickTile.Create(QuickTileKind.Goal, name: title, size: QuickTileSize.Wide) with
            {
                GoalId = goalId,
                GoalName = title,
            },
            onToggled);

    public static MenuFlyoutItem ForJob(string jobKey, string title, Action<bool>? onToggled = null) =>
        Make(
            FavoritesPinRules.JobMatch(jobKey),
            () => QuickTile.Create(QuickTileKind.JobCard, name: title, size: QuickTileSize.Wide) with
            {
                Job = jobKey,
                JobName = title,
            },
            onToggled);

    public static MenuFlyoutItem ForTaskView(string viewKey, string title, Action<bool>? onToggled = null) =>
        Make(
            FavoritesPinRules.TaskViewMatch(viewKey),
            () => QuickTile.Create(QuickTileKind.Tasks, name: title, size: QuickTileSize.Wide) with
            {
                TaskView = viewKey,
                TaskViewName = title,
            },
            onToggled);

    private static MenuFlyoutItem Make(
        Func<QuickTile, bool> match,
        Func<QuickTile> make,
        Action<bool>? onToggled)
    {
        var pinned = FavoritesPinRules.Contains(QuickActionsFeature.Store, match);
        var item = new MenuFlyoutItem
        {
            Text = pinned ? "Remove from Favorites" : "Add to Favorites",
            Icon = new FontIcon { Glyph = pinned ? "\uE735" : "\uE734" },
        };
        item.Click += (_, _) =>
        {
            var firstBot = ListsHub.Current is { Bots.HasRoster: true } hub && hub.Bots.Rows.FirstOrDefault() is { } first
                ? ((string Profile, string Name)?)(first.Id, first.Model.DisplayName)
                : null;
            var added = FavoritesPinRules.Toggle(
                QuickActionsFeature.Store,
                match,
                make,
                firstBot,
                AppState.Client?.AccountId);
            onToggled?.Invoke(added);
        };
        return item;
    }
}
