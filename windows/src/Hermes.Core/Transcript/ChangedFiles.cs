using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Model;

namespace Hermes.Core.Transcripts;

// Port of HermesKit/Chat/Transcript/ChangedFiles.swift (docs/spec/3x-transcript.md §5.2 and §5.4): the files a turn
// changed, the diffs its edit tools returned, the "N files changed" card's words, and the bounded diff store.

/// One file a turn edited. `Path`: exactly as the tool reported it; `Name`: its basename, for the row. `Edits`: how
/// many landed edits the counts add up (a file edited twice says "2 edits" on the card).
public sealed record ChangedFile(string Path, string Name, int Added, int Removed, int Edits = 1);

/// An edit tool call as `Derive` reads it: its name and state, its arguments as JSON text (ToolCall.ArgsJson) and the
/// diff it returned (`DiffFromResult`, or the `inline_diff` of its tool.complete event).
public sealed record EditCall(string Name, ToolState State, string? ArgsJson, string? Diff)
{
    public static EditCall Of(ToolCall call, string? diff = null) =>
        new(call.Name, call.State, call.ArgsJson, diff ?? ChangedFiles.DiffFromResult(call.ResultText));
}

public enum PreviewLineKind { Added, Removed, Context }

/// A preview line, with its leading "+", "−" or space, so colour is never the only signal.
public sealed record PreviewLine(PreviewLineKind Kind, string Text);

public static class ChangedFiles
{
    /// The web's `isFileEditTool`.
    public static readonly IReadOnlySet<string> EditTools = new HashSet<string> { "edit_file", "patch", "write_file" };

    public static bool IsEditTool(string name) => EditTools.Contains(name);

    private static readonly Regex Ansi = new("\u001B\\[[0-?]*[ -/]*[@-~]", RegexOptions.CultureInvariant);

    /// The diff a finished edit tool's result carries: its `inline_diff` (else `diff`), as Hermes sends it.
    public static string? DiffFromResult(string? resultText)
    {
        if (string.IsNullOrWhiteSpace(resultText) || J.Parse(resultText) is not JsonObject o) return null;
        return JsonString(o, "inline_diff") ?? JsonString(o, "diff");
    }

    private static string? JsonString(JsonNode? node, string key) =>
        node.Get(key) is JsonValue v && v.TryGetValue(out string? s) ? s : null;

    /// The diff as Hermes sends it, made plain: its `inline_diff` is the CLI's coloured print (every line wrapped in ANSI
    /// colour codes), led by a "┊ review diff" line and with "a/x → b/x" in place of the "---"/"+++" headers. The codes
    /// and the "┊" line go; an arrow header becomes a "+++ " line so `Path` can still read it. A plain diff is unchanged.
    public static string Plain(string diff)
    {
        var stripped = diff.Contains('\u001B') ? Ansi.Replace(diff, "") : diff;
        if (!stripped.Contains('┊') && !stripped.Contains('→')) return stripped;
        var out_ = new List<string>();
        foreach (var line in TxText.Lines(stripped))
        {
            var t = TxText.TrimSpaces(line);
            if (t.StartsWith('┊')) continue;
            var arrow = t.IndexOf(" → ", StringComparison.Ordinal);
            if (t.Length > 0 && !"+-@ ".Contains(t[0]) && arrow >= 0 && !t[(arrow + 3)..].Contains(' '))
            {
                out_.Add("+++ " + t[(arrow + 3)..]);
                continue;
            }
            out_.Add(line);
        }
        return string.Join("\n", out_);
    }

    /// Lines added and removed in a unified diff: lines starting "+" (not "+++") and "-" (not "---").
    public static (int Added, int Removed) LineStats(string diff)
    {
        int added = 0, removed = 0;
        foreach (var line in TxText.Lines(Plain(diff)))
        {
            if (line.StartsWith('+')) { if (!line.StartsWith("+++", StringComparison.Ordinal)) added++; }
            else if (line.StartsWith('-')) { if (!line.StartsWith("---", StringComparison.Ordinal)) removed++; }
        }
        return (added, removed);
    }

    public static string Basename(string path)
    {
        var trimmed = path.EndsWith('/') ? path[..^1] : path;
        return trimmed.Split('/', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? trimmed;
    }

    /// The file an edit call names: its `path` / `file_path` / `file` argument, else the diff's "+++ b/<path>" header.
    public static string? Path(string? argsJson, string diff)
    {
        var args = argsJson is null ? null : J.Parse(argsJson);
        foreach (var key in new[] { "path", "file_path", "file", "filepath", "target_file" })
            if (JsonString(args, key) is { } value && TxText.TrimSpaces(value) is { Length: > 0 } v) return v;
        foreach (var line in TxText.Lines(Plain(diff)))
        {
            if (!line.StartsWith("+++ ", StringComparison.Ordinal)) continue;
            var name = TxText.TrimSpaces(line[4..]);
            if (name.StartsWith("b/", StringComparison.Ordinal)) name = name[2..];
            if (name.IndexOf('\t') is var tab and >= 0) name = name[..tab];
            if (name.Length > 0 && name != "/dev/null") return name;
        }
        return null;
    }

    /// One row per file the turn edited, in first-touched order, the +/− of every edit to that file summed. Only landed
    /// edits with a diff count (a running call has none; a failed one changed nothing).
    public static List<ChangedFile> Derive(IEnumerable<EditCall> calls)
    {
        var order = new List<string>();
        var byPath = new Dictionary<string, ChangedFile>();
        foreach (var entry in calls)
        {
            if (!IsEditTool(entry.Name) || entry.State != ToolState.Done || entry.Diff is not { } diff
                || diff.Trim().Length == 0 || Path(entry.ArgsJson, diff) is not { } path) continue;
            var (added, removed) = LineStats(diff);
            if (byPath.TryGetValue(path, out var existing))
                byPath[path] = existing with { Added = existing.Added + added, Removed = existing.Removed + removed, Edits = existing.Edits + 1 };
            else
            {
                order.Add(path);
                byPath[path] = new ChangedFile(path, Basename(path), added, removed);
            }
        }
        return [.. order.Select(p => byPath[p])];
    }

    /// The tool calls of a message, as `Derive` reads them; `diffFor`: a call's diff by id when the app kept it apart
    /// (the tool.complete event's `inline_diff`, ToolDiffStore), else the result's own.
    public static List<ChangedFile> Derive(IEnumerable<ToolCall> calls, Func<string, string?>? diffFor = null) =>
        Derive(calls.Select(c => EditCall.Of(c, diffFor?.Invoke(c.Id))));

    /// "1 file changed" / "3 files changed".
    public static string Title(int count) => count == 1 ? "1 file changed" : $"{count} files changed";

    /// A card row's file in the Changes list: the exact path, then a suffix match on the repo-relative path.
    public static string? Match(string file, IReadOnlyList<string> listed)
    {
        if (listed.FirstOrDefault(l => l == file) is { } exact) return exact;
        var clean = file.StartsWith("./", StringComparison.Ordinal) ? file[2..] : file;
        return listed.FirstOrDefault(l => clean.EndsWith("/" + l, StringComparison.Ordinal) || l.EndsWith("/" + clean, StringComparison.Ordinal) || l == clean);
    }

    /// An edit tool's path, in a place the gateway's file routes can open: a relative one joined to the chat's working
    /// folder; one already absolute, home-relative or a Windows path left as it is (and one with no known folder).
    public static string Resolve(string path, string? folder)
    {
        var clean = path.StartsWith("./", StringComparison.Ordinal) ? path[2..] : path;
        if (clean.StartsWith('/') || clean.StartsWith('~') || clean.Contains(":\\") || string.IsNullOrEmpty(folder)) return clean;
        return folder.EndsWith('/') ? folder + clean : folder + "/" + clean;
    }

    /// The first `limit` changed lines of a diff, each hunk's changes led by one line of context; and whether more
    /// follow. File headers, hunk headers and "\ No newline" marks are not lines.
    public static (List<PreviewLine> Lines, bool More) Preview(string diff, int limit = 8)
    {
        var out_ = new List<PreviewLine>();
        var more = false;
        string? pendingContext = null;
        var lastWasChange = false;
        var normalised = Plain(diff.Replace("\r\n", "\n"));
        foreach (var line in normalised.Split('\n'))
        {
            if (line.StartsWith("+++", StringComparison.Ordinal) || line.StartsWith("---", StringComparison.Ordinal)
                || line.StartsWith("diff ", StringComparison.Ordinal) || line.StartsWith("index ", StringComparison.Ordinal)
                || line.StartsWith("@@", StringComparison.Ordinal) || line.StartsWith('\\') || line.StartsWith("Binary files", StringComparison.Ordinal))
            {
                pendingContext = null; lastWasChange = false;
                continue;
            }
            bool isAdd = line.StartsWith('+'), isDel = line.StartsWith('-');
            if (!isAdd && !isDel)
            {
                pendingContext = line;
                lastWasChange = false;
                continue;
            }
            if (out_.Count >= limit) { more = true; break; }
            if (!lastWasChange && pendingContext is { } context && out_.Count < limit - 1)
                out_.Add(new PreviewLine(PreviewLineKind.Context, " " + (context.StartsWith(' ') ? context[1..] : context)));
            pendingContext = null;
            lastWasChange = true;
            out_.Add(new PreviewLine(isAdd ? PreviewLineKind.Added : PreviewLineKind.Removed, (isAdd ? "+" : "−") + line[1..]));
        }
        return (out_, more);
    }
}

/// The diffs edit tools returned, by tool call id: 200 diffs or 1,048,576 characters, the newest always kept (Swift
/// `ToolDiffStore`). A row whose diff was evicted shows its header and "Show all changes".
public sealed class ToolDiffStore
{
    public static ToolDiffStore Shared { get; } = new();
    public const int MaxDiffs = 200;
    public const int MaxCharacters = 1_048_576;

    private readonly object _lock = new();
    private readonly Dictionary<string, string> _diffs = [];
    private readonly List<string> _order = [];   // oldest first
    private int _characters;

    public void Set(string diff, string id)
    {
        if (id.Length == 0 || diff.Length == 0) return;
        lock (_lock)
        {
            if (_diffs.TryGetValue(id, out var old))
            {
                if (old == diff)
                {
                    if (_order[^1] != id) { _order.Remove(id); _order.Add(id); }
                    return;
                }
                _characters -= old.Length;
                _order.Remove(id);
            }
            _diffs[id] = diff;
            _order.Add(id);
            _characters += diff.Length;
            while (_order.Count > 1 && (_order.Count > MaxDiffs || _characters > MaxCharacters))
            {
                var gone = _order[0];
                _order.RemoveAt(0);
                if (_diffs.Remove(gone, out var text)) _characters -= text.Length;
            }
        }
    }

    public string? Diff(string id)
    {
        lock (_lock) return _diffs.GetValueOrDefault(id);
    }

    public void Remove(IEnumerable<string> ids)
    {
        lock (_lock)
            foreach (var id in ids)
            {
                if (!_diffs.Remove(id, out var text)) continue;
                _characters -= text.Length;
                _order.Remove(id);
            }
    }

    public void Clear()
    {
        lock (_lock) { _diffs.Clear(); _order.Clear(); _characters = 0; }
    }

    public (int Diffs, int Characters) Counts { get { lock (_lock) return (_order.Count, _characters); } }
}
