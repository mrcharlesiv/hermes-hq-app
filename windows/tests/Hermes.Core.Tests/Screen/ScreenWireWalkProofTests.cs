// [WIN-SCREEN-WALK] The bot-screen-wire walk's pure checks (Hermes.Core/Shell/ScreenWalkProof.cs ScreenWireWalkProof):
// each passes on the state or record it is for and says what is wrong otherwise; the tap and key checks read the Mac's
// PointerEvent / KeyEvent bytes (RfbMessage), so a record whose bytes differ fails. Also pins the four places the walk is
// wired: the walk registration and its shots, the stand-in, e2e.sh's HQW_E2E_SCREEN_PORT and windows.yml's "screen"
// extra with its required shots. ScreenWireEndToEndTests runs the same checks against the stand-in over the wire.

using System.Text.Json.Nodes;
using Hermes.Core.Screen;
using Hermes.Core.Shell;
using Proof = Hermes.Core.Shell.ScreenWireWalkProof;

namespace Hermes.Core.Tests.Screen;

public sealed class ScreenWireWalkProofTests
{
    private static JsonObject Pointer(int mask, int x, int y, string? hex = null) => new()
    {
        ["kind"] = "pointer", ["mask"] = mask, ["x"] = x, ["y"] = y,
        ["hex"] = hex ?? Convert.ToHexString(RfbMessage.Pointer((byte)mask, x, y)).ToLowerInvariant(),
    };

    private static JsonObject Key(bool down, uint keysym, string? hex = null) => new()
    {
        ["kind"] = "key", ["down"] = down, ["keysym"] = keysym,
        ["hex"] = hex ?? Convert.ToHexString(RfbMessage.Key(keysym, down)).ToLowerInvariant(),
    };

    /// As the stand-in's GET answers it (parsed JSON, so numbers read as the walk reads them).
    private static JsonObject Record(params JsonObject[] inputs) =>
        (JsonObject)JsonNode.Parse(new JsonObject { ["inputs"] = new JsonArray([.. inputs]), ["rpc"] = new JsonArray(), ["sockets"] = 1 }.ToJsonString())!;

    [Fact]
    public void ATapIsAButtonDownThenUpAtThePointerInTheMacsSixBytes()
    {
        var record = Record(Pointer(0, 320, 200), Pointer(1, 320, 200), Pointer(0, 320, 200));
        Assert.Equal("0501014000c8", record["inputs"]![1]!["hex"]!.GetValue<string>());
        Assert.Null(Proof.Tap(record, 0, 320, 200));
        Assert.Null(Proof.Tap(record, 1, 320, 200));
        Assert.Contains("no button-down", Proof.Tap(record, 2, 320, 200));     // before the mark doesn't count
        Assert.Contains("no button-down", Proof.Tap(record, 0, 321, 200));
        Assert.Contains("no button-up", Proof.Tap(Record(Pointer(1, 320, 200)), 0, 320, 200));
        Assert.Contains("isn't the Mac's PointerEvent", Proof.Tap(Record(Pointer(1, 320, 200), Pointer(0, 320, 200, "0500400140c8")), 0, 320, 200));
    }

    [Fact]
    public void AKeyIsADownThenUpInTheMacsEightBytes()
    {
        var record = Record(Key(true, Proof.KeySym), Key(false, Proof.KeySym));
        Assert.Equal("0401000000000068", record["inputs"]![0]!["hex"]!.GetValue<string>());
        Assert.Null(Proof.Key(record, 0, Proof.KeySym));
        Assert.Contains("no key-down", Proof.Key(record, 0, 0x71));
        Assert.Contains("no key-up", Proof.Key(Record(Key(true, Proof.KeySym)), 0, Proof.KeySym));
        Assert.Contains("isn't the Mac's KeyEvent", Proof.Key(Record(Key(true, Proof.KeySym, "04010000680000000"), Key(false, Proof.KeySym)), 0, Proof.KeySym));
        Assert.Equal(2, Proof.Inputs(record));
        Assert.Equal(0, Proof.Inputs(null));
    }

    [Fact]
    public void TakeControlAsksWithExactlyTheProfileAndTheMintedViewer()
    {
        JsonObject Call(string method, JsonObject p) => new() { ["method"] = method, ["params"] = p };
        JsonObject With(params JsonObject[] calls) =>
            (JsonObject)JsonNode.Parse(new JsonObject { ["rpc"] = new JsonArray([.. calls]), ["inputs"] = new JsonArray(), ["sockets"] = 1 }.ToJsonString())!;
        JsonObject Observe() => Call("display.observe", new JsonObject { ["profile"] = Proof.Bot });
        Assert.Null(Proof.Lease(With(Observe(), Call("display.lease.acquire", (JsonObject)ScreenWire.AcquireParams(Proof.Bot, "viewer-1").DeepClone()))));
        Assert.Contains("no display.lease.acquire", Proof.Lease(With(Observe())));
        Assert.Contains("acquire sent", Proof.Lease(With(Observe(), Call("display.lease.acquire", new JsonObject { ["profile"] = Proof.Bot, ["viewer_id"] = "v", ["force"] = true }))));
        Assert.Contains("no display.observe", Proof.Lease(With(Call("display.lease.acquire", new JsonObject { ["profile"] = Proof.Bot, ["viewer_id"] = "v" }))));
        var undialled = With(Observe(), Call("display.lease.acquire", new JsonObject { ["profile"] = Proof.Bot, ["viewer_id"] = "v" }));
        undialled["sockets"] = 0;
        Assert.Contains("never dialled", Proof.Lease(undialled));
    }

    [Fact]
    public void EachViewerCheckSaysWhatIsWrong()
    {
        var fallback = new ScreenViewerState
        {
            StageHidden = true, BarHidden = true, FallbackShown = true,
            Fallback = new ScreenFallbackModel(ScreenSession.Fallback.Unsupported, null, Managed: false, Visible: true),
        };
        Assert.Null(Proof.SetupCard(fallback));
        Assert.Contains("managed", Proof.SetupCard(fallback with { Fallback = fallback.Fallback! with { Managed = true } }));
        Assert.Contains("isn't shown", Proof.SetupCard(new ScreenViewerState()));

        var note = new ScreenViewerState
        {
            Notes = new ScreenNotesModel { Lines = [new("Control needs setup…", "screen.note.control", Warning: true)], EnableControl = true },
            Bar = new ScreenBarModel { TakeEnabled = false },
        };
        Assert.Null(Proof.ControlNote(note));
        Assert.Contains("Enable Control", Proof.ControlNote(note with { Notes = note.Notes with { EnableControl = false } }));
        Assert.Contains("enabled before", Proof.ControlNote(note with { Bar = new ScreenBarModel { TakeEnabled = true } }));

        var live = new ScreenViewerState { Subtitle = $"{Proof.Display} · {Proof.Width}×{Proof.Height}", Panel = new ScreenPanelModel { Hidden = true } };
        var stage = new ScreenSize(800, 600);
        var fitted = new ScreenRect(0, 50, 800, 500);
        Assert.Null(Proof.Fitted(live, true, (Proof.Width, Proof.Height), ScreenView.Fit, fitted, stage));
        Assert.Contains("no picture", Proof.Fitted(live, false, (0, 0), ScreenView.Fit, fitted, stage));
        Assert.Contains("not fitted", Proof.Fitted(live, true, (Proof.Width, Proof.Height), new ScreenView(2), fitted, stage));
        Assert.Contains("aspect", Proof.Fitted(live, true, (Proof.Width, Proof.Height), ScreenView.Fit, new ScreenRect(0, 0, 800, 600), stage));
        Assert.Contains("doesn't fill", Proof.Fitted(live, true, (Proof.Width, Proof.Height), ScreenView.Fit, new ScreenRect(100, 100, 400, 250), stage));

        var zoomed = new ScreenViewerState { Bar = new ScreenBarModel { Fit = true } };
        Assert.Null(Proof.Zoomed(zoomed, new ScreenView(2), new ScreenRect(-400, -450, 1600, 1000), stage));
        Assert.Contains("the zoom is", Proof.Zoomed(zoomed, ScreenView.Fit, fitted, stage));
        Assert.Contains("no Fit", Proof.Zoomed(new ScreenViewerState(), new ScreenView(2), new ScreenRect(-400, -450, 1600, 1000), stage));

        var held = new ScreenViewerState { StageControl = true, Bar = new ScreenBarModel { Give = true, Take = null, Keyboard = true } };
        Assert.Null(Proof.TakeOver(held));
        Assert.Contains("isn't in control", Proof.TakeOver(held with { StageControl = false }));
        Assert.Contains("giving control back", Proof.TakeOver(held with { Bar = held.Bar with { Take = ControlWords.Take } }));
    }

    [Fact]
    public void ThePictureRuleIsTheStandInsAndADrawnPixelIsCheckedAgainstIt()
    {
        Assert.Equal(((byte)236, (byte)236, (byte)236), Proof.Pixel(Proof.Width / 2, Proof.Height / 2 + 40));
        Assert.Equal(((byte)200, (byte)120, (byte)40), Proof.Pixel(Proof.Width / 2, Proof.Height / 4));
        Assert.Equal(((byte)120, (byte)70, (byte)40), Proof.Pixel(0, 0));
        Assert.Null(Proof.PixelAt((236, 235, 237), 320, 240));
        Assert.NotNull(Proof.PixelAt((0, 0, 0), 320, 240));
        var standIn = Read("ci", "fixtures", "screen-gateway.py");
        Assert.Contains("WIDTH, HEIGHT = 640, 400", standIn);
        Assert.Contains("return (200, 120, 40) if y < HEIGHT // 4 + 24 else (236, 236, 236)", standIn);
        Assert.Contains("return (120 + x * 100 // WIDTH, 70 + y * 60 // HEIGHT, 40)", standIn);
        // A receiver only: it decodes and records, and never imports anything that could move a pointer or press a key.
        foreach (var never in new[] { "pyautogui", "pynput", "ctypes", "subprocess", "os.system", "Quartz" })
            Assert.DoesNotContain(never, standIn);
    }

    private static string Read(params string[] parts)
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir != null && !Directory.Exists(Path.Combine(dir.FullName, "src", "HermesHQ.Windows"))) dir = dir.Parent;
        Assert.NotNull(dir);
        return File.ReadAllText(Path.Combine([dir!.FullName, .. parts])).ReplaceLineEndings("\n");
    }

    [Fact]
    public void TheWalkIsWiredInTheFourPlaces()
    {
        var walk = Read("src", "HermesHQ.Windows", "Services", "ProofWalks.Screen.cs");
        Assert.Contains($"Automation.NamedWalks[\"{Proof.Walk}\"] = BotScreenWireAsync;", walk);
        foreach (var shot in Proof.Shots.Append(Proof.FinalShot)) Assert.Contains($"shot(\"{shot}\")", walk);
        Assert.Contains("new ScreenStageInput(viewer.Stage)", walk);
        Assert.Contains("viewer.KeyInput.CharacterReceived(", walk);
        Assert.DoesNotContain("Keys.Press", walk);     // no OS input: the stage and the key field's Core entry points only
        Assert.DoesNotContain("SendInput", walk);
        Assert.Contains("RegisterScreenWalks();", Read("src", "HermesHQ.Windows", "Services", "ProofWalks.cs"));

        var e2e = Read("scripts", "e2e.sh");
        Assert.Contains("SCRPORT=${HQW_E2E_SCREEN_PORT:-9880}", e2e);
        Assert.Contains("$FIXTURES/screen-gateway.py --port $SCRPORT", e2e);
        Assert.Contains("export HQW_E2E_SCREEN_CREDENTIALS=", e2e);

        var yml = Read("ci", "windows.yml");
        var line = yml.Split('\n').Single(l => l.Contains("@{ tag = \"screen\";", StringComparison.Ordinal));
        Assert.Contains("\"windows/ci/fixtures/screen-gateway.py\",\"--port\",\"9880\"", line);
        // [WIN-SCREEN-SETUP-SEND-WALK] bot-screen-setup-send runs after it on the same stand-in (ScreenSetupWalkProofTests).
        Assert.Contains($"walks = @(\"{Proof.Walk}\",\"{ScreenSetupWalkProof.Walk}\")", line);
        Assert.Contains("shots = @(" + string.Join(",", Proof.Shots.Concat(ScreenSetupWalkProof.Shots).Select(s => $"\"{s}\"")) + ")", line);
        // Toasts stay the last extra (a later sign-in clears its toasts).
        Assert.True(yml.IndexOf("@{ tag = \"screen\";", StringComparison.Ordinal) < yml.IndexOf("@{ tag = \"toasts\";", StringComparison.Ordinal));
        // No other stand-in takes the screen range.
        Assert.DoesNotContain(yml.Split('\n'), l => l.Contains("\"988", StringComparison.Ordinal) && !l.Contains("screen-gateway.py", StringComparison.Ordinal));
    }
}
