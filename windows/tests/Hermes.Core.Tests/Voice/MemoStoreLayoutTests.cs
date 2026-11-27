// [WIN-VOICE-FILES-UPLOAD] Tests/Voice/MemoStoreLayoutTests.swift at 93f984bb1, case for case: A-U5 (stores) and A-U7
// (waveform). Not ported: `speedCyclesAndPersists` (MemoPlayer and MemoBubbleView, the player/UI slice) and the whole
// "Memo row layout (A-U6)" suite (heightMatchesWhatIsDrawn, clampedTranscriptOpensWithMoreAndLess,
// playingAndSpeedNeverChangeTheHeight, barCountFollowsTheWidth, historyMemoRowsCarryTheirWords): they measure UIKit
// cells, MemoBubbleLayout and MemoPlayer, which belong to the memo UI slice.

using System.Text;
using System.Text.Json;
using Hermes.Core.Voice;

namespace Hermes.Core.Tests.Voice;

public sealed class MemoStoreTests : IDisposable
{
    private readonly VoiceTestStores _t = new();
    public void Dispose() => _t.Dispose();

    private static string NewKey() => MemoPaths.AccountKey($"store-test-{Guid.NewGuid()}");

    [Fact]
    public void ShapesKeepTheNewest64AndLinkLocalToGateway()
    {
        var key = NewKey();
        var shapes = new MemoShapeStore(_t.Paths, key);
        var peaks = Enumerable.Repeat(0.5, 48).ToArray();
        for (var i = 0; i < 70; i++) shapes.Remember($"/p/{i}.m4a", peaks, i + 1);
        Assert.Equal(64, shapes.Count);
        Assert.NotNull(shapes.Shape("/p/69.m4a"));
        shapes.Remember("/local/voice-memo.m4a", peaks, 3);
        shapes.Link("/local/voice-memo.m4a", "/gateway/voice-memo-2.m4a");
        Assert.Equal(3, shapes.Shape("/gateway/voice-memo-2.m4a")?.Seconds);
        // Persisted: a new store for the account reads them back.
        MemoDisk.Flush();
        Assert.Equal(peaks, new MemoShapeStore(_t.Paths, key).Shape("/gateway/voice-memo-2.m4a")?.Peaks);
        // Wrong shapes are refused.
        shapes.Remember("/bad.m4a", [0.1], 1);
        Assert.Null(shapes.Shape("/bad.m4a"));
    }

    [Fact]
    public void DraftsRoundTripNewestFirstAndNeverLoseARecording()
    {
        var accountId = $"draft-test-{Guid.NewGuid()}";
        var key = MemoPaths.AccountKey(accountId);
        var drafts = new MemoDraftStore(_t.Paths, key);
        var first = _t.Recording(accountId);
        var second = _t.Recording(accountId, seconds: 3);
        drafts.Set(first, "acct|ivy|s1");
        MemoDisk.Flush();
        Assert.Equal(first, new MemoDraftStore(_t.Paths, key).Draft("acct|ivy|s1")); // survives relaunch
        // A memo handed back goes in front; the earlier draft waits behind it, its recording kept.
        drafts.Set(second, "acct|ivy|s1");
        Assert.Equal(second, drafts.Draft("acct|ivy|s1"));
        Assert.True(File.Exists(first.Path));
        // Taking it to send leaves the file; the earlier draft shows next.
        Assert.Equal(second, drafts.Take("acct|ivy|s1"));
        Assert.Equal(first, drafts.Draft("acct|ivy|s1"));
        Assert.True(File.Exists(second.Path));
        // Remove: the shown draft goes, with its recording.
        drafts.Set(null, "acct|ivy|s1");
        Assert.Null(drafts.Draft("acct|ivy|s1"));
        Assert.False(File.Exists(first.Path));
        // Queued memos handed back when their chat was left: oldest first, with their words.
        var third = _t.Recording(accountId, seconds: 4);
        drafts.Set(second, "acct|ivy|s2");
        drafts.Restore([new MemoDraft(third, "and the eggs"), new MemoDraft(second, "")], "acct|ivy|s2");
        Assert.Equal(third, drafts.Draft("acct|ivy|s2"));
        Assert.Equal("and the eggs", drafts.Text("acct|ivy|s2"));
        drafts.ClearText("acct|ivy|s2");
        Assert.Null(drafts.Text("acct|ivy|s2"));
        Assert.Equal(third, drafts.Take("acct|ivy|s2"));
        Assert.Equal(second, drafts.Take("acct|ivy|s2")); // the same recording isn't listed twice
        Assert.Null(drafts.Draft("acct|ivy|s2"));
        // A bot chat opened before its id was known finds its draft once it knows it.
        drafts.Set(second, "acct|default|");
        Assert.Equal(second, drafts.Draft("acct|default|20261010_1"));
        Assert.False(drafts.All.ContainsKey("acct|default|"));
        // A draft whose file is gone is dropped on load.
        File.Delete(second.Path);
        MemoDisk.Flush();
        Assert.Null(new MemoDraftStore(_t.Paths, key).Draft("acct|default|20261010_1"));
    }

    /// The app's data folder can move: a draft saved under the old path is found under today's.
    [Fact]
    public void DraftsFollowAMovedContainer()
    {
        var accountId = $"rebase-{Guid.NewGuid()}";
        var key = MemoPaths.AccountKey(accountId);
        var memo = _t.Recording(accountId);
        var tail = memo.Path.Replace('\\', '/').Split("/memos/").Last();
        var moved = memo with { Path = "/var/mobile/Containers/Data/Application/OLD-UUID/Library/Application Support/memos/" + tail };
        var file = Path.Combine(_t.Paths.Memos(key), MemoPaths.DraftsFile);
        _t.Paths.Ensure(Path.GetDirectoryName(file)!);
        File.WriteAllBytes(file, JsonSerializer.SerializeToUtf8Bytes(
            new Dictionary<string, List<MemoDraft>> { ["acct|ivy|s1"] = [new MemoDraft(moved)] }));
        Assert.Equal(memo.Path, new MemoDraftStore(_t.Paths, key).Draft("acct|ivy|s1")?.Path);
        // A drafts file written before drafts were lists still reads.
        MemoDisk.Flush();
        File.WriteAllBytes(file, JsonSerializer.SerializeToUtf8Bytes(new Dictionary<string, MemoFile> { ["acct|ivy|s1"] = memo }));
        Assert.Equal(memo, new MemoDraftStore(_t.Paths, key).Draft("acct|ivy|s1"));
    }

    /// memos/ and memos/<key>/ are protected on every sign-in; recordings no draft refers to go once a day old (a crash
    /// or a kill mid-send).
    [Fact]
    public async Task SignInExcludesBackupsAndSweepsOrphans()
    {
        var accountId = $"sweep-{Guid.NewGuid()}";
        var key = MemoPaths.AccountKey(accountId);
        var kept = _t.Recording(accountId);
        var orphan = _t.Recording(accountId);
        var fresh = _t.Recording(accountId);
        var old = DateTime.UtcNow.AddSeconds(-2 * 86_400);
        foreach (var memo in new[] { kept, orphan })
        {
            File.SetLastWriteTimeUtc(memo.Path, old);
            Directory.SetLastWriteTimeUtc(Path.GetDirectoryName(memo.Path)!, old);
        }
        var drafts = new MemoDraftStore(_t.Paths, key);
        drafts.Set(kept, "acct|ivy|s1");
        MemoDisk.Flush();
        _t.Stores.Deactivate(purge: false);
        _t.Stores.Activate(accountId);
        await _t.Stores.SweepTask!;
        Assert.True(File.Exists(kept.Path), "a draft's recording stays");
        Assert.True(File.Exists(fresh.Path), "a recording under a day old stays");
        Assert.False(Directory.Exists(Path.GetDirectoryName(orphan.Path)), "an old recording nothing refers to goes");
        foreach (var folder in new[] { _t.Paths.MemosRoot, _t.Paths.Memos(key) })
            Assert.True(_t.Guard.Protected(folder), Path.GetFileName(folder));
    }

    [Fact]
    public void PlaybackCacheIsLRUAndPurges()
    {
        var key = NewKey();
        var cache = new MemoPlaybackCache(_t.Paths, key, maxFiles: 3, maxBytes: 1 << 20);
        _t.Paths.Ensure(cache.Folder);
        for (var i = 0; i < 5; i++)
        {
            var url = cache.CacheUrl($"/g/voice-memo-{i}.m4a");
            File.WriteAllBytes(url, Enumerable.Repeat((byte)i, 10).ToArray());
            File.SetLastWriteTimeUtc(url, DateTime.UtcNow.AddSeconds(i - 10));
        }
        // Touch the oldest: it becomes the newest.
        Assert.NotNull(cache.Local("/g/voice-memo-0.m4a"));
        cache.Evict();
        Assert.Equal(3, cache.FileCount);
        Assert.NotNull(cache.Local("/g/voice-memo-0.m4a"));
        Assert.Null(cache.Local("/g/voice-memo-1.m4a"));
        Assert.NotNull(cache.Local("/g/voice-memo-4.m4a"));
        // Adopt: the recording moves in under its gateway path.
        var recording = _t.Recording($"cache-{key}");
        cache.Adopt(recording.Path, "/g/voice-memo-9.wav");
        Assert.NotNull(cache.Local("/g/voice-memo-9.wav"));
        Assert.False(File.Exists(recording.Path));
        cache.Purge();
        Assert.Equal(0, cache.FileCount);
    }

    [Fact]
    public void SignOutPurgesTheAccountsMemos()
    {
        var accountId = $"purge-{Guid.NewGuid()}";
        var recording = _t.Recording(accountId);
        var cache = new MemoPlaybackCache(_t.Paths, MemoPaths.AccountKey(accountId));
        _t.Paths.Ensure(cache.Folder);
        File.WriteAllBytes(cache.CacheUrl("/g/v.m4a"), [1]);
        _t.Paths.Purge(accountId);
        Assert.False(File.Exists(recording.Path));
        Assert.Equal(0, cache.FileCount);
    }

    // Windows additions: the exact on-disk names the Mac uses.
    [Fact]
    public void LayoutOnDiskIsTheMacs()
    {
        Assert.Equal("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", MemoPaths.Hex("abc"));
        Assert.Equal("ba7816bf8f01cfea", MemoPaths.AccountKey("abc"));
        var key = MemoPaths.AccountKey("acct-1");
        var recording = _t.Paths.NewRecording(key, "m4a");
        var parts = Path.GetRelativePath(_t.Paths.SupportBase, recording).Split(Path.DirectorySeparatorChar);
        Assert.Equal("memos", parts[0]);
        Assert.Equal(key, parts[1]);
        Assert.Matches("^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$", parts[2]);
        Assert.Equal("voice-memo.m4a", parts[3]);
        var cache = new MemoPlaybackCache(_t.Paths, key);
        Assert.Equal(Path.Combine(_t.Paths.CachesBase, "memos", key, MemoPaths.Hex("/g/Voice.M4A") + ".m4a"), cache.CacheUrl("/g/Voice.M4A"));
        Assert.Equal(Path.Combine(cache.Folder, MemoPaths.Hex("/g/noext")), cache.CacheUrl("/g/noext"));
        Assert.True(_t.Paths.IsLocal(recording));
        Assert.False(_t.Paths.IsLocal("/Users/owner/.hermes/profiles/ivy/attachments/voice-memo.m4a"));
    }
}

public sealed class MemoWaveformTests
{
    private static string Write(byte[] data)
    {
        var url = Path.Combine(Path.GetTempPath(), $"wave-{Guid.NewGuid()}.wav");
        File.WriteAllBytes(url, data);
        return url;
    }

    [Fact]
    public void ComputesFortyEightPeaksAndTheLength()
    {
        var url = Write(VoiceFixtures.FixtureWave(3, [0.2, 0.9, 0.4, 0.1, 0.6]));
        try
        {
            var (peaks, seconds) = MemoWaveform.Compute(url, WavMemoAudio.Decoder);
            Assert.Equal(48, peaks.Count);
            Assert.All(peaks, p => Assert.InRange(p, 0, 1));
            Assert.Equal(1, peaks.Max());
            Assert.True(Math.Abs(seconds - 3) < 0.02, $"{seconds}");
        }
        finally { File.Delete(url); }
    }

    [Fact]
    public void RefusesOverLongAudio()
    {
        // 700 s at 2 kHz, 16-bit mono (a valid WAV header and silence).
        const int rate = 2000, frames = 700 * rate;
        var url = Write(VoiceFixtures.Wave(rate, new byte[frames * 2]));
        try
        {
            var error = Assert.Throws<MemoWaveformException>(() => MemoWaveform.Compute(url, WavMemoAudio.Decoder));
            Assert.Equal("Audio is empty or exceeds the memo limit.", error.Message);
        }
        finally { File.Delete(url); }
    }
}
