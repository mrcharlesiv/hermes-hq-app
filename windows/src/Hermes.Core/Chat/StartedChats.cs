namespace Hermes.Core.Chat;

/// Chats this app just started (`session.create` through SessionStore.NewChatAsync) and hasn't opened yet: the Mac's
/// `startsNew` (HermesKit/Chat/LiveChatSession.swift). Hermes stores such a chat with its first prompt, so until then
/// its REST history answers 404; the first open of one skips that read and only resumes ("A chat just made has no
/// stored rows yet: only the resume (to bind its runtime) runs"). The mark is taken by that first open, so a later open
/// of the same id reads its history as any chat's does.
public static class StartedChats
{
    private static readonly HashSet<string> Marks = [];

    private static string Key(string profile, string storedId) => $"{profile}\u0001{storedId}";

    public static void Note(string profile, string storedId)
    {
        lock (Marks) Marks.Add(Key(profile, storedId));
    }

    /// True once for a chat noted as just started (the mark is removed).
    public static bool Take(string profile, string storedId)
    {
        lock (Marks) return Marks.Remove(Key(profile, storedId));
    }
}
