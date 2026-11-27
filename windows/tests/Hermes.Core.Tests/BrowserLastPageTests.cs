// Watch Browser's last page (HermesKit/Browser/BrowserLastPage.swift; Tests/Browser/BrowserLastPageTests.swift):
// once a bot's browser closes, the viewer shows the last frame it drew, still, with the time, instead of "Browser
// Closed". One picture per bot of each account, kept a week, gone with the account on sign-out. On Windows a picture
// reaches disk only through a protector (DPAPI in the app); without one it stays in memory. Synthetic bytes only.

using System.Globalization;
using System.Text;
using Hermes.Core.Browser;

namespace Hermes.Core.Tests;

public sealed class BrowserLastPageTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "last-page-tests-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        try { if (Directory.Exists(_dir)) Directory.Delete(_dir, recursive: true); } catch (IOException) { }
    }

    private static BrowserLastPage Page(string? url = "https://shop.example.com/washers", string? session = "chat-1",
                                        DateTimeOffset? at = null, int bytes = 64) =>
        new(Enumerable.Repeat((byte)0xAB, bytes).ToArray(), 1280, 800, url, "Washers", session, at ?? DateTimeOffset.UtcNow);

    /// A stand-in for DPAPI: reversible, marks its output, counts calls, and can refuse (another user, tampering).
    private sealed class FakeProtector : IBrowserLastPageProtector
    {
        public int Protected;
        public bool Refuse;
        private static readonly byte[] Mark = "PROT1"u8.ToArray();
        public byte[] Protect(byte[] plain)
        {
            Interlocked.Increment(ref Protected);
            return Mark.Concat(plain.Select(b => (byte)(b ^ 0x5A))).ToArray();
        }
        public byte[]? Unprotect(byte[] stored)
        {
            if (Refuse || stored.Length < Mark.Length || !stored.AsSpan(0, Mark.Length).SequenceEqual(Mark)) return null;
            return stored.Skip(Mark.Length).Select(b => (byte)(b ^ 0x5A)).ToArray();
        }
    }

    private BrowserLastPages Store(IBrowserLastPageProtector? protector, TimeSpan? writeEvery = null) =>
        new(_dir, protector, writeEvery ?? TimeSpan.FromSeconds(60));

    private string[] Files() => Directory.Exists(_dir) ? Directory.GetFiles(_dir, "*", SearchOption.AllDirectories) : [];

    [Fact]
    public void AKeptPageComesBackFromDiskAfterTheAppForgetsIt()
    {
        var store = Store(new FakeProtector());
        var kept = Page();
        store.Keep(kept, "acct-1", "ivy");
        Assert.Equal(kept, store.Page("acct-1", "ivy")); // in memory at once
        store.Flush("acct-1", "ivy");
        store.DebugDrain();
        store.DebugForgetMemory();
        Assert.Equal(kept, store.Page("acct-1", "ivy")); // flushed to disk: a relaunched app still has it
        Assert.Null(store.Page("acct-1", "wren")); // one picture per bot
        Assert.Null(store.Page("acct-2", "ivy")); // and per account
    }

    [Fact]
    public void ANewStoreOnTheSameFolderReadsTheFlushedPage()
    {
        var protector = new FakeProtector();
        var kept = Page();
        var first = Store(protector);
        first.Keep(kept, "acct-1", "ivy");
        first.Flush("acct-1", "ivy");
        first.DebugDrain();
        Assert.Equal(kept, Store(protector).Page("acct-1", "ivy"));
    }

    [Fact]
    public void AnUnflushedPageWaitsForItsWrite()
    {
        var store = Store(new FakeProtector());
        store.Keep(Page(), "acct-1", "ivy");
        store.DebugDrain();
        store.DebugForgetMemory();
        Assert.Null(store.Page("acct-1", "ivy")); // frames at 30 a second are not each written
        Assert.Empty(Files());
    }

    [Fact]
    public async Task FramesInAWindowAreWrittenOnceAndTheNewestLands()
    {
        var protector = new FakeProtector();
        var store = Store(protector, TimeSpan.FromMilliseconds(150));
        for (var i = 0; i < 20; i++) store.Keep(Page($"https://shop.example.com/{i}"), "a", "ivy");
        var deadline = DateTime.UtcNow.AddSeconds(5);
        while (protector.Protected == 0 && DateTime.UtcNow < deadline) await Task.Delay(20);
        await Task.Delay(300);
        store.DebugDrain();
        Assert.Equal(1, protector.Protected);
        store.DebugForgetMemory();
        Assert.Equal("https://shop.example.com/19", store.Page("a", "ivy")?.Url);
    }

    [Fact]
    public void TheNewestFrameWins()
    {
        var store = Store(new FakeProtector());
        store.Keep(Page("https://shop.example.com/one"), "a", "ivy");
        store.Keep(Page("https://shop.example.com/two"), "a", "ivy");
        store.Flush("a", "ivy");
        store.DebugDrain();
        store.DebugForgetMemory();
        Assert.Equal("https://shop.example.com/two", store.Page("a", "ivy")?.Url);
    }

    [Fact]
    public void AFlushWithNothingNewWritesNothing()
    {
        var protector = new FakeProtector();
        var store = Store(protector);
        store.Keep(Page(), "a", "ivy");
        store.Flush("a", "ivy");
        store.Flush("a", "ivy");
        store.Flush("a", "wren");
        store.DebugDrain();
        Assert.Equal(1, protector.Protected);
    }

    [Fact]
    public void AWeekOldPageIsDropped()
    {
        var store = Store(new FakeProtector());
        var now = DateTimeOffset.UtcNow;
        store.Keep(Page(at: now.AddDays(-8)), "a", "ivy");
        Assert.Null(store.Page("a", "ivy", now));
        store.Keep(Page(at: now.AddHours(-1)), "a", "ivy");
        Assert.NotNull(store.Page("a", "ivy", now)); // an hour old still shows
    }

    [Fact]
    public void AStalePageOnDiskIsDeletedOnRead()
    {
        var store = Store(new FakeProtector());
        var now = DateTimeOffset.UtcNow;
        store.Keep(Page(at: now.AddDays(-6)), "a", "ivy");
        store.Flush("a", "ivy");
        store.DebugDrain();
        store.DebugForgetMemory();
        Assert.Single(Files());
        Assert.Null(store.Page("a", "ivy", now.AddDays(2)));
        store.DebugDrain();
        Assert.Empty(Files());
    }

    [Fact]
    public void FreshnessIsAWeekWithAMinuteOfClockAhead()
    {
        var now = new DateTimeOffset(2026, 11, 16, 21, 30, 0, TimeSpan.Zero);
        Assert.True(Page(at: now).Fresh(now));
        Assert.True(Page(at: now - BrowserLastPage.KeptFor + TimeSpan.FromSeconds(1)).Fresh(now));
        Assert.False(Page(at: now - BrowserLastPage.KeptFor).Fresh(now)); // a week to the second is gone
        Assert.True(Page(at: now.AddSeconds(60)).Fresh(now)); // a phone clock a minute ahead
        Assert.False(Page(at: now.AddSeconds(61)).Fresh(now)); // further ahead is not believed
    }

    [Fact]
    public void SignOutTakesEveryPictureOfTheAccount()
    {
        var store = Store(new FakeProtector());
        foreach (var bot in new[] { "ivy", "wren" })
        {
            store.Keep(Page(), "leaving", bot);
            store.Flush("leaving", bot);
        }
        store.Keep(Page(), "staying", "ivy");
        store.Flush("staying", "ivy");
        store.Purge("leaving");
        store.DebugDrain();
        store.DebugForgetMemory();
        Assert.Null(store.Page("leaving", "ivy"));
        Assert.Null(store.Page("leaving", "wren"));
        Assert.NotNull(store.Page("staying", "ivy")); // another account's pictures stay
    }

    [Fact]
    public async Task APendingWriteDoesNotOutliveSignOut()
    {
        var protector = new FakeProtector();
        var store = Store(protector, TimeSpan.FromMilliseconds(100));
        store.Keep(Page(), "leaving", "ivy"); // a coalesced write is waiting
        store.Purge("leaving");
        Assert.Null(store.Page("leaving", "ivy")); // gone from memory at once
        await Task.Delay(400);
        store.DebugDrain();
        Assert.Equal(0, protector.Protected);
        Assert.Empty(Files());
        store.DebugForgetMemory();
        Assert.Null(store.Page("leaving", "ivy"));
    }

    [Fact]
    public async Task ManyFlushesRacingSignOutLeaveNothingOfTheAccount()
    {
        var store = Store(new FakeProtector(), TimeSpan.FromMilliseconds(5));
        store.Keep(Page(), "staying", "ivy");
        store.Flush("staying", "ivy");
        var writers = Enumerable.Range(0, 8).Select(t => Task.Run(() =>
        {
            for (var i = 0; i < 50; i++)
            {
                store.Keep(Page($"https://shop.example.com/{t}/{i}"), "leaving", $"bot{t}");
                if (i % 5 == 0) store.Flush("leaving", $"bot{t}");
            }
        })).ToArray();
        await Task.WhenAll(writers);
        store.Purge("leaving");
        await Task.Delay(100); // any timer that was already due has run
        store.DebugDrain();
        store.DebugForgetMemory();
        for (var t = 0; t < 8; t++) Assert.Null(store.Page("leaving", $"bot{t}"));
        Assert.NotNull(store.Page("staying", "ivy"));
        Assert.All(Files(), f => Assert.StartsWith(Path.Combine(_dir, BrowserLastPages.Key("staying")), f));
    }

    /// Holds Unprotect until released: a disk read caught mid-way.
    private sealed class HeldProtector : IBrowserLastPageProtector
    {
        private readonly FakeProtector _inner = new();
        public readonly ManualResetEventSlim Reading = new();
        public readonly ManualResetEventSlim Release = new(initialState: true);
        public byte[] Protect(byte[] plain) => _inner.Protect(plain);
        public byte[]? Unprotect(byte[] stored)
        {
            Reading.Set();
            Release.Wait(TimeSpan.FromSeconds(10));
            return _inner.Unprotect(stored);
        }
    }

    [Fact]
    public async Task AReadCaughtBySignOutDoesNotBringThePictureBack()
    {
        var protector = new HeldProtector();
        var store = Store(protector);
        store.Keep(Page(), "leaving", "ivy");
        store.Flush("leaving", "ivy");
        store.DebugDrain();
        store.DebugForgetMemory(); // a relaunch: the picture is on disk only
        protector.Release.Reset();
        var reading = Task.Run(() => store.Page("leaving", "ivy"));
        Assert.True(protector.Reading.Wait(TimeSpan.FromSeconds(10)));
        store.Purge("leaving"); // sign-out while the file is being opened
        protector.Release.Set();
        Assert.Null(await reading);
        store.DebugDrain();
        Assert.Null(store.Page("leaving", "ivy")); // not left in memory either
        Assert.Empty(Files());
    }

    [Fact]
    public void NothingIsKeptWithoutAnAccountOrAPicture()
    {
        var store = Store(new FakeProtector());
        store.Keep(Page(), "", "ivy");
        store.Keep(Page(), "a", "");
        store.Keep(Page(bytes: 0), "a", "ivy");
        Assert.Null(store.Page("", "ivy"));
        Assert.Null(store.Page("a", ""));
        Assert.Null(store.Page("a", "ivy"));
    }

    [Fact]
    public void APictureLargerThanAFrameIsNotKept()
    {
        var store = Store(new FakeProtector());
        store.Keep(Page(bytes: BrowserLastPage.MaxImage + 1), "a", "ivy");
        Assert.Null(store.Page("a", "ivy"));
        store.Keep(Page(bytes: BrowserLastPage.MaxImage), "a", "ivy");
        Assert.NotNull(store.Page("a", "ivy")); // exactly the frame limit is kept
    }

    [Fact]
    public void WithoutAProtectorPicturesStayInMemoryOnly()
    {
        var store = Store(protector: null);
        var kept = Page();
        store.Keep(kept, "a", "ivy");
        store.Flush("a", "ivy");
        store.DebugDrain();
        Assert.Equal(kept, store.Page("a", "ivy"));
        Assert.Empty(Files()); // never plaintext on disk
        store.DebugForgetMemory();
        Assert.Null(store.Page("a", "ivy"));
    }

    [Fact]
    public void TheFileOnDiskIsProtectedAndNamedByKey()
    {
        var store = Store(new FakeProtector());
        store.Keep(Page("https://shop.example.com/secret-washers"), "acct-1@example.com", "ivy");
        store.Flush("acct-1@example.com", "ivy");
        store.DebugDrain();
        var file = Assert.Single(Files());
        var raw = File.ReadAllBytes(file);
        Assert.StartsWith("PROT1", Encoding.ASCII.GetString(raw, 0, 5));
        Assert.DoesNotContain("secret-washers", Encoding.UTF8.GetString(raw));
        Assert.DoesNotContain("example.com", file); // neither the account nor the bot names a path
        Assert.DoesNotContain("ivy", Path.GetFileName(file));
        Assert.Equal(Path.Combine(_dir, BrowserLastPages.Key("acct-1@example.com"), BrowserLastPages.Key("ivy") + ".json"), file);
    }

    [Fact]
    public void APictureThatCannotBeUnprotectedIsNotShown()
    {
        var protector = new FakeProtector();
        var store = Store(protector);
        store.Keep(Page(), "a", "ivy");
        store.Flush("a", "ivy");
        store.DebugDrain();
        store.DebugForgetMemory();
        protector.Refuse = true; // another Windows user, or a tampered file
        Assert.Null(store.Page("a", "ivy"));
        protector.Refuse = false;
        File.WriteAllBytes(Assert.Single(Files()), "PROT1garbage"u8.ToArray());
        Assert.Null(store.Page("a", "ivy"));
    }

    [Fact]
    public void KeysAreShortStableHex()
    {
        var key = BrowserLastPages.Key("acct-1");
        Assert.Equal(24, key.Length);
        Assert.Matches("^[0-9a-f]{24}$", key);
        Assert.Equal(key, BrowserLastPages.Key("acct-1"));
        Assert.NotEqual(key, BrowserLastPages.Key("acct-2"));
        // SHA-256("ivy"), first 12 bytes in lowercase hex: the same name the Mac gives the file.
        Assert.Equal(Sha24("ivy"), BrowserLastPages.Key("ivy"));
        Assert.Equal(Sha24("é"), BrowserLastPages.Key("é")); // UTF-8, as the Mac hashes it
    }

    private static string Sha24(string text) =>
        Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(text)))[..24];

    [Fact]
    public void AnotherChatOfTheBotShowsOnlyItsOwnPage()
    {
        var kept = Page(session: "chat-1");
        Assert.True(kept.Fits(chatOnly: false, sessionIds: [])); // the bot's own viewer: any page of the bot
        Assert.True(kept.Fits(chatOnly: true, sessionIds: ["chat-1"]));
        Assert.False(kept.Fits(chatOnly: true, sessionIds: ["chat-2"]));
        Assert.False(Page(session: null).Fits(chatOnly: true, sessionIds: ["chat-1"]));
        Assert.False(Page(session: "").Fits(chatOnly: true, sessionIds: [""]));
    }

    [Fact]
    public void TheLastPageTakesThePlaceOfNoBrowserOnly()
    {
        Assert.True(BrowserLastPage.Replaces(null)); // still asking the add-on, or an older add-on
        foreach (var status in new[] { "cloud", "hosted", "real_profile", "released", "error" })
            Assert.True(BrowserLastPage.Replaces(status), status + ": no browser open");
        foreach (var status in new[] { "ready", "starting", "external", "unknown", "not_responding", "off" })
            Assert.False(BrowserLastPage.Replaces(status), status + ": its own words stay");
    }

    [Fact]
    public void TheCaptionSaysWhen()
    {
        var zone = TimeZoneInfo.FindSystemTimeZoneById("America/Chicago");
        var culture = CultureInfo.GetCultureInfo("en-US");
        DateTimeOffset Local(int day, int hour, int minute)
        {
            var wall = new DateTime(2026, 11, day, hour, minute, 0, DateTimeKind.Unspecified);
            return new DateTimeOffset(wall, zone.GetUtcOffset(wall));
        }
        var now = Local(16, 21, 30);
        string Words(DateTimeOffset at) =>
            BrowserLastPage.Caption("Ivy", at, now, zone, culture).Replace('\u202F', ' ').Replace('\u00A0', ' ');
        Assert.Equal("Ivy’s browser has closed. This is the last page it showed, at 9:01 PM.", Words(Local(16, 21, 1)));
        Assert.Equal("Ivy’s browser has closed. This is the last page it showed, yesterday at 8:05 AM.", Words(Local(15, 8, 5)));
        Assert.Equal("Ivy’s browser has closed. This is the last page it showed, on Nov 12, 2026 at 2:00 PM.", Words(Local(12, 14, 0)));
        // The day is the viewer's: 11:30 PM in Chicago on the 15th is 05:30 UTC on the 16th, still "yesterday".
        Assert.Equal("Ivy’s browser has closed. This is the last page it showed, yesterday at 11:30 PM.",
                     Words(Local(15, 23, 30).ToUniversalTime()));
    }

    [Fact]
    public void TheHostIsTheAddressFieldsSite()
    {
        Assert.Equal("shop.example.com", Page("https://www.shop.example.com/washers").Host);
        Assert.Equal("shop.example.com:8443", Page("https://shop.example.com:8443/x").Host);
        Assert.Equal("", Page(null).Host);
        Assert.Equal("", Page("").Host);
        Assert.Equal("New Tab", Page("about:blank").Host);
        Assert.Equal("Local page", Page("data:text/html,hi").Host);
    }
}
