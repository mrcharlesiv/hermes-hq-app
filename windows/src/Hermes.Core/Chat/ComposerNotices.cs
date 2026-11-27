using Hermes.Core.Composer;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Chat;

/// [WIN-CHAT-LOCKED-ACTIONS] The cards above the composer: the chat's problem card and "Your message is waiting"
/// (93f984bb1 App/Chat/ChatNoticeCard.swift, ChatViewController.swift `installComposerNotices`). Their identifiers and
/// words are the Mac's: the card is `<id>`, its parts `<id>.title`, `.body`, `.action`, `.copy`, `.close`; the action
/// comes before Copy, and Copy shows only with copy text.
public static class ComposerNotices
{
    /// `problemCard = ChatNoticeCard(identifier: "chat.problem")`.
    public const string ProblemId = "chat.problem";
    /// `ownerWaitCard = ChatNoticeCard(identifier: "chat.ownerWait")`.
    public const string OwnerWaitId = "chat.ownerWait";
    /// [WIN-COMPOSER-CARD-IDS] `sendFailureCard = ChatNoticeCard(identifier: "chat.sendFailure")`: the Couldn’t Send card.
    public const string SendFailureId = "chat.sendFailure";

    public const string TitlePart = "title";
    public const string BodyPart = "body";
    public const string ActionPart = "action";
    public const string CopyPart = "copy";
    public const string ClosePart = "close";

    public static string Part(string cardId, string part) => cardId + "." + part;

    public const string CopyTitle = "Copy";
    /// The ✕'s accessibility label.
    public const string CloseName = "Close";
    /// `HQAnnounce.say` when the locked chat's New Chat opened nothing.
    public const string NewChatFailed = "Couldn’t open a new chat.";

    /// `ChatNoticeCard.Content.title(_:)`: the problem card's primary button.
    public static string ActionTitle(SessionProblemPrimary primary) => primary switch
    {
        SessionProblemPrimary.ChooseModel => "Choose a Model",
        SessionProblemPrimary.TryAgain => "Try Again",
        SessionProblemPrimary.NewChat => "Continue in New Chat",   // [locked-chat]
        _ => throw new ArgumentOutOfRangeException(nameof(primary)),
    };

    /// The card's buttons in order (the ✕ aside): the action, then Copy when there is copy text.
    public static IReadOnlyList<string> Buttons(string action, string? copyText) =>
        copyText == null ? [action] : [action, CopyTitle];

    public static IReadOnlyList<string> Buttons(SessionProblem problem) => Buttons(ActionTitle(problem.Primary), problem.CopyText);

    /// [locked-chat] The problem card's Continue in New Chat (ChatViewController's `.newChat`: `slashHooks.newChat(composer.text)`,
    /// i.e. `AppModel.openNewChat(like:draft:replacing:)`): the same bot's new chat, made as Bots › New Chat makes one,
    /// opened in this chat's place with the words in the box (trimmed) in its field. Nothing is sent here. Null when
    /// nothing could open (an unknown bot: the caller says `NewChatFailed`); otherwise the running make, which never throws.
    public static Task? ContinueInNewChat(string profile, string composerText, Func<string, bool> knowsBot,
        Func<string, Task<string>> create, Action<NewChatOpening> open, Action<Exception> failed) =>
        NewChatCommand.Start(profile, composerText, knowsBot, create, open, failed);
}
