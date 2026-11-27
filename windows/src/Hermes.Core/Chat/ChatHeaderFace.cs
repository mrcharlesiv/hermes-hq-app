using Hermes.Core.Heads;
using Hermes.Core.Model;

namespace Hermes.Core.Chat;

/// The face left of a chat's name in its header (AppModel.makeChatScreen at 93f984bb1): the chat's own bot, by its
/// profile (`HeadView.configure(raw: model.head, profile: model.profile)`), never by the chat's title.
/// [session-title-clean] Only a bot's own chat shows it; a session's title is its words alone.
public static class ChatHeaderFace
{
    /// The header's face, or null for none. `botChat`: the chat was opened as the bot's own chat (the Mac's
    /// `menus.isBotChat`); a chat titled "Bot Chat" is one too (`LiveChatSession.isBotChat`). `bots`: the roster's bot
    /// for a profile, null when it isn't listed (its face is then the profile's default head).
    public static Face? For(string profile, string title, bool botChat, Func<string, Bot?> bots)
    {
        if (!botChat && title != Bot.BotChatTitle) return null;
        return new Face(profile, bots(profile));
    }

    /// A bot's face: its row (with its saved head and photo) when the roster has it, else its profile's name.
    public sealed record Face(string Profile, Bot? Bot)
    {
        /// The head drawn (a photo, when the bot wears one, is drawn over it by the app).
        public Head Head => Bot is { } bot ? HeadStore.HeadOf(bot) : Head.DefaultHead(Profile);
    }
}
