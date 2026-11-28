using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Hermes.Core;

/// Lenient reads over gateway JSON. Like HermesKit's JSONValue: every field is optional, unknown keys are ignored, and
/// YAML-born numbers or bools are coerced where text is expected (spec 02 §2.1).
public static class J
{
    public static JsonNode? Get(this JsonNode? node, string key) =>
        node is JsonObject o && o.TryGetPropertyValue(key, out var v) ? v : null;

    public static string? Str(this JsonNode? node, string key) => AsString(node.Get(key));

    public static string? AsString(JsonNode? v) => v switch
    {
        JsonValue jv when jv.TryGetValue(out string? s) => s,
        JsonValue jv when jv.GetValueKind() is JsonValueKind.Number => jv.ToJsonString(),
        JsonValue jv when jv.GetValueKind() is JsonValueKind.True => "true",
        JsonValue jv when jv.GetValueKind() is JsonValueKind.False => "false",
        _ => null,
    };

    /// Trimmed, or null when empty.
    public static string? Text(this JsonNode? node, string key) =>
        node.Str(key)?.Trim() is { Length: > 0 } s ? s : null;

    public static double? Num(this JsonNode? node, string key) => node.Get(key) switch
    {
        JsonValue jv when jv.TryGetValue(out double d) => d,
        JsonValue jv when jv.TryGetValue(out long l) => l,
        JsonValue jv when jv.TryGetValue(out int i) => i,
        JsonValue jv when jv.TryGetValue(out decimal m) => (double)m,
        JsonValue jv when jv.TryGetValue(out float f) => f,
        JsonValue jv when jv.TryGetValue(out string? s)
            && double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var d) => d,
        _ => null,
    };

    public static long? Int(this JsonNode? node, string key)
    {
        if (node.Get(key) is JsonValue jv)
        {
            if (jv.TryGetValue(out long l)) return l;
            if (jv.TryGetValue(out int i)) return i;
        }
        return node.Num(key) is { } d && double.IsFinite(d) && d >= long.MinValue && d < 9223372036854775808.0
            ? (long)d
            : null;
    }

    public static bool? Bool(this JsonNode? node, string key) => node.Get(key) switch
    {
        JsonValue jv when jv.TryGetValue(out bool b) => b,
        JsonValue jv when jv.TryGetValue(out string? s) => s is "true" or "1" ? true : s is "false" or "0" ? false : null,
        JsonValue jv when jv.TryGetValue(out double d) => d != 0,
        JsonValue jv when jv.TryGetValue(out long l) => l != 0,
        JsonValue jv when jv.TryGetValue(out int i) => i != 0,
        _ => null,
    };

    public static JsonArray? Arr(this JsonNode? node, string key) => node.Get(key) as JsonArray;
    public static JsonObject? Obj(this JsonNode? node, string key) => node.Get(key) as JsonObject;

    public static JsonNode? Parse(string text)
    {
        try { return JsonNode.Parse(text); } catch (JsonException) { return null; }
    }

    private static readonly double MinUnixTimeMilliseconds = DateTimeOffset.MinValue.ToUnixTimeMilliseconds();
    private static readonly double MaxUnixTimeMilliseconds = DateTimeOffset.MaxValue.ToUnixTimeMilliseconds();

    /// Guards against non-finite (NaN / ±Infinity) and out-of-range Unix timestamps so malformed wire numbers
    /// return null cleanly instead of throwing ArgumentOutOfRangeException (H2).
    public static DateTimeOffset? UnixTime(this JsonNode? node, string key)
    {
        if (node.Num(key) is not { } s || !double.IsFinite(s) || s <= 0) return null;
        var ms = s * 1000.0;
        if (!double.IsFinite(ms) || ms < MinUnixTimeMilliseconds || ms > MaxUnixTimeMilliseconds) return null;
        return DateTimeOffset.FromUnixTimeMilliseconds((long)ms);
    }
}
