using System.Globalization;
using System.Text;
using Hermes.Core.Model;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Tests;

// Vectors from Tests/Chat/Transcript/{TranscriptPortsTests,TranscriptWiringTests,TranscriptFinishTests,
// ChangedFilesCardTests,TableDataTests,LinkAndMathTests,ChatTextAuditTests}.swift, for the pure ports in
// Hermes.Core/Transcript (TurnMarks, TurnErrorCopy, TimelineNotes, Deliveries, ChangedFiles, LinkTargets,
// LinkPreviewParsing, TableData/TableText, MathText, ChatRow.errorReason).

public class CronDeliveryTests
{
    private static readonly DeliverySeat[] Roster =
        [new("default", "Hermes"), new("scout", "Scout"), new("scout-pro", "Scout Pro")];

    [Fact]
    public void TheThreeWrapperShapes()
    {
        Assert.Equal(new CronDelivery("Morning brief", "All quiet."), CronDeliveries.Parse("[Cron delivery: Morning brief]\nAll quiet."));
        Assert.Equal(new CronDelivery("Morning brief", "All quiet."), CronDeliveries.Parse(
            "Cronjob Response: Morning brief\n(job_id: abc123)\n-------------\n\nAll quiet.\n\nTo stop or manage this job, send me a new message (e.g. \"stop reminder\")."));
        Assert.Equal(new CronDelivery("Morning brief", "All quiet."), CronDeliveries.Parse(
            "[Cronjob \"Morning brief\" output — scheduled job, not the user. Reply if useful.]\nAll quiet."));
        Assert.Equal("body", CronDeliveries.Parse("  \n[Cron delivery: x]\nbody\n\nNote: The agent cannot see this message, and therefore cannot respond to it.")?.Body);
    }

    [Fact]
    public void BadWrappersStayMessages()
    {
        Assert.Null(CronDeliveries.Parse("[Cron delivery: x"));
        Assert.Null(CronDeliveries.Parse("[Cron delivery: " + new string('j', 161) + "]\nbody"));
        Assert.Equal(160, CronDeliveries.Parse("[Cron delivery: " + new string('j', 160) + "]\nbody")?.Job.Length);
        Assert.Null(CronDeliveries.Parse("[Cron delivery: a\nb]\nbody"));
        Assert.Null(CronDeliveries.Parse("```\n[Cron delivery: x]\nbody\n```"));
        Assert.Null(CronDeliveries.Parse("He said [Cron delivery: x]\nbody"));
        Assert.Null(CronDeliveries.Parse("[Cron delivery: x] trailing words\nbody"));
        Assert.Equal("", CronDeliveries.Parse("[Cron delivery: x]\nTo stop or manage this job, send me a new message")?.Body);
    }

    [Fact]
    public void TheJobsBotIsTheLongestNameItStartsWith()
    {
        Assert.Equal("scout", CronDeliveries.Bot("Scout morning brief", Roster)?.Profile);
        Assert.Equal("scout-pro", CronDeliveries.Bot("Scout Pro: weekly", Roster)?.Profile);
        Assert.Null(CronDeliveries.Bot("Scouting report", Roster));
        Assert.Equal("default", CronDeliveries.Bot("hermes — digest", Roster)?.Profile);
        Assert.Null(CronDeliveries.Bot("Morning brief", Roster));
        Assert.Equal("default", CronDeliveries.Speaker("Morning brief", Roster, Roster[0]).Profile);
    }

    [Fact]
    public void CronJobNameAndLead()
    {
        Assert.Equal("Inbox watch", CronDeliveries.JobName("northwind-inbox-watch", "northwind"));
        Assert.Equal("Morning brief", CronDeliveries.JobName("Ivy morning brief", "Ivy"));
        Assert.Equal("Ivy", CronDeliveries.JobName("Ivy", "Ivy"));
        Assert.Equal("Disk watch", CronDeliveries.JobName("disk-watch", "Ivy"));
        Assert.Equal("1 new inbound email\n\n1) From: a",
            CronDeliveries.WithoutJobLead("Northwind inbox watch: 1 new inbound email\n\n1) From: a", "northwind-inbox-watch"));
        Assert.Equal("Subject: hi", CronDeliveries.WithoutJobLead("Subject: hi", "northwind-inbox-watch"));
    }

    [Fact]
    public void CronHeaderNamesTheBotOnce()
    {
        Assert.Equal("Ivy · Morning brief", CronDeliveries.Header("Ivy", "Ivy morning brief"));
        Assert.Equal("Ivy · Disk watch", CronDeliveries.Header("Ivy", "ivy: disk watch"));
        Assert.Equal("Ivy · Disk watch", CronDeliveries.Header("Ivy", "Disk watch"));
        Assert.Equal("Ivy · Samantha's notes", CronDeliveries.Header("Ivy", "Samantha's notes"));
        Assert.Equal("Ivy", CronDeliveries.Header("Ivy", "Ivy"));
    }

    [Fact]
    public void PreviewsAndProcessNotes()
    {
        var cut = "[Cronjob \"northwind-inbox-watch\" output — scheduled job, not the user. Review it, act on anything...";
        Assert.Equal(("northwind-inbox-watch", (string?)null), CronDeliveries.Preview(cut));
        Assert.Equal(("Ivy morning brief", (string?)"**Three** things"),
            CronDeliveries.Preview("[Cron delivery: Ivy morning brief] (job_id: 7) --- **Three** things"));
        Assert.Equal(("Disk watch", (string?)"[SILENT]"), CronDeliveries.Preview("[Cron delivery: Disk watch]\n[SILENT]"));
        Assert.Null(CronDeliveries.Preview("hello"));
        Assert.Equal("Background process 7 finished with exit code 0.",
            CronDeliveries.ProcessNote("[IMPORTANT: Background process 7 finished with exit code 0.]"));
        Assert.Null(CronDeliveries.ProcessNote("plain"));
    }
}

public class TimelineNoteTests
{
    [Fact]
    public void ModelSwitchReadsInWords()
    {
        var text = "[System: The active model for this chat has changed to claude-opus-5-5 via provider anthropic. From this point on, respond as that model.]";
        Assert.Equal("Model changed to Opus 5.5", TimelineNotes.ModelSwitchLabel(text, _ => "Opus 5.5"));
        Assert.Equal("Model changed to claude-opus-5-5", TimelineNotes.ModelSwitchLabel(text, _ => ""));
        Assert.Equal("Model changed", TimelineNotes.ModelSwitchLabel("[System: something else]"));
        Assert.Equal(TimelineNote.OfWords("Model changed to Opus 5.5"), TimelineNotes.Note(text, displayName: _ => "Opus 5.5"));
        Assert.Equal(TimelineNote.OfWords("Model changed"), TimelineNotes.Note("[System: The active model for this chat has changed to . From this point on]"));
        var longId = $"[System: The active model for this chat has changed to {new string('m', 300)}. From this point on]";
        Assert.Equal(TimelineNote.OfWords("Model changed"), TimelineNotes.Note(longId));
        Assert.StartsWith("Model changed to ", TimelineNotes.ModelSwitchLabel("[System: The active model for this chat has changed to gpt-5.5 via provider openai. From this point on.]"));
    }

    [Fact]
    public void OtherSystemTextLosesItsBrackets()
    {
        Assert.Equal(TimelineNote.OfWords("Context was compacted."), TimelineNotes.Note("[System: Context was compacted.]"));
        Assert.Equal(TimelineNote.OfRaw("plain words"), TimelineNotes.Note("plain words"));
    }

    [Fact]
    public void AFailedTurnNoteBesideItsErrorCardIsNotDrawn()
    {
        Assert.Equal(TimelineNote.Hidden, TimelineNotes.Note("Your request was not processed. Try again.", errorNearby: true));
        Assert.Equal(TimelineNote.OfRaw("This turn did not complete."), TimelineNotes.Note("This turn did not complete.", errorNearby: false));
    }

    [Fact]
    public void TheSilentSentinel()
    {
        Assert.True(TimelineNotes.HoldsBack("[SIL"));
        Assert.True(TimelineNotes.HoldsBack("[SILENT]"));
        Assert.False(TimelineNotes.HoldsBack("[SILENT] and more"));
        Assert.False(TimelineNotes.HoldsBack("Hello"));
        Assert.True(TimelineNotes.IsSilentReply(["  [SILENT]\n"]));
        Assert.True(TimelineNotes.IsSilentReply(["[SIL", "ENT]"]));
        Assert.True(TimelineNotes.IsSilentReply(["[SILENT]", "  "]));
        Assert.False(TimelineNotes.IsSilentReply([new string(' ', TimelineNotes.SilentScanLimit) + "[SILENT]"]));
        Assert.False(TimelineNotes.IsSilentReply(["Hello"]));
        Assert.True(TimelineNotes.IsSilentWords("NO_REPLY."));
        Assert.True(TimelineNotes.IsSilentWords("*[No reply needed]*"));
        Assert.True(TimelineNotes.IsSilentWords("[Notification processed; no additional user-facing response.]"));
        Assert.False(TimelineNotes.IsSilentWords("[No response from the server]"));
        Assert.False(TimelineNotes.IsSilentWords("[silent"));
        Assert.Equal("Nothing to report — this run was silent", TimelineNotes.SilentRunText);
    }

    [Fact]
    public void ProcessNotesInPlainWords()
    {
        Assert.Equal(("Background task finished", "Background process 7 finished with exit code 0."),
            TimelineNotes.ProcessHeadline("Background process 7 finished with exit code 0."));
        Assert.Equal("Background task failed: report.py --week", TimelineNotes.ProcessWords("Background process p1 exited (exit code 2).",
            "Command: /usr/local/bin/python3 /Users/me/tools/report.py --week\nOutput: x"));
        Assert.Equal("Background task finished: npm test", TimelineNotes.ProcessWords("Background process p completed normally.", "Command: npm test"));
        Assert.Null(TimelineNotes.ProcessWords("Background process p is odd", ""));
        Assert.Null(TimelineNotes.ProcessHeadline("Something else"));
        Assert.Equal("python3 script", TimelineNotes.ShortCommand("Command: python3 - <<'PY'\nprint(1)\nPY"));
    }

    [Fact]
    public void HelperAndRestatedNotes()
    {
        Assert.Equal("2 background agents finished", TimelineNotes.HelperTitle("[ASYNC DELEGATION BATCH] 2 subagents done"));
        Assert.Equal("Subagent Task Completed: Read the logs", TimelineNotes.HelperTitle("[ASYNC DELEGATION]\nStatus: completed\nOriginal goal: Read the logs"));
        Assert.Equal("Subagent Task Failed", TimelineNotes.HelperTitle("[ASYNC DELEGATION]\nStatus: error"));
        Assert.Equal("1 background agent finished", TimelineNotes.HelperTitle("[ASYNC DELEGATION]"));
        var restated = TimelineNotes.RestatedRequest("[STILL IN PROGRESS — this is the active request, restated after the compaction boundary because it was not finished yet. Continue it; do not start over.]\nWrite the memo");
        Assert.Equal(("", "Write the memo"), restated);
        Assert.Null(TimelineNotes.RestatedRequest("Write the memo"));
        Assert.True(TimelineNotes.IsTaskSnapshot("[Your active task list was preserved across context compression]\n- [ ] one"));
        Assert.False(TimelineNotes.IsTaskSnapshot("[Your active task list was preserved across context compression] why?"));
    }

    [Fact]
    public void HeredocScriptsAreNamedByTheirCommand()
    {
        Assert.Equal("python3 script", TimelineNotes.CollapseHeredocs("python3 - <<'PY'\nimport os\nprint(1)\nPY"));
        Assert.Equal("node script\necho done", TimelineNotes.CollapseHeredocs("FOO=1 /usr/bin/node <<EOF\nconsole.log(1)\nEOF\necho done"));
        Assert.Equal("cat > notes.txt", TimelineNotes.CollapseHeredocs("cat > notes.txt <<EOF\nhello\nEOF"));
        Assert.Equal("cat\nls", TimelineNotes.CollapseHeredocs("cat <<-EOF\n\thello\n\tEOF\nls"));
        Assert.Equal("echo 1 << 2", TimelineNotes.CollapseHeredocs("echo 1 << 2"));
        Assert.Equal("ls -la", TimelineNotes.CollapseHeredocs("ls -la"));
    }
}

public class TurnErrorCopyTests
{
    private static readonly DateTimeOffset Now = DateTimeOffset.FromUnixTimeSeconds(1_790_000_000);
    private static readonly TimeZoneInfo Utc = TimeZoneInfo.Utc;
    private static readonly CultureInfo Us = CultureInfo.GetCultureInfo("en-US");

    [Fact]
    public void TheKnownKinds()
    {
        var limit = TurnErrors.Copy("Anthropic provider quota exhausted: usage_limit reached, retry after 3600s", Now, culture: Us, timeZone: Utc);
        Assert.Equal(TurnErrorKind.UsageLimit, limit?.Kind);
        Assert.StartsWith("Anthropic usage limit reached until ", limit?.Title);
        Assert.Equal("Choose another model, or wait until then.", limit?.Body);
        Assert.Equal(TurnErrorPrimary.ChooseModel, limit?.Primary);
        var bare = TurnErrors.Copy("HTTP 429 too many requests", Now);
        Assert.Equal("Usage limit reached", bare?.Title);
        Assert.Equal("Choose another model, or try again later.", bare?.Body);
        var owned = TurnErrors.Copy("This session is open in another Hermes window", Now);
        Assert.Equal("This chat is open somewhere else", owned?.Title);
        Assert.Equal(TurnErrorPrimary.NewChat, owned?.Primary);
        Assert.Equal("The computer running Hermes, or another window, has this chat open, so it can’t answer here. Start a new chat, or close it there and try again.", owned?.Body);
        var start = TurnErrors.Copy("Could not find the 'claude' CLI command", Now);
        Assert.Equal("This chat’s model couldn’t start", start?.Title);
        Assert.Equal(TurnErrorPrimary.ChooseModel, start?.Primary);
        Assert.Equal("The computer running Hermes couldn’t start this chat’s model. Choose another model, or check the model’s provider there.", start?.Body);
        var busy = TurnErrors.Copy("agent readiness probe exceeded its budget (5097)", Now);
        Assert.Equal("The computer running Hermes is busy", busy?.Title);
        Assert.Equal("It didn’t answer in time while it checked its model. Try again in a moment.", busy?.Body);
        var cut = TurnErrors.Copy("The connection was lost before the reply finished.", Now);
        Assert.Equal("The reply was cut off", cut?.Title);
        Assert.Equal(TurnErrorPrimary.Retry, cut?.Primary);
        Assert.Equal("The connection dropped before the reply finished. Click Try Again to send it again.", cut?.Body);
        Assert.Null(TurnErrors.Copy("Something odd happened", Now));
        Assert.Null(TurnErrors.Copy("", Now));
    }

    [Fact]
    public void PrecedenceWhenTwoKindsMatch()
    {
        Assert.Equal(TurnErrorKind.AnotherWindow, TurnErrors.Copy("rate limit; session has another owner", Now)?.Kind);
        Assert.Equal(TurnErrorKind.UsageLimit, TurnErrors.Copy("429 while it could not start the assistant", Now)?.Kind);
        Assert.Equal(TurnErrorKind.ModelStart, TurnErrors.Copy("could not start the assistant: readiness probe", Now)?.Kind);
        Assert.Equal(TurnErrorKind.UsageLimit, TurnErrors.Copy("Anthropic provider quota exhausted: usage_limit reached (billing issue), retry after 3600s", Now)?.Kind);
        Assert.Equal(TurnErrorKind.UsageLimit, TurnErrors.Copy("429 too many requests: Anthropic rejected the API key (401)", Now)?.Kind);
    }

    [Fact]
    public void TheNewProviderFailureKinds()
    {
        var billing = TurnErrors.Copy("Anthropic: your credit balance is too low (402).", Now);
        Assert.Equal(TurnErrorKind.Billing, billing?.Kind);
        Assert.Equal(TurnErrorPrimary.ChooseModel, billing?.Primary);
        Assert.Equal("Low on credit", billing?.Title);
        Assert.Equal("Choose another model, or add credit with its provider.", billing?.Body);

        var key = TurnErrors.Copy("Anthropic rejected the API key (401).", Now);
        Assert.Equal(TurnErrorKind.BadApiKey, key?.Kind);
        Assert.Equal("This model’s API key failed", key?.Title);
        Assert.Equal(TurnErrorKind.BadApiKey, TurnErrors.Copy("Forbidden (403): invalid_api_key", Now)?.Kind);
        Assert.Equal(TurnErrorKind.BadApiKey, TurnErrors.Copy("OpenAI authentication failed", Now)?.Kind);

        var down = TurnErrors.Copy("Overloaded", Now);
        Assert.Equal(TurnErrorKind.ProviderDown, down?.Kind);
        Assert.Equal("This model’s provider is overloaded", down?.Title);
        Assert.Equal("Choose another model, or try again in a moment.", down?.Body);
        Assert.Equal("This model’s provider is overloaded", TurnErrors.Copy("HTTP 529", Now)?.Title);
        Assert.Equal("This model’s provider is overloaded", TurnErrors.Copy("503 Service Unavailable from the provider", Now)?.Title);
        foreach (var text in new[] { "Error code: 500 - internal server error", "502 Bad Gateway", "HTTP 504", "Internal Server Error" })
        {
            var copy = TurnErrors.Copy(text, Now);
            Assert.Equal(TurnErrorKind.ProviderDown, copy?.Kind);
            Assert.Equal("This model’s provider had a problem", copy?.Title);
        }
        var untilLater = TurnErrors.Copy("Overloaded, retry after 7200s", Now, culture: Us, timeZone: Utc);
        Assert.StartsWith("This model’s provider is overloaded until ", untilLater?.Title);
        Assert.Equal("Choose another model, or wait until then.", untilLater?.Body);

        var gone = TurnErrors.Copy("The model 'x' does not exist (404).", Now);
        Assert.Equal(TurnErrorKind.ModelGone, gone?.Kind);
        Assert.Equal("This model is gone", gone?.Title);
        Assert.Equal("Choose another model to continue this chat.", gone?.Body);
        Assert.Equal(TurnErrorKind.ModelGone, TurnErrors.Copy("model_not_found: gpt-ancient", Now)?.Kind);

        Assert.Equal(TurnErrorKind.ProviderDown, TurnErrors.Copy("Error code: 529 - {'type': 'error', 'error': {'type': 'overloaded_error'}}", Now)?.Kind);
        Assert.Equal(TurnErrorKind.ModelGone, TurnErrors.Copy("Error code: 404 - {'error': {'type': 'not_found_error', 'message': 'model: claude-x'}}", Now)?.Kind);
        Assert.Equal(TurnErrorKind.BadApiKey, TurnErrors.Copy("Error code: 401 - invalid x-api-key", Now)?.Kind);
        Assert.Null(TurnErrors.Copy("The fetch tool got 404 from example.com and the turn stopped", Now));
        Assert.Null(TurnErrors.Copy("Stopped after 512 steps", Now));
        Assert.Null(TurnErrors.Copy("The file does not exist", Now));
        foreach (var copy in new[] { billing, key, down, gone })
            Assert.DoesNotContain("switch provider", copy!.Title, StringComparison.OrdinalIgnoreCase);
        Assert.Equal("This model’s provider is overloaded", TurnErrors.Copy("Overloaded")?.Title);
        Assert.Equal("This model’s provider had a problem", TurnErrors.Copy("Error code: 500 - internal server error")?.Title);
    }

    [Fact]
    public void AWaitThatHasPassedNamesNoTime()
    {
        var old = TurnErrors.Copy("rate limit, retry after 60s", Now, at: Now.AddSeconds(-3600));
        Assert.Equal("Usage limit reached", old?.Title);
        Assert.Equal("Choose another model, or try again later.", old?.Body);
        Assert.Equal(1_790_003_600, TurnErrors.ResetsAt("resets_at: 1790003600", Now));
        Assert.Contains(":", TurnErrors.ResetTimeLabel(1_790_003_600, Now, Us, Utc));
        // ICU puts a narrow no-break space before "PM" (as the Mac's DateFormatter does).
        static string Plain(string s) => s.Replace((char)0x202F, ' ');
        Assert.Equal("2:13 PM", Plain(TurnErrors.ResetTimeLabel(1_790_000_000, Now, Us, Utc)));
        Assert.Equal("Tue, Sep 22, 3:13 PM", Plain(TurnErrors.ResetTimeLabel(1_790_090_000, Now, Us, Utc)));
    }

    [Fact]
    public void DetailsStartClosedForProviderAndStartFailures()
    {
        Assert.True(TurnErrors.DetailClosed("usage_limit reached"));
        Assert.True(TurnErrors.DetailClosed("failed to start the agent"));
        Assert.True(TurnErrors.DetailClosed("credit balance is too low (402)"));
        Assert.True(TurnErrors.DetailClosed("Anthropic rejected the API key (401)"));
        Assert.True(TurnErrors.DetailClosed("Overloaded"));
        Assert.True(TurnErrors.DetailClosed("The model 'x' does not exist (404)"));
        Assert.False(TurnErrors.DetailClosed("Something odd"));
        Assert.False(TurnErrors.DetailClosed(null));
        Assert.True(TurnErrors.DetailRepeatsBody("No such file.", "No such file"));
        Assert.True(TurnErrors.DetailRepeatsBody("  ", "x"));
        Assert.False(TurnErrors.DetailRepeatsBody("Traceback: line 4", "No such file"));
    }

    [Fact]
    public void NoRetryWordsWithoutARetryButton()
    {
        Assert.Equal("Copy the details if it keeps happening.", TurnErrors.WithoutRetryWords("Retry, or copy the details if it keeps happening."));
        Assert.Equal("Wait a minute, then send it again.", TurnErrors.WithoutRetryWords("Wait a minute, then retry."));
        Assert.Equal("The connection dropped before the reply finished.",
            TurnErrors.WithoutRetryWords("The connection dropped before the reply finished. Retry to send it again."));
        Assert.Equal("Send it again in a moment.", TurnErrors.WithoutRetryWords("Try again in a moment."));
        Assert.Equal("Send it again later.", TurnErrors.WithoutRetryWords("Try again later."));
        Assert.Equal("Retry.", TurnErrors.WithoutRetryWords("Retry."));
        Assert.Equal("The connection dropped before the reply finished.",
            TurnErrors.WithoutRetryHint("The connection dropped before the reply finished. Retry to send it again."));
        Assert.Equal("The connection dropped before the reply finished.",
            TurnErrors.WithoutRetryWords("The connection dropped before the reply finished. Tap Try Again to send it again."));
        Assert.Equal("Copy the details if it keeps happening.", TurnErrors.WithoutRetryWords("Try again, or copy the details if it keeps happening."));
        Assert.Equal("The connection dropped before the reply finished.",
            TurnErrors.WithoutRetryHint("The connection dropped before the reply finished. Tap Try Again to send it again."));
    }

    private static ChatMessage Failed(string id, string error, params ChatPart[] parts) => new(id, Role.Assistant, parts, Error: error);

    [Fact]
    public void OneCardPerFailedTurn()
    {
        var user = new ChatMessage("u", Role.User, [new TextPart("hi")]);
        var out1 = TurnErrors.WithoutDuplicateTurnErrors([user, Failed("a", "HTTP 429"), Failed("b", "rate limit reached")]);
        Assert.Equal(3, out1.Count);
        Assert.Null(out1[1].Error);
        Assert.NotNull(out1[2].Error);
        var withOutput = TurnErrors.WithoutDuplicateTurnErrors([user, Failed("a", "boom", new TextPart("partial")), Failed("b", "boom")]);
        Assert.NotNull(withOutput[1].Error);
        Assert.Null(withOutput[2].Error);
        IReadOnlyList<ChatMessage> different = [user, Failed("a", "boom"), Failed("b", "other")];
        Assert.Same(different, TurnErrors.WithoutDuplicateTurnErrors(different));
        IReadOnlyList<ChatMessage> twoTurns = [Failed("old", "boom"), user, Failed("b", "boom")];
        Assert.Same(twoTurns, TurnErrors.WithoutDuplicateTurnErrors(twoTurns));
    }

    [Fact]
    public void TheSessionProblemCard()
    {
        var start = SessionProblem.Make("could not start the assistant", "Ivy");
        Assert.Equal("This chat’s model couldn’t start", start?.Title);
        Assert.Equal(SessionProblemPrimary.ChooseModel, start?.Primary);
        Assert.Equal(SessionProblemPrimary.TryAgain, SessionProblem.Make("could not start the assistant", "Ivy", room: true)?.Primary);
        Assert.Equal("Couldn’t reopen this chat", SessionProblem.Make("Could not reopen that session", "Ivy")?.Title);
        Assert.True(SessionProblem.Make("Could not reopen that session", "Ivy")?.Reopen);
        Assert.Equal("Ivy reported a problem", SessionProblem.Make("Disk is full", "Ivy")?.Title);
        Assert.Equal("Hermes reported a problem", SessionProblem.Make("Disk is full", "")?.Title);
        Assert.Null(SessionProblem.Make("Turn cancelled before the agent was ready", "Ivy"));
        Assert.Null(SessionProblem.Make("Session no longer running before the agent was ready to go", "Ivy"));
        Assert.Null(SessionProblem.Make("  ", "Ivy"));
        Assert.Equal("This chat is still starting on the computer running Hermes.", SessionProblem.ReopenFailed(true).Body);
        Assert.Equal("The computer running Hermes didn’t answer in time.", SessionProblem.ReopenFailed(false).Body);
        var longText = SessionProblem.Make(new string('x', 10_000), "Ivy");
        Assert.True(longText!.Body.Length < 200);
        Assert.Equal(10_000, longText.Detail.Length);
        Assert.Equal("Ivy reported a problem\n\nDisk is full", SessionProblem.Make("Disk is full", "Ivy")!.CopyText);
        Assert.Equal(SessionProblemPrimary.NewChat, SessionProblem.ChatLocked("x").Primary);
    }

    [Fact]
    public void CouldntSendWording()
    {
        Assert.Equal("Couldn’t Send", SendFailure.Title);
        Assert.Equal("The computer running Hermes didn’t answer in time. Your message is still in the box below.", SendFailure.Make("The request timed out.").Body);
        Assert.Equal("You’re offline. Your message is still in the box below.", SendFailure.Make("You’re offline. Check your connection.").Body);
        Assert.Equal("Your message is still in the box below. Session busy.", SendFailure.Make("session busy").Body);
        Assert.Equal("Your message is still in the box below.", SendFailure.Make(null).Body);
        Assert.True(SendFailure.Make(new string('r', 400)).Body.Length <= 40 + 161);
        Assert.Equal("The computer running Hermes didn’t answer in time. Your message is still in the box below.",
            SendFailure.Make("request timed out after 30s: prompt.submit").Body);
        Assert.Equal("You’re offline. Your message is still in the box below.", SendFailure.Make("The Internet connection appears to be offline.").Body);
        Assert.Equal("Your message is still in the box below.", SendFailure.Make("").Body);
        Assert.Null(SendFailure.Make("The Internet connection appears to be offline.").CopyText);
        Assert.Equal("Your message is still in the box below. This profile has no model provider.",
            SendFailure.Make("This profile has no model provider").Body);
    }

    [Fact]
    public void AChatOwnedElsewhereOrBusySaysSoPlainly()
    {
        var reason = "This chat is open in another Hermes window/terminal. Use it there, or start a new chat here.\n"
            + "Details: session 20261018_083300_aabbcc02 opened by desktop 42m ago.";
        var failure = SendFailure.Make(reason);
        Assert.Equal("Your message is still in the box below. Hermes has this chat open somewhere else, like the Hermes "
            + "desktop app. Close it there and try again, or start a new chat.", failure.Body);
        Assert.Equal(reason, failure.CopyText);
        var busy = "The gateway is running a turn in this chat and the gateway refused it. Nothing was sent. Send it again when the current turn ends.";
        Assert.Equal("Your message is still in the box below. Hermes is still running a reply in this chat. Send it again when that reply is done.",
            SendFailure.Make(busy).Body);
    }
}

public class ErrorCardTests
{
    [Fact]
    public void TheCardsWords()
    {
        Assert.Equal("Ivy couldn’t finish this reply", ErrorCard.Title("Ivy"));
        var reason = ErrorCard.Reason("Hermes couldn't finish this turn.", retry: false, bot: "Luna");
        Assert.DoesNotContain("Hermes", reason);
        Assert.Contains("Luna", reason);
        Assert.Equal("Something went wrong while Luna was replying. Copy the details if it keeps happening.", reason);
        Assert.Equal("Something went wrong while Luna was replying. Try again, or copy the details if it keeps happening.",
            ErrorCard.Reason(new string('x', 200), retry: true, bot: "Luna"));
        Assert.Equal("Ivy ended this turn without a reply. Click Try Again to send it again.", ErrorCard.Reason("", retry: true, bot: "Ivy"));
        Assert.Equal("Ivy ended this turn without a reply.", ErrorCard.Reason("Hermes ended this turn without a reply.", bot: "Ivy"));
        Assert.Equal("Disk is full", ErrorCard.Reason("Disk is full"));
    }

    [Fact]
    public void AKnownFailureUsesItsOwnWordsAndButtons()
    {
        var plain = ErrorCard.Make("Disk is full", "Ivy", retry: true);
        Assert.Equal(new ErrorCardWords("Ivy couldn’t finish this reply", "Disk is full", true, false), plain);
        var limit = ErrorCard.Make("HTTP 429 too many requests", "Ivy", retry: true);
        Assert.Equal(new ErrorCardWords("Usage limit reached", "Choose another model, or try again later.", false, true), limit);
        var cutNoRetry = ErrorCard.Make("socket closed", "Ivy", retry: false);
        Assert.Equal("The reply was cut off", cutNoRetry.Title);
        Assert.False(cutNoRetry.Retry);
        var owned = ErrorCard.Make("SESSION_NOT_OWNED", "Ivy", retry: true);
        Assert.False(owned.Retry);
        Assert.Equal("The computer running Hermes, or another window, has this chat open, so it can’t answer here. Start a new chat, or close it there and send it again.", owned.Reason);
    }
}

public class TurnMarkTests
{
    [Fact]
    public void DurationsInWords()
    {
        Assert.Null(TurnDuration.Short(0.4));
        Assert.Equal("4s", TurnDuration.Short(4.2));
        Assert.Equal("1m 12s", TurnDuration.Short(72));
        Assert.Equal("1h 3m", TurnDuration.Short(3780));
        Assert.Null(TurnDuration.Short(double.NaN));
        Assert.Null(TurnDuration.Short(-3));
        Assert.Equal("1s", TurnDuration.Short(1.2));
        Assert.Equal("Took 1 minute 12 seconds", TurnDuration.Spoken(72));
        Assert.Equal("Took 1 second", TurnDuration.Spoken(1));
        Assert.Equal("Took 1 hour 3 minutes", TurnDuration.Spoken(3780));
    }

    [Fact]
    public void MarksBelongToTheirChatAndTheOldestGoesFirst()
    {
        var store = new TurnMarkStore();
        store.Set(6, "acct|ivy|s1", "stored-row-12-assistant");
        Assert.Equal(6, store.Seconds("acct|ivy|s1", "stored-row-12-assistant"));
        Assert.Null(store.Seconds("acct|max|s9", "stored-row-12-assistant"));
        for (var n = 0; n < 200; n++) store.Set(1, "s", $"m{n}");
        Assert.Equal(200, store.Count);
        Assert.Null(store.Seconds("acct|ivy|s1", "stored-row-12-assistant"));
        store.Move("s", "m199", "stored-9");
        Assert.Equal(1, store.Seconds("s", "stored-9"));
    }

    [Fact]
    public void MarksSurviveARelaunch()
    {
        IReadOnlyList<TurnMarkEntry> saved = [];
        new TurnMarkStore(save: s => saved = s).Set(72, "a", "m");
        Assert.Equal(72, new TurnMarkStore(saved).Seconds("a", "m"));
        IReadOnlyList<SeenEntry> seen = [];
        new SeenStore(save: s => seen = s).Mark("chat", "m9", 9);
        Assert.Equal("m9", new SeenStore(seen).MarkFor("chat")?.NewestId);
    }

    [Fact]
    public void WhereAReopenedChatLands()
    {
        string[] ids = ["u1", "a1", "u2", "a2", "a3"];
        bool[] incoming = [false, true, false, true, true];
        var now = DateTimeOffset.Now;
        Assert.Equal(SeenLanding.Usual, SeenStore.Landing(null, ids, incoming));
        Assert.Equal(SeenLanding.Usual, SeenStore.Landing(new SeenMark("a3", 5, now), ids, incoming));
        Assert.Equal(SeenLanding.UnseenAt(3), SeenStore.Landing(new SeenMark("a1", 2, now), ids, incoming));
        Assert.Equal(SeenLanding.UnseenAt(3), SeenStore.Landing(new SeenMark("local-1", 3, now), ids, incoming));
        Assert.Equal(SeenLanding.Usual, SeenStore.Landing(new SeenMark("a1", 2, now), ["u1", "a1", "u2"], [false, true, false]));
        var store = new SeenStore();
        for (var n = 0; n < 130; n++) store.Mark($"chat{n}", "m", 1);
        Assert.Equal(120, store.Count);
        Assert.Null(store.MarkFor("chat0"));
        Assert.NotNull(store.MarkFor("chat129"));
    }
}

public class ChangedFilesTests
{
    private const string DiffA = "--- a/src/app.py\n+++ b/src/app.py\n@@ -1,3 +1,4 @@\n import os\n-print(1)\n+print(2)\n+print(3)\n";

    private static EditCall Call(string name, string? path, string? diff, ToolState state = ToolState.Done) =>
        new(name, state, path is null ? "{}" : $"{{\"path\":\"{path}\"}}", diff);

    [Fact]
    public void OneRowPerFileWithSummedCounts()
    {
        var files = ChangedFiles.Derive([
            Call("patch", "src/app.py", DiffA),
            Call("write_file", "README.md", "+++ b/README.md\n+hello\n"),
            Call("patch", "src/app.py", DiffA),
            Call("patch", "x.py", DiffA, ToolState.Failed),
            Call("patch", "y.py", null, ToolState.Running),
            Call("terminal", "z.py", DiffA),
            Call("patch", null, "+++ b/from/header.txt\n+x\n"),
        ]);
        Assert.Equal(["src/app.py", "README.md", "from/header.txt"], files.Select(f => f.Path));
        Assert.Equal(new ChangedFile("src/app.py", "app.py", 4, 2, 2), files[0]);
        Assert.Equal("1 file changed", ChangedFiles.Title(1));
        Assert.Equal("3 files changed", ChangedFiles.Title(3));
    }

    [Fact]
    public void FromToolCallsAndTheirResults()
    {
        var withResult = new ToolCall("w", "write_file", null, null, ToolState.Done, ArgsJson: "{\"path\":\"notes.md\"}",
            ResultText: "{\"success\":true,\"inline_diff\":\"+++ b/notes.md\\n+a\\n+b\\n\"}");
        var kept = new ToolCall("p", "patch", null, null, ToolState.Done, ArgsJson: "{\"file_path\":\"a.py\"}");
        var files = ChangedFiles.Derive([withResult, kept], id => id == "p" ? "-x\n+y\n" : null);
        Assert.Equal([new ChangedFile("notes.md", "notes.md", 2, 0), new ChangedFile("a.py", "a.py", 1, 1)], files);
        Assert.Null(ChangedFiles.DiffFromResult("not json"));
    }

    [Fact]
    public void LineStatsIgnoreHeaders()
    {
        Assert.Equal((2, 1), ChangedFiles.LineStats(DiffA));
        Assert.Equal(0, ChangedFiles.LineStats("").Added);
        Assert.Equal(0, ChangedFiles.LineStats("--- a\n+++ b\n").Added);
        Assert.Equal((1, 1), ChangedFiles.LineStats("+a\r\n-b\r\n"));
    }

    [Fact]
    public void ThePreviewShowsEightChangedLines()
    {
        var small = ChangedFiles.Preview(DiffA);
        Assert.Equal([" import os", "−print(1)", "+print(2)", "+print(3)"], small.Lines.Select(l => l.Text));
        Assert.False(small.More);
        var big = string.Join("\n", Enumerable.Range(0, 3000).Select(n => $"+line {n}"));
        var preview = ChangedFiles.Preview(big);
        Assert.Equal(8, preview.Lines.Count);
        Assert.True(preview.More);
        Assert.Empty(ChangedFiles.Preview("--- a\n+++ b\n").Lines);
        Assert.Empty(ChangedFiles.Preview("Binary files a/x.png and b/x.png differ").Lines);
        Assert.Single(ChangedFiles.Preview("+a\n\\ No newline at end of file").Lines);
    }

    private static string HermesDiff(string path, string[] added, string[] removed)
    {
        var e = "\u001B";
        string fg = $"{e}[38;2;150;150;150m", bg = $"{e}[48;2;20;60;20m", reset = $"{e}[0m";
        var lines = new List<string> { "  ┊ review diff", $"{fg}a/{path} → b/{path}{reset}", $"{fg}@@ -1,{removed.Length} +1,{added.Length} @@{reset}" };
        lines.AddRange(removed.Select(r => $"{fg}{bg}-{r}{reset}"));
        lines.AddRange(added.Select(a => $"{fg}{bg}+{a}{reset}"));
        return string.Join("\n", lines);
    }

    [Fact]
    public void AColouredHermesDiffCountsItsLines()
    {
        var raw = HermesDiff("meal-plan.md", ["# Meals", "- Tacos", "- Curry"], ["# Old"]);
        Assert.Equal((3, 1), ChangedFiles.LineStats(raw));
        Assert.Equal("meal-plan.md", ChangedFiles.Path(null, raw));
        Assert.Equal(["−# Old", "+# Meals", "+- Tacos", "+- Curry"], ChangedFiles.Preview(raw).Lines.Select(l => l.Text));
        var files = ChangedFiles.Derive([new EditCall("write_file", ToolState.Done, "{\"path\":\"meal-plan.md\"}", raw)]);
        Assert.Equal(3, files[0].Added);
        Assert.Equal(1, files[0].Removed);
    }

    [Fact]
    public void MatchingACardRowToTheChangesList()
    {
        Assert.Equal("src/app.py", ChangedFiles.Match("/work/demo/src/app.py", ["README.md", "src/app.py"]));
        Assert.Equal("src/app.py", ChangedFiles.Match("src/app.py", ["src/app.py"]));
        Assert.Equal("src/app.py", ChangedFiles.Match("./src/app.py", ["src/app.py"]));
        Assert.Null(ChangedFiles.Match("other.py", ["src/app.py"]));
    }

    [Fact]
    public void ResolvingAnEditToolsPathAgainstTheChatsFolder()
    {
        Assert.Equal("/work/demo/src/app.py", ChangedFiles.Resolve("src/app.py", "/work/demo"));
        Assert.Equal("/work/demo/src/app.py", ChangedFiles.Resolve("./src/app.py", "/work/demo"));
        Assert.Equal("/work/demo/src/app.py", ChangedFiles.Resolve("src/app.py", "/work/demo/"));
        Assert.Equal("src/app.py", ChangedFiles.Resolve("src/app.py", null));
        Assert.Equal("src/app.py", ChangedFiles.Resolve("src/app.py", ""));
        Assert.Equal("/abs/app.py", ChangedFiles.Resolve("/abs/app.py", "/work/demo"));
        Assert.Equal("~/app.py", ChangedFiles.Resolve("~/app.py", "/work/demo"));
        Assert.Equal("C:\\app.py", ChangedFiles.Resolve("C:\\app.py", "/work/demo"));
        Assert.Equal("/etc/hosts", ChangedFiles.Resolve("/etc/hosts", "/work/demo"));
    }

    [Fact]
    public void TheDiffStoreStaysWithinItsBounds()
    {
        var store = new ToolDiffStore();
        for (var n = 0; n < 250; n++) store.Set($"+line {n}\n", $"t{n}");
        Assert.Equal(200, store.Counts.Diffs);
        Assert.Null(store.Diff("t0"));
        Assert.NotNull(store.Diff("t249"));
        var huge = new string('x', 700_000);
        store.Set(huge, "h1");
        store.Set(huge, "h2");
        Assert.True(store.Counts.Characters <= ToolDiffStore.MaxCharacters);
        Assert.NotNull(store.Diff("h2"));
        store.Set(new string('y', 2_000_000), "h3");
        Assert.Equal(1, store.Counts.Diffs);
        Assert.NotNull(store.Diff("h3"));
        store.Clear();
        Assert.Equal((0, 0), store.Counts);
    }
}

public class LinkTargetTests
{
    private static LinkTarget T(string url) => LinkTargets.Target(url);

    [Fact]
    public void WhereALinkGoes()
    {
        Assert.Equal(new LinkTarget(LinkTargetKind.Page, new Uri("https://example.com/a")), T("https://example.com/a"));
        foreach (var loop in new[] { "http://localhost:3000", "http://127.0.0.1:8080/x", "http://127.4.5.6/", "http://[::1]:9/", "http://0.0.0.0:80", "http://app.localhost/" })
            Assert.True(T(loop) == LinkTarget.Loopback, loop);
        Assert.Equal(LinkTargetKind.Page, T("http://127.example.com/").Kind);
        Assert.Equal(new LinkTarget(LinkTargetKind.System, new Uri("mailto:a@example.com")), T("mailto:a@example.com"));
        Assert.Equal(new LinkTarget(LinkTargetKind.File, Path: "/etc/hosts"), T("file:///etc/hosts"));
        Assert.Equal("C:/Users/me/report.html", T("file:///C:/Users/me/report.html").Path);
        foreach (var bad in new[] { "file://elsewhere.example.com/etc/hosts", "javascript:alert(1)", "ftp://example.com/x", "data:text/html,hi" })
            Assert.True(T(bad) == LinkTarget.Refused, bad);
    }

    [Fact]
    public void EverySpellingOfTheGatewayComputersOwnAddressIsLoopback()
    {
        foreach (var host in new[] { "127.1", "2130706433", "0177.0.0.1", "0x7f.0.0.1", "127.000.000.001", "::ffff:127.0.0.1", "[::ffff:7f00:1]", "::",
                     "[::1]", "0", "::127.0.0.1", "LOCALHOST", "localhost.", "::1%lo0" })
            Assert.True(LinkTargets.IsLoopback(host), host);
        foreach (var host in new[] { "example.com", "127.example.com", "8.8.8.8", "128.0.0.1", "::ffff:8.8.8.8", "2001:db8::1", "1.127.0.0", "localhost.example.com" })
            Assert.False(LinkTargets.IsLoopback(host), host);
        foreach (var url in new[] { "http://127.1:8080/", "http://2130706433/", "http://[::ffff:127.0.0.1]:3000/x", "http://[::ffff:7f00:1]/" })
            Assert.True(T(url) == LinkTarget.Loopback, url);
        Assert.Equal("This page runs on the computer running Hermes, so it can’t open on your iPad.", LinkTargets.LoopbackNotice("iPad"));
    }

    [Fact]
    public void FlagsStayWhole()
    {
        Assert.Equal("-\u2060-\u2060user", InlineCodeText.Display("--user"));
        Assert.Equal("-\u2060v", InlineCodeText.Display("-v"));
        Assert.Equal("--break-system-packages", InlineCodeText.Plain(InlineCodeText.Display("--break-system-packages")));
        foreach (var other in new[] { "a - b", "x-y", "pip install --user", "-", "--", string.Concat(Enumerable.Repeat("-a", 30)) })
            Assert.Equal(other, InlineCodeText.Display(other));
    }

    [Fact]
    public void FindLooksPastTheJoinersInDrawnText()
    {
        var drawn = "Use " + InlineCodeText.Display("--user") + " here, or " + InlineCodeText.Display("--user-site") + ".";
        var ranges = InlineCodeText.FindRanges("--user", drawn);
        Assert.Equal(2, ranges.Count);
        Assert.Equal(["--user", "--user"], ranges.Select(r => InlineCodeText.Plain(drawn.Substring(r.Start, r.Length))));
        Assert.Equal([(10, 4)], InlineCodeText.FindRanges("user", "no flags, user"));
        Assert.Equal("Use --user here, or --user-site.", InlineCodeText.Plain(drawn));
        Assert.Equal(ranges.Count, InlineCodeText.Find("--user", InlineCodeText.Plain(drawn)).Count);
    }

    [Fact]
    public void SpokenTextHasNoMarkdown()
    {
        var said = SpokenMarkdown.Plain("## Plan\n\nInstall with `--user`, **not** *globally*. See the [guide](https://example.com/a_b).\n\n- one\n- [x] two\n\n```sh\npip install x\n```\n\n| A | B |\n|---|---|\n| 1 | 2 |");
        foreach (var mark in new[] { "**", "`", "##", "](", "- ", "|" }) Assert.DoesNotContain(mark, said);
        Assert.Contains("Install with --user, not globally. See the guide.", said);
        Assert.Equal("snake_case_name and 2 * 3 * 4", SpokenMarkdown.Plain("snake_case_name and 2 * 3 * 4"));
        Assert.Equal("plain words", SpokenMarkdown.Plain("plain words"));
    }

    [Fact]
    public void ScreenReadersSummarizeCodeAndTables()
    {
        var code = "```python\n" + string.Join("\n", Enumerable.Range(1, 40).Select(n => $"x{n} = {n}")) + "\n```";
        var said = SpokenMarkdown.Plain("Try this:\n\n" + code + "\n\nThen:\n\n| Name | Score |\n|---|---|\n| A | 1 |\n| B | 2 |");
        Assert.Contains("Code, Python, 40 lines: x1 = 1", said);
        Assert.DoesNotContain("x40 = 40", said);
        Assert.Contains("Table, 2 rows, 2 columns. Name, Score", said);
        Assert.DoesNotContain("B, 2", said);
        Assert.StartsWith("Code, 1 line: ls", SpokenMarkdown.Plain("```\nls\n```"));
        Assert.Equal("Formula: E = mc^2 here", SpokenMarkdown.Plain("$E = mc^2$ here"));
    }

    [Fact]
    public void CodeLanguagesAreNamedProperly()
    {
        Assert.Equal("HCL", CodeLanguage.Label("hcl"));
        Assert.Equal("CSV", CodeLanguage.Label("csv"));
        Assert.Equal("Objective-C", CodeLanguage.Label("objective-c"));
        Assert.Equal("SCSS", CodeLanguage.Label("scss"));
        Assert.Equal("Python", CodeLanguage.Label("python"));
        Assert.Equal("Zig", CodeLanguage.Label("zig"));
        Assert.Null(CodeLanguage.Label("text"));
    }
}

public class FileLinkTests
{
    [Fact]
    public void PathsThatOpen()
    {
        var report = "/Users/me/.hermes/profiles/otto/research/weekly-notes-2026-10-28.md";
        Assert.Equal(report, FileLinks.PathInCode(report));
        Assert.Equal(report, FileLinks.PathInCode($" {report} "));
        Assert.Equal("~/notes/plan.md", FileLinks.PathInCode("~/notes/plan.md"));
        Assert.Equal("/Users/me/Projects/app", FileLinks.PathInCode("/Users/me/Projects/app"));
        Assert.Equal("/Users/me/Projects/app/", FileLinks.PathInCode("/Users/me/Projects/app/"));
        Assert.Equal("/srv/app/src/main.swift", FileLinks.PathInCode("/srv/app/src/main.swift:42"));
        Assert.Equal("/srv/app/src/main.swift", FileLinks.PathInCode("/srv/app/src/main.swift:42:7"));
        Assert.Equal("/data/out/report.tar.gz", FileLinks.PathInCode("/data/out/report.tar.gz"));
        Assert.Equal("/Users/me/My Reports/q3 plan.md", FileLinks.PathInCode("/Users/me/My Reports/q3 plan.md"));
        Assert.Equal("C:\\Users\\ivy\\notes.md", FileLinks.PathInCode("C:\\Users\\ivy\\notes.md"));
        Assert.Equal("/Users/me/project/Makefile", FileLinks.PathInCode("/Users/me/project/Makefile"));
    }

    [Fact]
    public void CodeThatStaysCode()
    {
        foreach (var code in new[] { "/new", "/compress", "/api/fs/list", "/api/status", "/README.md", "//server/share/a.md", "src/app.ts",
                     "npm test", "/usr/bin/env python3", "/Users/me/run.sh --fast", "/Users/me/*.md", "/Users/me/a.md && ls",
                     "https://example.com/a.md", "~", "~/", "/v1.2/x", "--user", "a.md", "/Users/me/$HOME/x.md" })
            Assert.True(FileLinks.PathInCode(code) is null, code);
    }

    [Fact]
    public void Extensions()
    {
        Assert.True(FileLinks.HasExtension("report.md") && FileLinks.HasExtension("a.tar.gz") && FileLinks.HasExtension("x.mp4"));
        Assert.False(FileLinks.HasExtension(".env") || FileLinks.HasExtension("Makefile") || FileLinks.HasExtension("v1.2")
            || FileLinks.HasExtension("name.") || FileLinks.HasExtension("a.toolongextension"));
    }

    [Fact]
    public void LinkRoundTrip()
    {
        var path = "/Users/me/My Reports/plan #2 (final).md";
        var url = FileLinks.Url(path);
        Assert.StartsWith("#file:", url);
        Assert.Equal(path, FileLinks.PathFromLink(url));
        Assert.Null(FileLinks.PathFromLink("https://example.com"));
    }

    [Fact]
    public void FolderAndName()
    {
        Assert.Equal(("/a/b", "c.md"), FileLinks.Place("/a/b/c.md"));
        Assert.Equal(("/a/b", (string?)null), FileLinks.Place("/a/b/"));
        Assert.Equal(("/", "a.md"), FileLinks.Place("/a.md"));
        Assert.Equal(("~", "plan.md"), FileLinks.Place("~/plan.md"));
        Assert.Equal(("C:\\Users\\ivy", "notes.md"), FileLinks.Place("C:\\Users\\ivy\\notes.md"));
        Assert.Equal(("C:\\", "notes.md"), FileLinks.Place("C:\\notes.md"));
    }

    [Fact]
    public void BarePathsInWords()
    {
        static List<string> Paths(string s) => [.. FileLinks.Bare(s).Select(b => b.Path)];
        var pdf = "/Users/me/.hermes/profiles/otto/research/q4/Planning-Notes-2026-10-29.pdf";
        Assert.Equal([pdf], Paths(pdf));
        Assert.Equal([pdf], Paths($"Saved to {pdf}."));
        Assert.Equal(["~/notes/plan.md", "/srv/app/main.swift"], Paths("(see ~/notes/plan.md, then /srv/app/main.swift:42)"));
        Assert.Equal(["/tmp/out/log.txt"], Paths("\"/tmp/out/log.txt\""));
        Assert.Equal(["/Users/me/Projects/app/"], Paths("Moved to /Users/me/Projects/app/"));
        Assert.Equal(["/Users/me/plan(1).md"], Paths("(/Users/me/plan(1).md)."));
        Assert.Equal(["C:\\Users\\ivy\\notes.md"], Paths("C:\\Users\\ivy\\notes.md"));
        foreach (var words in new[] { "and/or", "24/7 support", "10/29/2026", "run /new to start", "GET /api/fs/list", "https://example.com/Users/a.md",
                     "example.com/Users/a.md", "src/app/main.swift", "//server/share/a.md", "/README.md", "~/ is home", "/Users/me/*.md", "/Users/me/Alex's.md" })
            Assert.True(Paths(words).Count == 0, words);
        var s = "Open /srv/app/main.swift:42.";
        var first = FileLinks.Bare(s)[0];
        Assert.Equal("/srv/app/main.swift:42", s.Substring(first.Start, first.Length));
    }
}

public class LinkPreviewParsingTests
{
    [Fact]
    public void Titles()
    {
        Assert.Equal("Example Domain", LinkPreviewParsing.TitleFromHtml("<html><head><title> Example \n Domain </title></head>"));
        Assert.Equal("Tom & Jerry — 😀 — caf&eacute;", LinkPreviewParsing.TitleFromHtml("<title>Tom &amp; Jerry &#8212; &#x1F600; &mdash; caf&eacute;</title>"));
        Assert.Equal("From OG", LinkPreviewParsing.TitleFromHtml("<title></title><meta property=\"og:title\" content=\"From OG\">"));
        Assert.Equal("From Twitter", LinkPreviewParsing.TitleFromHtml("<meta name='twitter:title' content='From Twitter'>"));
        Assert.Equal("", LinkPreviewParsing.TitleFromHtml("<title>Just a moment...</title>"));
        Assert.Equal("", LinkPreviewParsing.TitleFromHtml("<title>Sign in - Google Accounts</title>"));
        Assert.Equal("", LinkPreviewParsing.TitleFromHtml("<title>404 Error</title>"));
        Assert.Equal("", LinkPreviewParsing.TitleFromHtml("<title>Access Denied</title>"));
        Assert.Equal("", LinkPreviewParsing.TitleFromHtml(""));
        Assert.Equal(240, LinkPreviewParsing.TitleFromHtml("<title>" + new string('t', 500) + "</title>").Length);
        Assert.Equal("abcgnp.exe", LinkPreviewParsing.TitleFromHtml("<title>abc\u202Egnp.exe</title>"));
        Assert.Equal("", LinkPreviewParsing.TitleFromHtml(new string(' ', 256 * 1024) + "<title>Too late</title>"));
        Assert.True(LinkPreviewParsing.IsSignInArrival(new Uri("https://accounts.google.com/x")));
        Assert.True(LinkPreviewParsing.IsSignInArrival(new Uri("https://example.com/login")));
        Assert.False(LinkPreviewParsing.IsSignInArrival(new Uri("https://example.com/blog")));
    }

    [Fact]
    public void IconCandidatesAreRankedAndHttpsOnly()
    {
        var html = """
            <link rel="icon" href="/small.png" sizes="16x16">
            <link rel="icon" href="/big.png" sizes="192x192">
            <link rel="apple-touch-icon" href="touch.png">
            <link rel="mask-icon" href="/mask.svg">
            <link rel="icon" href="http://insecure.example/i.png">
            <link rel="stylesheet" href="/s.css">
            """;
        Assert.Equal(["https://example.com/mask.svg", "https://example.com/big.png", "https://example.com/a/touch.png",
            "https://example.com/apple-touch-icon.png", "https://example.com/favicon.ico"],
            LinkPreviewParsing.IconCandidates(html, "https://example.com/a/page"));
        Assert.Equal(["https://example.com/apple-touch-icon.png", "https://example.com/favicon.ico", "https://example.com/favicon.png"],
            LinkPreviewParsing.IconCandidates("", "https://example.com/x"));
    }

    [Fact]
    public void MagicBytesDecideWhatIsAPicture()
    {
        static byte[] Padded(params byte[] head) => [.. head, .. new byte[64]];
        Assert.Equal("image/png", LinkPreviewParsing.ImageMime(Padded(0x89, 0x50, 0x4E, 0x47)));
        Assert.Equal("image/jpeg", LinkPreviewParsing.ImageMime(Padded(0xFF, 0xD8, 0xFF)));
        Assert.Equal("image/gif", LinkPreviewParsing.ImageMime(Padded(0x47, 0x49, 0x46, 0x38)));
        Assert.Equal("image/x-icon", LinkPreviewParsing.ImageMime(Padded(0, 0, 1, 0)));
        Assert.Equal("image/webp", LinkPreviewParsing.ImageMime(Padded(0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50)));
        Assert.Equal("", LinkPreviewParsing.ImageMime(new byte[] { 0x89, 0x50, 0x4E, 0x47 }));
        Assert.Equal("", LinkPreviewParsing.ImageMime(Encoding.UTF8.GetBytes("<html><body>blocked</body></html>                         "), "image/png"));
        Assert.Equal("image/svg+xml", LinkPreviewParsing.ImageMime(Encoding.UTF8.GetBytes("<svg xmlns='http://www.w3.org/2000/svg'></svg>            ")));
    }

    [Fact]
    public void ABareLinkShowsWhereItGoes()
    {
        Assert.Equal("example.com/docs/guide…", LinkPreviewParsing.BareLinkLabel(null, "https://www.example.com/docs/guide/?a=1#top"));
        Assert.Equal("example.com", LinkPreviewParsing.BareLinkLabel(null, "https://example.com/"));
        Assert.Equal("example.com:8443/x", LinkPreviewParsing.BareLinkLabel(null, "https://example.com:8443/x"));
        Assert.Equal("Example Domain · example.com", LinkPreviewParsing.BareLinkLabel("Example Domain", "https://example.com/"));
        Assert.Equal("Docs | example.com", LinkPreviewParsing.BareLinkLabel("Docs | example.com", "https://www.example.com/x"));
        Assert.Equal("example.com/a", LinkPreviewParsing.BareLinkLabel(" ", "https://example.com/a"));
        Assert.Equal("example.com/install…", LinkPreviewParsing.BareLinkLabel(null, "https://www.example.com/install?x=1"));
        Assert.Equal("example.com", LinkPreviewParsing.DisplayHost(new Uri("https://www.example.com/x")));
    }

    [Fact]
    public void DecodesByTheDeclaredCharset()
    {
        Assert.Equal("café", LinkPreviewParsing.Decode([0x63, 0x61, 0x66, 0xE9], "text/html; charset=iso-8859-1"));
        Assert.Equal("café", LinkPreviewParsing.Decode(Encoding.UTF8.GetBytes("café"), "text/html"));
    }
}

public class TableDataTests
{
    private static IReadOnlyList<IReadOnlyList<string>> Rows(params string[][] rows) => rows;

    [Fact]
    public void NumbersAtTheStartOfACell()
    {
        Assert.Equal(20.7, TableData.Number("20.7%"));
        Assert.Equal(1234, TableData.Number("$1,234"));
        Assert.Equal(-3, TableData.Number("−3"));
        Assert.Equal(-5, TableData.Number("-$5"));
        Assert.Equal(1_200_000, TableData.Number("1.2M"));
        Assert.Equal(900_000, TableData.Number("900k"));
        Assert.Equal(14.3, TableData.Number("14.3% (9 booked)"));
        Assert.Equal(3, TableData.Number("3 Bedrooms"));
        Assert.Null(TableData.Number("Robin Vega"));
        Assert.Null(TableData.Number("Q3"));
        Assert.Null(TableData.Number(""));
    }

    [Fact]
    public void ACellThatIsOnlyANumber()
    {
        foreach (var yes in new[] { "20.7%", "$5", "1,234", "3x", "10 GB", "-2", ".5", "€12.50", "14.3% (9 booked)" }) Assert.True(TableData.IsNumber(yes), yes);
        foreach (var no in new[] { "14.3% (9 booked) or so", "2026-10-28", "5 seats", "v2", "Team", "" }) Assert.False(TableData.IsNumber(no), no);
    }

    [Fact]
    public void ColumnsOfNumbersReadRightAligned()
    {
        Assert.Equal([false, true, true, false], TableData.NumericColumns(Rows(["Starter", "$5", "1", "—"], ["Team", "$20", "", "n/a"], ["Studio", "$60", "40", "-"]), 4));
        Assert.Equal([true], TableData.NumericColumns(Rows(["14.3% (9 booked)"], ["12%"]), 1));
        Assert.Equal([false], TableData.NumericColumns(Rows(["14% of them"], ["12%"]), 1));
    }

    [Fact]
    public void SortingByNumbersAndWords()
    {
        var rows = Rows(["Adele", "17.4%"], ["Jules", "20.7%"], ["Dorian", ""], ["Abel", "9.2%"], ["Item 10", "—"], ["Item 2", "3%"]);
        Assert.Equal([5, 3, 0, 1, 2, 4], TableData.Order(rows, 1, true));
        Assert.Equal([1, 0, 3, 5, 2, 4], TableData.Order(rows, 1, false));
        Assert.Equal([3, 0, 2, 5, 4, 1], TableData.Order(rows, 0, true));
        Assert.Equal([0, 1, 2], TableData.Order(Rows(["b", "1"], ["a", "1"], ["c", "1"]), 1, true));
        Assert.Equal([0, 1, 2], TableData.Order(Rows(["b", "1"], ["a", "1"], ["c", "1"]), 1, false));
        Assert.Equal([2, 0, 1], TableData.Order(Rows(["Adele", "17.4%"], ["Jules", "20.7%"], ["Abel", "9.2%"]), 1, true));
    }

    [Fact]
    public void CsvQuotesWhatNeedsIt() =>
        Assert.Equal("Name,Note\n\"Tea, green\",\"said \"\"hi\"\"\"\nMilk fresh,a b",
            TableData.Csv([["Name", "Note"], ["Tea, green", "said \"hi\""], ["Milk\tfresh", "a\nb"]]));

    [Fact]
    public void MarkdownBackWithItsAlignment() =>
        Assert.Equal("| Plan | Price |\n| --- | ---: |\n| Starter | $5 |\n| a\\|b |  |",
            TableData.Markdown(Rows(["Plan", "Price"], ["Starter", "$5"], ["a|b"]), [TableAlignment.Natural, TableAlignment.Right]));

    [Fact]
    public void TheCaptionAboveATable()
    {
        Assert.Equal("Rep by rep (minimum 40 orders)", TableData.Caption("Some words.\n\nRep by rep (minimum 40 orders):"));
        Assert.Null(TableData.Caption("Here are the plans."));
        Assert.Equal("Results", TableData.Caption("Results", lastLineIsHeading: true));
        Assert.Equal("Weak at follow-up", TableData.Caption("• Weak at follow-up:"));
        Assert.Null(TableData.Caption(string.Concat(Enumerable.Repeat("word ", 30)) + ":"));
        Assert.Equal("Sales by region", TableData.Caption("3.\tSales by region:"));
        Assert.Equal("Costs", TableData.Caption("12) Costs:"));
        Assert.Equal("Nested", TableData.Caption("▪\uFE0E\tNested:"));
    }

    [Fact]
    public void ColumnsFitTheScreen()
    {
        Assert.Equal([100, 300], TableData.Fit([50, 150], [20, 20], 400));
        var shrunk = TableData.Fit([200, 100, 300], [50, 100, 100], 400);
        Assert.Equal(400, shrunk.Sum());
        Assert.Equal(100, shrunk[1]);
        Assert.True(shrunk[0] >= 50 && shrunk[2] >= 100);
        Assert.Equal([150, 200], TableData.Fit([200, 300], [150, 200], 300));
    }

    [Fact]
    public void SqueezingShortCellsIsWorseThanScrolling()
    {
        IReadOnlyList<IReadOnlyList<double>> names = [[120, 50], [110, 48], [130, 52], [100, 50]];
        Assert.True(TableData.SqueezeBreaksShortCells(names, [130, 52], [90, 52]));
        Assert.False(TableData.SqueezeBreaksShortCells(names, [130, 52], [125, 52]));
        Assert.False(TableData.SqueezeBreaksShortCells([[600, 0], [500, 0]], [280, 40], [200, 40]));
    }

    [Fact]
    public void TableTextIsTabSeparated()
    {
        Assert.Equal("Name\tQty\nTab here\tline break\na|b\t🙂", TableText.Text([["Name", "Qty"], ["Tab\there", " line\nbreak "], ["a|b", "🙂"]]));
        Assert.Null(TableText.Copyable([]));
        Assert.Null(TableText.Copyable([[""]]));
        Assert.Null(TableText.Copyable([[" ", ""]]));
        Assert.Equal("Couldn’t copy. Select the table text and try again.", TableText.Failure);
    }
}

public class MathTextTests
{
    private static List<string> Sources(string text) => [.. MathText.Spans(text).Select(s => s.Source)];

    [Fact]
    public void WhatCountsAsAFormula()
    {
        Assert.Equal(["E = mc^2"], Sources("Energy is $E = mc^2$ here."));
        Assert.Empty(Sources("It costs $5 and $10 today."));
        Assert.Empty(Sources("Pay $5 = five dollars and $3"));
        Assert.Equal(["\\frac{a}{b}"], Sources("Block: $$\\frac{a}{b}$$ done"));
        Assert.True(MathText.Spans("$$x$$")[0].Block);
        Assert.Equal(["a_1", "b^2"], Sources("Inline \\(a_1\\) and \\[b^2\\]"));
        Assert.True(MathText.Spans("\\[b^2\\]")[0].Block);
        Assert.Empty(Sources("unclosed $x = 1"));
        Assert.Empty(Sources("unclosed $$x = 1"));
        Assert.Empty(Sources("escaped \\$x = 1\\$"));
        Assert.Empty(Sources("$ x = 1$"));
        Assert.Empty(Sources("$x = 1 $"));
        Assert.Empty(Sources("$plain words$"));
        Assert.Equal(["a^2", "b_1"], Sources("two $a^2$ and $b_1$"));
        Assert.Empty(Sources("Copper Kettle: ~5 min, ~$$, OpenTable. Bayside Grill: ~6 min, $$-$$$, online up to 4"));
        Assert.Empty(Sources("Cheap ($) to fancy ($$$)."));
        Assert.Equal(["-\\frac{1}{2}"], Sources("Then $$-\\frac{1}{2}$$ holds"));
        var bare = MathText.Spans("Steps:\n\\begin{align} a &= b \\end{align}\ndone");
        Assert.Equal("\\begin{align} a &= b \\end{align}", bare.Single().Source);
        Assert.True(bare[0].Block);
    }

    // The grammar is checked on a step clock, one tick per read, with a generous but finite budget, so a busy machine
    // (a parallel run, a GC, a cold JIT) can never turn supported math into null. Each call gets its own clock.
    private const long Generous = 1_000_000;

    private static Func<long> StepClock(Action? onRead = null)
    {
        long now = 0;
        return () => { onRead?.Invoke(); return now++; };
    }

    private static string? Read(string source, bool block = false) => MathText.Readable(source, block, StepClock(), Generous);

    /// How many times the parser reads its clock for `source` after the start: the budget it needs, exactly.
    private static long ReadsNeeded(string source, bool block = false)
    {
        long reads = 0;
        Assert.NotNull(MathText.Readable(source, block, StepClock(() => reads++), Generous));
        return reads - 1;
    }

    [Fact]
    public void TheSubsetReadsAsText()
    {
        Assert.Equal("E = mc²", Read("E = mc^2"));
        Assert.Equal("a⁄b", Read("\\frac{a}{b}"));
        Assert.Equal("(a+b)/c", Read("\\frac{a+b}{c}"));
        Assert.Equal("n(n+1)/2", Read("\\frac{n(n+1)}{2}"));
        Assert.Equal("√(x)", Read("\\sqrt{x}"));
        Assert.Equal("α × β ≤ ∞", Read("\\alpha \\times \\beta \\leq \\infty"));
        Assert.Equal("x₁ + x₁₂ → yⁿ⁺¹", Read("x_1 + x_{12} \\to y^{n+1}"));
        Assert.Equal("a^(xy)", Read("a^{xy}"));
        var limits = $"( ∑{MathText.LimitBelowOpen}i=1{MathText.LimitClose}{MathText.LimitAboveOpen}n{MathText.LimitClose} i )";
        Assert.Equal(limits, Read("\\left( \\sum_{i=1}^{n} i \\right)"));
        Assert.Equal("speed of light = c", Read("\\text{speed of light} = c"));
        Assert.Equal("a\nb", Read("a \\\\ b", block: true));
        Assert.Equal("a − b", Read("a - b"));
    }

    [Fact]
    public void AnythingOutsideTheSubsetFallsBackToSource()
    {
        Assert.Null(Read("\\begin{aligned} a &= b \\end{aligned}"));
        Assert.Null(Read("\\frac{a}"));
        Assert.Null(Read("\\frac{a}{b"));
        Assert.Null(Read("\\unknowncommand x"));
        Assert.Null(Read("a }"));
        Assert.Null(Read(new string('x', 10_000)));
        Assert.Null(Read(""));
    }

    [Fact]
    public void RunningOutOfTimeShowsTheWholeSourceAtAnExactPoint()
    {
        const string source = "\\left( \\sum_{i=1}^{n} i \\right)";
        var limits = $"( ∑{MathText.LimitBelowOpen}i=1{MathText.LimitClose}{MathText.LimitAboveOpen}n{MathText.LimitClose} i )";
        var needed = ReadsNeeded(source);
        Assert.True(needed > 10, $"the parser checks its clock as it goes ({needed} reads)");
        // A thread stalled longer than the real 25 ms budget mid-formula (what failed under a loaded parallel run)
        // no longer decides the grammar's answer: only the clock's reads count.
        var stalled = false;
        Assert.Equal(limits, MathText.Readable(source, false, StepClock(() =>
        {
            if (stalled) return;
            stalled = true;
            Thread.Sleep(40);
        }), needed));
        // Exactly enough time: the exact text. Any less, at any point in the formula: null, never a half-converted
        // prefix, so the caller shows the whole source.
        Assert.Equal(limits, MathText.Readable(source, false, StepClock(), needed));
        for (var budget = 1L; budget < needed; budget++)
            Assert.Null(MathText.Readable(source, false, StepClock(), budget));
        // The formula taken out of the reply keeps its whole source for that fallback.
        var taken = MathText.Extract($"Total $${source}$$ done").Formulas.Single();
        Assert.Equal(source, taken.Source);
        // A clock that jumps past the budget mid-formula ends it the same way.
        long now = 0;
        Assert.Null(MathText.Readable(source, false, () => now++ < 5 ? now : now + 1_000, 100));
    }

    [Fact]
    public void TheBudgetCannotBeTurnedOffAndTheProductionLimitsStay()
    {
        // 25 ms of Stopwatch ticks, as before; the public Readable uses it with the real clock.
        Assert.Equal(System.Diagnostics.Stopwatch.Frequency / 40, MathText.ReadableBudget);
        Assert.Throws<ArgumentOutOfRangeException>(() => MathText.Readable("x", false, StepClock(), 0));
        Assert.Throws<ArgumentOutOfRangeException>(() => MathText.Readable("x", false, StepClock(), -1));
        Assert.Throws<ArgumentNullException>(() => MathText.Readable("x", false, null!, 1));
        // A deadline that would overflow counts as spent, never as no limit.
        Assert.Null(MathText.Readable("x", false, () => long.MaxValue - 1, 10));
        // At most 2,000 characters, however much time there is.
        Assert.Equal(new string('x', MathText.MaxLength), Read(new string('x', MathText.MaxLength)));
        Assert.Null(Read(new string('x', MathText.MaxLength + 1)));
        // At most 24 nested groups.
        Assert.Equal("x", Read(new string('{', 24) + "x" + new string('}', 24)));
        Assert.Null(Read(new string('{', 25) + "x" + new string('}', 25)));
    }

    [Fact]
    public void TwoCallsAtOnceKeepTheirOwnClocks()
    {
        const string source = "x_1 + x_{12} \\to y^{n+1}";
        var needed = ReadsNeeded(source);
        var results = new string?[64];
        Parallel.For(0, results.Length, i =>
            results[i] = MathText.Readable(source, false, StepClock(), i % 2 == 0 ? needed : needed - 1));
        for (var i = 0; i < results.Length; i++)
            Assert.Equal(i % 2 == 0 ? "x₁ + x₁₂ → yⁿ⁺¹" : null, results[i]);
    }

    [Fact]
    public void FormulasAreTakenOutAndPutBack()
    {
        var text = "Energy $E = mc^2$ and `$x^2$` in code:\n\n$$a^2$$\n\n```\n$y_1$\n```";
        var extracted = MathText.Extract(text);
        Assert.Equal(2, extracted.Formulas.Count);
        Assert.False(extracted.Formulas[0].OwnParagraph);
        Assert.True(extracted.Formulas[1].OwnParagraph);
        Assert.Contains("`$x^2$`", extracted.Text);
        Assert.Contains("```\n$y_1$\n```", extracted.Text);
        Assert.Equal(text.Replace("$$a^2$$", "\n\n$$a^2$$\n\n"), MathText.Restore(extracted.Text, extracted.Formulas));
        Assert.Equal(1, MathText.BlockToken($"{MathText.BlockOpen}1{MathText.Close}"));
        Assert.Equal([new MathPiece("Energy ", null), new MathPiece(null, 0), new MathPiece(" ok", null)],
            MathText.Pieces($"Energy {MathText.InlineOpen}0{MathText.Close} ok"));
        Assert.Equal("Energy Formula: E = mc^2 here", MathText.Spoken("Energy $E = mc^2$ here"));
    }
}
