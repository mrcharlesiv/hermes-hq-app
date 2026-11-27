namespace Hermes.Core.Shell;

public sealed class ReplyGap(string reason) : Exception(reason);

/// The shell adapter has a verified Notification Center window. There is deliberately no desktop root, click,
/// arbitrary button, point or fallback on this interface. UIA names outside the fixture group are never logged.
public interface IReplyView<T> where T : class
{
    IReadOnlyList<T> AppGroups();
    IReadOnlyList<T> ExactBodyTexts(T group, string body);
    T? ListItemContaining(T text, T group);
    bool IsPlainRow(T row, string title, string body);
}

/// Facts from a child of the one matched notification row. No arbitrary action or coordinates cross this seam.
public sealed record ReplyChild(string Role, string Name, string Id, bool Local, bool Password, bool Interactive);

public static class ReplySelection
{
    public static bool Plain(IEnumerable<ReplyChild> children, string title, string body)
    {
        var titles = 0;
        var bodies = 0;
        foreach (var c in children)
        {
            if (!c.Local || c.Password) return false;
            // These two are shell chrome, never invocation targets. Anything resembling an app action is refused.
            if (c is { Role: "Button", Id: "DismissButton", Name: "Dismiss notification" }
                or { Role: "Button", Id: "MoreButton", Name: "More options" }) continue;
            if (c.Interactive) return false;
            if (c.Role is "Image" or "Pane" && c.Name.Length == 0) continue;
            if (c.Role != "Text") return false;
            if (c.Name == title) titles++;
            else if (c.Name == body) bodies++;
            else return false;
        }
        return titles == 1 && bodies == 1;
    }

    public static T Select<T>(IReplyView<T> view, DesktopProof proof, ReplyPhase phase) where T : class
    {
        var groups = view.AppGroups();
        if (groups.Count != 1) throw new ReplyGap("missing or ambiguous test-app group");
        var group = groups[0];
        var body = proof.Body(phase);
        var texts = view.ExactBodyTexts(group, body);
        if (texts.Count != 1) throw new ReplyGap("missing or ambiguous fixture reply");
        var row = view.ListItemContaining(texts[0], group);
        if (row == null || !view.IsPlainRow(row, ToastsWalkProof.Sender, body)) throw new ReplyGap("not a unique plain notification body");
        return row;
    }
}
