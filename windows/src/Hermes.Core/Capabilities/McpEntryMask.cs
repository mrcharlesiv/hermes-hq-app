using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Hermes.Core.Capabilities;

/// Port of HermesKit/Store/McpEntryMask.swift (the web's mcp-entry-mask.ts, spec 3x §6, §7). Connector › Advanced shows
/// the selected server's entry read-only with every credential replaced; its log goes through the same masker. Each
/// rule keeps the web's name; the patterns run in ECMAScript mode so \w, \d and \s mean what they mean in JavaScript.
public sealed class McpEntryMask
{
    public const string MASK = "••••••";

    /// The web's default masker: `${VAR}` references are masked too.
    public static readonly McpEntryMask Phone = new();

    public string Mask { get; init; } = MASK;
    /// Leave `${VAR}` references as written.
    public bool KeepRefs { get; init; }
    public bool FreeRuns { get; init; } = true;

    private static Regex R(string pattern, bool ignoreCase = false) =>
        new(pattern, RegexOptions.ECMAScript | RegexOptions.CultureInvariant | (ignoreCase ? RegexOptions.IgnoreCase : RegexOptions.None));

    public static readonly Regex SECRET_KEY = R(@"(?:key|token|secret|passw(?:or)?d|authorization|cookie|credential|bearer)", true);
    public static readonly Regex SECRET_PARAM = R(@"^(?:auth|sig|signature|code|session(?:[-_]?id)?|hmac|hash|access|customer[-_]?id|user[-_]?id)$", true);
    public static readonly IReadOnlySet<string> SECRET_MAPS = new HashSet<string> { "headers", "env", "environment" };
    public static readonly Regex SAFE_HEADER = R(@"^(?:content-type|accept(?:-[a-z]+)?)$", true);
    public static readonly Regex SECRET_VALUE = R(@"\b(?:sk-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9_]{8,}|xox[abprs]-[A-Za-z0-9-]{8,}|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)\b");
    public static readonly Regex SECRET_FLAG = R(@"^--?[\w-]*(?:key|token|secret|passw(?:or)?d|auth|cookie|credential)[\w-]*$", true);
    public static readonly Regex HEADER_FLAG = R(@"^(?:--header|-H)$");
    public static readonly Regex TOKEN_RUN = R(@"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[A-Za-z0-9]{16,}", true);
    public static readonly Regex URL_IN_TEXT = R(@"\b[a-z][a-z0-9+.-]*://[^\s""'<>]+", true);
    public static readonly Regex ENV_REF = R(@"\$\{[A-Za-z_][A-Za-z0-9_]*\}");
    public static readonly Regex IS_URL = R(@"^[a-z][a-z0-9+.-]*://", true);
    public static readonly Regex HEADER_LINE = R(@"^\s*([A-Za-z0-9_-]+)\s*:\s*(\S.*)$");
    public static readonly Regex URL_PARTS = R(@"^([a-z][a-z0-9+.-]*://)([^/?#]*)([^?#]*)(\?[^#]*)?(#.*)?$", true);
    public static readonly Regex NAMED = R(@"\b([\w-]*(?:api[-_]?key|token|secret|passw(?:or)?d|authorization|cookie|credential)[""']?\s*[:=]\s*)(?:(?:Bearer|Basic|Token)\s+)?(""[^""]*""|'[^']*'|[^\s,;""']+)", true);
    public static readonly Regex BEARER = new(@"\b(Bearer|Basic)\s+(?!••|«)[^\s,;""']+", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    public static readonly Regex FLAGGED = R(@"^(--header=)(.+)$");
    public static readonly Regex ASSIGNED = R(@"^([^=\s]*(?:key|token|secret|passw(?:or)?d|auth|cookie|credential)[^=\s]*=)(.+)$", true);
    public static readonly Regex AUTH_METHOD = R(@"^(?:none|oauth|bearer|basic|header)$", true);
    private static readonly Regex HAS_DIGIT = R(@"\d");
    private static readonly Regex HAS_LETTER = R(@"[A-Za-z]");

    private string Template => Mask.Replace("$", "$$");
    private bool Ref(string value) => KeepRefs && ENV_REF.IsMatch(value);
    private string Whole(string value) => value.Length > 0 && !Ref(value) ? Mask : value;

    private string Runs(string value) => TOKEN_RUN.Replace(value, m =>
        m.Value.Contains('-') || (HAS_DIGIT.IsMatch(m.Value) && HAS_LETTER.IsMatch(m.Value)) ? Mask : m.Value);

    private string OutsideRefs(string value, Func<string, string> apply)
    {
        if (!KeepRefs) return apply(value);
        var sb = new StringBuilder();
        var last = 0;
        foreach (Match m in ENV_REF.Matches(value))
        {
            sb.Append(apply(value[last..m.Index])).Append(m.Value);
            last = m.Index + m.Length;
        }
        return sb.Append(apply(value[last..])).ToString();
    }

    /// "Authorization: Bearer abc" → "Authorization: ••••••" for a secret header's name, and for any header when
    /// `always`. null when `value` is not a header.
    private string? Header(string value, bool always = false)
    {
        var m = HEADER_LINE.Match(value);
        if (!m.Success || IS_URL.IsMatch(value.Trim())) return null;
        var name = m.Groups[1].Value; var rest = m.Groups[2].Value;
        if (!always && !SECRET_KEY.IsMatch(name)) return null;
        return Ref(rest) || SAFE_HEADER.IsMatch(name) ? value : $"{name}: {Mask}";
    }

    private static string Decode(string text)
    {
        try { return Uri.UnescapeDataString(text.Replace('+', ' ')); } catch { return text; }
    }

    private string Url(string value)
    {
        var parts = URL_PARTS.Match(value);
        if (!parts.Success) return Runs(value);
        var scheme = parts.Groups[1].Value; var authority = parts.Groups[2].Value; var path = parts.Groups[3].Value;
        var query = parts.Groups[4].Value; var hash = parts.Groups[5].Value;
        // A username alone is often the token itself (https://TOKEN@host).
        var host = authority;
        var at = authority.LastIndexOf('@');
        if (at >= 0)
        {
            var user = string.Join(":", authority[..at].Split(':').Select(Whole));
            host = user + "@" + authority[(at + 1)..];
        }
        // Hosted "secret URL" servers carry the token in the path (…/s/<token>/mcp).
        var route = string.Join("/", path.Split('/').Select(s => Ref(s) ? s : Runs(s)));
        var search = "";
        if (query.Length > 0)
        {
            search = "?" + string.Join("&", query[1..].Split('&').Select(pair =>
            {
                var eq = pair.IndexOf('=');
                if (eq < 0) return pair;
                var rawName = pair[..eq];
                var name = Decode(rawName); var param = Decode(pair[(eq + 1)..]);
                var secret = param.Length > 0 && !Ref(param) && (SECRET_KEY.IsMatch(name) || SECRET_PARAM.IsMatch(name) || Runs(param) != param);
                return secret ? $"{rawName}={Mask}" : pair;
            }));
        }
        return scheme + host + route + search + hash;
    }

    /// Free text (an argument, a server log line): "Name: value" and "name=value" secrets, Bearer credentials, known
    /// key shapes, URLs' credentials and random-looking runs.
    public string Text(string value)
    {
        var template = Template;
        string Plain(string part) => OutsideRefs(part, piece =>
        {
            var o = NAMED.Replace(piece, "$1" + template);
            o = BEARER.Replace(o, "$1 " + template);
            o = SECRET_VALUE.Replace(o, template);
            return FreeRuns ? Runs(o) : o;
        });
        var sb = new StringBuilder();
        var last = 0;
        foreach (Match m in URL_IN_TEXT.Matches(value))
        {
            sb.Append(Plain(value[last..m.Index])).Append(Url(m.Value));
            last = m.Index + m.Length;
        }
        return sb.Append(Plain(value[last..])).ToString();
    }

    private string String(string value, string key)
    {
        if (value.Length == 0) return value;
        if (SECRET_KEY.IsMatch(key)) return Whole(value);
        if (Header(value) is { } named) return named;
        if (IS_URL.IsMatch(value)) return Url(value);
        if (FLAGGED.Match(value) is { Success: true } f) return f.Groups[1].Value + (Header(f.Groups[2].Value, always: true) ?? Whole(f.Groups[2].Value));
        if (ASSIGNED.Match(value) is { Success: true } a) return a.Groups[1].Value + Whole(a.Groups[2].Value);
        return Text(value);
    }

    public JsonNode? Entry(JsonNode? value) => Entry(value, "", false);

    private JsonNode? Entry(JsonNode? value, string key, bool inSecretMap)
    {
        switch (value)
        {
            case JsonValue v when v.TryGetValue(out string? s):
                return JsonValue.Create(inSecretMap ? Whole(s) : String(s, key));
            case JsonArray items:
            {
                var o = new JsonArray();
                for (var i = 0; i < items.Count; i++)
                {
                    var flag = i > 0 ? J.AsString(items[i - 1]) ?? "" : "";
                    if (items[i] is JsonValue iv && iv.TryGetValue(out string? s) && flag.Length > 0)
                    {
                        if (HEADER_FLAG.IsMatch(flag)) { o.Add(Header(s, always: true) ?? Whole(s)); continue; }
                        if (SECRET_FLAG.IsMatch(flag)) { o.Add(Whole(s)); continue; }
                    }
                    o.Add(Entry(items[i], key, inSecretMap));
                }
                return o;
            }
            case JsonObject map:
            {
                var headers = key.Equals("headers", StringComparison.OrdinalIgnoreCase);
                var o = new JsonObject();
                foreach (var (name, child) in map)
                {
                    // "auth": "oauth" names a method, and Content-Type / Accept a format; neither is a credential.
                    if ((name == "auth" && J.AsString(child) is { } m && AUTH_METHOD.IsMatch(m)) || (headers && SAFE_HEADER.IsMatch(name)))
                        o[name] = child?.DeepClone();
                    else
                    {
                        var container = child is JsonObject or JsonArray;
                        o[name] = Entry(child, name, inSecretMap || SECRET_MAPS.Contains(name.ToLowerInvariant()) || (SECRET_KEY.IsMatch(name) && container));
                    }
                }
                return o;
            }
            default:
                return value?.DeepClone();
        }
    }

    /// `JSON.stringify({[name]: maskMcpEntry(entry)}, null, 2)` with sorted keys.
    public string ConfigurationText(string name, JsonNode? entry)
    {
        var masked = new JsonObject { [name] = Entry(entry) };
        return Pretty(Sorted(masked), 0);
    }

    private static JsonNode? Sorted(JsonNode? n) => n switch
    {
        JsonObject o => new JsonObject(o.OrderBy(p => p.Key, StringComparer.Ordinal).Select(p => KeyValuePair.Create(p.Key, Sorted(p.Value)))),
        JsonArray a => new JsonArray([.. a.Select(Sorted)]),
        _ => n?.DeepClone(),
    };

    private static readonly JsonSerializerOptions Relaxed = new() { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    private static string Pretty(JsonNode? n, int depth)
    {
        var pad = new string(' ', (depth + 1) * 2); var end = new string(' ', depth * 2);
        switch (n)
        {
            case JsonObject o when o.Count == 0: return "{}";
            case JsonObject o:
                return "{\n" + string.Join(",\n", o.Select(p => $"{pad}{JsonSerializer.Serialize(p.Key, Relaxed)} : {Pretty(p.Value, depth + 1)}")) + $"\n{end}}}";
            case JsonArray a when a.Count == 0: return "[]";
            case JsonArray a: return "[\n" + string.Join(",\n", a.Select(v => pad + Pretty(v, depth + 1))) + $"\n{end}]";
            case null: return "null";
            default: return n.ToJsonString(Relaxed);
        }
    }
}
