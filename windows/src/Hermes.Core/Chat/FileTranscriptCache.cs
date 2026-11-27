using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Hermes.Core.Attachments;
using Hermes.Core.Model;

namespace Hermes.Core.Chat;

/// The newest 40 messages of each chat on disk, so a chat opens with its history already drawn
/// (HermesKit/Store/TranscriptCache.swift): &lt;root&gt;/&lt;sha256(account)[..16]&gt;/&lt;profile&gt;/&lt;storedId&gt;.json,
/// at most 256 KiB an entry and 64 entries (least recently used go first). Purged on sign-out.
public sealed class FileTranscriptCache(string root) : ITranscriptCache
{
    private const int KeepMessages = 40, MaxEntryBytes = 256 * 1024, MaxEntries = 64;
    private readonly object _lock = new();

    private sealed record Dto(string Id, Role Role, List<PartDto> Parts, DateTimeOffset? Timestamp, long? RowId, bool Interrupted);
    private sealed record PartDto(string Kind, string? Text, ToolCall? Tool);

    public IReadOnlyList<ChatMessage>? Read(string account, string profile, string storedId)
    {
        var path = PathFor(account, profile, storedId);
        try
        {
            lock (_lock)
            {
                if (!File.Exists(path)) return null;
                File.SetLastWriteTimeUtc(path, DateTime.UtcNow);
                var dtos = JsonSerializer.Deserialize<List<Dto>>(File.ReadAllBytes(path));
                return dtos?.Select(FromDto).ToList();
            }
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { return null; }
    }

    public void Write(string account, string profile, string storedId, IReadOnlyList<ChatMessage> messages)
    {
        var stored = messages.Where(m => !m.Id.StartsWith("local-")).TakeLast(KeepMessages).Select(ToDto).ToList();
        var bytes = JsonSerializer.SerializeToUtf8Bytes(stored);
        while (bytes.Length > MaxEntryBytes && stored.Count > 1)
        {
            stored.RemoveRange(0, Math.Max(1, stored.Count / 4));
            bytes = JsonSerializer.SerializeToUtf8Bytes(stored);
        }
        if (bytes.Length > MaxEntryBytes) return;
        var path = PathFor(account, profile, storedId);
        try
        {
            lock (_lock)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                var tmp = path + ".tmp";
                File.WriteAllBytes(tmp, bytes);
                File.Move(tmp, path, overwrite: true);
                Trim();
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    public void Purge(string account)
    {
        try { lock (_lock) Directory.Delete(Path.Combine(root, AccountDir(account)), recursive: true); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    private void Trim()
    {
        var files = new DirectoryInfo(root).EnumerateFiles("*.json", SearchOption.AllDirectories)
            .OrderByDescending(f => f.LastWriteTimeUtc).ToList();
        foreach (var f in files.Skip(MaxEntries)) f.Delete();
    }

    private string PathFor(string account, string profile, string storedId) =>
        Path.Combine(root, AccountDir(account), Safe(profile), Safe(storedId) + ".json");

    private static string AccountDir(string account) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(account)))[..16].ToLowerInvariant();

    private static string Safe(string s) =>
        string.Concat(s.Select(c => char.IsLetterOrDigit(c) || c is '-' or '_' or '.' ? c : '_')).TrimStart('.');

    private static Dto ToDto(ChatMessage m) => new(m.Id, m.Role, [.. m.Parts.Select(p => p switch
    {
        TextPart t => new PartDto("text", t.Text, null),
        ReasoningPart r => new PartDto("reasoning", r.Text, null),
        ToolPart tp => new PartDto("tool", null, tp.Call),
        AttachmentPart a => new PartDto(AttachmentCodec.AttachmentKindName, AttachmentCodec.Encode(a), null),
        GeneratedImagePart g => new PartDto(AttachmentCodec.GeneratedKindName, AttachmentCodec.Encode(g), null),
        _ => new PartDto("text", "", null),
    })], m.Timestamp, m.RowId, m.Interrupted);

    private static ChatMessage FromDto(Dto d) => new(d.Id, d.Role, [.. d.Parts.Select<PartDto, ChatPart>(p => p.Kind switch
    {
        "reasoning" => new ReasoningPart(p.Text ?? ""),
        "tool" when p.Tool != null => new ToolPart(p.Tool),
        AttachmentCodec.AttachmentKindName or AttachmentCodec.GeneratedKindName =>
            AttachmentCodec.Decode(p.Kind, p.Text) ?? new TextPart(""),
        _ => new TextPart(p.Text ?? ""),
    })], d.Timestamp, d.RowId, Interrupted: d.Interrupted);
}
