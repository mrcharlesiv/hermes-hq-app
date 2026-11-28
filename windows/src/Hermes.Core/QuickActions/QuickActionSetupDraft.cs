namespace Hermes.Core.QuickActions;

/// Set Up / Edit Action's form and its close rules (App/QuickActions/QuickActionSetup.swift QuickActionDraft
/// .hasChanges, QuickActionSetupHost.hasChanges/installCancel/save; App/BotInfo/BotInfoSheet.swift EditingPage
/// .confirmLeaving, EditingGuard.askToDiscard).
///
/// What counts as a change is the tile against the tile as the form first showed it (`tile != original`): typing a
/// field back to what it was is no change. Only Edit Action asks (`!draft.isNew && draft.hasChanges`): a new tile's Set Up
/// is a step inside Add Action and leaves without asking, as on the Mac. Nothing is written until the one Save or Add.
public sealed class QuickActionSetupDraft
{
    public const string DiscardTitle = "Discard Changes?";
    public const string DiscardConfirm = "Discard Changes";
    public const string DiscardKeep = "Keep Editing";

    /// `shown`: the tile as the form first shows it (after its own pre-fill, e.g. a new tile's first bot).
    public QuickActionSetupDraft(QuickTile shown, bool isNew)
    {
        Original = shown;
        Tile = shown;
        IsNew = isNew;
    }

    public QuickTile Original { get; }
    public QuickTile Tile { get; set; }
    public bool IsNew { get; }

    /// Saved once (Save or Add): later closes and saves do nothing.
    public bool Saved { get; private set; }

    /// QuickActionDraft.message's setter: an emptied words box is no words, as the tile was before any were typed.
    public static string? Words(string text) => text.Length == 0 ? null : text;

    /// QuickActionDraft.command's setter: trims and ensures a leading slash when non-empty.
    public static string? NormalizeCommand(string text)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0) return null;
        return trimmed.StartsWith('/') ? trimmed : "/" + trimmed;
    }

    /// QuickActionDraft.tileSize's setter: reconciles `Wide`, `Size`, and `Short`.
    public static QuickTile ApplySize(QuickTile tile, QuickTileSize size)
    {
        var clearShort = size == QuickTileSize.Mini || size.RowSpan() > 1 || (tile.Known is { } k && !k.SupportsShort());
        return tile with
        {
            Wide = size.IsWideSpan(),
            Size = size is QuickTileSize.Small or QuickTileSize.Wide ? null : size,
            Short = clearShort ? false : tile.Short,
        };
    }

    /// QuickActionDraft.hasChanges.
    public bool Changed => Tile != Original;

    /// QuickActionSetupHost.hasChanges: what Cancel and Escape ask about.
    public bool HasChanges => !IsNew && Changed;

    public bool CanSave => !Saved && QuickTileDraft.CanSave(Tile);

    public enum CloseDecision
    {
        /// Close: nothing to lose (a new tile's Set Up, an untouched or reverted edit), or it was just saved.
        Close,
        /// Ask Discard Changes? first; Keep Editing (the default for Return and Escape) brings the form back as it was.
        AskToDiscard,
    }

    /// Cancel, Escape or the window closing the form (EditingPage.confirmLeaving).
    public CloseDecision Close() => !Saved && HasChanges ? CloseDecision.AskToDiscard : CloseDecision.Close;

    /// The answer to Discard Changes?: leave only on the deliberate Discard Changes.
    public static bool Leaves(bool discardChosen) => discardChosen;

    /// What Save or Add handed back (the tile as saved), once it has.
    public QuickTile? Result { get; private set; }

    /// Save or Add (QuickActionSetupHost.save): the tile as saved, once. Null when it can't be saved or already was.
    public QuickTile? Save()
    {
        if (!CanSave) return null;
        Saved = true;
        return Result = QuickTileDraft.Finished(Tile);
    }

    /// The form's life: shown until it is saved, closed with nothing to lose, or Discard Changes is chosen; Keep Editing
    /// shows it again as it was. `show` shows the form once (false: it couldn't be shown at all); `askToDiscard` asks
    /// Discard Changes? (true: Discard Changes). Returns the saved tile, or null when nothing is to be written.
    public async Task<QuickTile?> RunAsync(Func<Task<bool>> show, Func<Task<bool>> askToDiscard)
    {
        while (true)
        {
            var shown = await show();
            if (Saved) return Result;
            if (!shown) return null;
            if (Close() == CloseDecision.AskToDiscard && !Leaves(await askToDiscard())) continue;
            return null;
        }
    }
}
