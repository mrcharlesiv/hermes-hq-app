// [WIN-SCREEN-SETUP-SEND] "Set up with Hermes" (docs/spec/3x-screen.md §5.13), the C# twin of the Mac's
// App/Screen/AppModel+Screen.swift at 93f984bb1, `requestScreenSetup` and `runScreenSetup`: the Screen closes, the bot's
// own chat opens, the installer is attached to it and the request goes out through the chat's normal send. A failure
// after the Screen closed is said as an alert over the chat ("Couldn’t Start Screen Setup"), never on the card.
//
// The drawing is the app's (Features/Screen/ScreenSetupHost.cs): this file is the order of the steps and their rules,
// over two seams, the app (IScreenSetupHost) and the open chat (IScreenSetupChat, made over ChatSession and its
// ChatComposer by ScreenSetupChat below).

using Hermes.Core.Composer;

namespace Hermes.Core.Screen;

/// The chat the app has open in its pane (the Swift's `(ChatViewController, LiveChatSession)` pair).
public interface IScreenSetupChat
{
    /// Which chat this is (compared by reference: "the chat changed" is a different session object).
    object Session { get; }
    string Profile { get; }
    /// The bot's own chat, not one of its sessions.
    bool IsBotChat { get; }
    string? RuntimeId { get; }
    bool HasQueuedSetup { get; }
    Task<(string RefText, string Runtime)> AttachAsync(string name, string dataUrl);
    void Send(string refText, ScreenSetupBundle bundle);
}

/// What the request needs from the app.
public interface IScreenSetupHost
{
    /// The signed-in account (`account` with a `client`); null when signed out.
    string? AccountId { get; }
    /// Closes everything over the main window (the Screen, Bot Info) and waits for it to be gone.
    Task CloseCoversAsync();
    /// The chat in the pane, when the pane is in a window; null otherwise.
    IScreenSetupChat? OpenChat();
    /// Opens the bot's own chat in the pane (`popToRoot` then `bots.open(profile)`).
    void OpenBotChat(string profile);
    /// "Opening setup…" over the chat until disposed (the Mac's MenusHUD).
    IDisposable? ShowOpening(IScreenSetupChat chat);
    /// The failure alert (`screenSetupFailed`): over the chat, or over the bots when the chat did not open.
    void Failed(ScreenSetupError failure, IScreenSetupChat? chat);
    /// The installer the app carries (ScreenSetupBundle.Load).
    Task<ScreenSetupBundle> LoadBundleAsync();
    /// The app log's "screen" line.
    void Note(string line);
}

/// The open chat as the setup sees it: a ChatSession and its composer (the queue the request goes into).
public sealed class ScreenSetupChat(ChatComposer composer, bool isBotChat) : IScreenSetupChat
{
    public ChatComposer Composer { get; } = composer;
    public object Session => Composer.Session;
    public string Profile => Composer.Session.Profile;
    public bool IsBotChat { get; } = isBotChat;
    public string? RuntimeId => Composer.Session.RuntimeId;
    public bool HasQueuedSetup => Composer.HasQueuedScreenSetup;
    public Task<(string RefText, string Runtime)> AttachAsync(string name, string dataUrl) => Composer.Session.AttachScreenSetupAsync(name, dataUrl);
    public void Send(string refText, ScreenSetupBundle bundle) => Composer.SendScreenSetup(refText, bundle);
}

/// `requestScreenSetup` / `runScreenSetup`.
public sealed class ScreenSetupRequester(IScreenSetupHost host, ScreenSetupLedger? ledger = null)
{
    private readonly ScreenSetupLedger _ledger = ledger ?? ScreenSetupLedger.Shared;

    /// How often, and how many times, the request looks for the bot's chat after asking for it. The Swift looks 80 times
    /// 50 ms apart (4 s); Windows looks for 10 s (the Windows lanes' polling floor: a chat page on a loaded CI runner
    /// can take longer to be in its window).
    public TimeSpan Poll { get; init; } = TimeSpan.FromMilliseconds(50);
    public int Polls { get; init; } = 200;
    /// The wait between looks (tests count them instead of sleeping).
    public Func<TimeSpan, Task> Sleep { get; init; } = Task.Delay;

    /// One request at a time per bot: a second call while one runs waits for the first's answer. Returns a failure
    /// only when it happened before the Screen closed; later ones are said as an alert over the chat.
    public Task<ScreenSetupError?> RequestAsync(string profile, bool resume)
    {
        if (host.AccountId is not { } account) return Task.FromResult<ScreenSetupError?>(new ScreenSetupError(ScreenSetupFailure.NotConnected));
        var key = ScreenSetupLedger.Key(account, profile);
        return _ledger.Request(key, () => Run(profile, key, resume));
    }

    /// The request without the ledger's one-at-a-time rule, for a viewer the ledger already configured
    /// (ScreenSetupLedger.Configure wraps its `request` in `Request`; going through it twice would wait on itself).
    public Task<ScreenSetupError?> RunAsync(string profile, bool resume)
    {
        if (host.AccountId is not { } account) return Task.FromResult<ScreenSetupError?>(new ScreenSetupError(ScreenSetupFailure.NotConnected));
        return Run(profile, ScreenSetupLedger.Key(account, profile), resume);
    }

    private async Task<ScreenSetupError?> Run(string profile, string key, bool resume)
    {
        if (host.AccountId == null) return new ScreenSetupError(ScreenSetupFailure.NotConnected);
        // The Screen (and Bot Info under it, when it opened from there) covers the chat: everything over the main
        // window closes first, then the bot's own chat opens.
        await host.CloseCoversAsync();
        IScreenSetupChat? BotChat() => host.OpenChat() is { IsBotChat: true } chat && chat.Profile == profile ? chat : null;
        if (BotChat() == null) host.OpenBotChat(profile);
        var found = BotChat();
        for (var i = 0; i < Polls && found == null; i++)
        {
            await Sleep(Poll);
            found = BotChat();
        }
        if (found is not { } live)
        {
            Fail(new ScreenSetupError(ScreenSetupFailure.ChatDidNotOpen), null);
            return null;
        }
        // Already there: a queued request, or one made this run that is not being continued.
        if (_ledger.AlreadyThere(key, live.HasQueuedSetup, resume)) return null;
        ScreenSetupError? failure = null;
        var hud = host.ShowOpening(live);
        try
        {
            var bundle = await host.LoadBundleAsync();
            var attached = await live.AttachAsync(bundle.File, bundle.DataUrl);
            if (BotChat() is not { } now || !ReferenceEquals(now.Session, live.Session) || live.RuntimeId != attached.Runtime)
                throw new ScreenSetupError(ScreenSetupFailure.ChangedBeforeStart);
            live.Send(attached.RefText, bundle);
            _ledger.MarkSubmitted(key);
            host.Note("setup requested");
        }
        catch (ScreenSetupError e) { failure = e; }
        catch (Exception) { failure = new ScreenSetupError(ScreenSetupFailure.Installer); }
        finally { hud?.Dispose(); }
        if (failure != null) Fail(failure, live);
        return null;
    }

    private void Fail(ScreenSetupError failure, IScreenSetupChat? chat)
    {
        host.Note("setup failed");
        host.Failed(failure, chat);
    }
}
