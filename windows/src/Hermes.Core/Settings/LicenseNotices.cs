using System.Reflection;
using System.Text.Json.Nodes;
using Hermes.Core.Gateways;

namespace Hermes.Core.Settings;

/// One notice on Settings › About › Open-Source Licenses (HermesKit/Settings/LicenseNotices.swift `LicenseNotice`).
public sealed record LicenseNotice(string Name, string Version, string License, string Text)
{
    /// "0.45.0 · BSD-2-Clause"; no leading dot when there is no version.
    public string Meta => string.Join(" · ", new[] { Version, License }.Where(s => s.Length > 0));
}

/// The notices of what ships inside the Windows app: `licenses.json` beside this file, embedded in Hermes.Core. The
/// Mac's page structure and words; the Windows app's own third-party packages (HermesHQ.Windows.csproj's
/// PackageReferences that reach the installed app, plus the self-contained .NET runtime). Hermes first, then by name.
/// Windows-only entries: Markdig (formatted replies), .NET Runtime, Windows App SDK (WinUI 3). The Mac's Swift, font,
/// React and Tailwind entries are not listed because the Windows app does not ship them. Microsoft.Windows.SDK.BuildTools
/// is build-time only and ships nothing.
public static class LicenseNotices
{
    public static string Intro =>
        $"This app is built on Hermes Agent by Nous Research and the open-source software below. {DeviceWord.TapCap} one to read its license.";
    public const string Failure = "The licenses couldn’t load.";
    public const string First = "Hermes Agent (Nous Research)";
    public const string PageTitle = "Open-Source Licenses";

    /// Decodes leniently: an entry without a name or text is skipped (as is a repeated name); Hermes is put first, the
    /// rest by name. Null when nothing usable is there.
    public static IReadOnlyList<LicenseNotice>? Decode(string json)
    {
        JsonArray? items;
        try { items = JsonNode.Parse(json) as JsonArray; }
        catch (System.Text.Json.JsonException) { return null; }
        if (items == null) return null;
        var seen = new HashSet<string>();
        var notices = new List<LicenseNotice>();
        foreach (var item in items)
        {
            if (item is not JsonObject o) continue;
            var name = Str(o, "name");
            var text = Str(o, "text");
            if (string.IsNullOrEmpty(name) || string.IsNullOrWhiteSpace(text) || !seen.Add(name)) continue;
            notices.Add(new LicenseNotice(name, Str(o, "version") ?? "", Str(o, "license") ?? "", text));
        }
        if (notices.Count == 0) return null;
        return [.. notices.OrderBy(n => n.Name == First ? 0 : 1).ThenBy(n => n.Name, StringComparer.OrdinalIgnoreCase)];
    }

    private static string? Str(JsonObject o, string key) =>
        o[key] is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;

    /// The app's own notices (read off the UI thread when the page opens).
    public static IReadOnlyList<LicenseNotice>? Load()
    {
        using var stream = typeof(LicenseNotices).Assembly.GetManifestResourceStream("Hermes.Core.Settings.licenses.json");
        if (stream == null) return null;
        using var reader = new StreamReader(stream);
        return Decode(reader.ReadToEnd());
    }

    /// The licence files are hard-wrapped at 80 columns; each paragraph is joined back into one line (blank lines still
    /// separate paragraphs) and the window wraps it.
    public static string Reflow(string text)
    {
        var paragraphs = new List<string>();
        var current = new List<string>();
        foreach (var line in text.Replace("\r\n", "\n").Split('\n'))
        {
            var trimmed = line.Trim(' ', '\t');
            if (trimmed.Length == 0)
            {
                if (current.Count > 0) { paragraphs.Add(string.Join(' ', current)); current.Clear(); }
            }
            else current.Add(trimmed);
        }
        if (current.Count > 0) paragraphs.Add(string.Join(' ', current));
        return string.Join("\n\n", paragraphs);
    }
}
