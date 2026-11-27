using System.Text.RegularExpressions;

namespace Hermes.Core.Groups;

// [groups] Stop / resume directives in your own room messages (HermesKit/Groups/GroupHolds.swift; docs/spec/3x-groups.md
// §6.4): a port of `classifyGroupHoldDirective`, `maskQuotedAndCodeSpans`, `stopWordPlacement` and
// `applyGroupHoldDirective` (`HB/group-rounds.ts:240-415`). Pure.
public static class GroupHolds
{
    public enum Placement { Adjacent, Distant }

    public sealed record Action(IReadOnlyList<string> Hold, bool HoldAll, IReadOnlyList<string> Release, bool ReleaseAll)
    {
        public static Action Of(IReadOnlyList<string>? hold = null, bool holdAll = false, IReadOnlyList<string>? release = null, bool releaseAll = false) =>
            new(hold ?? [], holdAll, release ?? [], releaseAll);
        public bool Equals(Action? o) => o != null && Hold.SequenceEqual(o.Hold) && HoldAll == o.HoldAll && Release.SequenceEqual(o.Release) && ReleaseAll == o.ReleaseAll;
        public override int GetHashCode() => HashCode.Combine(HoldAll, ReleaseAll, Hold.Count, Release.Count);
    }

    private static readonly Regex MentionToken = new(@"@[\p{L}\p{N}._-]+", RegexOptions.CultureInvariant);
    private static readonly Regex Token = new(@"@[\p{L}\p{N}._-]+|[\p{L}\p{N}_-]+", RegexOptions.CultureInvariant);
    private static readonly Regex FenceOpen = new(@"^\s*(`{3,}|~{3,})", RegexOptions.CultureInvariant);
    private static readonly Regex InlineCode = new(@"`[^`\n]*`", RegexOptions.CultureInvariant);
    private static readonly Regex Quoted = new("[\"“”][^\"“”\\n]*[\"“”]", RegexOptions.CultureInvariant);
    private static readonly Regex QuoteLine = new(@"^\s*>", RegexOptions.CultureInvariant);

    private static string MentionsOnly(string span)
    {
        var found = MentionToken.Matches(span).Select(m => m.Value).ToList();
        return found.Count == 0 ? "quoted" : string.Join(" ", found);
    }

    /// Fenced code, `>` quotes, inline code and quoted strings reduced to their @mentions (so a quoted "stop" is not a
    /// command).
    public static string Masked(string value)
    {
        var kept = new List<string>();
        var fence = "";
        foreach (var line in value.Split('\n'))
        {
            if (fence.Length > 0)
            {
                var closing = line.Trim(' ', '\t').StartsWith(fence, StringComparison.Ordinal);
                kept.Add(closing ? "" : MentionsOnly(line));
                if (closing) fence = "";
                continue;
            }
            if (FenceOpen.Match(line) is { Success: true } opened)
            {
                fence = opened.Groups[1].Value;
                continue;
            }
            if (QuoteLine.IsMatch(line))
            {
                kept.Add(MentionsOnly(line));
                continue;
            }
            kept.Add(Quoted.Replace(InlineCode.Replace(line, m => MentionsOnly(m.Value)), m => MentionsOnly(m.Value)));
        }
        return string.Join("\n", kept);
    }

    public static Placement? StopWordPlacement(string value)
    {
        var tokens = Token.Matches(Masked(value).ToLowerInvariant()).Select(m => m.Value).ToList();
        var mentionAt = new List<int>();
        var stopAt = new List<int>();
        for (var i = 0; i < tokens.Count; i++)
        {
            if (tokens[i].StartsWith('@')) mentionAt.Add(i);
            else if (tokens[i] is "stop" or "halt" or "pause") stopAt.Add(i);
        }
        if (stopAt.Any(stop => mentionAt.Any(m => Math.Abs(stop - m) <= 2))) return Placement.Adjacent;
        return stopAt.Count == 0 ? null : Placement.Distant;
    }

    public static Action Classify(string text, IReadOnlyList<string> mentioned, bool everyone)
    {
        var stop = StopWordPlacement(text);
        if (stop == Placement.Adjacent) return Action.Of(hold: mentioned, holdAll: everyone);
        return Action.Of(release: stop == Placement.Distant ? [] : mentioned, releaseAll: stop == null && everyone);
    }

    public static Dictionary<string, GroupHold> Apply(IReadOnlyDictionary<string, GroupHold> holds, GroupMentions.Parsed mentions, string text,
        GroupHold stamp, IReadOnlyList<string> allMemberKeys)
    {
        var action = Classify(text, mentions.Mentioned, mentions.Everyone);
        if (action.ReleaseAll) return [];
        var next = new Dictionary<string, GroupHold>(holds);
        foreach (var key in action.HoldAll ? allMemberKeys : action.Hold) next[key] = stamp;
        foreach (var key in action.Release) next.Remove(key);
        return next;
    }
}
