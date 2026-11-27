using System.Text.Json.Nodes;
using Hermes.Core.Capabilities;
using Hermes.Core.Gateways;
using HermesHQ.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Features.Capabilities;

/// A skill's page (SkillPageController.swift): its switch, its SKILL.md, Uninstall for a hub skill.
internal sealed class SkillScreen(CapabilitiesModel model, SkillInfo skill) : Screen
{
    private string? _content, _error;
    private readonly string _profile = model.Profile;
    public override string Title => DisplayName.Title(skill.Name);
    private SkillInfo? Skill => model.Profile == _profile ? model.Skills?.FirstOrDefault(s => s.Name == skill.Name) : null;

    public override void Shown() { model.Changed += Render; if (_content == null) Load(); }
    public override void Hidden() => model.Changed -= Render;

    private async void Load()
    {
        if (model.Api is not { } api) return;
        _error = null;
        Render();
        try { _content = StripFrontMatter(await api.SkillContentAsync(skill.Name, _profile)); }
        catch (Exception e) { _error = CapabilitiesWords.Detail(e); }
        Render();
    }

    public static string StripFrontMatter(string text)
    {
        var lines = text.Split('\n');
        if (lines.Length == 0 || lines[0].Trim() != "---") return text;
        var end = Array.FindIndex(lines, 1, l => l.Trim() == "---");
        return end < 0 ? text : string.Join("\n", lines.Skip(end + 1)).Trim();
    }

    public override void Build(StackPanel page)
    {
        if (Skill is { } s)
            page.Children.Add(Kit.Section(null, [Kit.SwitchRow("Turned On", s.Enabled, on => model.SetSkill(s, on), !model.Toggling.Contains(s.Name) && !model.ReadOnly)]));
        UIElement body;
        if (_content != null)
        {
            var panel = new StackPanel { Spacing = 6 };
            MarkdownRenderer.Render(_content, panel);
            body = Kit.Pad(panel, 12);
        }
        else if (_error != null)
        {
            var s2 = new StackPanel { Spacing = 8 };
            s2.Children.Add(Kit.Text("Couldn’t load this skill", 15, bold: true));
            s2.Children.Add(Kit.Text(_error, 13, secondary: true));
            s2.Children.Add(Kit.Button("Try Again", Load).Also(b => b.HorizontalAlignment = HorizontalAlignment.Left));
            body = Kit.Pad(s2, 12);
        }
        else body = Kit.Busy("Loading skill…");
        page.Children.Add(Kit.Section(null, [body]));
        if (Skill?.Provenance == "hub" && !model.ReadOnly)
        {
            UIElement action = model.Running.Contains(skill.Name) ? Kit.Busy("Uninstalling…")
                : Kit.Pad(Kit.Button("Uninstall", Uninstall).Also(b => b.Foreground = Kit.Critical));
            page.Children.Add(action);
        }
    }

    private async void Uninstall()
    {
        if (!await Kit.Confirm(Root, $"Uninstall {DisplayName.Title(skill.Name)}?", null, "Uninstall", destructive: true)) return;
        if (await model.Uninstall(skill.Name) && Host.Top == this) Pop();
    }
}

/// A toolset's page (ToolsetsSections.swift `ToolsetPageView`, ToolsetSetupSections.swift): what it does, its switch,
/// its tools by use, where it runs (providers), keys, one-time install, model, and the terminal's backends.
internal sealed class ToolsetScreen(CapabilitiesModel model, Toolset toolset) : Screen
{
    private readonly string _profile = model.Profile;
    private ToolsetConfig? _config;
    private bool _loading = true, _absent, _failed, _showAll;
    private string? _expanded, _selecting, _needsNous, _notice, _keyBusy, _settingModel, _settingBackend;
    private ToolModels? _models;
    private List<TerminalBackend>? _backends;
    private bool _backendsFailed;
    private (string State, string Line)? _install;

    public override string Title => toolset.Label;
    private Toolset? Current => model.Profile == _profile ? model.Toolsets?.FirstOrDefault(t => t.Name == toolset.Name) : null;
    private ToolProvider? Expanded => _config?.Providers.FirstOrDefault(p => p.Name == _expanded) ?? _config?.Providers.FirstOrDefault(p => p.IsActive) ?? _config?.Providers.FirstOrDefault();

    public override void Shown() { model.Changed += Render; _ = Load(); }
    public override void Hidden() => model.Changed -= Render;

    private async Task Load()
    {
        if (model.Api is not { } api) return;
        try
        {
            if (await api.ToolsetConfigAsync(toolset.Name, _profile) is { } cfg)
            {
                _config = cfg; _absent = false; _failed = false;
                _expanded ??= (cfg.Providers.FirstOrDefault(p => p.IsActive) ?? cfg.Providers.FirstOrDefault())?.Name;
                await LoadModels();
            }
            else _absent = true;
        }
        catch (Exception) { _failed = _config == null; }
        _loading = false;
        if (toolset.Name == "terminal") await LoadBackends();
        Render();
    }

    private async Task LoadModels()
    {
        if (model.Api is not { } api || Expanded is not { } p) { _models = null; return; }
        try { _models = await api.ToolModelsAsync(toolset.Name, p.Name, _profile); } catch (Exception) { _models = null; }
    }

    private async Task LoadBackends()
    {
        if (model.Api is not { } api) return;
        try { _backends = await api.TerminalBackendsAsync(_profile); _backendsFailed = false; }
        catch (Exception e) { if (_backends == null) _backendsFailed = !CapabilitiesWords.IsNotFound(e); }
    }

    private async void Flash(string text)
    {
        _notice = text;
        Render();
        await Task.Delay(TimeSpan.FromSeconds(4));
        if (_notice == text) { _notice = null; Render(); }
    }

    private async void Select(ToolProvider provider, string? capability = null)
    {
        if (model.Api is not { } api || _selecting != null || model.ReadOnly) return;
        _selecting = provider.Name; _expanded = provider.Name;
        Render();
        try
        {
            var nous = await api.SelectProviderAsync(toolset.Name, provider.Name, capability, _profile);
            _needsNous = nous ? provider.Name : null;
            await Load();
            await model.ReloadTools();
        }
        catch (Exception e) { Kit.Fail(Root, $"Couldn’t Select {provider.Name}", CapabilitiesWords.Detail(e)); }
        _selecting = null;
        Render();
    }

    private async void Expand(ToolProvider p) { _expanded = p.Name; _models = null; Render(); await LoadModels(); Render(); }

    private async void EditKey(ToolEnvVar v)
    {
        if (model.ReadOnly || model.Api is not { } api) return;
        switch (await SecretDialog.ShowAsync(Root, v.Prompt, v.Key, v.IsSet, v.Placeholder))
        {
            case SecretDialog.Result.Save(var value):
                _keyBusy = v.Key; Render();
                try { await api.SetEnvAsync(v.Key, value, _profile); await Load(); await model.ReloadTools(); }
                catch (Exception e) { Kit.Fail(Root, "Couldn’t Save the Key", CapabilitiesWords.Detail(e)); }
                _keyBusy = null; Render();
                break;
            case SecretDialog.Result.Remove:
                if (!await Kit.Confirm(Root, $"Remove {v.Key}?", $"{model.BotName} loses this key.", "Remove", destructive: true)) return;
                _keyBusy = v.Key; Render();
                try { await api.DeleteEnvAsync(v.Key, _profile); await Load(); await model.ReloadTools(); }
                catch (Exception e) { Kit.Fail(Root, $"Couldn’t Remove {v.Key}", CapabilitiesWords.Detail(e)); }
                _keyBusy = null; Render();
                break;
        }
    }

    private async void RunSetup(string key)
    {
        if (model.Api is not { } api || _install?.State == "running" || model.ReadOnly) return;
        _install = ("running", "");
        Render();
        ActionStatus? last = null;
        try
        {
            await foreach (var status in api.PostSetupAsync(toolset.Name, key, _profile))
            {
                last = status;
                _install = ("running", status.Lines.Count > 0 ? McpEntryMask.Phone.Text(status.Lines[^1][..Math.Min(300, status.Lines[^1].Length)]) : "");
                Render();
            }
        }
        catch (Exception) { _install = ("failed", ""); Render(); return; }
        _install = last?.ExitCode == 0 ? ("done", "") : ("failed", "");
        if (_install?.State == "done") { await Load(); await model.ReloadTools(); }
        Render();
    }

    private async void SetModel(ToolModel m)
    {
        if (model.Api is not { } api || _models is not { } models || _settingModel != null || model.ReadOnly) return;
        _settingModel = m.Id; Render();
        try
        {
            await api.SetToolModelAsync(toolset.Name, m.Id, models.Provider, _profile);
            _models = models with { Current = m.Id };
            Flash($"{m.Display} applies to new chats.");
        }
        catch (Exception e) { Kit.Fail(Root, $"Couldn’t Select {m.Display}", CapabilitiesWords.Detail(e)); }
        _settingModel = null; Render();
    }

    private async void Pick(TerminalBackend b)
    {
        if (b.Active || model.ReadOnly) return;
        if (!b.IsReady)
        {
            const string rest = "Chats that start after this change will have no terminal or file tools until setup is finished.";
            if (!await Kit.Confirm(Root, $"Select {b.Label} Anyway?", b.Detail.Length == 0 ? $"This backend isn’t set up yet. {rest}" : $"{b.Detail} {rest}", "Select Anyway")) return;
        }
        SetBackend(b);
    }

    private async void SetBackend(TerminalBackend b)
    {
        if (model.Api is not { } api || _settingBackend != null) return;
        _settingBackend = b.Name; Render();
        try
        {
            await api.SetTerminalBackendAsync(b.Name, _profile);
            await LoadBackends();
            Flash(b.Name == "local" ? "Terminal commands now run locally. Applies to new chats." : $"Terminal commands now run via {b.Label}. Applies to new chats.");
        }
        catch (Exception e) { Kit.Fail(Root, $"Couldn’t Select {b.Label}", CapabilitiesWords.Detail(e)); }
        _settingBackend = null; Render();
    }

    private static UIElement InUse() => Kit.Glyph(Kit.Check, 14, Kit.Accent).Also(g => AutomationProperties.SetName(g, "In use"));

    public override void Build(StackPanel page)
    {
        if (Current is not { } t) { page.Children.Add(Kit.Section(null, [Kit.Plain($"This tool isn’t on {model.BotName} any more.")])); return; }
        var top = new StackPanel { Spacing = 8 };
        top.Children.Add(Kit.Text(t.Description.Length == 0 ? "No description." : t.Description, 14, secondary: true));
        if (!t.Configured) top.Children.Add(new Border
        {
            Child = Kit.Text("Needs keys", 11, bold: true, color: Kit.Caution), Padding = new Thickness(10, 3, 10, 3), CornerRadius = new CornerRadius(10),
            Background = Kit.Brush("SubtleFillColorSecondaryBrush"), HorizontalAlignment = HorizontalAlignment.Left,
        });
        var first = new List<UIElement> { Kit.Pad(top, 12) };
        if (!model.ReadOnly) first.Add(Kit.SwitchRow($"On for {model.BotName}", t.Enabled, on => model.SetToolset(t, on), !model.ToolToggling.Contains(t.Name)));
        page.Children.Add(Kit.Section(null, first));
        if (_notice is { } n) page.Children.Add(Kit.Section(null, [Kit.Notice(n, Kit.Check)]));

        // Its tools, most used first.
        var sorted = t.Tools.OrderByDescending(x => model.ToolUsage?.GetValueOrDefault(x) ?? 0).ThenBy(x => x, StringComparer.Ordinal).ToList();
        if (sorted.Count > 0)
        {
            var rows = (_showAll ? sorted : sorted.Take(30)).Select(tool =>
            {
                var count = model.ToolUsage?.GetValueOrDefault(tool) ?? 0;
                return Kit.Row(tool, mono: true, trailing: count > 0 ? Kit.Text($"×{Toolset.Compact(count)}", 12, secondary: true) : null);
            }).ToList();
            if (sorted.Count > 30 && !_showAll) rows.Add(Kit.Row($"Show All {sorted.Count}", click: () => { _showAll = true; Render(); }));
            page.Children.Add(Kit.Section(CapabilitiesWords.Plural(sorted.Count, "Tool", "Tools"), rows));
        }

        Setup(page, t);
        page.Children.Add(Kit.Section(null, [], model.ReadOnly ? "This gateway is read-only." : CapabilitiesWords.ChangesApply));
    }

    private void Setup(StackPanel page, Toolset t)
    {
        if (_loading) page.Children.Add(Kit.Section(null, [Kit.Busy("Loading setup…")]));
        else if (_absent)
        {
            if (!t.Configured) page.Children.Add(Kit.Section(null, [Kit.Row("Open Keys", click: () => HermesHQ.Shell.Navigator.Open("settings", "keys"))]));
        }
        else if (_failed)
            page.Children.Add(Kit.Section(null, [Kit.Plain("Couldn’t load this tool’s setup."), Kit.Pad(Kit.Button("Try Again", () => _ = Load()))]));
        else if (_config is { } cfg)
        {
            RunsOn(page, cfg, t);
            if (Expanded is { } p)
            {
                Keys(page, p);
                if (p.PostSetup is { } key) OneTime(page, p, key);
                if (_models is { } models) Models(page, models, p);
            }
        }
        if (t.Name == "terminal") Backends(page);
        if (t.Name == "vision") page.Children.Add(Kit.Section(null, [], "Vision uses your auxiliary model configuration — the image-capable model is picked there, not per-provider here."));
        if (t.Name == "computer_use") page.Children.Add(Kit.Section(null, [], $"Computer Use needs permissions granted on the screen of {HostWord.Phrase}. Set it up in Hermes there."));
        if (t.Name == "browser") page.Children.Add(Kit.Section(null, [], $"To let {model.BotName} browse with your saved logins, turn on Use My Real Browser Profile in Hermes on {HostWord.Phrase}."));
    }

    private void RunsOn(StackPanel page, ToolsetConfig cfg, Toolset t)
    {
        if (!cfg.HasCategory) { page.Children.Add(Kit.Section(null, [], "This toolset has no provider options — enable it and it works with your current setup.")); return; }
        if (cfg.Providers.Count == 0) { page.Children.Add(Kit.Section("Runs On", [Kit.Plain("No providers are available for this toolset right now.")])); return; }
        var isWeb = t.Name == "web";
        var rows = new List<UIElement>();
        foreach (var p in cfg.Providers)
        {
            var words = new StackPanel { Spacing = 3 };
            var name = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            name.Children.Add(Kit.Text(p.Name, 14, bold: true));
            if (p.Badge.Length > 0) name.Children.Add(Kit.Badge(p.Badge, ConnectorTone.Quiet));
            words.Children.Add(name);
            if (p.Tag.Length > 0) words.Children.Add(Kit.Text(p.Tag, 13, secondary: true));
            if (p.StatusWord is { } sw) words.Children.Add(Kit.Text(sw, 12, color: p.Status == "ready" ? Kit.Success : Kit.Caution));
            if (isWeb)
            {
                var caps = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Margin = new Thickness(0, 4, 0, 0) };
                foreach (var kind in new[] { "search", "extract" }.Where(p.Capabilities.Contains))
                {
                    var word = kind == "search" ? "Search" : "Extract";
                    var inUse = (kind == "search" ? cfg.SearchBackend : cfg.ExtractBackend) is { } b && b == p.WebBackend;
                    if (inUse) caps.Children.Add(Kit.Text($"✓ {word} backend", 12, bold: true, color: Kit.Accent));
                    else if (!model.ReadOnly) caps.Children.Add(Kit.RowAction($"Use for {word}", () => Select(p, kind)).Also(b => b.IsEnabled = _selecting == null));
                }
                words.Children.Add(caps);
            }
            UIElement? end = _selecting == p.Name ? Kit.Spinner() : !isWeb && p.IsActive ? InUse() : null;
            rows.Add(Kit.Row("", subtitleElement: words, trailing: end, click: model.ReadOnly && !isWeb ? null : () => { if (isWeb || p.IsActive) Expand(p); else Select(p); }));
        }
        if (_needsNous is { } nn)
            rows.Add(Kit.Notice($"Sign in with your Nous account. {nn} is saved but will only work once you sign in with your Nous account.", Kit.Warning, Kit.Caution));
        page.Children.Add(Kit.Section("Runs On", rows, isWeb ? $"Search: {cfg.SearchBackend ?? "not set"} · Extract: {cfg.ExtractBackend ?? "not set"}" : null));
    }

    private void Keys(StackPanel page, ToolProvider p)
    {
        var rows = new List<UIElement>();
        if (p.EnvVars.Count == 0) rows.Add(Kit.Plain("No API key required."));
        foreach (var v in p.EnvVars)
        {
            UIElement end = _keyBusy == v.Key ? Kit.Spinner() : Kit.Text(v.IsSet ? "Set" : "Not Set", 14, color: v.IsSet ? Kit.Secondary : Kit.Caution, wrap: false);
            rows.Add(Kit.Row(v.Prompt, trailing: end, click: model.ReadOnly ? null : () => EditKey(v)));
            if (v.Url is { } url) rows.Add(Kit.Row("Get a Key", leading: Kit.Glyph(Kit.OpenOut, 12, Kit.Accent), click: () => Kit.Open(url)));
        }
        page.Children.Add(Kit.Section(p.EnvVars.Count == 0 ? "Keys" : $"Keys for {p.Name}", rows));
    }

    private void OneTime(StackPanel page, ToolProvider p, string key)
    {
        var s = new StackPanel { Spacing = 10 };
        var state = _install?.State;
        if (state == "done") s.Children.Add(Kit.Text($"Setup complete. {key} installed.", 14));
        else if (state == "failed") s.Children.Add(Kit.Text($"Setup finished with errors. Setting up {key} did not finish. Run it again, or check {HostWord.Phrase}.", 14));
        else s.Children.Add(Kit.Text(p.Status == "ready" ? "Installed. Run setup again only if something is broken."
            : $"This backend needs a one-time install ({key}). It runs on {HostWord.Phrase} and may take a few minutes.", 14, secondary: true));
        if (state == "running")
        {
            s.Children.Add(Kit.Busy("Installing…"));
            if (_install?.Line is { Length: > 0 } line) s.Children.Add(Kit.Text(line, 12, secondary: true, wrap: false).Also(x => x.FontFamily = Kit.Res<Microsoft.UI.Xaml.Media.FontFamily>("CodeFont")));
        }
        else if (!model.ReadOnly)
            s.Children.Add(Kit.Button(state == "failed" ? "Run Again" : p.Status == "ready" || state == "done" ? "Run Setup Again" : "Run Setup", () => RunSetup(key))
                .Also(b => b.HorizontalAlignment = HorizontalAlignment.Left));
        page.Children.Add(Kit.Section("One-Time Install", [Kit.Pad(s, 10)]));
    }

    private void Models(StackPanel page, ToolModels models, ToolProvider p)
    {
        var rows = models.Models.Select(m =>
        {
            UIElement? end = _settingModel == m.Id ? Kit.Spinner() : models.Current == m.Id ? InUse() : null;
            return Kit.Row(m.Id == models.Fallback ? $"{m.Display} · default" : m.Display, m.Caption, trailing: end,
                click: p.IsActive && !model.ReadOnly ? () => SetModel(m) : null);
        });
        page.Children.Add(Kit.Section($"Model · {CapabilitiesWords.Plural(models.Models.Count, "model", "models")}", rows,
            p.IsActive ? null : "Select this backend first to change its model."));
    }

    private void Backends(StackPanel page)
    {
        if (_backends is { } list)
        {
            var active = list.FirstOrDefault(b => b.Active);
            var rows = list.Select(b =>
            {
                var words = new StackPanel { Spacing = 3 };
                if (b.Description.Length > 0) words.Children.Add(Kit.Text(b.Description, 13, secondary: true));
                words.Children.Add(Kit.Text(b.IsReady ? "Ready" : b.Status == "unavailable" ? "Unavailable" : "Needs setup", 12,
                    color: b.IsReady ? Kit.Success : b.Status == "unavailable" ? Kit.Critical : Kit.Caution));
                if (!b.IsReady && b.Detail.Length > 0) words.Children.Add(Kit.Text(b.Detail, 12, secondary: true));
                UIElement? end = _settingBackend == b.Name ? Kit.Spinner() : b.Active ? InUse() : null;
                return Kit.Row(b.Label, subtitleElement: words, trailing: end, boldTitle: true, click: model.ReadOnly ? null : () => Pick(b));
            }).ToList();
            if (active is { IsReady: false } a && a.Name != "local" && !model.ReadOnly && list.FirstOrDefault(b => b.Name == "local") is { } local)
                rows.Add(Kit.Row("Use Local", click: () => SetBackend(local)));
            page.Children.Add(Kit.Section("Execution Backend", rows, footerElement: active is { IsReady: false }
                ? Kit.Text("This backend is currently selected without full setup — commands will fail until setup is complete.", 12, color: Kit.Critical) : null));
        }
        else if (_backendsFailed)
            page.Children.Add(Kit.Section("Execution Backend", [Kit.Plain("Couldn’t load terminal backends"), Kit.Pad(Kit.Button("Try Again", async () => { await LoadBackends(); Render(); }))]));
    }
}

/// A key editor (`SecretEntrySheet`): a password box with Paste, Save, and Remove when one is stored. The value is never
/// prefilled, logged or kept after the dialog closes.
internal static class SecretDialog
{
    public abstract record Result
    {
        public sealed record Save(string Value) : Result;
        public sealed record Remove : Result;
        public sealed record Cancel : Result;
    }

    public static async Task<Result> ShowAsync(XamlRoot? root, string title, string name, bool isSet, string? placeholder)
    {
        var box = new PasswordBox { PlaceholderText = placeholder ?? (isSet ? "Enter a new value" : "Paste the key"), Width = 320 };
        AutomationProperties.SetName(box, name);
        var paste = Kit.Button("Paste", async () => { if (await Kit.Paste() is { } t) box.Password = t; });
        var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        line.Children.Add(box);
        line.Children.Add(paste);
        var body = new StackPanel { Spacing = 8 };
        body.Children.Add(Kit.Text(name, 12, bold: true, color: Kit.Secondary));
        body.Children.Add(line);
        body.Children.Add(Kit.Text(isSet ? $"A value is stored on {HostWord.Phrase}. Saving replaces it." : $"Stored on {HostWord.Phrase} for this bot.", 12, secondary: true));
        var d = new ContentDialog
        {
            Title = title, Content = body, PrimaryButtonText = "Save", CloseButtonText = "Cancel", SecondaryButtonText = isSet ? "Remove" : "",
            DefaultButton = ContentDialogButton.Primary, IsPrimaryButtonEnabled = false,
        };
        box.PasswordChanged += (_, _) => d.IsPrimaryButtonEnabled = box.Password.Trim().Length > 0;
        var r = await Kit.Show(root, d);
        var value = box.Password.Trim();
        box.Password = "";
        return r switch
        {
            ContentDialogResult.Primary when value.Length > 0 => new Result.Save(value),
            ContentDialogResult.Secondary => new Result.Remove(),
            _ => new Result.Cancel(),
        };
    }
}

/// A connector's page (ConnectorPageController.swift): its state and why, Sign In / Try Again, its switch, its tools
/// with a switch each (saved together, remove-then-add), Advanced.
internal sealed class ConnectorScreen(CapabilitiesModel model, McpServer server) : Screen
{
    private enum ToolsState { Idle, Reading, Failed, Loaded }
    private readonly string _profile = model.Profile;
    private ToolsState _tools = ToolsState.Idle;
    private List<McpTool> _list = [];
    public JsonNode? Entry { get; private set; }
    public JsonNode? LostEntry { get; private set; }
    private bool _redacted, _saving, _checking, _signingIn, _needsAuthProbe;
    private string? _probeError;
    private HashSet<string> _savedOff = [], _draftOff = [];
    private string _search = "";
    private CancellationTokenSource? _signIn;

    public string Name => server.Name;
    public string Profile => _profile;
    public CapabilitiesModel Model => model;
    public override string Title => Server is { } s ? model.TitleOf(s) : model.TitleOf(server);
    public McpServer? Server => model.Profile == _profile ? model.Servers?.FirstOrDefault(s => s.Name == server.Name) : null;
    public bool IsPlugin => Server?.Source == "plugin";
    private bool CanEditTools => !IsPlugin && !model.ReadOnly && !_redacted && Entry != null;
    private bool Dirty => !_draftOff.SetEquals(_savedOff);

    private enum Status { Ok, Probing, Off, NeedsAuth, Error, Unknown }

    private Status State
    {
        get
        {
            if (Server is not { } s) return Status.Unknown;
            if (!s.Enabled) return Status.Off;
            if (_needsAuthProbe || ServerIssues.KindOf(s) == IssueKind.NeedsAuth) return Status.NeedsAuth;
            return s.Status switch { "connected" => Status.Ok, "connecting" => Status.Probing, "failed" => Status.Error, _ => Status.Unknown };
        }
    }

    private bool CanAuthenticate
    {
        get
        {
            if (Server is not { } s || IsPlugin || model.ReadOnly || (s.Url == null && s.Transport != "http") || s.HasHeaders) return false;
            if (s.Auth == "oauth") return State is Status.NeedsAuth or Status.Error;
            return string.IsNullOrEmpty(s.Auth) && State == Status.NeedsAuth;
        }
    }

    private string? Reason => Server is not { } s ? null : State switch
    {
        Status.Off => "Turn it on to read the tools it brings.",
        Status.NeedsAuth => "Sign in to let this server answer.",
        Status.Error => ConnectorTitle.FailureDetail(_probeError ?? "", s.Command != null || s.Transport == "stdio", s.Url != null || s.Transport == "http"),
        _ => null,
    };

    public override IEnumerable<MenuFlyoutItemBase> Menu() { yield return Kit.Item("Refresh Tools", Kit.Refresh, Check); }

    public override async void Shown()
    {
        model.Changed += Render;
        await ReadEntry();
        if (_tools == ToolsState.Idle) await ReadTools();
    }

    public override void Hidden() { model.Changed -= Render; _signIn?.Cancel(); }

    public override async Task<bool> LeaveAsync()
    {
        if (_saving) return false;
        if (!Dirty || !CanEditTools) return true;
        var d = new ContentDialog
        {
            Title = "Discard Changes?", Content = Kit.Text($"Your changes to {Name}’s tools haven’t been saved.", 14),
            PrimaryButtonText = "Discard Changes", CloseButtonText = "Keep Editing", DefaultButton = ContentDialogButton.Close,
        };
        if (await Kit.Show(Root, d) != ContentDialogResult.Primary) return false;
        _draftOff = [.. _savedOff];
        return true;
    }

    private async Task ReadEntry()
    {
        if (model.Api is not { } api || IsPlugin) return;
        try
        {
            Entry = await api.McpEntryAsync(Name, _profile);
            _redacted = Entry != null && McpToolFilter.LooksRedacted(Entry);
            ApplyRules();
        }
        catch (Exception) { }
        Render();
    }

    private void ApplyRules()
    {
        var off = _list.Select(t => t.Name).Where(n => !McpToolFilter.IsEnabled(Entry, n)).ToHashSet();
        var wasDirty = Dirty;
        _savedOff = off;
        if (!wasDirty) _draftOff = [.. off];
    }

    private async Task ReadTools()
    {
        if (model.Api is not { } api || Server is not { Enabled: true } || State == Status.NeedsAuth) return;
        _tools = ToolsState.Reading;
        Render();
        try
        {
            var probe = await api.McpTestAsync(Name, _profile);
            if (probe.OauthNeeded) { _needsAuthProbe = true; _tools = ToolsState.Idle; Render(); return; }
            _needsAuthProbe = false;
            if (probe.Ok)
            {
                _list = [.. probe.Tools]; _probeError = null; _tools = ToolsState.Loaded;
                ApplyRules();
                CapabilitiesServices.Issues.Clear(_profile, Name);
            }
            else { _probeError = probe.Error; _tools = ToolsState.Failed; }
        }
        catch (Exception e) { _probeError = CapabilitiesWords.Detail(e); _tools = ToolsState.Failed; }
        Render();
    }

    private async void Check()
    {
        if (_checking) return;
        _checking = true; Render();
        await ReadTools();
        await model.ReloadServers();
        _checking = false; Render();
    }

    private async void SetEnabled(bool on)
    {
        if (Server is not { } s) return;
        model.SetMcp(s, on);
        if (on) { await Task.Delay(1000); await ReadTools(); }
        else { _list = []; _tools = ToolsState.Idle; _needsAuthProbe = false; Render(); }
    }

    private async void SignIn()
    {
        if (model.Api is not { } api || _signingIn) return;
        _signingIn = true; Render();
        try
        {
            _signIn = new CancellationTokenSource();
            var flow = new McpSignIn(api) { AllowLoopbackHttp = CapabilitiesServices.LoopbackGateway };
            var outcome = await flow.RunAsync(Name, _profile, url => { Kit.Open(url.ToString()); return true; }, _signIn.Token);
            _signingIn = false;
            App.Window?.BringToFront();
            switch (outcome)
            {
                case McpSignIn.Outcome.SignedIn:
                    _needsAuthProbe = false;
                    CapabilitiesServices.Issues.Clear(_profile, Name);
                    await api.ReloadMcpAsync();
                    await model.ReloadServers();
                    await ReadTools();
                    break;
                case McpSignIn.Outcome.Failed(var reason):
                    Kit.Fail(Root, $"Couldn’t Sign In to {Name}", reason);
                    break;
            }
        }
        catch (Exception ex)
        {
            _signingIn = false;
            HermesHQ.Services.AppLog.Error("capabilities", ex);
        }
        Render();
    }

    private async void Save()
    {
        if (model.Api is not { } api || !Dirty || _saving || !CanEditTools) return;
        _saving = true; Render();
        var disabled = _list.Select(t => t.Name).Where(_draftOff.Contains).ToList();
        var discovered = _list.Select(t => t.Name).ToList();
        var before = Entry;
        try
        {
            switch (await api.SaveToolRulesAsync(Name, disabled, discovered, _profile))
            {
                case ToolRulesOutcome.Saved or ToolRulesOutcome.Unchanged:
                    _savedOff = [.. _draftOff];
                    await ReadEntry();
                    await model.ReloadServers();
                    break;
                case ToolRulesOutcome.Gone:
                    Kit.Fail(Root, "Couldn’t Save", "This connector is no longer on your gateway.");
                    await model.ReloadServers();
                    if (Host.Top == this) Pop();
                    break;
                case ToolRulesOutcome.RolledBack(var reason):
                    Kit.Fail(Root, "Couldn’t Save", $"Those tool rules were not saved. {McpEntryMask.Phone.Text(reason)}");
                    await model.ReloadServers();
                    break;
                case ToolRulesOutcome.Lost:
                    LostEntry = before;
                    Kit.Fail(Root, "Couldn’t Save", $"{Name} was taken off {model.BotName} while saving and could not be put back. Add it again under Connectors.");
                    await model.ReloadServers();
                    break;
            }
        }
        catch (CapabilityException e)
        {
            if (e.Reason.Contains("can be changed on the computer running Hermes")) _redacted = true;
            Kit.Fail(Root, "Couldn’t Save", e.Reason);
        }
        catch (Exception e) { Kit.Fail(Root, "Couldn’t Save", $"Those tool rules were not saved. {McpEntryMask.Phone.Text(CapabilitiesWords.Detail(e))}"); }
        _saving = false;
        Render();
    }

    public async Task<bool> Remove()
    {
        if (model.Api is not { } api) return false;
        try
        {
            await api.McpRemoveAsync(Name, _profile);
            await api.ReloadMcpAsync();
            CapabilitiesServices.Issues.Clear(_profile, Name);
            await model.ReloadServers();
            return true;
        }
        catch (Exception e)
        {
            Kit.Fail(Root, $"Couldn’t Remove {Name}", McpEntryMask.Phone.Text(CapabilitiesWords.Detail(e)));
            return false;
        }
    }

    public override UIElement? Bottom
    {
        get
        {
            if (!Dirty) return null;
            var g = new Grid { ColumnSpacing = 12, Padding = new Thickness(24, 10, 24, 10), Background = Kit.Brush("LayerFillColorDefaultBrush") };
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var back = _savedOff.Except(_draftOff).Count();
            g.Children.Add(Kit.Text($"{CapabilitiesWords.Plural(_draftOff.Count, "tool", "tools")} off, {(back == 0 ? "none" : back.ToString())} back on", 12)
                .Also(t => t.VerticalAlignment = VerticalAlignment.Center));
            var discard = Kit.Button("Discard", () => { _draftOff = [.. _savedOff]; Render(); }, enabled: !_saving);
            Grid.SetColumn(discard, 1);
            g.Children.Add(discard);
            var save = Kit.Button(_saving ? "Saving…" : "Save", Save, accent: true, enabled: !_saving);
            Grid.SetColumn(save, 2);
            g.Children.Add(save);
            return g;
        }
    }

    private (string, ConnectorTone) Words(McpServer s) => State switch
    {
        Status.Ok => ($"Connected · {CapabilitiesWords.Plural(s.Tools ?? _list.Count, "tool", "tools")}", ConnectorTone.Good),
        Status.Probing => ("Connecting…", ConnectorTone.Busy),
        Status.Off => ("Off", ConnectorTone.Quiet),
        Status.NeedsAuth => ("Needs sign-in", ConnectorTone.Warn),
        Status.Error => ("Couldn’t connect", ConnectorTone.Bad),
        _ => ("Starts when needed", ConnectorTone.Busy),
    };

    public override void Build(StackPanel page)
    {
        if (Server is not { } s) { page.Children.Add(Kit.Section(null, [Kit.Plain("This connector is no longer on your gateway.")])); return; }
        var entry = model.CatalogEntry(s);
        var kind = IsPlugin ? (s.Plugin is { } pl ? $"From the {DisplayName.Title(pl)} plugin" : null)
            : s.Url is { } u && Uri.TryCreate(u, UriKind.Absolute, out var uri) ? uri.Host : null;
        page.Children.Add(Kit.Header(model.TitleOf(s), Kit.Logo(null, s.Name, 56), Words(s), kind, entry?.Description ?? ""));

        var state = State;
        var signIn = (state == Status.NeedsAuth || (state == Status.Error && CanAuthenticate)) && (CanAuthenticate || state == Status.NeedsAuth) && !model.ReadOnly && !IsPlugin;
        var retry = state is Status.Error or Status.Unknown;
        if (Reason != null || signIn || retry)
        {
            var rows = new List<UIElement>();
            if (Reason is { } r) rows.Add(Kit.Plain(r));
            if (signIn) rows.Add(Kit.Row(_signingIn ? "Signing in…" : "Sign In", click: _signingIn ? null : SignIn, subtitleColor: Kit.Accent));
            if (retry) rows.Add(Kit.Row(_checking ? "Checking…" : state == Status.Error ? "Try Again" : "Check Now", click: _checking ? null : Check));
            page.Children.Add(Kit.Section(null, rows));
        }
        if (!model.ReadOnly && !IsPlugin)
            page.Children.Add(Kit.Section(null, [Kit.SwitchRow($"On for {model.BotName}", s.Enabled, SetEnabled, !model.McpToggling.Contains(s.Name))]));
        Tools(page, s);
        var more = new List<UIElement> { Kit.Row("Advanced", "The configuration and logs", click: () => Push(new ConnectorAdvancedScreen(this)), chevron: true) };
        if (IsPlugin) more.Add(Kit.Row("Open Plugins", click: () => Push(new ListScreen(CapabilitiesTab.Plugins, _profile, false))));
        page.Children.Add(Kit.Section(null, more, IsPlugin && s.Plugin is { } p2 ? $"Provided by the {p2} plugin." : null));
    }

    private void Tools(StackPanel page, McpServer s)
    {
        var rows = new List<UIElement>();
        var title = model.TitleOf(s);
        if (!s.Enabled)
        {
            var w = new StackPanel { Spacing = 3 };
            w.Children.Add(Kit.Text($"{title} is off.", 14));
            w.Children.Add(Kit.Text("Turn it on with the switch above to read the tools it brings.", 13, secondary: true));
            rows.Add(Kit.Pad(w));
        }
        else if (State == Status.NeedsAuth) rows.Add(Kit.Plain($"Sign in to {title} to read its tools."));
        else switch (_tools)
        {
            case ToolsState.Idle or ToolsState.Reading: rows.Add(Kit.Busy("Reading the tool list")); break;
            case ToolsState.Failed: rows.Add(Kit.Plain("Tool list unavailable.")); break;
            default:
                var editable = CanEditTools;
                var toolRowsHost = new StackPanel();
                void FillToolRows()
                {
                    toolRowsHost.Children.Clear();
                    if (editable && _search.Length == 0 && _list.Count > 0)
                        toolRowsHost.Children.Add(Kit.SwitchRow("All Tools", _draftOff.Count == 0, on => { _draftOff = on ? [] : [.. _list.Select(t => t.Name)]; Render(); }, !_saving, bold: true));
                    var q = _search.Trim();
                    var shown = q.Length == 0 ? _list : _list.Where(t => t.Name.Contains(q, StringComparison.OrdinalIgnoreCase) || t.Description.Contains(q, StringComparison.OrdinalIgnoreCase)).ToList();
                    if (shown.Count == 0) toolRowsHost.Children.Add(Kit.Plain(_list.Count == 0 ? "This connector brings no tools." : "No tool matches these filters."));
                    foreach (var t in shown)
                    {
                        UIElement? end = editable
                            ? Kit.Switch(!_draftOff.Contains(t.Name), t.Name, on => { if (on) _draftOff.Remove(t.Name); else _draftOff.Add(t.Name); Render(); }, !_saving)
                            : !McpToolFilter.IsEnabled(Entry, t.Name) ? Kit.Text("Off", 13, secondary: true) : null;
                        toolRowsHost.Children.Add(Kit.Row(t.Name, t.Description, trailing: end, mono: true));
                    }
                }
                if (_list.Count > 8)
                {
                    var box = new TextBox { PlaceholderText = $"Search {_list.Count} tools", Text = _search };
                    box.TextChanged += (_, _) => { if (_search != box.Text) { _search = box.Text; FillToolRows(); } };
                    rows.Add(Kit.Pad(box, 8));
                }
                FillToolRows();
                rows.Add(toolRowsHost);
                break;
        }
        var header = _tools == ToolsState.Loaded && s.Enabled ? CapabilitiesWords.Plural(_list.Count, "Tool", "Tools") : "Tools";
        page.Children.Add(Kit.Section(header, rows, _redacted ? $"This connector’s tool list can be changed on {HostWord.Phrase}." : null));
    }
}

/// Connector › Advanced: the entry read-only with every secret hidden, Copy, Logs, Remove.
internal sealed class ConnectorAdvancedScreen(ConnectorScreen connector) : Screen
{
    private string? _config;
    private bool _missing, _failed, _loading = true;
    public override string Title => "Advanced";

    public override void Shown() { if (_loading) Load(); }

    private async void Load()
    {
        _loading = true; _failed = false; Render();
        if (connector.LostEntry is { } lost) _config = McpEntryMask.Phone.ConfigurationText(connector.Name, lost);
        else if (connector.IsPlugin) _missing = true;
        else if (connector.Model.Api is { } api)
        {
            try
            {
                if (await api.McpEntryAsync(connector.Name, connector.Profile) is { } entry) _config = McpEntryMask.Phone.ConfigurationText(connector.Name, entry);
                else _missing = true;
            }
            catch (Exception) { _failed = true; }
        }
        _loading = false;
        Render();
    }

    public override void Build(StackPanel page)
    {
        var rows = new List<UIElement>();
        if (_loading) rows.Add(Kit.Busy(""));
        else if (_config is { } text)
        {
            var code = new TextBlock
            {
                Text = text, FontFamily = Kit.Res<Microsoft.UI.Xaml.Media.FontFamily>("CodeFont"), FontSize = 12, IsTextSelectionEnabled = true,
                TextWrapping = TextWrapping.NoWrap,
            };
            rows.Add(Kit.Pad(new ScrollViewer { Content = code, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled, HorizontalScrollMode = ScrollMode.Enabled }));
            rows.Add(Kit.Row("Copy", click: () => Kit.Copy(text)));
        }
        else if (_missing)
            rows.Add(Kit.Plain("This connector is not in your gateway’s configuration." + (connector.Server?.Plugin is { } p ? $" It comes from the {p} plugin." : "")));
        else if (_failed) { rows.Add(Kit.Plain("Couldn’t load the configuration.")); rows.Add(Kit.Pad(Kit.Button("Try Again", Load))); }
        page.Children.Add(Kit.Section("Configuration", rows, CapabilitiesWords.ConfigFooter));
        page.Children.Add(Kit.Section(null, [Kit.Row("Logs", chevron: true, click: () => Push(new ConnectorLogsScreen(connector)))]));
        if (!connector.IsPlugin && !connector.Model.ReadOnly && connector.Server is { } s)
        {
            var shown = connector.Model.TitleOf(s);
            page.Children.Add(Kit.Pad(Kit.Button($"Remove {shown}", async () =>
            {
                if (!await Kit.Confirm(Root, $"Remove {shown}?", CapabilitiesWords.RemoveMessage(connector.Model.BotName), "Remove", destructive: true)) return;
                if (await connector.Remove()) Host.PopTo(x => x is ListScreen);
            }).Also(b => b.Foreground = Kit.Critical)));
        }
    }
}

/// A connector's logs, followed live (ConnectorLogsController): its last run's section of the MCP log for a command
/// connector, else the agent log's lines that name it; every line masked.
internal sealed class ConnectorLogsScreen(ConnectorScreen connector) : Screen
{
    private enum State { Loading, Lines, Empty, Failed, Unsupported }
    private State _state = State.Loading;
    private List<string> _lines = [];
    private bool _stale;
    private int _failures;
    private CancellationTokenSource? _loop;
    public override string Title => "Logs";

    public override IEnumerable<MenuFlyoutItemBase> Menu() { yield return Kit.Item("Copy", "", () => { if (_lines.Count > 0) Kit.Copy(string.Join("\n", _lines)); }); }

    public override void Shown()
    {
        _loop?.Cancel();
        var cts = _loop = new CancellationTokenSource();
        _ = Run(cts.Token);
    }

    public override void Hidden() => _loop?.Cancel();

    private async Task Run(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested && _state != State.Unsupported)
        {
            await Tick();
            try { await Task.Delay(TimeSpan.FromSeconds(_failures >= 5 ? 10 : 2), ct); } catch (OperationCanceledException) { return; }
        }
    }

    private async Task Tick()
    {
        if (connector.Model.Api is not { } api) return;
        var stdio = connector.Server?.Command != null || connector.Server?.Transport == "stdio";
        try
        {
            List<string>? raw = null;
            if (stdio) raw = ConnectorLogs.Section(await api.LogsAsync("mcp", 500, null, connector.Profile), connector.Name);
            raw ??= await api.LogsAsync("agent", 300, connector.Name, connector.Profile);
            var masked = ConnectorLogs.Clean(raw);
            var changed = !masked.SequenceEqual(_lines) || _stale || _state is not (State.Lines or State.Empty);
            _lines = masked;
            _state = masked.Count == 0 ? State.Empty : State.Lines;
            _stale = false; _failures = 0;
            if (changed) Render();
        }
        catch (Hermes.Core.Net.GatewayException e) when (e is { Code: "http", Status: 400 or 404 })
        {
            _state = State.Unsupported;
            Render();
        }
        catch (Exception)
        {
            _failures++;
            if (_lines.Count == 0) _state = State.Failed; else _stale = true;
            Render();
        }
    }

    public override void Build(StackPanel page)
    {
        switch (_state)
        {
            case State.Loading: page.Children.Add(Kit.Busy("")); break;
            case State.Empty: page.Children.Add(Kit.Plain("No output yet.")); break;
            case State.Unsupported: page.Children.Add(Kit.Plain("This gateway doesn’t keep logs for connectors.")); break;
            case State.Failed:
                page.Children.Add(Kit.Plain("Couldn’t load the logs."));
                page.Children.Add(Kit.Pad(Kit.Button("Try Again", () => { _failures = 0; _state = State.Loading; Shown(); })));
                break;
            default:
                var text = new TextBlock
                {
                    Text = string.Join("\n", _lines), FontFamily = Kit.Res<Microsoft.UI.Xaml.Media.FontFamily>("CodeFont"), FontSize = 12,
                    IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap,
                };
                page.Children.Add(text);
                if (_stale) page.Children.Add(Kit.Text("Not updating. Trying again…", 12, secondary: true).Also(t => t.Margin = new Thickness(0, 6, 0, 0)));
                break;
        }
    }
}

/// An app from Hermes's catalog (CatalogAppController): what it is, its keys, Install for the bot, the details.
internal sealed class CatalogAppScreen(CapabilitiesModel model, McpCatalogEntry entry) : Screen
{
    private readonly Dictionary<string, string> _values = [];
    private readonly string _profile = model.Profile;
    private bool _installing;
    private string? _error;
    public override string Title => entry.Title;

    private IEnumerable<string> Missing => entry.RequiredEnv.Where(k => k.Required && (_values.GetValueOrDefault(k.Name) ?? "").Trim().Length == 0).Select(k => k.Prompt);
    private bool CanInstall => !_installing && !model.ReadOnly && !Missing.Any();

    private async void Install()
    {
        if (!CanInstall || model.Api is not { } api) return;
        _installing = true; _error = null; Render();
        var env = _values.Where(p => p.Value.Trim().Length > 0).ToDictionary(p => p.Key, p => p.Value.Trim());
        try { await api.InstallCatalogAsync(entry.Name, env, _profile); }
        catch (Exception e) { _installing = false; _error = CapabilitiesWords.Detail(e); Render(); return; }
        _installing = false;
        await model.ReloadServers();
        await model.ReloadCatalog();
        model.ServersNotice = $"{entry.Title} is installed for {model.BotName}." + (entry.NeedsSignIn ? " Sign in to it below to finish." : "");
        model.Notify();
        Pop();
        if (model.Profile == _profile && model.Servers?.FirstOrDefault(s => s.Name == entry.Name) is { } server) Push(new ConnectorScreen(model, server));
    }

    public override void Build(StackPanel page)
    {
        page.Children.Add(Kit.Header(entry.Title, Kit.Tile(Kit.SymbolFor(entry.Name), 56), null, "From Hermes’s app catalog", entry.Description));
        if (entry.RequiredEnv.Count > 0)
        {
            var rows = entry.RequiredEnv.Select(k =>
            {
                var s = new StackPanel { Spacing = 4 };
                s.Children.Add(Kit.Text(k.Prompt, 13, secondary: true));
                var hint = k.Required ? "Required" : "Optional";
                if (McpCatalog.IsAddress(k))
                {
                    var box = new TextBox { PlaceholderText = hint, Text = _values.GetValueOrDefault(k.Name) ?? "", IsSpellCheckEnabled = false };
                    box.TextChanged += (_, _) => { _values[k.Name] = box.Text; Render(); };
                    AutomationProperties.SetName(box, k.Prompt);
                    s.Children.Add(box);
                }
                else
                {
                    var box = new PasswordBox { PlaceholderText = hint, Password = _values.GetValueOrDefault(k.Name) ?? "" };
                    box.PasswordChanged += (_, _) => { var was = Missing.Any(); _values[k.Name] = box.Password; if (was != Missing.Any()) Render(); };
                    AutomationProperties.SetName(box, k.Prompt);
                    s.Children.Add(box);
                }
                return (UIElement)Kit.Pad(s);
            });
            page.Children.Add(Kit.Section(entry.RequiredEnv.Count == 1 ? "Key" : "Keys", rows, CapabilitiesWords.KeysFooter(model.BotName)));
        }
        var install = new StackPanel { Spacing = 10, Margin = new Thickness(0, 0, 0, 18) };
        var face = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center };
        if (_installing) face.Children.Add(Kit.Spinner());
        face.Children.Add(Kit.Text(_installing ? (entry.NeedsBuild ? "Installing… (this can take a few minutes)" : "Installing…") : $"Install for {model.BotName}", 14, bold: true));
        var b = new Button { Content = face, HorizontalAlignment = HorizontalAlignment.Stretch, Style = Kit.Res<Style>("AccentButtonStyle"), IsEnabled = CanInstall, MinHeight = 36 };
        AutomationProperties.SetName(b, $"Install for {model.BotName}");
        b.Click += (_, _) => Install();
        install.Children.Add(b);
        if (_error != null) install.Children.Add(Kit.Text(_error, 13, color: Kit.Critical));
        else if (model.ReadOnly) install.Children.Add(Kit.Text("This gateway is read-only. Install from a gateway you can change.", 13, secondary: true));
        else if (entry.NeedsSignIn) install.Children.Add(Kit.Text($"After it installs, you’ll sign in to {entry.Title} in your browser.", 13, secondary: true).Also(t => t.TextAlignment = TextAlignment.Center));
        page.Children.Add(install);

        var details = new List<UIElement>();
        UIElement Detail(string label, string value)
        {
            var s = new StackPanel { Spacing = 3 };
            s.Children.Add(Kit.Text(label, 13, secondary: true));
            s.Children.Add(Kit.Text(value, 14).Also(t => t.IsTextSelectionEnabled = true));
            return Kit.Pad(s);
        }
        if (entry.Url is { } url && entry.Transport == "http") details.Add(Detail("Connects to", Uri.TryCreate(url, UriKind.Absolute, out var u) ? u.Host : url));
        else if (entry.Command is { } cmd) details.Add(Detail($"Runs on {HostWord.Phrase}", string.Join(" ", new[] { cmd }.Concat(entry.Args))));
        if (entry.InstallUrl is { } repo) details.Add(Detail("Downloads and builds", repo));
        details.Add(Detail("Sign-in", entry.NeedsSignIn ? "In your browser" : entry.RequiredEnv.Count == 0 ? "None needed" : "With the key above"));
        if (entry.Source.StartsWith("https://")) details.Add(Kit.Row("Learn More", trailing: Kit.Glyph(Kit.OpenOut, 12, Kit.Tertiary), click: () => Kit.Open(entry.Source), subtitleColor: Kit.Accent));
        page.Children.Add(Kit.Section("Details", details, "Reviewed and approved by Nous for Hermes’s app catalog."));
    }
}

/// See All Apps: every catalog app not on this bot, A–Z, with its own search.
internal sealed class CatalogBrowseScreen(CapabilitiesModel model) : Screen
{
    public override string Title => "All Apps";
    public override string? SearchPrompt => CapabilitiesWords.SearchApps(model.CatalogAvailable.Count);

    public override void Build(StackPanel page)
    {
        var all = model.CatalogAvailable.OrderBy(e => e.Title, StringComparer.CurrentCultureIgnoreCase).ToList();
        var shown = all.Where(e => e.Matches(Query)).ToList();
        var rows = new List<UIElement>();
        if (shown.Count == 0) rows.Add(Kit.Plain(all.Count == 0 ? $"Every app here is installed for {model.BotName}." : $"No app matches “{Query}”."));
        rows.AddRange(shown.Select(e => ListScreen.CatalogRow(model, e, this)));
        page.Children.Add(Kit.Section(null, rows, CapabilitiesWords.CatalogFooter(model.BotName)));
    }
}
