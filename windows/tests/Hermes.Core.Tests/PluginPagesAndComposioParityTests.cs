using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Capabilities;
using Hermes.Core.Composio;
using Hermes.Core.Net;
using Hermes.Core.Settings;

namespace Hermes.Core.Tests;

/// Wave 5C parity tests: DashboardPagesApi, PluginPageBridge (strict /api/plugins/<name>/ allowlist, C5 percent-decoded
/// traversal rejection, FastAPI bare 404 -> NeedsRestart, host HTML & theme CSS), and ComposioClient / ComposioGateway /
/// ComposioIdentity / ComposioSignIn (no-redirect HTTPS client, x-api-key, ui_meta["dispatch-composio"] round-trip,
/// composio MCP server config with ${COMPOSIO_API_KEY}).
public class PluginPagesAndComposioParityTests
{
    private const string SamplePluginListJson = """
        [
          {"name": "memory-wiki", "label": "Memory Wiki", "description": "Subject pages and daily logs.", "icon": "BookOpen", "version": "0.4.0",
           "tab": {"path": "/memory-wiki", "position": "after:skills"}, "slots": [], "entry": "dist/index.js", "css": "dist/style.css",
           "has_api": true, "source": "user"},
          {"name": "helper", "label": "Helper", "icon": "Puzzle", "tab": {"path": "/helper", "hidden": true}, "entry": "dist/index.js", "has_api": true},
          {"name": "my-sessions", "label": "Sessions+", "tab": {"path": "/sessions", "override": "/sessions"}, "entry": "dist/index.js"},
          {"name": "plain", "tab": {"path": "plain", "override": null}, "entry": "index.js"},
          {"name": "kanban", "label": "Kanban", "tab": {"path": "/kanban"}, "entry": "dist/index.js", "has_api": true},
          {"name": "no-entry", "label": "No Entry", "tab": {"path": "/x"}},
          {"name": "no-tab", "label": "No Tab", "entry": "dist/index.js"}
        ]
        """;

    private const string SessionJson =
        """{"session_id":"trs_1","mcp":{"type":"http","url":"https://backend.composio.dev/tool_router/v3/trs_1/mcp"},"config":{"user_id":"dispatch-aabbcc","multi_account":{"enable":true}}}""";

    // =========================================================================
    // 1. DashboardPages & PluginDashboardPage
    // =========================================================================

    [Fact]
    public void DashboardPagesReadExcludesKanbanHiddenAndOverrides()
    {
        var pages = PluginDashboardPage.Read(SamplePluginListJson);
        Assert.Equal(["memory-wiki", "plain"], pages.Select(p => p.Name));

        var wiki = pages[0];
        Assert.Equal("Memory Wiki", wiki.Label);
        Assert.Equal("/memory-wiki", wiki.TabPath);
        Assert.Equal("dist/style.css", wiki.Css);
        Assert.True(wiki.HasApi);
        Assert.Equal("book", wiki.Symbol);

        var plain = pages[1];
        Assert.Equal("Plain", plain.Label);
        Assert.Equal("/plain", plain.TabPath);
        Assert.Null(plain.Css);
        Assert.Equal("square.grid.2x2", plain.Symbol);

        Assert.Empty(PluginDashboardPage.Read("""{"detail":"x"}"""));
        Assert.Equal("book.closed", PluginDashboardPage.SymbolForLucide("NotebookPen"));
        Assert.Equal("chart.bar", PluginDashboardPage.SymbolForLucide("bar-chart-3"));
        Assert.Equal("square.grid.2x2", PluginDashboardPage.SymbolForLucide("SomethingNew"));
    }

    [Fact]
    public void DashboardPagesAssetPathsScopeNonDefaultProfilesAndStripDots()
    {
        Assert.Equal("/dashboard-plugins/memory-wiki/dist/index.js",
            PluginDashboardPage.AssetPath("memory-wiki", "dist/index.js", "default"));
        Assert.Equal("/dashboard-plugins/memory-wiki/dist/index.js",
            PluginDashboardPage.AssetPath("memory-wiki", "dist/index.js", ""));
        Assert.Equal("/dashboard-plugins/@ivy/memory-wiki/dist/index.js",
            PluginDashboardPage.AssetPath("memory-wiki", "./dist/../index.js", "ivy"));
    }

    [Fact]
    public async Task DashboardPagesApiRescansOnceWhenInstalledPluginIsMissing()
    {
        var scanned = false;
        var seen = new List<string>();
        var wiki = """[{"name":"memory-wiki","label":"Memory Wiki","tab":{"path":"/memory-wiki"},"entry":"dist/index.js"}]""";

        using var handler = new StubHttpHandler(req =>
        {
            var pathAndQuery = req.RequestUri!.PathAndQuery;
            seen.Add($"{req.Method} {pathAndQuery}");
            if (req.RequestUri.AbsolutePath == "/api/dashboard/plugins/rescan")
            {
                scanned = true;
                return (200, """{"ok":true}""");
            }
            return (200, scanned ? wiki : "[]");
        });
        using var session = MakeGatewaySession(handler);
        var api = new DashboardPagesApi(session);

        var rescanned = new HashSet<string>(StringComparer.Ordinal);
        var first = await api.PagesAsync("ivy", new HashSet<string> { "memory-wiki", "kanban" }, rescanned);
        Assert.Equal(["memory-wiki"], first.Select(p => p.Name));
        Assert.Equal([
            "GET /api/dashboard/plugins?profile=ivy",
            "GET /api/dashboard/plugins/rescan?profile=ivy",
            "GET /api/dashboard/plugins?profile=ivy",
        ], seen);
        Assert.Equal(["kanban", "memory-wiki"], rescanned.OrderBy(s => s));

        // Second read must NOT trigger another rescan for already-seen plugins.
        _ = await api.PagesAsync("ivy", new HashSet<string> { "memory-wiki", "kanban" }, rescanned);
        Assert.Equal(4, seen.Count);

        // Default bot omits ?profile= and skips rescan when all installed plugins are listed.
        seen.Clear();
        var none = new HashSet<string>(StringComparer.Ordinal);
        _ = await api.PagesAsync("default", new HashSet<string> { "memory-wiki" }, none);
        Assert.Equal(["GET /api/dashboard/plugins"], seen);
    }

    [Fact]
    public async Task DashboardPagesMergeAndBoundedConcurrency()
    {
        var pages = PluginDashboardPage.Read(SamplePluginListJson);
        var wiki = pages[0];
        var plain = pages[1];

        var merged = DashboardPagesMerge.Merge(
            new Dictionary<string, IReadOnlyList<PluginDashboardPage>>
            {
                ["finance"] = [wiki],
                ["default"] = [wiki, plain],
                ["travel"] = [plain],
            },
            ["default", "finance", "travel", "gone"]);

        Assert.Equal(["memory-wiki", "plain"], merged.Select(m => m.Page.Name));
        Assert.Equal(["default", "finance"], merged[0].Profiles);
        Assert.Equal(["default", "travel"], merged[1].Profiles);
        Assert.Empty(DashboardPagesMerge.Merge(new Dictionary<string, IReadOnlyList<PluginDashboardPage>> { ["finance"] = [wiki] }, ["default"]));

        var active = 0;
        var peak = 0;
        var gate = new object();
        var read = await DashboardPagesMerge.ReadPagesAsync(
            ["default", "otto", "herald", "ivy", "wren"],
            async p =>
            {
                lock (gate) { active++; if (active > peak) peak = active; }
                await Task.Delay(15);
                lock (gate) { active--; }
                return p == "herald" ? null : [wiki];
            });

        Assert.Equal(["default", "ivy", "otto", "wren"], read.Keys.OrderBy(k => k));
        Assert.True(peak <= DashboardPagesMerge.ReadWidth);
    }

    // =========================================================================
    // 2. PluginPageBridge Security (Allowlist, C5 Traversal, 404 NeedsRestart, HTML)
    // =========================================================================

    [Fact]
    public void BridgeAllowsOnlyPluginsOwnRoutesAndRejectsTraversalAndSchemes()
    {
        static string? Allow(string raw, string profile = "default") =>
            PluginPageBridge.AllowedPath(raw, "memory-wiki", profile);

        Assert.Equal("/api/plugins/memory-wiki/overview", Allow("/api/plugins/memory-wiki/overview"));
        Assert.Equal("/api/plugins/memory-wiki", Allow("/api/plugins/memory-wiki"));
        Assert.Equal("/api/plugins/memory-wiki/subjects?q=lisbon", Allow("/api/plugins/memory-wiki/subjects?q=lisbon"));
        Assert.Equal("/api/plugins/memory-wiki/overview?profile=ivy", Allow("/api/plugins/memory-wiki/overview", "ivy"));
        Assert.Equal("/api/plugins/memory-wiki/x?a=1&profile=ivy", Allow("/api/plugins/memory-wiki/x?a=1", "ivy"));
        Assert.Equal("/api/plugins/memory-wiki/x?profile=research", Allow("/api/plugins/memory-wiki/x?profile=research", "ivy"));
        Assert.Equal("/api/plugins/memory-wiki/subject/caf%C3%A9", Allow("/api/plugins/memory-wiki/subject/caf%C3%A9"));

        string[] rejected =
        [
            "/api/plugins/memory-wikix/overview",
            "/api/plugins/kanban/board",
            "/api/env",
            "/api/plugins/memory-wiki/../../env",
            "/api/plugins/memory-wiki/%2e%2e/%2e%2e/env",
            "/api/plugins/memory-wiki/%2E%2E/env",
            "/api/plugins/memory-wiki/%2e%2e%2fenv",
            "/api/plugins/memory-wiki/./x",
            "/api/plugins/memory-wiki/%2e/x",
            "//evil.example/api/plugins/memory-wiki",
            "https://evil.example/api/plugins/memory-wiki/x",
            "javascript:alert(1)",
            "api/plugins/memory-wiki/x",
            "/api/plugins/memory-wiki/x\n",
            "/api/plugins/memory-wiki\\..\\env",
            "/api/plugins/memory-wiki/%5csecret",
            "/api/plugins/memory-wiki/file%00.json",
        ];
        foreach (var bad in rejected)
            Assert.Null(Allow(bad));

        Assert.Contains("POST", PluginPageBridge.Methods);
        Assert.DoesNotContain("CONNECT", PluginPageBridge.Methods);
    }

    [Fact]
    public void AllowedAssetPathEnforcesC5PercentDecodedTraversalGuard()
    {
        Assert.Equal("/dashboard-plugins/memory-wiki/assets/icon.png",
            PluginPageBridge.AllowedAssetPath("/dashboard-plugins/memory-wiki/assets/icon.png", "memory-wiki", "default"));
        Assert.Equal("/dashboard-plugins/memory-wiki/assets/icon.png?v=2",
            PluginPageBridge.AllowedAssetPath("/dashboard-plugins/memory-wiki/assets/icon.png", "memory-wiki", "default", "?v=2"));
        Assert.Equal("/dashboard-plugins/@ivy/memory-wiki/assets/caf%C3%A9.png",
            PluginPageBridge.AllowedAssetPath("/dashboard-plugins/@ivy/memory-wiki/assets/caf%C3%A9.png", "memory-wiki", "ivy"));

        string[] badPaths =
        [
            "/dashboard-plugins/memory-wiki/%2e%2e/other/secret.js",
            "/dashboard-plugins/memory-wiki/%2E%2E/other/secret.js",
            "/dashboard-plugins/memory-wiki/%2e%2e%2fother/secret.js",
            "/dashboard-plugins/memory-wiki/../other/secret.js",
            "/dashboard-plugins/memory-wiki/assets/..",
            "/dashboard-plugins/memory-wiki/assets/%2e%2e",
            "/dashboard-plugins/memory-wiki/./icon.png",
            "/dashboard-plugins/memory-wiki/%2e/icon.png",
            "/dashboard-plugins/memory-wiki/assets/%5csecret.js",
            "/dashboard-plugins/memory-wiki/assets/icon%00.png",
            "/dashboard-plugins/memory-wikix/icon.png",
            "//example.com/dashboard-plugins/memory-wiki/icon.png",
            "https://evil.example/dashboard-plugins/memory-wiki/icon.png",
            "file:///etc/passwd",
        ];
        foreach (var path in badPaths)
            Assert.Null(PluginPageBridge.AllowedAssetPath(path, "memory-wiki", "default"));
    }

    [Fact]
    public void RouteMissingDistinguishesBareFastApi404FromPlugin404()
    {
        Assert.True(PluginPageBridge.RouteMissing(404, """{"detail":"Not Found"}"""));
        Assert.True(PluginPageBridge.RouteMissing(404, ""));
        Assert.True(PluginPageBridge.RouteMissing(404, null));
        Assert.False(PluginPageBridge.RouteMissing(404, """{"detail":"Subject not found"}"""));
        Assert.False(PluginPageBridge.RouteMissing(404, "<html>nope</html>"));
        Assert.False(PluginPageBridge.RouteMissing(500, """{"detail":"Not Found"}"""));
    }

    [Fact]
    public void BuildHostHtmlInjectsThemeVariablesAssetsAndEscapesScriptBreakouts()
    {
        var page = new PluginDashboardPage(
            Name: "memory-wiki",
            Label: "Memory </script> Wiki",
            Description: "Notes",
            Icon: "BookOpen",
            TabPath: "/memory-wiki",
            Entry: "dist/index.js",
            Css: "dist/style.css",
            HasApi: true,
            Source: "user",
            Version: "1.0.0");

        var themeSet = ThemeResolver.Resolve(ThemeState.Default);
        var themeCss = PluginPageBridge.BuildThemeCss(themeSet.Tokens(dark: true), ThemeState.Default, dark: true);
        Assert.Contains("--hq-bg:", themeCss);
        Assert.Contains("--hq-tint:", themeCss);
        Assert.Contains("color-scheme:dark;", themeCss);

        var html = PluginPageBridge.BuildHostHtml(page, "ivy", themeCss, ".hq-card{color:var(--hq-label);}");
        Assert.Contains("id=\"hq-vars\"", html);
        Assert.Contains("/__hq/tailwind.js", html);
        Assert.Contains("/__hq/plugin-host.js", html);
        Assert.Contains("/dashboard-plugins/@ivy/memory-wiki/dist/index.js", html);
        Assert.Contains("/dashboard-plugins/@ivy/memory-wiki/dist/style.css", html);
        Assert.Contains("window.chrome.webview", html);
        Assert.DoesNotContain("Memory </script> Wiki", html);
    }

    // =========================================================================
    // 3. ComposioClient (No-redirect HTTPS, x-api-key, routes, redaction)
    // =========================================================================

    [Fact]
    public void ComposioDefaultHandlerDisablesRedirectsAndCookies()
    {
        using var handler = ComposioClient.CreateDefaultHandler();
        Assert.False(handler.AllowAutoRedirect);
        Assert.False(handler.UseCookies);
    }

    [Fact]
    public async Task ComposioClientSendsApiKeyOnlyAsHeaderToComposioBase()
    {
        var keys = new MemoryComposioKeyStore();
        keys.SaveKey("acct", "ak_mock_dispatch");

        var seen = new List<(string Method, Uri Url, string? ApiKey, string? Auth, string? Cookie, JsonNode? Body)>();
        using var handler = new StubHttpHandler(req =>
        {
            var bodyStr = req.Content?.ReadAsStringAsync().GetAwaiter().GetResult();
            var bodyJson = !string.IsNullOrEmpty(bodyStr) ? J.Parse(bodyStr) : null;
            req.Headers.TryGetValues("x-api-key", out var apiKeys);
            seen.Add((
                req.Method.Method,
                req.RequestUri!,
                apiKeys?.FirstOrDefault(),
                req.Headers.Authorization?.ToString(),
                req.Headers.Contains("Cookie") ? "present" : null,
                bodyJson));

            var path = req.RequestUri!.AbsolutePath;
            if (path.EndsWith("/toolkits", StringComparison.Ordinal))
                return (200, """{"items":[{"slug":"gmail","name":"Gmail","meta":{"logo":"https://logos.composio.dev/api/gmail","description":"Mail"},"connected_account":{"id":"ca_1","status":"active","created_at":"2026-09-29T20:00:00Z"}}],"next_cursor":"30"}""");
            if (path.EndsWith("/link", StringComparison.Ordinal))
                return (201, """{"redirect_url":"https://connect.composio.dev/link/lk_1","connected_account_id":"ca_2"}""");
            if (path == "/api/v3.1/connected_accounts")
                return (200, """{"items":[{"id":"ca_3","status":"ACTIVE","created_at":"2026-10-20T10:00:00Z","alias":"work","word_id":"googledrive_ab12"},{"id":"ca_1","status":"ACTIVE","created_at":"2026-09-29T20:00:00Z"},{"id":"ca_9","status":"INITIATED","created_at":"2026-10-21T10:00:00Z"},{"id":"ca_4","status":"EXPIRED","created_at":"2026-10-22T10:00:00Z"}]}""");
            if (path.Contains("/connected_accounts/", StringComparison.Ordinal))
                return (200, """{"id":"ca_2","status":"INITIATED"}""");
            if (path.EndsWith("/tools", StringComparison.Ordinal))
                return (200, req.RequestUri.Query.Contains("important=true", StringComparison.Ordinal)
                    ? """{"items":[]}"""
                    : """{"items":[{"slug":"GMAIL_SEND","name":"Send email","description":"Send."}]}""");
            return (200, SessionJson);
        });

        using var client = new ComposioClient(keys, "acct", handler, ComposioClient.ProductionBase);
        var made = await client.CreateSessionAsync("dispatch-aabbcc");
        Assert.Equal("trs_1", made.Id);
        Assert.True(made.MultiAccount);
        _ = await client.ReadSessionAsync("trs_1");

        var page = await client.ToolkitsAsync("trs_1", search: "g mail", slugs: ["gmail", "slack"], cursor: "0", limit: 30, connectedOnly: true);
        Assert.Equal("30", page.Next);
        Assert.True(page.Items[0].Connected);

        var link1 = await client.LinkAsync("trs_1", "gmail");
        Assert.Equal("ca_2", link1.AccountId);

        var link2 = await client.LinkAsync("trs_1", "googledrive", alias: "work");
        Assert.Equal("ca_2", link2.AccountId);

        var accounts = await client.AccountsAsync("dispatch-aabbcc", "googledrive");
        Assert.Equal(["ca_1", "ca_3", "ca_4"], accounts.Select(a => a.Id));
        Assert.Equal(["Account 1", "Work", "Account 3"], accounts.Select((a, i) => a.Title(i + 1)));

        await client.RenameAsync("ca_1", "home");
        Assert.False((await client.AccountAsync("ca_2")).IsActive);
        await client.DisconnectAsync("ca_2");

        var tools = await client.ToolsAsync("gmail");
        Assert.Equal(["GMAIL_SEND"], tools.Select(t => t.Slug));

        Assert.Equal(11, seen.Count);
        foreach (var req in seen)
        {
            Assert.Equal("https", req.Url.Scheme);
            Assert.Equal("backend.composio.dev", req.Url.Host);
            Assert.Equal("ak_mock_dispatch", req.ApiKey);
            Assert.DoesNotContain("ak_mock_dispatch", req.Url.AbsoluteUri);
            Assert.Null(req.Auth);
            Assert.Null(req.Cookie);
        }

        Assert.Equal("POST", seen[0].Method);
        Assert.Equal("/api/v3.1/tool_router/session", seen[0].Url.AbsolutePath);
        Assert.Equal(true, seen[0].Body.Obj("multi_account").Bool("enable"));
        Assert.Equal("/api/v3/tool_router/session/trs_1/link", seen[3].Url.AbsolutePath);
        Assert.Equal("/api/v3.1/tool_router/session/trs_1/link", seen[4].Url.AbsolutePath);
        Assert.Equal("work", seen[4].Body.Str("alias"));
        Assert.Equal("PATCH", seen[6].Method);
        Assert.Equal("/api/v3.1/connected_accounts/ca_1", seen[6].Url.AbsolutePath);
        Assert.Equal("DELETE", seen[8].Method);
    }

    [Fact]
    public async Task ComposioClientSanitizesPathSegmentsRefusesRedirectsAndRedactsErrors()
    {
        var keys = new MemoryComposioKeyStore();
        keys.SaveKey("acct", "ak_mock_dispatch");

        var rawUrls = new List<string>();
        using var handler = new StubHttpHandler(req =>
        {
            rawUrls.Add(req.RequestUri!.OriginalString);
            return (200, SessionJson);
        });
        using var client = new ComposioClient(keys, "acct", handler, ComposioClient.ProductionBase);

        _ = await client.ReadSessionAsync("../../v3/connected_accounts?x=1#frag");
        _ = await client.ReadSessionAsync("..");

        Assert.StartsWith("https://backend.composio.dev/api/v3.1/tool_router/session/", rawUrls[0]);
        Assert.DoesNotContain("/connected_accounts", rawUrls[0]);
        Assert.Equal("https://backend.composio.dev/api/v3.1/tool_router/session/_", rawUrls[1]);

        Assert.Equal(ComposioErrorKind.BadKey, ComposioClient.Error(401, null).Kind);
        Assert.Equal(ComposioErrorKind.NotFound, ComposioClient.Error(404, J.Parse("""{"error":{"message":"Session not found"}}""")).Kind);
        Assert.Equal(ComposioErrorKind.RateLimited, ComposioClient.Error(429, null).Kind);
        Assert.Equal(ComposioErrorKind.Server, ComposioClient.Error(302, null).Kind);
        Assert.Equal(ComposioErrorKind.Server, ComposioClient.Error(503, null).Kind);

        var leaked = ComposioClient.Error(400, J.Parse("""{"error":{"message":"bad key ak_mock_dispatch in body"}}"""), "ak_mock_dispatch");
        Assert.Equal(ComposioErrorKind.Rejected, leaked.Kind);
        Assert.DoesNotContain("ak_mock_dispatch", leaked.Message);

        // ConnectLink URL policy
        Assert.NotNull(ComposioClient.ConnectLinkUrl("https://connect.composio.dev/link/lk_1", ComposioClient.ProductionBase));
        Assert.NotNull(ComposioClient.ConnectLinkUrl("https://composio.dev/x", ComposioClient.ProductionBase));
        Assert.Null(ComposioClient.ConnectLinkUrl("http://connect.composio.dev/link/lk_1", ComposioClient.ProductionBase));
        Assert.Null(ComposioClient.ConnectLinkUrl("https://composio.dev.evil.example/link", ComposioClient.ProductionBase));
        Assert.Null(ComposioClient.ConnectLinkUrl("https://user:pw@connect.composio.dev/link", ComposioClient.ProductionBase));
        Assert.Null(ComposioClient.ConnectLinkUrl("javascript:alert(1)", ComposioClient.ProductionBase));
        Assert.Null(ComposioClient.ConnectLinkUrl("http://127.0.0.1:10012/link/lk_1", ComposioClient.ProductionBase));
        Assert.NotNull(ComposioClient.ConnectLinkUrl("http://127.0.0.1:10012/link/lk_1", new Uri("http://127.0.0.1:10012")));
    }

    // =========================================================================
    // 4. ComposioIdentity, ComposioAlias & ComposioSignIn
    // =========================================================================

    [Fact]
    public async Task ComposioIdentityAndAliasesAndSignInRulesMatchSwiftParity()
    {
        var drive = ComposioWhoAmI.Read(
            J.Parse("""{"successful":true,"data":{"user":{"displayName":"Jordan Lee","emailAddress":"jordan@work.example"}}}"""),
            ComposioWhoAmI.Table["googledrive"]);
        Assert.Equal(new ComposioIdentity("jordan@work.example", "Jordan Lee"), drive);

        var notion = ComposioWhoAmI.Read(
            J.Parse("""{"successful":true,"data":{"response_data":{"type":"bot","name":"Integration","bot":{"owner":{"user":{"name":"Jordan Lee","person":{"email":"jordan.lee@gmail.com"}}}}}}}"""),
            ComposioWhoAmI.Table["notion"]);
        Assert.Equal(new ComposioIdentity("jordan.lee@gmail.com", "Jordan Lee"), notion);

        var gmailFallback = ComposioWhoAmI.Read(
            J.Parse("""{"successful":true,"data":{"profile":{"emailAddress":"jordan.lee@gmail.com"}}}"""),
            ComposioWhoAmI.Table["gmail"]);
        Assert.Equal("jordan.lee@gmail.com", gmailFallback?.Email);

        var githubNoEmail = ComposioWhoAmI.Read(
            J.Parse("""{"successful":true,"data":{"login":"jlee","name":null,"email":null}}"""),
            ComposioWhoAmI.Table["github"]);
        Assert.Equal(new ComposioIdentity("", "jlee"), githubNoEmail);

        Assert.Null(ComposioWhoAmI.Read(J.Parse("""{"successful":false,"data":{"user":{"emailAddress":"a@b.co"}}}"""),
            ComposioWhoAmI.Table["googledrive"]));

        Assert.Equal("work", ComposioAlias.Normalized("Work"));
        Assert.Equal("work-drive", ComposioAlias.Normalized("  Work Drive "));
        Assert.Equal("Work Drive", ComposioAlias.Shown("work-drive"));
        Assert.Null(ComposioAlias.Normalized("—  "));
        Assert.Equal("work", ComposioAlias.Suggestion("a.rivera@work.example"));
        Assert.Equal("acme", ComposioAlias.Suggestion("Jordan@Mail.Acme.co.uk"));
        Assert.Equal("personal", ComposioAlias.Suggestion("jordan.lee@gmail.com"));
        Assert.Equal("jordan-lee", ComposioAlias.Suggestion("jordan.lee+drive@gmail.com", new HashSet<string> { "personal" }));

        var unnamed = new ComposioAccount("ca_1", "ACTIVE", "", "");
        var named = unnamed with { Alias = "work-drive" };
        Assert.Equal("jordan@work.example", unnamed.Title(2, drive));
        Assert.Null(unnamed.EmailLine(drive));
        Assert.Equal("Work Drive", named.Title(2, drive));
        Assert.Equal("jordan@work.example", named.EmailLine(drive));

        // ComposioSignIn rules
        var twitterRow = J.Parse("""{"slug":"twitter","auth_schemes":["OAUTH2"],"composio_managed_auth_schemes":[],"no_auth":false}""");
        var metaAdsRow = J.Parse("""{"slug":"metaads","auth_schemes":["OAUTH2","API_KEY"],"composio_managed_auth_schemes":[],"no_auth":false}""");
        var gdriveRow = J.Parse("""{"slug":"googledrive","auth_schemes":["OAUTH2"],"composio_managed_auth_schemes":["OAUTH2"],"no_auth":false}""");
        Assert.True(ComposioSignIn.NeedsOwnApp(twitterRow));
        Assert.False(ComposioSignIn.NeedsOwnApp(metaAdsRow));
        Assert.False(ComposioSignIn.NeedsOwnApp(gdriveRow));

        var twitterKit = new ComposioToolkit("twitter", "Twitter", "", "", false, null, []);
        Assert.True(ComposioSignIn.Hidden(twitterKit, new HashSet<string> { "twitter" }, new HashSet<string>()));
        Assert.False(ComposioSignIn.Hidden(twitterKit, new HashSet<string> { "twitter" }, new HashSet<string> { "twitter" }));

        var keys = new MemoryComposioKeyStore();
        keys.SaveKey("acct", "ak_mock_dispatch");
        using var handler = new StubHttpHandler(req =>
        {
            if (req.RequestUri!.AbsolutePath == "/api/v3/auth_configs")
                return (200, """{"items":[{"id":"ac_1","status":"ENABLED","toolkit":{"slug":"metaads"}},{"id":"ac_2","status":"DISABLED","toolkit":{"slug":"twitter"}},{"id":"ac_3","status":"ENABLED","toolkit":{"slug":"Shopify"}}]}""");
            return (200, """{"items":[{"slug":"twitter","auth_schemes":["OAUTH2"],"composio_managed_auth_schemes":[],"no_auth":false}],"next_cursor":null}""");
        });
        using var client = new ComposioClient(keys, "acct", handler, ComposioClient.ProductionBase);
        Assert.Equal(["twitter"], (await client.AppsNeedingOwnSignInAsync()).OrderBy(x => x));
        Assert.Equal(["metaads", "shopify"], (await client.AppsWithOwnAuthConfigAsync()).OrderBy(x => x));
    }

    // =========================================================================
    // 5. ComposioGateway (ui_meta["dispatch-composio"] round-trip & MCP config)
    // =========================================================================

    [Fact]
    public async Task ComposioGatewayRoundTripsUiMetaAndConfiguresMcpServerWithEnvReference()
    {
        var transport = new FakeComposioGatewayTransport();
        var gateway = new ComposioGateway(transport);

        Assert.Null(await gateway.RecordAsync());

        var record = new ComposioRecord("dispatch-aabbcc", "trs_1", AllBots: true);
        await gateway.WriteAsync(record);
        var loaded = await gateway.RecordAsync();
        Assert.Equal(record, loaded);

        // TurnOn writes COMPOSIO_API_KEY via SetEnv, registers `composio` with `${COMPOSIO_API_KEY}` header (never literal key), and reloads MCP.
        const string secretKey = "ak_live_super_secret_key_1234";
        const string mcpUrl = "https://backend.composio.dev/tool_router/v3/trs_1/mcp";
        await gateway.TurnOnAsync("ivy", secretKey, mcpUrl);

        Assert.Equal(secretKey, transport.Env[("ivy", "COMPOSIO_API_KEY")]);
        var addedConfig = transport.McpConfigs[("ivy", "composio")];
        Assert.Equal(mcpUrl, addedConfig.Str("url"));
        Assert.Equal("${COMPOSIO_API_KEY}", addedConfig.Obj("headers").Str("x-api-key"));
        Assert.DoesNotContain(secretKey, addedConfig.ToJsonString());
        Assert.Equal(1, transport.ReloadCount);

        var server = await gateway.ServerAsync("ivy");
        Assert.NotNull(server);
        Assert.Equal("composio", server!.Name);
        Assert.Equal(mcpUrl, server.Url);

        // RevealKeyAsync delegates to RevealEnvAsync("COMPOSIO_API_KEY", profile).
        var revealed = await gateway.RevealKeyAsync("ivy");
        Assert.Equal(secretKey, revealed);

        // TurnOff removes server and env key, and reloads MCP.
        await gateway.TurnOffAsync("ivy");
        Assert.Null(await gateway.ServerAsync("ivy"));
        Assert.False(transport.Env.ContainsKey(("ivy", "COMPOSIO_API_KEY")));
        Assert.Equal(2, transport.ReloadCount);

        // Clear ui_meta["dispatch-composio"] with null.
        await gateway.WriteAsync(null);
        Assert.Null(await gateway.RecordAsync());

        // Read-only gateway refuses writes.
        transport.ReadOnly = true;
        await Assert.ThrowsAsync<CapabilityException>(() => gateway.WriteAsync(record));
        await Assert.ThrowsAsync<CapabilityException>(() => gateway.TurnOnAsync("ivy", secretKey, mcpUrl));
    }

    // =========================================================================
    // Test helpers
    // =========================================================================

    private static GatewaySession MakeGatewaySession(HttpMessageHandler handler)
    {
        var address = GatewayAddress.Validated("http://127.0.0.1:9119");
        var account = new StoredAccount(address.ToString(), "tester");
        return new GatewaySession(address, account, new MemoryTokenStore(), handler);
    }

    private sealed class StubHttpHandler(Func<HttpRequestMessage, (int Status, string Body)> respond) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var (status, body) = respond(request);
            var response = new HttpResponseMessage((HttpStatusCode)status)
            {
                Content = new StringContent(body, Encoding.UTF8, "application/json"),
            };
            return Task.FromResult(response);
        }
    }

    private sealed class FakeComposioGatewayTransport : IComposioGatewayTransport
    {
        public bool ReadOnly { get; set; }
        public JsonNode? DefaultUiMeta { get; set; }
        public Dictionary<(string Profile, string Key), string> Env { get; } = [];
        public Dictionary<(string Profile, string Name), JsonObject> McpConfigs { get; } = [];
        public int ReloadCount { get; private set; }

        public Task<JsonNode> CallRpcAsync(string method, JsonObject parameters, TimeSpan timeout, CancellationToken ct = default)
        {
            if (method == "profiles.list")
            {
                var uiMeta = new JsonObject();
                if (DefaultUiMeta != null) uiMeta[ComposioRecord.Key] = DefaultUiMeta.DeepClone();
                return Task.FromResult<JsonNode>(new JsonObject
                {
                    ["profiles"] = new JsonArray(new JsonObject { ["name"] = "default", ["ui_meta"] = uiMeta }),
                });
            }
            if (method == "profiles.configure")
            {
                Assert.Equal("default", parameters.Str("name"));
                var next = parameters.Obj("ui_meta")?.Get(ComposioRecord.Key);
                DefaultUiMeta = next?.DeepClone();
                return Task.FromResult<JsonNode>(new JsonObject
                {
                    ["applied"] = new JsonObject { ["ui_meta"] = true },
                });
            }
            throw new InvalidOperationException($"Unexpected RPC {method}");
        }

        public Task<List<McpServer>> McpServersAsync(string profile, CancellationToken ct = default)
        {
            var list = McpConfigs
                .Where(kv => kv.Key.Profile == profile)
                .Select(kv => new McpServer(kv.Key.Name, "http", true, "config", null) { Url = kv.Value.Str("url") })
                .ToList();
            return Task.FromResult(list);
        }

        public Task SetEnvAsync(string key, string value, string profile, CancellationToken ct = default)
        {
            Env[(profile, key)] = value;
            return Task.CompletedTask;
        }

        public Task DeleteEnvAsync(string key, string profile, CancellationToken ct = default)
        {
            Env.Remove((profile, key));
            return Task.CompletedTask;
        }

        public Task<string?> RevealEnvAsync(string key, string profile, CancellationToken ct = default) =>
            Task.FromResult(Env.TryGetValue((profile, key), out var value) ? value : null);

        public Task McpAddAsync(string name, JsonObject config, string? bearer, string profile, CancellationToken ct = default)
        {
            McpConfigs[(profile, name)] = (JsonObject)config.DeepClone();
            return Task.CompletedTask;
        }

        public Task McpRemoveAsync(string name, string profile, CancellationToken ct = default)
        {
            McpConfigs.Remove((profile, name));
            return Task.CompletedTask;
        }

        public Task ReloadMcpAsync(CancellationToken ct = default)
        {
            ReloadCount++;
            return Task.CompletedTask;
        }
    }
}
