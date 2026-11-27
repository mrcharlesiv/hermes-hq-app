using Hermes.Core.Composer;
using Hermes.Core.Voice;
using HermesHQ.Features.Transcript;
using HermesHQ.Services;
using Microsoft.UI.Windowing;

namespace HermesHQ.Features.Composer;

// [WIN-MEMO-SEND-WIRE] The app's memo singletons, as the Mac's `MemoAccountStores.shared`, the chat screens' shared
// `MemoController` and `MemoPlayer.shared`. Every chat's composer reads them as it opens (ComposerMemo). The memo
// gateway itself needs nothing here: HermesClient.OpenChat gives each chat its client's HermesMemoGateway.
// [WIN-MEMO-APP-STORES] Made at launch on the UI thread (App.OnLaunched, before any chat opens) by Hermes.Core's
// MemoAppWiring, which holds the lifecycle (93f984bb1 AppModel activate / tearDown / finishSignOut, the Settings purge):
//   AppState.Adopt (a launch's restore, a sign-in, a switch)  → SignedIn(account): the account's stores open
//   AppState.SignOutAsync                                     → SignedOut(account): this account's memo files go
//   AppState.EndedAsync (the gateway ended the session)        → Ended(): the files stay for the next sign-in
//   AppState.Purge (Sign Out, Remove Gateway)                  → Forget(account)
// Folders: %LOCALAPPDATA%\HermesHQ\memos\<key>\ (recordings, drafts.json, shapes.json; the Mac's Application Support)
// and %LOCALAPPDATA%\HermesHQ\cache\memos\<key>\ (played memos; the Mac's Caches), beside the other per-account caches.
// One controller serves every chat page, as the Mac's `MemoController.shared`: each composer hands it its own target.
// The microphone and the speaker are Core's Unavailable* stand-ins: a memo touch says "Couldn’t Record · Couldn’t start
// the voice memo: the microphone didn’t start." and a memo's play shows its failed state. The Windows capture
// (MediaCapture / AudioGraph behind IMemoAudioInput), its output and the system's audio events come with a later
// Windows-run lane; swap them in Start.
internal static class MemoApp
{
    private static MemoAppWiring? _wiring;

    public static MemoAccountStores? Stores => _wiring?.Stores;
    public static MemoController? Controller => _wiring?.Controller;
    public static MemoPlayer? Player => _wiring?.Player;

    public static string SupportBase => AppPaths.Root;
    public static string CachesBase => Path.Combine(AppPaths.Root, "cache");

    /// Builds the memo pieces once, on the UI thread.
    public static void Start()
    {
        if (_wiring != null) return;
        try
        {
            _wiring = MemoAppWiring.Build(
                new MemoPaths(SupportBase, CachesBase, Features.Voice.WindowsVoiceAudio.FolderGuard),
                Features.Voice.WindowsVoiceAudio.MemoInput,
                Features.Voice.WindowsVoiceAudio.MemoOutput,
                Features.Voice.WindowsVoiceAudio.SystemEvents,
                FilePreferences.Shared,
                new JsonFileStore(Path.Combine(AppPaths.Root, "memo-player.json")),
                AppOnScreen);
            Features.Voice.VoiceMemosFeature.UseWiring(_wiring);
            AppLog.Note("memo", "memos ready (Windows winmm/WinRT audio wired)");
        }
        catch (Exception e)
        {
            // Without them a chat offers no memos and Send is the text send; nothing else depends on them.
            AppLog.Error("memo", e);
        }
    }

    /// UIApplication's `.active`: the window is shown and not minimized (a take begins only then).
    private static bool AppOnScreen() => App.Window is { } w && w.AppWindow.IsVisible
        && w.AppWindow.Presenter is not OverlappedPresenter { State: OverlappedPresenterState.Minimized };

    public static void SignedIn(string accountId) => Run(w => w.SignedIn(accountId));
    public static void SignedOut(string accountId) => Run(w => w.SignedOut(accountId));
    public static void Ended() => Run(w => w.TearDown());
    public static void Forget(string accountId) => Run(w => w.Forget(accountId));

    internal static void StopForQuit()
    {
        try { Player?.Stop(); }
        finally
        {
            Features.Voice.VoiceMemosFeature.StopForQuit();
            Features.Voice.TalkFeature.StopForQuit();
            Features.Voice.DictationFeature.StopForQuit();
        }
    }

    private static void Run(Action<MemoAppWiring> act)
    {
        if (_wiring is not { } wiring) return;
        try { act(wiring); }
        catch (Exception e) { AppLog.Error("memo", e); }
    }
}
