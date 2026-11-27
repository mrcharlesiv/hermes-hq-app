using System.Text.Json.Nodes;
using Hermes.Core.Model;

namespace Hermes.Core.Attachments;

/// Attachment and generated-image parts as the transcript cache keeps them (spec §7.2): refs only, never bytes and
/// never this PC's own paths (a send whose upload never finished keeps no attachment in the cache).
public static class AttachmentCodec
{
    public const string AttachmentKindName = "attachment", GeneratedKindName = "generated-image";

    public static string? Encode(ChatPart part)
    {
        switch (part)
        {
            case AttachmentPart { Attachment: var raw } when raw.Cacheable is { } a:
                var o = new JsonObject { ["kind"] = a.Kind.ToString(), ["name"] = a.Name };
                switch (a.Source)
                {
                    case AttachmentSource.Gateway g: o["path"] = g.Path; break;
                    case AttachmentSource.Inline i: o["inline"] = i.MediaKey; break;
                    case AttachmentSource.Remote r: o["url"] = r.Url.AbsoluteUri; break;
                    case AttachmentSource.TooLarge: o["tooLarge"] = true; break;
                    default: return null;
                }
                if (a.PixelWidth is { } w) o["w"] = w;
                if (a.PixelHeight is { } h) o["h"] = h;
                if (a.ByteSize is { } b) o["bytes"] = b;
                return o.ToJsonString();
            case GeneratedImagePart g:
                var info = g.Image;
                var j = new JsonObject { ["id"] = g.ToolId, ["source"] = info.Source, ["aspect"] = info.Aspect.ToString() };
                if (info.PixelWidth is { } gw) j["w"] = gw;
                if (info.PixelHeight is { } gh) j["h"] = gh;
                return j.ToJsonString();
            default:
                return null;
        }
    }

    public static ChatPart? Decode(string kind, string? text)
    {
        if (text == null || J.Parse(text) is not JsonObject o) return null;
        if (kind == AttachmentKindName)
        {
            if (!Enum.TryParse<AttachmentKind>(o.Str("kind"), out var k)) return null;
            AttachmentSource? source = o.Str("path") is { } p ? new AttachmentSource.Gateway(p)
                : o.Str("inline") is { } key ? new AttachmentSource.Inline(key)
                : o.Str("url") is { } u && Uri.TryCreate(u, UriKind.Absolute, out var url) ? new AttachmentSource.Remote(url)
                : o.Bool("tooLarge") == true ? new AttachmentSource.TooLarge() : null;
            if (source == null) return null;
            return new AttachmentPart(new MessageAttachment(k, source, o.Str("name") ?? "File", (int?)o.Int("w"), (int?)o.Int("h"),
                o.Int("bytes")));
        }
        if (kind == GeneratedKindName)
        {
            Enum.TryParse<GeneratedImageInfo.AspectHint>(o.Str("aspect"), out var aspect);
            return new GeneratedImagePart(o.Str("id") ?? "", new GeneratedImageInfo(o.Str("source"), (int?)o.Int("w"), (int?)o.Int("h"),
                aspect, true, new HashSet<string>()));
        }
        return null;
    }
}
