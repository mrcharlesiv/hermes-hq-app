using Hermes.Core.Composer;
using Hermes.Core.Insights;
using Hermes.Core.Settings;
using HermesHQ.Features.Insights;
using HermesHQ.Services;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.Settings;

/// Settings › Bots & Tools › Tile Model (App/Settings/Config/TileModelPage.swift): per-account Default Model &
/// Fallback Model pickers (`TileModelSettings`), `"Apply to Existing Tiles"` reconcile action
/// (`TileModelSync.ReconcileAllAsync`), and live `TileActivitySummary` with Pause/Resume All Tile Updates.
internal static class TileModelPane
{
    /// Shared store matching `TilesPage.TileModelPrefs` (`tile-models.json`) so Settings › Tile Model and each tile's
    /// Updates › Model menu read and write the same settings file.
    internal static readonly IKeyValueStore Store = new JsonFileStore(Path.Combine(AppPaths.Root, "tile-models.json"));

    internal static TileModelSettings SettingsFor(string accountId) => new(accountId, Store);

    public static FrameworkElement Make(SettingsPage page)
    {
        var host = new ContentControl { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetAutomationId(host, "tile-model.list");
        if (AppState.Client is not { } client)
            return Kit.Page(Kit.Section(null, null, Kit.Row(null, "Connect to your gateway to configure Tile Model.")));

        var accountId = client.AccountId;
        var settings = SettingsFor(accountId);
        var modelApi = new ModelSettingsApi(client.Session);
        var updates = new TileUpdates(client.Session);
        var pins = TilesPage.PinsFor(client);

        IReadOnlyList<ModelProviderOption> providers = [];
        var chosen = settings.DefaultModel;
        var fallback = settings.FallbackModel;
        var applying = false;
        string? status = null;
        var statusIsIssue = false;
        TileActivitySummary? activity = null;
        List<TileCronJob> currentJobs = [];
        var togglingAll = false;
        var disposed = false;

        void Dispatch(Action work)
        {
            if (disposed) return;
            if (host.DispatcherQueue is { } q) q.TryEnqueue(() => { if (!disposed) work(); });
            else work();
        }

        async Task LoadActivityAsync()
        {
            var pages = pins.Pins.Where(p => p.IsPage).ToList();
            if (pages.Count == 0)
            {
                currentJobs = [];
                activity = null;
                Dispatch(Draw);
                return;
            }
            try
            {
                var jobs = await updates.AllJobsAsync(pages);
                currentJobs = jobs;
                activity = TileActivitySummary.Summarize(jobs);
            }
            catch (Exception ex)
            {
                AppLog.Note("settings", $"tile model activity load failed: {ex.GetType().Name}");
            }
            Dispatch(Draw);
        }

        async Task ApplyAsync()
        {
            if (applying) return;
            AppLog.Note("settings", $"tile model: default {(chosen == null ? "bots" : "picked")}, fallback {(fallback == null ? "bots" : "picked")}");
            TileModelSync.Shared.NotifyChanged(accountId);
            applying = true;
            status = null;
            statusIsIssue = false;
            Dispatch(Draw);
            try
            {
                var (changed, failed) = await TileModelSync.Shared.ReconcileAllAsync(pins.Pins, accountId, Store, updates);
                status = TileModels.AppliedWords(changed, failed);
                statusIsIssue = failed.Count > 0;
            }
            catch (Exception ex)
            {
                status = SettingsErrorText.Save(ex);
                statusIsIssue = true;
            }
            finally
            {
                applying = false;
                Dispatch(Draw);
                await LoadActivityAsync();
            }
        }

        void SetDefault(TileModelPick? pick)
        {
            if (pick == chosen) return;
            chosen = pick;
            settings.DefaultModel = pick;
            _ = ApplyAsync();
        }

        void SetFallback(TileModelPick? pick)
        {
            if (pick == fallback) return;
            fallback = pick;
            settings.FallbackModel = pick;
            _ = ApplyAsync();
        }

        async Task OpenChooserAsync(bool isFallback)
        {
            var current = isFallback ? fallback : chosen;
            var title = isFallback ? "Fallback Model" : "Default Model";
            var note = isFallback
                ? "Tried when a tile’s picked model fails."
                : "Every tile’s job runs this unless the tile has its own.";
            var picked = await ShowModelChooserDialogAsync(host.XamlRoot ?? page.XamlRoot, title, note, providers,
                current?.Provider ?? "", current?.Model ?? "");
            if (picked is not { } p) return;
            var pick = new TileModelPick(p.Provider, p.Model);
            if (isFallback) SetFallback(pick);
            else SetDefault(pick);
        }

        async Task ToggleAllUpdatesAsync(bool pause)
        {
            if (togglingAll) return;
            togglingAll = true;
            Dispatch(Draw);
            try
            {
                foreach (var job in currentJobs)
                {
                    if (TileJobs.IsPaused(job) == pause) continue;
                    try { await updates.SetPausedAsync(job, pause); }
                    catch (Exception ex) { AppLog.Note("settings", $"tile toggle pause failed: {ex.GetType().Name}"); }
                }
            }
            finally
            {
                togglingAll = false;
                await LoadActivityAsync();
            }
        }

        UIElement ChoiceRow(string title, string? subtitle, bool selected, string id, Action onPick)
        {
            var grid = new Grid { Padding = new Thickness(14, 10, 14, 10), ColumnSpacing = 12, MinHeight = 44 };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var ring = new Border
            {
                Width = 16,
                Height = 16,
                CornerRadius = new CornerRadius(8),
                BorderThickness = new Thickness(selected ? 5 : 1.5),
                BorderBrush = Kit.B(selected ? "AccentFillColorDefaultBrush" : "TextFillColorSecondaryBrush"),
                VerticalAlignment = VerticalAlignment.Center,
            };
            AutomationProperties.SetAccessibilityView(ring, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
            grid.Children.Add(ring);

            var words = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
            words.Children.Add(new TextBlock
            {
                Text = title,
                MaxLines = 1,
                TextTrimming = TextTrimming.CharacterEllipsis,
                Foreground = Kit.B("TextFillColorPrimaryBrush"),
            });
            if (!string.IsNullOrEmpty(subtitle))
            {
                words.Children.Add(new TextBlock
                {
                    Text = subtitle,
                    FontSize = 12,
                    Foreground = Kit.B("TextFillColorSecondaryBrush"),
                });
            }
            Grid.SetColumn(words, 1);
            grid.Children.Add(words);

            if (selected)
            {
                var check = new FontIcon
                {
                    Glyph = "\uE73E",
                    FontSize = 12,
                    VerticalAlignment = VerticalAlignment.Center,
                    Foreground = Kit.B("AccentTextFillColorPrimaryBrush"),
                };
                Grid.SetColumn(check, 2);
                grid.Children.Add(check);
            }

            var btn = new Button
            {
                Content = grid,
                Padding = new Thickness(0),
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Stretch,
                Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
                BorderThickness = new Thickness(0),
                CornerRadius = new CornerRadius(0),
                IsEnabled = !applying,
            };
            AutomationProperties.SetName(btn, subtitle == null ? title : $"{title}, {subtitle}");
            AutomationProperties.SetAutomationId(btn, id);
            if (selected) AutomationProperties.SetItemStatus(btn, "Selected");
            btn.Click += (_, _) => onPick();
            return btn;
        }

        void Draw()
        {
            if (disposed) return;
            UiTree.DeactivateProgressRings(host);
            var sections = new List<UIElement?>();

            // 1. Default Model
            sections.Add(Kit.Section("Default Model", TileModels.DefaultFooter,
                ChoiceRow(TileModels.EachBotsModel, null, chosen == null, "tile-model.default.bots", () => SetDefault(null)),
                ChoiceRow(chosen != null ? TileModels.Name(chosen) : "Choose a Model…",
                    chosen != null ? ModelSettingsWords.ProviderName(chosen.Provider, providers) : null,
                    chosen != null, "tile-model.default.pick", () => _ = OpenChooserAsync(isFallback: false))));

            // 2. Fallback Model
            sections.Add(Kit.Section("Fallback Model", TileModels.Footer(chosen, fallback),
                ChoiceRow(TileModels.EachBotsFallback, null, fallback == null, "tile-model.fallback.bots", () => SetFallback(null)),
                ChoiceRow(fallback != null ? TileModels.Name(fallback) : "Choose a Model…",
                    fallback != null ? ModelSettingsWords.ProviderName(fallback.Provider, providers) : null,
                    fallback != null, "tile-model.fallback.pick", () => _ = OpenChooserAsync(isFallback: true))));

            // 3. Apply to Existing Tiles + Status
            var applyRows = new List<UIElement?>();
            var applyBtn = Kit.Push("Apply to Existing Tiles", () => _ = ApplyAsync());
            applyBtn.IsEnabled = !applying;
            AutomationProperties.SetAutomationId(applyBtn, "tile-model.apply");
            applyRows.Add(Kit.Row("\uE895", "Apply to Existing Tiles",
                "Updates every scheduled tile job to match the choices above.", applyBtn, "row:tile-model-apply"));

            if (applying)
            {
                var spin = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Padding = new Thickness(14, 10, 14, 10) };
                spin.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
                spin.Children.Add(new TextBlock
                {
                    Text = "Updating your tiles…",
                    Foreground = Kit.B("TextFillColorSecondaryBrush"),
                    VerticalAlignment = VerticalAlignment.Center,
                });
                applyRows.Add(spin);
            }
            else if (!string.IsNullOrEmpty(status))
            {
                var statusText = new TextBlock
                {
                    Text = status,
                    FontSize = 12,
                    TextWrapping = TextWrapping.Wrap,
                    Margin = new Thickness(14, 10, 14, 10),
                    Foreground = Kit.B(statusIsIssue ? "SystemFillColorCriticalBrush" : "TextFillColorSecondaryBrush"),
                };
                AutomationProperties.SetAutomationId(statusText, "tile-model.status");
                applyRows.Add(statusText);
            }
            sections.Add(Kit.Section(null, null, [.. applyRows]));

            // 4. Tile Activity Summary
            if (activity is { } act)
            {
                var actRows = new List<UIElement?>();
                var summaryStack = new StackPanel { Spacing = 3, Padding = new Thickness(14, 10, 14, 10) };
                summaryStack.Children.Add(new TextBlock
                {
                    Text = act.Headline,
                    FontWeight = FontWeights.SemiBold,
                    Foreground = Kit.B("TextFillColorPrimaryBrush"),
                    TextWrapping = TextWrapping.Wrap,
                });
                if (!string.IsNullOrEmpty(act.Detail))
                {
                    summaryStack.Children.Add(new TextBlock
                    {
                        Text = act.Detail,
                        FontSize = 12,
                        TextWrapping = TextWrapping.Wrap,
                        Foreground = Kit.B(act.FailingJobs > 0 ? "SystemFillColorCriticalBrush" : "TextFillColorSecondaryBrush"),
                    });
                }
                AutomationProperties.SetAutomationId(summaryStack, "tile-model.activity");
                actRows.Add(summaryStack);

                if (act.TotalJobs > 0)
                {
                    var willPause = act.ActiveJobs > 0;
                    var trailing = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
                    if (togglingAll)
                        trailing.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
                    var toggleBtn = Kit.Push(willPause ? "Pause All Tile Updates" : "Resume All Tile Updates",
                        () => _ = ToggleAllUpdatesAsync(willPause));
                    toggleBtn.IsEnabled = !togglingAll;
                    AutomationProperties.SetAutomationId(toggleBtn, "tile-model.toggle-all");
                    trailing.Children.Add(toggleBtn);
                    actRows.Add(Kit.Row(willPause ? "\uE769" : "\uE768",
                        willPause ? "Pause All Tile Updates" : "Resume All Tile Updates",
                        null, trailing, "row:tile-model-toggle-all"));
                }
                sections.Add(Kit.Section("Tile Activity", null, [.. actRows]));
            }

            host.Content = Kit.Page([.. sections]);
        }

        host.Unloaded += (_, _) =>
        {
            disposed = true;
            UiTree.DeactivateProgressRings(host);
        };

        Draw();
        _ = Task.Run(async () =>
        {
            try { providers = await modelApi.GetModelOptionsAsync(); }
            catch (Exception) { }
            await LoadActivityAsync();
        });
        return host;
    }

    private static async Task<(string Provider, string Model)?> ShowModelChooserDialogAsync(
        XamlRoot? root,
        string title,
        string note,
        IReadOnlyList<ModelProviderOption> providers,
        string currentProvider,
        string currentModel)
    {
        if (root == null) return null;

        var stack = new StackPanel { Spacing = 10, MinWidth = 340 };
        stack.Children.Add(new TextBlock
        {
            Text = note,
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
            Foreground = Kit.B("TextFillColorSecondaryBrush"),
        });

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

        stack.Children.Add(providerBox);
        stack.Children.Add(modelBox);
        stack.Children.Add(customBox);

        var dialog = new ContentDialog
        {
            Title = title,
            Content = stack,
            PrimaryButtonText = "Choose",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };

        if (await SafeDialog.ShowAsync(root, dialog) != ContentDialogResult.Primary) return null;

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
