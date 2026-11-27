// [WIN-DELIVERY-WALK] The chat-delivery walk's pure checks (Hermes.Core/Shell/DeliveryWalkProof.cs): each passes on the
// state or record it is for and says what is wrong otherwise. The words are the Mac's (93f984bb1 App/Chat/ChatRow.swift
// and Cells/ChatCells.swift "Delivery Unconfirmed · Check" `chat.delivery-check`; ChatViewController.swift
// `chatCellCheckDelivery`'s notice; HermesKit/Chat/LiveChatSession.swift `OwnerWait`; Transcript/TurnErrorCopy.swift
// `chatLocked`; ExternalTurn's "Working…"), written out here so a drift on either side fails. Also pins where the walk
// is wired (registration, shots, no OS input, the stand-in's plans with error data and its working ledger).
// DeliveryWireEndToEndTests runs the same checks over the wire.

using System.Text.Json.Nodes;
using Hermes.Core.Chat;
using Hermes.Core.Model;
using Hermes.Core.Transcripts;
using Proof = Hermes.Core.Shell.DeliveryWalkProof;

namespace Hermes.Core.Tests;

public sealed class DeliveryWalkProofTests
{
    private static ChatMessage Bubble(Role role, string text, string? error = null, bool pending = false, bool streaming = false) =>
        new($"m-{Guid.NewGuid():N}", role, [new TextPart(text)], IsPending: pending, IsStreaming: streaming, Error: error);

    private static JsonObject Entry(string text, bool accepted, JsonObject? plan = null) => new()
    {
        ["profile"] = "default", ["method"] = "prompt.submit", ["text"] = text, ["accepted"] = accepted, ["plan"] = plan ?? new JsonObject(),
    };

    private static JsonObject State(params JsonObject[] entries) => new() { ["ledger"] = new JsonArray([.. entries.Select(e => e.DeepClone())]) };

    private static JsonObject Refusal(string reason, int code = 4090, string message = "refused") =>
        new() { ["reject"] = message, ["code"] = code, ["data"] = new JsonObject { ["reason"] = reason } };

    [Fact]
    public void TheWordsAreTheMacsAndWindowsSaysThem()
    {
        Assert.Equal("Delivery Unconfirmed · Check", Proof.CheckLine);
        Assert.Equal("chat.delivery-check", Proof.CheckId);
        Assert.Equal("The computer running Hermes doesn\u2019t have this message yet.", Proof.NotThere);
        Assert.Equal("Your message is waiting", Proof.OwnerWaitTitle);
        Assert.Equal("Hermes is running a scheduled job or a message from another bot in this chat. Yours sends as soon as it\u2019s done. You can keep typing.",
            Proof.OwnerWaitBody);
        Assert.Equal("Cancel Message", Proof.OwnerWaitCancel);
        Assert.Equal("Waiting for a background task\u2026", Proof.OwnerWaitStatus);
        Assert.Equal("This chat can\u2019t take messages", Proof.LockedTitle);
        Assert.Equal("Hermes won\u2019t open this chat any more, so messages sent here can\u2019t reach it. Your message is still in the box below. Continue in a new chat with the same bot.",
            Proof.LockedBody);
        Assert.Equal("Working\u2026", Proof.Working);

        // Windows' own constants say the same.
        Assert.Equal(Proof.CheckLine, ChatSession.CheckDeliveryWords);
        Assert.Equal(Proof.CheckId, ChatSession.CheckDeliveryId);
        Assert.Equal(Proof.NotThere, ChatSession.NotThereYetNotice);
        Assert.Equal(Proof.OwnerWaitTitle, OwnerWait.CardTitle);
        Assert.Equal(Proof.OwnerWaitBody, OwnerWait.BackgroundTask.CardBody);
        Assert.Equal(Proof.OwnerWaitCancel, OwnerWait.CancelTitle);
        Assert.Equal(Proof.OwnerWaitStatus, OwnerWait.BackgroundTask.Status);
        Assert.Equal(Proof.LockedTitle, SessionProblem.ChatLocked("x").Title);
        Assert.Equal(Proof.LockedBody, SessionProblem.ChatLocked("x").Body);
        Assert.Equal(Proof.Working, ExternalTurn.StatusWords);
    }

    [Fact]
    public void TheLockedCardsButtonsAreContinueInNewChatThenCopy()
    {
        // [WIN-CHAT-LOCKED-ACTIONS] ChatNoticeCard.Content.title(.newChat), the action before Copy; the Mac's identifiers.
        Assert.Equal("Continue in New Chat", Proof.LockedAction);
        Assert.Equal("chat.problem", Proof.LockedId);
        Assert.Equal("chat.ownerWait", Proof.OwnerWaitId);
        Assert.Null(Proof.LockedButtons(["Continue in New Chat", "Copy"]));
        Assert.Contains("Copy only", Proof.LockedButtons(["Copy"]));
        Assert.Contains("order", Proof.LockedButtons(["Copy", "Continue in New Chat"]));
        Assert.Contains("\"New Chat\"", Proof.LockedButtons(["New Chat", "Copy"]));
    }

    [Fact]
    public void TheShotsAreNamedAndTheWalkHasItsOwn()
    {
        Assert.Equal("chat-delivery", Proof.Walk);
        Assert.Equal("delivery", Proof.Tag);
        Assert.Equal(["delivery-unconfirmed", "delivery-check-notice", "owner-wait", "chat-locked", "external-working"], Proof.Shots);
        Assert.Equal(Proof.Walk, Proof.FinalShot);
    }

    [Fact]
    public void ThePlansRefuseWithTheReasonInTheErrorsData()
    {
        var unconfirmed = JsonNode.Parse(Proof.UnconfirmedPlan())!["plans"]!.AsArray();
        Assert.Single(unconfirmed);
        Assert.Equal(4090, (int)unconfirmed[0]!["code"]!);
        Assert.Equal("SESSION_OWNER_UNCONFIRMED", (string)unconfirmed[0]!["data"]!["reason"]!);

        var owner = JsonNode.Parse(Proof.OwnerWaitPlan())!["plans"]!.AsArray();
        Assert.Equal(Proof.OwnerRefusals + 1, owner.Count);
        Assert.True(Proof.OwnerRefusals >= 3);
        foreach (var refusal in owner.Take(Proof.OwnerRefusals))
        {
            Assert.Equal(4090, (int)refusal!["code"]!);
            Assert.Equal("SESSION_NOT_OWNED", (string)refusal["data"]!["reason"]!);
            // A one-shot run holds it: the long wait (the background task's card), not the 30 s one.
            Assert.Equal(OwnerWaitKind.BackgroundTask, ChatSession.OwnerWaitOf(new Hermes.Core.Net.GatewayException("rpc", (string)refusal["reject"]!)).Kind);
        }
        Assert.Null(owner[^1]!["reject"]);

        var locked = JsonNode.Parse(Proof.LockedPlan())!["plans"]!.AsArray();
        Assert.Single(locked);
        Assert.Equal(4001, (int)locked[0]!["code"]!);
        Assert.Equal("profile_mismatch", (string)locked[0]!["data"]!["reason"]!);

        Assert.Equal("""{"profile":"sam","text":"Synthetic prompt another app sent"}""", Proof.ExternalBody());
        Assert.Equal("""{"sessions":[{"profile":"sam","id":"s-1","status":"running","kind":"gateway"}]}""", Proof.WorkingBody("s-1"));
        Assert.Equal("""{"sessions":[]}""", Proof.IdleBody());
    }

    [Fact]
    public void TheBubblesAreCheckedForTheirMarks()
    {
        var hello = Bubble(Role.Assistant, "Build 47 synthetic acceptance chat.");
        Assert.Null(Proof.Unconfirmed([hello, Bubble(Role.User, Proof.UnconfirmedText, error: "Delivery unconfirmed")]));
        Assert.Equal("unconfirmed: no bubble of yours says the note", Proof.Unconfirmed([hello]));
        Assert.Equal("unconfirmed: the bubble isn't marked", Proof.Unconfirmed([Bubble(Role.User, Proof.UnconfirmedText)]));
        Assert.Equal("unconfirmed: the bubble is still sending", Proof.Unconfirmed([Bubble(Role.User, Proof.UnconfirmedText, error: "x", pending: true)]));

        Assert.Null(Proof.CheckButton(Proof.CheckId, Proof.CheckLine));
        Assert.Contains("Checking", Proof.CheckButton(Proof.CheckId, "Checking Delivery\u2026"));
        Assert.Contains("automation id", Proof.CheckButton("chat.other", Proof.CheckLine));

        Assert.Null(Proof.Notice(Proof.NotThere));
        Assert.Contains("Couldn", Proof.Notice("Couldn\u2019t check right now. Try again in a moment."));
        Assert.Contains("no notice", Proof.Notice(null));

        Assert.Null(Proof.OwnerWaitCard(Proof.OwnerWaitTitle, Proof.OwnerWaitBody, Proof.OwnerWaitCancel));
        Assert.Contains("title", Proof.OwnerWaitCard("Waiting", Proof.OwnerWaitBody, Proof.OwnerWaitCancel));
        Assert.Contains("body", Proof.OwnerWaitCard(Proof.OwnerWaitTitle, OwnerWait.OtherWindow.CardBody, Proof.OwnerWaitCancel));
        Assert.Contains("Cancel Message", Proof.OwnerWaitCard(Proof.OwnerWaitTitle, Proof.OwnerWaitBody, null));

        var sent = Bubble(Role.User, Proof.OwnerText);
        Assert.Null(Proof.OwnerSent([hello, sent, Bubble(Role.Assistant, Proof.OwnerReply)]));
        Assert.Contains("reply", Proof.OwnerSent([hello, sent]));
        Assert.Contains("reply", Proof.OwnerSent([hello, sent, Bubble(Role.Assistant, "Synth", streaming: true)]));
        Assert.Contains("marked", Proof.OwnerSent([Bubble(Role.User, Proof.OwnerText, error: "x"), Bubble(Role.Assistant, Proof.OwnerReply)]));
        Assert.Contains("no bubble", Proof.OwnerSent([hello]));

        Assert.Null(Proof.LockedCard(Proof.LockedTitle, Proof.LockedBody, Proof.LockedText));
        Assert.Contains("title", Proof.LockedCard("Couldn\u2019t Send", Proof.LockedBody, Proof.LockedText));
        Assert.Contains("box", Proof.LockedCard(Proof.LockedTitle, Proof.LockedBody, ""));

        Assert.Null(Proof.Header(Proof.Working));
        Assert.Contains("Replying", Proof.Header("Replying\u2026"));
        Assert.Contains("nothing", Proof.Header(""));
    }

    [Fact]
    public void TheWireShowsEachSendAsTheMacMakesIt()
    {
        var earlier = Entry("Run three steps", true);
        Assert.Equal(1, Proof.Mark(State(earlier)));
        Assert.Equal(0, Proof.Mark(new JsonObject()));

        // Unconfirmed: one try, refused, never sent again (the Check reads, it doesn't resend).
        var unconfirmed = Entry(Proof.UnconfirmedText, false, Refusal("SESSION_OWNER_UNCONFIRMED"));
        Assert.Null(Proof.UnconfirmedWire(State(earlier, unconfirmed), 1));
        Assert.Contains("resent", Proof.UnconfirmedWire(State(earlier, unconfirmed, unconfirmed), 1));
        Assert.Contains("never", Proof.UnconfirmedWire(State(earlier), 1));
        Assert.Contains("SESSION_OWNER_UNCONFIRMED", Proof.UnconfirmedWire(State(earlier, Entry(Proof.UnconfirmedText, false, Refusal("SESSION_NOT_OWNED"))), 1));

        // The owner wait: the refusals, then one accepted try.
        var refused = Entry(Proof.OwnerText, false, Refusal("SESSION_NOT_OWNED"));
        var accepted = Entry(Proof.OwnerText, true);
        var tries = Enumerable.Repeat(refused, Proof.OwnerRefusals).Select(e => (JsonObject)e.DeepClone()).ToList();
        Assert.Null(Proof.OwnerWire(State([earlier, .. tries, accepted]), 1));
        Assert.Contains("refused", Proof.OwnerWire(State([earlier, .. tries.Skip(1), accepted]), 1));
        Assert.Contains("accepted", Proof.OwnerWire(State([earlier, .. tries]), 1));
        Assert.Contains("twice", Proof.OwnerWire(State([earlier, .. tries, accepted, (JsonObject)accepted.DeepClone()]), 1));

        // Locked: one try, no resume-and-resend.
        var locked = Entry(Proof.LockedText, false, Refusal("profile_mismatch", 4001, "profile_mismatch"));
        Assert.Null(Proof.LockedWire(State(earlier, locked), 1));
        Assert.Contains("tries", Proof.LockedWire(State(earlier, locked, (JsonObject)locked.DeepClone()), 1));
        Assert.Contains("never", Proof.LockedWire(State(earlier), 1));
    }

    private static string Read(params string[] parts)
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir != null && !Directory.Exists(Path.Combine(dir.FullName, "src", "HermesHQ.Windows"))) dir = dir.Parent;
        Assert.NotNull(dir);
        return File.ReadAllText(Path.Combine([dir!.FullName, .. parts])).ReplaceLineEndings("\n");
    }

    [Fact]
    public void TheWalkIsWiredAndPressesThroughAutomationPeersOnly()
    {
        Assert.Contains("RegisterDeliveryWalks();", Read("src", "HermesHQ.Windows", "Services", "ProofWalks.cs"));
        var walk = Read("src", "HermesHQ.Windows", "Services", "ProofWalks.Delivery.cs");
        Assert.Contains($"Automation.NamedWalks[\"{Proof.Walk}\"]", walk);
        foreach (var shot in Proof.Shots.Append(Proof.FinalShot))
            Assert.Contains($"await shot(\"{shot}\")", walk);
        // No OS input: the walk's buttons are invoked through their peers, the words set in the box.
        Assert.DoesNotContain("Mouse.Click", walk);
        Assert.DoesNotContain("Keys.", walk);
        Assert.Contains("Invoke(", walk);
        // Every card is asserted before its shot.
        Assert.True(walk.IndexOf("DeliveryWalkProof.OwnerWaitCard(", StringComparison.Ordinal) < walk.IndexOf("await shot(\"owner-wait\")", StringComparison.Ordinal));
        Assert.True(walk.IndexOf("DeliveryWalkProof.LockedCard(", StringComparison.Ordinal) < walk.IndexOf("await shot(\"chat-locked\")", StringComparison.Ordinal));
        Assert.True(walk.IndexOf("DeliveryWalkProof.LockedButtons(", StringComparison.Ordinal) is > 0 and var buttons
            && buttons < walk.IndexOf("await shot(\"chat-locked\")", StringComparison.Ordinal));
        // The cards are found by the Mac's identifiers, never Windows' old ones.
        Assert.DoesNotContain("chat.owner-wait", walk);
        Assert.DoesNotContain("chat.session-problem", walk);
        Assert.True(walk.IndexOf("DeliveryWalkProof.Header(", StringComparison.Ordinal) < walk.IndexOf("await shot(\"external-working\")", StringComparison.Ordinal));
        Assert.True(walk.IndexOf("DeliveryWalkProof.Notice(", StringComparison.Ordinal) < walk.IndexOf("await shot(\"delivery-check-notice\")", StringComparison.Ordinal));
        Assert.True(walk.IndexOf("DeliveryWalkProof.CheckButton(", StringComparison.Ordinal) < walk.IndexOf("await shot(\"delivery-unconfirmed\")", StringComparison.Ordinal));

        var yml = Read("ci", "windows.yml");
        var line = yml.Split('\n').Single(l => l.Contains("tag = \"delivery\""));
        Assert.Contains("windows/ci/fixtures/performance-fixture-gateway.py", line);
        Assert.Contains($"walks = @(\"{Proof.Walk}\")", line);
        Assert.Contains("shots = @(" + string.Join(",", Proof.Shots.Select(s => $"\"{s}\"")) + ")", line);

        var fixture = Read("ci", "fixtures", "build47-fixture-gateway.py");
        Assert.Contains("'data'", fixture);
        Assert.Contains(ExternalTurn.LedgerPath, fixture);
        Assert.Contains(Proof.WorkingPath, fixture);
        Assert.Contains(Proof.ExternalPath, fixture);
        Assert.Contains("HQW_E2E_DELIVERY_CREDENTIALS", Read("scripts", "e2e.sh"));
    }
}
