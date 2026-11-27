using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Gateways;

namespace Hermes.Core.Settings;

/// Settings › Export Settings… / Import Settings… / Reset to Defaults… (HermesKit/Settings/SettingsFile.swift).
/// `GET /api/config` returns every ${VAR} reference expanded, so an exported file would carry connector bearer tokens and
/// provider keys in plain text: the export writes a placeholder at each credential, and an import never writes a
/// placeholder (or a secret the file lacks) over the value already on the gateway.
public static class SettingsFile
{
    /// What an exported file holds in place of a key or token.
    public const string Placeholder = "«left out of this export»";

    private const RegexOptions I = RegexOptions.IgnoreCase | RegexOptions.CultureInvariant;

    private static bool Matches(string text, string pattern) => Regex.IsMatch(text, pattern, I);

    // ------------------------------------------------------------------ which values are credentials

    /// `api_key_env`, `password_store`: the name of where a secret lives, not the secret.
    private static bool NamesAPlace(string key) => Matches(key, @"_env(?:_?(?:var|name))?$|_store$|_backend$");

    /// Outside connectors: authorization, api key, token, secret, password, bearer, cookie.
    public static bool SecretKey(string key) =>
        Matches(key, @"authorization|api[_-]?key|token|secret|password|bearer|cookie") && !NamesAPlace(key);

    /// A connector's entry: any key-like name.
    public static bool ConnectorSecretKey(string key) =>
        Matches(key, @"key|token|secret|passw(?:or)?d|authorization|cookie|credential|bearer") && !NamesAPlace(key);

    private static bool IsReference(string text) => Matches(text, @"\$\{[A-Za-z_][A-Za-z0-9_]*\}");

    // Swift's `replacingOccurrences(…, options: .regularExpression)`: case-sensitive.
    private static readonly Regex ValueShapes = new(
        @"\b(?:sk-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9_]{8,}|xox[abprs]-[A-Za-z0-9-]{8,}|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)\b",
        RegexOptions.CultureInvariant);
    private const string SecretParams = @"^(?:auth|sig|signature|code|session(?:[-_]?id)?|hmac|hash|access|customer[-_]?id|user[-_]?id)$";

    /// A whole value replaced, unless it is empty or a ${VAR} reference.
    private static string Whole(string text) => text.Length == 0 || IsReference(text) ? text : Placeholder;

    /// Free text: provider key shapes and JWTs; URLs' user info and credential parameters.
    private static string Scrub(string text, bool connector)
    {
        var output = ValueShapes.Replace(text, Placeholder);
        output = MaskUrls(output);
        if (connector)
        {
            // A random-looking run (a bare token argument): 16+ letters and digits mixed, or a UUID.
            output = Regex.Replace(output, @"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[A-Za-z0-9]{16,}", m =>
            {
                var run = m.Value;
                return run.Contains('-') || (run.Any(char.IsAsciiDigit) && run.Any(char.IsLetter)) ? Placeholder : run;
            }, I);
        }
        return output;
    }

    private static string MaskUrls(string text) =>
        Regex.Replace(text, @"\b[a-z][a-z0-9+.-]*://[^\s""'<>]+", m => MaskUrl(m.Value), I);

    /// One URL as `URLComponents` takes it apart and puts it back: user and password (when not ${VAR}) and each
    /// credential parameter's value become the placeholder; a changed URL comes back percent-decoded, and one that
    /// can't be decoded is left as it was.
    private static string MaskUrl(string url)
    {
        var scheme = url.IndexOf("://", StringComparison.Ordinal) + 3;
        var rest = url[scheme..];
        var hashAt = rest.IndexOf('#');
        var fragment = hashAt >= 0 ? rest[hashAt..] : "";
        if (hashAt >= 0) rest = rest[..hashAt];
        var queryAt = rest.IndexOf('?');
        string? query = queryAt >= 0 ? rest[(queryAt + 1)..] : null;
        if (queryAt >= 0) rest = rest[..queryAt];
        var pathAt = rest.IndexOfAny(['/']);
        var authority = pathAt >= 0 ? rest[..pathAt] : rest;
        var path = pathAt >= 0 ? rest[pathAt..] : "";
        var at = authority.LastIndexOf('@');
        string? user = null, password = null;
        var host = authority;
        if (at >= 0)
        {
            var info = authority[..at];
            host = authority[(at + 1)..];
            var colon = info.IndexOf(':');
            user = colon >= 0 ? info[..colon] : info;
            password = colon >= 0 ? info[(colon + 1)..] : null;
        }
        var changed = false;
        if (user != null && !IsReference(Lenient(user))) { user = Placeholder; changed = true; }
        if (password != null && !IsReference(Lenient(password))) { password = Placeholder; changed = true; }
        List<string>? items = null;
        if (query != null)
        {
            items = [];
            foreach (var item in query.Split('&'))
            {
                var eq = item.IndexOf('=');
                var name = Lenient(eq >= 0 ? item[..eq] : item);
                string? value = eq >= 0 ? Lenient(item[(eq + 1)..]) : null;
                if (value is { Length: > 0 } && !IsReference(value) && (ConnectorSecretKey(name) || Matches(name, SecretParams)))
                {
                    value = Placeholder;
                    changed = true;
                }
                items.Add(value == null ? name : $"{name}={value}");
            }
        }
        if (!changed) return url;
        var head = new StringBuilder(url[..scheme]);
        if (user != null) head.Append(user).Append(password != null ? ":" + password : "").Append('@');
        head.Append(host).Append(path);
        if (Strict(head.ToString()) is not { } decodedHead || Strict(fragment) is not { } decodedFragment) return url;
        return decodedHead + (items != null ? "?" + string.Join("&", items) : "") + decodedFragment;
    }

    /// `removingPercentEncoding`: null when a % isn't a valid UTF-8 escape.
    private static string? Strict(string text)
    {
        if (!text.Contains('%')) return text;
        var bytes = new List<byte>();
        for (var i = 0; i < text.Length; i++)
        {
            if (text[i] == '%')
            {
                if (i + 2 >= text.Length || !byte.TryParse(text.AsSpan(i + 1, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var b)) return null;
                bytes.Add(b);
                i += 2;
            }
            else bytes.AddRange(Encoding.UTF8.GetBytes(text[i].ToString()));
        }
        try { return new UTF8Encoding(false, true).GetString(bytes.ToArray()); }
        catch (DecoderFallbackException) { return null; }
    }

    /// A query item's name or value as `URLQueryItem` reads it: valid escapes decoded, anything else kept as written.
    private static string Lenient(string text) => Strict(text) ?? Regex.Replace(text, @"(?:%[0-9A-Fa-f]{2})+", m => Strict(m.Value) ?? m.Value);

    // ------------------------------------------------------------------ export

    /// The config with every credential replaced by the placeholder (numbers, switches, empty values and ${VAR}
    /// references stay as they are).
    public static JsonNode? Redact(JsonNode? config)
    {
        if (config is not JsonObject o) return RedactValue(config, null, false);
        var output = new JsonObject();
        foreach (var (key, value) in o)
        {
            if (key == "mcp_servers" && value is JsonObject servers)
            {
                var masked = new JsonObject();
                foreach (var (name, server) in servers) masked[name] = RedactValue(server, null, true);
                output[key] = masked;
            }
            else output[key] = RedactValue(value, key, false);
        }
        return output;
    }

    private static JsonNode? RedactValue(JsonNode? value, string? key, bool connector, bool flagBefore = false)
    {
        var isSecret = key != null && (connector ? ConnectorSecretKey(key) : SecretKey(key));
        switch (value)
        {
            case JsonValue v when v.GetValueKind() == JsonValueKind.String:
                var text = v.GetValue<string>();
                if (isSecret || flagBefore) return Whole(text);
                if (connector && MaskHeader(text) is { } header) return header;
                if (connector && MaskAssignment(text) is { } assigned) return assigned;
                return Scrub(text, connector);
            case JsonArray items:
                var output = new JsonArray();
                var maskNext = false;
                foreach (var item in items)
                {
                    output.Add(RedactValue(item, key, connector, maskNext));
                    // A flag that takes a credential as its next argument ("--api-key", "--token", "--header").
                    maskNext = connector && item is JsonValue iv && iv.GetValueKind() == JsonValueKind.String
                        && Matches(iv.GetValue<string>(), @"^--?[\w-]*(?:key|token|secret|passw(?:or)?d|auth|cookie|credential)[\w-]*$");
                }
                return output;
            case JsonObject obj:
                var secretMap = connector && key is "headers" or "env" or "environment";
                var masked = new JsonObject();
                foreach (var (k, entry) in obj)
                {
                    if (secretMap && Matches(k, "^(?:content-type|accept(?:-[a-z]+)?)$")) masked[k] = entry?.DeepClone();
                    else if (secretMap && entry is JsonValue ev && ev.GetValueKind() == JsonValueKind.String) masked[k] = Whole(ev.GetValue<string>());
                    else masked[k] = RedactValue(entry, k, connector);
                }
                return masked;
            default:
                return value?.DeepClone();
        }
    }

    /// "Authorization: Bearer ***" → "Authorization: «left out…»".
    private static string? MaskHeader(string text)
    {
        var m = Regex.Match(text, @"^\s*([A-Za-z0-9_-]+)\s*:\s*(\S.*)$", RegexOptions.CultureInvariant);
        if (!m.Success || Matches(text, @"^\s*[a-z][a-z0-9+.-]*://") || !ConnectorSecretKey(m.Groups[1].Value)) return null;
        return IsReference(m.Groups[2].Value) ? text : $"{m.Groups[1].Value}: {Placeholder}";
    }

    /// "API_TOKEN=abc" / "--token=abc" → the name kept, the value left out.
    private static string? MaskAssignment(string text)
    {
        var equals = text.IndexOf('=');
        if (equals < 0) return null;
        string name = text[..equals], value = text[(equals + 1)..];
        if (!Regex.IsMatch(name, @"^-{0,2}[A-Za-z_][A-Za-z0-9_-]*$", RegexOptions.CultureInvariant) || !ConnectorSecretKey(name.Trim('-'))
            || value.Length == 0 || IsReference(value)) return null;
        return $"{name}={Placeholder}";
    }

    /// "Hermes settings 2026-10-11.json": which profile, and the day on this PC.
    public static string ExportFileName(string profile, DateTime now)
    {
        var day = now.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        var cleaned = Regex.Replace(profile, @"[\\/:*?""<>|\x00-\x1f]+", " ");
        cleaned = Regex.Replace(cleaned, @"\s+", " ").Trim(' ', '\t');
        return $"{(cleaned.Length == 0 ? "Hermes" : cleaned)} settings {day}.json";
    }

    /// The file, as Swift's `JSONEncoder` writes it with pretty printing, sorted keys and unescaped slashes (UTF-8).
    public static byte[] FileData(JsonNode? config)
    {
        var sb = new StringBuilder();
        Write(sb, Redact(config), 0);
        return new UTF8Encoding(false).GetBytes(sb.ToString());
    }

    private static void Write(StringBuilder sb, JsonNode? node, int depth)
    {
        var pad = new string(' ', 2 * (depth + 1));
        var close = new string(' ', 2 * depth);
        switch (node)
        {
            case null: sb.Append("null"); break;
            case JsonObject o:
                if (o.Count == 0) { sb.Append("{\n\n").Append(close).Append('}'); break; }
                sb.Append("{\n");
                var first = true;
                foreach (var (key, value) in o.OrderBy(p => p.Key, StringComparer.Ordinal))
                {
                    if (!first) sb.Append(",\n");
                    first = false;
                    sb.Append(pad);
                    WriteString(sb, key);
                    sb.Append(" : ");
                    Write(sb, value, depth + 1);
                }
                sb.Append('\n').Append(close).Append('}');
                break;
            case JsonArray a:
                if (a.Count == 0) { sb.Append("[\n\n").Append(close).Append(']'); break; }
                sb.Append("[\n");
                for (var i = 0; i < a.Count; i++)
                {
                    if (i > 0) sb.Append(",\n");
                    sb.Append(pad);
                    Write(sb, a[i], depth + 1);
                }
                sb.Append('\n').Append(close).Append(']');
                break;
            case JsonValue v:
                switch (v.GetValueKind())
                {
                    case JsonValueKind.String: WriteString(sb, v.GetValue<string>()); break;
                    case JsonValueKind.True: sb.Append("true"); break;
                    case JsonValueKind.False: sb.Append("false"); break;
                    case JsonValueKind.Number: sb.Append(Number(double.Parse(v.ToJsonString(), NumberStyles.Float, CultureInfo.InvariantCulture))); break;
                    default: sb.Append("null"); break;
                }
                break;
        }
    }

    private static void WriteString(StringBuilder sb, string s)
    {
        sb.Append('"');
        foreach (var c in s)
        {
            switch (c)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                case '\b': sb.Append("\\b"); break;
                case '\f': sb.Append("\\f"); break;
                default:
                    if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                    else sb.Append(c);
                    break;
            }
        }
        sb.Append('"');
    }

    /// A number as `JSONValue` encodes it: a whole number under 2^53 as an integer, anything else as Swift's
    /// `Double.description` (decimal from 1e-4 up to 2^53, exponent form outside, "1e+20", "1e-05").
    internal static string Number(double d)
    {
        if (Math.Round(d) == d && Math.Abs(d) < 9.007e15) return ((long)d).ToString(CultureInfo.InvariantCulture);
        var r = d.ToString("R", CultureInfo.InvariantCulture);
        var negative = r.StartsWith('-');
        if (negative) r = r[1..];
        // The shortest round-trip digits and where the point goes.
        var e = r.IndexOfAny(['E', 'e']);
        var exp = e >= 0 ? int.Parse(r[(e + 1)..], CultureInfo.InvariantCulture) : 0;
        var mantissa = e >= 0 ? r[..e] : r;
        var dot = mantissa.IndexOf('.');
        var intDigits = dot >= 0 ? dot : mantissa.Length;
        var digits = mantissa.Replace(".", "");
        var lead = digits.Length - digits.TrimStart('0').Length;
        digits = digits.TrimStart('0').TrimEnd('0');
        if (digits.Length == 0) return negative ? "-0" : "0";
        var point = intDigits - lead + exp;   // value = 0.digits × 10^point
        var abs = Math.Abs(d);
        string text;
        if (abs >= 1e-4 && abs < 9007199254740992.0)
        {
            if (point <= 0) text = "0." + new string('0', -point) + digits;
            else if (point >= digits.Length) text = digits + new string('0', point - digits.Length);
            else text = digits[..point] + "." + digits[point..];
        }
        else
        {
            var e10 = point - 1;
            text = digits[..1] + (digits.Length > 1 ? "." + digits[1..] : "") + "e" + (e10 < 0 ? "-" : "+")
                + Math.Abs(e10).ToString("00", CultureInfo.InvariantCulture);
        }
        return negative ? "-" + text : text;
    }

    // ------------------------------------------------------------------ import

    /// The picked file as a record: null when it isn't JSON with an object at the top ("That file isn’t a Hermes
    /// settings file.").
    public static JsonObject? Parse(byte[]? data)
    {
        if (data == null) return null;
        var span = data.AsSpan();
        if (span.StartsWith(new byte[] { 0xEF, 0xBB, 0xBF })) span = span[3..];
        try { return JsonNode.Parse(span) as JsonObject; }
        catch (JsonException) { return null; }
    }

    /// A left-out value: this placeholder, or the gateway's own redaction.
    public static bool IsPlaceholder(JsonNode? value)
    {
        if (value is not JsonValue v || v.GetValueKind() != JsonValueKind.String) return false;
        var text = v.GetValue<string>();
        return text == Placeholder || text.ToLowerInvariant().StartsWith("«redacted", StringComparison.Ordinal)
            || Regex.IsMatch(text.Trim(' ', '\t'), @"^\*{3,}$");
    }

    /// The file as the gateway should see it: each placeholder takes the value already saved there (or is dropped), and
    /// an object inside a list keeps the secrets the file left out, since a list is written whole.
    public static JsonNode? KeepSecrets(JsonNode? next, JsonNode? current) => Keep(next, current, false).Value;

    private readonly record struct Kept(bool Has, JsonNode? Value);

    private static string? Str(JsonNode? n) => n is JsonValue v && v.GetValueKind() == JsonValueKind.String ? v.GetValue<string>() : null;

    private static Kept Keep(JsonNode? next, JsonNode? current, bool inList)
    {
        switch (next)
        {
            case JsonValue v when Str(v) is { } text && (IsPlaceholder(v) || text.Contains(Placeholder, StringComparison.Ordinal)):
                // The saved value stays (a string with left-out parts can't be stitched back safely: keep the whole saved one).
                return Str(current) != null ? new Kept(true, current!.DeepClone()) : new Kept(false, null);
            case JsonArray items:
                var currentItems = current as JsonArray ?? [];
                var names = currentItems.Select(i => Str((i as JsonObject)?["name"])).ToList();
                var pairByName = currentItems.Count > 0 && names.All(n => n != null) && names.Distinct(StringComparer.Ordinal).Count() == names.Count;
                var output = new JsonArray();
                for (var index = 0; index < items.Count; index++)
                {
                    var item = items[index];
                    JsonNode? counterpart = null;
                    if (pairByName)
                    {
                        if (Str((item as JsonObject)?["name"]) is { } name)
                            counterpart = currentItems.FirstOrDefault(c => Str((c as JsonObject)?["name"]) == name);
                    }
                    else if (index < currentItems.Count) counterpart = currentItems[index];
                    var kept = Keep(item, counterpart, true);
                    if (kept.Has) output.Add(kept.Value?.DeepClone());
                }
                return new Kept(true, output);
            case JsonObject obj:
                var baseline = current as JsonObject;
                var result = new JsonObject();
                foreach (var (key, value) in obj)
                {
                    var kept = Keep(value, baseline?[key], inList);
                    if (kept.Has) result[key] = kept.Value?.DeepClone();
                }
                if (inList && baseline != null)
                {
                    // A list is written whole: a credential the file left out entirely comes back from the saved item.
                    foreach (var (key, value) in baseline)
                    {
                        if (result.ContainsKey(key)) continue;
                        var redacted = (Redact(new JsonObject { [key] = value?.DeepClone() }) as JsonObject)?[key];
                        if (!JsonNode.DeepEquals(redacted, value)) result[key] = value?.DeepClone();
                    }
                }
                return new Kept(true, result);
            default:
                return new Kept(true, next?.DeepClone());
        }
    }

    /// Only what the file changes is written (`PUT /api/config` deep-merges).
    public static JsonObject ImportPatch(JsonNode? file, JsonNode? current) =>
        ConfigPath.Diff(current, KeepSecrets(file, current) ?? new JsonObject());
}

/// What Settings › Import says before and after it writes a settings file (HermesKit/Settings/SettingsImportWords.swift).
public static class SettingsImportWords
{
    public const string ConfirmTitle = "Import Settings?";
    public const string ConfirmAction = "Import";
    public const string DoneTitle = "Settings Imported";
    public const string Unchanged = "The file matches your settings; nothing changed.";

    /// How many settings a patch from `ConfigPath.Diff` changes: each leaf (a value that isn't an object) is one.
    public static int ChangeCount(JsonNode? patch) => patch is JsonObject o ? o.Sum(p => ChangeCount(p.Value)) : 1;

    /// "3 settings", "1 setting".
    public static string Settings(int count) => count == 1 ? "1 setting" : $"{count} settings";

    public static string ConfirmMessage(int changes) =>
        $"{Settings(changes)} on your gateway will change to the file’s values. Keys, tokens and passwords already there stay.";

    /// The footer line (and the HUD's detail) after the write.
    public static string Done(int changes) => changes == 0 ? Unchanged : $"Settings imported. {Settings(changes)} changed.";
}

/// The words of Settings' file buttons and their alerts (App/Settings/SettingsRootView.swift, SettingsNavigator.swift).
public static class SettingsFileWords
{
    public const string Export = "Export Settings…";
    public const string Import = "Import Settings…";
    public const string Reset = "Reset to Defaults…";
    /// [WIN-06a] Between Import and Reset, as on the Mac (SettingsRootView.swift `settings.clear-models`).
    public const string ClearModels = "Clear Model Favorites…";
    public const string Footer = "Exported files leave out keys, tokens and passwords.";

    public const string ExportFailedTitle = "Couldn’t Export Settings";
    public const string ImportFailedTitle = "Couldn’t Import Settings";
    public const string ResetFailedTitle = "Couldn’t Reset Settings";
    public const string NotASettingsFile = "That file isn’t a Hermes settings file.";

    public const string ToolsetsTitle = "Remove All Tool Groups?";
    public const string ToolsetsMessage = "This file turns off memory, terminal, web search, subagents and most other tools.";
    public const string ToolsetsAction = "Import Anyway";

    public const string ResetTitle = "Reset All Settings to Defaults?";
    public static string ResetMessage =>
        $"Every setting on {HostWord.Phrase} goes back to its Hermes default. Keys, bots and chats stay. Export Settings… first to keep a copy.";
    public const string ResetAction = "Reset to Defaults";
    public const string Resetting = "Resetting…";
    public const string ResetDone = "Settings reset to Hermes defaults.";

    public const string ClearModelsTitle = "Clear Favorite & Recent Models?";
    public const string ClearModelsAction = "Clear";
    public const string ClearModelsDone = "Favorite and recent models cleared.";
}

/// A file the person picked: its bytes, or null when it couldn't be read.
public sealed record PickedSettingsFile(byte[]? Data);

/// What the file actions need from the screen: the Mac's alerts, share sheet and document picker. The app fills it with
/// ContentDialogs, FileSavePicker and FileOpenPicker; tests with a stand-in.
public interface ISettingsFileUi
{
    /// A destructive confirmation (`TextPrompt.confirm`): true when the action was chosen, false for Cancel.
    Task<bool> ConfirmAsync(string title, string? message, string action);
    /// Offers the exported file under this name; false when the person cancelled.
    Task<bool> SaveAsync(string fileName, byte[] data);
    /// One .json file, or null when the person cancelled.
    Task<PickedSettingsFile?> PickAsync();
    /// `FailureAlert.present(title:reason:)`.
    void Fail(string title, string reason);
    /// `PagesHUD.show(title, detail:)` after an import that changed something.
    void Done(string title, string detail);
}

/// Export / Import / Reset, run from Settings (App/Settings/SettingsNavigator.swift `SettingsFileActions`).
public sealed class SettingsFileActions(GatewayConfigStore store, ISettingsFileUi ui)
{
    /// Whose settings the exported file's name says (the Mac's is "Hermes").
    public string ProfileName { get; init; } = "Hermes";
    /// The clock for the file's day (tests pin it).
    public Func<DateTime> Now { get; init; } = () => DateTime.Now;
    /// Where the actions note what happened (the app sends it to AppLog under "settings"). Never a value.
    public static Action<string>? Log { get; set; }

    /// How an action went (the section's footer shows it); null clears it.
    public event Action<string?>? StatusChanged;
    /// While the reset's two gateway calls run, its button can't be pressed again.
    public event Action<bool>? ResettingChanged;

    private int _resetting;
    public bool Resetting => Volatile.Read(ref _resetting) == 1;

    private void Status(string? text) => StatusChanged?.Invoke(text);

    /// A Settings search result for a file action (SettingsNavigator.open `.action(id)`): "export" → Export Settings…,
    /// "import" → Import Settings…, "clear-models" → Clear Model Favorites…, any other id → Reset to Defaults… (the Mac's
    /// `default:`, SettingsNavigator.swift:36-40). False, and nothing run, when
    /// the target is a page or a row.
    public async Task<bool> OpenAsync(string target)
    {
        switch (SettingsSearch.ActionId(target))
        {
            case null: return false;
            case "export": await ExportAsync(); break;
            case "import": await PickImportAsync(); break;
            case "clear-models": await ConfirmClearModelsAsync(); break;
            default: await ConfirmResetAsync(); break;
        }
        return true;
    }

    /// Export Settings…: the record read fresh, credentials left out, offered as "<Profile> settings <day>.json".
    public async Task ExportAsync()
    {
        Status(null);
        byte[] data;
        try
        {
            data = SettingsFile.FileData(await store.FreshAsync());
        }
        catch (Exception x) when (IsGatewayFailure(x))
        {
            Log?.Invoke($"export failed: {x.GetType().Name}");
            ui.Fail(SettingsFileWords.ExportFailedTitle, SettingsErrorText.Load(x));
            return;
        }
        if (await ui.SaveAsync(SettingsFile.ExportFileName(ProfileName, Now()), data)) Log?.Invoke("settings exported");
    }

    /// Import Settings…: a picked .json file.
    public async Task PickImportAsync()
    {
        Status(null);
        if (await ui.PickAsync() is not { } picked) return;
        await ImportFileAsync(picked.Data);
    }

    public async Task ImportFileAsync(byte[]? data)
    {
        if (SettingsFile.Parse(data) is not { } file)
        {
            ui.Fail(SettingsFileWords.ImportFailedTitle, SettingsFileWords.NotASettingsFile);
            return;
        }
        JsonNode current;
        try { current = await store.FreshAsync(); }
        catch (Exception x) when (IsGatewayFailure(x))
        {
            Log?.Invoke($"import read failed: {x.GetType().Name}");
            ui.Fail(SettingsFileWords.ImportFailedTitle, SettingsErrorText.Load(x));
            return;
        }
        var next = SettingsFile.KeepSecrets(file, current) ?? new JsonObject();
        var patch = ConfigPath.Diff(current, next);
        var changes = SettingsImportWords.ChangeCount(patch);
        if (ConfigPath.ClearsEnabledToolsets(current, next))
        {
            if (await ui.ConfirmAsync(SettingsFileWords.ToolsetsTitle, SettingsFileWords.ToolsetsMessage, SettingsFileWords.ToolsetsAction))
                await ApplyImportAsync(patch);
        }
        else if (changes == 0)
        {
            Status(SettingsImportWords.Unchanged);
        }
        else if (await ui.ConfirmAsync(SettingsImportWords.ConfirmTitle, SettingsImportWords.ConfirmMessage(changes), SettingsImportWords.ConfirmAction))
        {
            // Says how much changes before anything is written.
            await ApplyImportAsync(patch);
        }
    }

    private async Task ApplyImportAsync(JsonObject patch)
    {
        try
        {
            await store.WriteAsync(patch);
        }
        catch (Exception x) when (IsGatewayFailure(x))
        {
            Log?.Invoke($"import apply failed: {x.GetType().Name}");
            ui.Fail(SettingsFileWords.ImportFailedTitle, SettingsErrorText.Save(x));
            return;
        }
        Log?.Invoke("settings imported");
        var changes = SettingsImportWords.ChangeCount(patch);
        Status(SettingsImportWords.Done(changes));
        // The footer line alone was easy to miss: a HUD says it too.
        if (changes > 0) ui.Done(SettingsImportWords.DoneTitle, $"{SettingsImportWords.Settings(changes)} changed.");
    }

    /// Reset to Defaults…: asks first, then Hermes' defaults (`GET /api/config/defaults`) written over the record.
    public async Task ConfirmResetAsync()
    {
        if (Resetting) return;
        Status(null);
        if (!await ui.ConfirmAsync(SettingsFileWords.ResetTitle, SettingsFileWords.ResetMessage, SettingsFileWords.ResetAction)) return;
        await ResetAsync();
    }

    private async Task ResetAsync()
    {
        if (Interlocked.CompareExchange(ref _resetting, 1, 0) != 0) return;
        ResettingChanged?.Invoke(true);
        Status(SettingsFileWords.Resetting);
        try
        {
            var defaults = await store.DefaultsAsync();
            await store.WriteAsync(defaults as JsonObject ?? new JsonObject());
            Log?.Invoke("settings reset");
            Status(SettingsFileWords.ResetDone);
        }
        catch (Exception x) when (IsGatewayFailure(x))
        {
            Log?.Invoke($"settings reset failed: {x.GetType().Name}");
            Status(null);
            ui.Fail(SettingsFileWords.ResetFailedTitle, SettingsErrorText.Save(x));
        }
        finally
        {
            Volatile.Write(ref _resetting, 0);
            ResettingChanged?.Invoke(false);
        }
    }

    /// This account's model stars and recents on this PC (the Mac's `ModelPrefs(accountId:)`); null when no account.
    public Hermes.Core.Composer.ModelPrefs? Models { get; init; }

    /// [WIN-06a] Clear Model Favorites… (SettingsNavigator.swift `confirmClearModels`). Models from a removed
    /// provider can no longer be unstarred individually. Asks with this account's
    /// counts, then clears its stars and recents, which live on this PC, not on the gateway: no gateway call.
    public async Task ConfirmClearModelsAsync()
    {
        if (Models is not { } prefs) return;
        Status(null);
        var words = SettingsWords.ClearModelsMessage(prefs.Favorites.Count, prefs.Recents.Count);
        if (!await ui.ConfirmAsync(SettingsFileWords.ClearModelsTitle, words, SettingsFileWords.ClearModelsAction)) return;
        prefs.ClearFavoritesAndRecents();
        Log?.Invoke("model favourites and recents cleared");
        Status(SettingsFileWords.ClearModelsDone);
    }

    private static bool IsGatewayFailure(Exception x) =>
        x is Net.GatewayException or HttpRequestException or OperationCanceledException or SettingsSaveRefused or SettingsReadOnly or JsonException;
}
