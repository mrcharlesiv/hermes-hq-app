using System.Text.Json.Nodes;

namespace Hermes.Core.Attachments;

// Value types for photos and files (HermesKit/Attachments/AttachmentModels.swift; spec 1x-attachments §6.1, §7.2,
// §7.7): what sits in a composer draft, what a message shows, and an image_generate result.

public enum DraftKind { Image, File, Link }

/// Where one tray item is, from the pick to the send (DraftAttachment.Upload).
public abstract record UploadState
{
    /// Being imported / normalised on this PC.
    public sealed record Preparing(double? Fraction) : UploadState;
    /// Ready; the upload has not started (offline, or behind another).
    public sealed record Waiting : UploadState;
    public sealed record Uploading(long Sent, long Total) : UploadState;
    /// On the gateway: its path and the staging folder it sits in.
    public sealed record Uploaded(string Path, string Folder) : UploadState;
    public sealed record Failed(string Reason, bool Retryable) : UploadState;

    public static readonly UploadState Ready = new Waiting();
}

/// One photo or file in a chat's draft (spec §6.1). `LocalFile` is the full path of this PC's own copy, inside the
/// account's staging folder ("" for a link).
public sealed record DraftAttachment(string Id, DraftKind Kind, string Name, string LocalFile, long ByteSize,
    int? PixelWidth, int? PixelHeight, UploadState Upload, string? RefText = null)
{
    public bool IsLink => Kind == DraftKind.Link;
    public bool IsPreparing => Upload is UploadState.Preparing;
    public bool IsUploaded => Upload is UploadState.Uploaded;
    public string? GatewayPath => (Upload as UploadState.Uploaded)?.Path;
    public string? StagingFolder => (Upload as UploadState.Uploaded)?.Folder;
    public UploadState.Failed? Failure => Upload as UploadState.Failed;

    /// Whether a failed tile offers Try Again: a final refusal fails the same way again; "no folder for uploads" is
    /// final too, but the gateway's owner can add the folder meanwhile.
    public bool OffersRetry => Failure is { } f && (f.Retryable || f.Reason == AttachmentUploadException.NoFolderReason);

    /// Picked audio waits for Send (the voice stream transcribes it once); everything else uploads at once.
    public bool DefersUpload => Kind == DraftKind.File && MediaKinds.Kind(Name) == MediaKind.Audio;
}

public enum AttachmentKind { Image, File, Folder, Link }

/// Where a message attachment's bytes are (MessageAttachment.Source).
public abstract record AttachmentSource
{
    /// @image: / @file: / MEDIA: path (absolute, or relative to the session's working folder).
    public sealed record Gateway(string Path) : AttachmentSource;
    /// A decoded data: part; its bytes are in the inline media store under this key.
    public sealed record Inline(string MediaKey) : AttachmentSource;
    /// Your send from this PC, before the media cache holds the uploaded copy.
    public sealed record Local(string DraftId, string LocalPath) : AttachmentSource;
    /// An https image (public internet only, no cookies).
    public sealed record Remote(Uri Url) : AttachmentSource;
    /// A known image with no bytes we can show ("Photo too large to load").
    public sealed record TooLarge : AttachmentSource;
}

/// A photo or file shown in a message (spec §7.2).
public sealed record MessageAttachment(AttachmentKind Kind, AttachmentSource Source, string Name, int? PixelWidth = null,
    int? PixelHeight = null, long? ByteSize = null, string? UploadedPath = null)
{
    public bool IsImage => Kind == AttachmentKind.Image;

    /// The gateway path behind this attachment, if it has one.
    public string? GatewayPath => Source switch
    {
        AttachmentSource.Gateway g => g.Path,
        AttachmentSource.Local => UploadedPath,
        _ => null,
    };

    /// The same attachment as the transcript cache keeps it: Local becomes its gateway path, or null when the upload
    /// never finished (no local paths survive into the cache).
    public MessageAttachment? Cacheable => Source switch
    {
        AttachmentSource.Local when UploadedPath is { } p => this with { Source = new AttachmentSource.Gateway(p), UploadedPath = null },
        AttachmentSource.Local => null,
        _ => this,
    };

    /// "PDF · 2.4 MB", "Folder", "Link".
    public string Detail => Kind switch
    {
        AttachmentKind.Folder => "Folder",
        AttachmentKind.Link => "Link",
        _ => MediaKinds.Detail(Name, ByteSize),
    };

    public MediaKind MediaKind => Kind switch
    {
        AttachmentKind.Image => MediaKind.Image,
        AttachmentKind.Folder => MediaKind.Folder,
        _ => MediaKinds.Kind(Name),
    };
}

/// The image an image_generate call made (spec §7.7; V:lib/generated-images.ts:51-80).
public sealed record GeneratedImageInfo(string? Source, int? PixelWidth, int? PixelHeight, GeneratedImageInfo.AspectHint Aspect,
    bool Success, IReadOnlySet<string> Echoes)
{
    public enum AspectHint { Landscape, Square, Portrait }

    /// Width ÷ height for the frame: the result's pixel size when known, else the requested aspect.
    public double Ratio => PixelWidth is > 0 && PixelHeight is > 0
        ? (double)PixelWidth.Value / PixelHeight.Value
        : Aspect switch { AspectHint.Square => 1, AspectHint.Portrait => 9.0 / 16.0, _ => 16.0 / 9.0 };

    /// The image's name for Narrator and "Open image: <name>".
    public string Name
    {
        get
        {
            if (Source is not { } s) return "Image";
            if (Uri.TryCreate(s, UriKind.Absolute, out var u) && u.Scheme is "http" or "https")
                return u.Segments.LastOrDefault()?.Trim('/') is { Length: > 0 } n ? Uri.UnescapeDataString(n) : "Image";
            var last = MediaKinds.NameOfPath(s, image: true);
            return last == "Photo" ? "Image" : last;
        }
    }

    /// Frame (spec §7.7): w = min(column, 320); h from the ratio; past 400 tall, h = 400 and w follows.
    public (double Width, double Height) Frame(double column)
    {
        var w = Math.Min(column, 320);
        var h = w / Ratio;
        if (h > 400) { h = 400; w = 400 * Ratio; }
        return (w, h);
    }

    /// From the call's arguments and its result (an object, or a JSON string of one). Null when the call failed or
    /// settled without an image; a running call (no result yet) gives a sourceless placeholder.
    public static GeneratedImageInfo? From(JsonNode? args, JsonNode? result, bool running)
    {
        var argsObj = args is JsonValue v && v.TryGetValue(out string? text) ? J.Parse(text) : args;
        var aspect = (argsObj.Str("aspect_ratio") ?? "").ToLowerInvariant() switch
        {
            "square" => AspectHint.Square,
            "portrait" => AspectHint.Portrait,
            _ => AspectHint.Landscape,
        };
        if (result == null) return running ? new GeneratedImageInfo(null, null, null, aspect, true, new HashSet<string>()) : null;
        var obj = AsObject(result);
        if (obj == null || obj.Bool("success") == false) return null;
        var image = (obj.Str("host_image") ?? obj.Str("image"))?.Trim();
        if (string.IsNullOrEmpty(image)) return null;
        int? w = null, h = null;
        if (obj.Str("pixel_size") is { } size)
        {
            var parts = size.ToLowerInvariant().Split('x').Select(p => int.TryParse(p.Trim(), out var n) ? n : 0).ToArray();
            if (parts.Length == 2 && parts[0] > 0 && parts[1] > 0) { w = parts[0]; h = parts[1]; }
        }
        return new GeneratedImageInfo(image, w, h, aspect, true, EchoesOf(obj));
    }

    /// The paths/URLs a reply may repeat for this image (so prose drops them).
    public static IReadOnlySet<string> EchoesOf(JsonNode? result) =>
        AsObject(result) is { } o
            ? new[] { "host_image", "image", "agent_visible_image" }.Select(k => o.Str(k)).Where(s => !string.IsNullOrEmpty(s))
                .Select(s => s!).ToHashSet()
            : new HashSet<string>();

    private static JsonObject? AsObject(JsonNode? n) =>
        n as JsonObject ?? (n is JsonValue jv && jv.TryGetValue(out string? s) ? J.Parse(s) as JsonObject : null);
}
