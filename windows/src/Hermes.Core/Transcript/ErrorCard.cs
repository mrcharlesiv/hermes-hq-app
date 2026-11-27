namespace Hermes.Core.Transcripts;

/// What a reply's error card says (App/Chat/ChatRow.swift, the `.error` row and `errorReason`): its title, its second
/// line, and which of Try Again / Choose a Model it offers.
public sealed record ErrorCardWords(string Title, string Reason, bool Retry, bool ChooseModel);

public static class ErrorCard
{
    /// The card's own title: "<bot> couldn’t finish this reply".
    public static string Title(string bot) => $"{bot} couldn’t finish this reply";

    /// The card's words for `error`. `retry`: the chat can send the prompt again (the card is the newest message,
    /// nothing runs, the prompt right above it is words only — ChatRowBuilder.retryPrompt). `at`: when it failed.
    /// A failure the app knows reads in the web's words (§6.1); a card without Retry has no retry words.
    public static ErrorCardWords Make(string error, string bot, bool retry, DateTimeOffset? at = null, DateTimeOffset? now = null)
    {
        var title = Title(bot);
        var chooseModel = false;
        var reason = Reason(error, retry, bot);
        if (TurnErrors.Copy(error, now, at) is { } known)
        {
            title = known.Title;
            switch (known.Primary)
            {
                case TurnErrorPrimary.ChooseModel: chooseModel = true; retry = false; break;
                case TurnErrorPrimary.NewChat: retry = false; break;   // the body names the action; a Retry would fail again
                case TurnErrorPrimary.Retry: break;
            }
            reason = retry || chooseModel ? known.Body : TurnErrors.WithoutRetryWords(known.Body);
        }
        return new ErrorCardWords(title, reason, retry, chooseModel);
    }

    /// The error card's second line (spec 06 §5.6.1): a short raw error (≤ 160 characters, one line) is the reason
    /// itself; anything longer gets the generic wording, and the raw text stays behind Details. `bot`: the chat's bot,
    /// which the card names (not the software).
    public static string Reason(string error, bool retry = false, string bot = "Hermes")
    {
        var trimmed = error.Trim();
        if (trimmed.Length == 0 || trimmed == "Hermes ended this turn without a reply.")
        {
            // `no_reply` (spec 06 §5.6.2): the gateway's sentence always says Hermes; the card says which bot.
            return retry ? $"{bot} ended this turn without a reply. {TranscriptWords.Tap} Try Again to send it again."
                : $"{bot} ended this turn without a reply.";
        }
        // The app's own stand-in when the gateway sent no words: it says "Hermes" under a title that names the bot.
        var ownFallback = trimmed is "Hermes couldn't finish this turn." or "Hermes couldn’t finish this turn.";
        if (!ownFallback && trimmed.Length <= 160 && !trimmed.Any(TxText.IsNewline)) return trimmed;
        return retry ? $"Something went wrong while {bot} was replying. Try again, or copy the details if it keeps happening."
            : $"Something went wrong while {bot} was replying. Copy the details if it keeps happening.";
    }
}
