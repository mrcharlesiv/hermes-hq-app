namespace HermesHQ.Features.Bots;

/// The Bots list (spec 02 §5–§8, docs/spec/3x-botslist.md): the sidebar's bots, their menus, Bot Info, New Bot, sections,
/// pin, hide, mute, Duplicate and Delete. The rows live in the sidebar (Shell/, Pages/ShellPage); the data in
/// Hermes.Core.Bots through `ListsHub`.
public static class BotsFeature
{
    public static void Register()
    {
        // Change Face… in the bot's menu opens the heads feature's editor (Edit Head); the heads feature draws faces.
        BotActions.ChangeFace = (bot, root) => _ = Heads.HeadsFeature.EditHead(bot.Model, root);
    }
}
