using Hermes.Core.Tasks;
using HermesHQ.Features.Kanban;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;
using static HermesHQ.Features.Kanban.PageKit;

namespace HermesHQ.Features.Tasks;

/// [WIN-TASK-LIST-EDIT] Edit List (App/Pages/Tasks/TaskListViews.swift TaskListEditView, 93f984bb1; a list pill's
/// Edit List…): the list's name, and on an add-on that keeps lists its Colour, Icon, the bot that keeps it (Kept By,
/// New Tasks), Show in Today, then Delete List…. Each change saves at once through TaskListEditModel (the whole lists on
/// `PUT /tasks/sections`); a refused save puts the control back and the page's notice says why. Delete List… closes the
/// editor first and then asks, as the Mac dismisses the sheet before its alert.
internal static class TaskListEditDialog
{
    /// The Mac's SF Symbol for each icon, drawn here with a Segoe Fluent glyph, or an emoji where the font has none.
    private static (string Glyph, bool Emoji) Face(string icon) => icon switch
    {
        "briefcase" => ("\uE821", false),
        "house" => ("\uE80F", false),
        "cart" => ("\uE7BF", false),
        "heart" => ("\uEB51", false),
        "star" => ("\uE734", false),
        "book" => ("\uE82D", false),
        "airplane" => ("\uE709", false),
        "dollarsign.circle" => ("\uE8C7", false),
        "person.2" => ("\uE716", false),
        "wrench.and.screwdriver" => ("\uE90F", false),
        "leaf" => ("\U0001F343", true),
        "graduationcap" => ("\uE7BE", false),
        "gift" => ("\U0001F381", true),
        "pawprint" => ("\U0001F43E", true),
        "flag" => ("\uE7C1", false),
        _ => ("\uE8FD", false),
    };

    private static FrameworkElement Glyph(string icon, double size, Brush? color)
    {
        var (glyph, emoji) = Face(icon);
        if (emoji) return new TextBlock { Text = glyph, FontSize = size, FontFamily = new FontFamily("Segoe UI Emoji"), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        var f = new FontIcon { Glyph = glyph, FontSize = size, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        if (color != null) f.Foreground = color;
        return f;
    }

    private static Color Ink(string? color) => GoalTints.Rgb(color ?? "blue") is var (r, g, b) ? Rgb(r, g, b) : Blue;

    /// Shows Edit List for `model`'s list. true when Delete List… was pressed (the caller then asks to delete).
    public static async Task<bool> PresentAsync(XamlRoot? root, TaskListEditModel model)
    {
        var ui = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
        var body = new StackPanel { Spacing = 6, MinWidth = 380 };
        var scroll = new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, MaxHeight = 560 };
        AutomationProperties.SetAutomationId(scroll, "tasks.list-edit");
        var deleting = false;
        ContentDialog? dialog = null;

        void Header(string text)
        {
            var t = Text(text, 13, bold: true, color: Secondary);
            t.Margin = new Thickness(0, 14, 0, 2);
            AutomationProperties.SetHeadingLevel(t, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level2);
            body.Children.Add(t);
        }
        void Footer(string text) => body.Children.Add(Text(text, 12, color: Secondary));
        void Row(string label, FrameworkElement control)
        {
            var grid = new Grid { ColumnSpacing = 12, MinHeight = 36 };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var l = Text(label, 14);
            l.VerticalAlignment = VerticalAlignment.Center;
            grid.Children.Add(l);
            control.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(control, 1);
            grid.Children.Add(control);
            body.Children.Add(grid);
        }

        void Build()
        {
            body.Children.Clear();
            var draft = model.Draft;
            var color = model.Color;

            // The name, after the list's mark (its colour and icon).
            var top = new Grid { ColumnSpacing = 10 };
            top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(24) });
            top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            top.Children.Add(Glyph(model.ShownIcon, 16, color == null ? Secondary : Solid(Ink(color))));
            var name = new TextBox { Text = model.Name, PlaceholderText = TaskListEditCopy.NamePlaceholder };
            AutomationProperties.SetName(name, TaskListEditCopy.NamePlaceholder);
            AutomationProperties.SetAutomationId(name, "tasks.list-edit.name");
            name.TextChanged += (_, _) => model.Name = name.Text;
            name.KeyDown += (_, e) =>
            {
                if (e.Key != Windows.System.VirtualKey.Enter) return;
                e.Handled = true;
                _ = model.CommitNameAsync();
                name.Text = model.Name;
            };
            name.LostFocus += (_, _) => { if (!deleting) _ = model.CommitNameAsync(); };
            Grid.SetColumn(name, 1);
            top.Children.Add(name);
            body.Children.Add(top);

            if (model.ShowsExtras)
            {
                Header(TaskListEditCopy.Colour);
                var swatches = new VariableSizedWrapGrid { Orientation = Orientation.Horizontal, ItemWidth = 40, ItemHeight = 40 };
                foreach (var choice in TodoListColors.All)
                {
                    var picked = choice == color;
                    var face = new Grid { Width = 36, Height = 36 };
                    if (picked) face.Children.Add(new Ellipse { Width = 36, Height = 36, Stroke = Solid(Ink(choice)), StrokeThickness = 2 });
                    face.Children.Add(new Ellipse { Width = 28, Height = 28, Fill = Solid(Ink(choice)) });
                    if (picked) face.Children.Add(new FontIcon { Glyph = "\uE73E", FontSize = 13, FontWeight = FontWeights.Bold, Foreground = Solid(Microsoft.UI.Colors.White) });
                    var swatch = new Button { Content = face, Padding = new Thickness(0), Style = Style("QuietButtonStyle") };
                    AutomationProperties.SetName(swatch, TodoListColors.Name(choice));
                    AutomationProperties.SetItemStatus(swatch, picked ? "Selected" : "");
                    AutomationProperties.SetAutomationId(swatch, "tasks.list-edit.color." + choice);
                    var c = choice;
                    swatch.Click += (_, _) => _ = model.PickColorAsync(c);
                    swatches.Children.Add(swatch);
                }
                body.Children.Add(swatches);
                Footer(TaskListEditCopy.ColourFooter);

                Header(TaskListEditCopy.Icon);
                var icons = new VariableSizedWrapGrid { Orientation = Orientation.Horizontal, ItemWidth = 44, ItemHeight = 44 };
                foreach (var icon in TodoListIcons.All)
                {
                    var picked = (draft.Icon ?? "") == icon;
                    var face = new Grid { Width = 36, Height = 36 };
                    face.Children.Add(new Ellipse
                    {
                        Width = 36, Height = 36,
                        Fill = picked ? (color == null ? Brush("AccentFillColorDefaultBrush") : Solid(Ink(color))) : Brush("ControlFillColorSecondaryBrush"),
                    });
                    face.Children.Add(Glyph(icon, 16, picked ? Brush("TextOnAccentFillColorPrimaryBrush") : null));
                    var button = new Button { Content = face, Padding = new Thickness(0), Style = Style("QuietButtonStyle") };
                    AutomationProperties.SetName(button, TodoListIcons.Spoken(icon));
                    AutomationProperties.SetItemStatus(button, picked ? "Selected" : "");
                    AutomationProperties.SetAutomationId(button, "tasks.list-edit.icon." + icon);
                    var i = icon;
                    button.Click += (_, _) => _ = model.PickIconAsync(i);
                    icons.Children.Add(button);
                }
                body.Children.Add(icons);

                Header(TaskListEditCopy.Bot);
                var keeper = new ComboBox { MinWidth = 180 };
                keeper.Items.Add(new ComboBoxItem { Content = TaskListEditCopy.NoOne, Tag = "" });
                foreach (var (id, botName) in model.Bots) keeper.Items.Add(new ComboBoxItem { Content = botName, Tag = id });
                if (draft.Bot is { } kept && !model.Bots.Any(b => b.Id == kept)) keeper.Items.Add(new ComboBoxItem { Content = model.BotName(kept), Tag = kept });
                keeper.SelectedIndex = Math.Max(0, keeper.Items.Cast<ComboBoxItem>().ToList().FindIndex(x => (string)x.Tag == (draft.Bot ?? "")));
                AutomationProperties.SetName(keeper, TaskListEditCopy.KeptBy);
                AutomationProperties.SetAutomationId(keeper, "tasks.list-edit.bot");
                keeper.SelectionChanged += (_, _) =>
                {
                    if (keeper.SelectedItem is ComboBoxItem { Tag: string id } && id != (model.Draft.Bot ?? "")) _ = model.SetBotAsync(id);
                };
                Row(TaskListEditCopy.KeptBy, keeper);
                if (model.ShowsNewTasks)
                {
                    var adds = new ComboBox { MinWidth = 180 };
                    adds.Items.Add(new ComboBoxItem { Content = TaskListEditCopy.AddWithoutAsking, Tag = false });
                    adds.Items.Add(new ComboBoxItem { Content = TaskListEditCopy.AskFirst, Tag = true });
                    adds.SelectedIndex = draft.AsksFirst ? 1 : 0;
                    AutomationProperties.SetName(adds, TaskListEditCopy.NewTasks);
                    AutomationProperties.SetAutomationId(adds, "tasks.list-edit.adds");
                    adds.SelectionChanged += (_, _) =>
                    {
                        if (adds.SelectedItem is ComboBoxItem { Tag: bool ask } && ask != model.Draft.AsksFirst) _ = model.SetAsksFirstAsync(ask);
                    };
                    Row(TaskListEditCopy.NewTasks, adds);
                }
                Footer(model.BotFooter);

                var today = new ToggleSwitch { IsOn = draft.InToday, OnContent = "", OffContent = "" };
                AutomationProperties.SetName(today, TaskListEditCopy.ShowInToday);
                AutomationProperties.SetAutomationId(today, "tasks.list-edit.today");
                today.Toggled += (_, _) => { if (today.IsOn != model.Draft.InToday) _ = model.SetInTodayAsync(today.IsOn); };
                var spacer = new Border { Height = 10 };
                body.Children.Add(spacer);
                Row(TaskListEditCopy.ShowInToday, today);
                Footer(TaskListEditCopy.TodayFooter);
            }

            var face2 = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            face2.Children.Add(new FontIcon { Glyph = "\uE74D", FontSize = 14, Foreground = Critical });
            face2.Children.Add(new TextBlock { Text = TaskListEditCopy.DeleteList, Foreground = Critical });
            var delete = new Button { Content = face2, Margin = new Thickness(0, 18, 0, 0), Style = Style("QuietButtonStyle") };
            AutomationProperties.SetName(delete, TaskListEditCopy.DeleteList);
            AutomationProperties.SetAutomationId(delete, "tasks.list-edit.delete");
            delete.Click += (_, _) => { deleting = true; dialog?.Hide(); };
            body.Children.Add(delete);
        }

        model.Changed += () => ui.TryEnqueue(Build);
        Build();
        dialog = new ContentDialog
        {
            Title = TaskListEditCopy.Title, Content = scroll, CloseButtonText = TaskListEditCopy.Done, DefaultButton = ContentDialogButton.Close,
        };
        // Done (or Esc) keeps the name as typed, as the Mac's sheet does on disappearing.
        dialog.Closing += (_, _) => { if (!deleting) _ = model.CommitNameAsync(); };
        await PageKit.ShowAsync(root, dialog);
        return deleting;
    }
}
