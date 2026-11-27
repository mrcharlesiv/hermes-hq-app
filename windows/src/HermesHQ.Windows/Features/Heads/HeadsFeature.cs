using Hermes.Core;
using Hermes.Core.Heads;
using Hermes.Core.Model;
using HermesHQ.Controls;
using HermesHQ.Services;
using Microsoft.UI.Xaml;

namespace HermesHQ.Features.Heads;

/// Robot heads (PARITY "Bots": drawn from `ui_meta["dispatch-head"]`, Edit Head). Every face in the app goes through
/// `BotHead.Renderer`, so the sidebar, the chat header and the session rows all draw the real head (or the bot's photo).
public static class HeadsFeature
{
    static HermesClient? _client;

    public static void Register()
    {
        BotHead.Renderer = (bot, name, size) =>
        {
            Sync();
            return new HeadFace(bot, name, size);
        };
    }

    /// The signed-in account's gateway for photos and saves: a new account forgets every face of the one before.
    static void Sync()
    {
        if (ReferenceEquals(_client, AppState.Client)) return;
        _client = AppState.Client;
        HeadStore.Forget();
        BotPhotos.Shared.Rpc = _client is { } c ? c.Rpc.RequestAsync : null;
    }

    /// Edit Head (spec 1x-settings §7) for a bot, as a dialog over the window. True when a head was saved or reset.
    /// The bots feature calls this from Bot Info / the bot row's menu.
    public static Task<bool> EditHead(Bot bot, XamlRoot? root = null)
    {
        Sync();
        var xamlRoot = root ?? App.Window?.Content?.XamlRoot;
        if (_client is not { } client || xamlRoot == null) return Task.FromResult(false);
        return EditHeadDialog.ShowAsync(bot, client, xamlRoot);
    }
}
