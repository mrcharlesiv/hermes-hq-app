using System.Net;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Auth;
using Hermes.Core.Net;
using Hermes.Core.Settings;

namespace Hermes.Core.Tests;

/// Settings › About › Open-Source Licenses (HermesKit/Settings/LicenseNotices.swift) and Detailed Logging
/// (HermesKit/Diagnostics/DiagnosticLog.swift, HermesKit/Net/HTTPTransport.swift), with synthetic fixtures only.
[Collection("DetailedLogging")]
public class AboutLoggingTests : IDisposable
{
    public AboutLoggingTests() => DetailedLogging.Reset();
    public void Dispose() => DetailedLogging.Reset();

    // ---------------------------------------------------------------- licenses

    [Fact]
    public void LicensesIntroAndFailureAreTheMacsWordsForAPc()
    {
        Assert.Equal("This app is built on Hermes Agent by Nous Research and the open-source software below. Click one to read its license.", LicenseNotices.Intro);
        Assert.Equal("The licenses couldn’t load.", LicenseNotices.Failure);
        Assert.Equal("Open-Source Licenses", LicenseNotices.PageTitle);
    }

    [Fact]
    public void DecodeSkipsBadEntriesPutsHermesFirstThenByName()
    {
        const string json = """
            [{"name":"zeta","version":"1.0","license":"MIT","text":"Z"},
             {"name":"","text":"no name"},
             {"name":"blank","text":"   "},
             {"name":"Alpha","license":"ISC","text":"A"},
             {"name":"zeta","version":"2.0","text":"repeat"},
             {"name":"Hermes Agent (Nous Research)","license":"MIT","text":"H"}]
            """;
        var notices = LicenseNotices.Decode(json)!;
        Assert.Equal(["Hermes Agent (Nous Research)", "Alpha", "zeta"], notices.Select(n => n.Name));
        Assert.Equal("1.0 · MIT", notices[2].Meta);
        Assert.Equal("ISC", notices[1].Meta);   // no leading dot without a version
        Assert.Null(LicenseNotices.Decode("[]"));
        Assert.Null(LicenseNotices.Decode("not json"));
        Assert.Null(LicenseNotices.Decode("{\"name\":\"x\"}"));
    }

    [Fact]
    public void ReflowJoinsHardWrappedParagraphs()
    {
        Assert.Equal("Permission is hereby granted, free of charge.\n\nTHE SOFTWARE IS PROVIDED.",
            LicenseNotices.Reflow("  Permission is hereby granted,\r\n free of charge.\n\n\n THE SOFTWARE\nIS PROVIDED.\n"));
    }

    [Fact]
    public void TheAppShipsANoticeForEveryShippedPackage()
    {
        var notices = LicenseNotices.Load();
        Assert.NotNull(notices);
        Assert.Equal(LicenseNotices.First, notices![0].Name);
        Assert.Contains("Nous Research", notices[0].Text);
        Assert.All(notices, n => Assert.False(string.IsNullOrWhiteSpace(n.Text)));
        Assert.Equal(["Hermes Agent (Nous Research)", ".NET Runtime", "AMS Blackboard Bold (font)", "CSharpMath (formulas)",
                      "Cyrillic Modern (font)", "Latin Modern Math (font)", "Markdig (formatted replies)", "SkiaSharp (formula drawing)",
                      "Typography (OpenType reader)", "Windows App SDK (WinUI 3)"],
            notices.Select(n => n.Name));

        // Every package the installed app carries (not the build-time SDK tools) has a notice at the version it ships.
        var csproj = File.ReadAllText(Path.Combine(RepoRoot(), "windows", "src", "HermesHQ.Windows", "HermesHQ.Windows.csproj"));
        var shipped = new Dictionary<string, string>
        {
            ["Markdig"] = "Markdig (formatted replies)",
            ["Microsoft.WindowsAppSDK"] = "Windows App SDK (WinUI 3)",
        };
        var buildOnly = new[] { "Microsoft.Windows.SDK.BuildTools" };
        foreach (Match m in Regex.Matches(csproj, "<PackageReference Include=\"([^\"]+)\" Version=\"([^\"]+)\""))
        {
            var (id, version) = (m.Groups[1].Value, m.Groups[2].Value);
            if (buildOnly.Contains(id)) continue;
            Assert.True(shipped.TryGetValue(id, out var name), $"{id} ships without a notice on About › Open-Source Licenses");
            Assert.Equal(version, notices.Single(n => n.Name == name).Version);
        }
        Assert.Contains("<SelfContained>true</SelfContained>", csproj);   // hence the .NET runtime's notice

        // [WIN-MATH-UI] The app carries Hermes.Math, and with it every package that project pins (the formulas'
        // typesetter, its drawing) and the fonts CSharpMath.Rendering embeds.
        Assert.Contains(@"<ProjectReference Include=""..\Hermes.Math\Hermes.Math.csproj"" />", csproj);
        var math = File.ReadAllText(Path.Combine(RepoRoot(), "windows", "src", "Hermes.Math", "Hermes.Math.csproj"));
        var mathShipped = new Dictionary<string, string>
        {
            ["CSharpMath.SkiaSharp"] = "CSharpMath (formulas)",
            ["SkiaSharp"] = "SkiaSharp (formula drawing)",
        };
        foreach (Match m in Regex.Matches(math, "<PackageReference Include=\"([^\"]+)\" Version=\"([^\"]+)\""))
        {
            var (id, version) = (m.Groups[1].Value, m.Groups[2].Value);
            Assert.True(mathShipped.TryGetValue(id, out var name), $"{id} ships without a notice on About › Open-Source Licenses");
            Assert.Equal(version, notices.Single(n => n.Name == name).Version);
        }
        Assert.Contains("GUST Font License", notices.Single(n => n.Name == "Latin Modern Math (font)").Text);
        Assert.Contains("Reserved Font Name MSBM9", notices.Single(n => n.Name == "AMS Blackboard Bold (font)").Text);
        Assert.Contains("Andrey V. Panov", notices.Single(n => n.Name == "Cyrillic Modern (font)").Text);
        foreach (var font in new[] { "AMS Blackboard Bold (font)", "Cyrillic Modern (font)" })
            Assert.Contains("SIL OPEN FONT LICENSE Version 1.1", notices.Single(n => n.Name == font).Text);
        // CSharpMath.Rendering.dll compiles in LayoutFarm's Typography (OpenFont, TextBreak) at the submodule commit
        // CSharpMath v0.5.1 pins; its own notice plus the full texts its file headers name.
        var typography = notices.Single(n => n.Name == "Typography (OpenType reader)").Text;
        Assert.Contains("d331968f3ee714332a8ea4fa95a21c15812a8d93", typography);
        Assert.Contains("Samuel Carlsson", typography);
        foreach (var text in new[] { "Version 2.0, January 2004", "The FreeType Project LICENSE", "UNICODE LICENSE V3",
                     "Permission is hereby granted, free of charge" })
            Assert.Contains(text, typography);
    }

    private static string RepoRoot()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir != null; dir = dir.Parent)
            if (File.Exists(Path.Combine(dir.FullName, "windows", "HermesHQ.sln")))
                return dir.FullName;
        throw new InvalidOperationException("repo root not found");
    }

    // ---------------------------------------------------------------- the switch

    [Fact]
    public void DetailedLoggingDefaultsOnPersistsUnderTheMacsKeyAndNotesTheChange()
    {
        var prefs = new MemoryPrefs();
        var lines = new List<string>();
        Assert.True(DetailedLogging.Load(prefs));
        Assert.Equal("logging: detailed on", DetailedLogging.Start(prefs, (a, t) => lines.Add($"[{a}] {t}")));
        Assert.True(DetailedLogging.Enabled);

        DetailedLogging.Set(prefs, false);
        Assert.Equal("false", prefs.Values["hqn.log.detailed"]);
        Assert.False(DetailedLogging.Enabled);
        Assert.Equal(["[settings] detailed logging off"], lines);

        // Next launch: still off (no auto-off or auto-on rule).
        DetailedLogging.Reset();
        Assert.Equal("logging: detailed off", DetailedLogging.Start(prefs, (_, _) => { }));
        Assert.False(DetailedLogging.Enabled);
        DetailedLogging.Set(prefs, true, (a, t) => lines.Add($"[{a}] {t}"));
        Assert.Equal("true", prefs.Values["hqn.log.detailed"]);
        Assert.Equal("[settings] detailed logging on", lines[^1]);
        Assert.Equal("Every request, reply step and send, in this PC’s log, so problems can be traced afterwards.", DetailedLogging.Note);
    }

    [Fact]
    public void TraceIsNotEvenBuiltWhileOff()
    {
        var prefs = new MemoryPrefs();
        var lines = new List<string>();
        DetailedLogging.Start(prefs, (a, t) => lines.Add(t));
        DetailedLogging.Set(prefs, false, (_, _) => { });
        var built = false;
        DetailedLogging.Trace("http", () => { built = true; return "x"; });
        Assert.False(built);
        Assert.Empty(lines);
        DetailedLogging.Set(prefs, true, (_, _) => { });
        DetailedLogging.Trace("http", () => { built = true; return "chat 20251027_101010_ab12cd opened"; });
        Assert.True(built);
        Assert.Equal($"chat {DetailedLogging.Tag("20251027_101010_ab12cd")} opened", Assert.Single(lines));
    }

    // ---------------------------------------------------------------- redaction (the Mac's vectors)

    [Fact]
    public void TagsMatchTheMacsSha256Tags()
    {
        Assert.Equal("#-", DetailedLogging.Tag(null));
        Assert.Equal("#-", DetailedLogging.Tag(""));
        Assert.Matches("^#[0-9a-f]{6}$", DetailedLogging.Tag("abc"));
        Assert.Equal("#ba7816", DetailedLogging.Tag("abc"));   // SHA-256("abc") = ba7816bf…
    }

    [Fact]
    public void PathsDropQueriesAndTagIdsHostsAndIdWords()
    {
        var url = new Uri("https://my-pc.tail1234.ts.net:8443/api/sessions/20251027_101010_ab12cd/messages?q=secret");
        Assert.Equal($"/api/sessions/{DetailedLogging.Tag("20251027_101010_ab12cd")}/messages?…", DetailedLogging.Path(url));
        Assert.Equal("/api/status", DetailedLogging.Path(new Uri("https://example.com/api/status")));
        Assert.Equal("/api/plugins/hermes-hq-browser", DetailedLogging.Path(new Uri("https://example.com/api/plugins/hermes-hq-browser")));

        var hosted = DetailedLogging.TagHosts("failed: https://user:pw@my-pc.tail1234.ts.net:8443/api/x");
        Assert.Equal($"failed: https://{DetailedLogging.Tag("my-pc.tail1234.ts.net")}/api/x", hosted);
        Assert.DoesNotContain("tail1234", hosted);
        Assert.DoesNotContain("pw", hosted);
        Assert.Equal("model gpt-4o-2024-08-06, 12 items", DetailedLogging.TagIds("model gpt-4o-2024-08-06, 12 items"));
    }

    // ---------------------------------------------------------------- what it adds to the log

    private sealed class Fixed(HttpStatusCode status, string body) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct) =>
            Task.FromResult(new HttpResponseMessage(status) { Content = new StringContent(body) });
    }

    private sealed class Down : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct) =>
            throw new HttpRequestException("No such host is known. (my-pc.tail1234.ts.net:8443)");
    }

    private static GatewaySession Session(HttpMessageHandler handler) => new(
        GatewayAddress.Validated("https://my-pc.tail1234.ts.net:8443"), new StoredAccount("https://my-pc.tail1234.ts.net:8443", "qa"),
        new MemoryTokenStore(), handler);

    [Fact]
    public async Task EveryRequestIsOneRedactedLineWhileOn()
    {
        var lines = new List<(string Area, string Text)>();
        DetailedLogging.Start(new MemoryPrefs(), (a, t) => lines.Add((a, t)));
        using var ok = Session(new Fixed(HttpStatusCode.OK, "{\"text\":\"my private message\"}"));
        await ok.SendAsync(HttpMethod.Get, "/api/sessions/20251027_101010_ab12cd/messages", [new("cursor", "abc")]);
        var (area, line) = Assert.Single(lines);
        Assert.Equal("http", area);
        Assert.Matches($@"^GET /api/sessions/{DetailedLogging.Tag("20251027_101010_ab12cd")}/messages\?… → 200, 29 B, \d+ ms$", line);

        lines.Clear();
        using var refused = Session(new Fixed(HttpStatusCode.Forbidden, "{\"error\":\"denied\",\"token\":\"tok-SECRET-789\",\"session\":\"20251027_101010_ab12cd\",\"content\":\"my private message\"}"));
        await refused.SendAsync(HttpMethod.Post, "/api/auth/ws-ticket", body: new JsonObject());
        line = Assert.Single(lines).Text;
        Assert.StartsWith("POST /api/auth/ws-ticket (control) → 403, ", line);
        Assert.Contains("denied", line);

        lines.Clear();
        using var down = Session(new Down());
        await Assert.ThrowsAsync<GatewayException>(() => down.SendAsync(HttpMethod.Get, "/api/status"));
        line = Assert.Single(lines).Text;
        Assert.Matches(@"^GET /api/status → failed after \d+ ms: ", line);

        // Nothing private in any of them: tokens, the gateway's host, message text, raw ids.
        foreach (var l in new[] { line }.Concat(lines.Select(x => x.Text)))
            foreach (var secret in new[] { "SECRET", "tail1234", "my private message", "20251027_101010_ab12cd", "cursor", "abc" })
                Assert.DoesNotContain(secret, l);
    }

    [Fact]
    public async Task RefusalLinesKeepNoTokenOrText()
    {
        var lines = new List<string>();
        DetailedLogging.Start(new MemoryPrefs(), (_, t) => lines.Add(t));
        using var refused = Session(new Fixed(HttpStatusCode.Forbidden, "{\"error\":\"denied\",\"token\":\"tok-SECRET-789\",\"content\":\"my private message\"}"));
        await refused.SendAsync(HttpMethod.Post, "/api/auth/ws-ticket", body: new JsonObject());
        var line = Assert.Single(lines);
        Assert.DoesNotContain("SECRET", line);
        Assert.DoesNotContain("my private message", line);
    }

    [Fact]
    public async Task NothingIsWrittenWhileOff()
    {
        var prefs = new MemoryPrefs();
        var lines = new List<string>();
        DetailedLogging.Start(prefs, (_, t) => lines.Add(t));
        DetailedLogging.Set(prefs, false, (_, _) => { });
        using var ok = Session(new Fixed(HttpStatusCode.OK, "{}"));
        await ok.SendAsync(HttpMethod.Get, "/api/status");
        using var down = Session(new Down());
        await Assert.ThrowsAsync<GatewayException>(() => down.SendAsync(HttpMethod.Get, "/api/status"));
        Assert.Empty(lines);
    }

    // ---------------------------------------------------------------- Settings search

    [Fact]
    public void SearchFindsDetailedLoggingAndLicensesUnderAbout()
    {
        var detailed = Assert.Single(SettingsSearch.Results("verbose", SettingsSearch.Index));
        Assert.Equal(("Detailed Logging", "About", "about:detailed-log"), (detailed.Label, detailed.Context, detailed.Target));
        var licenses = Assert.Single(SettingsSearch.Results("licence", SettingsSearch.Index));
        Assert.Equal(("Open-Source Licenses", "About", "licenses"), (licenses.Label, licenses.Context, licenses.Target));
        Assert.Equal(SettingsCategory.About, SettingsSearch.Category("licenses"));
        Assert.Equal(SettingsCategory.About, SettingsSearch.Category("about:detailed-log"));
    }
}

[CollectionDefinition("DetailedLogging", DisableParallelization = true)]
public class DetailedLoggingCollection;
