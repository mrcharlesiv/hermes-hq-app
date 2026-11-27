using System.Text;
using System.Text.Json.Nodes;
using Hermes.Core.Terminal;

namespace Hermes.Core.Tests;

/// The Terminal (docs/spec/terminal.md; the Mac's Tests/Terminal/TerminalTests.swift): the wire, the connection loop
/// over a stand-in socket, the add-on status, the words, and the screen the shell's output draws on.
public class TerminalTests
{
    [Fact]
    public void SocketAddressAndQuery()
    {
        var url = TerminalWire.SocketUrl(new Uri("https://hermes.example.com/"), "/base",
            TerminalWire.Query("ab", 80, 24, 12).Append(new("ticket", "old")), "t+1");
        Assert.Equal("wss://hermes.example.com/base/api/plugins/hermes-hq-push/terminal?session=ab&cols=80&rows=24&since=12&ticket=t%2B1",
            url!.AbsoluteUri);
        Assert.StartsWith("ws://127.0.0.1:9850/api/", TerminalWire.SocketUrl(new Uri("http://127.0.0.1:9850/"), "", [], "t")!.AbsoluteUri);
        Assert.Null(TerminalWire.SocketUrl(new Uri("ftp://x/"), "", [], "t"));
        var s = TerminalWire.NewSession();
        Assert.True(TerminalWire.IsSession(s));
        Assert.False(TerminalWire.IsSession(s.ToUpperInvariant()));
        Assert.NotEqual(s, TerminalWire.NewSession());
    }

    [Fact]
    public void TextFramesAndEndings()
    {
        Assert.Equal(new TerminalWire.Message.Ready(120, "zsh", true),
            TerminalWire.Parse("""{"type":"ready","session":"x","offset":120,"shell":"zsh","resumed":true}"""));
        Assert.Equal(new TerminalWire.Message.Exit(3), TerminalWire.Parse("""{"type":"exit","code":3}"""));
        Assert.Equal(new TerminalWire.Message.Exit(null), TerminalWire.Parse("""{"type":"exit"}"""));
        Assert.IsType<TerminalWire.Message.Ping>(TerminalWire.Parse("""{"type":"ping"}"""));
        Assert.IsType<TerminalWire.Message.Other>(TerminalWire.Parse("nope"));
        Assert.Equal("""{"type":"resize","cols":100,"rows":30}""", TerminalWire.Resize(100, 30));
        Assert.Equal(TerminalWire.EndingKind.Ended, TerminalWire.EndingFor(1000, null).Kind);
        Assert.Equal(TerminalWire.EndingKind.Replaced, TerminalWire.EndingFor(4409, null).Kind);
        Assert.Equal(TerminalWire.EndingKind.Off, TerminalWire.EndingFor(4403, null).Kind);
        Assert.Equal(TerminalWire.EndingKind.Unsupported, TerminalWire.EndingFor(4501, null).Kind);
        Assert.Equal(TerminalWire.EndingKind.Full, TerminalWire.EndingFor(4429, null).Kind);
        Assert.Equal(new TerminalWire.Ending(TerminalWire.EndingKind.Refused, "no pty"), TerminalWire.EndingFor(4500, "no pty"));
        Assert.Equal("The computer refused the terminal.", TerminalWire.EndingFor(4400, "").Reason);
        Assert.Equal(TerminalWire.EndingKind.Blocked, TerminalWire.EndingFor(null, null, 404).Kind);
        Assert.Equal(TerminalWire.EndingKind.Retry, TerminalWire.EndingFor(null, null).Kind);
        Assert.Equal(TerminalWire.EndingKind.Retry, TerminalWire.EndingFor(1006, null).Kind);
        Assert.Equal("close 4409 → replaced", TerminalWire.Describe(4409, null, TerminalWire.EndingFor(4409, "secret")));
        Assert.Equal("HTTP 404 → blocked", TerminalWire.Describe(null, 404, TerminalWire.EndingFor(null, null, 404)));
    }

    [Fact]
    public void TheAddOnSaysWhetherItHasTheTerminal()
    {
        Assert.Equal(TerminalWire.AddOn.Ready, TerminalWire.AddOnFrom(200, JsonNode.Parse("""{"terminal":true,"terminalOff":false}""")));
        Assert.Equal(TerminalWire.AddOn.Off, TerminalWire.AddOnFrom(200, JsonNode.Parse("""{"terminal":true,"terminalOff":true}""")));
        Assert.Equal(TerminalWire.AddOn.Unsupported, TerminalWire.AddOnFrom(200, JsonNode.Parse("""{"terminal":false}""")));
        Assert.Equal(TerminalWire.AddOn.NeedsUpdate, TerminalWire.AddOnFrom(200, JsonNode.Parse("""{"pluginVersion":"0.9.20"}""")));
        Assert.Equal(TerminalWire.AddOn.NeedsUpdate, TerminalWire.AddOnFrom(404, null));
        Assert.Equal(TerminalWire.AddOn.Unknown, TerminalWire.AddOnFrom(500, null));
    }

    [Fact]
    public void Words()
    {
        Assert.Equal("This Computer", TerminalWords.ComputerName(""));
        var consent = TerminalWords.Consent("Studio", unlock: true);
        Assert.Equal("Open a Terminal on Studio?", consent.Title);
        Assert.Equal(("Turn On", "Not Now"), (consent.Button, consent.Secondary));
        Assert.Equal(3, TerminalWords.ConsentPoints(true).Count);
        Assert.Equal("Windows Hello or your PIN is asked", TerminalWords.ConsentPoints(true)[2].Lead);
        Assert.Equal(2, TerminalWords.ConsentPoints(false).Count);
        Assert.Equal("You ended this shell.", TerminalWords.Ended(0, endedHere: true).Body);
        Assert.Equal("It exited with code 2.", TerminalWords.Ended(2, false).Body);
        Assert.Equal("The shell has closed.", TerminalWords.Ended(null, false).Body);
        Assert.Equal("Turned Off on Studio", TerminalWords.Stopped(new(TerminalWire.EndingKind.Off), "Studio").Title);
        Assert.Null(TerminalWords.Stopped(new(TerminalWire.EndingKind.Off), "Studio").Button);
        Assert.Equal("Studio has 8 shells open. Close a tab or end one in another window, or wait a few minutes.",
            TerminalWords.Stopped(new(TerminalWire.EndingKind.Full), "Studio").Body);
        Assert.Equal("Open Here", TerminalWords.Stopped(new(TerminalWire.EndingKind.Replaced), "x").Button);
        Assert.Equal("Update Add-on", TerminalWords.NeedsAddOn("x", false).Button);
        Assert.Equal("Try Again", TerminalWords.NeedsAddOn("x", true).Button);
        Assert.Equal(("Paste 2 Lines?", 2), (TerminalWords.PasteAsk(2).Title, TerminalWords.PasteLines("a\nb\n")));
        Assert.Equal("Paste and Run?", TerminalWords.PasteAsk(TerminalWords.PasteLines("ls\n")).Title);
        Assert.True(TerminalWords.PasteAsks("a\nb", bracketed: false));
        Assert.False(TerminalWords.PasteAsks("a\nb", bracketed: true));
        Assert.False(TerminalWords.PasteAsks("ls", bracketed: false));
    }

    [Fact]
    public void SettingsAndTabTitles()
    {
        var prefs = new WorkspaceTests.Prefs();
        var settings = new TerminalSettings(prefs);
        Assert.False(settings.Allowed("a"));
        settings.SetAllowed(true, "a");
        Assert.True(settings.Allowed("a"));
        Assert.True(settings.RequiresUnlock);
        settings.RequiresUnlock = false;
        Assert.False(settings.RequiresUnlock);
        Assert.Equal(TerminalSettings.DefaultSize, settings.FontSize);
        settings.FontSize = 99;
        Assert.Equal(32, settings.FontSize);
        var first = settings.Sessions("a");
        Assert.Single(first);
        Assert.Equal(first, settings.Sessions("a"));
        prefs.Set("hq.terminal.session.b", new string('a', 32));   // a device from before tabs
        Assert.Equal([new string('a', 32)], settings.Sessions("b"));
        Assert.Equal(["1 zsh", "Build", "Shell 3"], TerminalSettings.TabTitles([("", "zsh"), ("Build", "vim"), ("", null)]));
        settings.FontFace = TerminalSettings.Face.Hack;
        Assert.Equal("hack", prefs.Get("hq.terminal.font"));
    }

    [Fact]
    public void KeysAsXtermSendsThem()
    {
        Assert.Equal("\x1b[A", Encoding.ASCII.GetString(TerminalKeys.Encode(TerminalKeys.Key.Up)));
        Assert.Equal("\x1bOA", Encoding.ASCII.GetString(TerminalKeys.Encode(TerminalKeys.Key.Up, appCursor: true)));
        Assert.Equal("\x1b[1;5C", Encoding.ASCII.GetString(TerminalKeys.Encode(TerminalKeys.Key.Right, ctrl: true)));
        Assert.Equal("\x7f", Encoding.ASCII.GetString(TerminalKeys.Encode(TerminalKeys.Key.Backspace)));
        Assert.Equal("\x1b[3~", Encoding.ASCII.GetString(TerminalKeys.Encode(TerminalKeys.Key.Delete)));
        Assert.Equal("\x1b[Z", Encoding.ASCII.GetString(TerminalKeys.Encode(TerminalKeys.Key.Tab, shift: true)));
        Assert.Equal((byte)3, TerminalKeys.Control('c'));
        Assert.Equal((byte)0x1b, TerminalKeys.Control('['));
        Assert.Null(TerminalKeys.Control('é'));
        Assert.Equal("a\rb\r", Encoding.UTF8.GetString(TerminalKeys.Paste("a\r\nb\n", bracketed: false)));
        Assert.Equal("\x1b[200~a\rb\x1b[201~", Encoding.UTF8.GetString(TerminalKeys.Paste("a\nb", bracketed: true)));
    }

    // MARK: The screen

    [Fact]
    public void TheScreenPrintsWrapsAndScrolls()
    {
        var t = new TerminalScreen(10, 3);
        t.Feed("hello\r\nworld");
        Assert.Equal("hello\nworld", t.ScreenText());
        Assert.Equal((5, 1), (t.CursorX, t.CursorY));
        t.Feed("\r\n0123456789AB");          // wraps after the tenth column
        Assert.Equal("world\n0123456789\nAB", t.ScreenText());
        Assert.Equal("hello", TerminalScreen.Text(Assert.Single(t.Scrollback)));
        Assert.Equal("hello\nworld\n0123456789\nAB", t.AllText());
        t.Feed("\x1b[2J\x1b[H");
        Assert.Equal("", t.ScreenText());
        Assert.Equal("hello", t.AllText());
    }

    [Fact]
    public void ColoursAndAttributes()
    {
        var t = new TerminalScreen(40, 2);
        t.Feed("\x1b[1;31mred\x1b[0m \x1b[38;5;208mo\x1b[48;2;1;2;3mx\x1b[7mi\x1b[m.");
        var line = t.Line(0);
        Assert.Equal(new CellStyle(1, -1, CellStyle.Attr.Bold), line[0].Style);
        Assert.Equal(CellStyle.Plain, line[3].Style);
        Assert.Equal(208, line[4].Style.Fg);
        Assert.Equal(CellStyle.Rgb(1, 2, 3), line[5].Style.Bg);
        Assert.True(line[6].Style.Has(CellStyle.Attr.Inverse));
        Assert.Equal(CellStyle.Plain, line[7].Style);
        t.Feed("\r\n\x1b[94mblue\x1b[39m");
        Assert.Equal(12, t.Line(1)[0].Style.Fg);

        // The page's colours: the panel, VS Code's ANSI blue, the 256 cube and greys, bold brightening, inverse.
        Assert.Equal((TerminalColors.Foreground, TerminalColors.Background), TerminalColors.Resolve(CellStyle.Plain));
        Assert.Equal(0x3B8EEA, TerminalColors.Rgb(12, true));
        Assert.Equal(0xFF8700, TerminalColors.Rgb(208, true));
        Assert.Equal(0x080808, TerminalColors.Rgb(232, true));
        Assert.Equal(0xF14C4C, TerminalColors.Resolve(line[0].Style).Fg);
        Assert.Equal((TerminalColors.Background, TerminalColors.Foreground), TerminalColors.Resolve(line[6].Style with { Bg = -1, Fg = -1 }));
    }

    [Fact]
    public void CursorMovesAndErases()
    {
        var t = new TerminalScreen(10, 4);
        t.Feed("abcdef\x1b[3D\x1b[K");
        Assert.Equal("abc", t.ScreenText());
        t.Feed("\x1b[3;5HX\x1b[1;1H\x1b[2Pz");
        Assert.Equal("z\n\n    X", t.ScreenText());
        t.Feed("\x1b[1;1H\x1b[2@");
        Assert.Equal("  z", TerminalScreen.Text(t.Line(0)));
        t.Feed("\x1b[2;1H\x1b[L");   // insert a line: X moves down
        Assert.Equal("  z\n\n\n    X", t.ScreenText());
        t.Feed("\x1b[2;1H\x1b[M");
        Assert.Equal("  z\n\n    X", t.ScreenText());
        var said = new List<string>();
        t.Respond += b => said.Add(Encoding.ASCII.GetString(b));
        t.Feed("\x1b[3;7H\x1b[6n");
        Assert.Equal("\x1b[3;7R", Assert.Single(said));
        t.Feed("\ta");
        Assert.Equal(9, t.CursorX);   // tab to column 8, then 'a'
    }

    [Fact]
    public void ScrollRegionsAndTheAlternateScreen()
    {
        var t = new TerminalScreen(10, 4);
        t.Feed("1\r\n2\r\n3\r\n4");
        t.Feed("\x1b[2;3r\x1b[3;1H\n");      // scroll lines 2–3 only
        Assert.Equal("1\n3\n\n4", t.ScreenText());
        Assert.Empty(t.Scrollback);
        t.Feed("\x1b[r\x1b[?1049h\x1b[Hvim");
        Assert.True(t.AltScreen);
        Assert.Equal("vim", t.ScreenText());
        t.Feed("\x1b[?1049l");
        Assert.False(t.AltScreen);
        Assert.Equal("1\n3\n\n4", t.ScreenText());
        t.Feed("\x1b[?2004h\x1b[?1h\x1b[?25l");
        Assert.True(t.BracketedPaste && t.AppCursorKeys && !t.CursorVisible);
    }

    [Fact]
    public void TitlesCopiesAndSplitCharacters()
    {
        var t = new TerminalScreen(20, 2);
        string? title = null, copied = null;
        t.TitleChanged += s => title = s;
        t.Copied += s => copied = s;
        t.Feed("\x1b]0;vim notes.txt\a\x1b]52;c;" + Convert.ToBase64String(Encoding.UTF8.GetBytes("from tmux")) + "\x1b\\");
        Assert.Equal("vim notes.txt", title);
        Assert.Equal("from tmux", copied);
        // A multi-byte character split across two frames still draws once.
        var bytes = Encoding.UTF8.GetBytes("é👋中");
        t.Feed(bytes[..1]);
        t.Feed(bytes[1..5]);
        t.Feed(bytes[5..]);
        Assert.Equal("é👋中", TerminalScreen.Text(t.Line(0)));
        Assert.Equal(5, t.CursorX);     // é 1, 👋 2, 中 2
        Assert.Equal("", t.Line(0)[2].Text);
    }

    [Fact]
    public void ResizingKeepsTheText()
    {
        var t = new TerminalScreen(10, 4);
        t.Feed("a\r\nb\r\nc\r\nd");
        t.Resize(6, 2);
        Assert.Equal((6, 2), (t.Cols, t.Rows));
        Assert.Equal("c\nd", t.ScreenText());
        Assert.Equal(1, t.CursorY);
        Assert.Equal("a\nb\nc\nd", t.AllText());
        t.Resize(6, 4);
        Assert.Equal("a\nb\nc\nd", t.ScreenText());
        Assert.Equal(3, t.CursorY);
        t.Clear();
        Assert.Equal("", t.AllText());
    }

    // MARK: The connection loop

    private sealed class FakeSocket : ITerminalSocket
    {
        private readonly System.Threading.Channels.Channel<TerminalFrame?> _in = System.Threading.Channels.Channel.CreateUnbounded<TerminalFrame?>();
        public readonly List<TerminalFrame> Sent = [];
        public int? CloseCode { get; set; }
        public string? CloseReason { get; set; }
        public int? RefusedStatus { get; set; }
        public bool Closed;
        public void Push(TerminalFrame frame) => _in.Writer.TryWrite(frame);
        public void Drop(int? code = null) { CloseCode = code; _in.Writer.TryWrite(null); }
        public async Task<TerminalFrame> ReceiveAsync(CancellationToken ct) =>
            await _in.Reader.ReadAsync(ct) ?? throw new IOException("closed");
        public void Send(TerminalFrame frame) { lock (Sent) Sent.Add(frame); }
        public void Close() { Closed = true; _in.Writer.TryWrite(null); }
    }

    private static async Task Until(Func<bool> condition, int seconds = 10)
    {
        var until = DateTime.UtcNow.AddSeconds(seconds);
        while (!condition())
        {
            if (DateTime.UtcNow > until) throw new TimeoutException("condition not met");
            await Task.Delay(10);
        }
    }

    [Fact]
    public async Task TheConnectionReplaysWhatWasMissedAndSendsWhatWaited()
    {
        TerminalConnection.Backoff = _ => TimeSpan.FromMilliseconds(10);
        var sockets = new List<FakeSocket>();
        var queries = new List<Dictionary<string, string>>();
        var connection = new TerminalConnection(TerminalWire.NewSession(), (q, ct) =>
        {
            var s = new FakeSocket();
            lock (sockets) { queries.Add(q.ToDictionary(k => k.Key, k => k.Value)); sockets.Add(s); }   // the query first: the test waits on sockets.Count
            return Task.FromResult<ITerminalSocket>(s);
        });
        var output = new StringBuilder();
        var resets = 0;
        var phases = new List<TerminalConnection.Phase>();
        connection.Output += b => { lock (output) output.Append(Encoding.UTF8.GetString(b)); };
        connection.Reset += () => resets++;
        connection.PhaseChanged += p => { lock (phases) phases.Add(p); };
        connection.Send(Encoding.UTF8.GetBytes("early"));   // typed before the shell is there: waits
        connection.Start(100, 30);
        await Until(() => sockets.Count == 1);
        Assert.Equal("0", queries[0]["since"]);
        Assert.Equal("100", queries[0]["cols"]);
        sockets[0].Push(new TerminalFrame.Text("""{"type":"ready","offset":0,"shell":"zsh"}"""));
        await Until(() => connection.CurrentPhase is TerminalConnection.Phase.Live);
        await Until(() => sockets[0].Sent.OfType<TerminalFrame.Binary>().Any());
        Assert.Equal("early", Encoding.UTF8.GetString(sockets[0].Sent.OfType<TerminalFrame.Binary>().First().Data));
        Assert.Equal("zsh", connection.Shell);
        sockets[0].Push(new TerminalFrame.Binary(Encoding.UTF8.GetBytes("$ ls\r\n")));
        await Until(() => connection.Shown == 6);
        connection.Resize(90, 30);
        Assert.Contains(sockets[0].Sent, f => f is TerminalFrame.Text { Value: var v } && v.Contains("\"cols\":90"));

        // The link drops: dial again from byte 6; the computer kept it all, so nothing is cleared.
        sockets[0].Drop();
        await Until(() => sockets.Count == 2);
        Assert.Equal("6", queries[1]["since"]);
        Assert.Contains(phases, p => p is TerminalConnection.Phase.Reconnecting);
        sockets[1].Push(new TerminalFrame.Text("""{"type":"ready","offset":6,"shell":"zsh","resumed":true}"""));
        await Until(() => connection.CurrentPhase is TerminalConnection.Phase.Live);
        Assert.Equal(0, resets);

        // End Shell: the end message, then exit, then the 1000 close: Ended, no more dials.
        connection.EndShell();
        Assert.Contains(sockets[1].Sent, f => f is TerminalFrame.Text { Value: TerminalWire.End });
        sockets[1].Push(new TerminalFrame.Text("""{"type":"exit","code":0}"""));
        sockets[1].Drop(1000);
        await Until(() => connection.CurrentPhase is TerminalConnection.Phase.Ended);
        Assert.Equal(new TerminalConnection.Phase.Ended(0), connection.CurrentPhase);
        await Task.Delay(100);
        Assert.Equal(2, sockets.Count);
        connection.Stop();
    }

    [Fact]
    public async Task TheConnectionStopsOnARefusalAndGivesUpOnAShellItNeverReached()
    {
        TerminalConnection.Backoff = _ => TimeSpan.FromMilliseconds(5);
        var replaced = new TerminalConnection(TerminalWire.NewSession(), (q, ct) =>
        {
            var s = new FakeSocket();
            s.Drop(4409);
            return Task.FromResult<ITerminalSocket>(s);
        });
        replaced.Start(80, 24);
        await Until(() => replaced.CurrentPhase is TerminalConnection.Phase.Stopped);
        Assert.Equal(TerminalWire.EndingKind.Replaced, ((TerminalConnection.Phase.Stopped)replaced.CurrentPhase).Ending.Kind);

        var dials = 0;
        var never = new TerminalConnection(TerminalWire.NewSession(), (q, ct) =>
        {
            Interlocked.Increment(ref dials);
            return Task.FromException<ITerminalSocket>(new IOException("refused"));
        });
        never.Start(80, 24);
        await Until(() => never.CurrentPhase is TerminalConnection.Phase.Stopped);
        Assert.Equal(TerminalWire.EndingKind.Unreachable, ((TerminalConnection.Phase.Stopped)never.CurrentPhase).Ending.Kind);
        Assert.Equal(TerminalConnection.GiveUpAfter, dials);
    }

    [Fact]
    public async Task AnOffsetBehindTheScreenClearsIt()
    {
        var socket = new FakeSocket();
        var connection = new TerminalConnection(TerminalWire.NewSession(), (q, ct) => Task.FromResult<ITerminalSocket>(socket));
        var resets = 0;
        connection.Reset += () => resets++;
        connection.Start(80, 24);
        socket.Push(new TerminalFrame.Text("""{"type":"ready","offset":4096,"shell":"bash"}"""));
        await Until(() => connection.CurrentPhase is TerminalConnection.Phase.Live);
        Assert.Equal(1, resets);
        Assert.Equal(4096, connection.Shown);
        connection.Stop();
        Assert.True(socket.Closed);
    }
}
