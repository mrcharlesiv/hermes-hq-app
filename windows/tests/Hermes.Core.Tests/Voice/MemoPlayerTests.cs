// [WIN-VOICE-PLAYER] Tests/Voice/MemoPlayerTests.swift at 93f984bb1, case for case (the first four), then the rest of
// MemoPlayer.swift's behaviour the Mac suite leaves to its device runs: speed, pause/resume, seek, the end, decode
// errors, interruption / route loss / background / media reset, preemption, session refusal, failures and the two
// resolvers. MemoPlayer builds and primes its player off the main thread; a stop or another memo while that runs must
// win. The player runs on the Mac's main actor (Screen/FakeDisplay.cs MainLoop); the audio is Voice/FakeMemoAudio.cs.

using Hermes.Core.Composer;
using Hermes.Core.Net;
using Hermes.Core.Tests.Screen;
using Hermes.Core.Voice;

namespace Hermes.Core.Tests.Voice;

public sealed class MemoPlayerTests : IDisposable
{
    private readonly MainLoop _loop = new();
    private readonly FakeMemoOutput _output = new();
    private readonly FakeMemoSession _session = new();
    private readonly FakeMemoSystem _system = new();
    private readonly MemoryStore _defaults = new();
    private readonly MemoPlayer _player;
    private readonly List<string?> _posts = [];
    private readonly string _folder = Path.Combine(Path.GetTempPath(), $"memo-player-tests-{Guid.NewGuid()}");

    public MemoPlayerTests()
    {
        Directory.CreateDirectory(_folder);
        _player = _loop.Read(() =>
        {
            var player = new MemoPlayer(_output, _session, _system, _defaults);
            player.Changed += path => _posts.Add(path);
            return player;
        });
    }

    public void Dispose()
    {
        _loop.Run(_player.Stop);
        Assert.Empty(_loop.Failures);
        _loop.Dispose();
        try { Directory.Delete(_folder, recursive: true); } catch (IOException) { }
    }

    private T On<T>(Func<MemoPlayer, T> read) => _loop.Read(() => read(_player));
    private void On(Action<MemoPlayer> act) => _loop.Run(() => act(_player));
    private Task<bool> Until(Func<MemoPlayer, bool> condition) => VoiceFixtures.WaitUntil(() => On(condition));
    private IReadOnlyList<string?> Posts => _loop.Read(() => _posts.ToArray());

    private string Wave(double seconds = 2)
    {
        var path = Path.Combine(_folder, $"memo-player-{Guid.NewGuid()}.wav");
        File.WriteAllBytes(path, VoiceFixtures.FixtureWave(seconds, [0.3, 0.6, 0.9]));
        return path;
    }

    private static Func<Task<string>> Resolve(string file) => () => Task.FromResult(file);

    /// Plays `path` and waits until its track really plays.
    private async Task<FakeMemoTrack> Playing(string path)
    {
        On(p => p.Play(path, Resolve(path)));
        Assert.True(await Until(p => p.StateOf(path) == MemoPlayState.Playing));
        Assert.True(await VoiceFixtures.WaitUntil(() => _loop.Read(() => _output.Opened.LastOrDefault()?.Playing == true)));
        return _loop.Read(() => _output.Opened.Last());
    }

    // MARK: The Mac's cases

    [Fact]
    public async Task PlayLoadsThenPlays()
    {
        var url = Wave();
        var loading = On(p => { p.Play(url, Resolve(url)); return p.StateOf(url); });
        Assert.Equal(MemoPlayState.Loading, loading);
        Assert.True(await Until(p => p.StateOf(url) == MemoPlayState.Playing));
        Assert.True(On(p => p.Duration) > 1.5);
    }

    [Fact]
    public async Task AStopWhileThePlayerIsBuiltNeverStartsIt()
    {
        _output.OpenDelay = TimeSpan.FromMilliseconds(150);
        var url = Wave();
        On(p => { p.Play(url, Resolve(url)); p.Stop(); });
        await _output.Drain();
        await Task.Delay(200);
        Assert.False(On(p => p.IsCurrent(url)));
        Assert.Equal(MemoPlayState.Idle, On(p => p.StateOf(url)));
        Assert.Equal(0, On(p => p.Duration));
        // Windows: the track that was built is never played, nor held.
        Assert.All(_output.Opened, t => Assert.Equal(0, t.Plays));
    }

    [Fact]
    public async Task AnotherMemoWhileTheFirstIsBuiltKeepsTheNewerOne()
    {
        var first = Wave();
        var second = Wave(3);
        On(p => { p.Play(first, Resolve(first)); p.Play(second, Resolve(second)); });
        Assert.True(await Until(p => p.StateOf(second) == MemoPlayState.Playing));
        await Task.Delay(200);
        Assert.True(On(p => p.IsCurrent(second)));
        Assert.Equal(MemoPlayState.Idle, On(p => p.StateOf(first)));
        Assert.True(On(p => p.Duration) > 2.5);
    }

    [Fact]
    public async Task AnUnreadableFileIsALoadFailure()
    {
        var url = Path.Combine(_folder, $"memo-player-bad-{Guid.NewGuid()}.m4a");
        File.WriteAllText(url, "not audio");
        On(p => p.Play(url, Resolve(url)));
        Assert.True(await VoiceFixtures.WaitUntil(() => MemoLoadFailures.Contains(url)));
        Assert.False(On(p => p.IsCurrent(url)));
        MemoLoadFailures.Remove(url);
    }

    // MARK: Windows: the rest of MemoPlayer.swift

    [Fact]
    public async Task SpeedIsRememberedAppWideAndCycles()
    {
        Assert.Equal("hq.voice.memoSpeed", MemoPlayer.SpeedKey);
        Assert.Equal([1, 1.5, 2], MemoPlayer.Speeds);
        Assert.Equal(1, On(p => p.Speed));
        _defaults.Set(MemoPlayer.SpeedKey, "1.25");   // not a step: 1×
        Assert.Equal(1, On(p => p.Speed));
        var track = await Playing(Wave());
        Assert.Equal(1, _loop.Read(() => track.Rate));
        var seen = new List<double>();
        for (var i = 0; i < 3; i++) seen.Add(On(p => { p.CycleSpeed(); return p.Speed; }));
        Assert.Equal([1.5, 2, 1], seen);
        On(p => p.CycleSpeed());
        Assert.Equal("1.5", _defaults.Get(MemoPlayer.SpeedKey));
        Assert.Equal(1.5, _loop.Read(() => track.Rate));
        // A new player reads it back (UserDefaults).
        Assert.Equal(1.5, _loop.Read(() => new MemoPlayer(_output, _session, _system, _defaults).Speed));
    }

    [Fact]
    public async Task PauseKeepsThePlaceGivesTheSessionBackAndPlayResumesTheSameTrack()
    {
        var url = Wave();
        var track = await Playing(url);
        Assert.Equal(1, _session.Acquires);
        _loop.Run(() => track.CurrentTime = 0.8);
        On(p => p.Pause());
        Assert.Equal(MemoPlayState.Paused, On(p => p.StateOf(url)));
        Assert.False(_loop.Read(() => track.Playing));
        var releases = _session.Releases;
        Assert.Equal(0.8, On(p => p.CurrentTime(url)));
        Assert.Equal(0, On(p => p.CurrentTime("/elsewhere.wav")));
        Assert.Equal(MemoPlayState.Idle, On(p => p.StateOf("/elsewhere.wav")));
        On(p => p.Play(url, Resolve(url)));
        Assert.True(await VoiceFixtures.WaitUntil(() => _loop.Read(() => track.Playing)));
        Assert.Single(_output.Opened);
        Assert.Equal(2, _session.Acquires);
        Assert.Equal(releases, _session.Releases);
        Assert.Equal(0.8, _loop.Read(() => track.CurrentTime));
    }

    [Fact]
    public async Task ToggleAndAPauseWhileLoadingStops()
    {
        var url = Wave();
        _output.OpenDelay = TimeSpan.FromMilliseconds(150);
        var state = On(p => { p.Toggle(url, Resolve(url)); p.Pause(); return p.StateOf(url); });
        Assert.Equal(MemoPlayState.Idle, state);
        Assert.False(On(p => p.IsCurrent(url)));
        _output.OpenDelay = TimeSpan.Zero;
        On(p => p.Toggle(url, Resolve(url)));
        Assert.True(await Until(p => p.StateOf(url) == MemoPlayState.Playing));
        On(p => p.Toggle(url, Resolve(url)));
        Assert.Equal(MemoPlayState.Paused, On(p => p.StateOf(url)));
    }

    [Fact]
    public async Task SeekMovesALoadedMemoAndStartsAnUnloadedOneThere()
    {
        var url = Wave(2);
        On(p => p.Seek(url, 0.25, Resolve(url)));
        Assert.True(await Until(p => p.StateOf(url) == MemoPlayState.Playing));
        var track = _loop.Read(() => _output.Opened.Single());
        Assert.Equal(0.5, _loop.Read(() => track.CurrentTime), 6);
        var posted = Posts.Count;
        On(p => p.Seek(url, 7, Resolve(url)));    // clamped to the end
        Assert.Equal(2, _loop.Read(() => track.CurrentTime), 6);
        Assert.Equal(posted + 1, Posts.Count);
        Assert.Equal(url, Posts[^1]);
        On(p => p.Seek(url, -1, Resolve(url)));
        Assert.Equal(0, On(p => p.CurrentTime(url)));
        Assert.Single(_output.Opened);
        // Play from a fraction of the memo already held moves there and plays.
        On(p => { p.Pause(); p.Play(url, Resolve(url), 0.5); });
        Assert.Equal(1, _loop.Read(() => track.CurrentTime), 6);
        Assert.Equal(MemoPlayState.Playing, On(p => p.StateOf(url)));
    }

    [Fact]
    public async Task TheEndGoesBackToTheStartPausedAndOnlyThePlayingTrackMayEndIt()
    {
        var first = Wave();
        var old = await Playing(first);
        var second = Wave(3);
        var track = await Playing(second);
        Assert.True(_loop.Read(() => old.Stopped));
        Assert.False(_loop.Read(() => old.Subscribed));
        await old.Finish();                       // memo A's callback, already queued
        await Task.Delay(100);
        Assert.Equal(MemoPlayState.Playing, On(p => p.StateOf(second)));
        var releases = _session.Releases;
        _loop.Run(() => track.CurrentTime = 2.9);
        await track.Finish();
        Assert.True(await Until(p => p.StateOf(second) == MemoPlayState.Paused));
        Assert.Equal(0, _loop.Read(() => track.CurrentTime));
        Assert.Equal(0, On(p => p.CurrentTime(second)));
        Assert.Equal(releases + 1, _session.Releases);
        Assert.True(On(p => p.IsCurrent(second)));
        // An end while paused changes nothing.
        await track.Finish();
        await Task.Delay(100);
        Assert.Equal(releases + 1, _session.Releases);
    }

    [Fact]
    public async Task ADecodeErrorIsALoadFailureOnlyForThePlayingTrack()
    {
        var first = Wave();
        var old = await Playing(first);
        var second = Wave();
        var track = await Playing(second);
        await old.FailDecode();
        await Task.Delay(100);
        Assert.True(On(p => p.IsCurrent(second)));
        Assert.False(MemoLoadFailures.Contains(first));
        await track.FailDecode();
        Assert.True(await Until(p => !p.IsCurrent(second)));
        Assert.Contains(second, On(p => p.Failed.ToArray()));
        Assert.True(MemoLoadFailures.Contains(second));
        Assert.Equal(second, Posts[^1]);
        Assert.True(_loop.Read(() => track.Stopped));
        // Playing it again clears the player's mark (the shared one waits for ForgetFailure).
        On(p => p.Play(second, Resolve(second)));
        Assert.DoesNotContain(second, On(p => p.Failed.ToArray()));
        Assert.True(MemoLoadFailures.Contains(second));
        On(p => p.ForgetFailure(second));
        Assert.False(MemoLoadFailures.Contains(second));
    }

    [Fact]
    public async Task InterruptionRouteLossAndTheBackgroundPauseAndNothingResumes()
    {
        var url = Wave();
        var track = await Playing(url);
        foreach (var pausing in new[] { MemoSystemEvent.InterruptionBegan, MemoSystemEvent.OldDeviceUnavailable, MemoSystemEvent.EnteredBackground })
        {
            if (!_loop.Read(() => track.Playing))
            {
                On(p => p.Play(url, Resolve(url)));
                Assert.True(await VoiceFixtures.WaitUntil(() => _loop.Read(() => track.Playing)));
            }
            var releases = _session.Releases;
            await _system.Raise(pausing);
            Assert.True(await Until(p => p.StateOf(url) == MemoPlayState.Paused));
            Assert.False(_loop.Read(() => track.Playing));
            Assert.Equal(releases + 1, _session.Releases);
        }
        // Never auto-resume on the interruption's end; another route change is not a pause.
        await _system.Raise(MemoSystemEvent.InterruptionEnded);
        await Task.Delay(100);
        Assert.Equal(MemoPlayState.Paused, On(p => p.StateOf(url)));
        On(p => p.Play(url, Resolve(url)));
        Assert.True(await VoiceFixtures.WaitUntil(() => _loop.Read(() => track.Playing)));
        await _system.Raise(MemoSystemEvent.RouteChanged);
        await Task.Delay(100);
        Assert.Equal(MemoPlayState.Playing, On(p => p.StateOf(url)));
        Assert.Single(_output.Opened);
    }

    [Fact]
    public async Task MediaServicesResettingStopsAndResetsTheSession()
    {
        var url = Wave();
        var track = await Playing(url);
        await _system.Raise(MemoSystemEvent.MediaServicesReset);
        Assert.True(await Until(p => !p.IsCurrent(url)));
        Assert.Equal(1, _session.Resets);
        Assert.True(_loop.Read(() => track.Stopped));
        Assert.Equal(0, On(p => p.Duration));
        Assert.False(MemoLoadFailures.Contains(url));
    }

    [Fact]
    public async Task RecordingTakingTheSessionPausesPlayback()
    {
        var url = Wave();
        await Playing(url);
        _loop.Run(() => _session.PlaybackPreempted!());
        Assert.Equal(MemoPlayState.Paused, On(p => p.StateOf(url)));
    }

    [Fact]
    public async Task ASessionThatCantBeHadOrAPlayerThatWontPlayIsALoadFailure()
    {
        var refused = Wave();
        _session.Refuse = true;
        On(p => p.Play(refused, Resolve(refused)));
        Assert.True(await VoiceFixtures.WaitUntil(() => MemoLoadFailures.Contains(refused)));
        Assert.False(On(p => p.IsCurrent(refused)));
        _session.Refuse = false;

        var silent = Wave();
        _output.PlayResult = false;
        On(p => p.Play(silent, Resolve(silent)));
        Assert.True(await VoiceFixtures.WaitUntil(() => MemoLoadFailures.Contains(silent)));
        Assert.Contains(silent, On(p => p.Failed.ToArray()));
        MemoLoadFailures.Remove(refused);
        MemoLoadFailures.Remove(silent);
    }

    [Fact]
    public async Task APauseBeforeTheSessionIsActiveNeverStartsTheSound()
    {
        var url = Wave();
        _session.AcquireDelay = TimeSpan.FromMilliseconds(400);
        On(p => p.Play(url, Resolve(url)));
        // Pause lands between the Pause button showing and the activation coming back.
        Assert.True(await VoiceFixtures.WaitUntil(() => _loop.Read(() =>
        {
            if (_player.StateOf(url) != MemoPlayState.Playing) return false;
            _player.Pause();
            return true;
        })));
        await Task.Delay(600);
        Assert.Equal(MemoPlayState.Paused, On(p => p.StateOf(url)));
        Assert.Equal(0, _loop.Read(() => _output.Opened.Single().Plays));
    }

    [Fact]
    public async Task AResolveThatFailsIsALoadFailureAndACancelledOneIsNot()
    {
        On(p => p.Play("/gone.m4a", () => Task.FromException<string>(new GatewayException("http", "HTTP 404", 404, "missing"))));
        Assert.True(await VoiceFixtures.WaitUntil(() => MemoLoadFailures.Contains("/gone.m4a")));
        Assert.False(On(p => p.IsCurrent("/gone.m4a")));
        Assert.Null(On(p => p.Path));
        MemoLoadFailures.Remove("/gone.m4a");

        On(p => p.Play("/switched.m4a", () => Task.FromException<string>(new OperationCanceledException())));
        await Task.Delay(100);
        Assert.False(MemoLoadFailures.Contains("/switched.m4a"));
        Assert.Equal(MemoPlayState.Loading, On(p => p.StateOf("/switched.m4a")));
    }

    [Fact]
    public void MarkFailedAndForgetFailurePostOnlyWhenSomethingChanged()
    {
        const string path = "/Users/owner/.hermes/profiles/ivy/attachments/voice-memo.m4a";
        On(p => p.MarkFailed(path));
        On(p => p.MarkFailed(path));
        Assert.Equal([path], Posts);
        Assert.True(MemoLoadFailures.Contains(path));
        On(p => p.ForgetFailure(path));
        On(p => p.ForgetFailure(path));
        Assert.Equal([path, path], Posts);
        Assert.False(MemoLoadFailures.Contains(path));
        Assert.Empty(On(p => p.Failed.ToArray()));
        // Stop with nothing held posts nothing.
        On(p => p.Stop());
        Assert.Equal(2, Posts.Count);
    }

    [Fact]
    public void TheNamesAreTheMacs()
    {
        Assert.Equal("hq.memo.player.changed", MemoPlayer.DidChangeName);
        Assert.Equal("path", MemoPlayer.PathKey);
        // One-thread: built off a UI thread with no context given, it refuses.
        Exception? refused = null;
        var thread = new Thread(() =>
        {
            try { _ = new MemoPlayer(_output, _session, _system, _defaults); }
            catch (InvalidOperationException e) { refused = e; }
        });
        thread.Start();
        thread.Join();
        Assert.NotNull(refused);
    }

    // MARK: Resolvers

    [Fact]
    public async Task TheLocalResolverAnswersTheFileOrA404()
    {
        var url = Wave();
        Assert.Equal(url, await MemoResolve.LocalFile(url)());
        var gone = await Assert.ThrowsAsync<GatewayException>(MemoResolve.LocalFile(url + ".gone"));
        Assert.Equal(404, gone.Status);
    }

    [Fact]
    public async Task TheChatResolverPlaysTheRecordingACachedCopyOrADownload()
    {
        using var stores = new VoiceTestStores();
        const string gatewayPath = "/Users/owner/.hermes/profiles/ivy/attachments/voice-memo-1.wav";
        var client = new VoiceFakeClient();
        var signedOut = await Assert.ThrowsAsync<GatewayException>(MemoResolve.Through(stores.Stores, gatewayPath, "ivy", client, _player));
        Assert.Equal(401, signedOut.Status);

        stores.Activate(client.AccountId);
        var recording = stores.Recording(client.AccountId);
        Assert.Equal(recording.Path, await MemoResolve.Through(stores.Stores, recording.Path, "ivy", null, _player)());
        var noGateway = await Assert.ThrowsAsync<GatewayException>(MemoResolve.Through(stores.Stores, gatewayPath, "ivy", null, _player));
        Assert.Equal(503, noGateway.Status);

        var wave = VoiceFixtures.FixtureWave(1, [0.5]);
        client.OnRest((method, path, _) => (method, path) == ("GET", "/api/fs/download") ? wave : VoiceFakeClient.DefaultRest(method, path, null));
        On(p => p.Play(gatewayPath, MemoResolve.Through(stores.Stores, gatewayPath, "ivy", client, p)));
        Assert.True(await Until(p => p.StateOf(gatewayPath) == MemoPlayState.Playing));
        var download = Assert.Single(client.Entries("GET /api/fs/download"));
        Assert.Equal([new("path", gatewayPath), new("profile", "ivy")], download.Query);
        Assert.Equal(stores.Stores.Cache!.CacheUrl(gatewayPath), _loop.Read(() => _output.Opened.Single().File));
        Assert.Equal(1, On(p => p.Duration), 6);
        // Cached now: the next play doesn't download.
        On(p => p.Stop());
        Assert.Equal(stores.Stores.Cache.CacheUrl(gatewayPath), await MemoResolve.Through(stores.Stores, gatewayPath, "ivy", client, _player)());
        Assert.Single(client.Entries("GET /api/fs/download"));

        // A gateway error marks the memo failed (the bubble's Retry).
        const string missing = "/Users/owner/.hermes/profiles/ivy/attachments/voice-memo-2.wav";
        client.OnRest((_, _, _) => throw new GatewayException("http", "HTTP 404", 404, "missing"));
        On(p => p.Play(missing, MemoResolve.Through(stores.Stores, missing, "ivy", client, p)));
        Assert.True(await VoiceFixtures.WaitUntil(() => MemoLoadFailures.Contains(missing)));
        Assert.True(await Until(p => !p.IsCurrent(missing) && p.Failed.Contains(missing)));
        MemoLoadFailures.Remove(missing);
    }
}
