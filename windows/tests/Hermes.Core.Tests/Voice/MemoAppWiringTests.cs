// [WIN-MEMO-APP-STORES] The app's memo lifecycle (93f984bb1 App/AppModel.swift activate/tearDown/finishSignOut, the
// Settings purge; MemoAccountStores.shared, MemoController.shared, MemoPlayer.shared). The Mac has no test of its own
// for these AppModel lines (its Voice suites activate MemoAccountStores.shared directly, as VoiceTestStores does here),
// so these are new, one per state: sign-in activates, the same account again changes nothing, sign-out purges this
// account's files only, a gateway ending the session keeps them, an account switch keeps the take as the first
// account's draft, two chats keep their own drafts and notices, Remove Gateway, and the unavailable microphone's and
// output's words. The controller runs on the Mac's main actor (MainLoop.Drive). Synthetic data only: made-up account
// ids, the demo bots Ivy and Otto, generated WAVs.

using Hermes.Core.Composer;
using Hermes.Core.Voice;

namespace Hermes.Core.Tests.Voice;

/// Ends each take with the next file of `files` (a second take gets a second recording).
internal sealed class FilesCapture(params MemoFile[] files) : IMemoCapturing
{
    private int _next;
    public Action<MemoCaptureEvent>? OnEvent { get; set; }
    public string? AccountKey { get; set; }
    public bool IsRecording { get; private set; }
    public double? StartLatencyMs { get; } = 4;
    public List<MemoEndAction> Ended { get; } = [];

    public Task<MemoTakeStart> BeginAsync()
    {
        IsRecording = true;
        return Task.FromResult(new MemoTakeStart($"take-{_next + 1}", 600));
    }

    public Task<MemoFile?> EndAsync(string id, MemoEndAction action)
    {
        IsRecording = false;
        Ended.Add(action);
        if (action == MemoEndAction.Cancel) return Task.FromResult<MemoFile?>(null);
        return Task.FromResult<MemoFile?>(files[Math.Min(_next++, files.Length - 1)]);
    }

    public void NativeStop(MemoStopReason reason) => IsRecording = false;
}

public sealed class MemoAppWiringTests : IDisposable
{
    private readonly VoiceTestStores _stores = new();
    private readonly List<object> _alive = [];
    private readonly List<MemoController> _made = [];
    private static readonly string A = $"wiring-a-{Guid.NewGuid()}";
    private static readonly string B = $"wiring-b-{Guid.NewGuid()}";

    public void Dispose()
    {
        foreach (var c in _made) c.Dispose();
        _stores.Dispose();
    }

    private static string Key(string account) => MemoPaths.AccountKey(account);
    private static Task<bool> WaitUntil(Func<bool> condition) => VoiceFixtures.WaitUntil(condition);
    private static double Ms() => System.Diagnostics.Stopwatch.GetTimestamp() * 1000.0 / System.Diagnostics.Stopwatch.Frequency;

    /// The app's pieces over the unavailable input and output, as the Windows app builds them today.
    private MemoAppWiring Built(MemoUploadState? uploads = null)
    {
        var wiring = MemoAppWiring.Build(_stores.Paths, UnavailableMemoAudioInput.Instance, UnavailableMemoAudioOutput.Instance,
            NoMemoSystemEvents.Instance, new MemoryPrefs(), new MemoryStore(), () => true, uploads: uploads ?? new MemoUploadState());
        _made.Add(wiring.Controller);
        return wiring;
    }

    /// The same lifecycle over a capture that hands back `files` (a take that really ends).
    private (MemoAppWiring Wiring, FilesCapture Capture) WithCapture(bool sendOnRelease, params MemoFile[] files)
    {
        var stores = new MemoAccountStores(_stores.Paths);
        var capture = new FilesCapture(files);
        var prefs = new MemoryPrefs();
        if (!sendOnRelease) prefs.Set(MemoController.SendOnReleaseKey, "false");
        var controller = new MemoController(capture, stores, prefs);
        _made.Add(controller);
        return (new MemoAppWiring(stores, controller, uploads: new MemoUploadState()), capture);
    }

    private MemoTarget Target(string account, string bot, out FakeMemoHost host)
    {
        host = new FakeMemoHost();
        var session = new FakeMemoChat();
        _alive.Add(host);
        _alive.Add(session);
        return new MemoTarget($"{account}|{bot.ToLowerInvariant()}|{Guid.NewGuid()}", host, session, bot, Key(account));
    }

    /// A file under caches/memos/<key>/ (a played memo).
    private string Played(string account)
    {
        var folder = _stores.Paths.Caches(Key(account));
        Directory.CreateDirectory(folder);
        var file = Path.Combine(folder, "played.m4a");
        File.WriteAllBytes(file, [1, 2, 3]);
        return file;
    }

    // MARK: Sign-in

    [Fact]
    public Task SignInActivatesTheAccountsStores() => MainLoop.Drive(async () =>
    {
        var wiring = Built();
        Assert.False(wiring.IsActive);
        Assert.Null(wiring.Stores.Drafts);
        wiring.SignedIn(A);
        Assert.True(wiring.IsActive);
        Assert.Equal(A, wiring.Stores.AccountId);
        Assert.Equal(Key(A), wiring.Stores.Key);
        Assert.NotNull(wiring.Stores.Drafts);
        Assert.NotNull(wiring.Stores.Shapes);
        Assert.NotNull(wiring.Stores.Cache);
        Assert.Equal(_stores.Paths.Caches(Key(A)), wiring.Stores.Cache!.Folder);
        // memos/ and memos/<key>/ are made and protected off the UI thread at sign-in.
        await wiring.Stores.SweepTask!;
        Assert.True(Directory.Exists(_stores.Paths.Memos(Key(A))));
        Assert.True(_stores.Guard.Protected(_stores.Paths.MemosRoot));
        Assert.True(_stores.Guard.Protected(_stores.Paths.Memos(Key(A))));
    });

    [Fact]
    public Task SigningInToTheSameAccountAgainChangesNothing() => MainLoop.Drive(async () =>
    {
        var file = _stores.Recording(A);
        var (wiring, _) = WithCapture(sendOnRelease: false, file);
        wiring.SignedIn(A);
        var target = Target(A, "Ivy", out _);
        wiring.Controller.MemoDown(target, 402);
        Assert.True(await WaitUntil(() => wiring.Controller.State.Phase == MemoPhase.Holding));
        wiring.Controller.Input(new MemoInput.Up(Ms() + 5000));
        Assert.True(await WaitUntil(() => wiring.Controller.State.Phase == MemoPhase.Review));
        var generation = wiring.Stores.Generation;
        var drafts = wiring.Stores.Drafts;
        wiring.SignedIn(A);   // a new client for the same account (signed in again): the take in review stays
        Assert.Equal(generation, wiring.Stores.Generation);
        Assert.Same(drafts, wiring.Stores.Drafts);
        Assert.Equal(MemoPhase.Review, wiring.Controller.State.Phase);
        Assert.Equal(file, wiring.Controller.File);
    });

    // MARK: Sign-out

    [Fact]
    public Task SignOutPurgesThisAccountsFilesOnly() => MainLoop.Drive(async () =>
    {
        var mine = _stores.Recording(A);
        var theirs = _stores.Recording(B);
        var (wiring, capture) = WithCapture(sendOnRelease: true, mine);
        // B was used on this PC before: its draft and a played memo are on disk.
        wiring.SignedIn(B);
        wiring.Stores.Drafts!.Set(theirs, $"{B}|otto|s1");
        var theirPlayed = Played(B);
        wiring.SignedIn(A);
        var target = Target(A, "Ivy", out _);
        wiring.Controller.MemoDown(target, 402);
        Assert.True(await WaitUntil(() => wiring.Controller.State.Phase == MemoPhase.Holding));
        wiring.Controller.Input(new MemoInput.Leave());
        Assert.True(await WaitUntil(() => wiring.Controller.State.Phase == MemoPhase.Idle));
        Assert.Equal([MemoEndAction.Draft], capture.Ended);
        Assert.Equal(mine, wiring.Stores.Drafts!.Draft(target.Scope));
        var myPlayed = Played(A);

        wiring.SignedOut(A);
        Assert.False(wiring.IsActive);
        Assert.Null(wiring.Stores.Drafts);
        Assert.False(Directory.Exists(_stores.Paths.Memos(Key(A))));
        Assert.False(Directory.Exists(_stores.Paths.Caches(Key(A))));
        Assert.False(File.Exists(mine.Path));
        Assert.False(File.Exists(myPlayed));
        // B's recordings, drafts and played memos stay.
        Assert.True(File.Exists(theirs.Path));
        Assert.True(File.Exists(Path.Combine(_stores.Paths.Memos(Key(B)), MemoPaths.DraftsFile)));
        Assert.True(File.Exists(theirPlayed));
        wiring.SignedIn(B);
        Assert.Equal(theirs, wiring.Stores.Drafts!.Draft($"{B}|otto|s1"));
    });

    [Fact]
    public Task SignOutDropsATakeStillRecordingAndItsReviewedDraftGoesWithTheAccount() => MainLoop.Drive(async () =>
    {
        var file = _stores.Recording(A);
        var (wiring, capture) = WithCapture(sendOnRelease: false, file);
        wiring.SignedIn(A);
        var target = Target(A, "Ivy", out var host);
        wiring.Controller.MemoDown(target, 402);
        Assert.True(await WaitUntil(() => wiring.Controller.State.Phase == MemoPhase.Holding));
        wiring.Controller.Input(new MemoInput.Up(Ms() + 5000));
        Assert.True(await WaitUntil(() => wiring.Controller.State.Phase == MemoPhase.Review));
        wiring.SignedOut(A);
        Assert.Equal(MemoPhase.Idle, wiring.Controller.State.Phase);
        Assert.Null(wiring.Controller.File);
        Assert.Null(wiring.Controller.Target);
        Assert.Contains("state", host.Log);   // the chat's composer was told to lay out again
        Assert.Empty(host.Sent);              // nothing is sent on the way out
        Assert.False(File.Exists(file.Path));
        Assert.False(Directory.Exists(_stores.Paths.Memos(Key(A))));
        Assert.Equal([MemoEndAction.Review], capture.Ended);
    });

    [Fact]
    public Task AnEndedSessionKeepsTheAccountsFiles() => MainLoop.Drive(async () =>
    {
        var file = _stores.Recording(A);
        var (wiring, _) = WithCapture(sendOnRelease: true, file);
        wiring.SignedIn(A);
        var target = Target(A, "Ivy", out _);
        wiring.Controller.MemoDown(target, 402);
        Assert.True(await WaitUntil(() => wiring.Controller.State.Phase == MemoPhase.Holding));
        wiring.Controller.Input(new MemoInput.Leave());
        Assert.True(await WaitUntil(() => wiring.Controller.State.Phase == MemoPhase.Idle));
        var played = Played(A);
        wiring.TearDown();   // the gateway ended the session: the account stays saved, without its session
        Assert.False(wiring.IsActive);
        Assert.True(File.Exists(file.Path));
        Assert.True(File.Exists(played));
        wiring.SignedIn(A);
        Assert.Equal(file, wiring.Stores.Drafts!.Draft(target.Scope));
    });

    // MARK: Account switch

    [Fact]
    public Task AnAccountSwitchKeepsTheReviewedTakeAsTheFirstAccountsDraft() => MainLoop.Drive(async () =>
    {
        var file = _stores.Recording(A);
        var uploads = new MemoUploadState();
        var stores = new MemoAccountStores(_stores.Paths);
        var prefs = new MemoryPrefs();
        prefs.Set(MemoController.SendOnReleaseKey, "false");
        var controller = new MemoController(new FilesCapture(file), stores, prefs);
        _made.Add(controller);
        var wiring = new MemoAppWiring(stores, controller, uploads: uploads);
        wiring.SignedIn(A);
        var target = Target(A, "Ivy", out var host);
        controller.MemoDown(target, 402);
        Assert.True(await WaitUntil(() => controller.State.Phase == MemoPhase.Holding));
        controller.Input(new MemoInput.Up(Ms() + 5000));
        Assert.True(await WaitUntil(() => controller.State.Phase == MemoPhase.Review));
        lock (uploads.Gate) uploads.Roots[A] = "/Users/me";
        var generation = stores.Generation;

        wiring.SignedIn(B);
        Assert.Equal(B, stores.AccountId);
        Assert.Equal(Key(B), stores.Key);
        Assert.True(stores.Generation > generation);   // A's work in flight is dropped
        Assert.Equal(MemoPhase.Idle, controller.State.Phase);
        Assert.Null(controller.File);
        Assert.Empty(host.Sent);
        lock (uploads.Gate) Assert.Empty(uploads.Roots);   // the uploader's session caches went with A
        // B sees none of A's drafts; A's take waits on disk, in A's folder.
        Assert.Null(stores.Drafts!.Draft(target.Scope));
        Assert.True(File.Exists(file.Path));
        await stores.SweepTask!;

        wiring.SignedIn(A);
        Assert.Equal(file, stores.Drafts!.Draft(target.Scope));
    });

    // MARK: Two chats

    [Fact]
    public Task TwoChatsKeepTheirOwnDraftsAndNotices() => MainLoop.Drive(async () =>
    {
        var first = _stores.Recording(A);
        var second = _stores.Recording(A, seconds: 3);
        var (wiring, capture) = WithCapture(sendOnRelease: true, first, second);
        wiring.SignedIn(A);
        var ivy = Target(A, "Ivy", out var ivyHost);
        var otto = Target(A, "Otto", out var ottoHost);
        var controller = wiring.Controller;

        // Ivy's chat: a take left as a draft.
        controller.MemoDown(ivy, 402);
        Assert.True(await WaitUntil(() => controller.State.Phase == MemoPhase.Holding));
        Assert.Same(ivy, controller.Target);
        controller.Input(new MemoInput.Leave());
        Assert.True(await WaitUntil(() => controller.State.Phase == MemoPhase.Idle));

        // Otto's chat: a send whose chat is gone from the screen becomes its draft, with a notice for Otto's chat only.
        ottoHost.CanSendMemo = false;
        controller.MemoDown(otto, 402);
        Assert.True(await WaitUntil(() => controller.State.Phase == MemoPhase.Holding));
        Assert.Same(otto, controller.Target);
        controller.Input(new MemoInput.Up(Ms() + 5000));
        Assert.True(await WaitUntil(() => controller.State.Phase == MemoPhase.Idle));

        Assert.Equal([MemoEndAction.Draft, MemoEndAction.Send], capture.Ended);
        Assert.Equal(first, wiring.Stores.Drafts!.Draft(ivy.Scope));
        Assert.Equal(second, wiring.Stores.Drafts!.Draft(otto.Scope));
        Assert.Null(controller.Notice(ivy.Scope));
        Assert.Equal("It didn’t send. It’s waiting in the message field of your chat with Otto.", controller.Notice(otto.Scope)?.Message);
        Assert.Empty(ivyHost.Sent);
        Assert.Empty(ottoHost.Sent);

        // Sign-out clears the notices and takes both chats' drafts.
        wiring.SignedOut(A);
        Assert.Null(controller.Notice(otto.Scope));
        Assert.False(File.Exists(first.Path));
        Assert.False(File.Exists(second.Path));
    });

    // MARK: Remove Gateway

    [Fact]
    public Task ForgettingAnotherAccountLeavesTheOneInUse() => MainLoop.Drive(async () =>
    {
        var mine = _stores.Recording(A);
        var theirs = _stores.Recording(B);
        var (wiring, _) = WithCapture(sendOnRelease: true, mine);
        wiring.SignedIn(A);
        wiring.Stores.Drafts!.Set(mine, $"{A}|ivy|s1");
        wiring.Forget(B);
        Assert.True(wiring.IsActive);
        Assert.Equal(A, wiring.Stores.AccountId);
        Assert.False(File.Exists(theirs.Path));
        Assert.True(File.Exists(mine.Path));
        // Forgetting the account in use closes its stores first.
        wiring.Forget(A);
        Assert.False(wiring.IsActive);
        Assert.False(File.Exists(mine.Path));
        await Task.CompletedTask;
    });

    // MARK: No microphone, no output (the seams this build leaves unfilled)

    [Fact]
    public Task TheUnavailableMicrophoneShowsTheMacsCouldNotRecordWords() => MainLoop.Drive(async () =>
    {
        var wiring = Built();
        wiring.SignedIn(A);
        var target = Target(A, "Ivy", out var host);
        wiring.Controller.MemoDown(target, 402);
        Assert.True(await WaitUntil(() => wiring.Controller.Notice(target.Scope) != null));
        Assert.Equal(MemoPhase.Idle, wiring.Controller.State.Phase);
        var notice = wiring.Controller.Notice(target.Scope)!;
        Assert.Equal("Couldn’t Record", notice.Title);
        Assert.Equal("Couldn’t start the voice memo: the microphone didn’t start.", notice.Message);
        Assert.Equal("Try Again", notice.ActionTitle);
        Assert.Equal(MemoNoticeTone.Error, notice.Tone);
        Assert.Empty(host.Sent);
        Assert.Null(wiring.Stores.Drafts!.Draft(target.Scope));
        Assert.Equal("the microphone didn’t start", MemoRecorder.StartReason(new MemoAudioUnavailableException("microphone")));
    });

    [Fact]
    public Task TheUnavailableOutputMarksAMemoFailed() => MainLoop.Drive(async () =>
    {
        var wiring = Built();
        wiring.SignedIn(A);
        var file = _stores.Recording(A);
        var player = wiring.Player!;
        player.Play(file.Path, () => Task.FromResult(file.Path));
        Assert.True(await WaitUntil(() => player.Failed.Contains(file.Path)));
        Assert.NotEqual(MemoPlayState.Playing, player.StateOf(file.Path));
        wiring.SignedOut(A);
        Assert.Null(player.Path);
    });

    [Fact]
    public void RecordingTakesTheSessionFromPlayback()
    {
        var sessions = new MemoAudioSessions();
        var preempted = 0;
        sessions.Playback.PlaybackPreempted = () => preempted++;
        sessions.Playback.AcquireAsync().GetAwaiter().GetResult();
        Assert.Equal("Playback", sessions.Holder);
        sessions.Recording.AcquireAsync().GetAwaiter().GetResult();
        Assert.Equal(1, preempted);
        Assert.Equal("Recording", sessions.Holder);
        sessions.Playback.Release();   // not its to give back
        Assert.Equal("Recording", sessions.Holder);
        sessions.Recording.Release();
        Assert.Null(sessions.Holder);
        sessions.Recording.AcquireAsync().GetAwaiter().GetResult();
        sessions.Playback.AcquireAsync().GetAwaiter().GetResult();   // playback after recording preempts nothing
        Assert.Equal(1, preempted);
        sessions.Playback.Reset();
        Assert.Null(sessions.Holder);
    }
}
