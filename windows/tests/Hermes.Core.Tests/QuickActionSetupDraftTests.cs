using Hermes.Core.QuickActions;
using static Hermes.Core.QuickActions.QuickActionSetupDraft;

namespace Hermes.Core.Tests;

/// Edit Action keeps unsaved edits when the form closes (App/QuickActions/QuickActionSetup.swift QuickActionDraft
/// .hasChanges, QuickActionSetupHost.hasChanges/installCancel/save; App/BotInfo/BotInfoSheet.swift EditingPage
/// .confirmLeaving, EditingGuard.askToDiscard at 93f984bb1). Synthetic stand-ins only (demo bot "otto").
public class QuickActionSetupDraftTests
{
    private static QuickTile Saved() => QuickTile.Create(QuickTileKind.Send, id: "T-1", name: "Ping Otto") with
    {
        Bot = "otto", BotName = "Otto", Message = "status please", Flag = true,
    };

    /// One showing of the form: what the person does before it closes (Cancel/Escape, or Save/Add).
    private sealed class Form(QuickActionSetupDraft draft)
    {
        public readonly Queue<Action<QuickActionSetupDraft>> Edits = new();
        public readonly Queue<bool> Answers = new();
        public int Shown, Asked;

        public Task<QuickTile?> RunAsync() => draft.RunAsync(() =>
        {
            Shown++;
            if (Edits.Count == 0) throw new InvalidOperationException("form shown again with nothing scripted");
            Edits.Dequeue()(draft);
            return Task.FromResult(true);
        }, () => { Asked++; return Task.FromResult(Answers.Dequeue()); });
    }

    private static void Cancel(QuickActionSetupDraft d) { }
    private static void SaveIt(QuickActionSetupDraft d) => d.Save();

    [Fact]
    public void An_untouched_edit_closes_without_asking()
    {
        var draft = new QuickActionSetupDraft(Saved(), isNew: false);
        Assert.False(draft.HasChanges);
        Assert.Equal(CloseDecision.Close, draft.Close());
    }

    [Fact]
    public void A_changed_edit_asks_before_Cancel_or_Escape_drops_it()
    {
        foreach (var edit in new Func<QuickTile, QuickTile>[]
        {
            t => t with { Name = "Ping Otto now" },
            t => t with { Message = "status?" },
            t => t with { Flag = false },
            t => t with { Color = QuickTileColor.Teal.Raw() },
            t => t with { Bot = "herald", BotName = "Herald" },
            t => t with { Name = "Ping Otto " },   // the raw tile differs (Swift compares before trimming)
        })
        {
            var draft = new QuickActionSetupDraft(Saved(), isNew: false) { Tile = edit(Saved()) };
            Assert.True(draft.HasChanges);
            Assert.Equal(CloseDecision.AskToDiscard, draft.Close());
        }
    }

    [Fact]
    public void Typing_a_field_back_to_what_it_was_is_no_change()
    {
        var draft = new QuickActionSetupDraft(Saved(), isNew: false);
        draft.Tile = draft.Tile with { Name = "Ping" };
        Assert.True(draft.HasChanges);
        draft.Tile = draft.Tile with { Name = "Ping Otto" };
        Assert.False(draft.HasChanges);
        Assert.Equal(CloseDecision.Close, draft.Close());

        // Words typed into an empty box and deleted again leave the tile with no words, as it was.
        var chat = new QuickActionSetupDraft(QuickTile.Create(QuickTileKind.NewChat, id: "T-2") with { Bot = "otto" }, isNew: false);
        chat.Tile = chat.Tile with { Message = Words("hello") };
        Assert.True(chat.HasChanges);
        chat.Tile = chat.Tile with { Message = Words("") };
        Assert.Null(chat.Tile.Message);
        Assert.Equal(CloseDecision.Close, chat.Close());
    }

    [Fact]
    public void A_new_tiles_Set_Up_leaves_without_asking_as_on_the_Mac()
    {
        // QuickActionSetupHost.hasChanges is `!draft.isNew && draft.hasChanges`: Set Up is a step inside Add Action.
        var draft = new QuickActionSetupDraft(QuickTile.Create(QuickTileKind.Send, id: "T-3") with { Bot = "otto" }, isNew: true);
        draft.Tile = draft.Tile with { Message = "typed", Name = "Typed" };
        Assert.True(draft.Changed);
        Assert.False(draft.HasChanges);
        Assert.Equal(CloseDecision.Close, draft.Close());
    }

    [Fact]
    public void Discard_Changes_is_the_only_answer_that_leaves()
    {
        Assert.Equal("Discard Changes?", DiscardTitle);
        Assert.Equal("Discard Changes", DiscardConfirm);
        Assert.Equal("Keep Editing", DiscardKeep);
        Assert.True(Leaves(true));
        Assert.False(Leaves(false));   // Keep Editing, Return and Escape on the question
    }

    [Fact]
    public async Task Keep_Editing_shows_the_form_again_with_every_field_as_it_was()
    {
        var draft = new QuickActionSetupDraft(Saved(), isNew: false);
        var form = new Form(draft);
        var edited = Saved() with { Name = "Ping Otto now", Message = "status?", Flag = false, Color = QuickTileColor.Teal.Raw() };
        form.Edits.Enqueue(d => d.Tile = edited);    // typed, then Cancel
        form.Answers.Enqueue(false);                  // Keep Editing
        QuickTile? seenOnReturn = null;
        form.Edits.Enqueue(d => seenOnReturn = d.Tile);  // Escape this time
        form.Answers.Enqueue(true);                   // Discard Changes
        var result = await form.RunAsync();
        Assert.Null(result);
        Assert.Equal(2, form.Shown);
        Assert.Equal(2, form.Asked);
        Assert.Equal(edited, seenOnReturn);
        Assert.False(draft.Saved);
    }

    [Fact]
    public async Task Cancel_on_an_untouched_or_reverted_edit_closes_at_once()
    {
        var untouched = new Form(new QuickActionSetupDraft(Saved(), isNew: false));
        untouched.Edits.Enqueue(Cancel);
        Assert.Null(await untouched.RunAsync());
        Assert.Equal((1, 0), (untouched.Shown, untouched.Asked));

        var reverted = new Form(new QuickActionSetupDraft(Saved(), isNew: false));
        reverted.Edits.Enqueue(d => { d.Tile = d.Tile with { Name = "x" }; d.Tile = d.Tile with { Name = "Ping Otto" }; });
        Assert.Null(await reverted.RunAsync());
        Assert.Equal((1, 0), (reverted.Shown, reverted.Asked));
    }

    [Fact]
    public async Task Nothing_is_written_until_the_one_Save_and_then_once()
    {
        var draft = new QuickActionSetupDraft(Saved(), isNew: false);
        var form = new Form(draft);
        form.Edits.Enqueue(d => d.Tile = d.Tile with { Name = "  Ping Otto now  ", Message = " status? " });
        form.Answers.Enqueue(false);   // Keep Editing
        form.Edits.Enqueue(d =>
        {
            Assert.Null(d.Result);     // nothing handed back to the page yet
            d.Save();
            Assert.Null(d.Save());     // Return held down / a second click: no second write
        });
        var result = await form.RunAsync();
        Assert.NotNull(result);
        Assert.Equal("Ping Otto now", result!.Name);
        Assert.Equal("status?", result.Message);
        Assert.Equal("T-1", result.Id);
        Assert.Equal(CloseDecision.Close, draft.Close());   // a saved form never asks
    }

    [Fact]
    public async Task Add_on_a_new_tile_is_its_single_write_and_Cancel_writes_nothing()
    {
        var add = new Form(new QuickActionSetupDraft(QuickTile.Create(QuickTileKind.Send, id: "T-4") with { Bot = "otto" }, isNew: true));
        add.Edits.Enqueue(d => { d.Tile = d.Tile with { Message = "hi" }; SaveIt(d); });
        Assert.Equal("hi", (await add.RunAsync())?.Message);

        var cancel = new Form(new QuickActionSetupDraft(QuickTile.Create(QuickTileKind.Send, id: "T-5") with { Bot = "otto" }, isNew: true));
        cancel.Edits.Enqueue(d => d.Tile = d.Tile with { Message = "typed" });
        Assert.Null(await cancel.RunAsync());
        Assert.Equal(0, cancel.Asked);
    }

    [Fact]
    public void A_tile_that_cant_be_saved_is_not_saved()
    {
        var draft = new QuickActionSetupDraft(Saved(), isNew: false) { Tile = Saved() with { Name = "   " } };
        Assert.False(draft.CanSave);
        Assert.Null(draft.Save());
        Assert.False(draft.Saved);
        Assert.Equal(CloseDecision.AskToDiscard, draft.Close());
    }

    [Fact]
    public async Task A_form_that_could_not_be_shown_returns_nothing_and_does_not_loop()
    {
        var draft = new QuickActionSetupDraft(Saved(), isNew: false) { Tile = Saved() with { Name = "changed" } };
        var shows = 0;
        Assert.Null(await draft.RunAsync(() => { shows++; return Task.FromResult(false); }, () => throw new InvalidOperationException()));
        Assert.Equal(1, shows);
    }

    /// The WinUI form is wired to the draft (source level: the dialog itself only runs on Windows).
    [Fact]
    public void The_Windows_form_runs_through_the_draft()
    {
        var root = AppContext.BaseDirectory;
        for (var dir = new DirectoryInfo(root); dir != null; dir = dir.Parent)
            if (File.Exists(Path.Combine(dir.FullName, "windows", "HermesHQ.sln"))) { root = dir.FullName; break; }
        var source = File.ReadAllText(Path.Combine(root, "windows", "src", "HermesHQ.Windows", "Features", "QuickActions", "QuickActionDialogs.cs"))
            .Replace("\r\n", "\n");
        var setUp = source[source.IndexOf("public static async Task<QuickTile?> SetUpAsync", StringComparison.Ordinal)..];
        Assert.Contains("var draft = new QuickActionSetupDraft(tile, isNew);", setUp);
        Assert.Contains("return await draft.RunAsync(", setUp);
        Assert.DoesNotContain("== ContentDialogResult.Primary && QuickTileDraft.CanSave(tile) ? QuickTileDraft.Finished(tile) : null", setUp);
        Assert.Contains("e.Result == ContentDialogResult.Primary && draft.Save() == null", setUp);
        Assert.Contains("Message = QuickActionSetupDraft.Words(words.Text)", setUp);
        Assert.Contains("lastField.Focus(FocusState.Programmatic);", setUp);
        Assert.Contains("box.Select(caret, selected);", setUp);
        var ask = setUp[setUp.IndexOf("private static async Task<bool> AskToDiscardAsync", StringComparison.Ordinal)..];
        Assert.Contains("CloseButtonText = QuickActionSetupDraft.DiscardKeep, DefaultButton = ContentDialogButton.Close", ask);
        Assert.Contains("PrimaryButtonText = QuickActionSetupDraft.DiscardConfirm", ask);
        Assert.Contains("== ContentDialogResult.Primary", ask);
        // Every field Keep Editing can return to is tracked.
        Assert.Equal(6, System.Text.RegularExpressions.Regex.Matches(setUp, @"fields\.Add\(").Count);
    }
}
