using Hermes.Core.Screen;
using Hermes.Core.Shell;
using HermesHQ.Features.Bots;
using HermesHQ.Features.Composer;
using HermesHQ.Pages;
using HermesHQ.Services;
using HermesHQ.Shell;

namespace HermesHQ.Features.Screen;

/// [WIN-SCREEN-SETUP-SEND] "Set up with Hermes" in the app (App/Screen/AppModel+Screen.swift at 93f984bb1,
/// `runScreenSetup` and `screenSetupFailed`): the Screen's window closes, the bot's own chat opens in the main window's
/// pane, "Opening setup…" stands in its status line while the installer is attached, and a failure is an alert over the
/// chat. The steps and their rules are Hermes.Core's ScreenSetupRequester; this is its IScreenSetupHost.
internal sealed class ScreenSetupHost : IScreenSetupHost
{
    public string? AccountId => AppState.Client?.AccountId;

    public async Task CloseCoversAsync()
    {
        // The Mac dismisses everything over the tabs (the Screen, Bot Info under it); here the Screen is a window of
        // its own (its sheet closes with it), and the main window comes forward.
        ScreenWindow.CloseOpen();
        App.Window?.Activate();
        await Task.Yield();
    }

    public IScreenSetupChat? OpenChat()
    {
        if (ChatPage.Current is not { XamlRoot: not null } page || ComposerController.For(page) is not { } composer) return null;
        var pane = ShellPage.Current?.KeyState();
        return new ScreenSetupChat(composer.Composer, pane?.Pane == OpenPane.BotChat && pane.Profile == composer.Composer.Session.Profile);
    }

    public void OpenBotChat(string profile)
    {
        if (ListsHub.Current?.Bots.Bot(profile) is { } bot) Navigator.Go(new BotChatDestination(bot.Model));
        else AppLog.Note("screen", "setup: the bot isn't in the list");
    }

    public IDisposable? ShowOpening(IScreenSetupChat chat)
    {
        if (ChatPage.Current is not { } page || ComposerController.For(page) is not { } composer
            || !ReferenceEquals(composer.Composer.Session, chat.Session)) return null;
        composer.SetStatus(ScreenSetupCopy.Opening);
        return new Opening(composer);
    }

    private sealed class Opening(ComposerController composer) : IDisposable
    {
        private bool _done;
        public void Dispose()
        {
            if (_done) return;
            _done = true;
            composer.SetStatus(null);
        }
    }

    public void Failed(ScreenSetupError failure, IScreenSetupChat? chat)
    {
        var (title, message, _) = ScreenInfoRowWords.SetupFailed(failure);
        var root = ChatPage.Current?.XamlRoot ?? App.Window?.Content?.XamlRoot;
        if (root == null) { AppLog.Note("screen", "setup failed with nowhere to say it"); return; }
        _ = Prompts.FailureAsync(root, title, message);
    }

    public Task<ScreenSetupBundle> LoadBundleAsync() => ScreenSetupBundle.Load();

    public void Note(string line) => AppLog.Note("screen", line);
}
