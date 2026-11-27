using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Model;

namespace Hermes.Core.Attachments;

/// What a stored row says about attachments (HermesKit/Attachments/AttachmentHydration.swift; spec 1x-attachments §7.1,
/// spec 03 §6.6): `@image:` lines (Hermes' own form), the older `[Image attached at: …]` hint, leading `@file:` /
/// `@folder:` / `@url:` lines, non-voice `MEDIA:` lines, and image parts of a content array (inline `data:` bytes
/// decoded into the inline store; https; absolute paths). Pure apart from the inline store.
public static partial class AttachmentHydration
{
    public sealed record Lifted(string Text, IReadOnlyList<string> Refs, IReadOnlyList<MessageAttachment> Attachments);

    [GeneratedRegex(@"^@image:(`[^`\n]+`|""[^""\n]+""|'[^'\n]+'|\S+)$")]
    private static partial Regex ImageRe();
    [GeneratedRegex(@"^\[Image attached at: (.+)\]$")]
    private static partial Regex AttachedAtRe();
    [GeneratedRegex(@"^MEDIA:\s*(""[^""\n]+""|`[^`\n]+`|'[^'\n]+'|\S+)$")]
    private static partial Regex MediaLineRe();
    [GeneratedRegex(@"^@(file|folder|url|image|tool|line|terminal|session):(`[^`\n]+`|""[^""\n]+""|'[^'\n]+'|\S+)$")]
    private static partial Regex ReferenceLineRe();
    /// MEDIA: inside a reply's sentence: a quoted value, or an absolute path up to whitespace.
    [GeneratedRegex(@"MEDIA:\s*(""[^""\n]+""|`[^`\n]+`|'[^'\n]+'|(?:/|~/|[A-Za-z]:\\)\S+)")]
    private static partial Regex InlineMediaRe();

    /// One pair of surrounding quotes (backticks, double or single) off a ref value.
    public static string Unquote(string value)
    {
        var v = value.Trim(' ', '\t');
        if (v.Length >= 2 && v[0] == v[^1] && v[0] is '`' or '"' or '\'') return v[1..^1];
        return v;
    }

    /// splitLeadingAttachmentRefs (reference-kinds.ts:188-197): a leading block of @file: / @folder: / @url: lines.
    public static (List<string> Refs, string Text) SplitLeadingRefs(string text)
    {
        var lines = text.Split('\n').ToList();
        var refs = new List<string>();
        while (lines.Count > 0 && (lines[0].StartsWith("@file:") || lines[0].StartsWith("@folder:") || lines[0].StartsWith("@url:")))
        {
            var trimmed = lines[0].TrimEnd();
            if (!ReferenceLineRe().IsMatch(trimmed)) break;
            refs.Add(trimmed);
            lines.RemoveAt(0);
        }
        return refs.Count == 0 ? ([], text) : (refs, string.Join("\n", lines).Trim());
    }

    private static MessageAttachment Image(string path) =>
        new(AttachmentKind.Image, new AttachmentSource.Gateway(path), MediaKinds.NameOfPath(path, image: true));

    private static MessageAttachment FileAt(string path, AttachmentKind kind = AttachmentKind.File) =>
        new(kind, new AttachmentSource.Gateway(path), MediaKinds.NameOfPath(path, image: false));

    /// Rules 1–5 on a user row's text: images (refs, [Image attached at:], MEDIA: images), files (leading @file: /
    /// @folder: lines, MEDIA: files). Audio MEDIA: lines stay text (voice memos are the voice stream's).
    public static Lifted LiftText(string raw)
    {
        if (!raw.Contains('@') && !raw.Contains("[Image attached at:") && !raw.Contains("MEDIA:"))
            return new Lifted(raw, [], []);
        var images = new List<MessageAttachment>();
        var mediaFiles = new List<MessageAttachment>();
        var imageRefs = new List<string>();
        var kept = new List<string>();
        foreach (var line in raw.Split('\n'))
        {
            var t = line.TrimEnd();
            if (t.StartsWith("@image:"))
            {
                var m = ImageRe().Match(t);
                var path = Unquote(m.Success ? m.Groups[1].Value : t["@image:".Length..]);
                if (path.Length > 0)
                {
                    imageRefs.Add(t);
                    images.Add(Image(path));
                    continue;
                }
            }
            if (t.StartsWith("[Image attached at: ") && AttachedAtRe().Match(t) is { Success: true } at
                && at.Groups[1].Value.Trim() is { Length: > 0 } atPath)
            {
                images.Add(Image(atPath));
                continue;
            }
            if (t.StartsWith("MEDIA:") && MediaLineRe().Match(t) is { Success: true } media)
            {
                var path = Unquote(media.Groups[1].Value);
                var kind = MediaKinds.Kind(path);
                if (path.Length > 0 && kind != MediaKind.Audio && (path.StartsWith('/') || path.StartsWith('~')))
                {
                    if (kind == MediaKind.Image) images.Add(Image(path)); else mediaFiles.Add(FileAt(path));
                    continue;
                }
            }
            kept.Add(line);
        }
        // [screenshot] / [image] describe the same pictures (session_history.py:111-148).
        if (images.Count > 0) kept.RemoveAll(l => l is "[screenshot]" or "[image]");
        var cleaned = images.Count == 0 && mediaFiles.Count == 0 && imageRefs.Count == 0 ? raw : string.Join("\n", kept);
        var (refs, rest) = SplitLeadingRefs(cleaned);
        var files = new List<MessageAttachment>();
        foreach (var r in refs)
        {
            if (r.StartsWith("@folder:")) files.Add(FileAt(Unquote(r["@folder:".Length..]), AttachmentKind.Folder));
            else if (r.StartsWith("@url:"))
            {
                var url = Unquote(r["@url:".Length..]);
                files.Add(new MessageAttachment(AttachmentKind.Link, new AttachmentSource.Gateway(url), LinkDisplay(url)));
            }
            else if (r.StartsWith("@file:")) files.Add(FileAt(Unquote(r["@file:".Length..])));
        }
        var text = refs.Count == 0 ? (images.Count == 0 && mediaFiles.Count == 0 ? cleaned : cleaned.Trim()) : rest;
        return new Lifted(text, [.. refs, .. imageRefs], [.. files, .. mediaFiles, .. images]);
    }

    /// LinkText.display: the URL without its scheme.
    public static string LinkDisplay(string url)
    {
        foreach (var prefix in new[] { "https://", "http://" })
            if (url.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) return url[prefix.Length..];
        return url;
    }

    /// Rules 1–6 on a whole user row: its text (already the display content) and its raw content (image parts).
    public static Lifted LiftUser(string raw, JsonNode? content)
    {
        var lifted = LiftText(raw);
        var parts = ImageParts(content);
        if (parts.Count == 0) return lifted;
        var decoded = parts.Select(AttachmentFromPart).Where(a => a != null).Select(a => a!).ToList();
        var attachments = lifted.Attachments.ToList();
        var refImages = attachments.Select((a, i) => (a, i)).Where(x => x.a.Kind == AttachmentKind.Image).ToList();
        if (refImages.Count > 0 && refImages.Count == decoded.Count)
        {
            // Hermes' native-vision form: N refs and N parts are the same pictures — the path's name, the part's bytes.
            for (var k = 0; k < refImages.Count; k++)
            {
                var part = decoded[k];
                if (part.Source is not AttachmentSource.Inline) continue;
                attachments[refImages[k].i] = refImages[k].a with
                {
                    Source = part.Source, PixelWidth = part.PixelWidth, PixelHeight = part.PixelHeight, ByteSize = part.ByteSize,
                };
            }
        }
        else attachments.AddRange(decoded);
        var text = lifted.Text is "[image]" or "[screenshot]" ? "" : lifted.Text;
        return lifted with { Text = text, Attachments = attachments };
    }

    public static bool IsImagePart(JsonObject o)
    {
        var type = o.Str("type") ?? "";
        return type is "image_url" or "input_image" or "image" || o.ContainsKey("image_url");
    }

    /// The image parts of a content array (type image_url / input_image / image, or an image_url key).
    public static List<JsonObject> ImageParts(JsonNode? content) =>
        content is JsonArray a ? [.. a.OfType<JsonObject>().Where(IsImagePart)] : [];

    /// One part as an attachment: a decoded data: image (into the inline store), an https URL, or an absolute path.
    public static MessageAttachment? AttachmentFromPart(JsonObject part)
    {
        var value = part.Obj("image_url").Str("url") ?? part.Str("image_url") ?? part.Str("url") ?? part.Obj("source").Str("url");
        if (value == null && part.Obj("source") is { } src && src.Str("type") == "base64"
            && src.Str("media_type") is { } media && src.Str("data") is { } data)
            value = $"data:{media};base64,{data}";
        return value == null ? null : AttachmentFromUrlString(value);
    }

    public static MessageAttachment? AttachmentFromUrlString(string value)
    {
        if (value.StartsWith("data:"))
        {
            var comma = value.IndexOf(',');
            if (comma < 0 || !value[..comma].Contains(";base64") || !value.StartsWith("data:image/")) return null;
            var encoded = value[(comma + 1)..];
            // Decoded size ≈ ¾ of the text: refuse before decoding anything too big.
            if (encoded.Length / 4L * 3 > InlineMediaStore.MaxBytes)
                return new MessageAttachment(AttachmentKind.Image, new AttachmentSource.TooLarge(), "Photo");
            byte[] data;
            try { data = Convert.FromBase64String(string.Concat(encoded.Where(c => !char.IsWhiteSpace(c)))); }
            catch (FormatException) { return null; }
            if (data.Length == 0) return null;
            var key = InlineMediaStore.Store(data);
            var size = ImageHeader.PixelSize(data);
            return new MessageAttachment(AttachmentKind.Image, new AttachmentSource.Inline(key), "Photo", size?.Width, size?.Height,
                data.Length);
        }
        if (Uri.TryCreate(value, UriKind.Absolute, out var url) && url.Scheme == "https")
        {
            var name = Uri.UnescapeDataString(url.Segments.LastOrDefault()?.Trim('/') ?? "");
            return new MessageAttachment(AttachmentKind.Image, new AttachmentSource.Remote(url), name.Length == 0 ? "Photo" : name);
        }
        if (value.StartsWith('/') || value.StartsWith('~')) return Image(value);
        return null;
    }

    /// A user row as bubble parts: its photos, its file rows, then the words.
    public static List<ChatPart> UserParts(string raw, JsonNode? content)
    {
        var lifted = LiftUser(raw, content);
        var parts = new List<ChatPart>();
        // The bubble's order: the photos, then file rows, then the caption (spec §7.3).
        parts.AddRange(lifted.Attachments.Where(a => a.IsImage).Select(a => new AttachmentPart(a)));
        parts.AddRange(lifted.Attachments.Where(a => !a.IsImage).Select(a => new AttachmentPart(a)));
        parts.Add(new TextPart(lifted.Text));
        return parts;
    }

    /// A reply's own media (spec §7.5): a line that is only `MEDIA:<path>` leaves the words and becomes a photo or a
    /// file row; a `MEDIA:<path>` inside a sentence keeps its name in the sentence and adds the row after it. Code
    /// fences are left alone, and so are audio files (the voice stream's) and relative paths. [page-cards] A page (.html)
    /// alone on its line stays in the words, where it draws as a page card (PageCards.Split).
    public static List<ChatPart> ReplyParts(string text)
    {
        if (!text.Contains("MEDIA:")) return [new TextPart(text)];
        var found = new List<MessageAttachment>();
        var kept = new List<string>();
        var fence = false;
        foreach (var line in text.Split('\n'))
        {
            if (line.TrimStart().StartsWith("```")) { fence = !fence; kept.Add(line); continue; }
            if (fence || !line.Contains("MEDIA:")) { kept.Add(line); continue; }
            var t = line.Trim();
            // [page-cards] A page alone on its line stays in the words, in its place: they draw it as a page card.
            if (Hermes.Core.Transcripts.PageCards.CardPath(t) is { } page && ReplyAttachment(page) != null) { kept.Add(line); continue; }
            if (MediaLineRe().Match(t) is { Success: true } whole && ReplyAttachment(Unquote(whole.Groups[1].Value)) is { } a)
            {
                found.Add(a);
                continue;
            }
            kept.Add(InlineMediaRe().Replace(line, m =>
            {
                var raw = Unquote(m.Groups[1].Value);
                var trailing = "";
                if (m.Groups[1].Value[0] is not ('"' or '`' or '\''))
                    while (raw.Length > 1 && raw[^1] is '.' or ',' or ';' or ':' or '!' or '?' or ')') { trailing = raw[^1] + trailing; raw = raw[..^1]; }
                if (ReplyAttachment(raw) is not { } inline) return m.Value;
                found.Add(inline);
                return inline.Name + trailing;
            }));
        }
        if (found.Count == 0) return [new TextPart(text)];
        var words = string.Join("\n", kept).Trim();
        var parts = new List<ChatPart>();
        if (words.Length > 0) parts.Add(new TextPart(words));
        parts.AddRange(found.Select(a => new AttachmentPart(a)));
        return parts;
    }

    /// A reply's file on the bot's computer (a page card opens and shares it as a file row would). Null: not a path.
    public static MessageAttachment? ReplyAttachment(string path)
    {
        if (path.Length == 0) return null;
        if (!(path.StartsWith('/') || path.StartsWith('~') || Regex.IsMatch(path, @"^[A-Za-z]:\\"))) return null;
        var kind = MediaKinds.Kind(path);
        if (kind == MediaKind.Audio) return null;
        return kind == MediaKind.Image ? Image(path) : FileAt(path);
    }
}
