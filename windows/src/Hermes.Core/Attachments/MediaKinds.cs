using System.Globalization;

namespace Hermes.Core.Attachments;

/// A file's kind by its extension (HermesKit/Attachments/AttachmentModels.swift MediaKinds; spec 1x-attachments §7.5, §7.6).
public enum MediaKind { Image, Video, Audio, Pdf, Text, Table, Archive, Folder, Other }

public static class MediaKinds
{
    public static readonly HashSet<string> ImageExtensions =
        ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "heif", "tif", "tiff"];
    /// What Hermes' image.attach accepts (H:hermes_cli/cli_terminal_input.py:33-36).
    public static readonly HashSet<string> HermesImageExtensions =
        ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "svg", "ico"];
    public static readonly HashSet<string> VideoExtensions = ["mp4", "mov", "m4v", "webm", "mkv", "avi"];
    public static readonly HashSet<string> AudioExtensions = ["mp3", "m4a", "wav", "ogg", "opus", "flac", "aac", "aiff", "caf"];
    public static readonly HashSet<string> TextExtensions =
    [
        "txt", "md", "markdown", "json", "yaml", "yml", "toml", "xml", "html", "css", "js", "ts", "tsx", "jsx", "py", "swift",
        "go", "rs", "rb", "java", "kt", "c", "h", "cpp", "sh", "log", "ini", "env", "sql",
    ];
    public static readonly HashSet<string> TableExtensions = ["csv", "tsv", "xls", "xlsx", "numbers"];
    public static readonly HashSet<string> ArchiveExtensions = ["zip", "tar", "gz", "tgz", "7z", "rar", "bz2", "xz"];

    /// The extension of a name's last component, lower-cased, without the dot ("" for ".env" or "README"), as
    /// NSString.pathExtension.
    public static string Ext(string name)
    {
        var last = LastComponent(name);
        var dot = last.LastIndexOf('.');
        return dot <= 0 || dot == last.Length - 1 ? "" : last[(dot + 1)..].ToLowerInvariant();
    }

    private static string LastComponent(string path)
    {
        var p = path.TrimEnd('/');
        var slash = p.LastIndexOf('/');
        return slash >= 0 ? p[(slash + 1)..] : p;
    }

    public static MediaKind Kind(string name)
    {
        var e = Ext(name);
        if (ImageExtensions.Contains(e)) return MediaKind.Image;
        if (VideoExtensions.Contains(e)) return MediaKind.Video;
        if (AudioExtensions.Contains(e)) return MediaKind.Audio;
        if (e == "pdf") return MediaKind.Pdf;
        if (TableExtensions.Contains(e)) return MediaKind.Table;
        if (TextExtensions.Contains(e)) return MediaKind.Text;
        if (ArchiveExtensions.Contains(e)) return MediaKind.Archive;
        return MediaKind.Other;
    }

    /// "PDF", "JPEG", "Markdown", "Text": the short type word for a detail line.
    public static string? TypeWord(string name)
    {
        var e = Ext(name);
        if (e.Length == 0 || e.Length > 8) return null;
        return e switch
        {
            "jpg" or "jpeg" => "JPEG",
            "md" or "markdown" => "Markdown",
            "txt" => "Text",
            _ => e.ToUpperInvariant(),
        };
    }

    /// "PDF · 2.4 MB", "PDF" without a size, "2.4 MB" without a type, "File" with neither.
    public static string Detail(string name, long? bytes)
    {
        var parts = new List<string>();
        if (TypeWord(name) is { } w) parts.Add(w);
        if (bytes is { } b && b >= 0) parts.Add(FileSize(b));
        return parts.Count == 0 ? "File" : string.Join(" · ", parts);
    }

    /// ByteCountFormatter's .file style: decimal units, "812 KB", "2.4 MB", "1.25 GB", "12 bytes", "Zero KB".
    public static string FileSize(long bytes)
    {
        var c = CultureInfo.InvariantCulture;
        if (bytes == 0) return "Zero KB";
        if (bytes == 1) return "1 byte";
        if (bytes < 1000) return $"{bytes} bytes";
        if (bytes < 1_000_000) return Math.Round(bytes / 1000.0).ToString("0", c) + " KB";
        if (bytes < 1_000_000_000) return (bytes / 1_000_000.0).ToString("0.#", c) + " MB";
        return (bytes / 1_000_000_000.0).ToString("0.##", c) + " GB";
    }

    /// A path's last component, unquoted ("Photo" for an image without one, "File" otherwise). A Windows gateway's
    /// C:\Users\…\chart.png gives the name after the last backslash.
    public static string NameOfPath(string path, bool image)
    {
        var p = path;
        while (p.EndsWith('/') && p.Length > 1) p = p[..^1];
        var last = p == "/" ? "" : LastComponent(p);
        if (last.Contains('\\')) last = last.Split('\\', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? last;
        if (last.Length == 0 || last == "/") return image ? "Photo" : "File";
        return last;
    }

    /// The glyph for a kind (Segoe Fluent Icons), the Windows stand-in for the Mac's SF Symbols (spec §7.6).
    public static string Glyph(MediaKind kind) => kind switch
    {
        MediaKind.Image => "\uEB9F",   // Photo2
        MediaKind.Video => "\uE714",   // Video
        MediaKind.Audio => "\uE8D6",   // Audio
        MediaKind.Pdf => "\uEA90",     // PDF
        MediaKind.Text => "\uE8A5",    // Document
        MediaKind.Table => "\uE80A",   // ViewAll (table cells)
        MediaKind.Archive => "\uF012", // ZipFolder
        MediaKind.Folder => "\uE8B7",  // Folder
        _ => "\uE7C3",                 // Page
    };
}
