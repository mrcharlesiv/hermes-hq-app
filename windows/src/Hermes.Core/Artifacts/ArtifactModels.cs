using System.Text.Json.Nodes;

namespace Hermes.Core.Artifacts;

/// What an artifact is (HermesKit/Pages/PagesWire.swift `ArtifactRecord.Kind`).
public enum ArtifactKind { Image, File, Link }

public static class ArtifactKinds
{
    public static string Raw(this ArtifactKind kind) => kind switch
    {
        ArtifactKind.Image => "image",
        ArtifactKind.File => "file",
        _ => "link",
    };

    public static ArtifactKind? Parse(string? raw) => raw switch
    {
        "image" => ArtifactKind.Image,
        "file" => ArtifactKind.File,
        "link" => ArtifactKind.Link,
        _ => null,
    };
}

/// A session row the Artifacts index reads (`GET /api/profiles/sessions`; PagesWire.swift `ArtifactSessionRow`).
public sealed record ArtifactSessionRow
{
    public required string Id { get; init; }
    public string? Profile { get; init; }
    public string? Title { get; init; }
    public string? Preview { get; init; }
    public long? MessageCount { get; init; }
    public double? LastActive { get; init; }
    public double? StartedAt { get; init; }
    /// `cwd` as sent: null when the row has no `cwd` key, "" when present and empty (§5.4 phone fixes).
    public string? Cwd { get; init; }
    public bool CwdPresent { get; init; }

    public static ArtifactSessionRow? FromJson(JsonNode? json, string? listedProfile)
    {
        var id = J.AsString(json.Get("id"));
        if (string.IsNullOrEmpty(id)) return null;
        var stamped = Str(json.Get("profile")) ?? Str(json.Get("profile_name"));
        string? cwd = null;
        var present = false;
        if (json is JsonObject o && o.TryGetPropertyValue("cwd", out var c))
        {
            present = true;
            cwd = Str(c) ?? "";
        }
        return new ArtifactSessionRow
        {
            Id = id,
            Profile = (string.IsNullOrEmpty(stamped) ? null : stamped) ?? listedProfile,
            Title = Str(json.Get("title")),
            Preview = Str(json.Get("preview")),
            MessageCount = Number(json.Get("message_count")) is { } n ? (long)n : null,
            LastActive = Number(json.Get("last_active")),
            StartedAt = Number(json.Get("started_at")),
            Cwd = cwd,
            CwdPresent = present,
        };
    }

    internal static string? Str(JsonNode? node) => node is JsonValue v && v.TryGetValue(out string? s) ? s : null;
    internal static double? Number(JsonNode? node) => node is not JsonValue v ? null
        : v.TryGetValue(out double d) ? d
        : v.GetValueKind() == System.Text.Json.JsonValueKind.Number
          && double.TryParse(v.ToJsonString(), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var p) ? p : null;

    /// title → preview → "Untitled session" (`artifact-utils.ts:115-117`).
    public string DisplayTitle
    {
        get
        {
            var t = Title?.Trim() ?? "";
            if (t.Length > 0) return t;
            var p = Preview?.Trim() ?? "";
            return p.Length == 0 ? "Untitled session" : p;
        }
    }

    /// The row says it has no working directory (the key is present and empty).
    public bool LacksCwd => CwdPresent && string.IsNullOrWhiteSpace(Cwd);

    public double Recency => Math.Max(LastActive ?? 0, StartedAt ?? 0);
}

/// A file, image or link a bot produced (PagesWire.swift `ArtifactRecord`).
public sealed record ArtifactRecord
{
    /// "&lt;profile&gt;\u001F&lt;sessionId&gt;:&lt;value&gt;" (profile "default" when unset; ids repeat across profiles).
    public required string Id { get; init; }
    public required ArtifactKind Kind { get; init; }
    public required string Value { get; init; }
    public required string Href { get; init; }
    public required string Label { get; init; }
    public required string SessionId { get; init; }
    public string? Profile { get; init; }
    public required string SessionTitle { get; init; }
    /// Milliseconds since 1970.
    public required double Timestamp { get; init; }
    /// [morepages] How many times this chat named the file or link (3x-morepages §2): the row shows "×N" past 1.
    public int Repeats { get; init; } = 1;

    /// "×3" on a file or link row named more than once; null for one mention and for images.
    public string? RepeatBadge => Kind != ArtifactKind.Image && Repeats > 1 ? $"×{Repeats}" : null;
    /// The badge in words, for Narrator and the top of the row's ⋯ menu: "Mentioned 3 times".
    public string? RepeatSpoken => Kind != ArtifactKind.Image && Repeats > 1 ? $"Mentioned {Repeats} times" : null;

    public JsonObject ToJson()
    {
        var o = new JsonObject
        {
            ["id"] = Id, ["kind"] = Kind.Raw(), ["value"] = Value, ["href"] = Href, ["label"] = Label,
            ["sessionId"] = SessionId, ["sessionTitle"] = SessionTitle, ["timestamp"] = Timestamp, ["repeats"] = Repeats,
        };
        if (Profile != null) o["profile"] = Profile;
        return o;
    }

    /// An index kept by an older build has no `repeats`: it reads as 1 (as the Swift decoder does).
    public static ArtifactRecord? FromJson(JsonNode? json)
    {
        string? S(string key) => ArtifactSessionRow.Str(json.Get(key));
        if (S("id") is not { } id || ArtifactKinds.Parse(S("kind")) is not { } kind || S("value") is not { } value
            || S("href") is not { } href || S("label") is not { } label || S("sessionId") is not { } sid
            || S("sessionTitle") is not { } title || ArtifactSessionRow.Number(json.Get("timestamp")) is not { } ts) return null;
        var repeats = ArtifactSessionRow.Number(json.Get("repeats")) is { } d ? (int)d : 1;
        return new ArtifactRecord
        {
            Id = id, Kind = kind, Value = value, Href = href, Label = label, SessionId = sid, Profile = S("profile"),
            SessionTitle = title, Timestamp = ts, Repeats = Math.Max(1, repeats),
        };
    }
}
