using System.Text.RegularExpressions;

namespace Hermes.Core.Groups;

// [groups] @mentions in a room (HermesKit/Groups/GroupMentions.swift; docs/spec/3x-groups.md §6.3): a port of
// `parseGroupChatMentions` and the tag helpers of `HB/data.ts`. Pure.
public static class GroupMentions
{
    private static readonly Regex Mention = new("@([a-z0-9][a-z0-9._-]*)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    private static readonly HashSet<string> Reserved = ["all", "everyone", "user", "default", "hermes"];
    private static readonly Regex Tag = new("^[a-z0-9][a-z0-9_-]*$");

    private static string Replacing(string text, string pattern, string with) => Regex.Replace(text, pattern, with);

    /// `botHandle`: `hermes` for the default profile, else the row's handle or the name.
    public static string Handle(string name, string? saved)
    {
        if (name == "default") return "hermes";
        var s = (saved ?? "").Trim(' ', '\t');
        return s.Length == 0 || s == "default" ? name : s;
    }

    /// `mentionNameForms`: a friendly name's slug ("research-buddy") and collapsed form ("researchbuddy"); never a
    /// reserved word, always a valid tag.
    public static List<string> NameForms(string friendly)
    {
        var lower = friendly.ToLowerInvariant().Trim();
        if (lower.Length == 0) return [];
        var slug = Replacing(lower, "[^a-z0-9_-]+", "-").Trim('-');
        var collapsed = Replacing(lower, "[^a-z0-9_-]+", "");
        var o = new List<string>();
        foreach (var form in new[] { slug, collapsed })
        {
            if (o.Contains(form) || !Tag.IsMatch(form) || Reserved.Contains(form)) continue;
            o.Add(form);
        }
        return o;
    }

    /// `botMentionTag`: the first form of the member's friendly names, else its handle.
    public static string TagFor(GroupSeat seat)
    {
        foreach (var friendly in seat.Friendly)
            if (NameForms(friendly) is [var first, ..]) return first;
        return seat.Handle;
    }

    /// Every form → member key, built with the web's precedence (live identities claim first; slugs and earlier
    /// names only fill gaps).
    public static Dictionary<string, string> Handles(IReadOnlyList<GroupSeat> seats)
    {
        var handles = new Dictionary<string, string>();
        foreach (var seat in seats)
        {
            var name = seat.Name.ToLowerInvariant();
            var title = (seat.Title ?? "").Trim();
            var handle = seat.Handle.Trim(' ', '\t').ToLowerInvariant();
            var forms = new List<string> { name, Replacing(name, @"[\s_-]+", "") };
            if (handle.Length > 0) forms.AddRange([handle, Replacing(handle, @"[\s_-]+", "")]);
            if (title.Length > 0)
            {
                var lower = title.ToLowerInvariant();
                forms.AddRange([lower, Replacing(lower, @"[\s_-]+", ""), lower.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? ""]);
            }
            foreach (var friendly in seat.Friendly) forms.AddRange(NameForms(friendly));
            if (!seat.Remote) forms.Add($"{name}-local");
            foreach (var form in forms.Where(f => f.Length > 0)) handles[form] = seat.Key;
            foreach (var raw in new[] { seat.Name, seat.Handle, title }.Concat(seat.Friendly))
                foreach (var form in NameForms(raw)) handles.TryAdd(form, seat.Key);
        }
        foreach (var seat in seats)
            foreach (var previous in seat.PreviousNames)
                foreach (var form in NameForms(previous)) handles.TryAdd(form, seat.Key);
        return handles;
    }

    public sealed record Parsed(bool Everyone, IReadOnlyList<string> Mentioned)
    {
        public static readonly Parsed None = new(false, []);
        public bool Equals(Parsed? other) => other != null && Everyone == other.Everyone && Mentioned.SequenceEqual(other.Mentioned);
        public override int GetHashCode() => Everyone.GetHashCode();
    }

    public static Parsed Parse(string text, IReadOnlyList<GroupSeat> seats)
    {
        var everyone = false;
        var mentioned = new List<string>();
        var handles = Handles(seats);
        foreach (Match m in Mention.Matches(text))
        {
            var handle = m.Groups[1].Value.ToLowerInvariant();
            if (handle is "everyone" or "all") { everyone = true; continue; }
            if (handle == "user") continue;
            var resolved = handles.GetValueOrDefault(handle) ?? handles.GetValueOrDefault(Replacing(handle, "[._-]+", ""));
            if (resolved != null && !mentioned.Contains(resolved)) mentioned.Add(resolved);
        }
        return new Parsed(everyone, mentioned);
    }

    /// The `@word` being typed at the end of `text` (the composer's suggestion list); null when the caret is not in one.
    public static string? TypingQuery(string text)
    {
        var at = text.LastIndexOf('@');
        if (at < 0) return null;
        if (at > 0 && !char.IsWhiteSpace(text[at - 1])) return null;
        var tail = text[(at + 1)..];
        if (tail.Any(char.IsWhiteSpace)) return null;
        return tail.ToLowerInvariant();
    }
}
