using System.Text;

namespace Hermes.Core.Transcripts;

/// [utf8-pages] A page file that declares no charset is read as UTF-8 when its bytes are UTF-8 (App/Chat/Viewer/
/// PageSnapshots.swift `PageEncoding` and `loadPageFile` at 93f984bb1: a local file is otherwise read as Latin-1, "·"
/// showed as "Â·" in tiles and opened pages). A declared charset, a BOM or plain ASCII is left to the web view.
public static class PageEncoding
{
    private static readonly UTF8Encoding Strict = new(false, true);
    private static readonly byte[] Bom = [0xEF, 0xBB, 0xBF], Utf16Be = [0xFE, 0xFF], Utf16Le = [0xFF, 0xFE];

    /// An HTML file's bytes when they are valid UTF-8, hold some non-ASCII and declare no encoding (no BOM, no
    /// "charset" in the first 1024 bytes, as the HTML prescan reads); null when the web view's own reading is right.
    public static byte[]? Utf8Undeclared(string file)
    {
        if (Path.GetExtension(file).TrimStart('.').ToLowerInvariant() is not ("html" or "htm" or "xhtml")) return null;
        byte[] data;
        try { data = File.ReadAllBytes(file); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
        return NeedsUtf8(data) ? data : null;
    }

    public static bool NeedsUtf8(ReadOnlySpan<byte> data)
    {
        if (data.IndexOfAnyInRange((byte)0x80, (byte)0xFF) < 0) return false;                 // ASCII reads the same either way
        if (data.StartsWith(Bom) || data.StartsWith(Utf16Be) || data.StartsWith(Utf16Le)) return false;
        var head = Encoding.UTF8.GetString(data[..Math.Min(1024, data.Length)]).ToLowerInvariant();
        if (head.Contains("charset") || head.Contains("encoding=")) return false;           // <meta charset>, http-equiv, <?xml encoding?>
        try { Strict.GetCharCount(data); return true; }
        catch (DecoderFallbackException) { return false; }
    }

    /// [windows] The file to draw the page from. WebView2 has no `load(_:characterEncodingName:baseURL:)`, so an
    /// undeclared UTF-8 page is drawn from a copy beside it that starts with a UTF-8 BOM (its pictures and scripts beside
    /// it still load; the file itself keeps its bytes). Anything else, or a copy that can't be written, is drawn as is.
    public static string DrawableFile(string file)
    {
        if (Utf8Undeclared(file) is not { } data) return file;
        var copy = Path.Combine(Path.GetDirectoryName(file) ?? "", Path.GetFileNameWithoutExtension(file) + ".utf8" + Path.GetExtension(file));
        try
        {
            using (var output = File.Create(copy))
            {
                output.Write(Bom);
                output.Write(data);
            }
            return copy;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return file; }
    }
}
