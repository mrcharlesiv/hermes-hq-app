using System.Text.Json.Nodes;
using Hermes.Core.Chat;
using Hermes.Core.Gateways;
using Hermes.Core.Settings;
using HermesHQ.Features.Workspace;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace HermesHQ.Controls;

/// Detail dialog for model and provider fallbacks (port of App/Chat/ModelFallbackViews.swift `ModelFallbackSheetView`):
/// header + kicker, route badge (primary strikethrough → fallback), explanation, "Fix on <host>" card with copyable
/// command + "Run in Terminal" + "Check/Set <ENV>", "Choose a Model", "Provider Settings", "Copy Details", and
/// collapsible "Technical details".
public static class ModelFallbackDialog
{
    private static readonly Color AmberColor = Color.FromArgb(255, 245, 158, 11);
    private static readonly Brush AmberBrush = new SolidColorBrush(AmberColor);
    private static readonly Brush AmberFill = new SolidColorBrush(Color.FromArgb(42, 245, 158, 11));
    private static readonly Brush AmberStroke = new SolidColorBrush(Color.FromArgb(105, 245, 158, 11));

    public static async Task ShowAsync(
        XamlRoot? xamlRoot,
        ModelFallbackRow.DetailModel detail,
        Action? openModels = null,
        Action? openProviders = null,
        Action<string?>? runInTerminal = null,
        Action<string>? setEnvVar = null)
    {
        if (xamlRoot == null) return;

        var technicalDump = BuildTechnicalDump(detail);
        Action? postCloseAction = null;
        ContentDialog? dialog = null;

        void DismissAndRun(Action next)
        {
            postCloseAction = next;
            dialog?.Hide();
        }

        var labelBrush = ThemeBrushes.Get("TextFillColorPrimaryBrush");
        var secondaryBrush = ThemeBrushes.Get("TextFillColorSecondaryBrush");
        var cardBg = ThemeBrushes.Get("CardBackgroundFillColorDefaultBrush");
        var cardStroke = ThemeBrushes.Get("CardStrokeColorDefaultBrush");
        var subtleBg = ThemeBrushes.Get("SubtleFillColorSecondaryBrush");
        var monoFont = TryCodeFont();

        var stack = new StackPanel { Spacing = 14, MinWidth = 440, MaxWidth = 520 };

        // Header: amber warning badge + "Switched to <fallbackName>" + kicker.
        var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        var iconBadge = new Border
        {
            Width = 38,
            Height = 38,
            CornerRadius = new CornerRadius(19),
            Background = AmberFill,
            BorderBrush = AmberStroke,
            BorderThickness = new Thickness(1),
            Child = new FontIcon
            {
                Glyph = "\uE7BA",
                FontSize = 16,
                Foreground = AmberBrush,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            },
        };
        var titleCol = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        titleCol.Children.Add(new TextBlock
        {
            Text = $"Switched to {detail.FallbackName}",
            FontSize = 16,
            FontWeight = FontWeights.SemiBold,
            Foreground = labelBrush,
            TextWrapping = TextWrapping.Wrap,
        });
        titleCol.Children.Add(new TextBlock
        {
            Text = detail.Kicker,
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            Foreground = AmberBrush,
        });
        header.Children.Add(iconBadge);
        header.Children.Add(titleCol);
        stack.Children.Add(header);

        // Route badge card: primary (strikethrough) → fallback (amber badge) + routeStatus.
        var routeGrid = new Grid { ColumnSpacing = 8 };
        routeGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        routeGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        routeGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        routeGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var primaryPill = new Border
        {
            Padding = new Thickness(9, 4, 9, 4),
            CornerRadius = new CornerRadius(6),
            Background = subtleBg,
            Child = new TextBlock
            {
                Text = detail.PrimaryName,
                FontSize = 12,
                FontWeight = FontWeights.SemiBold,
                Foreground = secondaryBrush,
                TextDecorations = Windows.UI.Text.TextDecorations.Strikethrough,
                TextTrimming = TextTrimming.CharacterEllipsis,
                MaxWidth = 170,
            },
        };
        var arrow = new FontIcon
        {
            Glyph = "\uE72A",
            FontSize = 11,
            Foreground = secondaryBrush,
            VerticalAlignment = VerticalAlignment.Center,
        };
        var fallbackPill = new Border
        {
            Padding = new Thickness(9, 4, 9, 4),
            CornerRadius = new CornerRadius(6),
            Background = AmberFill,
            BorderBrush = AmberStroke,
            BorderThickness = new Thickness(1),
            Child = new TextBlock
            {
                Text = detail.FallbackName,
                FontSize = 12,
                FontWeight = FontWeights.SemiBold,
                Foreground = labelBrush,
                TextTrimming = TextTrimming.CharacterEllipsis,
                MaxWidth = 170,
            },
        };
        var statusText = new TextBlock
        {
            Text = detail.RouteStatus,
            FontSize = 12,
            Foreground = secondaryBrush,
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(arrow, 1);
        Grid.SetColumn(fallbackPill, 2);
        Grid.SetColumn(statusText, 3);
        routeGrid.Children.Add(primaryPill);
        routeGrid.Children.Add(arrow);
        routeGrid.Children.Add(fallbackPill);
        routeGrid.Children.Add(statusText);

        var routeCard = new Border
        {
            Padding = new Thickness(12, 10, 12, 10),
            CornerRadius = new CornerRadius(10),
            Background = cardBg,
            BorderBrush = cardStroke,
            BorderThickness = new Thickness(1),
            Child = routeGrid,
        };
        AutomationProperties.SetName(routeCard, $"{detail.PrimaryName} switched to {detail.FallbackName}. {detail.RouteStatus}");
        stack.Children.Add(routeCard);

        // Plain explanation.
        var explanation = new TextBlock
        {
            Text = detail.Explanation,
            FontSize = 13.5,
            Foreground = labelBrush,
            TextWrapping = TextWrapping.Wrap,
        };
        AutomationProperties.SetAutomationId(explanation, "fallback.sheet.explanation");
        stack.Children.Add(explanation);

        // Fix card ("Fix on <host>").
        Action<string?> effectiveRunInTerminal = runInTerminal ?? DefaultRunInTerminal;
        Action<string> effectiveSetEnv = setEnvVar ?? (envKey => _ = ShowEnvVarEditorAsync(xamlRoot, envKey));

        var showsFixCard = detail.PrimaryCommand != null || detail.PrimaryEnvVar != null;
        if (showsFixCard)
        {
            var fixPanel = new StackPanel { Spacing = 10 };
            fixPanel.Children.Add(new TextBlock
            {
                Text = $"FIX ON {HostWord.Phrase.ToUpperInvariant()}",
                FontSize = 11,
                FontWeight = FontWeights.SemiBold,
                Foreground = secondaryBrush,
            });

            if (detail.PrimaryCommand is { } command)
            {
                var cmdGrid = new Grid { ColumnSpacing = 8 };
                cmdGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                cmdGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

                var cmdText = new TextBlock
                {
                    Text = command,
                    FontFamily = monoFont,
                    FontSize = 12.5,
                    Foreground = labelBrush,
                    IsTextSelectionEnabled = true,
                    TextWrapping = TextWrapping.Wrap,
                    VerticalAlignment = VerticalAlignment.Center,
                };
                var copyBtn = new Button { Content = "Copy", Padding = new Thickness(10, 4, 10, 4) };
                AutomationProperties.SetAutomationId(copyBtn, "fallback.sheet.copy-command");
                copyBtn.Click += async (_, _) =>
                {
                    SafeClipboard.TrySetText(command);
                    copyBtn.Content = "Copied";
                    await Task.Delay(1500);
                    copyBtn.Content = "Copy";
                };
                Grid.SetColumn(copyBtn, 1);
                cmdGrid.Children.Add(cmdText);
                cmdGrid.Children.Add(copyBtn);

                fixPanel.Children.Add(new Border
                {
                    Padding = new Thickness(10, 8, 10, 8),
                    CornerRadius = new CornerRadius(8),
                    Background = subtleBg,
                    Child = cmdGrid,
                });

                var runnable = detail.RunnableCommand;
                var runBtn = new Button
                {
                    Content = runnable != null ? "Run in Terminal" : "Copy & Open Terminal",
                    HorizontalAlignment = HorizontalAlignment.Stretch,
                    Style = TryStyle("AccentButtonStyle"),
                };
                AutomationProperties.SetAutomationId(runBtn, "fallback.sheet.run-terminal");
                runBtn.Click += (_, _) =>
                {
                    if (runnable != null)
                        DismissAndRun(() => effectiveRunInTerminal(runnable));
                    else
                        DismissAndRun(() =>
                        {
                            SafeClipboard.TrySetText(command);
                            effectiveRunInTerminal(null);
                        });
                };
                fixPanel.Children.Add(runBtn);
            }

            var hintText = detail.SecondaryHint
                ?? (detail.PrimaryCommand == null && detail.PrimaryEnvVar != null
                    ? $"Set {detail.PrimaryEnvVar} in Hermes’s environment."
                    : null);
            if (!string.IsNullOrEmpty(hintText))
            {
                fixPanel.Children.Add(new TextBlock
                {
                    Text = hintText.Replace("`", ""),
                    FontSize = 12,
                    Foreground = secondaryBrush,
                    TextWrapping = TextWrapping.Wrap,
                });
            }

            if (detail.PrimaryEnvVar is { } envVar)
            {
                var isInvalidToken = detail.RawText.Contains("invalid bearer token", StringComparison.OrdinalIgnoreCase);
                var envTitle = isInvalidToken ? $"Check {envVar}" : $"Set {envVar}";
                var envBtn = new Button
                {
                    Content = envTitle,
                    HorizontalAlignment = HorizontalAlignment.Stretch,
                    Style = detail.PrimaryCommand == null ? TryStyle("AccentButtonStyle") : null,
                };
                AutomationProperties.SetAutomationId(envBtn, "fallback.sheet.set-env");
                envBtn.Click += (_, _) => DismissAndRun(() => effectiveSetEnv(envVar));
                fixPanel.Children.Add(envBtn);
            }

            stack.Children.Add(new Border
            {
                Padding = new Thickness(12),
                CornerRadius = new CornerRadius(10),
                Background = cardBg,
                BorderBrush = cardStroke,
                BorderThickness = new Thickness(1),
                Child = fixPanel,
            });
        }

        // Action buttons: "Choose a Model", "Provider Settings", "Copy Details".
        var actionsPanel = new StackPanel { Spacing = 8 };
        var chooseModelBtn = new Button
        {
            Content = "Choose a Model",
            HorizontalAlignment = HorizontalAlignment.Stretch,
            Style = !showsFixCard ? TryStyle("AccentButtonStyle") : null,
        };
        AutomationProperties.SetAutomationId(chooseModelBtn, "fallback.sheet.choose-model");
        chooseModelBtn.Click += (_, _) => DismissAndRun(() =>
        {
            if (openModels != null) openModels();
            else SettingsWindows.Show("models");
        });
        actionsPanel.Children.Add(chooseModelBtn);

        var secondaryRow = new Grid { ColumnSpacing = 8 };
        secondaryRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        secondaryRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var providersBtn = new Button
        {
            Content = "Provider Settings",
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        AutomationProperties.SetAutomationId(providersBtn, "fallback.sheet.providers");
        providersBtn.Click += (_, _) => DismissAndRun(() =>
        {
            if (openProviders != null) openProviders();
            else SettingsWindows.Show("providers");
        });

        var copyDetailsBtn = new Button
        {
            Content = "Copy Details",
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        AutomationProperties.SetAutomationId(copyDetailsBtn, "fallback.sheet.copy-details");
        copyDetailsBtn.Click += async (_, _) =>
        {
            SafeClipboard.TrySetText(technicalDump);
            copyDetailsBtn.Content = "Copied";
            await Task.Delay(1500);
            copyDetailsBtn.Content = "Copy Details";
        };
        Grid.SetColumn(copyDetailsBtn, 1);
        secondaryRow.Children.Add(providersBtn);
        secondaryRow.Children.Add(copyDetailsBtn);
        actionsPanel.Children.Add(secondaryRow);
        stack.Children.Add(actionsPanel);

        // Collapsible Technical details.
        var techBox = new Border
        {
            Padding = new Thickness(10),
            CornerRadius = new CornerRadius(8),
            Background = subtleBg,
            Child = new TextBlock
            {
                Text = technicalDump,
                FontFamily = monoFont,
                FontSize = 11.5,
                Foreground = secondaryBrush,
                IsTextSelectionEnabled = true,
                TextWrapping = TextWrapping.Wrap,
            },
        };
        var expander = new Expander
        {
            Header = "Technical details",
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            IsExpanded = false,
            Content = techBox,
        };
        AutomationProperties.SetAutomationId(expander, "fallback.sheet.technical");
        stack.Children.Add(expander);

        var scroll = new ScrollViewer
        {
            Content = stack,
            MaxHeight = 560,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };

        dialog = new ContentDialog
        {
            Title = "Model Fallback",
            Content = scroll,
            CloseButtonText = "Done",
            DefaultButton = ContentDialogButton.Close,
        };
        await SafeDialog.ShowAsync(xamlRoot, dialog);
        postCloseAction?.Invoke();
    }

    public static string BuildTechnicalDump(ModelFallbackRow.DetailModel detail)
    {
        var lines = new List<string>
        {
            detail.PrimaryProvider != null
                ? $"Primary: {detail.PrimaryId} ({detail.PrimaryProvider})"
                : $"Primary: {detail.PrimaryId}",
            detail.FallbackProvider != null
                ? $"Fallback: {detail.FallbackId} ({detail.FallbackProvider})"
                : $"Fallback: {detail.FallbackId}",
            detail.RawText,
        };
        return string.Join("\n", lines);
    }

    private static void DefaultRunInTerminal(string? command)
    {
        if (!string.IsNullOrWhiteSpace(command))
            TerminalPage.OpenWithCommand(command);
        else
            Navigator.Open("terminal");
    }

    /// Lightweight env-key editor enforcing `EnvKeys.ValueProblem` (e.g. `CLAUDE_CODE_OAUTH_TOKEN` `code#state` guard).
    public static async Task ShowEnvVarEditorAsync(XamlRoot? xamlRoot, string key)
    {
        if (xamlRoot == null) return;
        var panel = new StackPanel { Spacing = 10, MinWidth = 400 };
        var fallbackDesc = EnvKeys.FallbackDescription(key);
        if (fallbackDesc.Length > 0)
        {
            panel.Children.Add(new TextBlock
            {
                Text = fallbackDesc,
                FontSize = 12.5,
                Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                TextWrapping = TextWrapping.Wrap,
            });
        }

        var box = new TextBox
        {
            Header = key,
            PlaceholderText = key == "CLAUDE_CODE_OAUTH_TOKEN" ? "sk-ant-… (or leave empty to unset)" : "Enter value (empty removes)",
        };
        AutomationProperties.SetAutomationId(box, "fallback.env.input");

        var warning = new TextBlock
        {
            FontSize = 12,
            Foreground = AmberBrush,
            TextWrapping = TextWrapping.Wrap,
            Visibility = Visibility.Collapsed,
        };
        AutomationProperties.SetAutomationId(warning, "fallback.env.warning");

        var openKeysLink = new HyperlinkButton { Content = "Open Settings › Keys" };
        panel.Children.Add(box);
        panel.Children.Add(warning);
        panel.Children.Add(openKeysLink);

        var dialog = new ContentDialog
        {
            Title = $"Configure {key}",
            Content = panel,
            PrimaryButtonText = "Save",
            SecondaryButtonText = "Unset Key",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };

        void Validate()
        {
            var problem = EnvKeys.ValueProblem(key, box.Text);
            warning.Text = problem ?? "";
            warning.Visibility = problem != null ? Visibility.Visible : Visibility.Collapsed;
            dialog.IsPrimaryButtonEnabled = problem == null;
        }
        box.TextChanged += (_, _) => Validate();
        Validate();

        var openSettings = false;
        openKeysLink.Click += (_, _) => { openSettings = true; dialog.Hide(); };

        var result = await SafeDialog.ShowAsync(xamlRoot, dialog);
        if (openSettings)
        {
            SettingsWindows.Show("keys");
            return;
        }
        if (AppState.Client is not { } client) return;

        try
        {
            if (result == ContentDialogResult.Secondary || (result == ContentDialogResult.Primary && string.IsNullOrWhiteSpace(box.Text)))
            {
                await client.Session.SendAsync(HttpMethod.Delete, $"/api/env/{Uri.EscapeDataString(key)}");
            }
            else if (result == ContentDialogResult.Primary)
            {
                var body = new JsonObject { ["key"] = key, ["value"] = box.Text.Trim() };
                await client.Session.SendAsync(HttpMethod.Post, "/api/env", body: body);
            }
        }
        catch (Exception ex)
        {
            AppLog.Note("env", $"update failed: {ex.GetType().Name}");
        }
    }

    private static FontFamily TryCodeFont()
    {
        try { return ThemeBrushes.Res<FontFamily>("CodeFont"); }
        catch (Exception) { return new FontFamily("Cascadia Mono, Consolas"); }
    }

    private static Style? TryStyle(string key)
    {
        try { return ThemeBrushes.Res<Style>(key); }
        catch (Exception) { return null; }
    }
}
