// [WIN-SCREEN-PAGE] What the bot-screen walk (HermesHQ.Windows/Services/ProofWalks.Screen.cs) opens and checks: the Bot
// Screen viewer over an in-process stand-in of a gateway's display side (ScreenStandIn below), so the walk needs no new
// fixture server, no port and no windows.yml stand-in of its own. The stand-in answers display.status / start / observe /
// lease.acquire / lease.release as Hermes does (the rules of Tests/Screen/FakeDisplay.swift at 93f984bb1, trimmed to what
// the walk drives), and its display socket speaks RFB 3.8: the preamble, then one raw-encoded synthetic picture (a
// gradient with a window drawn on it). Nothing here is real data. Each check answers null when right, otherwise the words
// of what is wrong.

using System.Text;
using System.Text.Json.Nodes;
using Hermes.Core.Net;
using Hermes.Core.Rpc;
using Hermes.Core.Screen;

namespace Hermes.Core.Shell;

public static class ScreenWalkProof
{
    public const string Walk = "bot-screen";
    /// A demo bot (the repo's stand-in names).
    public const string Bot = "otto";
    public const string BotName = "Otto";
    public const string Display = "Bot Desktop";
    public const int Width = 320;
    public const int Height = 200;

    /// The shots, in the order the walk takes them.
    public static readonly IReadOnlyList<string> Shots = ["bot-screen-connecting", "bot-screen-live", "bot-screen-held", "bot-screen-fallback"];

    /// S0: the centred spinner and its words, nothing else.
    public static string? Connecting(ScreenViewerState s)
    {
        if (s.Panel.Hidden || s.Panel.Id != "screen.connecting") return $"connecting: the panel is {(s.Panel.Hidden ? "hidden" : s.Panel.Id)}";
        if (!s.Panel.Spinner || s.Panel.Body != "Connecting to the screen…") return "connecting: no spinner or the wrong words";
        if (!s.BarHidden) return "connecting: the control bar shows";
        if (s.Title != $"{BotName}’s Screen") return $"connecting: the title is \"{s.Title}\"";
        return null;
    }

    /// S2: the picture, the label under the title, the bar with Take Control, the display kept on.
    public static string? Live(ScreenViewerState s, bool hasPicture, (int Width, int Height) framebuffer)
    {
        if (!hasPicture) return "live: no picture";
        if (framebuffer != (Width, Height)) return $"live: the picture is {framebuffer.Width}×{framebuffer.Height}, not {Width}×{Height}";
        if (!s.Panel.Hidden) return $"live: the panel {s.Panel.Id} covers the picture";
        if (s.StageHidden || s.BarHidden) return "live: the stage or the bar is hidden";
        if (s.Subtitle != $"{Display} · {Width}×{Height}" || s.StageLabel != s.Subtitle) return $"live: the subtitle is \"{s.Subtitle}\"";
        if (s.Bar.Take != ControlWords.Take || !s.Bar.TakeEnabled) return "live: no Take Control";
        if (!s.KeepAwake) return "live: the display isn't kept on";
        return null;
    }

    /// S6: another viewer holds control: the note says so, the bar offers End Their Control.
    public static string? Held(ScreenViewerState s)
    {
        if (s.StageHidden || s.BarHidden) return "held: the picture or the bar went away";
        if (!s.Notes.Lines.Any(l => l.Id == "screen.note.other" && l.Text == ControlWords.OtherNote)) return "held: no \"Another viewer has control\" note";
        if (!s.Bar.Force) return "held: no End Their Control";
        return null;
    }

    /// S8: no live screen here: the latest-screenshots page in place of the picture and the bar.
    public static string? Fallback(ScreenViewerState s)
    {
        if (s.Fallback is not { Visible: true } page || !s.FallbackShown) return "fallback: the latest-screenshots page isn't shown";
        if (page.Reason != ScreenSession.Fallback.Unsupported) return $"fallback: the reason is {page.Reason}";
        if (!s.StageHidden || !s.BarHidden) return "fallback: the picture or the bar still shows";
        if (s.Subtitle != null) return "fallback: a subtitle shows over the screenshots page";
        if (s.KeepAwake) return "fallback: the display is still kept on";
        return null;
    }

    /// The pixel the page drew at the picture's middle is the stand-in's window colour (BGRA).
    public static string? Pixel((byte B, byte G, byte R) drawn)
    {
        var want = ScreenStandIn.Pixel(Width / 2, Height / 2);
        return Math.Abs(drawn.B - want.B) + Math.Abs(drawn.G - want.G) + Math.Abs(drawn.R - want.R) <= 6 ? null
            : $"the picture's middle is #{drawn.R:x2}{drawn.G:x2}{drawn.B:x2}, not #{want.R:x2}{want.G:x2}{want.B:x2}";
    }
}

/// A gateway's display side in-process, for the walk: synthetic status, Hermes's lease rules, and a display socket that
/// sends a picture. `Hold` hands control to another viewer; `Unsupported` takes the live screen away (the fallback page).
/// Safe from any thread.
public sealed class ScreenStandIn : IScreenGateway, IScreenshotGateway
{
    private readonly object _gate = new();
    private readonly List<(IReadOnlySet<string> Types, Action<string, JsonNode?> Handler)> _sinks = [];
    private readonly Dictionary<string, string> _tickets = [];
    private readonly HashSet<string> _minted = [];
    private TaskCompletionSource _statusGate = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private bool _supported = true;
    private string _holder = "agent";
    private string? _hash;
    private int _epoch = 1;
    private int _counter;

    public const string HomeKey = "/fixture/home/otto";
    public string AccountId => "account-screen-walk";
    public int Sockets { get; private set; }

    /// display.status waits until `Answer()`: the viewer sits in Connecting for its shot.
    public ScreenStandIn(bool holdFirstStatus = true)
    {
        if (!holdFirstStatus) _statusGate.SetResult();
    }

    /// Lets the held display.status answer.
    public void Answer() => _statusGate.TrySetResult();

    /// Another person takes control (a `display.lease` event, as Hermes sends one).
    public void Hold()
    {
        JsonObject payload;
        lock (_gate)
        {
            _holder = "human";
            _hash = ScreenWire.ViewerHash("someone-else");
            _epoch += 1;
            payload = new JsonObject { ["profile_key"] = HomeKey, ["lease"] = Lease() };
        }
        Publish("display.lease", payload);
    }

    /// The gateway stops offering a live screen (a `display.status` event with `supported: false`).
    public void Unsupported()
    {
        JsonObject payload;
        lock (_gate)
        {
            _supported = false;
            payload = Status();
        }
        Publish("display.status", payload);
    }

    /// The synthetic picture: a blue-grey gradient with a lighter window in the middle (B, G, R).
    public static (byte B, byte G, byte R) Pixel(int x, int y)
    {
        var inWindow = x >= ScreenWalkProof.Width / 4 && x < ScreenWalkProof.Width * 3 / 4 && y >= ScreenWalkProof.Height / 4 && y < ScreenWalkProof.Height * 3 / 4;
        if (inWindow) return y < ScreenWalkProof.Height / 4 + 14 ? ((byte)200, (byte)120, (byte)40) : ((byte)236, (byte)236, (byte)236);
        return ((byte)(120 + x * 100 / ScreenWalkProof.Width), (byte)(70 + y * 60 / ScreenWalkProof.Height), (byte)40);
    }

    /// RFB 3.8 up to ServerInit (no security), then one raw update with the whole picture.
    public static byte[] Picture()
    {
        int w = ScreenWalkProof.Width, h = ScreenWalkProof.Height;
        var name = Encoding.UTF8.GetBytes(ScreenWalkProof.Display);
        var bytes = new List<byte>();
        bytes.AddRange(Encoding.ASCII.GetBytes("RFB 003.008\n"));
        bytes.AddRange([1, 1]);
        bytes.AddRange(Be32(0));
        bytes.AddRange(Be16(w));
        bytes.AddRange(Be16(h));
        bytes.AddRange([32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]);
        bytes.AddRange(Be32(name.Length));
        bytes.AddRange(name);
        bytes.AddRange([0, 0]);
        bytes.AddRange(Be16(1));
        bytes.AddRange(Be16(0));
        bytes.AddRange(Be16(0));
        bytes.AddRange(Be16(w));
        bytes.AddRange(Be16(h));
        bytes.AddRange(Be32(0));
        for (var y = 0; y < h; y++)
            for (var x = 0; x < w; x++)
            {
                var (b, g, r) = Pixel(x, y);
                bytes.AddRange([b, g, r, 0]);
            }
        return [.. bytes];
    }

    private static byte[] Be16(int v) => [(byte)((v >> 8) & 0xFF), (byte)(v & 0xFF)];
    private static byte[] Be32(long v) => [(byte)((v >> 24) & 0xFF), (byte)((v >> 16) & 0xFF), (byte)((v >> 8) & 0xFF), (byte)(v & 0xFF)];

    private JsonObject Lease() => new()
    {
        ["holder"] = _holder, ["viewer_id"] = null, ["viewer_hash"] = _hash, ["since"] = 1_791_700_000, ["epoch"] = _epoch, ["reason"] = "",
    };

    private JsonObject Status() => new()
    {
        ["profile"] = ScreenWalkProof.Bot, ["profile_key"] = HomeKey, ["supported"] = _supported, ["installed"] = true, ["missing"] = new JsonArray(),
        ["running"] = true, ["display"] = ScreenWalkProof.Display, ["geometry"] = $"{ScreenWalkProof.Width}x{ScreenWalkProof.Height}",
        ["install_command"] = null, ["blocker"] = null, ["placement"] = "gateway", ["lease"] = Lease(),
    };

    private void Publish(string type, JsonObject payload)
    {
        List<Action<string, JsonNode?>> sinks;
        lock (_gate) sinks = _sinks.Where(s => s.Types.Contains(type)).Select(s => s.Handler).ToList();
        foreach (var sink in sinks) sink(type, JsonNode.Parse(payload.ToJsonString()));
    }

    public IDisposable Events(IReadOnlySet<string> types, Action<string, JsonNode?> handler)
    {
        var sink = (types, handler);
        lock (_gate) _sinks.Add(sink);
        return new Stop(() => { lock (_gate) _sinks.Remove(sink); });
    }

    public IDisposable ConnectionStates(Action<ConnectionState> handler)
    {
        handler(ConnectionState.Open);
        return new Stop(() => { });
    }

    public IDisposable RpcEvents(IReadOnlySet<string> types, Action<RpcEvent> handler) => new Stop(() => { });

    public async Task<JsonNode> CallAsync(string method, JsonObject parameters, TimeSpan timeout, CancellationToken ct = default)
    {
        if (method == "display.status") await _statusGate.Task.WaitAsync(ct).ConfigureAwait(false);
        else await Task.Yield();
        lock (_gate)
        {
            var viewer = parameters["viewer_id"] is JsonValue v && v.TryGetValue<string>(out var id0) ? id0 : null;
            switch (method)
            {
                case "display.status":
                case "display.start":
                    return JsonNode.Parse(Status().ToJsonString())!;
                case "display.observe":
                {
                    var id = viewer is { } known && _minted.Contains(known) ? known : $"viewer-walk-{++_counter}";
                    _minted.Add(id);
                    var ticket = $"ticket-walk-{++_counter}";
                    _tickets[ticket] = id;
                    var answer = Status();
                    answer["ticket"] = ticket;
                    answer["path"] = ScreenWire.DisplayPath;
                    answer["viewer_id"] = id;
                    return JsonNode.Parse(answer.ToJsonString())!;
                }
                case "display.lease.acquire":
                    if (viewer == null || !_minted.Contains(viewer)) throw new GatewayException("rpc", "viewer_id was not minted for this connection", rpcCode: 5300);
                    _holder = "human";
                    _hash = ScreenWire.ViewerHash(viewer);
                    _epoch += 1;
                    return JsonNode.Parse(new JsonObject { ["lease"] = Lease() }.ToJsonString())!;
                case "display.lease.release":
                    _holder = "agent";
                    _hash = null;
                    _epoch += 1;
                    return JsonNode.Parse(new JsonObject { ["lease"] = Lease() }.ToJsonString())!;
                default:
                    throw new GatewayException("rpc", "Method not found", rpcCode: -32601);
            }
        }
    }

    /// The display socket (ScreenService's dial).
    public Task<IScreenSocket> Dial(string path, string ticket, CancellationToken ct)
    {
        lock (_gate)
        {
            if (path != ScreenWire.DisplayPath || !_tickets.Remove(ticket)) throw new IOException("Could not connect to the server.");
            Sockets += 1;
        }
        return Task.FromResult<IScreenSocket>(new Socket(Picture()));
    }

    /// No plugin health route (not a Mac), no screenshots yet.
    public Task<string> RestAsync(string method, string path, CancellationToken ct = default) =>
        Task.FromException<string>(new GatewayException("http", "The gateway answered 404.", 404));

    public Task<string> RestAsync(string method, string path, IReadOnlyList<KeyValuePair<string, string>> query, CancellationToken ct = default) =>
        Task.FromResult(path.EndsWith("/messages", StringComparison.Ordinal) ? """{"messages":[]}""" : """{"sessions":[]}""");

    private sealed class Stop(Action stop) : IDisposable
    {
        private int _done;
        public void Dispose() { if (Interlocked.Exchange(ref _done, 1) == 0) stop(); }
    }

    /// Sends the picture once, then stays open until closed (the stream asks for updates; none come).
    private sealed class Socket(byte[] picture) : IScreenSocket
    {
        private readonly TaskCompletionSource _closed = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private int _sent;

        public int? CloseCode { get; private set; }
        public string? CloseReason => null;

        public async Task<ScreenSocketFrame> ReceiveAsync(CancellationToken ct)
        {
            if (Interlocked.Exchange(ref _sent, 1) == 0)
            {
                await Task.Yield();
                return new ScreenSocketFrame.Binary(picture);
            }
            await _closed.Task.WaitAsync(ct).ConfigureAwait(false);
            throw new IOException("The display socket closed.");
        }

        public Task SendAsync(byte[] data, CancellationToken ct) => _closed.Task.IsCompleted ? Task.FromException(new IOException("closed")) : Task.CompletedTask;
        public Task<bool> PingAsync(TimeSpan timeout) => Task.FromResult(!_closed.Task.IsCompleted);

        public void Close(bool handBack)
        {
            if (handBack) CloseCode = 1000;
            _closed.TrySetResult();
        }
    }
}

/// [WIN-SCREEN-WALK] What the bot-screen-wire walk (HermesHQ.Windows/Services/ProofWalks.Screen.cs) opens and checks over
/// the REAL wire: the signed-in client's ScreenService against windows/ci/fixtures/screen-gateway.py (display.* over the
/// gateway's JSON-RPC, the display socket's RFB 3.8 in binary WebSocket messages, the Mac plugin's health route). The
/// stand-in's picture is generated (no desktop is read) and its socket only records what the client sends. The walk
/// shoots the setup card (no live screen here), the Screen Control sheet (a Mac screen whose control is not set up), the
/// fitted picture, a zoomed view and the take-over state, and drives a tap and a key through Hermes.Core's
/// ScreenStageInput / ScreenKeyInput (never OS input). The Mac's wire (93f984bb1 App/Screen/*, AppModel+Screen.swift,
/// ScreenStageView.swift, HermesKit RFB): PointerEvent `05 mask x16 y16`, KeyEvent `04 down 00 00 keysym32`, and
/// display.lease.acquire with exactly `profile` and `viewer_id`. Each check answers null when right, else what is wrong.
public static class ScreenWireWalkProof
{
    public const string Walk = "bot-screen-wire";
    /// The stand-in's tag in windows.yml's screenshot extras.
    public const string Tag = "screen";
    public const string Bot = "otto";
    public const string BotName = "Otto";
    public const string Display = "This Mac";
    public const int Width = 640;
    public const int Height = 400;
    public const string StandIn = "/__fixture/screen";
    /// The key the walk types: "h" (X keysym 0x68).
    public const char KeyChar = 'h';
    public const uint KeySym = 0x68;

    /// The shots, in the order the walk takes them.
    public static readonly IReadOnlyList<string> Shots =
        ["bot-screen-setup-card", "bot-screen-control-sheet", "bot-screen-viewer", "bot-screen-zoomed", "bot-screen-take-over"];

    /// The walk's last shot, named after the walk (windows.yml wants a picture per walk name): the take-over state after
    /// the tap and the key reached the stand-in.
    public const string FinalShot = Walk;

    /// The stand-in's phase control's body.
    public static string PhaseBody(string phase) => new JsonObject { ["phase"] = phase }.ToJsonString();

    /// The synthetic picture (B, G, R), the stand-in's `pixel` rule.
    public static (byte B, byte G, byte R) Pixel(int x, int y)
    {
        if (x >= Width / 4 && x < Width * 3 / 4 && y >= Height / 4 && y < Height * 3 / 4)
            return y < Height / 4 + 24 ? ((byte)200, (byte)120, (byte)40) : ((byte)236, (byte)236, (byte)236);
        return ((byte)(120 + x * 100 / Width), (byte)(70 + y * 60 / Height), (byte)40);
    }

    /// A drawn pixel against the picture's own at (x, y), within a small tolerance.
    public static string? PixelAt((byte B, byte G, byte R) drawn, int x, int y)
    {
        var want = Pixel(x, y);
        return Math.Abs(drawn.B - want.B) + Math.Abs(drawn.G - want.G) + Math.Abs(drawn.R - want.R) <= 6 ? null
            : $"the picture at {x},{y} is #{drawn.R:x2}{drawn.G:x2}{drawn.B:x2}, not #{want.R:x2}{want.G:x2}{want.B:x2}";
    }

    /// Setup: no live screen for the bot, so the screenshots page shows with its setup card (not managed).
    public static string? SetupCard(ScreenViewerState s)
    {
        if (s.Fallback is not { Visible: true } page || !s.FallbackShown) return "setup: the screenshots page isn't shown";
        if (page.Reason != ScreenSession.Fallback.Unsupported) return $"setup: the reason is {page.Reason}";
        if (page.Managed) return "setup: the page is managed, so it has no setup card";
        if (!s.StageHidden || !s.BarHidden) return "setup: the picture or the bar shows";
        return null;
    }

    /// A live Mac screen whose control is not set up: the note and the Enable Control row, no Take Control yet.
    public static string? ControlNote(ScreenViewerState s)
    {
        if (s.StageHidden || s.BarHidden) return "control note: the picture or the bar is hidden";
        if (!s.Notes.Lines.Any(l => l.Id == "screen.note.control")) return "control note: no \"Control needs setup\" note";
        if (!s.Notes.EnableControl) return "control note: no Enable Control row";
        if (s.Bar.TakeEnabled) return "control note: Take Control is enabled before control is set up";
        return null;
    }

    /// The picture drawn and fitted: zoom 1, placed inside the stage at the picture's aspect, touching two of its edges.
    public static string? Fitted(ScreenViewerState s, bool hasPicture, (int Width, int Height) framebuffer, ScreenView view, ScreenRect drawn, ScreenSize stage)
    {
        if (!hasPicture) return "viewer: no picture";
        if (framebuffer != (Width, Height)) return $"viewer: the picture is {framebuffer.Width}×{framebuffer.Height}, not {Width}×{Height}";
        if (!s.Panel.Hidden) return $"viewer: the panel {s.Panel.Id} covers the picture";
        if (s.Subtitle != $"{Display} · {Width}×{Height}") return $"viewer: the subtitle is \"{s.Subtitle}\"";
        if (Math.Abs(view.Zoom - 1) > 0.001) return $"viewer: the zoom is {view.Zoom:0.###}, not fitted";
        if (stage.Width <= 0 || stage.Height <= 0 || drawn.Width <= 0) return "viewer: the stage isn't laid out";
        if (Math.Abs(drawn.Width / drawn.Height - (double)Width / Height) > 0.01) return $"viewer: drawn at {drawn.Width:0}×{drawn.Height:0}, not the picture's aspect";
        const double e = 0.75;
        if (drawn.X < -e || drawn.Y < -e || drawn.X + drawn.Width > stage.Width + e || drawn.Y + drawn.Height > stage.Height + e)
            return $"viewer: drawn at {drawn} outside the stage {stage.Width:0}×{stage.Height:0}";
        if (Math.Abs(drawn.Width - stage.Width) > e && Math.Abs(drawn.Height - stage.Height) > e) return "viewer: the picture doesn't fill the stage's width or height";
        return null;
    }

    /// Zoomed in: the view's zoom is past 1.5 and the drawn picture is bigger than the stage.
    public static string? Zoomed(ScreenViewerState s, ScreenView view, ScreenRect drawn, ScreenSize stage)
    {
        if (view.Zoom < 1.5) return $"zoomed: the zoom is {view.Zoom:0.###}";
        if (drawn.Width <= stage.Width + 0.75 && drawn.Height <= stage.Height + 0.75) return "zoomed: the picture is no bigger than the stage";
        if (!s.Bar.Fit) return "zoomed: the bar offers no Fit";
        return null;
    }

    /// Take-over: this device holds control, the bar offers Give Control (no Take Control), input is on.
    public static string? TakeOver(ScreenViewerState s)
    {
        if (!s.StageControl) return "take-over: the stage isn't in control";
        if (!s.Bar.Give || s.Bar.Take != null) return "take-over: the bar doesn't offer giving control back";
        if (!s.Bar.Keyboard) return "take-over: no keyboard button";
        return null;
    }

    /// How many input messages the stand-in has recorded (a mark before driving the stage).
    public static int Inputs(JsonNode? record) => record?["inputs"] is JsonArray list ? list.Count : 0;

    private static List<JsonObject> InputsAfter(JsonNode? record, int mark) =>
        record?["inputs"] is JsonArray list ? list.Skip(mark).OfType<JsonObject>().ToList() : [];

    private static string Hex(byte[] bytes) => Convert.ToHexString(bytes).ToLowerInvariant();

    /// A tap reached the socket: after `mark`, a PointerEvent with button 1 down at (x, y), then one with it up, each in
    /// the Mac's six bytes.
    public static string? Tap(JsonNode? record, int mark, int x, int y)
    {
        var pointers = InputsAfter(record, mark).Where(i => i.Str("kind") == "pointer").ToList();
        var down = pointers.FindIndex(i => i.Int("mask") == 1 && i.Int("x") == x && i.Int("y") == y);
        if (down < 0) return $"tap: no button-down at {x},{y} reached the stand-in ({string.Join(" ", pointers.Select(p => p.Str("hex")))})";
        if (!pointers.Skip(down + 1).Any(i => i.Int("mask") == 0 && i.Int("x") == x && i.Int("y") == y)) return $"tap: no button-up at {x},{y} after the press";
        foreach (var p in pointers)
            if (p.Str("hex") != Hex(RfbMessage.Pointer((byte)(p.Int("mask") ?? 0), (int)(p.Int("x") ?? 0), (int)(p.Int("y") ?? 0))))
                return $"tap: a pointer message isn't the Mac's PointerEvent ({p.Str("hex")})";
        return null;
    }

    /// A key reached the socket: after `mark`, a KeyEvent down then up for `keysym`, each in the Mac's eight bytes.
    public static string? Key(JsonNode? record, int mark, uint keysym)
    {
        var keys = InputsAfter(record, mark).Where(i => i.Str("kind") == "key").ToList();
        var down = keys.FindIndex(i => i.Bool("down") == true && i.Int("keysym") == keysym);
        if (down < 0) return $"key: no key-down for {keysym:x} reached the stand-in ({string.Join(" ", keys.Select(k => k.Str("hex")))})";
        if (!keys.Skip(down + 1).Any(i => i.Bool("down") == false && i.Int("keysym") == keysym)) return $"key: no key-up for {keysym:x}";
        if (keys[down].Str("hex") != Hex(RfbMessage.Key(keysym, true))) return $"key: the key-down isn't the Mac's KeyEvent ({keys[down].Str("hex")})";
        return null;
    }

    /// Take Control asked as the Mac asks: display.lease.acquire with exactly the profile and the minted viewer id.
    public static string? Lease(JsonNode? record)
    {
        var calls = record?["rpc"] is JsonArray list ? list.OfType<JsonObject>().ToList() : [];
        var acquire = calls.LastOrDefault(c => c.Str("method") == "display.lease.acquire");
        if (acquire?["params"] is not JsonObject p) return "lease: no display.lease.acquire reached the stand-in";
        var keys = p.Select(kv => kv.Key).OrderBy(k => k, StringComparer.Ordinal).ToArray();
        if (!keys.SequenceEqual(["profile", "viewer_id"])) return $"lease: acquire sent {string.Join(", ", keys)}";
        if (p.Str("profile") != Bot) return $"lease: acquire named {p.Str("profile")}";
        var observed = calls.Where(c => c.Str("method") == "display.observe").Select(c => c["params"]).OfType<JsonObject>().ToList();
        if (observed.Count == 0) return "lease: no display.observe before it";
        if (string.IsNullOrEmpty(p.Str("viewer_id"))) return "lease: no viewer id";
        if ((record.Int("sockets") ?? 0) < 1) return "lease: the display socket was never dialled";
        return null;
    }
}
