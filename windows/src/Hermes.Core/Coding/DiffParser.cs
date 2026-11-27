using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Composer;

namespace Hermes.Core.Coding;

/// Classification of one line inside a unified diff patch.
public enum DiffLineKind
{
    FileHeader,
    HunkHeader,
    Context,
    Added,
    Removed,
    NoNewline,
}

/// Which side of the diff an inline comment is anchored to.
public enum DiffLineSide
{
    Old,
    New,
}

/// One parsed line in a unified diff hunk, carrying original & new line numbers.
public sealed record DiffLine(
    int Index,
    DiffLineKind Kind,
    int? OldLine,
    int? NewLine,
    string Text)
{
    public DiffLineSide AnchorSide => Kind == DiffLineKind.Removed ? DiffLineSide.Old : DiffLineSide.New;
    public int? AnchorLineNumber => Kind == DiffLineKind.Removed ? OldLine : NewLine;
    public bool CanComment => Kind is DiffLineKind.Added or DiffLineKind.Removed or DiffLineKind.Context && AnchorLineNumber != null;
}

/// One parsed `@@ -oldStart,oldCount +newStart,newCount @@` hunk.
public sealed record DiffHunk(
    string Header,
    int OldStart,
    int OldCount,
    int NewStart,
    int NewCount,
    IReadOnlyList<DiffLine> Lines);

/// Parsed unified diff for one file.
public sealed record ParsedDiff(
    string FilePath,
    IReadOnlyList<DiffHunk> Hunks,
    int Additions,
    int Deletions,
    bool Truncated)
{
    public int TotalLines => Hunks.Sum(h => h.Lines.Count);
}

/// Unified diff hunk parser supporting standard git/GitHub patches.
public static partial class DiffParser
{
    [GeneratedRegex(@"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)$")]
    private static partial Regex HunkHeaderRegex();

    public static ParsedDiff Parse(string filePath, string? patch, bool patchCut = false)
    {
        if (string.IsNullOrEmpty(patch))
            return new ParsedDiff(filePath, [], 0, 0, patchCut);

        var rawLines = patch.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n');
        var hunks = new List<DiffHunk>();
        List<DiffLine>? currentLines = null;
        string currentHeader = "";
        int oldStart = 0, oldCount = 0, newStart = 0, newCount = 0;
        int oldLine = 0, newLine = 0;
        int additions = 0, deletions = 0;
        var index = 0;

        void Flush()
        {
            if (currentLines != null)
                hunks.Add(new DiffHunk(currentHeader, oldStart, oldCount, newStart, newCount, currentLines));
            currentLines = null;
        }

        foreach (var raw in rawLines)
        {
            if (raw.StartsWith("@@ ", StringComparison.Ordinal))
            {
                var match = HunkHeaderRegex().Match(raw);
                if (match.Success)
                {
                    Flush();
                    oldStart = int.Parse(match.Groups[1].Value);
                    oldCount = match.Groups[2].Success ? int.Parse(match.Groups[2].Value) : 1;
                    newStart = int.Parse(match.Groups[3].Value);
                    newCount = match.Groups[4].Success ? int.Parse(match.Groups[4].Value) : 1;
                    currentHeader = raw;
                    oldLine = oldStart;
                    newLine = newStart;
                    currentLines = [new DiffLine(index++, DiffLineKind.HunkHeader, null, null, raw)];
                    continue;
                }
            }

            if (raw.StartsWith("--- ", StringComparison.Ordinal) || raw.StartsWith("+++ ", StringComparison.Ordinal)
                || raw.StartsWith("diff --git ", StringComparison.Ordinal) || raw.StartsWith("index ", StringComparison.Ordinal))
            {
                currentLines ??= [];
                currentLines.Add(new DiffLine(index++, DiffLineKind.FileHeader, null, null, raw));
                continue;
            }

            if (currentLines == null)
            {
                // Patch without explicit @@ header: start synthetic hunk at line 1.
                oldStart = 1; newStart = 1; oldCount = 0; newCount = 0;
                oldLine = 1; newLine = 1;
                currentHeader = "@@ -1 +1 @@";
                currentLines = [];
            }

            if (raw.StartsWith("\\ No newline", StringComparison.Ordinal))
            {
                currentLines.Add(new DiffLine(index++, DiffLineKind.NoNewline, null, null, raw));
            }
            else if (raw.StartsWith('+'))
            {
                additions++;
                currentLines.Add(new DiffLine(index++, DiffLineKind.Added, null, newLine++, raw));
            }
            else if (raw.StartsWith('-'))
            {
                deletions++;
                currentLines.Add(new DiffLine(index++, DiffLineKind.Removed, oldLine++, null, raw));
            }
            else
            {
                var text = raw.StartsWith(' ') ? raw : " " + raw;
                currentLines.Add(new DiffLine(index++, DiffLineKind.Context, oldLine++, newLine++, text));
            }
        }

        Flush();
        return new ParsedDiff(filePath, hunks, additions, deletions, patchCut);
    }
}

/// An inline diff review comment anchored to a file, side, and line number.
public sealed record DiffComment(
    string Id,
    string FilePath,
    DiffLineSide Side,
    int LineNumber,
    string Body,
    string Author,
    DateTimeOffset CreatedAt,
    bool Resolved = false)
{
    public JsonObject ToJson() => new()
    {
        ["id"] = Id,
        ["file"] = FilePath,
        ["side"] = Side == DiffLineSide.Old ? "old" : "new",
        ["line"] = LineNumber,
        ["body"] = Body,
        ["author"] = Author,
        ["created_at"] = CreatedAt.ToString("O"),
        ["resolved"] = Resolved,
    };

    public static DiffComment? FromJson(JsonNode? node)
    {
        if (node is not JsonObject) return null;
        var id = node.Text("id");
        var file = node.Text("file");
        var body = node.Text("body");
        var line = node.Int("line");
        if (id == null || file == null || body == null || line is not > 0) return null;
        var side = string.Equals(node.Str("side"), "old", StringComparison.OrdinalIgnoreCase)
            ? DiffLineSide.Old
            : DiffLineSide.New;
        var created = DateTimeOffset.TryParse(node.Str("created_at"), out var dt) ? dt : DateTimeOffset.UtcNow;
        return new DiffComment(id, file, side, (int)line.Value, body, node.Text("author") ?? "You", created, node.Bool("resolved") ?? false);
    }
}

/// Stores and formats inline diff review comments for a PR or coding session.
public sealed class DiffCommentStore
{
    private readonly List<DiffComment> _comments = [];
    private readonly IKeyValueStore? _prefs;
    private readonly string? _storageKey;

    public event Action? Changed;

    public DiffCommentStore(IKeyValueStore? prefs = null, string? storageKey = null)
    {
        _prefs = prefs;
        _storageKey = storageKey;
        Load();
    }

    public IReadOnlyList<DiffComment> All => _comments;

    public int OpenCount => _comments.Count(c => !c.Resolved);

    public IReadOnlyList<DiffComment> ForFile(string filePath) =>
        [.. _comments.Where(c => string.Equals(c.FilePath, filePath, StringComparison.Ordinal)).OrderBy(c => c.LineNumber).ThenBy(c => c.CreatedAt)];

    public IReadOnlyList<DiffComment> ForLine(string filePath, DiffLineSide side, int lineNumber) =>
        [.. _comments.Where(c => string.Equals(c.FilePath, filePath, StringComparison.Ordinal) && c.Side == side && c.LineNumber == lineNumber).OrderBy(c => c.CreatedAt)];

    public IReadOnlyDictionary<string, int> CountsByFile(bool openOnly = true)
    {
        var map = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var c in _comments)
        {
            if (openOnly && c.Resolved) continue;
            map[c.FilePath] = map.GetValueOrDefault(c.FilePath) + 1;
        }
        return map;
    }

    public DiffComment? Add(string filePath, DiffLineSide side, int lineNumber, string body, string author = "You", DateTimeOffset? now = null)
    {
        var clean = body.Trim();
        if (string.IsNullOrWhiteSpace(filePath) || lineNumber <= 0 || clean.Length == 0) return null;
        var comment = new DiffComment(Guid.NewGuid().ToString("N")[..12], filePath.Trim(), side, lineNumber, clean, author, now ?? DateTimeOffset.UtcNow);
        _comments.Add(comment);
        Save();
        Changed?.Invoke();
        return comment;
    }

    public bool Edit(string id, string body)
    {
        var clean = body.Trim();
        if (clean.Length == 0) return false;
        var idx = _comments.FindIndex(c => c.Id == id);
        if (idx < 0) return false;
        _comments[idx] = _comments[idx] with { Body = clean };
        Save();
        Changed?.Invoke();
        return true;
    }

    public bool SetResolved(string id, bool resolved)
    {
        var idx = _comments.FindIndex(c => c.Id == id);
        if (idx < 0) return false;
        _comments[idx] = _comments[idx] with { Resolved = resolved };
        Save();
        Changed?.Invoke();
        return true;
    }

    public bool Delete(string id)
    {
        var removed = _comments.RemoveAll(c => c.Id == id) > 0;
        if (removed) { Save(); Changed?.Invoke(); }
        return removed;
    }

    public void Clear()
    {
        if (_comments.Count == 0) return;
        _comments.Clear();
        Save();
        Changed?.Invoke();
    }

    /// Formats all unresolved inline comments as a structured review message to send to a bot or PR review.
    public string FormatReviewMessage(string? prLabel = null, string? overallNote = null)
    {
        var open = _comments.Where(c => !c.Resolved).OrderBy(c => c.FilePath, StringComparer.Ordinal).ThenBy(c => c.LineNumber).ToList();
        if (open.Count == 0 && string.IsNullOrWhiteSpace(overallNote)) return "";

        var sb = new StringBuilder();
        sb.Append(string.IsNullOrWhiteSpace(prLabel) ? "Review comments:" : $"Review comments for {prLabel}:");
        if (!string.IsNullOrWhiteSpace(overallNote))
        {
            sb.AppendLine();
            sb.AppendLine();
            sb.Append(overallNote.Trim());
        }
        foreach (var group in open.GroupBy(c => c.FilePath))
        {
            sb.AppendLine();
            sb.AppendLine();
            sb.Append($"### `{group.Key}`");
            foreach (var c in group)
            {
                var sideTag = c.Side == DiffLineSide.Old ? "old " : "";
                sb.AppendLine();
                sb.Append($"- **Line {sideTag}{c.LineNumber}:** {c.Body}");
            }
        }
        return sb.ToString();
    }

    private void Load()
    {
        if (_prefs == null || string.IsNullOrEmpty(_storageKey)) return;
        if (_prefs.Get(_storageKey) is not { Length: > 0 } raw) return;
        if (J.Parse(raw) is not JsonArray arr) return;
        foreach (var item in arr)
            if (DiffComment.FromJson(item) is { } comment) _comments.Add(comment);
    }

    private void Save()
    {
        if (_prefs == null || string.IsNullOrEmpty(_storageKey)) return;
        if (_comments.Count == 0) { _prefs.Set(_storageKey, null); return; }
        var arr = new JsonArray([.. _comments.Select(c => (JsonNode)c.ToJson())]);
        _prefs.Set(_storageKey, arr.ToJsonString());
    }
}
