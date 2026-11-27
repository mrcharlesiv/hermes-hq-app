using Hermes.Core.Composer;
using Hermes.Core.Net;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Windows.ApplicationModel.DataTransfer;

namespace HermesHQ.Features.Composer;

/// ⋯ › Model Prices (App/Chat/Menus/ModelPricesSheet.swift): each signed-in provider's models with their price per
/// million tokens — the gateway's where it has them, models.dev list prices otherwise (kept a day), "Included" for a
/// subscription — the chat's provider first, "Search Models", right-click to Copy Model ID or Copy Price.
internal static class PricesDialog
{
    public static async Task ShowAsync(XamlRoot root, ChatComposer c)
    {
        var ui = DispatcherQueue.GetForCurrentThread();
        var dialog = new ContentDialog { Title = ModelPricesModel.Title, CloseButtonText = "Done", DefaultButton = ContentDialogButton.Close };
        var search = new TextBox { PlaceholderText = ModelPricesModel.SearchPlaceholder };
        AutomationProperties.SetName(search, ModelPricesModel.SearchPlaceholder);
        var list = new StackPanel();
        var content = new StackPanel { Width = 480, Spacing = 8 };
        content.Children.Add(search);
        content.Children.Add(new ScrollViewer { Content = list, Height = 420 });
        dialog.Content = content;

        var loading = true;
        Exception? failure = null;
        ModelsDevPrices? fallback = ComposerServices.ModelsDev.Stored();
        var lookingUp = false;
        var fallbackFailed = false;
        var open = true;

        void Draw()
        {
            list.Children.Clear();
            var options = c.Options;
            if (options == null)
            {
                list.Children.Add(Ui.Text(loading ? ModelPricesModel.Loading
                    : failure != null ? ModelPricesModel.LoadFailed + (ModelLoad.Words(failure, c.Offline) is { } w ? " " + w : "") : "", 13, secondary: true));
                if (!loading && failure != null)
                {
                    var again = new Button { Content = "Try Again" };
                    again.Click += (_, _) => Load();
                    list.Children.Add(again);
                }
                return;
            }
            var current = c.Current();
            var sections = ModelPricesModel.Sections(options, fallback, fallbackFailed, search.Text, (current.Id, current.Provider));
            if (sections.Count == 0)
            {
                list.Children.Add(Ui.Text(search.Text.Trim().Length > 0 ? $"No Results for “{search.Text.Trim()}”" : ModelPricesModel.Empty, 13, secondary: true));
                return;
            }
            if (lookingUp) list.Children.Add(Ui.Text(ModelPricesModel.LookingUp, 12, secondary: true));
            foreach (var section in sections)
            {
                list.Children.Add(Ui.Header(section.Title));
                foreach (var row in section.Rows) list.Children.Add(Row(row));
                if (section.Footer != null) list.Children.Add(Ui.Text(section.Footer, 12, secondary: true));
            }
        }

        UIElement Row(PriceRow row)
        {
            var grid = new Grid { ColumnSpacing = 10, Padding = new Thickness(8, 4, 8, 4) };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var words = new StackPanel();
            words.Children.Add(Ui.Text(row.Name, 14, bold: row.Current, wrap: false));
            if (row.Current) words.Children.Add(Ui.Text("This Chat", 12, secondary: true));
            grid.Children.Add(words);
            var price = Ui.Text(row.Detail, 13, secondary: !row.Priced, wrap: false);
            Grid.SetColumn(price, 1);
            grid.Children.Add(price);
            ToolTipService.SetToolTip(grid, row.Model);
            AutomationProperties.SetName(grid, $"{row.Name}, {row.Detail}");
            var menu = new MenuFlyout();
            foreach (var (title, text) in new[] { ("Copy Model ID", row.Model), ("Copy Price", row.Detail) })
            {
                var item = new MenuFlyoutItem { Text = title };
                item.Click += (_, _) => HermesHQ.Services.SafeClipboard.TrySetText(text);
                menu.Items.Add(item);
            }
            grid.ContextFlyout = menu;
            return grid;
        }

        void Load()
        {
            loading = true;
            failure = null;
            Draw();
            _ = Task.Run(async () =>
            {
                for (var pass = 0; pass < 2 && open; pass++)
                {
                    try { await c.LoadModelsAsync(reread: true); failure = null; }
                    catch (Exception x) { failure = x; }
                    loading = false;
                    ui.TryEnqueue(Draw);
                    if (c.Options is { } o && ModelPricesModel.NeedsFallback(o) && fallback == null)
                    {
                        lookingUp = true;
                        ui.TryEnqueue(Draw);
                        fallback = await ComposerServices.ModelsDev.LoadAsync();
                        fallbackFailed = fallback == null;
                        lookingUp = false;
                        ui.TryEnqueue(Draw);
                    }
                    // The gateway warms its prices after a read: ask once more a few seconds later.
                    if (c.Options is not { } again || !ModelPricesModel.WorthAskingAgain(again)) break;
                    await Task.Delay(TimeSpan.FromSeconds(4));
                }
            });
        }

        search.TextChanged += (_, _) => Draw();
        Load();
        try { await Ui.Show(root, dialog); }
        finally { open = false; }
    }
}
