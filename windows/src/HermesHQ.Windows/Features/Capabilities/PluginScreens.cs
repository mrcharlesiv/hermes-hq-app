using System.Globalization;
using System.Text.Json.Nodes;
using Hermes.Core;
using Hermes.Core.Capabilities;
using Hermes.Core.Gateways;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;

namespace HermesHQ.Features.Capabilities;

/// A plugin's page (PluginsSections.swift `PluginPageView`): what it is, its switch, Update / Uninstall, its settings
/// (secrets go to the bot's env, the rest through `plugins.manage settings`).
internal sealed class PluginScreen(CapabilitiesModel model, PluginInfo plugin) : Screen
{
    private readonly string _profile = model.Profile;
    private readonly Dictionary<string, string> _texts = [], _secrets = [];
    private readonly Dictionary<string, bool> _bools = [];
    private bool _busy, _saving, _reset;
    private string? _notice, _fieldError;

    public override string Title => plugin.Title;
    private PluginInfo? Current => model.Profile == _profile ? model.Plugins?.FirstOrDefault(p => p.Name == plugin.Name) : null;
    private bool CanEdit => !model.ReadOnly && Current?.Key != null;

    public override void Shown() { model.Changed += Render; if (!_reset) { Reset(plugin); _reset = true; } }
    public override void Hidden() => model.Changed -= Render;

    public static string TextOf(PluginField f)
    {
        if ((f.Value ?? f.Fallback) is not { } v) return f.Type == "enum" ? f.Choices.FirstOrDefault() ?? "" : "";
        return v switch
        {
            JsonValue jv when jv.TryGetValue(out string? s) => s,
            JsonValue jv when jv.GetValueKind() == System.Text.Json.JsonValueKind.Number && jv.TryGetValue(out double n) =>
                n == Math.Round(n) && Math.Abs(n) < 1e15 ? ((long)n).ToString(CultureInfo.InvariantCulture) : n.ToString(CultureInfo.InvariantCulture),
            JsonValue jv when jv.TryGetValue(out bool b) => b ? "true" : "false",
            _ => v.ToJsonString(new System.Text.Json.JsonSerializerOptions { WriteIndented = true }),
        };
    }

    private static bool BoolOf(PluginField f) => (f.Value ?? f.Fallback) is JsonValue jv && jv.TryGetValue(out bool b) && b;

    private void Reset(PluginInfo p)
    {
        _texts.Clear(); _bools.Clear();
        foreach (var f in p.Schema)
        {
            if (f.Type == "boolean") _bools[f.Key] = BoolOf(f);
            else if (f.Type != "secret") _texts[f.Key] = TextOf(f);
        }
    }

    /// The changed non-secret values, or the first field's error.
    private (JsonObject? Values, string? Error) Changes(PluginInfo p)
    {
        var o = new JsonObject();
        foreach (var f in p.Schema)
        {
            switch (f.Type)
            {
                case "boolean":
                    var now = _bools.GetValueOrDefault(f.Key);
                    if (now != BoolOf(f)) o[f.Key] = now;
                    break;
                case "string" or "enum":
                    var t = _texts.GetValueOrDefault(f.Key) ?? "";
                    if (t != TextOf(f)) o[f.Key] = t;
                    break;
                case "number":
                    var n = (_texts.GetValueOrDefault(f.Key) ?? "").Trim();
                    if (n == TextOf(f)) break;
                    if (!double.TryParse(n, NumberStyles.Float, CultureInfo.InvariantCulture, out var d) || double.IsInfinity(d)) return (null, $"{f.Label}: expected a number");
                    o[f.Key] = d;
                    break;
                case "json":
                    var j = _texts.GetValueOrDefault(f.Key) ?? "";
                    if (j == TextOf(f)) break;
                    if (J.Parse(j) is not { } parsed) return (null, $"{f.Label}: not valid JSON");
                    o[f.Key] = parsed;
                    break;
            }
        }
        return (o, null);
    }

    private List<(string Env, string Value)> Typed(PluginInfo p) =>
        [.. p.Schema.Where(f => f.Type == "secret" && f.Env != null && (_secrets.GetValueOrDefault(f.Key) ?? "").Trim().Length > 0)
            .Select(f => (f.Env!, _secrets[f.Key]))];

    private bool Dirty => Current is { } p && (Typed(p).Count > 0 || Changes(p) is not ({ Count: 0 }, null));

    public override async Task<bool> LeaveAsync()
    {
        if (!CanEdit || !Dirty) return true;
        var d = new ContentDialog { Title = "Discard Changes?", PrimaryButtonText = "Discard", CloseButtonText = "Keep Editing", DefaultButton = ContentDialogButton.Close };
        return await Kit.Show(Root, d) == ContentDialogResult.Primary;
    }

    private async void Save()
    {
        if (model.Api is not { } api || Current is not { Key: { } key } p || _saving) return;
        _fieldError = null;
        var (values, error) = Changes(p);
        if (error != null) { _fieldError = error; Render(); return; }
        var typed = Typed(p);
        _saving = true; Render();
        try
        {
            // Secrets first; if one fails nothing else is sent, and what was typed stays in its field.
            foreach (var (env, value) in typed) await api.SetEnvAsync(env, value, _profile);
            if (values!.Count > 0) await api.PluginAsync(new PluginAction.Settings(key, values), _profile);
            _secrets.Clear();
            await model.ReloadPlugins();
            if (Current is { } fresh) Reset(fresh);
            Flash($"{plugin.Name} settings saved.");
        }
        catch (Exception e) { Kit.Fail(Root, $"Couldn’t Save {plugin.Name} Settings", McpEntryMask.Phone.Text(CapabilitiesWords.Detail(e))); }
        _saving = false; Render();
    }

    private async void Flash(string text)
    {
        _notice = text; Render();
        await Task.Delay(TimeSpan.FromSeconds(5));
        if (_notice == text) { _notice = null; Render(); }
    }

    private async void Update()
    {
        if (model.Api is not { } api || _busy) return;
        _busy = true; Render();
        try
        {
            var r = await api.PluginAsync(new PluginAction.Update(plugin.Name, false), _profile);
            // The new version asks for more than this one had: say what, and update only on a yes.
            if (r.ConsentRequired && await Kit.Confirm(Root, $"Update {plugin.Name}?", string.Join("\n", r.DeltaLines), "Update"))
                r = await api.PluginAsync(new PluginAction.Update(plugin.Name, true), _profile);
            if (r.ScanBlocked) Kit.Fail(Root, $"Couldn’t Update {plugin.Name}", string.Join("\n", r.ScanFindings.Prepend("Hermes’s security scan stopped the update. Nothing changed.")));
            else if (r.Unchanged) Flash($"{plugin.Name} is up to date.");
            else
            {
                model.PluginNotice = r.NeedsRestart ? "Restart your gateway to apply." : $"{plugin.Name} updated.";
                await model.ReloadPlugins();
            }
        }
        catch (Exception e) { Kit.Fail(Root, $"Couldn’t Update {plugin.Name}", McpEntryMask.Phone.Text(CapabilitiesWords.Detail(e))); }
        _busy = false; Render();
    }

    private async void Uninstall()
    {
        if (model.Api is not { } api || _busy) return;
        if (!await Kit.Confirm(Root, $"Uninstall {plugin.Name}?", $"This deletes the plugin’s files from {model.BotName} on {HostWord.Phrase}. You can install it again later.", "Uninstall", destructive: true)) return;
        _busy = true; Render();
        try
        {
            await api.PluginAsync(new PluginAction.Remove(plugin.Name), _profile);
            model.PluginNotice = $"{plugin.Name} uninstalled. Restart your gateway to unload it.";
            model.PluginNeedsKeys = false;
            await model.ReloadPlugins();
            if (Host.Top == this) Pop();
        }
        catch (Exception e) { Kit.Fail(Root, $"Couldn’t Uninstall {plugin.Name}", McpEntryMask.Phone.Text(CapabilitiesWords.Detail(e))); }
        _busy = false; Render();
    }

    public override void Build(StackPanel page)
    {
        if (Current is not { } p) { page.Children.Add(Kit.Section(null, [Kit.Plain($"This plugin isn’t on {model.BotName} any more.")])); return; }
        var about = new StackPanel { Spacing = 6 };
        if (p.Description.Length > 0) about.Children.Add(Kit.Text(p.Description, 14));
        if (p.Version.Length > 0) about.Children.Add(Kit.Text($"Version {p.Version}", 13, secondary: true));
        if (p.SourceWords is { } src) about.Children.Add(Kit.Text(src, 13, secondary: true));
        var first = new List<UIElement> { Kit.Pad(about, 12) };
        if (p.Key != null && !model.ReadOnly) first.Add(Kit.SwitchRow($"On for {model.BotName}", p.Enabled, on => model.SetPlugin(p, on), !model.PluginBusy.Contains(p.Name)));
        page.Children.Add(Kit.Section(null, first, p.HasDesktopHalf && !p.IsKanban ? "Part of this plugin shows only in Hermes on a computer." : null));
        if (_notice is { } n) page.Children.Add(Kit.Section(null, [Kit.Notice(n, Kit.Check)]));
        if (!model.ReadOnly && (p.UpdateAvailable || p.CanUninstall))
        {
            var rows = new List<UIElement>();
            if (p.UpdateAvailable) rows.Add(Kit.Row(_busy ? "Updating…" : $"Update to {p.NewVersion ?? "the Latest Version"}", click: _busy ? null : Update));
            if (p.CanUninstall) rows.Add(Kit.Pad(Kit.Button("Uninstall", Uninstall, enabled: !_busy).Also(b => b.Foreground = Kit.Critical)));
            page.Children.Add(Kit.Section(null, rows));
        }
        if (p.Schema.Count > 0) Settings(page, p);
    }

    private void Settings(StackPanel page, PluginInfo p)
    {
        var editable = CanEdit;
        var rows = new List<UIElement>();
        Button? saveBtn = editable ? Kit.Button(_saving ? "Saving…" : "Save Settings", Save, enabled: !_saving && Dirty) : null;
        void RefreshSaveEnabled() { if (saveBtn != null) saveBtn.IsEnabled = !_saving && Dirty; }
        foreach (var f in p.Schema)
        {
            var s = new StackPanel { Spacing = 6 };
            var label = new TextBlock { FontSize = 14, TextWrapping = TextWrapping.Wrap };
            label.Inlines.Add(new Run { Text = f.Label });
            if (!f.Required) label.Inlines.Add(new Run { Text = " (optional)", Foreground = Kit.Secondary });
            switch (f.Type)
            {
                case "boolean":
                    var sw = Kit.Switch(_bools.GetValueOrDefault(f.Key), f.Label, on => { _bools[f.Key] = on; RefreshSaveEnabled(); }, editable);
                    var g = new Grid();
                    g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                    g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                    g.Children.Add(label);
                    Grid.SetColumn(sw, 1);
                    g.Children.Add(sw);
                    s.Children.Add(g);
                    break;
                case "enum":
                    s.Children.Add(label);
                    var box = new ComboBox { IsEnabled = editable, MinWidth = 180 };
                    foreach (var c in f.Choices) box.Items.Add(c);
                    box.SelectedItem = _texts.GetValueOrDefault(f.Key);
                    box.SelectionChanged += (_, _) => { if (box.SelectedItem is string v) { _texts[f.Key] = v; RefreshSaveEnabled(); } };
                    AutomationProperties.SetName(box, f.Label);
                    s.Children.Add(box);
                    break;
                case "secret":
                    s.Children.Add(label);
                    if (f.Env == null) s.Children.Add(Kit.Text($"Set this one on {HostWord.Phrase}.", 12, secondary: true));
                    else
                    {
                        var pw = new PasswordBox { PlaceholderText = f.HasValue ? "•••••••• (set)" : "", Password = _secrets.GetValueOrDefault(f.Key) ?? "", IsEnabled = editable };
                        pw.PasswordChanged += (_, _) => { _secrets[f.Key] = pw.Password; RefreshSaveEnabled(); };
                        AutomationProperties.SetName(pw, f.Label);
                        AutomationProperties.SetHelpText(pw, $"Saved as {f.Env} on the computer running Hermes");
                        s.Children.Add(pw);
                    }
                    break;
                case "json" or "string" or "number":
                    s.Children.Add(label);
                    var tb = new TextBox { Text = _texts.GetValueOrDefault(f.Key) ?? "", IsEnabled = editable, IsSpellCheckEnabled = false, PlaceholderText = f.Type == "json" ? "" : f.Label };
                    if (f.Type == "json") { tb.AcceptsReturn = true; tb.MinHeight = 80; tb.MaxHeight = 220; tb.FontFamily = Kit.Res<Microsoft.UI.Xaml.Media.FontFamily>("CodeFont"); tb.TextWrapping = TextWrapping.Wrap; }
                    if (f.Type == "number") tb.InputScope = new Microsoft.UI.Xaml.Input.InputScope { Names = { new Microsoft.UI.Xaml.Input.InputScopeName(Microsoft.UI.Xaml.Input.InputScopeNameValue.Number) } };
                    tb.TextChanged += (_, _) => { _texts[f.Key] = tb.Text; RefreshSaveEnabled(); };
                    AutomationProperties.SetName(tb, f.Label);
                    s.Children.Add(tb);
                    break;
                default:
                    s.Children.Add(label);
                    s.Children.Add(Kit.Text(McpEntryMask.Phone.Text(TextOf(f)), 13, secondary: true));
                    break;
            }
            var caption = string.Join(" ", new[] { f.Description, f.Type == "secret" && f.Env != null
                ? "Saved as a secret on the computer running Hermes. Leave blank to keep the current value." : "" }.Where(x => x.Length > 0));
            if (caption.Length > 0) s.Children.Add(Kit.Text(caption, 12, secondary: true));
            rows.Add(Kit.Pad(s));
        }
        if (_fieldError is { } fe) rows.Add(Kit.Pad(Kit.Text(fe, 13, color: Kit.Critical)));
        if (saveBtn != null) rows.Add(Kit.Pad(saveBtn));
        page.Children.Add(Kit.Section("Settings", rows, p.Key == null ? $"Update Hermes on {HostWord.UpdateTarget} to change these here." : null));
    }
}

/// Plugins › Install from Git… (§9.4).
internal sealed class PluginInstallScreen(CapabilitiesModel model) : Screen
{
    private string _repo = "", _ref = "";
    private bool _enable = true, _force, _installing, _uncertain;
    private string? _already;
    private DateTimeOffset? _lockedUntil;
    public static bool Running { get; set; }
    public override string Title => "Install Plugin";

    private PluginRepo.Check Check => PluginRepo.CheckRepo(_repo);
    private bool CanInstall => Check is PluginRepo.Check.Ok or PluginRepo.Check.Insecure && PluginRepo.RefValid(_ref) && !_installing && !Running
        && (_lockedUntil is not { } until || until < DateTimeOffset.UtcNow);

    private async void Ask()
    {
        if (!CanInstall) return;
        var identifier = _repo.Trim();
        if (!await Kit.Confirm(Root, "Install This Plugin?", $"Hermes will download {identifier} and run its code on {HostWord.Phrase} for {model.BotName}.", "Install")) return;
        if (model.Api is not { } api || Running) return;
        _installing = true; Running = true; _already = null; _uncertain = false; Render();
        var pin = _ref.Trim();
        try
        {
            var result = await api.PluginAsync(new PluginAction.Install(identifier, _force, _enable, pin.Length == 0 ? null : pin), model.Profile);
            model.NoteInstalled(result, result.Name ?? identifier);
            await model.ReloadPlugins();
            if (Host.Top == this) Pop();
        }
        catch (Exception e)
        {
            var detail = CapabilitiesWords.Detail(e);
            if (e is Hermes.Core.Net.GatewayException { RpcCode: 4090 } || detail.Contains("already installed", StringComparison.OrdinalIgnoreCase))
                _already = $"{identifier} is already installed. Turn on Replace If Already Installed to install it again.";
            else if (detail.Contains("timed out", StringComparison.OrdinalIgnoreCase) || detail.Contains("took too long", StringComparison.OrdinalIgnoreCase))
            {
                _uncertain = true;
                _lockedUntil = DateTimeOffset.UtcNow.AddSeconds(30);
                var ui = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
                _ = Task.Delay(TimeSpan.FromSeconds(30)).ContinueWith(_ => ui?.TryEnqueue(() =>
                {
                    if (HermesHQ.Services.AppShutdown.Stopping) return;
                    _lockedUntil = null;
                    if (Host.Top == this) Render();
                }));
            }
            else Kit.Fail(Root, "Couldn’t Install Plugin", new string(McpEntryMask.Phone.Text(detail).Take(600).ToArray()));
        }
        _installing = false; Running = false; Render();
    }

    public override void Build(StackPanel page)
    {
        page.Children.Add(Kit.Section(null, [Kit.Plain($"Install only from sources you trust. A plugin is code that runs on {HostWord.Phrase}.", secondary: false)]));
        var repoNote = Kit.Text("", 12);
        var pinNote = Kit.Text("", 12);
        var face = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        if (_installing) face.Children.Add(Kit.Spinner());
        face.Children.Add(Kit.Text(_installing ? "Installing…" : "Install", 14));
        var b = new Button { Content = face, HorizontalAlignment = HorizontalAlignment.Stretch, IsEnabled = CanInstall, Style = Kit.Res<Style>("AccentButtonStyle") };
        AutomationProperties.SetName(b, "Install");
        b.Click += (_, _) => Ask();

        void UpdateValidation()
        {
            b.IsEnabled = CanInstall;
            if (Check == PluginRepo.Check.Invalid)
            {
                repoNote.Text = "That doesn’t look like a repository address.";
                repoNote.Foreground = Kit.Critical;
                repoNote.Visibility = Visibility.Visible;
            }
            else if (Check == PluginRepo.Check.Insecure)
            {
                repoNote.Text = "This URL uses an insecure or local scheme. Prefer https:// or git@ for production installs.";
                repoNote.Foreground = Kit.Caution;
                repoNote.Visibility = Visibility.Visible;
            }
            else if (_already != null)
            {
                repoNote.Text = _already;
                repoNote.Foreground = Kit.Critical;
                repoNote.Visibility = Visibility.Visible;
            }
            else repoNote.Visibility = Visibility.Collapsed;

            if (PluginRepo.RefValid(_ref))
            {
                pinNote.Text = "Pin to Commit (Optional): everyone installing this SHA gets the same code; the plugin then refuses updates until re-pinned. Leave empty for the latest commit.";
                pinNote.Foreground = Kit.Secondary;
            }
            else
            {
                pinNote.Text = "Must be a full 40-character commit SHA (branches and tags are not accepted).";
                pinNote.Foreground = Kit.Critical;
            }
        }

        var repo = new TextBox { PlaceholderText = "https://github.com/owner/repo", Text = _repo, IsSpellCheckEnabled = false };
        repo.TextChanged += (_, _) => { if (_repo != repo.Text) { _repo = repo.Text; _already = null; UpdateValidation(); } };
        AutomationProperties.SetName(repo, "Repository");
        page.Children.Add(Kit.Section("Repository", [Kit.Pad(repo, 8)], footerElement: repoNote));
        var pin = new TextBox { PlaceholderText = "Full 40-character commit SHA", Text = _ref, IsSpellCheckEnabled = false, FontFamily = Kit.Res<Microsoft.UI.Xaml.Media.FontFamily>("CodeFont") };
        pin.TextChanged += (_, _) => { if (_ref != pin.Text) { _ref = pin.Text; UpdateValidation(); } };
        AutomationProperties.SetName(pin, "Pin to Commit (Optional)");
        page.Children.Add(Kit.Section("Options",
            [Kit.SwitchRow("Turn On After Installing", _enable, on => { _enable = on; }), Kit.SwitchRow("Replace If Already Installed", _force, on => { _force = on; }), Kit.Pad(pin, 8)],
            footerElement: pinNote));
        if (_uncertain)
            page.Children.Add(Kit.Section(null, [Kit.Notice("Hermes stopped waiting for the install result, but the plugin may still be installing. Go back and press Ctrl+R to refresh Plugins before trying Install again.", Kit.Warning, Kit.Caution)]));
        page.Children.Add(Kit.Section(null, [Kit.Pad(b)], $"Installs for {model.BotName}. Plugin changes take effect after your gateway restarts."));
        UpdateValidation();
    }
}

/// A Marketplace plugin's page (PluginCatalogPages.swift `PluginCatalogEntryController`): what it does, Install for the
/// bot (Hermes downloads the commit Nous reviewed), what it shares, more by its maker, the details.
internal sealed class PluginCatalogEntryScreen(CapabilitiesModel model, PluginCatalogEntry entry, bool autoInstall = false) : Screen
{
    private readonly string _profile = model.Profile;
    private bool _installing, _uncertain, _expanded, _didAutoInstall;
    private string? _error;
    public override string Title => entry.Title;
    private PluginInfo? Installed => model.Profile == _profile ? model.InstalledPlugin(entry) : null;
    private bool CanInstall => !_installing && !_uncertain && Installed == null && !model.ReadOnly && !model.PluginsUnavailable && model.Api != null && !PluginInstallScreen.Running;

    public override void Shown()
    {
        model.Changed += Render;
        if (model.Plugins == null) _ = model.ReloadPlugins();
        if (autoInstall && !_didAutoInstall)
        {
            _didAutoInstall = true;
            Install();
        }
    }
    public override void Hidden() => model.Changed -= Render;

    private async void Install()
    {
        if (!CanInstall || model.Api is not { } api) return;
        _installing = true; PluginInstallScreen.Running = true; _error = null; Render();
        try
        {
            PluginResult result;
            try { result = await api.PluginAsync(new PluginAction.InstallCatalog(entry.Name, true), _profile); }
            catch (Hermes.Core.Net.GatewayException e) when (e is { Code: "rpc", RpcCode: 4019 } && e.Message.Contains("identifier"))
            {
                // A Hermes from before `catalog_name`: the same reviewed commit, by its address and pin.
                result = await api.PluginAsync(new PluginAction.Install(entry.InstallIdentifier, false, true, entry.Sha.Length == 0 ? null : entry.Sha), _profile);
            }
            var name = result.Name ?? entry.Name;
            model.NoteInstalled(result, name);
            await model.ReloadPlugins();
            if (model.Plugins?.FirstOrDefault(p => p.Name == name || p.CatalogName == entry.Name) is { } plugin && Host.Top == this) { Pop(); Push(new PluginScreen(model, plugin)); }
        }
        catch (Exception e)
        {
            var detail = CapabilitiesWords.Detail(e);
            if (e is Hermes.Core.Net.GatewayException { RpcCode: 4090 } || detail.Contains("already installed", StringComparison.OrdinalIgnoreCase))
            {
                await model.ReloadPlugins();
                if (Installed == null) _error = $"{entry.Title} is already on {HostWord.Phrase} for {model.BotName}. Open Plugins to turn it on.";
            }
            else if (detail.Contains("timed out", StringComparison.OrdinalIgnoreCase) || detail.Contains("took too long", StringComparison.OrdinalIgnoreCase))
            {
                _uncertain = true;
                var ui = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
                _ = Task.Delay(TimeSpan.FromSeconds(30)).ContinueWith(_ => ui?.TryEnqueue(async () =>
                {
                    if (HermesHQ.Services.AppShutdown.Stopping) return;
                    try { await model.ReloadPlugins(); } catch (Exception) { }
                    _uncertain = false;
                    if (!HermesHQ.Services.AppShutdown.Stopping && Host.Top == this) Render();
                }));
            }
            else _error = new string(McpEntryMask.Phone.Text(detail).Take(600).ToArray());
        }
        _installing = false; PluginInstallScreen.Running = false; Render();
    }

    private (string, Microsoft.UI.Xaml.Media.Brush)? Note()
    {
        if (_error != null) return (_error, Kit.Critical);
        if (_uncertain) return ("Hermes is still working on it, or the install stopped. The Plugins list will show it once it’s done.", Kit.Caution);
        if (model.PluginsUnavailable) return (CapabilitiesWords.PluginsTooOld.Replace("manage plugins", "install plugins"), Kit.Secondary);
        if (model.ReadOnly) return ("This gateway is read-only. Install from a gateway you can change.", Kit.Secondary);
        if (_installing) return ("Hermes is downloading the version Nous reviewed. This can take a minute.", Kit.Secondary);
        if (entry.Category == PluginCatalogCategory.Desktop) return ($"This one adds to the Hermes desktop app on {HostWord.Phrase}. It won’t show in Hermes HQ.", Kit.Secondary);
        if (entry.RequiresEnv.Count > 0)
            return ($"It needs {(entry.RequiresEnv.Count == 1 ? "a key" : "keys")} once it’s installed: {string.Join(", ", entry.RequiresEnv.Take(3))}.", Kit.Secondary);
        return null;
    }

    public override void Build(StackPanel page)
    {
        var top = new StackPanel { Spacing = 10 };
        var head = new Grid { ColumnSpacing = 14 };
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        head.Children.Add(Kit.Tile(Kit.Puzzle, 56));
        var words = new StackPanel { Spacing = 5, VerticalAlignment = VerticalAlignment.Center };
        words.Children.Add(Kit.Text(entry.Title, 20, bold: true));
        var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        if (entry.TierWord is { } tier) line.Children.Add(Kit.Badge(tier, ConnectorTone.Good));
        line.Children.Add(Kit.Text(entry.Maintainer.Length == 0 ? entry.Category.Title() : $"{entry.Category.Title()} · by {entry.Maintainer}", 12, secondary: true, wrap: false));
        words.Children.Add(line);
        Grid.SetColumn(words, 1);
        head.Children.Add(words);
        top.Children.Add(head);
        if (entry.About.Length > 0)
        {
            var long_ = entry.About.Length > 420;
            top.Children.Add(Kit.Text(entry.About, 13, secondary: true).Also(t => { t.IsTextSelectionEnabled = true; if (long_ && !_expanded) t.MaxLines = 6; }));
            if (long_) top.Children.Add(Kit.Link(_expanded ? "Less" : "More", () => { _expanded = !_expanded; Render(); }));
        }
        page.Children.Add(Kit.Section(null, [Kit.Pad(top, 12)]));

        var install = new StackPanel { Spacing = 10, Margin = new Thickness(0, 0, 0, 18) };
        if (CapabilitiesServices.Bots().Count > 1)
            install.Children.Add(BotRow.Make(model.Profile, false, p => { model.SetProfile(p); Render(); }));
        if (Installed != null)
        {
            install.Children.Add(Kit.Text($"✓ Installed for {model.BotName}", 13, bold: true, color: Kit.Success).Also(t => t.HorizontalAlignment = HorizontalAlignment.Center));
            install.Children.Add(Kit.Button("Open in Plugins", () => { if (Installed is { } p) Push(new PluginScreen(model, p)); }).Also(b => b.HorizontalAlignment = HorizontalAlignment.Stretch));
        }
        else
        {
            var face = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center };
            if (_installing) face.Children.Add(Kit.Spinner());
            face.Children.Add(Kit.Text(_installing ? "Installing…" : $"Install for {model.BotName}", 14, bold: true));
            var b = new Button { Content = face, HorizontalAlignment = HorizontalAlignment.Stretch, IsEnabled = CanInstall, Style = Kit.Res<Style>("AccentButtonStyle"), MinHeight = 36 };
            AutomationProperties.SetName(b, $"Install for {model.BotName}");
            b.Click += async (_, _) =>
            {
                if (await Kit.Confirm(Root, $"Install {entry.Title} for {model.BotName}?", MarketplaceWords.PluginInstallMessage(entry), "Install")) Install();
            };
            install.Children.Add(b);
            if (Note() is var (text, brush)) install.Children.Add(Kit.Text(text, 13, color: brush).Also(t => t.TextAlignment = TextAlignment.Center));
        }
        install.Children.Add(Kit.Text(entry.InstallIdentifier.Length > 0 ? $"hermes plugins install {entry.Name}" : "", 12, secondary: true)
            .Also(t => { t.FontFamily = Kit.Res<Microsoft.UI.Xaml.Media.FontFamily>("CodeFont"); t.IsTextSelectionEnabled = true; t.HorizontalAlignment = HorizontalAlignment.Center; }));
        page.Children.Add(install);

        if (entry.Disclosure is { } disclosure || entry.ProvidesTools.Count > 0)
        {
            var rows = new List<UIElement>();
            if (entry.Disclosure is { } d) rows.Add(Kit.Plain(d, secondary: false));
            page.Children.Add(Kit.Section("What It Shares", rows, "From the plugin’s catalog listing, which Nous checks."));
        }
        var others = (CapabilitiesServices.PluginCatalog.Entries ?? []).Where(e => e.Maintainer == entry.Maintainer && e.Maintainer.Length > 0 && e.Name != entry.Name)
            .OrderByDescending(e => e.Stars ?? -1).ToList();
        if (others.Count > 0)
            page.Children.Add(Kit.Section($"More by {entry.Maintainer}", others.Take(3).Select(e => ListScreen.PluginCatalogRow(model, e, this))));

        var details = new List<UIElement>();
        UIElement Detail(string label, string value)
        {
            var s = new StackPanel { Spacing = 3 };
            s.Children.Add(Kit.Text(label, 13, secondary: true));
            s.Children.Add(Kit.Text(value, 14).Also(t => t.IsTextSelectionEnabled = true));
            return Kit.Pad(s);
        }
        if (entry.Maintainer.Length > 0) details.Add(Detail("Made by", entry.Maintainer));
        var version = string.Join(" · ", new[] { entry.Version, entry.Sha.Length == 0 ? "" : $"commit {entry.Sha[..Math.Min(7, entry.Sha.Length)]}" }.Where(s => s.Length > 0));
        if (version.Length > 0) details.Add(Detail("Version", version));
        if (entry.Stars is { } stars) details.Add(Detail("GitHub stars", stars.ToString("N0")));
        details.Add(Detail("Works on", entry.PlatformWords ?? "Every system Hermes runs on"));
        if (entry.HermesWords is { } hw) details.Add(Detail("Needs Hermes", hw));
        if (entry.RequiresEnv.Count > 0) details.Add(Detail(entry.RequiresEnv.Count == 1 ? "Key it needs" : "Keys it needs", string.Join(", ", entry.RequiresEnv)));
        if (entry.ProvidesTools.Count > 0)
        {
            var tools = string.Join(", ", entry.ProvidesTools.Take(10));
            details.Add(Detail("Tools it adds", entry.ProvidesTools.Count > 10 ? $"{tools} and {entry.ProvidesTools.Count - 10} more" : tools));
        }
        if ((entry.UpdatedAt ?? entry.AddedAt) is { } when)
            details.Add(Detail(entry.UpdatedAt != null && entry.UpdatedAt != entry.AddedAt ? "Updated" : "Listed", when.ToLocalTime().ToString("d MMM yyyy")));
        if (entry.DocsUrl is { } docs) details.Add(Kit.Row("Learn More", trailing: Kit.Glyph(Kit.OpenOut, 12, Kit.Tertiary), click: () => Kit.Open(docs.ToString())));
        if (entry.PageUrl is { } site) details.Add(Kit.Row("See in the Hermes Marketplace", trailing: Kit.Glyph(Kit.OpenOut, 12, Kit.Tertiary), click: () => Kit.Open(site.ToString())));
        page.Children.Add(Kit.Section("Details", details, MarketplaceWords.TrustNote(entry)));
    }
}
