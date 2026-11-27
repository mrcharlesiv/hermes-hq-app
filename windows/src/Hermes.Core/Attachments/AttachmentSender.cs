using System.Text.Json.Nodes;
using Hermes.Core.Net;
using Hermes.Core.Rpc;

namespace Hermes.Core.Attachments;

/// The attach RPCs and the prompt text (HermesKit/Attachments/AttachmentSender.swift; spec §3.4–§3.8). Exact param
/// sets — Hermes answers any other key with 4000:
///   image.attach  {session_id, path, profile}
///   file.attach   {session_id, path, name, profile}
///   image.detach  {session_id, path, profile}
///   image.attach_bytes {session_id, profile, content_base64, filename} (a gateway-hosted session authority only)
public static class AttachmentSender
{
    /// What a photo-only send says (parity; your bubble hides it, A4).
    public const string DefaultQuestion = "What do you see in this image?";

    /// The prompt.submit text: the files' refs (one per line), a blank line, then your words; photos alone send the
    /// default question.
    public static string PromptText(string typed, IEnumerable<string> fileRefs, bool hasImages)
    {
        var body = typed.Trim();
        var refs = string.Join("\n", fileRefs.Where(r => r.Length > 0));
        var text = string.Join("\n\n", new[] { refs, body }.Where(s => s.Length > 0));
        return text.Length == 0 && hasImages ? DefaultQuestion : text;
    }

    /// Your bubble's text part: what you typed, or the default question for photos alone (drawn as no text).
    public static string BubbleText(string typed, IEnumerable<DraftAttachment> attachments) =>
        typed.Trim().Length == 0 && attachments.Any(a => a.Kind == DraftKind.Image) ? DefaultQuestion : typed;

    public static JsonObject ImageAttachParams(string session, string path, string? profile)
    {
        var p = new JsonObject { ["session_id"] = session, ["path"] = path };
        if (profile != null) p["profile"] = profile;
        return p;
    }

    public static JsonObject FileAttachParams(string session, string path, string name, string? profile)
    {
        var p = new JsonObject { ["session_id"] = session, ["path"] = path, ["name"] = name };
        if (profile != null) p["profile"] = profile;
        return p;
    }

    public static JsonObject ImageDetachParams(string session, string path, string? profile) => ImageAttachParams(session, path, profile);

    /// One attach's outcome.
    public sealed record Attached(string? RefText, string StoredPath, bool Uploaded, int? Width = null, int? Height = null);

    /// Stale: the runtime went away (4001, or 4007 "…no longer live"); resume once and attach again. Otherwise the send
    /// is refused with Reason.
    public sealed record AttachFailure(bool Stale, string Reason);

    public static bool IsStale(GatewayException e) =>
        e.Code == "rpc" && (e.RpcCode == 4001 || (e.RpcCode == 4007 && e.Message.Contains("no longer live", StringComparison.OrdinalIgnoreCase)));

    private static string DidntAccept(string name) => $"Your gateway didn’t accept “{name}”.";

    /// image.attach (60 s: the handler opens the image inline). Success = attached == true.
    public static async Task<(Attached? Ok, AttachFailure? Failed)> AttachImageAsync(RpcConnection rpc, string session, string path,
        string name, string? profile, CancellationToken ct = default)
    {
        try
        {
            var r = await rpc.RequestAsync("image.attach", ImageAttachParams(session, path, profile), TimeSpan.FromSeconds(60), ct);
            if (r.Bool("attached") != true) return (null, new AttachFailure(false, r.Text("message") ?? DidntAccept(name)));
            return (new Attached(null, r.Text("path") ?? path, false, (int?)r.Int("width"), (int?)r.Int("height")), null);
        }
        catch (GatewayException e)
        {
            if (IsStale(e)) return (null, new AttachFailure(true, e.Message));
            return (null, new AttachFailure(false, e.Code == "rpc" && e.Message.Length > 0 ? e.Message : DidntAccept(name)));
        }
    }

    /// The picture types a session authority takes on prompt.submit.
    public static readonly HashSet<string> AuthorityImageMimes = ["image/png", "image/jpeg", "image/gif", "image/webp"];

    public static string ImageMime(string name) => MediaKinds.Ext(name) switch
    {
        "png" => "image/png",
        "gif" => "image/gif",
        "webp" => "image/webp",
        _ => "image/jpeg",
    };

    /// A gateway-hosted Hermes's session authority has no path-based image.attach: the bytes go up, and the answer's
    /// path + mime then ride on prompt.submit as attachments: [{path, mime}].
    public static bool IsAuthority(RpcConnection rpc) => rpc.ReadyPayload.Bool("session_authority") == true;

    public static async Task<(Attached? Ok, string? Mime, AttachFailure? Failed)> AttachImageBytesAsync(RpcConnection rpc,
        string session, byte[] data, string name, string? profile, CancellationToken ct = default)
    {
        var p = new JsonObject { ["session_id"] = session, ["content_base64"] = Convert.ToBase64String(data), ["filename"] = name };
        if (profile != null) p["profile"] = profile;
        try
        {
            var r = await rpc.RequestAsync("image.attach_bytes", p, TimeSpan.FromSeconds(60), ct);
            if (r.Bool("attached") != true || r.Text("path") is not { } path)
                return (null, null, new AttachFailure(false, r.Text("message") ?? DidntAccept(name)));
            var mime = r.Text("mime") ?? ImageMime(name);
            if (!AuthorityImageMimes.Contains(mime)) return (null, null, new AttachFailure(false, DidntAccept(name)));
            return (new Attached(null, path, false), mime, null);
        }
        catch (GatewayException e)
        {
            if (IsStale(e) && e.Message != "invalid_params") return (null, null, new AttachFailure(true, e.Message));
            var reason = e.Code != "rpc" || e.Message.Length == 0 || e.Message == "invalid_params" ? DidntAccept(name) : e.Message;
            return (null, null, new AttachFailure(false, reason));
        }
    }

    /// file.attach (60 s: the handler copies the file inline). Success = attached != false and a non-empty ref_text.
    public static async Task<(Attached? Ok, AttachFailure? Failed)> AttachFileAsync(RpcConnection rpc, string session, string path,
        string name, string? profile, CancellationToken ct = default)
    {
        try
        {
            var r = await rpc.RequestAsync("file.attach", FileAttachParams(session, path, name, profile), TimeSpan.FromSeconds(60), ct);
            if (r.Bool("attached") == false || r.Text("ref_text") is not { } refText)
                return (null, new AttachFailure(false, r.Text("message") ?? DidntAccept(name)));
            var stored = r.Text("path") ?? r.Text("ref_path") ?? path;
            return (new Attached(refText, stored, r.Bool("uploaded") == true), null);
        }
        catch (GatewayException e)
        {
            if (IsStale(e)) return (null, new AttachFailure(true, e.Message));
            return (null, new AttachFailure(false, e.Code == "rpc" && e.Message.Length > 0 ? e.Message : DidntAccept(name)));
        }
    }

    /// image.detach, errors ignored (spec §3.8).
    public static async Task DetachImageAsync(RpcConnection rpc, string session, string path, string? profile)
    {
        try { await rpc.RequestAsync("image.detach", ImageDetachParams(session, path, profile), TimeSpan.FromSeconds(15)); }
        catch (GatewayException) { }
    }

    /// The path a file's ref_text names (@file:<path>, quotes stripped): what the stored row will say.
    public static string? RefPath(string refText)
    {
        var t = refText.Trim();
        return t.StartsWith("@file:") ? AttachmentHydration.Unquote(t["@file:".Length..]) : null;
    }
}
