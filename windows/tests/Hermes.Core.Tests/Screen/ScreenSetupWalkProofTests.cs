// [WIN-SCREEN-SETUP-SEND-WALK] The bot-screen-setup-send walk's pure checks (Hermes.Core/Shell/ScreenSetupWalkProof.cs):
// each passes on the state or record it is for and says what is wrong otherwise. The wire check holds the stand-in's
// record to the Mac's frames (93f984bb1 LiveChatSession+ScreenSetup.swift, AppModel+Screen.swift): one file.attach
// {data_url, name, profile, session_id} with the reviewed installer's size and SHA-256, then one prompt.submit to the
// same runtime with the exact prompt and its three installer lines. Also pins where the walk is wired (registration,
// shots, no OS input, the stand-in's roster and recording). ScreenSetupWireEndToEndTests runs the checks over the wire.

using System.Text.Json.Nodes;
using Hermes.Core.Model;
using Hermes.Core.Screen;
using Hermes.Core.Shell;
using Proof = Hermes.Core.Shell.ScreenSetupWalkProof;

namespace Hermes.Core.Tests.Screen;

public sealed class ScreenSetupWalkProofTests
{
    private static JsonObject Attach(Action<JsonObject>? change = null)
    {
        var a = new JsonObject
        {
            ["method"] = "file.attach", ["keys"] = new JsonArray("data_url", "name", "profile", "session_id"), ["owner"] = "otto",
            ["session_id"] = "rt-otto", ["profile"] = "otto", ["name"] = "hermes-hq-screen-setup.zip",
            ["data_url_prefix"] = "data:application/zip;base64,", ["data_bytes"] = 550_200,
            ["data_sha256"] = ScreenSetupBundle.ExpectedSha256, ["ref_text"] = Proof.RefText,
        };
        change?.Invoke(a);
        return a;
    }

    private static JsonObject Submit(Action<JsonObject>? change = null)
    {
        var s = new JsonObject
        {
            ["method"] = "prompt.submit", ["keys"] = new JsonArray("profile", "session_id", "text"), ["owner"] = "otto",
            ["session_id"] = "rt-otto", ["profile"] = "otto", ["text"] = Proof.Message, ["queued"] = false,
        };
        change?.Invoke(s);
        return s;
    }

    /// As the stand-in's GET answers it (parsed JSON).
    private static JsonNode Record(params JsonObject[] chat) =>
        JsonNode.Parse(new JsonObject { ["chat"] = new JsonArray([.. chat.Select(c => c.DeepClone())]), ["inputs"] = new JsonArray() }.ToJsonString())!;

    [Fact]
    public void TheMacsFramesInOrderPass()
    {
        Assert.Null(Proof.Sent(Record(Attach(), Submit()), 0));
        // A mark skips what came before (an earlier walk's frames).
        var earlier = Submit(s => s["text"] = "hello");
        Assert.Null(Proof.Sent(Record(earlier, Attach(), Submit()), 1));
        Assert.Equal(1, Proof.Chat(Record(earlier)));
        Assert.Equal(0, Proof.Chat(null));
        // The Mac's submission_id is allowed (Windows doesn't send it yet).
        Assert.Null(Proof.Sent(Record(Attach(), Submit(s => s["keys"] = new JsonArray("profile", "session_id", "submission_id", "text"))), 0));
    }

    [Fact]
    public void TheMessageIsTheReviewedPromptWithTheStandInsRefText()
    {
        Assert.StartsWith(ScreenSetupPrompt.Text, Proof.Message, StringComparison.Ordinal);
        Assert.EndsWith("\n\nInstaller source: @file:/fixture/uploads/hermes-hq-screen-setup.zip\nSHA-256: 71ff241d0a3e803b8a457a9df5f91c14df48c1f227893d785974837af0c8de09\nSigned helper inside the bundle: hermes-hq-screen-setup/Hermes HQ Screen.app",
            Proof.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void EachWrongFrameIsSaid()
    {
        Assert.Equal("attach: no file.attach reached the stand-in", Proof.Sent(Record(), 0));
        Assert.Equal("prompt: no prompt.submit reached the stand-in", Proof.Sent(Record(Attach()), 0));
        Assert.Equal("attach: no file.attach reached the stand-in", Proof.Sent(Record(Attach(), Submit()), 1));
        Assert.Equal("attach: 2 file.attach frames, not one", Proof.Sent(Record(Attach(), Attach(), Submit()), 0));
        Assert.Equal("prompt: 2 prompt.submit frames, not one", Proof.Sent(Record(Attach(), Submit(), Submit()), 0));
        Assert.Equal("order: the prompt went out before the installer was attached", Proof.Sent(Record(Submit(), Attach()), 0));

        Assert.StartsWith("attach: sent data_url, name, path", Proof.Sent(Record(Attach(a => a["keys"] = new JsonArray("data_url", "name", "path", "profile", "session_id")), Submit()), 0));
        Assert.StartsWith("attach: sent data_url, name, session_id", Proof.Sent(Record(Attach(a => a["keys"] = new JsonArray("data_url", "name", "session_id")), Submit()), 0));
        Assert.Equal("attach: profile sam", Proof.Sent(Record(Attach(a => a["profile"] = "sam"), Submit()), 0));
        Assert.Equal("attach: the session id rt-otto is default's chat, not otto's", Proof.Sent(Record(Attach(a => a["owner"] = "default"), Submit()), 0));
        Assert.Equal("attach: named setup.zip", Proof.Sent(Record(Attach(a => a["name"] = "setup.zip"), Submit()), 0));
        Assert.Equal("attach: the data URL isn't a base64 zip", Proof.Sent(Record(Attach(a => a["data_url_prefix"] = ""), Submit()), 0));
        Assert.Equal("attach: 4 bytes, not 550200", Proof.Sent(Record(Attach(a => a["data_bytes"] = 4), Submit()), 0));
        Assert.StartsWith("attach: SHA-256 00", Proof.Sent(Record(Attach(a => a["data_sha256"] = "00"), Submit()), 0));

        Assert.Equal("prompt: no profile", Proof.Sent(Record(Attach(), Submit(s => s["keys"] = new JsonArray("session_id", "text"))), 0));
        Assert.StartsWith("prompt: also sent queued", Proof.Sent(Record(Attach(), Submit(s => s["keys"] = new JsonArray("profile", "queued", "session_id", "text"))), 0));
        Assert.Equal("prompt: sent as queued", Proof.Sent(Record(Attach(), Submit(s => s["queued"] = true)), 0));
        Assert.Equal("prompt: sent to sam as otto, not otto", Proof.Sent(Record(Attach(), Submit(s => s["owner"] = "sam")), 0));
        Assert.Equal("prompt: sent to another runtime than the installer was attached to", Proof.Sent(Record(Attach(), Submit(s => s["session_id"] = "rt-2")), 0));
        Assert.Equal("prompt: the words aren't the reviewed prompt", Proof.Sent(Record(Attach(), Submit(s => s["text"] = ScreenSetupPrompt.QueueTitle)), 0));
        var otherRef = ScreenSetupPrompt.Message("@file:/elsewhere.zip", ScreenSetupBundle.ExpectedSha256, ScreenSetupBundle.HelperAppPath);
        Assert.StartsWith("prompt: the installer lines are \"Installer source: @file:/elsewhere.zip", Proof.Sent(Record(Attach(), Submit(s => s["text"] = otherRef)), 0));
    }

    [Fact]
    public void TheRosterNamesOttoAndGivesItAChat()
    {
        JsonNode Profiles(string name, string? display, string? session) => JsonNode.Parse(new JsonObject
        {
            ["profiles"] = new JsonArray(
                new JsonObject { ["name"] = "default", ["canonical_session"] = new JsonObject { ["id"] = "s-default" } },
                new JsonObject
                {
                    ["name"] = name, ["ui_meta"] = new JsonObject { ["hermes-bots"] = new JsonObject { ["display_name"] = display } },
                    ["canonical_session"] = session == null ? null : new JsonObject { ["id"] = session },
                }),
        }.ToJsonString())!;
        Assert.Null(Proof.Roster(Profiles("otto", "Otto", "s-otto")));
        Assert.Equal("s-otto", Proof.StoredSession(Profiles("otto", "Otto", "s-otto")));
        Assert.Equal("roster: no otto in profiles.list", Proof.Roster(Profiles("sam", "Sam", "s-sam")));
        Assert.Equal("roster: otto isn't named Otto", Proof.Roster(Profiles("otto", "Sam", "s-otto")));
        Assert.Equal("roster: otto has no chat of its own", Proof.Roster(Profiles("otto", "Otto", null)));
        Assert.Equal("roster: no otto in profiles.list", Proof.Roster(null));
    }

    [Fact]
    public void TheCardBeforeThePressOffersSetUpWithHermes()
    {
        var card = new ScreenSetupCardState(controlOnly: false);
        Assert.Null(Proof.Card(card.Look));
        Assert.Equal("card: it is screen.setup.card.control, not the setup card", Proof.Card(new ScreenSetupCardState(controlOnly: true).Look));
        card.WindowsGateway = true;
        Assert.Equal("card: no buttons (a Windows gateway's sentence?)", Proof.Card(card.Look));
        card.WindowsGateway = false;
        card.ShowRequested();
        Assert.Equal("card: the button says \"Continue with Hermes\", not \"Set Up with Hermes\" (already requested this run?)", Proof.Card(card.Look));
    }

    [Fact]
    public void TheScreenClosesAndOttosBotChatIsThePanes()
    {
        Assert.Null(Proof.Closed(false, false));
        Assert.Equal("screen: the Screen's window is still open", Proof.Closed(true, false));
        Assert.Equal("screen: the viewer is still open", Proof.Closed(false, true));

        Assert.Null(Proof.ChatOpen(OpenPane.BotChat, "otto", "otto"));
        Assert.Equal("chat: the pane shows Chat, not a bot chat", Proof.ChatOpen(OpenPane.Chat, "otto", "otto"));
        Assert.Equal("chat: the pane shows Nothing, not a bot chat", Proof.ChatOpen(OpenPane.Nothing, null, null));
        Assert.Equal("chat: the pane is sam's chat (sam), not otto's", Proof.ChatOpen(OpenPane.BotChat, "sam", "sam"));
        Assert.Equal("chat: the pane is otto's chat (no session), not otto's", Proof.ChatOpen(OpenPane.BotChat, "otto", null));
    }

    private static ChatMessage Bubble(Role role, string text, bool streaming = false) =>
        new(Guid.NewGuid().ToString("n"), role, [new TextPart(text)], IsStreaming: streaming);

    [Fact]
    public void TheBubbleIsTheShortTitleAndTheReplyComesAfterIt()
    {
        var hello = Bubble(Role.Assistant, "Synthetic Otto chat for the screen setup walk.");
        var request = Bubble(Role.User, ScreenSetupPrompt.QueueTitle);
        Assert.Null(Proof.Bubble([hello, request]));
        Assert.Null(Proof.Bubble([Bubble(Role.User, Proof.Message), hello, request]));   // an earlier request read back
        Assert.Equal("bubble: no bubble of yours", Proof.Bubble([hello]));
        Assert.Equal("bubble: the prompt's own words show, not its short title", Proof.Bubble([request, Bubble(Role.User, Proof.Message)]));
        Assert.Equal("bubble: your newest bubble says \"hello\"", Proof.Bubble([request, Bubble(Role.User, "hello")]));

        Assert.False(Proof.Replied([hello, request]));
        Assert.False(Proof.Replied([request, Bubble(Role.Assistant, "Synth", streaming: true)]));
        Assert.True(Proof.Replied([hello, request, Bubble(Role.Assistant, "Synthetic reply for build 47.")]));
        // Read back from history after the reply: the stored row is the whole prompt (D26).
        Assert.True(Proof.Replied([hello, Bubble(Role.User, Proof.Message), Bubble(Role.Assistant, "Synthetic reply for build 47.")]));
        Assert.False(Proof.Replied([hello]));

        Assert.Equal("""{"plans":[{"replyDelay":2.5}]}""", Proof.PlanBody());
    }

    private static string Read(params string[] parts)
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir != null && !Directory.Exists(Path.Combine(dir.FullName, "src", "HermesHQ.Windows"))) dir = dir.Parent;
        Assert.NotNull(dir);
        return File.ReadAllText(Path.Combine([dir!.FullName, .. parts])).ReplaceLineEndings("\n");
    }

    [Fact]
    public void SetUpWithHermesMustBeInsideTheWindowAndThePageBeforeItIsPressed()
    {
        // [WIN-SCREEN-SETUP-LAYOUT] The Windows CI shot 207: a 1000 × 700 Screen window (984 × 661 of client), the empty
        // frame 595 tall, the button at about y 800, below the window.
        var client = new ScreenSize(984, 661);
        var page = new ScreenRect(0, 56, 984, 605);
        Assert.Null(Proof.InView(new ScreenRect(32, 540, 920, 48), client, page));
        Assert.Contains("below", Proof.InView(new ScreenRect(32, 800, 920, 48), client, page));
        Assert.Contains("below", Proof.InView(new ScreenRect(32, 640, 920, 48), client, page));   // its bottom past the page
        Assert.Contains("above", Proof.InView(new ScreenRect(32, 20, 920, 48), client, page));    // scrolled under the bar
        Assert.Contains("beside", Proof.InView(new ScreenRect(960, 300, 920, 48), client, page));
        Assert.Contains("no size", Proof.InView(new ScreenRect(32, 300, 0, 0), client, page));
        Assert.Contains("window", Proof.InView(new ScreenRect(32, 300, 920, 48), new ScreenSize(0, 0), page));
    }

    [Fact]
    public void BothScreenWalksCheckTheButtonIsInViewBeforeThePress()
    {
        var send = Read("src", "HermesHQ.Windows", "Services", "ProofWalks.ScreenSetup.cs");
        var check = send.IndexOf("await ButtonInViewAsync(window, button, page.Fallback!);", StringComparison.Ordinal);
        Assert.True(check > 0, "bot-screen-setup-send never checks the button is in view");
        Assert.True(check < send.IndexOf("Invoke(button);", StringComparison.Ordinal), "the check comes after the press");
        var wire = Read("src", "HermesHQ.Windows", "Services", "ProofWalks.Screen.cs");
        var inWire = wire.IndexOf("await ButtonInViewAsync(window, primary, page.Fallback!);", StringComparison.Ordinal);
        Assert.True(inWire > 0, "bot-screen-wire never checks the button is in view");
        Assert.True(inWire < wire.IndexOf("shot(\"bot-screen-setup-card\")", StringComparison.Ordinal), "the check comes after the setup card's shot");
        // Measured from the button's own bounds in the window's content, against the content's size and the page's
        // viewport, through the pure check.
        Assert.Contains("private static string? ButtonInView(", send);
        Assert.Contains("button.TransformToVisual(window.Content)", send);
        Assert.Contains("fallback.Page", send);
        Assert.Contains("return ScreenSetupWalkProof.InView(", send);
    }

    [Fact]
    public void TheWalkIsWiredAndTheStandInRecordsWithoutRunningAnything()
    {
        Assert.Equal("bot-screen-setup-send", Proof.Walk);
        Assert.Equal(["bot-screen-setup-sent"], Proof.Shots);
        var walk = Read("src", "HermesHQ.Windows", "Services", "ProofWalks.ScreenSetup.cs");
        Assert.Contains($"Automation.NamedWalks[\"{Proof.Walk}\"] = BotScreenSetupSendAsync;", walk);
        foreach (var shot in Proof.Shots.Append(Proof.FinalShot)) Assert.Contains($"shot(\"{shot}\")", walk);
        // Pressed through the card's own button (its automation peer), not OS input and not the requester directly.
        Assert.Contains("FindIn(window.Content, \"screen.setup.primary\")", walk);
        Assert.Contains("Invoke(button);", walk);
        foreach (var never in new[] { "Keys.Send", "Keys.Press", "SendInput", "SetCursorPos", "Requester.RunAsync", "SetupAsync()" })
            Assert.DoesNotContain(never, walk);
        Assert.Contains("RegisterScreenSetupWalks();", Read("src", "HermesHQ.Windows", "Services", "ProofWalks.cs"));

        var standIn = Read("ci", "fixtures", "screen-gateway.py");
        Assert.Contains("voice.SIDS[BOT] = BOT_SESSION", standIn);
        Assert.Contains($"SETUP_REF_TEXT = '{Proof.RefText}'", standIn);
        Assert.Contains("if method == 'file.attach':\n        return attach(params)", standIn);
        Assert.Contains("base.Client.prompt = prompt", standIn);
        foreach (var never in new[] { "zipfile", "subprocess", "os.system", "exec(", "ditto", "extract" })
            Assert.DoesNotContain(never, standIn);
    }
}
