using Hermes.Core.Composer;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Voice;

// [WIN-MEMO-APP-STORES] What the Mac app sets up for memos (93f984bb1 App/AppModel.swift `activate` line 417, `tearDown`
// lines 660-665, `finishSignOut` line 376; App/Settings/AppModel+Settings.swift `purge` line 200; the shared
// singletons `MemoAccountStores.shared`, `MemoController.shared` (App/Chat/Voice/MemoController.swift:92, built over
// `MemoRecorder.shared`), `MemoPlayer.shared`, and MemoUploader's statics):
//   SignedIn(accountId)   activate: a different account tears the last one down first, then its stores open (their
//                         folders protected and swept off the UI thread); the same account again changes nothing
//   TearDown()            tearDown: a take still recording is dropped, a take in review waits as its chat's draft on
//                         the account it was recorded for, playback stops, the uploader's session caches go, the
//                         stores close without deleting anything (an account switch, a session the gateway ended)
//   SignedOut(accountId)  finishSignOut: TearDown, then this account's recordings, drafts, shapes and played memos
//                         (memos/<key>/ and caches/memos/<key>/); every other account's stay
//   Forget(accountId)     Remove Gateway's purge: that account's files (the stores close first when it is in use)
// One controller serves every chat, as the Mac's `MemoController.shared`: each chat page's composer hands it its own
// MemoTarget (scope, host, session) at touch-down, so drafts and notices are kept per chat. One-thread: build and call it
// on the UI thread (the controller, the recorder and the player are).
//
// The microphone is a seam (IMemoAudioInput). This file gives the app no real capture: `UnavailableMemoAudioInput`
// says there is no input, so a memo touch shows the Mac's words for a microphone that doesn't start ("Couldn’t Record",
// "Couldn’t start the voice memo: the microphone didn’t start."). Playback likewise has `UnavailableMemoAudioOutput`
// (a memo's play shows "Couldn’t load audio · Retry"). The Windows capture and output (MediaCapture / AudioGraph) and
// the system's audio events come with a later Windows-run lane.

/// The app's memo pieces and their sign-in, switch and sign-out lifecycle.
public sealed class MemoAppWiring
{
    public MemoPaths Paths { get; }
    public MemoAccountStores Stores { get; }
    public MemoController Controller { get; }
    public MemoPlayer? Player { get; }
    public MemoUploadState Uploads { get; }

    public MemoAppWiring(MemoAccountStores stores, MemoController controller, MemoPlayer? player = null,
        MemoUploadState? uploads = null)
    {
        Stores = stores;
        Paths = stores.Paths;
        Controller = controller;
        Player = player;
        Uploads = uploads ?? MemoUploadState.Shared;
    }

    /// The app's pieces over one audio input and output: the recorder (`MemoRecorder.shared`), the controller over it,
    /// the player, and the stores under `supportBase/memos` and `cachesBase/memos`. Build it on the UI thread (or pass
    /// its context).
    public static MemoAppWiring Build(MemoPaths paths, IMemoAudioInput input, IMemoAudioOutput output,
        IMemoSystemEvents events, IPreferences prefs, IKeyValueStore playerDefaults, Func<bool> appActive,
        MemoAudioSessions? sessions = null, MemoUploadState? uploads = null,
        Func<string, IEnumerable<string>>? queuedMemoPaths = null, SynchronizationContext? context = null)
    {
        context ??= SynchronizationContext.Current
            ?? throw new InvalidOperationException("MemoAppWiring is one-thread: build it on the UI thread or pass its context.");
        sessions ??= new MemoAudioSessions();
        var stores = new MemoAccountStores(paths, queuedMemoPaths);
        var player = new MemoPlayer(output, sessions.Playback, events, playerDefaults, context);
        var recorder = new MemoRecorder(input, sessions.Recording, events, paths, appActive, context: context);
        var controller = new MemoController(recorder, stores, prefs, player);
        return new MemoAppWiring(stores, controller, player, uploads);
    }

    /// The account's memo stores are open (a chat offers memos).
    public bool IsActive => Stores.Key != null;

    /// Signed in (a launch's restore, a fresh sign-in, a switch to another gateway).
    public void SignedIn(string accountId)
    {
        if (Stores.AccountId == accountId) return;
        if (Stores.AccountId != null) TearDown();
        // The drafts file is written behind the UI thread (MemoDisk): a draft the last account's reset or a take just
        // kept is on disk before the stores read it back (a quick switch back, a sign-in after the session ended).
        MemoDisk.Flush();
        Stores.Activate(accountId);
    }

    /// The account stops being the one in use; nothing on disk is deleted.
    public void TearDown()
    {
        Controller.Reset();
        Player?.Stop();
        Uploads.Reset();
        Stores.Deactivate(purge: false);
    }

    /// Sign Out: the account in use goes, and with it this PC's memo files for it (only it).
    public void SignedOut(string accountId)
    {
        if (Stores.AccountId != null) TearDown();
        Purge(accountId);
    }

    /// Remove Gateway: that account's memo files. The stores close first when it is the one in use.
    public void Forget(string accountId)
    {
        if (Stores.AccountId == accountId) TearDown();
        Purge(accountId);
    }

    private void Purge(string accountId)
    {
        MemoDisk.Flush();   // a draft the reset just kept is written before its folder goes
        Paths.Purge(accountId);
    }
}

/// No microphone input on this build: the recorder never starts. Permission reads granted (there is nothing to allow:
/// a denied one would send the person to the privacy settings for a microphone the app can't use), so a touch goes to
/// `Create`, which throws; the recorder's start reason is then the Mac's "the microphone didn’t start".
public sealed class UnavailableMemoAudioInput : IMemoAudioInput
{
    public static readonly UnavailableMemoAudioInput Instance = new();

    public MemoMicPermission Permission => MemoMicPermission.Granted;
    public Task<bool> RequestPermissionAsync() => Task.FromResult(true);
    public IMemoAudioTake Create(string file) => throw new MemoAudioUnavailableException("microphone");
}

/// No memo playback on this build: every open fails, so the memo shows the player's failed state.
public sealed class UnavailableMemoAudioOutput : IMemoAudioOutput
{
    public static readonly UnavailableMemoAudioOutput Instance = new();

    public Task<IMemoAudioTrack> OpenAsync(string file) =>
        Task.FromException<IMemoAudioTrack>(new MemoAudioUnavailableException("audio output"));
}

/// The input or output this build doesn't have. Its HResult is the default one, which no microphone code names.
public sealed class MemoAudioUnavailableException(string what) : Exception($"no {what} on this build");

/// No system audio or app events (the Windows ones come with the capture lane): nothing is ever raised.
public sealed class NoMemoSystemEvents : IMemoSystemEvents
{
    public static readonly NoMemoSystemEvents Instance = new();

    public event Action<MemoSystemEvent>? Raised { add { } remove { } }
}

/// The two memo owners of the audio session (AudioSessionCoordinator's `.memoRecording` and `.memoPlayback`): taking
/// it for a recording takes it from playback, whose player pauses (`PlaybackPreempted`). Windows has no shared audio
/// session to activate, so acquiring never fails here.
public sealed class MemoAudioSessions
{
    private readonly object _gate = new();
    private Owner? _holder;

    public MemoAudioSessions()
    {
        Recording = new Handle(this, Owner.Recording);
        Playback = new Handle(this, Owner.Playback);
    }

    public IMemoAudioSession Recording { get; }
    public IMemoAudioSession Playback { get; }

    /// Who holds it now (tests read it).
    public string? Holder { get { lock (_gate) return _holder?.ToString(); } }

    private enum Owner { Recording, Playback }

    private void Acquire(Owner owner)
    {
        Action? preempted = null;
        lock (_gate)
        {
            if (_holder is { } held && held != owner && held == Owner.Playback) preempted = Playback.PlaybackPreempted;
            _holder = owner;
        }
        preempted?.Invoke();
    }

    private void Release(Owner owner)
    {
        lock (_gate) if (_holder == owner) _holder = null;
    }

    private void Reset()
    {
        lock (_gate) _holder = null;
    }

    private sealed class Handle(MemoAudioSessions sessions, Owner owner) : IMemoAudioSession
    {
        public Action? PlaybackPreempted { get; set; }

        public Task AcquireAsync()
        {
            sessions.Acquire(owner);
            return Task.CompletedTask;
        }

        public void Release() => sessions.Release(owner);
        public void Reset() => sessions.Reset();
    }
}
