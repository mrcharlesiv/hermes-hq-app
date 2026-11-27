using Hermes.Core;
using Hermes.Core.Auth;
using Hermes.Core.Chat;
using Hermes.Core.Gateways;
using Hermes.Core.Net;

namespace HermesHQ.Services;

/// The saved gateways, the one in use and the services around it. One HermesClient at a time: the gateway in use.
/// Switching ends the old client and makes a new one (the Mac's AppModel.activate); ShellPage reads `Client` when it
/// is shown, and the launch flow shows the shell again after every switch.
public static partial class AppState
{
    public static ITokenStore Store { get; } = Automation.AppOnly ? new MemoryTokenStore() : new CredentialLockerStore();
    public static FileTranscriptCache Cache { get; } = new(AppPaths.Transcripts);
    public static SignIn SignIn { get; } = new(Store);
    public static GatewayHub Gateways { get; } = new(Store, new FileParkedRosters(AppPaths.Lists));
    public static LaunchChatMemory LaunchChat { get; } = new(Path.Combine(AppPaths.Root, "launch-chat.json"));
    /// [WIN-LOST-SEND-MARKER] Sends that may never have arrived, for the Sessions rows' "Not Delivered:" (LostSends.shared).
    public static Hermes.Core.Sessions.LostSends LostSends { get; } = new(AppPaths.Root);
    public static HermesClient? Client { get; private set; }
    /// The gateway in use changed (a sign-in, a switch: the new client; a sign-out or an ended session: null).
    /// Raised on the caller's thread.
    public static event Action<HermesClient?>? ClientChanged;


    /// The account in use as saved now (its label may have been renamed since its session was made).
    public static StoredAccount? Account => Client is { } c ? Gateways.Saved().Find(c.AccountId) ?? c.Session.Account : null;

    /// Makes `session` the gateway in use. The old client (another gateway, or the same one signed in again) ends.
    public static HermesClient Adopt(GatewaySession session)
    {
        var old = Client;
        // [WIN-MEMO-APP-STORES] The account's memo stores open before its client (AppModel.activate, line 417); another
        // account's take, playback and stores close first.
        Features.Composer.MemoApp.SignedIn(session.Account.Key);
        // [WIN-SENT-TITLES] The app's one list of titled requests, its fixed pairs noted at every sign-in (the Mac's
        // AppModel.startPresence).
        SentTitles.Shared.NoteFixedPairs();
        Client = new HermesClient(session, Cache) { LostSends = LostSends, SentTitles = SentTitles.Shared };
        Gateways.CurrentKey = session.Account.Key;
        var title = Gateways.CurrentTitle;
        HostWord.GatewayName = title.Length > 0 && title != GatewayNaming.Unnamed ? title : null;
        Client.BotsChanged += ParkRoster;
        // [WIN-23] A listener that throws no longer ends the socket (RpcConnection.Deliver): say which one, and why an
        // open link closed, so a redial in a walk's log names its cause. Types and places only, never frame contents.
        Client.Rpc.ListenerFailed += (name, e) => AppLog.Note("rpc",
            $"a {name} listener threw {e.GetType().Name} (0x{e.HResult:X8}) in {e.TargetSite?.DeclaringType?.Name}.{e.TargetSite?.Name}");
        Client.Rpc.Dropped += why => AppLog.Note("rpc", $"link dropped: {why}");
        if (old != null)
        {
            old.BotsChanged -= ParkRoster;
            _ = old.DisposeAsync().AsTask();
        }
        Gateways.AccountsChanged();
        AppLog.Note("account", $"using a gateway ({(session.IsNous ? "nous" : "password")})");
        ClientChanged?.Invoke(Client);
        return Client;
    }

    /// What the gateway in use last showed, for the news check once another gateway is in use.
    /// [WIN-EXIT-STOWED-PROBE] The quit's gateway step: the client in use closes its socket and session, so no event
    /// marshals onto the UI thread after this and a request in flight ends while XAML still runs. Client stays set (the
    /// features see no sign-out); the next launch reads the saved sign-in as before.
    internal static async Task CloseGatewayForQuitAsync()
    {
        Features.Browser.BrowserFeature.CloseForQuit();
        Features.PhoneCalls.PhoneCallsFeature.CloseForQuit();
        if (Client is not { } c) return;
        c.BotsChanged -= ParkRoster;
        await c.DisposeAsync();
    }

    private static void ParkRoster()
    {
        if (Client is { Bots: { } bots } c) Gateways.Park(c.AccountId, bots);
    }

    /// Sign out of the gateway in use: it tells the gateway, and this PC forgets the session and its cached chats. With
    /// other gateways saved it leaves the list and the most recently used other one is returned (to switch to); alone,
    /// it stays as the sign-in form's prefill and null is returned.
    public static async Task<StoredAccount?> SignOutAsync()
    {
        if (Client is not { } c) return null;
        Client = null;
        c.BotsChanged -= ParkRoster;
        var key = c.AccountId;
        Features.Composer.MemoApp.SignedOut(key);   // [WIN-MEMO-APP-STORES] the take and playback stop; its memo files go
        Purge(key);
        await c.Session.SignOutAsync();
        await c.DisposeAsync();
        var saved = Gateways.Saved();
        StoredAccount? next = null;
        if (saved.Accounts.Count > 1)
        {
            saved.Remove(key);
            next = saved.Accounts.FirstOrDefault();
            Store.Write(saved.ToJson());
        }
        Gateways.CurrentKey = null;
        Gateways.AccountsChanged();
        HostWord.GatewayName = null;
        AppLog.Note("account", "signed out");
        ClientChanged?.Invoke(Client);
        return next;
    }

    /// The gateway ended this PC's session: the client ends; the entry stays, without its session, as the prefill.
    public static async Task EndedAsync()
    {
        if (Client is not { } c) return;
        Client = null;
        c.BotsChanged -= ParkRoster;
        Features.Composer.MemoApp.Ended();   // [WIN-MEMO-APP-STORES] its memo files stay for the next sign-in
        await c.DisposeAsync();
        Gateways.AccountsChanged();
        ClientChanged?.Invoke(Client);
    }

    /// This PC's copies of a gateway's data (Sign Out, Remove Gateway).
    public static void Purge(string key)
    {
        Cache.Purge(key);
        LaunchChat.Forget(key);
        Features.Attachments.AttachmentsFeature.SignedOut(key);
        Features.Jobs.JobsFeature.SignedOut(key);
        Features.Composer.MemoApp.Forget(key);   // [WIN-MEMO-APP-STORES] recordings, drafts, played memos
        Features.Browser.BrowserFeature.SignedOut(key);
        LostSends.Purge(key);                    // [WIN-LOST-SEND-MARKER] the rows' "Not Delivered:" words
    }
}
