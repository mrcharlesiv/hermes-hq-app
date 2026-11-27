namespace Hermes.Core.Insights;

/// Every word the Tiles page says (App/Pages/Artifacts/ArtifactsViewController.swift, PinnedArtifacts.swift,
/// TileUpdates.swift), with the Mac's "Control-click" as Windows' "right-click".
public static class TileWords
{
    public const string PageTitle = "Tiles";
    public const string SearchPlaceholder = "Search Tiles";
    public const string AllBots = "All Bots";

    /// "1 Item", "3 Items".
    public static string ItemCount(int count) => count == 1 ? "1 Item" : $"{count} Items";

    // Empty states
    public const string NoTilesYet = "No Tiles Yet";
    public const string ThisPageIsEmpty = "This Page Is Empty";
    public static string NoTilesFor(string bot) => $"No Tiles for {bot}";
    public const string HowTo = "Pin the pages, pictures and files your bots make, and keep them one click away.";
    public const string HowToChat = "In a chat, right-click one and choose Pin as Tile.";
    public const string HowToArtifacts = "In Artifacts, right-click one and choose Pin as Tile.";
    public const string NewTile = "New Tile";
    public const string OpenArtifacts = "Open Artifacts";
    public const string NoResults = "No Results";
    public static string NoTileMatches(string words) => $"No tile matches “{words}”.";

    // View menu
    public const string ViewAs = "View As";
    public const string Grid = "Grid", Cards = "Cards", List = "List";
    public const string ShowNames = "Show Names";
    public const string EditTiles = "Edit Tiles";
    public const string Done = "Done";
    public const string NewPage = "New Page…";
    public static string ViewTitle(TilesView v) => v switch { TilesView.Grid => Grid, TilesView.Cards => Cards, _ => List };

    // Tile menu
    public const string Size = "Size";
    public const string Open = "Open";
    public const string OpenChat = "Open Chat";
    public const string ShowInChat = "Show in Chat";
    public const string Share = "Share…";
    public const string SaveAs = "Save As…";
    public const string CopyPath = "Copy Path";
    public const string CopyLink = "Copy Link";
    public const string Copied = "Copied";
    public const string Change = "Change…";
    public const string Versions = "Versions";
    public const string Rename = "Rename…";
    public const string MoveToPage = "Move to Page";
    public const string Unpin = "Unpin";
    public const string Remove = "Remove";
    public static string MovedTo(string page) => $"Moved to {page}";
    public static string Unpinned(string name) => $"Unpinned “{name}”";
    public const string Undo = "Undo";

    // Updates submenu
    public const string Updates = "Updates";
    public const string NotKeptUpdated = "Not Kept Updated";
    public const string NoJobRewrites = "No job rewrites this tile";
    public const string CouldntReadUpdates = "Couldn’t Read Updates";
    public const string CantReachGateway = "Can’t reach your gateway";
    public const string HowOften = "How Often";
    public const string UpdateNow = "Update Now";
    public const string PauseUpdates = "Pause Updates";
    public const string ResumeUpdates = "Resume Updates";
    public const string LastUpdateFailed = "Last Update Failed";
    public const string UpdatesTile = "Updates this tile";
    public const string Updating = "Updating…";
    public const string UpdatesPaused = "Updates Paused";
    public const string UpdatesResumed = "Updates Resumed";
    public static string UpdatesEvery(string frequencyTitle) => $"Updates {frequencyTitle}";
    public const string CouldntChangeUpdates = "Couldn’t Change Updates";
    public const string CouldntUpdate = "Couldn’t Update";

    // Rename
    public const string RenameTile = "Rename Tile";
    public static string RenameMessage(TilePin pin)
    {
        var own = pin.IsPage ? "page’s" : pin.Kind == TileKind.Image ? "picture’s" : pin.Kind == TileKind.Link ? "link’s" : "file’s";
        return $"Leave it empty to use the {own} own name.";
    }
    public const string Cancel = "Cancel";
    public const string RenameAction = "Rename";

    // Remove
    public static string RemoveTitle(string name) => name.Length == 0 ? "Remove This Artifact?" : $"Remove “{name}”?";
    public const string RemoveMessage = "It’s removed from Artifacts, Tiles and Bot Info in every chat that names it. "
        + "The file or link itself isn’t deleted. This can’t be undone.";
    public const string RemoveArtifact = "Remove Artifact";
    public const string Removed = "Removed";

    // Pages
    public const string NewPageTitle = "New Page";
    public const string Add = "Add";
    public const string RenamePage = "Rename Page";
    public const string DeletePageAction = "Delete Page";
    public const string PageIcon = "Icon";
    public const string NoIcon = "No Icon";
    public static string DeletePageTitle(string name) => $"Delete “{name}”?";
    public static string DeletePageMessage(int count, string main) =>
        $"Its {(count == 1 ? "tile moves" : $"{count} tiles move")} to {main}. Nothing is unpinned.";

    // Tiles v2 (New Tile, Change, Duplicate, Batch, Activity)
    public const string Make = "Make";
    public const string OnTheTile = "On the Tile";
    public const string WhatShouldItShow = "What should it show?";
    public const string NewTileFooter = "The bot makes a live tile that fits any size and keeps it up to date. It pins itself here when it’s ready.";
    public const string MadeBy = "Made By";
    public const string MadeByFooter = "Pick a bot that can reach the data, for example one signed in to your mail or calendar.";
    public const string Ideas = "Ideas";
    public const string MoreIdeas = "More Ideas";
    public const string Fit = "Fit";
    public const string LayoutAndUpdates = "Layout & Updates";
    public const string Duplicate = "Duplicate…";
    public const string TileActivity = "Tile Activity";
    public const string UpdateAllNow = "Update All Now";
    public const string PauseAllUpdates = "Pause All Updates";
    public const string ResumeAllUpdates = "Resume All Updates";
    public const string UnpinSelected = "Unpin Selected";
    public const string SelectAll = "Select All";
    public const string ClearSelection = "Clear Selection";
    public const string RollBack = "Roll Back";
    public const string Restore = "Restore";
    public const string RollBackConfirmTitle = "Roll Back to This Version?";
    public static string VersionShownToast(string name, int number) => $"{name} Is on Version {number}";

    // The page that isn't there any more, a picture that's gone
    public const string GoneWords = "The page isn’t on your gateway anymore.";

    // Live tile buttons
    public const string ReadOnly = "This gateway is read-only.";
    public const string CouldntSend = "Couldn’t Send to This Tile";
    public const string BotGone = "This Tile’s Bot Is Gone";

    /// A tile's button: its prompt to the tile's bot (`TileMaker.actionPrompt`).
    public static string ActionPrompt(string path, string name, string prompt) =>
        $"{prompt}\n\n(Asked from my Hermes HQ tile “{name}”, {path}. Do it, then give that tile its new data in place so it "
        + "shows the result (the way the hermes-hq-push:dashboard-tile skill says); keep its look, its name and its "
        + "job. Reply in a line or two.)";

    /// The most a tile's button may send.
    public const int MaxIntentLength = 500;
}
