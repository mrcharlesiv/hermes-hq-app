// [WIN-CHAT-LOCKED-ACTIONS] The cards above the composer (Hermes.Core/Chat/ComposerNotices.cs), stated from the Swift at
// 93f984bb1 (the Mac has no unit test of these): App/Chat/ChatNoticeCard.swift `Content.title(_:)` (the primary's words),
// `init(identifier:)` (the card is `<id>` and its parts `.title`, `.body`, `.action`, `.copy`, `.close`; the action
// before Copy; Copy only with copy text); App/Chat/ChatViewController.swift `installComposerNotices` (the cards'
// identifiers `chat.problem` and `chat.ownerWait`; `.newChat` hands `composer.text` to `slashHooks.newChat` and says
// "Couldn’t open a new chat." when nothing opened); App/Chat/Menus/AppModel+ChatMenus.swift `openNewChat(like:draft:)`
// (the same bot's new chat in this one's place, the words trimmed in its field, nothing sent here).

using Hermes.Core.Chat;
using Hermes.Core.Composer;
using Hermes.Core.Transcripts;
using Proof = Hermes.Core.Shell.DeliveryWalkProof;

namespace Hermes.Core.Tests;

public sealed class ComposerNoticesTests
{
    [Fact]
    public void ThePrimaryActionsAreTheMacsWords()
    {
        Assert.Equal("Choose a Model", ComposerNotices.ActionTitle(SessionProblemPrimary.ChooseModel));
        Assert.Equal("Try Again", ComposerNotices.ActionTitle(SessionProblemPrimary.TryAgain));
        Assert.Equal("Continue in New Chat", ComposerNotices.ActionTitle(SessionProblemPrimary.NewChat));
        Assert.Equal("Copy", ComposerNotices.CopyTitle);
        Assert.Equal("Close", ComposerNotices.CloseName);
        Assert.Equal("Couldn\u2019t open a new chat.", ComposerNotices.NewChatFailed);
    }

    [Fact]
    public void TheLockedChatsCardOffersContinueInNewChatThenCopy()
    {
        var locked = SessionProblem.ChatLocked("profile_mismatch");
        Assert.Equal(SessionProblemPrimary.NewChat, locked.Primary);
        Assert.Equal(["Continue in New Chat", "Copy"], ComposerNotices.Buttons(locked));
        // The owner-wait card has no copy text: Cancel Message alone.
        Assert.Equal(["Cancel Message"], ComposerNotices.Buttons(OwnerWait.CancelTitle, null));
    }

    [Fact]
    public void TheCardsCarryTheMacsIdentifiers()
    {
        Assert.Equal("chat.problem", ComposerNotices.ProblemId);
        Assert.Equal("chat.ownerWait", ComposerNotices.OwnerWaitId);
        Assert.Equal("chat.problem.action", ComposerNotices.Part(ComposerNotices.ProblemId, ComposerNotices.ActionPart));
        Assert.Equal(["title", "body", "action", "copy", "close"],
            [ComposerNotices.TitlePart, ComposerNotices.BodyPart, ComposerNotices.ActionPart, ComposerNotices.CopyPart, ComposerNotices.ClosePart]);
        // The delivery walk looks for the same ones.
        Assert.Equal(ComposerNotices.OwnerWaitId, Proof.OwnerWaitId);
        Assert.Equal(ComposerNotices.ProblemId, Proof.LockedId);
    }

    [Fact]
    public void TheCouldntSendCardCarriesTheMacsIdentifier()
    {
        // [WIN-COMPOSER-CARD-IDS] `sendFailureCard = ChatNoticeCard(identifier: "chat.sendFailure")`; its parts are
        // `<identifier>.title`, `.body`, `.action`, `.copy`, `.close` (ChatNoticeCard `init(identifier:)`).
        Assert.Equal("chat.sendFailure", ComposerNotices.SendFailureId);
        Assert.Equal(["chat.sendFailure.title", "chat.sendFailure.body", "chat.sendFailure.action", "chat.sendFailure.copy", "chat.sendFailure.close"],
            new[] { ComposerNotices.TitlePart, ComposerNotices.BodyPart, ComposerNotices.ActionPart, ComposerNotices.CopyPart, ComposerNotices.ClosePart }
                .Select(p => ComposerNotices.Part(ComposerNotices.SendFailureId, p)));
        // `SendFailure.title` and its primary, `Content(_ failure:)`: "Try Again".
        Assert.Equal("Couldn\u2019t Send", SendFailure.Title);
    }

    [Fact]
    public void TheCouldntSendCardAndItsWalksUseTheMacsIdentifier()
    {
        var feature = Read("src", "HermesHQ.Windows", "Features", "Transcript", "TranscriptFeature.cs");
        Assert.Contains("SetAutomationId(card, ComposerNotices.SendFailureId)", feature);
        foreach (var part in new[] { "TitlePart", "BodyPart", "ActionPart", "CopyPart", "ClosePart" })
            Assert.Contains($"ComposerNotices.Part(ComposerNotices.SendFailureId, ComposerNotices.{part})", feature);
        foreach (var walk in new[] { "ProofWalks.Transcript.cs", "ProofWalks.KeyboardOnly.cs", "ProofWalks.Delivery.cs" })
        {
            var text = Read("src", "HermesHQ.Windows", "Services", walk);
            Assert.Contains("ComposerNotices.SendFailureId", text);
            Assert.DoesNotContain("chat.send-failure", text);
        }
        Assert.DoesNotContain("chat.send-failure", feature);
    }

    [Fact]
    public void TheProblemCardsPrimariesEachRunTheirOwnWay()
    {
        // ChatViewController `problemCard.onPrimary`: `.chooseModel` → `presentModelSheet()` (the error card's Choose a
        // Model, the chat's own chooser), `.tryAgain` → `retryAfterProblem()`, `.newChat` → the same bot's new chat.
        var feature = Read("src", "HermesHQ.Windows", "Features", "Transcript", "TranscriptFeature.cs");
        Assert.Contains("SessionProblemPrimary.ChooseModel => () => MessageView.RequestChooseModel(session)", feature);
        Assert.Contains("SessionProblemPrimary.NewChat => () => ContinueInNewChat(ctx, problemCard)", feature);
        Assert.Contains("_ => () => _ = session.RetryAfterProblemAsync()", feature);
        var bubbles = Read("src", "HermesHQ.Windows", "Controls", "MessageView.cs");
        Assert.Contains("public static void RequestChooseModel(Hermes.Core.Chat.ChatSession? session) => ChooseModelRequested?.Invoke(session);", bubbles);
        // Every problem now has its action, then Copy.
        Assert.Equal(["Try Again", "Copy"], ComposerNotices.Buttons(SessionProblem.Make("Disk is full", "Ivy")!));
        Assert.Equal(["Choose a Model", "Copy"], ComposerNotices.Buttons(SessionProblem.Make("could not start the assistant", "Ivy")!));
        Assert.Equal(["Try Again", "Copy"], ComposerNotices.Buttons(SessionProblem.ReopenFailed(starting: true)));
    }

    [Fact]
    public async Task ContinueInNewChatOpensTheSameBotsNewChatWithTheWordsInItsBox()
    {
        var made = new List<string>();
        NewChatOpening? opened = null;
        var started = ComposerNotices.ContinueInNewChat("otto", "  Synthetic words that couldn\u2019t go  \n",
            p => p == "otto", p => { made.Add(p); return Task.FromResult("new-otto-1"); }, o => opened = o, _ => Assert.Fail("failed"));
        Assert.NotNull(started);
        await started!;
        Assert.Equal(["otto"], made);
        Assert.Equal(new NewChatOpening("otto", "new-otto-1", "Synthetic words that couldn\u2019t go"), opened);
        Assert.Equal("New Chat", NewChatCommand.Title);
    }

    [Fact]
    public async Task AnEmptyBoxOpensTheNewChatEmpty()
    {
        NewChatOpening? opened = null;
        await ComposerNotices.ContinueInNewChat("ivy", "   ", _ => true, _ => Task.FromResult("new-ivy"), o => opened = o, _ => { })!;
        Assert.Equal("", opened?.Draft);
    }

    [Fact]
    public void ABotTheRosterDoesntKnowOpensNothing()
    {
        var made = 0;
        Assert.Null(ComposerNotices.ContinueInNewChat("wren", "words", _ => false, _ => { made++; return Task.FromResult("x"); }, _ => Assert.Fail("opened"), _ => { }));
        Assert.Null(ComposerNotices.ContinueInNewChat("", "words", _ => true, _ => { made++; return Task.FromResult("x"); }, _ => Assert.Fail("opened"), _ => { }));
        Assert.Equal(0, made);
    }

    [Fact]
    public async Task AFailedMakeOpensNothingAndSaysWhy()
    {
        Exception? why = null;
        await ComposerNotices.ContinueInNewChat("juno", "words", _ => true, _ => Task.FromException<string>(new InvalidOperationException("synthetic")),
            _ => Assert.Fail("opened"), e => why = e)!;
        Assert.IsType<InvalidOperationException>(why);
    }

    [Fact]
    public void TheCardWiresItsActionThroughNavigatorNotAnotherFeature()
    {
        var feature = Read("src", "HermesHQ.Windows", "Features", "Transcript", "TranscriptFeature.cs");
        Assert.Contains("ComposerNotices.ProblemId", feature);
        Assert.Contains("ComposerNotices.OwnerWaitId", feature);
        Assert.Contains("ComposerNotices.ContinueInNewChat(", feature);
        Assert.Contains("Navigator.Go(new ChatDestination(", feature);
        Assert.Contains("ComposerNotices.ActionTitle(", feature);
        Assert.DoesNotContain("\"chat.session-problem\"", feature);
        Assert.DoesNotContain("\"chat.owner-wait\"", feature);
        Assert.DoesNotContain("ChatPage", feature);
        Assert.DoesNotContain("ComposerController", feature);
    }

    private static string Read(params string[] parts)
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir != null && !Directory.Exists(Path.Combine(dir.FullName, "src", "HermesHQ.Windows"))) dir = dir.Parent;
        Assert.NotNull(dir);
        return File.ReadAllText(Path.Combine([dir!.FullName, .. parts])).ReplaceLineEndings("\n");
    }
}
