using System.Text.Json.Nodes;
using Hermes.Core;
using Hermes.Core.Composer;
using Hermes.Core.Settings;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Features.Settings;

/// Settings › Models: Main Model, Fallback Models, Auxiliary Models, Mixture of Agents, plus Accounts › Providers / Keys /
/// Billing helper panes (App/Settings/Config/ModelPages.swift & MacForm.swift `#616`).
/// Pickers and model chooser buttons are width-capped with single-line ellipsis truncation so long model names never
/// overflow their card.
internal static class ModelSettingsPane
{
    private static string? DefaultBotName() => AppState.Client?.Bots?.FirstOrDefault(b => b.IsDefault)?.DisplayName;
    private static bool HasOtherBots() => (AppState.Client?.Bots?.Count ?? 0) > 1;

    // ---------------------------------------------------------------- Models Hub

    public static FrameworkElement MakeHub(SettingsPage page)
    {
        var defaultBot = DefaultBotName();
        var otherBots = HasOtherBots();
        return Kit.Page(
            Kit.Section(SettingsWords.ModelsLabel, SettingsWords.ModelSectionFooter(defaultBot, otherBots),
                Kit.Nav("\uE945", SettingsWords.MainModelLabel, null, () => page.Push(SettingsWords.MainModelLabel, () => MakeMainModel(page)), "settings.models.main"),
                Kit.Nav("\uE8AB", SettingsWords.FallbackModelsLabel, null, () => page.Push(SettingsWords.FallbackModelsLabel, () => MakeFallbackModels(page)), "settings.models.fallbacks"),
                Kit.Nav("\uE734", SettingsWords.AuxiliaryModelsLabel, null, () => page.Push(SettingsWords.AuxiliaryModelsLabel, () => MakeAuxiliaryModels(page)), "settings.models.auxiliary"),
                Kit.Nav("\uE902", SettingsWords.MoaLabel, null, () => page.Push(SettingsWords.MoaLabel, () => MakeMoa(page)), "settings.models.moa")));
    }

    // ---------------------------------------------------------------- Main Model

    public static FrameworkElement MakeMainModel(SettingsPage page, string? profile = null)
    {
        var host = new ContentControl { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetAutomationId(host, "main-model.list");
        if (AppState.Client is not { } client)
            return Kit.Page(Kit.Section(null, null, Kit.Row(null, "Connect to your gateway to configure Main Model.")));

        var api = new ModelSettingsApi(client.Session, profile);
        var store = new GatewayConfigStore(new GatewayConfigApi(client.Session, profile));
        IReadOnlyList<ModelProviderOption> providers = [];
        var mainProvider = "";
        var mainModel = "";
        var loading = true;
        var applying = false;
        string? loadError = null;
        string? applyError = null;
        var disposed = false;

        void Dispatch(Action work)
        {
            if (disposed) return;
            if (host.DispatcherQueue is { } q) q.TryEnqueue(() => { if (!disposed) work(); });
            else work();
        }

        async Task LoadAsync()
        {
            loading = true;
            loadError = null;
            Dispatch(Draw);
            try
            {
                var optionsTask = api.GetModelOptionsAsync();
                var infoTask = api.GetModelInfoAsync();
                var configTask = store.LoadAsync();
                await Task.WhenAll(optionsTask, infoTask, configTask);
                providers = optionsTask.Result;
                mainProvider = infoTask.Result.Provider;
                mainModel = infoTask.Result.Model;
            }
            catch (Exception ex)
            {
                loadError = SettingsErrorText.Load(ex);
            }
            finally
            {
                loading = false;
                Dispatch(Draw);
            }
        }

        async Task ApplyModelAsync(string provider, string model, bool confirm = false)
        {
            if (string.IsNullOrWhiteSpace(model) || applying) return;
            applying = true;
            applyError = null;
            Dispatch(Draw);
            try
            {
                var baseUrl = providers.FirstOrDefault(p => p.Slug == provider)?.ApiUrl;
                await api.SetModelAsync("main", provider, model, baseUrl: baseUrl, confirmExpensive: confirm);
                mainProvider = provider;
                mainModel = model;
                AppLog.Note("settings", "main model changed");
                _ = client.BotsAsync();
                await LoadAsync();
            }
            catch (ModelConfirmRequiredException confirmEx)
            {
                applying = false;
                Dispatch(Draw);
                var dialog = new ContentDialog
                {
                    Title = $"Use {ModelNames.DisplayModelName(model)}?",
                    Content = new TextBlock { Text = confirmEx.Message, TextWrapping = TextWrapping.Wrap },
                    PrimaryButtonText = "Use It",
                    CloseButtonText = "Cancel",
                    DefaultButton = ContentDialogButton.Primary,
                };
                if (await SafeDialog.ShowAsync(host.XamlRoot, dialog) == ContentDialogResult.Primary)
                    await ApplyModelAsync(provider, model, confirm: true);
            }
            catch (Exception ex)
            {
                applyError = SettingsErrorText.Save(ex);
            }
            finally
            {
                applying = false;
                Dispatch(Draw);
            }
        }

        async Task OpenChooserAsync()
        {
            var picked = await ShowModelChooserDialogAsync(host.XamlRoot, "Model", providers, mainProvider, mainModel, includeUseMain: false);
            if (picked is { } p) await ApplyModelAsync(p.Provider, p.Model);
        }

        void Draw()
        {
            if (disposed) return;
            UiTree.DeactivateProgressRings(host);
            var sections = new List<UIElement?>();
            var defaultBot = DefaultBotName();
            var otherBots = HasOtherBots();

            if (!string.IsNullOrEmpty(applyError))
            {
                sections.Add(Kit.Section(null, null, new TextBlock
                {
                    Text = applyError,
                    FontSize = 12,
                    TextWrapping = TextWrapping.Wrap,
                    Margin = new Thickness(14, 10, 14, 10),
                    Foreground = Kit.B("SystemFillColorCriticalBrush"),
                }));
            }

            var modelValue = loading && mainModel.Length == 0
                ? "Loading…"
                : ModelSettingsWords.Describe(mainProvider, mainModel, providers);
            var rows = new List<UIElement?>
            {
                Kit.ChooserButton(null, "Model", null, modelValue, () => _ = OpenChooserAsync(), "main-model.model", enabled: !applying),
            };
            if (applying)
            {
                var spin = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Padding = new Thickness(14, 10, 14, 10) };
                spin.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
                spin.Children.Add(new TextBlock { Text = "Switching…", Foreground = Kit.B("TextFillColorSecondaryBrush"), VerticalAlignment = VerticalAlignment.Center });
                rows.Add(spin);
            }
            sections.Add(Kit.Section(SettingsWords.MainModelHeader(defaultBot),
                loadError ?? SettingsWords.MainModelFooter(defaultBot, otherBots), [.. rows]));

            if (store.Config != null)
            {
                var effort = ModelNames.NormalizeConfigEffort(store.Value("agent.reasoning_effort")) ?? ModelNames.DefaultReasoningEffort;
                var effortOptions = ModelNames.ReasoningEffortValues.Select(v => (ModelNames.EffortLabel(v), v)).ToList();
                var fast = string.Equals(J.AsString(store.Value("agent.service_tier")), "fast", StringComparison.OrdinalIgnoreCase);

                sections.Add(Kit.Section("Defaults", SettingsWords.MainDefaultsFooter(defaultBot),
                    Kit.Picker(null, "Reasoning Effort", null, effortOptions, effort,
                        next => store.Set("agent.reasoning_effort", JsonValue.Create(next == "none" ? "false" : next)), "main-model.reasoning"),
                    Kit.Toggle(null, "Fast Mode", null, fast,
                        on => store.Set("agent.service_tier", JsonValue.Create(on ? "fast" : "normal")), "main-model.fast")));
            }

            host.Content = Kit.Page([.. sections]);
        }

        host.Unloaded += (_, _) =>
        {
            disposed = true;
            UiTree.DeactivateProgressRings(host);
            _ = store.Flush();
        };

        Draw();
        _ = LoadAsync();
        return host;
    }

    // ---------------------------------------------------------------- Fallback Models

    public static FrameworkElement MakeFallbackModels(SettingsPage page, string? profile = null, string? botName = null)
    {
        var host = new ContentControl { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetAutomationId(host, "fallbacks.list");
        if (AppState.Client is not { } client)
            return Kit.Page(Kit.Section(null, null, Kit.Row(null, "Connect to your gateway to configure Fallback Models.")));

        var store = new GatewayConfigStore(new GatewayConfigApi(client.Session, profile));
        var api = new ModelSettingsApi(client.Session, profile);
        IReadOnlyList<ModelProviderOption> providers = [];
        var disposed = false;

        void Dispatch(Action work)
        {
            if (disposed) return;
            if (host.DispatcherQueue is { } q) q.TryEnqueue(() => { if (!disposed) work(); });
            else work();
        }

        IReadOnlyList<FallbackModel> CurrentList() => FallbackModel.ParseList(store.Value("fallback_providers"));

        void SaveList(List<FallbackModel> next)
        {
            store.Set("fallback_providers", FallbackModel.ToJson(next));
            Dispatch(Draw);
        }

        async Task AddAsync()
        {
            var picked = await ShowModelChooserDialogAsync(host.XamlRoot, "Add Fallback", providers, "", "", includeUseMain: false);
            if (picked is not { } p) return;
            var next = CurrentList().ToList();
            next.Add(new FallbackModel(p.Provider, p.Model));
            SaveList(next);
        }

        void Draw()
        {
            if (disposed) return;
            UiTree.DeactivateProgressRings(host);

            if (store.Config == null)
            {
                if (store.Phase == GatewayConfigStore.LoadPhase.Failed)
                {
                    var retry = Kit.Push("Try Again", () => _ = store.LoadAsync(force: true));
                    host.Content = Kit.Page(Kit.Section(null, null, Kit.Row(null, "Couldn’t Load Fallback Models", store.LoadError, retry)));
                    return;
                }
                var spin = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Padding = new Thickness(14, 12, 14, 12) };
                spin.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
                spin.Children.Add(new TextBlock { Text = "Loading…", Foreground = Kit.B("TextFillColorSecondaryBrush") });
                host.Content = Kit.Page(Kit.Section(null, null, spin));
                return;
            }

            var list = CurrentList();
            var rows = new List<UIElement?>();
            for (var i = 0; i < list.Count; i++)
            {
                var idx = i;
                var entry = list[i];
                var controls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
                var up = Kit.Push("↑", () =>
                {
                    var next = CurrentList().ToList();
                    if (idx > 0) { (next[idx - 1], next[idx]) = (next[idx], next[idx - 1]); SaveList(next); }
                });
                up.IsEnabled = idx > 0;
                up.Padding = new Thickness(8, 3, 8, 3);
                AutomationProperties.SetName(up, "Move Up");
                var down = Kit.Push("↓", () =>
                {
                    var next = CurrentList().ToList();
                    if (idx < next.Count - 1) { (next[idx + 1], next[idx]) = (next[idx], next[idx + 1]); SaveList(next); }
                });
                down.IsEnabled = idx < list.Count - 1;
                down.Padding = new Thickness(8, 3, 8, 3);
                AutomationProperties.SetName(down, "Move Down");
                var remove = Kit.Push("Remove", () =>
                {
                    var next = CurrentList().ToList();
                    if (idx < next.Count) { next.RemoveAt(idx); SaveList(next); }
                }, destructive: true);
                remove.Padding = new Thickness(8, 3, 8, 3);
                controls.Children.Add(up);
                controls.Children.Add(down);
                controls.Children.Add(remove);
                rows.Add(Kit.Row(null, $"{idx + 1}. {ModelNames.DisplayModelName(entry.Model)}", ModelSettingsWords.ProviderName(entry.Provider, providers), controls, $"fallback-row-{idx}"));
            }

            var addBtn = Kit.Push("Add Fallback Model…", () => _ = AddAsync());
            AutomationProperties.SetAutomationId(addBtn, "fallback.add");
            var addWrap = new StackPanel { Padding = new Thickness(14, 10, 14, 10) };
            addWrap.Children.Add(addBtn);
            rows.Add(addWrap);

            var baseFooter = list.Count == 0
                ? "No fallback models. If the default model fails, the chat shows the error."
                : "Tried in order when the default model fails.";
            var footer = SettingsWords.BotScoped(baseFooter, botName, DefaultBotName(), HasOtherBots());
            host.Content = Kit.Page(Kit.Section(null, footer, [.. rows]));
        }

        store.Changed += () => Dispatch(Draw);
        host.Unloaded += (_, _) =>
        {
            disposed = true;
            UiTree.DeactivateProgressRings(host);
            _ = store.Flush();
        };

        Draw();
        _ = Task.Run(async () =>
        {
            await store.LoadAsync();
            try { providers = await api.GetModelOptionsAsync(); } catch (Exception) { }
            Dispatch(Draw);
        });
        return host;
    }

    // ---------------------------------------------------------------- Auxiliary Models (#616)

    public static FrameworkElement MakeAuxiliaryModels(SettingsPage page, string? profile = null, string? botName = null)
    {
        var host = new ContentControl { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetAutomationId(host, "aux.list");
        if (AppState.Client is not { } client)
            return Kit.Page(Kit.Section(null, null, Kit.Row(null, "Connect to your gateway to configure Auxiliary Models.")));

        var api = new ModelSettingsApi(client.Session, profile);
        IReadOnlyList<AuxiliaryAssignment> tasks = [];
        IReadOnlyList<ModelProviderOption> providers = [];
        var mainProvider = "";
        var mainModel = "";
        var loaded = false;
        string? loadError = null;
        string? saveError = null;
        string? busyTask = null;
        var disposed = false;

        void Dispatch(Action work)
        {
            if (disposed) return;
            if (host.DispatcherQueue is { } q) q.TryEnqueue(() => { if (!disposed) work(); });
            else work();
        }

        async Task LoadAsync()
        {
            loadError = null;
            Dispatch(Draw);
            try
            {
                tasks = await api.GetAuxiliaryModelsAsync();
                loaded = true;
                try
                {
                    var optTask = api.GetModelOptionsAsync();
                    var infoTask = api.GetModelInfoAsync();
                    await Task.WhenAll(optTask, infoTask);
                    providers = optTask.Result;
                    mainProvider = infoTask.Result.Provider;
                    mainModel = infoTask.Result.Model;
                }
                catch (Exception) { /* task list still renders without provider catalog */ }
            }
            catch (Exception ex)
            {
                loadError = SettingsErrorText.Load(ex);
            }
            Dispatch(Draw);
        }

        async Task ChooseAsync(AuxiliaryAssignment task)
        {
            var picked = await ShowModelChooserDialogAsync(host.XamlRoot, AuxiliaryAssignment.Label(task.Task),
                providers, task.FollowsMain ? "" : task.Provider, task.FollowsMain ? "" : task.Model,
                includeUseMain: mainModel.Length > 0, mainProvider: mainProvider, mainModel: mainModel);
            if (picked is not { } p) return;
            busyTask = task.Task;
            saveError = null;
            Dispatch(Draw);
            try
            {
                var baseUrl = providers.FirstOrDefault(x => x.Slug == p.Provider)?.ApiUrl;
                await api.SetModelAsync("auxiliary", p.Provider, p.Model, task: task.Task, baseUrl: baseUrl);
                tasks = await api.GetAuxiliaryModelsAsync();
            }
            catch (Exception ex)
            {
                saveError = SettingsErrorText.Save(ex);
            }
            finally
            {
                busyTask = null;
                Dispatch(Draw);
            }
        }

        void Draw()
        {
            if (disposed) return;
            UiTree.DeactivateProgressRings(host);
            var sections = new List<UIElement?>();

            if (!string.IsNullOrEmpty(saveError))
            {
                sections.Add(Kit.Section(null, null, new TextBlock
                {
                    Text = saveError,
                    FontSize = 12,
                    TextWrapping = TextWrapping.Wrap,
                    Margin = new Thickness(14, 10, 14, 10),
                    Foreground = Kit.B("SystemFillColorCriticalBrush"),
                }));
            }

            if (loadError != null && !loaded)
            {
                var retry = Kit.Push("Try Again", () => _ = LoadAsync());
                sections.Add(Kit.Section(null, null, Kit.Row(null, "Couldn’t Load Auxiliary Models", loadError, retry)));
            }
            else if (!loaded)
            {
                var spin = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Padding = new Thickness(14, 12, 14, 12) };
                spin.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
                spin.Children.Add(new TextBlock { Text = "Loading…", Foreground = Kit.B("TextFillColorSecondaryBrush") });
                sections.Add(Kit.Section(null, null, spin));
            }
            else
            {
                // #616: width-capped truncating chooser buttons keep long model names inside their card.
                var rows = tasks.Select(task =>
                {
                    var value = busyTask == task.Task ? "Saving…"
                        : task.FollowsMain ? ModelSettingsWords.MainModelPlaceholder
                        : ModelSettingsWords.Describe(task.Provider, task.Model, providers);
                    return (UIElement)Kit.ChooserButton(null, AuxiliaryAssignment.Label(task.Task), null, value,
                        () => _ = ChooseAsync(task), $"aux-task.{task.Task}", enabled: busyTask == null);
                }).ToArray();
                var footer = SettingsWords.BotScoped(
                    "Helper jobs (reading images, summarizing long chats, naming chats…) can use a cheaper or faster model than your main one.",
                    botName, DefaultBotName(), HasOtherBots());
                sections.Add(Kit.Section(null, footer, rows.Length > 0 ? rows : [Kit.Row(null, "No auxiliary tasks reported by this gateway.")]));
            }

            host.Content = Kit.Page([.. sections]);
        }

        host.Unloaded += (_, _) =>
        {
            disposed = true;
            UiTree.DeactivateProgressRings(host);
        };

        Draw();
        _ = LoadAsync();
        return host;
    }

    // ---------------------------------------------------------------- Mixture of Agents

    public static FrameworkElement MakeMoa(SettingsPage page, string? profile = null)
    {
        var host = new ContentControl { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetAutomationId(host, "moa.list");
        if (AppState.Client is not { } client)
            return Kit.Page(Kit.Section(null, null, Kit.Row(null, "Connect to your gateway to configure Mixture of Agents.")));

        var api = new ModelSettingsApi(client.Session, profile);
        JsonNode? record = null;
        IReadOnlyList<ModelProviderOption> providers = [];
        var selectedPreset = "";
        string? error = null;
        var saving = false;
        var disposed = false;

        void Dispatch(Action work)
        {
            if (disposed) return;
            if (host.DispatcherQueue is { } q) q.TryEnqueue(() => { if (!disposed) work(); });
            else work();
        }

        async Task LoadAsync()
        {
            error = null;
            Dispatch(Draw);
            try
            {
                var moaTask = api.GetMoaAsync();
                var optTask = api.GetModelOptionsAsync();
                await Task.WhenAll(moaTask, optTask);
                record = moaTask.Result;
                providers = optTask.Result;
                selectedPreset = MixtureRecord.DefaultPreset(record);
            }
            catch (Exception ex)
            {
                error = SettingsErrorText.Load(ex);
            }
            Dispatch(Draw);
        }

        async Task SaveAsync(JsonObject nextRecord)
        {
            if (!MixtureRecord.Complete(nextRecord) || saving) return;
            saving = true;
            error = null;
            Dispatch(Draw);
            try
            {
                var answer = await api.SetMoaAsync(nextRecord);
                record = answer.Obj("presets") != null ? answer : nextRecord;
            }
            catch (Exception ex)
            {
                error = SettingsErrorText.Save(ex);
            }
            finally
            {
                saving = false;
                Dispatch(Draw);
            }
        }

        void Draw()
        {
            if (disposed) return;
            UiTree.DeactivateProgressRings(host);
            if (error != null && record == null)
            {
                var retry = Kit.Push("Try Again", () => _ = LoadAsync());
                host.Content = Kit.Page(Kit.Section(null, null, Kit.Row(null, "Couldn’t Load Mixture of Agents", error, retry)));
                return;
            }
            if (record == null)
            {
                var spin = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Padding = new Thickness(14, 12, 14, 12) };
                spin.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
                spin.Children.Add(new TextBlock { Text = "Loading…", Foreground = Kit.B("TextFillColorSecondaryBrush") });
                host.Content = Kit.Page(Kit.Section(null, null, spin));
                return;
            }

            var names = MixtureRecord.PresetNames(record);
            var active = names.Contains(selectedPreset) ? selectedPreset : MixtureRecord.DefaultPreset(record);
            var preset = MixtureRecord.Presets(record).Get(active);
            var sections = new List<UIElement?>();
            if (error != null)
            {
                sections.Add(Kit.Section(null, null, new TextBlock
                {
                    Text = error, FontSize = 12, TextWrapping = TextWrapping.Wrap,
                    Margin = new Thickness(14, 10, 14, 10), Foreground = Kit.B("SystemFillColorCriticalBrush"),
                }));
            }

            if (names.Count > 0)
            {
                var opts = names.Select(n => (ModelSettingsWords.PrettyKey(n), n)).ToList();
                var presetFooter = names.Count > 1
                    ? (active == MixtureRecord.DefaultPreset(record) ? "/moa uses this preset." : $"/moa uses {ModelSettingsWords.PrettyKey(MixtureRecord.DefaultPreset(record))}.")
                    : SettingsWords.MoaFooter(DefaultBotName());
                sections.Add(Kit.Section("Preset", presetFooter,
                    Kit.Picker(null, "Preset", null, opts, active, next => { selectedPreset = next; Draw(); }, "moa.preset")));
            }

            if (preset is JsonObject presetObj)
            {
                var refs = presetObj.Arr("reference_models") ?? [];
                var refRows = new List<UIElement?>();
                for (var i = 0; i < refs.Count; i++)
                {
                    var idx = i;
                    var slot = refs[i];
                    var off = slot.Bool("enabled") == false ? " · Off" : "";
                    var desc = ModelSettingsWords.Describe(slot.Str("provider") ?? "", slot.Str("model") ?? "", providers) + off;
                    refRows.Add(Kit.ChooserButton(null, $"Model {idx + 1}", null, desc, async () =>
                    {
                        var picked = await ShowModelChooserDialogAsync(host.XamlRoot, $"Model {idx + 1}",
                            providers.Where(p => !string.Equals(p.Slug, MixtureRecord.ProviderId, StringComparison.OrdinalIgnoreCase)).ToList(),
                            slot.Str("provider") ?? "", slot.Str("model") ?? "", includeUseMain: false);
                        if (picked is not { } p || record is not JsonObject rootCopy) return;
                        var updated = (JsonObject)rootCopy.DeepClone();
                        if (updated.Obj("presets")?.Get(active)?.Arr("reference_models") is { } list && idx < list.Count)
                        {
                            list[idx] = new JsonObject { ["provider"] = p.Provider, ["model"] = p.Model };
                            await SaveAsync(MixtureRecord.Mirrored(updated));
                        }
                    }, $"moa.ref-{idx}", enabled: !saving));
                }
                sections.Add(Kit.Section("Reference Models", null, [.. refRows]));

                var agg = presetObj.Get("aggregator");
                var aggDesc = ModelSettingsWords.Describe(agg.Str("provider") ?? "", agg.Str("model") ?? "", providers);
                sections.Add(Kit.Section("Aggregator", saving ? "Saving…" : MixtureRecord.AdviceLine(presetObj),
                    Kit.ChooserButton(null, "Aggregator", null, aggDesc, async () =>
                    {
                        var picked = await ShowModelChooserDialogAsync(host.XamlRoot, "Aggregator",
                            providers.Where(p => !string.Equals(p.Slug, MixtureRecord.ProviderId, StringComparison.OrdinalIgnoreCase)).ToList(),
                            agg.Str("provider") ?? "", agg.Str("model") ?? "", includeUseMain: false);
                        if (picked is not { } p || record is not JsonObject rootCopy) return;
                        var updated = (JsonObject)rootCopy.DeepClone();
                        if (updated.Obj("presets")?.Get(active) is JsonObject target)
                        {
                            target["aggregator"] = new JsonObject { ["provider"] = p.Provider, ["model"] = p.Model };
                            await SaveAsync(MixtureRecord.Mirrored(updated));
                        }
                    }, "moa.aggregator", enabled: !saving)));
            }

            host.Content = Kit.Page([.. sections]);
        }

        host.Unloaded += (_, _) =>
        {
            disposed = true;
            UiTree.DeactivateProgressRings(host);
        };

        Draw();
        _ = LoadAsync();
        return host;
    }

    // ---------------------------------------------------------------- Accounts & Keys sub-panes

    public static FrameworkElement MakeProviders()
    {
        var host = new ContentControl { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        if (AppState.Client is not { } client)
            return Kit.Page(Kit.Section(null, null, Kit.Row(null, "Connect to your gateway to view Providers.")));

        var api = new ModelSettingsApi(client.Session);
        var disposed = false;

        var loading = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Padding = new Thickness(14, 12, 14, 12) };
        loading.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
        loading.Children.Add(new TextBlock { Text = "Loading providers…", Foreground = Kit.B("TextFillColorSecondaryBrush") });
        host.Content = Kit.Page(Kit.Section("Providers", null, loading));

        host.Unloaded += (_, _) =>
        {
            disposed = true;
            UiTree.DeactivateProgressRings(host);
        };

        _ = Task.Run(async () =>
        {
            try
            {
                var list = await api.GetModelOptionsAsync();
                host.DispatcherQueue?.TryEnqueue(() =>
                {
                    if (disposed) return;
                    UiTree.DeactivateProgressRings(host);
                    var rows = list.Select(p => (UIElement)Kit.Value(p.Name, p.IsReady ? $"{p.Models.Count} models" : "Not Set Up")).ToArray();
                    host.Content = Kit.Page(Kit.Section("Providers",
                        "Model providers configured on your gateway.",
                        rows.Length > 0 ? rows : [Kit.Row(null, "No providers reported.")]));
                });
            }
            catch (Exception ex)
            {
                host.DispatcherQueue?.TryEnqueue(() =>
                {
                    if (disposed) return;
                    UiTree.DeactivateProgressRings(host);
                    host.Content = Kit.Page(Kit.Section("Providers", null, Kit.Row(null, "Couldn’t Load Providers", SettingsErrorText.Load(ex))));
                });
            }
        });
        return host;
    }

    public static FrameworkElement MakeKeys()
    {
        var host = new ContentControl { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        if (AppState.Client is not { } client)
            return Kit.Page(Kit.Section(null, null, Kit.Row(null, "Connect to your gateway to view Keys.")));

        var disposed = false;
        var loading = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Padding = new Thickness(14, 12, 14, 12) };
        loading.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
        loading.Children.Add(new TextBlock { Text = "Loading keys…", Foreground = Kit.B("TextFillColorSecondaryBrush") });
        host.Content = Kit.Page(Kit.Section("Keys", null, loading));

        host.Unloaded += (_, _) =>
        {
            disposed = true;
            UiTree.DeactivateProgressRings(host);
        };

        _ = Task.Run(async () =>
        {
            try
            {
                var json = await client.Session.GetJsonAsync("/api/env");
                var keys = (json.Arr("vars") ?? json.Arr("keys") ?? json as JsonArray ?? [])
                    .Select(v => (Name: v.Text("key") ?? v.Text("name") ?? "", Set: v.Bool("is_set") ?? v.Bool("has_value") ?? !string.IsNullOrEmpty(v.Text("redacted"))))
                    .Where(k => k.Name.Length > 0)
                    .ToList();
                host.DispatcherQueue?.TryEnqueue(() =>
                {
                    if (disposed) return;
                    UiTree.DeactivateProgressRings(host);
                    var rows = keys.Select(k => (UIElement)Kit.Value(k.Name, k.Set ? "Set" : "Not Set")).ToArray();
                    host.Content = Kit.Page(Kit.Section("Environment Keys",
                        "Redacted API keys and tokens configured on your gateway.",
                        rows.Length > 0 ? rows : [Kit.Row(null, "No environment keys configured.")]));
                });
            }
            catch (Exception ex)
            {
                host.DispatcherQueue?.TryEnqueue(() =>
                {
                    if (disposed) return;
                    UiTree.DeactivateProgressRings(host);
                    host.Content = Kit.Page(Kit.Section("Environment Keys", null, Kit.Row(null, "Couldn’t Load Keys", SettingsErrorText.Load(ex))));
                });
            }
        });
        return host;
    }

    public static FrameworkElement MakeBilling()
    {
        var openUsage = Kit.Push("Open Usage", () => Navigator.Open("usage"));
        var wrap = new StackPanel { Padding = new Thickness(14, 10, 14, 10) };
        wrap.Children.Add(openUsage);
        return Kit.Page(
            Kit.Section("Billing & Usage",
                "Track token usage, spending, and provider limits on the Usage page.",
                Kit.Value("Account", AppState.Client is { } c ? c.Session.Account.Username : "Signed Out"),
                wrap));
    }

    // ---------------------------------------------------------------- Shared model chooser dialog

    private static async Task<(string Provider, string Model)?> ShowModelChooserDialogAsync(
        XamlRoot? root,
        string title,
        IReadOnlyList<ModelProviderOption> providers,
        string currentProvider,
        string currentModel,
        bool includeUseMain,
        string mainProvider = "",
        string mainModel = "")
    {
        if (root == null) return null;

        var stack = new StackPanel { Spacing = 10, MinWidth = 340 };
        var useMainRequested = false;

        var providerBox = new ComboBox
        {
            Header = "Provider",
            HorizontalAlignment = HorizontalAlignment.Stretch,
            MaxWidth = 360,
        };
        var slugs = providers.Select(p => p.Slug).ToList();
        if (!string.IsNullOrEmpty(currentProvider) && !slugs.Contains(currentProvider)) slugs.Insert(0, currentProvider);
        foreach (var slug in slugs)
        {
            var p = providers.FirstOrDefault(x => x.Slug == slug);
            providerBox.Items.Add(p == null ? ModelSettingsWords.ProviderName(slug) : p.IsReady ? p.Name : $"{p.Name} (Not Set Up)");
        }
        providerBox.SelectedIndex = Math.Max(0, slugs.IndexOf(currentProvider));

        var modelBox = new ComboBox
        {
            Header = "Model",
            HorizontalAlignment = HorizontalAlignment.Stretch,
            MaxWidth = 360,
        };
        var customBox = new TextBox
        {
            Header = "Or enter model ID",
            PlaceholderText = "Model name",
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };

        List<string> activeModels = [];
        void FillModels()
        {
            modelBox.Items.Clear();
            activeModels.Clear();
            var slug = providerBox.SelectedIndex >= 0 && providerBox.SelectedIndex < slugs.Count ? slugs[providerBox.SelectedIndex] : "";
            var listed = providers.FirstOrDefault(p => p.Slug == slug)?.Models ?? [];
            if (slug == currentProvider && !string.IsNullOrEmpty(currentModel) && !listed.Contains(currentModel))
                activeModels.Add(currentModel);
            activeModels.AddRange(listed);
            foreach (var m in activeModels) modelBox.Items.Add(ModelNames.DisplayModelName(m));
            modelBox.SelectedIndex = activeModels.Count > 0 ? Math.Max(0, activeModels.IndexOf(currentModel)) : -1;
            modelBox.Visibility = activeModels.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        }
        providerBox.SelectionChanged += (_, _) => FillModels();
        FillModels();

        ContentDialog? dialog = null;
        if (includeUseMain && !string.IsNullOrEmpty(mainModel))
        {
            var useMain = Kit.Push("Use Main Model", () =>
            {
                useMainRequested = true;
                dialog?.Hide();
            });
            AutomationProperties.SetAutomationId(useMain, "aux.use-main");
            stack.Children.Add(useMain);
        }
        stack.Children.Add(providerBox);
        stack.Children.Add(modelBox);
        stack.Children.Add(customBox);

        dialog = new ContentDialog
        {
            Title = title,
            Content = stack,
            PrimaryButtonText = "Choose",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };

        var result = await SafeDialog.ShowAsync(root, dialog);
        if (useMainRequested) return (mainProvider, mainModel);
        if (result != ContentDialogResult.Primary) return null;

        var chosenProvider = providerBox.SelectedIndex >= 0 && providerBox.SelectedIndex < slugs.Count
            ? slugs[providerBox.SelectedIndex]
            : currentProvider;
        var custom = customBox.Text.Trim();
        var chosenModel = custom.Length > 0
            ? custom
            : (modelBox.SelectedIndex >= 0 && modelBox.SelectedIndex < activeModels.Count ? activeModels[modelBox.SelectedIndex] : currentModel);
        return string.IsNullOrWhiteSpace(chosenModel) ? null : (chosenProvider, chosenModel);
    }
}
