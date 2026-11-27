using System.Text.Json.Nodes;
using Hermes.Core.Chat;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Shell;

/// [WIN-43] What the chat-actions walk (HermesHQ.Windows/Services/ProofWalks.ChatActions.cs) checks, on the composer
/// stand-in's Trip planning chat (menus-gateway.py `TRIP`): the reply's right-click menu in the Mac's order, and that
/// Branch in New Chat went over the wire as `session.branch {count}` and opened the branch with the Mac's notice. Each
/// check answers null when right, otherwise the words of what is wrong.
public static class ChatActionsProof
{
    public const string TripStoredId = "20261005_090000_menus001";
    public const string TripTitle = "Trip planning";
    public const string TripBot = "default";

    /// A settled reply's menu under its tiles, in the Mac's order (MessageMenuModel.rows for a latest reply without
    /// hidden steps): Select Text, Regenerate, Branch in New Chat.
    public static readonly IReadOnlyList<string> LatestReplyRows = ["Copy", "Share…", "Select Text", "Regenerate", "Branch in New Chat"];

    /// The menu's entries as shown (after its title and separator) carry the Mac's rows in order, none dimmed.
    public static string? MenuReads(IReadOnlyList<(string Title, bool Enabled)> entries)
    {
        var titles = entries.Select(e => e.Title).Where(LatestReplyRows.Contains).ToList();
        if (!titles.SequenceEqual(LatestReplyRows))
            return $"the reply's menu reads {string.Join(", ", titles)}, not {string.Join(", ", LatestReplyRows)}";
        if (entries.FirstOrDefault(e => LatestReplyRows.Contains(e.Title) && !e.Enabled) is { Title: { } off } )
            return $"{off} is dimmed on a settled reply";
        return null;
    }

    /// After `mark` the stand-in took exactly one branch: `session.branch` on the chat with `count` (the messages up
    /// to and including the reply), and no prompt of any kind.
    public static string? Branched(JsonNode? menusState, double mark, int count)
    {
        var calls = (menusState.Arr("calls") ?? []).OfType<JsonNode>().Where(c => (c.Num("at") ?? 0) > mark).ToList();
        var branches = calls.Where(c => c.Str("method") is "session.branch" or "session.branch_stored" or "session.create").ToList();
        if (branches.Count != 1) return $"the stand-in took {branches.Count} branch calls, not 1";
        var b = branches[0];
        if (b.Str("method") != "session.branch") return $"the branch went as {b.Str("method")}, not session.branch";
        if (b["params"].Num("count") is not { } n || (int)n != count) return $"the branch's count was {b["params"].Num("count")}, not {count}";
        if (calls.FirstOrDefault(c => WalkProof.PromptMethods.Contains(c.Str("method") ?? "")) is { } prompt)
            return $"the branch also sent {prompt.Str("method")}";
        return null;
    }

    /// The chat on screen after Branch: a new stored id, titled "Branch of <parent>", saying "Branched into a new chat.".
    public static string? BranchOpened(string? storedId, string? title, string? notice, string parentId, string parentTitle)
    {
        if (storedId == null || storedId == parentId) return "the branch didn't open in the chat's place";
        if (title != ChatActionWords.BranchTitle(parentTitle)) return $"the branch is titled {title}, not {ChatActionWords.BranchTitle(parentTitle)}";
        if (notice != ChatActionWords.Branched) return $"the notice reads {notice ?? "nothing"}, not {ChatActionWords.Branched}";
        return null;
    }
}
