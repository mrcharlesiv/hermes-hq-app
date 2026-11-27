using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Capabilities;
using Hermes.Core.Net;

namespace Hermes.Core.Tests;

/// Capabilities against scripts/fixtures/connectors-gateway.py (which layers on capabilities-gateway.py and
/// settings-gateway.py): skills with an install that runs as an action, the Skills Hub, tools and their setup,
/// connectors with status, a probe, tool rules saved remove-then-add, the masked entry, logs, Add a Connector, an OAuth
/// sign-in through the loopback relay, the app catalog install, plugins, and a managed app connected through a sign-in
/// link that settles on `connection.update` broadcasts. Run through windows/scripts/e2e.sh
/// (HQW_E2E_CAPABILITIES_CREDENTIALS); without it these pass vacuously.
[Trait("Category", "E2E")]
public class CapabilitiesEndToEndTests
{
    /// The Windows build machine is slow: every wait is a deadline, never a fixed delay.
    private static async Task Until(Func<Task<bool>> condition, int seconds = 30)
    {
        var until = DateTime.UtcNow.AddSeconds(seconds);
        while (!await condition())
        {
            if (DateTime.UtcNow > until) throw new TimeoutException("condition not met");
            await Task.Delay(100);
        }
    }

    private static async Task<JsonNode> Get(string url, string path)
    {
        using var http = new HttpClient();
        return JsonNode.Parse(await http.GetStringAsync(url.TrimEnd('/') + path))!;
    }

    private static async Task Post(string url, string path, string json)
    {
        using var http = new HttpClient();
        var r = await http.PostAsync(url.TrimEnd('/') + path, new StringContent(json, System.Text.Encoding.UTF8, "application/json"));
        r.EnsureSuccessStatusCode();
    }

    private static async Task<(HermesClient Client, string Url)?> SignIn()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_CAPABILITIES_CREDENTIALS");
        if (path == null || !File.Exists(path)) return null;
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        var url = cred.Str("url")!;
        var session = await new SignIn(new MemoryTokenStore()).PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
        var client = new HermesClient(session);
        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(30)).Token);
        return (client, url);
    }

    [Fact]
    public async Task SkillsToolsAndPlugins()
    {
        if (await SignIn() is not var (client, url)) return;
        await using var owned = client;
        await Post(url, "/__seed", """{"reset":true}""");
        var api = new CapabilitiesApi(client.Session, client.Rpc) { PollInterval = TimeSpan.FromMilliseconds(300) };

        // Skills: the installed list with use counts, the official catalog, a switch.
        var skills = await api.SkillsAsync("default");
        Assert.Contains(skills, s => s.Name == "web-search" && s.Usage == 30);
        var official = await api.OfficialSkillsAsync("default");
        var get = official.First(o => !o.Installed && !skills.Any(s => s.Name == o.Name));
        await api.SetSkillAsync("arxiv", false, "default");
        Assert.False((await api.SkillsAsync("default")).First(s => s.Name == "arxiv").Enabled);

        // An install runs as an action, polled until it ends.
        ActionStatus? last = null;
        await foreach (var status in api.InstallAsync(get.Identifier, "default")) last = status;
        Assert.Equal(0, last?.ExitCode);
        await Until(async () => (await api.SkillsAsync("default")).Any(s => s.Name == get.Name));

        // The Skills Hub.
        var hub = await api.SearchHubAsync("pdf", "default");
        Assert.Contains(hub.Results, r => r.Identifier == "skills-sh/pdf-redact" && r.IsCommunity);

        // Tools: the list (hidden ones dropped by the page), a switch, the setup of Web, terminal backends.
        var toolsets = await api.ToolsetsAsync("default");
        Assert.Contains(toolsets, t => t.Name == "web" && t.Label == "Web" && !t.Configured);
        await api.SetToolsetAsync("image_gen", true, "default");
        Assert.True((await api.ToolsetsAsync("default")).First(t => t.Name == "image_gen").Enabled);
        await api.DeleteEnvAsync("FIRECRAWL_API_KEY", "default");
        var web = await api.ToolsetConfigAsync("web", "default");
        Assert.NotNull(web);
        Assert.Contains(web!.Providers, p => p.Name == "Firecrawl" && p.StatusWord == "Needs keys");
        await api.SetEnvAsync("FIRECRAWL_API_KEY", "fc-test-value", "default");
        var after = await api.ToolsetConfigAsync("web", "default");
        Assert.True(after!.Providers.First(p => p.Name == "Firecrawl").EnvVars[0].IsSet);
        await api.DeleteEnvAsync("FIRECRAWL_API_KEY", "default");
        var backends = await api.TerminalBackendsAsync("default");
        Assert.Contains(backends, b => b.Name == "local" && b.Active && b.IsReady);
        _ = await api.ToolUsageAsync("default");

        // Plugins: the list and a switch.
        var plugins = await api.PluginsAsync("default");
        var clipper = plugins.First(p => p.Name == "web-clipper");
        Assert.False(clipper.Enabled);
        var toggled = await api.PluginAsync(new PluginAction.Toggle(clipper.Key!, true), "default");
        Assert.True(toggled.Ok);
        Assert.True((await api.PluginsAsync("default")).First(p => p.Name == "web-clipper").Enabled);
    }

    [Fact]
    public async Task ConnectorsProbeRulesSignInAndCatalog()
    {
        if (await SignIn() is not var (client, url)) return;
        await using var owned = client;
        await Post(url, "/__seed", """{"reset":true}""");
        var api = new CapabilitiesApi(client.Session, client.Rpc) { PollInterval = TimeSpan.FromMilliseconds(300) };

        // The list with live status folded in.
        var servers = await api.ServersWithStatusAsync("default");
        var github = servers.First(s => s.Name == "github");
        Assert.Equal("Connected · 5 tools", CapabilitiesWords.StatusLine(github));
        Assert.Equal("12 tools · Plugin", CapabilitiesWords.ShownWords(servers.First(s => s.Name == "browser")));
        Assert.Equal("Off", CapabilitiesWords.StatusLine(servers.First(s => s.Name == "files")));

        // The probe, then two tools off: the entry is saved with an exclude list and the tools read back off.
        var probe = await api.McpTestAsync("github", "default");
        Assert.True(probe.Ok);
        Assert.Equal(5, probe.Tools.Count);
        var outcome = await api.SaveToolRulesAsync("github", ["delete_repo", "search_code"], [.. probe.Tools.Select(t => t.Name)], "default");
        Assert.IsType<ToolRulesOutcome.Saved>(outcome);
        var entry = await api.McpEntryAsync("github", "default");
        Assert.False(McpToolFilter.IsEnabled(entry, "delete_repo"));
        Assert.True(McpToolFilter.IsEnabled(entry, "create_issue"));
        Assert.IsType<ToolRulesOutcome.Unchanged>(await api.SaveToolRulesAsync("github", ["delete_repo", "search_code"], [.. probe.Tools.Select(t => t.Name)], "default"));
        // Advanced: the entry masked, nothing secret on screen.
        var text = McpEntryMask.Phone.ConfigurationText("github", entry);
        Assert.DoesNotContain("ghp_FIXTURESECRET", text);
        Assert.Contains("\"github\"", text);

        // A switch, then Add a Connector by web address and remove it.
        await api.SetMcpAsync("files", true, "default");
        Assert.True((await api.McpServersAsync("default")).First(s => s.Name == "files").Enabled);
        var draft = new ConnectorDraft { Name = "weather", Url = "https://mcp.weather.example/mcp" };
        await api.McpAddAsync(draft.TrimmedName, draft.Config, draft.Bearer, "default");
        Assert.Contains(await api.McpServersAsync("default"), s => s.Name == "weather");
        var taken = await Assert.ThrowsAsync<GatewayException>(() => api.McpAddAsync("weather", draft.Config, null, "default"));
        Assert.Null(ConnectorDraft.Reason(taken));
        await api.McpRemoveAsync("weather", "default");
        Assert.DoesNotContain(await api.McpServersAsync("default"), s => s.Name == "weather");
        await api.McpRemoveAsync("weather", "default");   // already gone counts as removed

        // Logs: the MCP log, this connector's section.
        await Post(url, "/__log", """{"file":"mcp","line":"===== starting MCP server 'files' ====="}""");
        await Post(url, "/__log", """{"file":"mcp","line":"files started with token ghp_abcdefghijklmnopqrstuvwxyz0123456789"}""");
        var lines = await api.LogsAsync("mcp", 500, null, "default");
        var section = ConnectorLogs.Clean(ConnectorLogs.Section(lines, "files") ?? []);
        Assert.Contains(section, l => l.StartsWith("files started"));
        Assert.DoesNotContain(section, l => l.Contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789"));

        // OAuth: Linear turned on needs a sign-in; the page (allowed) sends the browser to this PC's relay.
        await api.SetMcpAsync("linear", true, "default");
        var linear = (await api.ServersWithStatusAsync("default")).First(s => s.Name == "linear");
        Assert.Equal(IssueKind.NeedsAuth, ServerIssues.KindOf(linear));
        await Post(url, "/__seed", """{"oauth_auto":"allow"}""");
        using var browser = new HttpClient(new HttpClientHandler { AllowAutoRedirect = true });
        var signIn = new McpSignIn(api) { AllowLoopbackHttp = true, PollEvery = TimeSpan.FromMilliseconds(300) };
        var result = await signIn.RunAsync("linear", "default", page => { _ = browser.GetAsync(page); return true; });
        Assert.IsType<McpSignIn.Outcome.SignedIn>(result);
        await Until(async () => ServerIssues.KindOf((await api.ServersWithStatusAsync("default")).First(s => s.Name == "linear")) == null);

        // The app catalog: an entry installs with its keys and joins the list.
        var catalog = await api.McpCatalogAsync("default");
        Assert.NotNull(catalog);
        var pick = catalog!.First(e => !e.Installed && e.InstallUrl == null && e.RequiredEnv.All(k => !k.Required));
        await api.InstallCatalogAsync(pick.Name, new Dictionary<string, string>(), "default");
        await Until(async () => (await api.McpServersAsync("default")).Any(s => s.Name == pick.Name));
    }

    [Fact]
    public async Task AManagedAppConnectsThroughItsSignInLink()
    {
        if (await SignIn() is not var (client, url)) return;
        await using var owned = client;
        await Post(url, "/__connectors", """{"reset":true}""");
        var api = new ManagedConnectorsApi(client.Rpc);
        var state = new ManagedAppsState(api, "default");
        client.Rpc.Event += ev => { if (ev.Type == "connection.update") lock (state) state.Apply(ev.Payload); };
        await state.ReloadAsync();
        Assert.IsType<ManagedPhase.Ready>(state.Phase);
        var apps = state.Apps;
        Assert.NotEmpty(apps);
        var app = apps.First(a => a.State == ManagedState.Available && a.InCatalog);
        Assert.Equal(ManagedVerb.Connect, app.Verb);

        var op = await api.ConnectAsync(app.Slug, reconnect: false, "default");
        lock (state) state.Remember(op, app.Slug);
        Assert.True(state.Waiting(app.Slug));
        var link = op.Target(app.Slug)?.ConnectUrl ?? op.Link;
        Assert.NotNull(link);
        using var browser = new HttpClient();
        await browser.GetAsync(link + "&choice=allow");
        await Until(() => { lock (state) return Task.FromResult(!state.Waiting(app.Slug)); });
        await state.ReloadAccountsAndListAsync();
        Assert.Equal(ManagedState.Connected, state.App(app.Slug)!.State);

        // The tool list and the member rule.
        var tools = await api.ToolsAsync(app.Slug, refresh: false, "default");
        Assert.Equal(app.Slug, tools.Connector.Length == 0 ? app.Slug : tools.Connector);
        var revision = state.Policy.MemberRevision;
        if (revision != null)
        {
            await api.SetEnabledAsync(app.Slug, false, revision, "default");
            await state.ReloadPolicyAsync();
            Assert.Equal("Off for you", state.App(app.Slug)!.StateWord);
        }

        // A signed-out bot's account is an empty state, not a failure.
        await Post(url, "/__connectors", """{"mode":{"profile":"ivy","mode":"signed_out"}}""");
        var ivy = new ManagedAppsState(api, "ivy");
        await ivy.ReloadAsync();
        Assert.IsType<ManagedPhase.SignedOut>(ivy.Phase);
    }
}
