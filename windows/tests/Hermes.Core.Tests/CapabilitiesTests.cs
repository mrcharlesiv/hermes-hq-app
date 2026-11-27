using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Capabilities;
using Hermes.Core.Composer;
using Hermes.Core.Net;

namespace Hermes.Core.Tests;

/// Capabilities' rules (ports of Tests/Capabilities/CapabilitiesUnitTests.swift, McpCatalogTests, MarketplaceTests):
/// secrets never shown, tool rules, the issue count, tools, plugins, Add a Connector, logs, sign-in pages, managed apps
/// and the Marketplace.
public class CapabilitiesTests
{
    private static JsonNode N(string json) => JsonNode.Parse(json)!;

    // ---------------------------------------------------------------- Secrets never shown

    [Fact]
    public void MaskHidesSecretsInText()
    {
        var mask = McpEntryMask.Phone;
        var token = "ghp_abcdefghijklmnopqrstuvwxyz0123456789";
        Assert.DoesNotContain(token, mask.Text($"connected with token {token}"));
        Assert.DoesNotContain("abc.def.ghi-123456", mask.Text("Authorization: Bearer abc.def.ghi-123456"));
        Assert.DoesNotContain("sk-test1234567890abcdef", mask.Text("api_key=sk-test1234567890abcdef rest"));
        Assert.Equal("plain words stay as they are", mask.Text("plain words stay as they are"));
        var url = mask.Text("GET https://user:hunter2@example.com/mcp?token=abcd1234&page=2");
        Assert.DoesNotContain("hunter2", url);
        Assert.DoesNotContain("abcd1234", url);
        Assert.Contains("example.com", url);
        Assert.Contains("page=2", url);
    }

    [Fact]
    public void MaskHidesHeadersAndEnvInAnEntry()
    {
        var entry = N("""{"url":"https://api.example.com/mcp","headers":{"Authorization":"Bearer live-secret-value","Accept":"application/json"},"env":{"ROOT":"/Users/me/files"},"args":["--api-key","sk-live1234567890","serve"]}""");
        var text = McpEntryMask.Phone.ConfigurationText("demo", entry);
        Assert.DoesNotContain("live-secret-value", text);
        Assert.DoesNotContain("sk-live1234567890", text);
        Assert.DoesNotContain("/Users/me/files", text);
        foreach (var kept in new[] { "application/json", "api.example.com", "serve", McpEntryMask.MASK, "\"demo\"" }) Assert.Contains(kept, text);
        // Sorted keys, two-space indents, as the Mac shows it.
        Assert.True(text.IndexOf("\"args\"", StringComparison.Ordinal) < text.IndexOf("\"url\"", StringComparison.Ordinal));
        Assert.StartsWith("{\n  \"demo\" : {", text);
    }

    [Fact]
    public void RedactedEntriesAreNeverWrittenBack()
    {
        Assert.True(McpToolFilter.LooksRedacted(N("""{"headers":{"x":"••••••"}}""")));
        Assert.True(McpToolFilter.LooksRedacted(N("""{"args":["a","***"]}""")));
        Assert.False(McpToolFilter.LooksRedacted(N("""{"url":"https://example.com","headers":{"x-api-key":"${COMPOSIO_API_KEY}"}}""")));
    }

    // ---------------------------------------------------------------- Tool rules

    [Fact]
    public void ToolFilterKeepsTheEntrysMode()
    {
        var plain = N("""{"url":"https://e.example/mcp"}""");
        var off = McpToolFilter.SetDisabled(plain, ["b"], ["a", "b", "c"]);
        Assert.Equal("""["b"]""", off["tools"]!["exclude"]!.ToJsonString());
        Assert.True(McpToolFilter.IsEnabled(off, "a"));
        Assert.False(McpToolFilter.IsEnabled(off, "b"));
        Assert.Equal(2, McpToolFilter.CountEnabled(off, ["a", "b", "c"]));
        Assert.Null(McpToolFilter.SetDisabled(off, [], ["a", "b", "c"])["tools"]);
        var include = N("""{"url":"u","tools":{"include":["a","gone"]}}""");
        var next = McpToolFilter.SetDisabled(include, ["a"], ["a", "b"]);
        Assert.Equal("""["b","gone"]""", next["tools"]!["include"]!.ToJsonString());
        Assert.Null(next["tools"]!["exclude"]);
        Assert.False(McpToolFilter.IsEnabled(N("""{"tools":{"include":[]}}"""), "a"));
        var kept = McpToolFilter.SetDisabled(N("""{"tools":{"exclude":["old"]}}"""), ["a"], ["a"]);
        Assert.Equal("""["a","old"]""", kept["tools"]!["exclude"]!.ToJsonString());
    }

    [Fact]
    public void ConnectorTitlesAndBusyWords()
    {
        Assert.Equal("My Files Server", ConnectorTitle.Title("my_files-server"));
        Assert.Equal("GitHub", ConnectorTitle.Title("github"));
        Assert.True(ConnectorTitle.IsBusy("request timed out after 30000 ms"));
        Assert.True(ConnectorTitle.IsBusy("The gateway is busy"));
        Assert.False(ConnectorTitle.IsBusy("401 Unauthorized"));
        Assert.StartsWith("The connector needs valid credentials", ConnectorTitle.FailureDetail("401 Unauthorized", true, false));
        Assert.StartsWith("This connector has no server address", ConnectorTitle.FailureDetail("x", false, false));
    }

    // ---------------------------------------------------------------- Issues

    private static McpServer Failed(string name = "github") => new(name, "http", true, "config", null) { Status = "failed", Tools = 0 };

    [Fact]
    public void IssuesNeedTwoReadsTenSecondsApart()
    {
        var store = new MemoryStore();
        var clock = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);
        var issues = new ServerIssues(store, () => clock);
        issues.Use("acct");
        var failed = Failed();
        issues.Report("default", [failed]);
        Assert.Equal(0, issues.Count);
        clock += TimeSpan.FromSeconds(5);
        issues.Report("default", [failed]);
        Assert.Equal(0, issues.Count);
        clock += TimeSpan.FromSeconds(6);
        issues.Report("default", [failed]);
        Assert.Equal(1, issues.Count);
        Assert.Contains("GitHub", issues.Summary);
        Assert.Equal("1 Issue", issues.RowText);
        var linear = new McpServer("linear", "http", true, "config", null) { Status = "connected", Auth = "oauth", OauthTokensPresent = false };
        var files = failed with { Name = "files", Enabled = false };
        clock += TimeSpan.FromSeconds(1);
        issues.Report("ivy", [linear, files]);
        Assert.Equal(2, issues.Count);
        Assert.Equal("linear", issues.Issues[0].Name);
        Assert.Null(ServerIssues.KindOf(files));
        Assert.Equal(IssueKind.NeedsAuth, ServerIssues.KindOf(linear));
        Assert.Equal("2 connectors need attention", issues.Summary);
        var again = new ServerIssues(store, () => clock);
        again.Use("acct");
        Assert.Equal(2, again.Count);
        again.Use("other");
        Assert.Equal(0, again.Count);
        var ok = failed with { Status = "connected" };
        issues.Report("default", [ok]);
        Assert.Equal(1, issues.Count);
        clock += ServerIssues.Lifetime + TimeSpan.FromSeconds(1);
        Assert.Equal(0, issues.Count);
        issues.Report("default", [failed]);
        issues.Report("default", [ok]);
        clock += TimeSpan.FromSeconds(20);
        issues.Report("default", [failed]);
        Assert.Equal(0, issues.Count);
        issues.SignOut("acct");
        Assert.Null(store.Get("capabilities.serverIssues.acct"));
    }

    [Fact]
    public void AConnectorBrokenForDaysStaysAnIssue()
    {
        var store = new MemoryStore();
        var clock = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);
        var issues = new ServerIssues(store, () => clock);
        issues.Use("acct");
        var linear = new McpServer("linear", "http", true, "config", null) { Status = "connected", Auth = "oauth", OauthTokensPresent = false };
        issues.Report("default", [Failed(), linear]);
        clock += TimeSpan.FromSeconds(11);
        issues.Report("default", [Failed(), linear]);
        Assert.Equal(2, issues.Count);
        for (var i = 0; i < 20; i++)
        {
            clock += TimeSpan.FromSeconds(9000);
            issues.Report("default", [Failed(), linear]);
            Assert.Equal(2, issues.Count);
        }
        var again = new ServerIssues(store, () => clock);
        again.Use("acct");
        Assert.Equal(2, again.Count);
        clock += ServerIssues.Lifetime + TimeSpan.FromSeconds(1);
        Assert.Equal(0, issues.Count);
    }

    [Fact]
    public void SweepOrderPutsDefaultFirstAndCapsAtThirty()
    {
        var order = ServerIssues.SweepOrder([.. Enumerable.Range(0, 40).Select(i => $"bot{i}"), "default"]);
        Assert.Equal("default", order[0]);
        Assert.Equal(30, order.Count);
    }

    // ---------------------------------------------------------------- Words of the lists

    [Fact]
    public void FourListsEachAPage()
    {
        Assert.Equal(["Skills", "Tools", "Connectors", "Plugins"], CapabilitiesTabs.All.Select(t => t.Title()));
        Assert.Equal("Search Connectors", CapabilitiesTab.Connectors.Prompt());
        Assert.Contains("Each bot has its own", CapabilitiesWords.HubFooter);
    }

    [Fact]
    public void ConnectorStatusLines()
    {
        var gh = new McpServer("github", "http", true, "config", null) { Status = "connected", Tools = 5 };
        Assert.Equal("Connected · 5 tools", CapabilitiesWords.StatusLine(gh));
        Assert.Equal("5 tools", CapabilitiesWords.ShownWords(gh));
        Assert.Equal("Connected · 1 tool", CapabilitiesWords.StatusLine(gh with { Tools = 1 }));
        Assert.Equal("Off", CapabilitiesWords.StatusLine(gh with { Enabled = false }));
        Assert.Equal("Couldn’t connect", CapabilitiesWords.StatusLine(gh with { Status = "failed" }));
        Assert.Equal("Starts when needed", CapabilitiesWords.StatusLine(gh with { Status = "lazy" }));
        Assert.Equal("Needs sign-in", CapabilitiesWords.StatusLine(gh with { Auth = "oauth", OauthTokensPresent = false }));
        var browser = new McpServer("browser", "stdio", true, "plugin", "browser") { Status = "connected", Tools = 12 };
        Assert.Equal("Connected · 12 tools · Added by the Browser plugin", CapabilitiesWords.StatusLine(browser));
        Assert.Equal("12 tools · Plugin", CapabilitiesWords.ShownWords(browser));
        Assert.Equal(ConnectorTone.Good, ConnectorTones.Of(gh));
        Assert.Equal(ConnectorTone.Quiet, ConnectorTones.Of(gh with { Enabled = false }));
        Assert.Equal(ConnectorTone.Bad, ConnectorTones.Of(gh with { Status = "failed" }));
    }

    [Fact]
    public void SkillWords()
    {
        var s = SkillInfo.Read(N("""{"name":"web-search","description":"Search the web","category":"research","usage":30}"""))!;
        Assert.Equal("Research · Used 30 times", CapabilitiesWords.SkillCaption(s));
        Assert.Equal("Research · Used 30 times · Search the web", CapabilitiesWords.SkillLine(s));
        Assert.Equal("General", CapabilitiesWords.SkillCaption(s with { Category = null, Usage = 0 }));
        Assert.Equal("Installing Web Search…", CapabilitiesWords.InstallTitle("web-search", false));
        Assert.Equal("For Ivy. This can take a minute.", CapabilitiesWords.InstallMessage("Ivy", false));
        Assert.Equal("No Skills Installed", CapabilitiesWords.SkillsEmpty("Ivy", true).Title);
        Assert.Equal("Search Skills", CapabilitiesWords.SkillsEmpty("Ivy", true).Action);
        Assert.Null(CapabilitiesWords.SkillsEmpty("Ivy", false).Action);
        Assert.Equal("Turn Off 3 Unused Skills for Ivy?", CapabilitiesWords.DisableUnusedTitle(3, "Ivy"));
        Assert.Equal((2, true), CapabilitiesWords.InstallBlocked(["Not installed: the security scan found 2 high-risk patterns. Hermes never installs unverified"]));
        Assert.Equal((3, true), CapabilitiesWords.InstallBlocked(["Installation blocked: nope (community source + dangerous verdict, 3 findings)"]));
        Assert.Null(CapabilitiesWords.InstallBlocked(["all fine"]));
        Assert.Equal("The security scan flagged 1 item to review. Read the scan before deciding whether to trust the author.",
            CapabilitiesWords.BlockedMessage(1, false));
        Assert.Equal("Web Search", DisplayName.Title("web-search"));
        Assert.Equal("GitHub PR", DisplayName.Title("github-pr"));
        Assert.Equal("Keep Mine", DisplayName.Title("Keep Mine"));
        var hub = new HubSkill("pdf-redact", "", "skills-sh/pdf-redact", "skills-sh", "community", null);
        Assert.True(hub.IsCommunity);
        Assert.Equal("Community · skills.sh", hub.Provenance);
        Assert.StartsWith("It comes from the community (skills.sh), not from Nous.", CapabilitiesWords.HubInstallAskMessage(hub, "Ivy"));
    }

    // ---------------------------------------------------------------- Tools

    [Fact]
    public void ToolsetLabelsCountsAndHiddenOnes()
    {
        Assert.Equal("Web", Toolset.StripLabel("🌐 Web"));
        Assert.Equal("Terminal", Toolset.StripLabel("Terminal"));
        Assert.Equal("🌐", Toolset.StripLabel("🌐"));
        Assert.Equal(["999", "1.2K", "12K", "1.5M", "0"], new long[] { 999, 1200, 12_400, 1_500_000, -4 }.Select(Toolset.Compact));
        Assert.Contains("discord", Toolset.Hidden);
        Assert.DoesNotContain("web", Toolset.Hidden);
        var row = Toolset.Read(N("""{"name":"web","label":"🌐 Web","enabled":true,"configured":false,"tools":["web_search",3]}"""))!;
        Assert.Equal("Web", row.Label);
        Assert.False(row.Configured);
        Assert.Equal(["web_search"], row.Tools);
        Assert.Null(Toolset.Read(N("""{"label":"no name"}""")));
        Assert.Equal(12, SkillUsage.Read(JsonValue.Create(12)));
        Assert.Null(SkillUsage.Read(JsonValue.Create("12")));
        Assert.Equal("2 tools", CapabilitiesWords.ToolMeta(row with { Tools = ["a", "b"] }, null));
        Assert.Equal("1.2K uses", CapabilitiesWords.ToolMeta(row, new Dictionary<string, int> { ["web_search"] = 1200 }));
        var cfg = ToolsetConfig.Read(N("""{"has_category":true,"providers":[{"name":"Firecrawl","status":"needs_keys","env_vars":[{"key":"FIRECRAWL_API_KEY","prompt":"Firecrawl API key","url":"https://firecrawl.dev","default":"sk-abcdef1234567890"}]}]}"""));
        Assert.Equal("Needs keys", cfg.Providers[0].StatusWord);
        Assert.Null(cfg.Providers[0].EnvVars[0].Placeholder);
    }

    // ---------------------------------------------------------------- Plugins

    [Fact]
    public void PluginActionsSendExactlyTheContractsKeys()
    {
        static string J2(PluginAction a, string p) => a.Params(p).ToJsonString();
        Assert.Equal("""{"profile":"ivy","action":"toggle","key":"catalog:x","enable":true}""", J2(new PluginAction.Toggle("catalog:x", true), "ivy"));
        Assert.Equal("""{"profile":"p","action":"update","name":"x"}""", J2(new PluginAction.Update("x", false), "p"));
        Assert.True(new PluginAction.Update("x", true).Params("p")["accept_capabilities"]!.GetValue<bool>());
        Assert.Equal("""{"profile":"p","action":"remove","name":"x"}""", J2(new PluginAction.Remove("x"), "p"));
        var install = new PluginAction.Install("acme/x", false, true, "");
        Assert.Equal("""{"profile":"p","action":"install","identifier":"acme/x","force":false,"enable":true}""", J2(install, "p"));
        Assert.Equal(TimeSpan.FromSeconds(120), install.Timeout);
        Assert.Equal(TimeSpan.FromSeconds(60), new PluginAction.Remove("x").Timeout);
        Assert.Equal("""{"profile":"p","action":"install","catalog_name":"web-clipper","enable":true}""", J2(new PluginAction.InstallCatalog("web-clipper", true), "p"));
        Assert.True(PluginInfo.Read(N("""{"name":"kanban","key":"bundled:kanban","source":"bundled","status":"enabled"}"""))!.IsKanban);
        Assert.True(PluginInfo.Read(N("""{"name":"mine","key":"git:mine","source":"git","status":"enabled"}"""))!.CanUninstall);
        var p = PluginInfo.Read(N("""{"name":"weather-now","source":"catalog","status":"disabled","catalog_sha":"0123456789abcdef0123","servers":[{"name":"w","state":"app_not_running"}]}"""))!;
        Assert.Equal("Weather Now", p.Title);
        Assert.False(p.Enabled);
        Assert.Equal("0123456", p.NewVersion);
        Assert.Equal("App not running", p.Servers[0].Words);
        Assert.Equal("From the Hermes catalog", p.SourceWords);
        var r = PluginResult.Read(N("""{"ok":true,"restart_required":true,"gateway_reloaded":false,"missing_env":["K"],"scan_findings":[{"description":"eval","file":"a.py"}]}"""));
        Assert.True(r.NeedsRestart);
        Assert.Equal(["eval (a.py)"], r.ScanFindings);
    }

    [Fact]
    public void PluginRepositoryAddresses()
    {
        Assert.Equal(PluginRepo.Check.Empty, PluginRepo.CheckRepo("   "));
        Assert.Equal(PluginRepo.Check.Ok, PluginRepo.CheckRepo("acme/notes-plugin"));
        Assert.Equal(PluginRepo.Check.Ok, PluginRepo.CheckRepo("https://github.com/acme/notes.git"));
        Assert.Equal(PluginRepo.Check.Ok, PluginRepo.CheckRepo("git@github.com:acme/notes.git"));
        Assert.Equal(PluginRepo.Check.Insecure, PluginRepo.CheckRepo("http://github.com/acme/notes"));
        Assert.Equal(PluginRepo.Check.Insecure, PluginRepo.CheckRepo("file:///etc/passwd"));
        Assert.Equal(PluginRepo.Check.Invalid, PluginRepo.CheckRepo("not a repo"));
        Assert.Equal(PluginRepo.Check.Invalid, PluginRepo.CheckRepo("--upload-pack=x"));
        Assert.Equal(PluginRepo.Check.Invalid, PluginRepo.CheckRepo("acme"));
        Assert.True(PluginRepo.RefValid("") && PluginRepo.RefValid(new string('f', 40)));
        Assert.False(PluginRepo.RefValid("main") || PluginRepo.RefValid(new string('g', 40)));
    }

    // ---------------------------------------------------------------- Add a Connector

    [Fact]
    public void ConnectorDraftRules()
    {
        var draft = new ConnectorDraft();
        Assert.False(draft.IsComplete([]));
        Assert.False(draft.HasContent);
        draft.Name = "weather";
        draft.Url = "https://mcp.weather.example/mcp";
        Assert.True(draft.IsComplete(["github"]));
        Assert.True(draft.HasContent);
        Assert.False(draft.IsComplete(["Weather"]));
        draft.Name = "bad name";
        Assert.False(draft.NameValid);
        draft.Name = "weather";
        draft.Url = "ftp://example.com";
        Assert.False(draft.UrlValid);
        draft.Url = "https://mcp.weather.example/mcp";
        draft.Auth = ConnectorDraft.Auths.Bearer;
        Assert.False(draft.IsComplete([]));
        draft.Token = " tok-1234 ";
        Assert.True(draft.IsComplete([]));
        Assert.Equal("tok-1234", draft.Bearer);
        Assert.Equal("https://mcp.weather.example/mcp", draft.Config["url"]!.GetValue<string>());
        Assert.DoesNotContain("tok-1234", draft.Config.ToJsonString());
        var command = new ConnectorDraft { Name = "files", Kind = ConnectorDraft.Kinds.Command };
        Assert.False(command.IsComplete([]));
        command.Command = "npx";
        command.Args.Add(new() { Value = "-y" });
        Assert.True(command.IsComplete([]));
        Assert.Null(command.Bearer);
        Assert.Equal("""{"command":"npx","args":["-y"]}""", command.Config.ToJsonString());
        Assert.Equal("Bearer Token", ConnectorDraft.AuthTitle(ConnectorDraft.Auths.Bearer));
        Assert.Null(ConnectorDraft.Reason(new GatewayException("rpc", "server already exists", rpcCode: 4090)));
        Assert.Equal("Enter a web address or a command.", ConnectorDraft.Reason(new GatewayException("rpc", "x", rpcCode: 4063)));
    }

    // ---------------------------------------------------------------- Logs and sign-in

    [Fact]
    public void LogsShowOnlyThisConnectorsLastRun()
    {
        string[] lines = ["===== starting MCP server 'github' =====", "old run", "===== starting MCP server 'files' =====", "files line",
            "===== starting MCP server 'github' =====", "new one", "new two", "===== starting MCP server 'linear' =====", "other"];
        Assert.Equal(["new one", "new two"], ConnectorLogs.Section(lines, "github"));
        Assert.Equal(["other"], ConnectorLogs.Section(lines, "linear"));
        Assert.Null(ConnectorLogs.Section(lines, "absent"));
        var cleaned = ConnectorLogs.Clean(["token ghp_abcdefghijklmnopqrstuvwxyz0123456789", string.Concat(Enumerable.Repeat("x ", 1500))]);
        Assert.DoesNotContain("ghp_abcdefghijklmnopqrstuvwxyz0123456789", cleaned[0]);
        Assert.EndsWith("…", cleaned[1]);
        Assert.Equal(500, ConnectorLogs.Clean([.. Enumerable.Range(0, 700).Select(i => $"line {i}")]).Count);
    }

    [Fact]
    public void SignInPageMustBeHttpsAndCarryThisPcsRedirect()
    {
        var redirect = "http://127.0.0.1:53111/callback";
        var good = "https://auth.example.com/authorize?client_id=x&redirect_uri=http%3A%2F%2F127.0.0.1%3A53111%2Fcallback&state=s";
        Assert.NotNull(McpSignInRules.Accepts(good, redirect));
        Assert.Null(McpSignInRules.Accepts(good, "http://127.0.0.1:1/callback"));
        Assert.Null(McpSignInRules.Accepts($"http://auth.example.com/authorize?redirect_uri={redirect}", redirect));
        Assert.Null(McpSignInRules.Accepts("javascript:alert(1)", redirect));
        Assert.Null(McpSignInRules.Accepts("https://auth.example.com/authorize", redirect));
        Assert.NotNull(McpSignInRules.Accepts($"http://127.0.0.1:9840/__oauth/authorize?redirect_uri={Uri.EscapeDataString(redirect)}", redirect, allowLoopbackHttp: true));
    }

    // ---------------------------------------------------------------- The app catalog

    [Fact]
    public void CatalogTitlesOrderAndKeys()
    {
        var entries = McpCatalog.Entries(N("""
            {"entries":[
            {"name":"sentry","connector_slug":"sentry_mcp","description":"Sentry: Errors and issues","transport":"http","url":"https://mcp.sentry.dev/mcp","auth_type":"oauth"},
            {"name":"n8n","description":"Workflows","required_env":[{"name":"N8N_MCP_SERVER_URL","prompt":"Server URL"},{"name":"N8N_API_KEY","required":false}]},
            {"name":"linear","description":"Issues"},
            {"name":"my-cool_mcp"}]}
            """));
        Assert.Equal("Sentry", entries[0].Title);
        Assert.Equal("Errors and issues", entries[0].ShortDescription);
        Assert.True(entries[0].NeedsSignIn);
        Assert.Equal("My Cool MCP", entries[3].Title);
        Assert.True(McpCatalog.IsAddress(entries[1].RequiredEnv[0]));
        Assert.False(McpCatalog.IsAddress(entries[1].RequiredEnv[1]));
        Assert.False(entries[1].RequiredEnv[1].Required);
        Assert.Equal("linear", McpCatalog.Ordered(entries)[0].Name);
        Assert.Equal(["sentry_mcp", "sentry"], McpCatalog.LogoSlugs(entries[0]));
        Assert.True(entries[2].Matches("ISSU"));
    }

    // ---------------------------------------------------------------- Managed apps

    [Fact]
    public void ManagedAppsJoinStateAndWords()
    {
        var catalog = ManagedWire.Catalog(N("""{"connectors":[{"slug":"gmail","name":"Gmail","category":"email"},{"slug":"slack","name":"Slack"},{"slug":"github","name":"GitHub"},{"slug":"notion"}]}"""));
        var list = ManagedWire.List(N("""{"available":true,"connectors":[{"connector":"slack","connected":true,"connection_status":"expired"},{"connector":"github","connected":true,"connection_status":"active"}]}"""));
        var accounts = ManagedWire.Accounts(N("""{"accounts":[{"connection_id":"c1","connector":"gmail","status":"active","label":"me@example.com","active":true,"created_at":"2026-01-01"}]}"""));
        var policy = ManagedWire.Policy(N("""{"layers":[{"kind":"member","revision":"r1","body":{"mode":"deny","disabled_connectors":["notion"],"tools":{"github":["delete_repo"]}}}]}"""));
        var apps = ManagedJoin.Apps(catalog, list.Connectors, accounts, policy, rulesReadable: true);
        var by = apps.ToDictionary(a => a.Slug);
        Assert.Equal("Connected", by["gmail"].StateWord);
        Assert.Equal("Access expired", by["slack"].StateWord);
        Assert.Equal(ManagedVerb.Reconnect, by["slack"].Verb);
        Assert.Equal("Connected · 1 tool off", by["github"].StateWord);
        Assert.Equal("Off for you", by["notion"].StateWord);
        Assert.Equal(ManagedVerb.TurnBackOn, by["notion"].Verb);
        Assert.Equal("Notion", by["notion"].Name);
        Assert.Equal(["slack", "github", "gmail", "notion"], ManagedJoin.Mine(apps).Select(a => a.Slug));
        Assert.Equal(ConnectorTone.Warn, by["slack"].Tone());
        Assert.Equal("Reconnect to keep this app working.", by["slack"].Reason);
        Assert.Equal("r1", policy.MemberRevision);
        Assert.Equal("Turn Back On", ManagedApp.VerbTitle(ManagedVerb.TurnBackOn));
        Assert.Equal("2 tools off, none back on", ManagedToolWords.Draft(2, 0));
        Assert.True(ConnectorAccountRow.AliasValid("work"));
        Assert.Equal(AccountWords.AliasInvalid, ConnectorAccountRow.AliasProblem("Work", accounts));
        var failure = ConnectorFailure.From(new GatewayException("rpc", "nope", rpcCode: 4012, body: """{"reason":"NEEDS_NOUS_AUTH"}"""));
        Assert.Equal(ConnectorErrorReason.NeedsNousAuth, failure.Reason);
        Assert.Equal("Sign in to Nous to use managed apps.", failure.Words());
        Assert.True(ConnectorFailure.From(new GatewayException("rpc", "Method not found", rpcCode: -32601)).TooOld);
    }

    [Fact]
    public void OperationsMoveOnlyForward()
    {
        var op = ManagedWire.Operation(N("""{"op_id":"o1","seq":1,"targets":[{"name":"gmail","state":"initiated","connect_url":"https://x/y"}]}"""), ["gmail"])!;
        Assert.Equal("https://x/y", op.Link);
        Assert.False(op.Settled);
        var snap = ManagedWire.Operation(N("""{"op_id":"o1","seq":2,"settled_at":123,"targets":[{"name":"gmail","state":"connected"}]}"""))!;
        var next = op.Applying(snap, broadcast: true)!;
        Assert.True(next.Settled);
        Assert.Equal(ConnectionTargetState.Connected, next.Target("gmail")!.State);
        Assert.Null(next.Applying(snap, broadcast: true));
        var still = ManagedWire.Operation(N("""{"op_id":"o1","seq":2,"targets":[{"name":"gmail","state":"initiated"}]}"""))!;
        Assert.Equal("https://x/y", op.Applying(still, broadcast: true)!.Link);
    }

    // ---------------------------------------------------------------- Marketplace

    private static List<PluginCatalogEntry> Plugins() => PluginCatalogEntry.Decode("""
        [{"name":"mem0","description":"Mem0: Long-term memory for agents. Second sentence here.","repo":"https://github.com/mem0ai/mem0","tier":"verified","category":"memory","maintainer":"Mem0","stars":68000,"platforms":["macos","linux","windows"],"requiresHermes":">=0.20"},
         {"name":"memory-wiki","description":"A wiki of memories","repo":"https://github.com/nous/memory-wiki","tier":"official","category":"memory","maintainer":"NousResearch","stars":50},
         {"name":"zep","description":"Memory","repo":"https://github.com/getzep/zep","category":"memory","stars":4000},
         {"name":"weather","description":"Weather tools","repo":"https://github.com/x/weather","category":"tools","stars":10,"capabilities":{"providesTools":["forecast"],"requiresEnv":["WEATHER_KEY"]}},
         {"name":"bad","repo":"http://insecure"}]
        """);

    [Fact]
    public void PluginCatalogReadsSearchesAndPicks()
    {
        var p = Plugins();
        Assert.Equal(4, p.Count);
        Assert.Equal("Long-term memory for agents.", p[0].Summary);
        Assert.Equal("Certified", p[0].TierWord);
        Assert.Equal("macOS, Linux and Windows", p[0].PlatformWords);
        Assert.Equal("0.20 or newer", p[0].HermesWords);
        Assert.Equal("Memory Wiki", p[1].Title);
        Assert.Equal("memory-wiki", PluginCatalogEntry.Search(p, "memory wiki")[0].Name);
        Assert.Equal("weather", PluginCatalogEntry.Search(p, "forecast")[0].Name);
        Assert.Equal(["mem0", "memory-wiki", "weather"], PluginCatalogEntry.Picks(p, 5).Select(e => e.Name));
        Assert.Equal(("Uses x.", (string?)"It sends data."), PluginCatalogEntry.Split("Uses x. Disclosure — it sends data."));
    }

    [Fact]
    public void MarketplaceFiltersSortsAndCounts()
    {
        var skills = MarketSkill.ParseObjects("""
            junk {"name":"pdf","description":"Read PDFs","author":"Nous","category":"documents","categoryLabel":"Documents","tags":["pdf"],"source":"optional","slug":"official/pdf","installIdentifier":"official/documents/pdf"} junk
            {"name":"cuda","description":"GPU","category":"","tags":[],"source":"NVIDIA","installIdentifier":"nvidia/skills/cuda"}
            """);
        Assert.Equal(2, skills.Count);
        Assert.Equal("Other", skills[1].CategoryLabel);
        Assert.True(skills[0].IsOfficial);
        Assert.Equal("Nous", skills[0].SourceWord);
        var state = new MarketplaceState(MarketplaceKind.All);
        var items = state.Scoped(Plugins(), skills);
        Assert.Equal(6, items.Count);
        Assert.True(state.Browsing);
        Assert.Equal("mem0", state.Ordered(state.Filter(items))[0].Plugin!.Name);
        state.Query = "pdf";
        Assert.Equal("pdf", state.Ordered(state.Filter(items))[0].Skill!.Name);
        state.Query = "";
        state.Choose(MarketplaceKind.Plugins);
        items = state.Scoped(Plugins(), skills);
        var tiers = state.TierRows(items);
        Assert.Equal([(MarketplaceTier.Official, 1), (MarketplaceTier.Verified, 1), (MarketplaceTier.Community, 2)], tiers);
        state.Tiers.Add(MarketplaceTier.Community);
        Assert.Equal(2, state.Filter(items).Count);
        var cats = state.CategoryRows(items);
        Assert.Equal([("memory", "Memory", 1), ("tools", "Tools", 1)], cats);
        state.Sort = MarketplaceSort.Name;
        Assert.Equal(["Weather", "Zep"], state.Ordered(state.Filter(items)).Select(i => i.Name));
        Assert.Equal("Certified", MarketplaceTier.Verified.Title());
        var page = "<script>self.__next_f.push([1,\"{\\\"name\\\":\\\"x\\\",\\\"source\\\":\\\"optional\\\",\\\"installIdentifier\\\":\\\"official/x\\\"}\"])</script>";
        Assert.Equal("official/x", MarketSkill.ParsePage(page).Single().InstallIdentifier);
    }

    // ---------------------------------------------------------------- The relay the connector sign-in uses

    [Fact]
    public async Task RelayCarriesIssuerAndRefusals()
    {
        using var relay = new LoopbackRelay();
        var wait = relay.WaitAsync(CancellationToken.None);
        using var http = new HttpClient();
        await http.GetAsync(relay.RedirectUri + "?code=abc&state=s1&iss=https%3A%2F%2Fauth.example.com");
        var cb = await wait.WaitAsync(TimeSpan.FromSeconds(10));
        Assert.Equal(("abc", "s1", "https://auth.example.com", (string?)null), (cb.Code, cb.State, cb.Iss, cb.Error));
    }
}
