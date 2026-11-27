// [WIN-SENT-TITLES] A titled request keeps its title when its stored row comes back (docs/spec/3x-presence.md §10, G1;
// 93f984bb1 HermesKit/Presence/SentTitles.swift). Ported case for case from Tests/Presence/SentTitlesTests.swift
// (SentTitlesTests): aStoredPromptShowsItsTitle, nothingNotedChangesNothingAndTheListIsBounded,
// aTitleStandsForItsRequest, and theBrowserRequestShowsItsTitleWhereverItIsRead — Windows has no browser plugin request
// (nor the add-on setup offer), so its fixed-pair list is empty and that case runs on a made-up pair noted the same way
// (twice, as at every sign-in). The chat-level cases (TitledRequestChatTests) are in Voice/MemoSendTests+SentTitles.cs.
// Synthetic data only.

using Hermes.Core.Chat;
using Hermes.Core.Model;

namespace Hermes.Core.Tests;

public sealed class SentTitlesTests
{
    private static ChatMessage User(string id, string text) =>
        new(id, Role.User, [new TextPart(text)], DateTimeOffset.FromUnixTimeSeconds(1), RowId: 7);

    private const string Prompt = "Please install the plugin.\n\n1. First step.\n2. Second   step.";

    [Fact]
    public void AStoredPromptShowsItsTitle()
    {
        var titles = new SentTitles();
        Assert.True(titles.IsEmpty);
        titles.Note(Prompt, "Install the plugin.");
        IReadOnlyList<ChatMessage> stored =
        [
            User("a", "Hello"),
            User("b", "Please install the plugin. 1. First step. 2. Second step."),   // whitespace as the gateway kept it
            new("c", Role.Assistant, [new TextPart(Prompt)], DateTimeOffset.Now, RowId: 9),
        ];
        var shown = titles.Applied(stored);
        Assert.Equal("Hello", shown[0].Text);
        Assert.Equal(("Install the plugin.", "b", 7L), (shown[1].Text, shown[1].Id, shown[1].RowId!.Value));
        Assert.Equal(Prompt, shown[2].Text);                                    // only the person's own row is titled
        Assert.Null(titles.Title("Please install the plugin"));                // the whole prompt, not a part of it
    }

    [Fact]
    public void NothingNotedChangesNothingAndTheListIsBounded()
    {
        var titles = new SentTitles();
        IReadOnlyList<ChatMessage> rows = [User("a", "Hello")];
        Assert.Same(rows, titles.Applied(rows));
        titles.Note("", "Empty");
        titles.Note("Same", "Same");
        titles.Note("No title", "");
        Assert.True(titles.IsEmpty);
        for (var i = 0; i < SentTitles.Limit + 4; i++) titles.Note($"prompt {i}", $"title {i}");
        Assert.Null(titles.Title("prompt 0"));
        Assert.Null(titles.Title("prompt 3"));
        Assert.Equal("title 4", titles.Title("prompt 4"));
        Assert.Equal($"title {SentTitles.Limit + 3}", titles.Title($"prompt {SentTitles.Limit + 3}"));
        titles.Note("prompt 5", "renamed");
        Assert.Equal("renamed", titles.Title("prompt 5"));
        Assert.Equal("title 4", titles.Title("prompt 4"));
    }

    /// A title that came back to the field (a refused send, a queue row taken out) stands for its request again.
    [Fact]
    public void ATitleStandsForItsRequest()
    {
        var titles = new SentTitles();
        titles.Note(Prompt, "Install the plugin.");
        Assert.Equal(Prompt, titles.Prompt("Install the plugin."));            // the request as sent, line breaks and all
        Assert.Equal(Prompt, titles.Prompt("  Install the\nplugin.  "));       // whitespace aside
        Assert.Null(titles.Prompt("Install the plugin"));                      // the whole title only
        Assert.Null(titles.Prompt("install the plugin."));                     // and exactly
        Assert.Null(titles.Prompt(""));
        // Dropped with its title when the list is full.
        for (var i = 0; i < SentTitles.Limit; i++) titles.Note($"prompt {i}", $"title {i}");
        Assert.Null(titles.Prompt("Install the plugin."));
        Assert.Equal("prompt 0", titles.Prompt("title 0"));
    }

    /// The Mac's browser plugin request is its one fixed pair, noted at every sign-in. Windows has none (no browser
    /// plugin request, no add-on setup offer), so noting the fixed pairs leaves the list as it was; a fixed pair noted
    /// twice shows its title on both the stored and the flattened row, and stands for its prompt.
    [Fact]
    public void AFixedRequestShowsItsTitleWhereverItIsRead()
    {
        Assert.Empty(SentTitles.FixedPairs);
        var none = new SentTitles();
        none.NoteFixedPairs();
        none.NoteFixedPairs();
        Assert.True(none.IsEmpty);

        const string fixedPrompt = "Please install the otto add-on.\n\nUse the old wire name dispatch-push.";
        const string fixedTitle = "Install the otto add-on.";
        var titles = new SentTitles();
        titles.Note(fixedPrompt, fixedTitle);
        titles.Note(fixedPrompt, fixedTitle);                                   // noted at every sign-in
        IReadOnlyList<ChatMessage> stored = [User("a", fixedPrompt), User("b", SentTitles.Flat(fixedPrompt))];
        var shown = titles.Applied(stored);
        Assert.Equal([fixedTitle, fixedTitle], shown.Select(m => m.Text));
        Assert.DoesNotContain(shown, m => m.Text.Contains("dispatch", StringComparison.OrdinalIgnoreCase));
        Assert.Equal(fixedPrompt, titles.Prompt(fixedTitle));
    }

    /// Added: ChatText.flat (`text.replace(/\s+/g, ' ').trim()`), the key both directions use; a titled row keeps its
    /// other parts (a photo) and only its words change.
    [Fact]
    public void FlatKeysAndOtherPartsStay()
    {
        Assert.Equal("a b c", SentTitles.Flat("  a\n\tb   c \r\n"));
        Assert.Equal("", SentTitles.Flat(" \n "));
        var titles = new SentTitles();
        titles.Note(Prompt, "Install the plugin.");
        var photo = new AttachmentPart(new Hermes.Core.Attachments.MessageAttachment(Hermes.Core.Attachments.AttachmentKind.Image,
            new Hermes.Core.Attachments.AttachmentSource.Gateway("/Users/me/photo.png"), "photo.png"));
        var row = new ChatMessage("r", Role.User, [photo, new TextPart("Please install "), new TextPart("the plugin. 1. First step. 2. Second step.")],
            null, RowId: 3);
        var shown = Assert.Single(titles.Applied([row]));
        Assert.Equal("Install the plugin.", shown.Text);
        Assert.Same(photo, shown.Parts[0]);
        Assert.Equal(2, shown.Parts.Count);
    }
}
