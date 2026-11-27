using System.Globalization;
using System.Text.Json.Nodes;
using Hermes.Core.Gateways;

namespace Hermes.Core.Workspace;

/// More › Files and Changes (docs/spec/3x-morepages.md §11): which folder the pages show and the words around it. The
/// twin of HermesKit/Pages/More/MoreWorkspaceRoot.swift.
///
/// Precedence: 1) the folder chosen here for this gateway and bot; else 2) the working folder of the chat last on
/// screen, when that chat is this bot's; else 3) the gateway's own answer to `GET /api/fs/default-cwd`.
public static class WorkspaceRoot
{
    public enum Source { Chosen, Chat, Gateway }

    public sealed record Root(string Path, Source Source);

    public sealed record Words(string Title, string Body);

    // MARK: Precedence

    /// The root to show, null when none of the three is a folder path (the page then says why).
    public static Root? Resolve(string? chosen, string? chatFolder, string? gatewayDefault)
    {
        if (Folder(chosen) is { } a) return new Root(a, Source.Chosen);
        if (Folder(chatFolder) is { } b) return new Root(b, Source.Chat);
        if (Folder(gatewayDefault) is { } c) return new Root(c, Source.Gateway);
        return null;
    }

    /// A usable folder path: absolute, trimmed, without a trailing slash ("/" stays "/"). Null for anything else.
    public static string? Folder(string? raw)
    {
        var path = raw?.Trim();
        if (path == null || !path.StartsWith('/')) return null;
        while (path.Length > 1 && path.EndsWith('/')) path = path[..^1];
        return path;
    }

    /// Whether the gateway must be asked for its default folder (nothing chosen and no chat folder).
    public static bool NeedsGatewayDefault(string? chosen, string? chatFolder) => Folder(chosen) == null && Folder(chatFolder) == null;

    // MARK: The chosen folder (the Mac's UserDefaults `pages.filesRoot.<account>.<profile>`)

    public static string Key(string account, string profile) =>
        $"pages.filesRoot.{account}.{(profile.Length == 0 ? "default" : profile)}";

    public static string? Chosen(Transcripts.IPreferences prefs, string account, string profile) => Folder(prefs.Get(Key(account, profile)));

    /// Null (or a path that is not absolute) forgets the choice: "Use Chat’s Folder".
    public static void SetChosen(Transcripts.IPreferences prefs, string? path, string account, string profile) =>
        prefs.Set(Key(account, profile), Folder(path));

    // MARK: Paths in words

    /// The gateway user's home: the default profile lives in "<home>/.hermes". Null when unknown.
    public static string? GatewayHome(string? defaultProfilePath)
    {
        var path = (defaultProfilePath ?? "").Trim();
        if (!path.StartsWith('/')) return null;
        var at = path.IndexOf("/.hermes", StringComparison.Ordinal);
        if (at < 0) return null;
        var after = path[(at + "/.hermes".Length)..];
        if (after.Length > 0 && !after.StartsWith('/')) return null;
        var home = path[..at];
        return home.Length == 0 ? null : home;
    }

    /// The default profile's folder out of a `GET /api/profiles` answer (`{"profiles":[{"name","path","is_default"}]}`).
    public static string? GatewayHome(JsonNode? json)
    {
        var rows = (json.Arr("profiles") ?? json as JsonArray ?? []).OfType<JsonNode>().ToList();
        var row = rows.FirstOrDefault(r => r.Bool("is_default") == true) ?? rows.FirstOrDefault(r => r.Str("name") == "default");
        return GatewayHome(row.Str("path"));
    }

    /// "~/Projects/app" for a folder in the gateway user's own home; any other folder keeps its whole path.
    public static string Display(string path, string? home)
    {
        var value = path.Trim();
        while (value.Length > 1 && value.EndsWith('/')) value = value[..^1];
        if (string.IsNullOrEmpty(home) || !value.StartsWith('/')) return value;
        if (value == home) return "~";
        return value.StartsWith(home + "/", StringComparison.Ordinal) ? "~" + value[home.Length..] : value;
    }

    /// The folder's own name ("site"); "/" for the top.
    public static string Name(string path) => path.Split('/', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? "/";

    /// The folder holding `path`; "/" has none.
    public static string? Parent(string path)
    {
        if (Folder(path) is not { } p || p == "/") return null;
        var at = p.LastIndexOf('/');
        return at <= 0 ? "/" : p[..at];
    }

    /// Whether `path` is `root` or inside it.
    public static bool IsUnder(string path, string root) =>
        path == root || path.StartsWith(root.EndsWith('/') ? root : root + "/", StringComparison.Ordinal);

    /// Where the root comes from (the trail's tip, the header's source line).
    public static string SourceLine(Source source, string? chatTitle) => source switch
    {
        Source.Chosen => "Folder you chose",
        Source.Chat => (chatTitle?.Trim() ?? "") is { Length: > 0 } t ? $"The folder of “{t}”" : "The folder of your last chat",
        _ => $"The default folder on {HostWord.Phrase}",
    };

    /// The trail from the root's folder down to `browsed` (name, path).
    public static List<(string Name, string Path)> Crumbs(string root, string? browsed)
    {
        var o = new List<(string, string)> { (Name(root), root) };
        if (browsed == null || browsed == root || !IsUnder(browsed, root)) return o;
        var path = root;
        foreach (var part in browsed[root.Length..].Split('/', StringSplitOptions.RemoveEmptyEntries))
        {
            path = (path.EndsWith('/') ? path : path + "/") + part;
            o.Add((part, path));
        }
        return o;
    }

    // MARK: Failure words

    /// What Files says when its folder cannot be read: the reason in words, never "(ENOENT)".
    public static Words FolderErrorText(string code, bool chatFolder)
    {
        var folder = chatFolder ? "This chat’s folder" : "This folder";
        var reason = code.Trim();
        bool Starts(string word)
        {
            if (!reason.StartsWith(word, StringComparison.Ordinal)) return false;
            if (reason.Length == word.Length) return true;
            var next = reason[word.Length];
            return !(char.IsLetterOrDigit(next) || next == '_');
        }
        if (Starts("ENOENT")) return new("Folder Not Found", $"{folder} no longer exists on {HostWord.Phrase}.");
        if (Starts("EACCES") || Starts("EPERM"))
            return new("Can’t Open This Folder",
                $"{HostWord.Sentence} doesn’t allow Hermes HQ to read {(chatFolder ? "this chat’s folder" : "this folder")}.");
        if (Starts("ENOTDIR")) return new("Not a Folder", $"{folder} is a file on {HostWord.Phrase}, not a folder.");
        return new("Couldn’t Read This Folder", reason.Length == 0 ? $"{HostWord.Sentence} did not say why." : reason);
    }

    public const int PreviewKB = 512;

    /// "2.5 MB" / "640 KB" (one decimal, a trailing ".0" dropped).
    public static string FileSize(long bytes)
    {
        if (bytes >= 1024 * 1024)
        {
            var text = (bytes / 1_048_576.0).ToString("0.0", CultureInfo.InvariantCulture);
            return (text.EndsWith(".0") ? text[..^2] : text) + " MB";
        }
        return $"{(long)Math.Round(bytes / 1024.0, MidpointRounding.AwayFromZero)} KB";
    }

    /// "Showing the first 512 KB of 2.5 MB."
    public static string TruncatedNotice(long? byteSize) =>
        byteSize is { } b && b > PreviewKB * 1024 ? $"Showing the first {PreviewKB} KB of {FileSize(b)}." : $"Showing the first {PreviewKB} KB.";

    // MARK: Changes

    public static readonly Words NoChanges = new("No Changes", "Nothing has changed in this folder since its last saved version.");
    public static readonly Words NotGit = new("Not a Git Folder", "Changes shows what changed in a project that uses Git.");
    public static readonly Words NoFolderYet = new("No Folder Yet", $"Choose a folder on {HostWord.Phrase} to browse.");
    public static readonly Words EmptyFolder = new("Empty Folder", "There is nothing in this folder.");

    /// A refused review list that means "this folder is not a repository".
    public static bool IsNotGit(string reason)
    {
        var text = reason.ToLowerInvariant();
        return text.Contains("not a git repository") || text.Contains("not a git repo");
    }

    /// "+12 −3" (a real minus sign). A zero side is left out; both kept only when both are above zero.
    public static string Counts(long added, long removed)
    {
        long add = Math.Max(0, added), remove = Math.Max(0, removed);
        if (add > 0 && remove > 0) return $"+{add} −{remove}";
        if (remove > 0) return $"−{remove}";
        return $"+{add}";
    }

    /// What a change's Lines shows when it has no counted lines: a renamed or copied file nothing, a file not read as
    /// text "Binary", a text file that changed no lines a dash. Null: show `Counts`.
    public static string? LinesWord(long added, long removed, string status, string path)
    {
        if (added > 0 || removed > 0) return null;
        if (StatusLetter(status) is "R" or "C") return "";
        return Opening(path) == OpeningKind.Download ? "Binary" : "—";
    }

    /// The letter a change shows: one upper-case character, "M" when unknown.
    public static string StatusLetter(string status)
    {
        var letter = status.Trim().ToUpperInvariant();
        return letter is "M" or "A" or "D" or "R" or "C" or "U" or "?" ? letter : "M";
    }

    public enum ChangeTint { Added, Deleted, Changed }

    public static ChangeTint Tint(string status) => StatusLetter(status) switch
    {
        "A" or "?" => ChangeTint.Added,
        "D" => ChangeTint.Deleted,
        _ => ChangeTint.Changed,
    };

    /// The glyph a change shows in place of git's letter (Segoe Fluent Icons for the Mac's SF Symbols).
    public static string StatusGlyph(string status) => StatusLetter(status) switch
    {
        "A" or "?" => "",   // Add (plus.square.fill)
        "D" => "",          // Remove (minus.square.fill)
        "R" => "",          // Forward (arrow.right.square.fill)
        "C" => "",          // Copy (plus.square.on.square.fill)
        "U" => "",          // Warning (exclamationmark.triangle.fill)
        _ => "",            // Edit (pencil.circle.fill)
    };

    /// "1 item" / "11 items"; "1 changed file" / "2 changed files".
    public static string ItemCount(int n) => n == 1 ? "1 item" : $"{n} items";
    public static string ChangeCount(int n) => n == 1 ? "1 changed file" : $"{n} changed files";

    // MARK: Opening a file

    public enum OpeningKind { Text, Download }

    /// HermesKit/Pages/ArtifactFiles.swift `textExtensions`.
    public static readonly HashSet<string> TextExtensions =
    [
        "md", "markdown", "mdx", "txt", "text", "log", "json", "jsonl", "yaml", "yml", "toml", "ini", "cfg", "conf", "xml", "py",
        "js", "mjs", "cjs", "ts", "tsx", "jsx", "sh", "zsh", "bash", "swift", "rb", "go", "rs", "java", "kt", "c", "h", "cc",
        "cpp", "hpp", "css", "scss", "sql",
    ];

    public static readonly HashSet<string> MarkdownExtensions = ["md", "markdown", "mdx"];

    /// A file with a text extension (or none: Makefile, LICENSE) is read as text first; anything else is downloaded.
    public static OpeningKind Opening(string name)
    {
        var slash = name.LastIndexOf('/');
        var b = slash >= 0 ? name[(slash + 1)..] : name;
        var dot = b.LastIndexOf('.');
        if (dot <= 0) return OpeningKind.Text;
        var ext = b[(dot + 1)..].ToLowerInvariant();
        if (ext.Length == 0) return OpeningKind.Text;
        return TextExtensions.Contains(ext) || ext is "html" or "htm" or "csv" or "tsv" or "env" or "gitignore" or "lock"
            ? OpeningKind.Text : OpeningKind.Download;
    }

    public static bool IsMarkdown(string name)
    {
        var dot = name.LastIndexOf('.');
        return dot > 0 && MarkdownExtensions.Contains(name[(dot + 1)..].ToLowerInvariant());
    }

    /// Duplicate paths in a listing never reach a table twice (first one wins, order kept).
    public static List<WorkspaceEntry> Deduped(IEnumerable<WorkspaceEntry> entries)
    {
        var seen = new HashSet<string>();
        return [.. entries.Where(e => seen.Add(e.Path))];
    }

    public static List<WorkspaceChange> Deduped(IEnumerable<WorkspaceChange> changes)
    {
        var seen = new HashSet<string>();
        return [.. changes.Where(c => seen.Add($"{c.Staged}|{c.Path}"))];
    }

    /// A changed file's whole path (the list names it from the repository's root; the page's folder if that's unknown).
    public static string? FullPath(WorkspaceChange change, string? repoRoot, string? directory)
    {
        if (change.Path.StartsWith('/')) return change.Path;
        if ((repoRoot ?? directory) is not { } b) return null;
        return (b.EndsWith('/') ? b : b + "/") + change.Path;
    }

    // MARK: Kinds (HermesKit/Attachments/AttachmentModels.swift `MediaKinds.kindWord`)

    /// The Kind column, named as the Finder names a kind ("Log File", "Shell Script"; "Document" when nothing says).
    public static string KindWord(string name, bool isDirectory)
    {
        if (isDirectory) return "Folder";
        var slash = name.LastIndexOf('/');
        var file = (slash >= 0 ? name[(slash + 1)..] : name).ToLowerInvariant();
        if (file == ".env" || file.StartsWith(".env.")) return "Environment File";
        var dot = file.LastIndexOf('.');
        var ext = dot > 0 ? file[(dot + 1)..] : "";
        return ext switch
        {
            "log" => "Log File",
            "lock" => "Lock File",
            "env" => "Environment File",
            "ini" or "conf" or "cfg" => "Settings File",
            "sh" or "bash" or "zsh" => "Shell Script",
            "py" => "Python Script",
            "rb" => "Ruby Script",
            "js" or "mjs" or "cjs" => "JavaScript",
            "ts" => "TypeScript",
            "swift" => "Swift Source",
            "go" => "Go Source",
            "rs" => "Rust Source",
            "java" => "Java Source",
            "kt" => "Kotlin Source",
            "c" => "C Source",
            "h" => "C Header",
            "cpp" or "cc" or "hpp" => "C++ Source",
            "yml" => "YAML",
            "htm" => "HTML",
            "tif" or "tiff" => "TIFF",
            "mov" => "QuickTime Movie",
            "doc" or "docx" => "Word Document",
            "xls" or "xlsx" => "Excel Spreadsheet",
            "ppt" or "pptx" => "PowerPoint Presentation",
            "numbers" => "Numbers Spreadsheet",
            "pages" => "Pages Document",
            "key" => "Key File",
            _ => Attachments.MediaKinds.TypeWord(file) ?? "Document",
        };
    }

    // MARK: Not available (HermesKit/Pages/More/MoreWire.swift)

    public const string NotAvailableTitle = "Not Available on This Hermes";

    public static string NotAvailableBody(string? page) =>
        string.IsNullOrEmpty(page) ? "Not available on this Hermes. Updating Hermes may add it."
            : $"This Hermes doesn’t have {page}. Updating Hermes may add it.";

    /// The gateway has no such route (an older Hermes): HTTP 404 / 405.
    public static bool IsMissingRoute(Exception e) => e is Net.GatewayException { Status: 404 or 405 };
}
