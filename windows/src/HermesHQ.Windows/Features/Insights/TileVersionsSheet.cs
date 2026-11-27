using Hermes.Core.Insights;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.Insights;

/// [tile-versions] Versions of a page tile (App/Pages/Artifacts/TileVersionsSheet.swift): "Versions" over the tile's
/// name, every version newest first with "Version 3", Current on the one that shows, what was asked and when.
/// A click opens that version full size; on writable gateways each other version offers Roll Back (with inline
/// confirmation for older versions) or Restore (immediate for newer versions).
public static class TileVersionsSheet
{
    /// `open`: a version's page, opened full size as the tile opens (after the sheet closes).
    public static async Task ShowAsync(
        XamlRoot root,
        TileVersionsModel model,
        Action<TilePin, string> open,
        Func<ContentDialog, Task<ContentDialogResult>> show,
        Action<int>? onRolledBack = null,
        string? botName = null,
        bool hasJob = false)
    {
        var ui = DispatcherQueue.GetForCurrentThread();
        var body = new StackPanel { Spacing = 8, MinWidth = 440 };
        var subtitle = Kit.Text(model.Name, 12, secondary: true, wrap: false);
        var title = new StackPanel { Children = { new TextBlock { Text = TileVersionsModel.Title }, subtitle } };
        var dialog = new ContentDialog
        {
            Title = title, XamlRoot = root, CloseButtonText = TileWords.Done, DefaultButton = ContentDialogButton.Close,
            Content = new ScrollViewer { Content = body, MaxHeight = 520, VerticalScrollBarVisibility = ScrollBarVisibility.Auto },
        };
        AutomationProperties.SetAutomationId(dialog, "tile.versions.sheet");

        int? confirmingNumber = null;

        async Task PerformRollBackAsync(int number)
        {
            confirmingNumber = null;
            var updated = await model.RollBackAsync(number);
            if (updated != null)
            {
                dialog.Hide();
                onRolledBack?.Invoke(number);
            }
        }

        void Draw()
        {
            body.Children.Clear();
            if (model.RollBackError is { } err)
            {
                var errCard = Kit.Card([new StackPanel
                {
                    Padding = new Thickness(14, 10, 14, 10),
                    Children = { Kit.Text(err, 12.5, secondary: false) },
                }]);
                errCard.BorderBrush = new SolidColorBrush(Kit.Red);
                body.Children.Add(errCard);
            }
            if (confirmingNumber is { } pending && model.Writable)
            {
                var confirmBtn = new Button { Content = TileWords.RollBack, Style = Kit.Style("AccentButtonStyle") };
                AutomationProperties.SetAutomationId(confirmBtn, "tile.versions.confirm-rollback");
                confirmBtn.Click += (_, _) => _ = PerformRollBackAsync(pending);
                var cancelBtn = new Button { Content = TileWords.Cancel };
                cancelBtn.Click += (_, _) => { confirmingNumber = null; Draw(); };
                var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { confirmBtn, cancelBtn } };
                var confirmPanel = new StackPanel
                {
                    Spacing = 8, Padding = new Thickness(14, 12, 14, 12),
                    Children =
                    {
                        Kit.Text(TileWords.RollBackConfirmTitle, 14, bold: true),
                        Kit.Text(TileVersionsModel.RollBackWords(pending, botName, hasJob), 12.5, secondary: true),
                        actions,
                    },
                };
                var card = Kit.Card([confirmPanel]);
                card.BorderBrush = Kit.Brush("AccentFillColorDefaultBrush");
                body.Children.Add(card);
            }

            switch (model.Now)
            {
                case TileVersionsModel.State.Listed listed:
                    var rows = TileVersionsModel.Rows(listed.List).Select(r =>
                    {
                        var version = listed.List.Versions.FirstOrDefault(v => v.Number == r.Number);
                        string? verb = model.Writable && !r.Current && version != null
                            ? TileVersionsModel.Verb(version, listed.List)
                            : null;
                        Action? rollBack = model.Writable && !r.Current && version != null
                            ? () =>
                            {
                                if (TileVersionsModel.AsksFirst(version, listed.List))
                                {
                                    confirmingNumber = version.Number;
                                    Draw();
                                }
                                else
                                {
                                    _ = PerformRollBackAsync(version.Number);
                                }
                            }
                            : null;
                        return (UIElement)RowView(r, () =>
                        {
                            if (version == null || model.VersionPin(version) is not { } pin) return;
                            dialog.Hide();
                            open(pin, version.Title);
                        }, verb, rollBack, model.RollingBack == r.Number, model.RollingBack != null);
                    }).ToList();
                    var footer = TileVersionsModel.Footer(listed.List, model.Writable);
                    if (rows.Count > 0) body.Children.Add(Kit.Section(null, rows, footer));
                    else body.Children.Add(new TextBlock
                    {
                        Text = footer, FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(16, 10, 16, 0),
                        Foreground = Kit.Brush("TextFillColorSecondaryBrush"),
                    });
                    break;
                case TileVersionsModel.State.Problem problem:
                    var retry = new HyperlinkButton { Content = TileVersionsModel.TryAgain, Padding = new Thickness(0) };
                    AutomationProperties.SetAutomationId(retry, "tile.versions.retry");
                    retry.Click += (_, _) => _ = model.LoadAsync();
                    body.Children.Add(Kit.Card([new StackPanel
                    {
                        Spacing = 8, Padding = new Thickness(16, 12, 16, 12),
                        Children = { Kit.Text(TileVersionsModel.ProblemTitle, 14, bold: true), Kit.Text(problem.Words, 12, secondary: true), retry },
                    }]));
                    break;
                default:
                    body.Children.Add(Kit.Card([new StackPanel
                    {
                        Orientation = Orientation.Horizontal, Spacing = 10, Padding = new Thickness(16, 12, 16, 12),
                        Children = { new ProgressRing { IsActive = true, Width = 16, Height = 16 }, Kit.Text(TileVersionsModel.ReadingWords, 14, secondary: true) },
                    }]));
                    break;
            }
        }
        void OnChanged() { if (ui.HasThreadAccess) Draw(); else ui.TryEnqueue(Draw); }
        model.Changed += OnChanged;
        Draw();
        _ = model.LoadAsync();
        try { await show(dialog); }
        finally { model.Changed -= OnChanged; }
    }

    /// One version row: "Version 3" (and Current pill), what was asked, when, plus optional Roll Back / Restore action.
    private static FrameworkElement RowView(TileVersionsModel.Row row, Action open, string? actionVerb, Action? onAction,
        bool busyThisRow, bool anyBusy)
    {
        var name = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children = { Kit.Text(row.Title, 14, bold: true, wrap: false) } };
        if (row.Current)
            name.Children.Add(new Border
            {
                CornerRadius = new CornerRadius(8), Padding = new Thickness(6, 1, 6, 1), VerticalAlignment = VerticalAlignment.Center,
                Background = Kit.Brush("AccentFillColorSecondaryBrush"),
                Child = new TextBlock { Text = "Current", FontSize = 11, FontWeight = FontWeights.SemiBold, Foreground = Kit.Brush("TextOnAccentFillColorPrimaryBrush") },
            });
        var words = Kit.Text(row.Words, 12, secondary: true);
        words.MaxLines = 2;
        words.TextTrimming = TextTrimming.CharacterEllipsis;
        var when = Kit.Text(row.When, 11, secondary: true, wrap: false);
        var openButton = new Button
        {
            HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left,
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0),
            Padding = new Thickness(16, 8, 12, 8),
            Content = new StackPanel { Spacing = 2, Children = { name, words, when } },
        };
        AutomationProperties.SetName(openButton, row.AccessibilityLabel);
        AutomationProperties.SetHelpText(openButton, "Opens this version");
        AutomationProperties.SetAutomationId(openButton, row.AutomationId);
        openButton.Click += (_, _) => open();

        if (actionVerb == null || onAction == null) return openButton;

        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(openButton);
        FrameworkElement right;
        if (busyThisRow)
        {
            right = new ProgressRing { IsActive = true, Width = 16, Height = 16, Margin = new Thickness(0, 0, 14, 0), VerticalAlignment = VerticalAlignment.Center };
        }
        else
        {
            var actionBtn = new Button
            {
                Content = actionVerb,
                FontSize = 12,
                Padding = new Thickness(10, 4, 10, 5),
                Margin = new Thickness(0, 0, 12, 0),
                VerticalAlignment = VerticalAlignment.Center,
                IsEnabled = !anyBusy,
            };
            AutomationProperties.SetName(actionBtn, $"{actionVerb} {row.Title}");
            AutomationProperties.SetAutomationId(actionBtn, $"{row.AutomationId}.rollback");
            actionBtn.Click += (_, _) => onAction();
            right = actionBtn;
        }
        Grid.SetColumn(right, 1);
        grid.Children.Add(right);
        return grid;
    }
}
