using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Hermes.Core.Transcripts;

// [mermaid] Pure offline parser for Mermaid fenced code blocks (Mac 8094c82cb + M5 Cartesian fan-out overflow guard:
// HermesKit/Chat/MermaidParser.swift). Zero WinUI dependencies so layout and unit tests run off-main and on Mac.

public enum MermaidDirection { TopDown, BottomUp, LeftRight, RightLeft }

public enum MermaidNodeShape { Rect, Rounded, Stadium, Diamond, Circle, Cylinder, Hexagon }

public enum MermaidEdgeStyle { Solid, Dashed, Thick, Open }

public sealed record MermaidFlowNode(string Id, string Label, MermaidNodeShape Shape, string? Subgraph = null);

public sealed record MermaidFlowEdge(string From, string To, string Label, MermaidEdgeStyle Style, bool Directed);

public sealed record MermaidFlowSubgraph(string Id, string Title);

public sealed record MermaidSequenceMessage(string From, string To, string Text, bool Dashed, bool OpenArrow);

public sealed record MermaidPieSlice(string Label, double Value);

public abstract record MermaidKind
{
    public sealed record Flowchart(
        MermaidDirection Direction,
        IReadOnlyList<MermaidFlowNode> Nodes,
        IReadOnlyList<MermaidFlowEdge> Edges,
        IReadOnlyList<MermaidFlowSubgraph> Subgraphs) : MermaidKind;

    public sealed record Sequence(
        IReadOnlyList<string> Participants,
        IReadOnlyList<MermaidSequenceMessage> Messages) : MermaidKind;

    public sealed record State(
        IReadOnlyList<MermaidFlowNode> Nodes,
        IReadOnlyList<MermaidFlowEdge> Edges) : MermaidKind;

    public sealed record Pie(
        string Title,
        bool ShowData,
        IReadOnlyList<MermaidPieSlice> Slices) : MermaidKind;

    public sealed record Generic(
        string Title,
        IReadOnlyList<string> Lines) : MermaidKind;
}

public sealed record MermaidDiagram(string Source, MermaidKind Kind)
{
    public string KindLabel => Kind switch
    {
        MermaidKind.Flowchart => "Flowchart",
        MermaidKind.Sequence => "Sequence Diagram",
        MermaidKind.State => "State Diagram",
        MermaidKind.Pie => "Pie Chart",
        MermaidKind.Generic g => string.IsNullOrEmpty(g.Title) ? "Mermaid Diagram" : g.Title,
        _ => "Mermaid Diagram",
    };
}

public static class MermaidParser
{
    /// The most a diagram may hold and still be drawn; anything bigger stays a code block.
    public const int MaxSourceLength = 60_000;
    public const int MaxLines = 600;
    public const int MaxLineLength = 1_200;
    public const int MaxNodes = 160;
    public const int MaxEdges = 400;
    public const int MaxParticipants = 16;
    public const int MaxMessages = 120;
    public const int MaxSlices = 24;

    /// A slice bigger than this isn't a count of anything; it also keeps the total a finite number.
    public const double MaxPieValue = 1e15;

    private static readonly TimeSpan RxTimeout = TimeSpan.FromMilliseconds(250);

    private static readonly (string Prefix, string Title)[] KnownGenericPrefixes =
    [
        ("classdiagram", "Class Diagram"),
        ("erdiagram", "ER Diagram"),
        ("gantt", "Gantt Chart"),
        ("journey", "User Journey"),
        ("gitgraph", "Git Graph"),
        ("mindmap", "Mindmap"),
        ("timeline", "Timeline"),
        ("quadrantchart", "Quadrant Chart"),
        ("xychart", "XY Chart"),
        ("sankey", "Sankey Diagram"),
        ("c4context", "C4 Diagram"),
        ("c4container", "C4 Diagram"),
        ("c4component", "C4 Diagram"),
        ("c4dynamic", "C4 Diagram"),
        ("c4deployment", "C4 Diagram"),
        ("c4", "C4 Diagram"),
    ];

    /// Whether a code fence language names Mermaid (`mermaid` or `mmd`).
    public static bool IsMermaidLanguage(string? language)
    {
        if (string.IsNullOrWhiteSpace(language)) return false;
        var raw = language.Trim().ToLowerInvariant();
        return raw is "mermaid" or "mmd";
    }

    /// Parses a Mermaid source string into a structured diagram; returns null if empty, over limits, or not a diagram.
    public static MermaidDiagram? Parse(string? source)
    {
        if (string.IsNullOrEmpty(source) || source.Length > MaxSourceLength) return null;
        var normalized = source.Replace("\r\n", "\n").Replace('\r', '\n');
        var rawLines = WithoutFrontMatter(normalized.Split('\n'));
        if (rawLines.Count > MaxLines) return null;

        var lines = new List<string>(rawLines.Count);
        foreach (var raw in rawLines)
        {
            if (CleanLine(raw) is { } cleaned)
            {
                if (cleaned.Length > MaxLineLength) return null;
                lines.Add(cleaned);
            }
        }
        if (lines.Count == 0) return null;

        var lower = lines[0].ToLowerInvariant();
        try
        {
            if (lower.StartsWith("flowchart", StringComparison.Ordinal) || lower.StartsWith("graph", StringComparison.Ordinal))
            {
                var flow = ParseFlowchart(lines);
                if (flow.Nodes.Count > 0 && flow.Nodes.Count <= MaxNodes && flow.Edges.Count <= MaxEdges)
                    return new MermaidDiagram(source, flow);
                return null;
            }
            if (lower.StartsWith("sequencediagram", StringComparison.Ordinal))
            {
                var seq = ParseSequence(lines.Skip(1));
                if ((seq.Participants.Count > 0 || seq.Messages.Count > 0)
                    && seq.Participants.Count <= MaxParticipants && seq.Messages.Count <= MaxMessages)
                    return new MermaidDiagram(source, seq);
                return null;
            }
            if (lower.StartsWith("statediagram", StringComparison.Ordinal))
            {
                var state = ParseState(lines.Skip(1));
                if (state.Nodes.Count > 0 && state.Nodes.Count <= MaxNodes && state.Edges.Count <= MaxEdges)
                    return new MermaidDiagram(source, state);
                return null;
            }
            if (lower == "pie" || lower.StartsWith("pie ", StringComparison.Ordinal))
            {
                var pie = ParsePie(lines);
                if (pie.Slices.Count > 0 && pie.Slices.Count <= MaxSlices)
                    return new MermaidDiagram(source, pie);
                return null;
            }
            foreach (var (prefix, title) in KnownGenericPrefixes)
            {
                if (!lower.StartsWith(prefix, StringComparison.Ordinal)) continue;
                var body = lines.Skip(1).Take(24).ToList();
                if (body.Count == 0) return null;
                return new MermaidDiagram(source, new MermaidKind.Generic(title, body));
            }
        }
        catch (RegexMatchTimeoutException)
        {
            return null;
        }
        return null;
    }

    /// Strips a YAML front matter block (`---` … `---`) at the top.
    private static List<string> WithoutFrontMatter(string[] lines)
    {
        var start = -1;
        for (var i = 0; i < lines.Length; i++)
        {
            if (!string.IsNullOrWhiteSpace(lines[i])) { start = i; break; }
        }
        if (start < 0 || lines[start].Trim() != "---") return [.. lines];
        var end = -1;
        for (var i = start + 1; i < lines.Length; i++)
        {
            if (lines[i].Trim() == "---") { end = i; break; }
        }
        if (end < 0) return [.. lines];
        var rest = new List<string>(lines.Length - (end + 1));
        for (var i = end + 1; i < lines.Length; i++) rest.Add(lines[i]);
        return rest;
    }

    private static string? CleanLine(string raw)
    {
        var line = raw.Trim();
        if (line.Length == 0 || line.StartsWith("%%", StringComparison.Ordinal)) return null;
        var comment = line.IndexOf("%%", StringComparison.Ordinal);
        if (comment >= 0) line = line[..comment].Trim();
        return line.Length == 0 ? null : line;
    }

    // MARK: Flowchart / Graph

    private readonly record struct ParsedNode(string Id, string Label, MermaidNodeShape Shape);
    private readonly record struct RawEdgeOp(int Start, int Length, MermaidEdgeStyle Style, bool Directed, string Label);

    private static MermaidKind.Flowchart ParseFlowchart(List<string> lines)
    {
        var headerStatements = SplitStatements(lines[0]);
        var headerFirst = headerStatements.Count > 0 ? headerStatements[0] : "";
        var headerParts = headerFirst.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        var dirToken = headerParts.Length > 1 ? headerParts[1].ToUpperInvariant() : "TD";
        var direction = dirToken switch
        {
            "LR" => MermaidDirection.LeftRight,
            "RL" => MermaidDirection.RightLeft,
            "BT" => MermaidDirection.BottomUp,
            _ => MermaidDirection.TopDown,
        };

        var body = new List<string>(headerStatements.Count - 1 + lines.Count - 1);
        for (var i = 1; i < headerStatements.Count; i++) body.Add(headerStatements[i]);
        for (var i = 1; i < lines.Count; i++) body.Add(lines[i]);

        var nodes = new List<MermaidFlowNode>();
        var nodeIndex = new Dictionary<string, int>(StringComparer.Ordinal);
        var edges = new List<MermaidFlowEdge>();
        var subgraphs = new List<MermaidFlowSubgraph>();
        var subgraphStack = new List<string>();

        void UpsertNode(ParsedNode parsed)
        {
            var currentSg = subgraphStack.Count > 0 ? subgraphStack[^1] : null;
            if (nodeIndex.TryGetValue(parsed.Id, out var idx))
            {
                var existing = nodes[idx];
                var label = existing.Label;
                var shape = existing.Shape;
                if (parsed.Label != parsed.Id || parsed.Shape != MermaidNodeShape.Rect)
                {
                    label = parsed.Label;
                    shape = parsed.Shape;
                }
                var sg = existing.Subgraph ?? currentSg;
                nodes[idx] = existing with { Label = label, Shape = shape, Subgraph = sg };
            }
            else
            {
                nodeIndex[parsed.Id] = nodes.Count;
                nodes.Add(new MermaidFlowNode(parsed.Id, parsed.Label, parsed.Shape, currentSg));
            }
        }

        foreach (var raw in body)
        {
            foreach (var stmt in SplitStatements(raw))
            {
                var s = stmt.Trim();
                if (s.Length == 0) continue;
                var low = s.ToLowerInvariant();
                if (low.StartsWith("style ", StringComparison.Ordinal)
                    || low.StartsWith("classdef ", StringComparison.Ordinal)
                    || low.StartsWith("class ", StringComparison.Ordinal)
                    || low.StartsWith("linkstyle ", StringComparison.Ordinal)
                    || low.StartsWith("click ", StringComparison.Ordinal)
                    || low.StartsWith("direction ", StringComparison.Ordinal))
                    continue;

                if (low.StartsWith("subgraph", StringComparison.Ordinal))
                {
                    var rest = s["subgraph".Length..].Trim();
                    var sgId = rest.Length == 0 ? $"sg{subgraphs.Count + 1}" : ExtractSubgraphId(rest);
                    var sgTitle = ExtractSubgraphTitle(rest, sgId);
                    subgraphs.Add(new MermaidFlowSubgraph(sgId, sgTitle));
                    subgraphStack.Add(sgId);
                    continue;
                }
                if (low == "end")
                {
                    if (subgraphStack.Count > 0) subgraphStack.RemoveAt(subgraphStack.Count - 1);
                    continue;
                }

                // M5 Cartesian fan-out overflow guard: enforce edge budget before materializing product edges.
                var chain = ParseEdgeChain(s, MaxEdges - edges.Count);
                if (chain.Overflowed)
                    return new MermaidKind.Flowchart(direction, [], [], []);

                if (chain.Edges.Count == 0)
                {
                    if (ParseNodeToken(s) is { } single) UpsertNode(single);
                }
                else
                {
                    foreach (var node in chain.Nodes)
                    {
                        UpsertNode(node);
                        if (nodes.Count > MaxNodes)
                            return new MermaidKind.Flowchart(direction, [], [], []);
                    }
                    edges.AddRange(chain.Edges);
                }

                if (nodes.Count > MaxNodes || edges.Count > MaxEdges)
                    return new MermaidKind.Flowchart(direction, [], [], []);
            }
        }

        return new MermaidKind.Flowchart(direction, nodes, edges, subgraphs);
    }

    private static List<string> SplitStatements(string line)
    {
        var output = new List<string>();
        var cur = new StringBuilder();
        var inQuote = false;
        var depth = 0;
        foreach (var ch in line)
        {
            if (ch == '"') inQuote = !inQuote;
            if (!inQuote)
            {
                if (ch is '[' or '(' or '{') depth++;
                else if (ch is ']' or ')' or '}') depth = Math.Max(0, depth - 1);
                else if (ch == ';' && depth == 0)
                {
                    output.Add(cur.ToString());
                    cur.Clear();
                    continue;
                }
            }
            cur.Append(ch);
        }
        if (cur.Length > 0) output.Add(cur.ToString());
        return output;
    }

    private static string ExtractSubgraphId(string rest)
    {
        var bracket = rest.IndexOf('[');
        if (bracket >= 0)
        {
            var prefix = rest[..bracket].Trim();
            if (prefix.Length > 0) return prefix;
        }
        return rest.Trim('"', '\'', ' ');
    }

    private static string ExtractSubgraphTitle(string rest, string fallback)
    {
        var open = rest.IndexOf('[');
        var close = rest.LastIndexOf(']');
        if (open >= 0 && close > open)
        {
            var inner = rest[(open + 1)..close].Trim('"', '\'', ' ');
            if (inner.Length > 0) return inner;
        }
        var cleaned = rest.Trim('"', '\'', ' ');
        return cleaned.Length == 0 ? fallback : cleaned;
    }

    /// Parses chained edges (`A[Start] --> B{Check} -->|Yes| C((Done))`) and `&` fan-outs (`A & B --> C`).
    private static (List<ParsedNode> Nodes, List<MermaidFlowEdge> Edges, bool Overflowed) ParseEdgeChain(string line, int edgeBudget)
    {
        var ops = FindEdgeOperators(line);
        if (ops.Count == 0) return ([], [], false);

        var segments = new List<string>(ops.Count + 1);
        var cursor = 0;
        foreach (var op in ops)
        {
            segments.Add(line[cursor..op.Start].Trim());
            cursor = op.Start + op.Length;
        }
        segments.Add(line[cursor..].Trim());

        var allNodes = new List<ParsedNode>();
        var segmentNodes = new List<List<ParsedNode>>(segments.Count);
        foreach (var seg in segments)
        {
            var group = new List<ParsedNode>();
            foreach (var piece in SplitAmpersand(seg))
                if (ParseNodeToken(piece) is { } parsed)
                    group.Add(parsed);
            segmentNodes.Add(group);
            allNodes.AddRange(group);
        }

        var edges = new List<MermaidFlowEdge>();
        for (var i = 0; i < ops.Count; i++)
        {
            if (i + 1 >= segmentNodes.Count) break;
            var leftCount = segmentNodes[i].Count;
            var rightCount = segmentNodes[i + 1].Count;
            // M5 Cartesian fan-out overflow guard: reject before multiplying or allocating.
            if (leftCount > 0 && rightCount > 0)
            {
                var remaining = edgeBudget - edges.Count;
                if (remaining <= 0 || leftCount > remaining / rightCount)
                    return ([], [], true);
            }
            var op = ops[i];
            foreach (var lhs in segmentNodes[i])
                foreach (var rhs in segmentNodes[i + 1])
                    edges.Add(new MermaidFlowEdge(lhs.Id, rhs.Id, op.Label, op.Style, op.Directed));
        }

        return (allNodes, edges, false);
    }

    private sealed record EdgePattern(Regex Regex, MermaidEdgeStyle Style, bool Directed, int? LabelGroup);

    private static readonly EdgePattern[] EdgePatterns = BuildEdgePatterns();

    private static EdgePattern[] BuildEdgePatterns()
    {
        const string words = @"((?:[^\-\n>|]|-(?!-))+?)";
        (string Pattern, MermaidEdgeStyle Style, bool Directed, int? LabelGroup)[] table =
        [
            (@"-\.+\s*([^.\-\n>|]+?)\s*\.+->", MermaidEdgeStyle.Dashed, true, 1),               // A -. text .-> B
            (@"(?<![=<])==\s*([^=\n>|]+?)\s*={2,}>", MermaidEdgeStyle.Thick, true, 1),          // A == text ==> B
            (@"(?<![-<])--(?!-)\s*" + words + @"\s*-{2,}>", MermaidEdgeStyle.Solid, true, 1),   // A -- text --> B
            (@"(?<![-<])--(?!-)\s*" + words + @"\s*-{3,}(?!>)", MermaidEdgeStyle.Open, false, 1), // A -- text --- B
            (@"<?-\.+->\s*\|([^|\n]*)\|", MermaidEdgeStyle.Dashed, true, 1),                    // A -.->|text| B
            (@"<?={2,}>\s*\|([^|\n]*)\|", MermaidEdgeStyle.Thick, true, 1),                     // A ==>|text| B
            (@"<?-{2,}>\s*\|([^|\n]*)\|", MermaidEdgeStyle.Solid, true, 1),                     // A -->|text| B
            (@"-{3,}\s*\|([^|\n]*)\|", MermaidEdgeStyle.Open, false, 1),                        // A ---|text| B
            (@"<?-\.+->", MermaidEdgeStyle.Dashed, true, null),
            (@"-\.+-", MermaidEdgeStyle.Dashed, false, null),
            (@"<?={2,}>", MermaidEdgeStyle.Thick, true, null),
            (@"={3,}", MermaidEdgeStyle.Thick, false, null),
            (@"<?-{2,}>", MermaidEdgeStyle.Solid, true, null),                                  // -->, --->, <-->
            (@"(?<=\s)[ox]-{2,}[ox](?=\s|$)", MermaidEdgeStyle.Open, false, null),              // A o--o B, A x--x B
            (@"-{2,}[ox](?=\s|$)", MermaidEdgeStyle.Open, false, null),                         // A --o B, A --x B
            (@"-{3,}", MermaidEdgeStyle.Open, false, null),
        ];
        return
        [
            .. table.Select(t => new EdgePattern(
                new Regex(t.Pattern, RegexOptions.CultureInvariant | RegexOptions.Compiled, RxTimeout),
                t.Style, t.Directed, t.LabelGroup))
        ];
    }

    private static List<RawEdgeOp> FindEdgeOperators(string line)
    {
        // Mask bracketed and quoted spans per UTF-16 char so emoji offsets stay aligned 1:1 with `line`.
        var cleanChars = new char[line.Length];
        var inQuote = false;
        var depth = 0;
        for (var i = 0; i < line.Length; i++)
        {
            var ch = line[i];
            var hide = inQuote || depth > 0;
            if (ch == '"') { inQuote = !inQuote; hide = true; }
            else if (!inQuote)
            {
                if (ch is '[' or '(' or '{') { depth++; hide = true; }
                else if (ch is ']' or ')' or '}') { hide = hide || depth > 0; depth = Math.Max(0, depth - 1); }
            }
            cleanChars[i] = hide ? '_' : ch;
        }
        var clean = new string(cleanChars);

        var found = new List<RawEdgeOp>();
        var occupied = new List<(int Start, int End)>();

        foreach (var pat in EdgePatterns)
        {
            foreach (Match m in pat.Regex.Matches(clean))
            {
                var start = m.Index;
                var end = m.Index + m.Length;
                var overlaps = false;
                foreach (var occ in occupied)
                {
                    if (start < occ.End && occ.Start < end) { overlaps = true; break; }
                }
                if (overlaps) continue;
                var label = "";
                if (pat.LabelGroup is { } g && g < m.Groups.Count && m.Groups[g].Success)
                    label = CleanLabel(line.Substring(m.Groups[g].Index, m.Groups[g].Length));
                occupied.Add((start, end));
                found.Add(new RawEdgeOp(start, m.Length, pat.Style, pat.Directed, label));
            }
        }

        found.Sort((a, b) => a.Start.CompareTo(b.Start));
        return found;
    }

    private static List<string> SplitAmpersand(string segment)
    {
        var output = new List<string>();
        var cur = new StringBuilder();
        var inQuote = false;
        var depth = 0;
        foreach (var ch in segment)
        {
            if (ch == '"') inQuote = !inQuote;
            if (!inQuote)
            {
                if (ch is '[' or '(' or '{') depth++;
                else if (ch is ']' or ')' or '}') depth = Math.Max(0, depth - 1);
                else if (ch == '&' && depth == 0)
                {
                    output.Add(cur.ToString().Trim());
                    cur.Clear();
                    continue;
                }
            }
            cur.Append(ch);
        }
        var last = cur.ToString().Trim();
        if (last.Length > 0) output.Add(last);
        return output;
    }

    private static readonly (string Open, string Close, MermaidNodeShape Shape)[] NodeDelimiters =
    [
        ("(((", ")))", MermaidNodeShape.Circle),
        ("([", "])", MermaidNodeShape.Stadium),
        ("[(", ")]", MermaidNodeShape.Cylinder),
        ("[[", "]]", MermaidNodeShape.Rect),
        ("((", "))", MermaidNodeShape.Circle),
        ("{{", "}}", MermaidNodeShape.Hexagon),
        ("[/", "/]", MermaidNodeShape.Rect),
        ("[\\", "\\]", MermaidNodeShape.Rect),
        ("[/", "\\]", MermaidNodeShape.Rect),
        ("[\\", "/]", MermaidNodeShape.Rect),
        ("[", "]", MermaidNodeShape.Rect),
        ("(", ")", MermaidNodeShape.Rounded),
        ("{", "}", MermaidNodeShape.Diamond),
    ];

    private static ParsedNode? ParseNodeToken(string raw)
    {
        var token = raw.Trim();
        var cls = token.IndexOf(":::", StringComparison.Ordinal);
        if (cls >= 0) token = token[..cls].Trim();
        if (token.Length == 0) return null;

        var idEnd = 0;
        while (idEnd < token.Length)
        {
            var ch = token[idEnd];
            if (ch is '[' or '(' or '{') break;
            idEnd++;
        }
        var rawId = token[..idEnd].Trim();
        var rest = token[idEnd..].Trim();

        // Flag shape `A>Label]` has no bracket opener of its own.
        if (rest.Length == 0 && token.EndsWith(']'))
        {
            var flag = token.IndexOf('>');
            if (flag >= 0)
            {
                rawId = token[..flag].Trim();
                rest = "[" + token[(flag + 1)..];
            }
        }

        if (rawId.Length == 0) return null;
        if (rest.Length == 0) return new ParsedNode(rawId, rawId, MermaidNodeShape.Rect);

        foreach (var (open, close, shape) in NodeDelimiters)
        {
            if (rest.StartsWith(open, StringComparison.Ordinal)
                && rest.EndsWith(close, StringComparison.Ordinal)
                && rest.Length >= open.Length + close.Length)
            {
                var inner = rest[open.Length..(rest.Length - close.Length)];
                var label = CleanLabel(inner);
                return new ParsedNode(rawId, label.Length == 0 ? rawId : label, shape);
            }
        }
        return new ParsedNode(rawId, rawId, MermaidNodeShape.Rect);
    }

    private static readonly Regex TagPattern = new(@"</?[a-zA-Z][^<>]{0,40}>", RegexOptions.CultureInvariant | RegexOptions.Compiled, RxTimeout);
    private static readonly Regex IconPattern = new(@"\bfa[bsrl]?:fa-[a-z0-9-]+\s*", RegexOptions.CultureInvariant | RegexOptions.Compiled, RxTimeout);

    private static readonly (string Entity, string Replacement)[] Entities =
    [
        ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("#quot;", "\""),
        ("&nbsp;", " "), ("#amp;", "&"), ("#35;", "#"), ("&#39;", "'"), ("#lt;", "<"), ("#gt;", ">"),
    ];

    private static readonly string[] BreakTags = ["<br/>", "<br>", "<br />", "<BR/>", "<BR>", "<br >"];

    private static string CleanLabel(string s)
    {
        var output = Unquote(s);
        if (output.Length >= 2 && output[0] == '`' && output[^1] == '`')
            output = output[1..^1];
        foreach (var (entity, replacement) in Entities)
            output = output.Replace(entity, replacement, StringComparison.Ordinal);
        output = TagPattern.Replace(output, "");
        output = IconPattern.Replace(output, "");
        output = output.Replace("**", "", StringComparison.Ordinal);
        return string.Join("\n", output.Split('\n').Select(l => l.Trim())).Trim();
    }

    private static string Unquote(string s)
    {
        var output = s.Trim();
        if (output.Length >= 2
            && ((output[0] == '"' && output[^1] == '"') || (output[0] == '\'' && output[^1] == '\'')))
            output = output[1..^1];
        foreach (var br in BreakTags)
            output = output.Replace(br, "\n", StringComparison.Ordinal);
        return output;
    }

    // MARK: Sequence Diagram

    private static readonly Regex SequenceArrow = new(
        @"^(.+?)\s*(<<-->>|<<->>|-->>|->>|-->|->|--x|-x|--\)|-\))\s*([+-]?[^:]+?)(?:\s*:\s*(.*))?$",
        RegexOptions.CultureInvariant | RegexOptions.Compiled, RxTimeout);

    private static readonly string[] SequenceSkipped =
    [
        "note", "activate", "deactivate", "autonumber", "end", "loop", "alt", "else", "opt",
        "par", "and", "critical", "option", "break", "rect", "box", "title", "create",
        "destroy", "link", "links", "properties", "details",
    ];

    private static MermaidKind.Sequence ParseSequence(IEnumerable<string> lines)
    {
        var participants = new List<string>();
        var aliases = new Dictionary<string, string>(StringComparer.Ordinal);
        var messages = new List<MermaidSequenceMessage>();

        string AddParticipant(string raw, string? display = null)
        {
            var id = raw.Trim();
            if (!string.IsNullOrEmpty(display)) aliases[id] = display;
            var shown = aliases.TryGetValue(id, out var aliased) ? aliased : id;
            if (!participants.Contains(shown, StringComparer.Ordinal)) participants.Add(shown);
            return shown;
        }

        foreach (var line in lines)
        {
            var low = line.ToLowerInvariant();
            if (low.StartsWith("participant ", StringComparison.Ordinal) || low.StartsWith("actor ", StringComparison.Ordinal))
            {
                var keywordLen = low.StartsWith("participant ", StringComparison.Ordinal) ? 12 : 6;
                var rest = line[keywordLen..].Trim();
                var asIdx = rest.IndexOf(" as ", StringComparison.OrdinalIgnoreCase);
                if (asIdx >= 0)
                {
                    var id = rest[..asIdx].Trim();
                    var alias = CleanLabel(rest[(asIdx + 4)..]).Replace('\n', ' ');
                    AddParticipant(id, alias);
                }
                else
                {
                    AddParticipant(CleanLabel(rest).Replace('\n', ' '));
                }
                if (participants.Count > MaxParticipants)
                    return new MermaidKind.Sequence(participants, messages);
                continue;
            }
            if (SequenceSkipped.Any(kw => low == kw || low.StartsWith(kw + " ", StringComparison.Ordinal)))
                continue;

            var m = SequenceArrow.Match(line);
            if (!m.Success) continue;
            var fromRaw = m.Groups[1].Value.Trim();
            var arrow = m.Groups[2].Value;
            var toRaw = m.Groups[3].Value.Trim();
            if (toRaw.StartsWith('+') || toRaw.StartsWith('-')) toRaw = toRaw[1..];
            var text = m.Groups[4].Success ? CleanLabel(m.Groups[4].Value).Replace('\n', ' ') : "";
            if (fromRaw.Length == 0 || toRaw.Length == 0) continue;

            var from = AddParticipant(fromRaw);
            var to = AddParticipant(toRaw);
            messages.Add(new MermaidSequenceMessage(
                from, to, text,
                Dashed: arrow.StartsWith("--", StringComparison.Ordinal),
                OpenArrow: arrow is "->" or "-->" or "-)" or "--)"));

            if (participants.Count > MaxParticipants || messages.Count > MaxMessages)
                return new MermaidKind.Sequence(participants, messages);
        }

        return new MermaidKind.Sequence(participants, messages);
    }

    // MARK: State Diagram

    private static readonly Regex StateTransition = new(
        @"^(.+?)\s*-->\s*([^:]+?)(?:\s*:\s*(.*))?$",
        RegexOptions.CultureInvariant | RegexOptions.Compiled, RxTimeout);

    private static MermaidKind.State ParseState(IEnumerable<string> lines)
    {
        var nodes = new List<MermaidFlowNode>();
        var nodeIndex = new Dictionary<string, int>(StringComparer.Ordinal);
        var edges = new List<MermaidFlowEdge>();

        void Upsert(string id, string? label = null, MermaidNodeShape? shape = null, bool rename = true)
        {
            var finalShape = shape ?? (id == "[*]" ? MermaidNodeShape.Circle : MermaidNodeShape.Rounded);
            var finalLabel = label ?? (id == "[*]" ? "●" : id);
            if (nodeIndex.TryGetValue(id, out var idx))
            {
                if (rename && !string.IsNullOrEmpty(label))
                    nodes[idx] = nodes[idx] with { Label = label };
            }
            else
            {
                nodeIndex[id] = nodes.Count;
                nodes.Add(new MermaidFlowNode(id, finalLabel, finalShape));
            }
        }

        var inNote = false;
        foreach (var line in lines)
        {
            var low = line.ToLowerInvariant();
            if (inNote)
            {
                if (low == "end note") inNote = false;
                continue;
            }
            if (low.StartsWith("note ", StringComparison.Ordinal))
            {
                inNote = !line.Contains(':');
                continue;
            }
            if (low.StartsWith("direction ", StringComparison.Ordinal) || low is "{" or "}" or "--"
                || low.StartsWith("classdef ", StringComparison.Ordinal)
                || low.StartsWith("class ", StringComparison.Ordinal)
                || low.StartsWith("hide ", StringComparison.Ordinal)
                || low.StartsWith("scale ", StringComparison.Ordinal)
                || low.StartsWith("title ", StringComparison.Ordinal))
                continue;

            if (low.StartsWith("state ", StringComparison.Ordinal))
            {
                var rest = line[6..].Trim();
                var asIdx = rest.IndexOf(" as ", StringComparison.OrdinalIgnoreCase);
                if (asIdx >= 0)
                {
                    var lbl = CleanLabel(rest[..asIdx]);
                    var id = rest[(asIdx + 4)..].Trim(' ', '{');
                    Upsert(id, lbl, MermaidNodeShape.Rounded);
                }
                continue;
            }

            var m = StateTransition.Match(line);
            if (m.Success)
            {
                var from = m.Groups[1].Value.Trim();
                var to = m.Groups[2].Value.Trim();
                var lbl = m.Groups[3].Success ? CleanLabel(m.Groups[3].Value).Replace('\n', ' ') : "";
                var fromId = from == "[*]" ? "__start__" : from;
                var toId = to == "[*]" ? "__end__" : to;
                Upsert(fromId, from == "[*]" ? "Start" : from, from == "[*]" ? MermaidNodeShape.Circle : MermaidNodeShape.Rounded, rename: false);
                Upsert(toId, to == "[*]" ? "End" : to, to == "[*]" ? MermaidNodeShape.Circle : MermaidNodeShape.Rounded, rename: false);
                edges.Add(new MermaidFlowEdge(fromId, toId, lbl, MermaidEdgeStyle.Solid, true));
                if (nodes.Count > MaxNodes || edges.Count > MaxEdges)
                    return new MermaidKind.State(nodes, edges);
                continue;
            }

            var colon = line.IndexOf(':');
            if (colon >= 0)
            {
                var id = line[..colon].Trim();
                var desc = CleanLabel(line[(colon + 1)..]);
                if (id.Length > 0)
                {
                    var head = nodeIndex.TryGetValue(id, out var existingIdx) ? nodes[existingIdx].Label : id;
                    Upsert(id, desc.Length == 0 ? head : $"{head}\n{desc}", MermaidNodeShape.Rounded);
                }
            }
        }

        return new MermaidKind.State(nodes, edges);
    }

    // MARK: Pie Chart

    private static readonly Regex PieSlicePattern = new(
        @"^""([^""]+)""\s*:\s*([0-9]{1,18}(?:\.[0-9]{1,9})?)$",
        RegexOptions.CultureInvariant | RegexOptions.Compiled, RxTimeout);

    private static MermaidKind.Pie ParsePie(List<string> lines)
    {
        var header = lines[0];
        var showData = header.Contains("showdata", StringComparison.OrdinalIgnoreCase);
        var title = "";
        var titleIdx = header.IndexOf("title ", StringComparison.OrdinalIgnoreCase);
        if (titleIdx >= 0)
            title = CleanLabel(header[(titleIdx + 6)..]).Replace('\n', ' ');

        var slices = new List<MermaidPieSlice>();
        for (var i = 1; i < lines.Count; i++)
        {
            var line = lines[i];
            if (line.StartsWith("title ", StringComparison.OrdinalIgnoreCase))
            {
                title = CleanLabel(line[6..]).Replace('\n', ' ');
                continue;
            }
            var m = PieSlicePattern.Match(line);
            if (!m.Success) continue;
            if (!double.TryParse(m.Groups[2].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out var val)
                || !double.IsFinite(val) || val <= 0 || val > MaxPieValue)
                continue;
            slices.Add(new MermaidPieSlice(CleanLabel(m.Groups[1].Value).Replace('\n', ' '), val));
            if (slices.Count > MaxSlices) return new MermaidKind.Pie(title, showData, slices);
        }
        return new MermaidKind.Pie(title, showData, slices);
    }
}

/// Pure cycle-safe rank computation shared between MermaidRenderer and core tests (App/Chat/Render/MermaidRenderer.swift `flowRanks`).
public static class MermaidLayoutMath
{
    public static Dictionary<string, int> FlowRanks(IReadOnlyList<string> nodes, IReadOnlyList<(string From, string To)> edges)
    {
        var known = new HashSet<string>(nodes, StringComparer.Ordinal);
        var order = new List<string>(nodes);
        foreach (var (from, to) in edges)
        {
            if (known.Add(from)) order.Add(from);
            if (known.Add(to)) order.Add(to);
        }

        var outgoing = new Dictionary<string, List<string>>(StringComparer.Ordinal);
        var incoming = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var (from, to) in edges)
        {
            if (from == to) continue;
            if (!outgoing.TryGetValue(from, out var outs)) outgoing[from] = outs = [];
            outs.Add(to);
            incoming[to] = incoming.GetValueOrDefault(to) + 1;
        }

        var state = new Dictionary<string, byte>(StringComparer.Ordinal); // 1 = on path, 2 = done
        var back = new HashSet<(string From, string To)>();

        void Walk(string root)
        {
            if (state.ContainsKey(root)) return;
            var stack = new List<(string Id, int Next)> { (root, 0) };
            state[root] = 1;
            while (stack.Count > 0)
            {
                var top = stack[^1];
                var outs = outgoing.TryGetValue(top.Id, out var list) ? list : null;
                if (outs != null && top.Next < outs.Count)
                {
                    stack[^1] = (top.Id, top.Next + 1);
                    var to = outs[top.Next];
                    if (!state.TryGetValue(to, out var st))
                    {
                        state[to] = 1;
                        stack.Add((to, 0));
                    }
                    else if (st == 1)
                    {
                        back.Add((top.Id, to));
                    }
                }
                else
                {
                    state[top.Id] = 2;
                    stack.RemoveAt(stack.Count - 1);
                }
            }
        }

        foreach (var id in order)
            if (incoming.GetValueOrDefault(id) == 0) Walk(id);
        foreach (var id in order)
            Walk(id);

        var forward = new Dictionary<string, List<string>>(StringComparer.Ordinal);
        var waiting = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var (from, outs) in outgoing)
        {
            foreach (var to in outs)
            {
                if (back.Contains((from, to))) continue;
                if (!forward.TryGetValue(from, out var f)) forward[from] = f = [];
                f.Add(to);
                waiting[to] = waiting.GetValueOrDefault(to) + 1;
            }
        }

        var rank = new Dictionary<string, int>(StringComparer.Ordinal);
        var queue = new List<string>();
        foreach (var id in order)
        {
            if (waiting.GetValueOrDefault(id) == 0)
            {
                queue.Add(id);
                rank[id] = 0;
            }
        }

        var head = 0;
        while (head < queue.Count)
        {
            var cur = queue[head++];
            if (!forward.TryGetValue(cur, out var outs)) continue;
            var curRank = rank.GetValueOrDefault(cur);
            foreach (var to in outs)
            {
                rank[to] = Math.Max(rank.GetValueOrDefault(to), curRank + 1);
                var left = waiting.GetValueOrDefault(to, 1) - 1;
                waiting[to] = left;
                if (left == 0) queue.Add(to);
            }
        }

        foreach (var id in order)
            rank.TryAdd(id, 0);

        return rank;
    }
}
