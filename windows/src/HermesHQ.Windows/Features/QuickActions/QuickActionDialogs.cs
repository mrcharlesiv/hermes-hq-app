using Hermes.Core.QuickActions;
using HermesHQ.Features.Kanban;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Features.QuickActions;

/// Add Action and Set Up / Edit Action (App/QuickActions/QuickActionSetup.swift): pick an action or a page, then name
/// it, choose its bot, its words and its colour. Windows offers only the kinds it has a route for
/// (QuickTileRules.Windows).
internal static class QuickActionDialogs
{
    /// Add Action: the Chats, Work and Pages groups, searchable. Null: cancelled.
    public static async Task<QuickActionChoice?> ChooseAsync(XamlRoot? root, IReadOnlyList<QuickActionChoice> pages)
    {
        QuickActionChoice? picked = null;
        var dialog = new ContentDialog { Title = "Add Action", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
        var search = new TextBox { PlaceholderText = "Search actions and pages" };
        AutomationProperties.SetName(search, "Search actions and pages");
        AutomationProperties.SetAutomationId(search, "quick-actions.add.search");
        var list = new StackPanel { Spacing = 4 };
        void Fill()
        {
            list.Children.Clear();
            var groups = QuickActionChoice.Groups(pages, search.Text, QuickTileRules.Windows);
            if (groups.Count == 0)
            {
                list.Children.Add(PageKit.Text(QuickActionChoice.NoMatch(search.Text.Trim()), 13, color: PageKit.Secondary));
                return;
            }
            foreach (var (header, rows) in groups)
            {
                list.Children.Add(new TextBlock { Text = header, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 8, 0, 2) });
                foreach (var choice in rows)
                {
                    var face = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
                    var look = choice.Kind.DefaultLook();
                    face.Children.Add(new Border
                    {
                        Width = 28, Height = 28, CornerRadius = new CornerRadius(6), Background = QuickActionsPage.TileBrush(look.Color),
                        Child = new FontIcon { Glyph = QuickActionsPage.Glyph(look.Symbol), FontSize = 14, Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.White) },
                    });
                    var words = new StackPanel();
                    words.Children.Add(new TextBlock { Text = choice.Title });
                    words.Children.Add(new TextBlock { Text = choice.Detail, FontSize = 12, Foreground = PageKit.Secondary });
                    face.Children.Add(words);
                    var row = new Button { Content = face, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left };
                    AutomationProperties.SetName(row, $"{choice.Title}, {choice.Detail}");
                    AutomationProperties.SetAutomationId(row, "quick-actions.add." + choice.Id);
                    row.Click += (_, _) => { picked = choice; dialog.Hide(); };
                    list.Children.Add(row);
                }
            }
        }
        search.TextChanged += (_, _) => Fill();
        Fill();
        var panel = new StackPanel { Spacing = 8, MinWidth = 360 };
        panel.Children.Add(search);
        panel.Children.Add(new ScrollViewer { Content = list, MaxHeight = 460 });
        dialog.Content = panel;
        await PageKit.ShowAsync(root, dialog);
        return picked;
    }

    /// Set Up (a new tile: Add) or Edit Action (Save). Null: cancelled. Fields keep what this form doesn't show.
    /// `jobs`: the Jobs list's jobs (key, title) for a Run Job tile. Edit Action with changes asks Discard Changes? on
    /// Cancel or Escape (Keep Editing its default) and comes back with every field and the focused one as they were; a
    /// new tile's Set Up leaves without asking, as on the Mac (QuickActionSetupDraft). The tile is returned only by the
    /// one Save or Add.
    public static async Task<QuickTile?> SetUpAsync(XamlRoot? root, QuickTile start, bool isNew, IReadOnlyList<(string Id, string Name)> bots,
        IReadOnlyList<(string Key, string Name)>? jobs = null)
    {
        var tile = start;
        var kind = tile.Known;
        // QuickActionDraft.nameTouched: an edited tile's name is its own; a new one follows its job until one is typed.
        var nameTouched = !isNew;
        var following = false;
        TextBox? nameBox = null;
        var dialog = new ContentDialog
        {
            Title = isNew ? "Set Up" : "Edit Action", PrimaryButtonText = isNew ? "Add" : "Save", CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        AutomationProperties.SetAutomationId(dialog, "quick-actions.setup-sheet");
        var form = new StackPanel { Spacing = 12, MinWidth = 360 };
        void Refresh() => dialog.IsPrimaryButtonEnabled = QuickTileDraft.CanSave(tile);
        // The fields Keep Editing gives focus back to (the last one focused).
        var fields = new List<Control>();

        if (kind is { } k && (k.NeedsBot() || k == QuickTileKind.AddTask))
        {
            var picker = new ComboBox { Header = k == QuickTileKind.AddTask ? "Task For" : "Bot", HorizontalAlignment = HorizontalAlignment.Stretch };
            AutomationProperties.SetAutomationId(picker, "quick.setup.bot");
            var ids = new List<string?>();
            if (k == QuickTileKind.AddTask) { picker.Items.Add("None"); ids.Add(null); }
            foreach (var (id, name) in bots) { picker.Items.Add(name); ids.Add(id); }
            var at = ids.IndexOf(tile.Bot);
            if (at < 0 && k.NeedsBot() && bots.Count > 0)
            {
                // A new tile starts with the roster's first bot (an Open a Chat tile is named for it).
                at = ids.IndexOf(bots[0].Id);
                tile = tile with { Bot = bots[0].Id, BotName = bots[0].Name, Name = k == QuickTileKind.OpenChat && tile.Name == "Open Chat" ? bots[0].Name : tile.Name };
            }
            if (at < 0 && k == QuickTileKind.AddTask) at = 0;
            picker.SelectedIndex = at;
            picker.SelectionChanged += (_, _) =>
            {
                var i = picker.SelectedIndex;
                var id = i >= 0 && i < ids.Count ? ids[i] : null;
                var name = id == null ? null : bots.First(b => b.Id == id).Name;
                // An Open a Chat tile still named for its old bot follows the new one (its default name is the bot's).
                var renamed = k == QuickTileKind.OpenChat && (tile.Name == (tile.BotName ?? "") || tile.Name == "Open Chat") && name != null;
                tile = tile with { Bot = id, BotName = name, Name = renamed ? name! : tile.Name };
                Refresh();
            };
            form.Children.Add(picker);
            fields.Add(picker);
        }

        if (kind is QuickTileKind.NewChat or QuickTileKind.Send)
        {
            var send = kind == QuickTileKind.Send;
            var words = new TextBox
            {
                Header = "Message", PlaceholderText = send ? "Message" : "First Message (Optional)", AcceptsReturn = true, Text = tile.Message ?? "",
                TextWrapping = TextWrapping.Wrap, MinHeight = 64,
            };
            AutomationProperties.SetAutomationId(words, "quick.setup.message");
            words.TextChanged += (_, _) => { tile = tile with { Message = QuickActionSetupDraft.Words(words.Text) }; Refresh(); };
            form.Children.Add(words);
            fields.Add(words);
            var flag = new ToggleSwitch { Header = send ? "Open the Chat" : "Send It", IsOn = tile.Flag ?? !send };
            AutomationProperties.SetAutomationId(flag, send ? "quick.setup.open" : "quick.setup.send");
            flag.Toggled += (_, _) => tile = tile with { Flag = flag.IsOn };
            form.Children.Add(flag);
            fields.Add(flag);
        }

        if (kind == QuickTileKind.RunJob)
        {
            // The Job section (QuickActionSetup's Picker("Job")): the list's jobs, the tile's own kept when it's gone.
            var choices = QuickTileRun.JobChoices(tile, jobs ?? []);
            if (isNew && string.IsNullOrEmpty(tile.Job) && choices.Count > 0) tile = QuickTileRun.PickJob(tile, choices[0].Key, choices, nameTouched);
            var picker = new ComboBox { Header = "Job", PlaceholderText = "Choose", HorizontalAlignment = HorizontalAlignment.Stretch };
            AutomationProperties.SetAutomationId(picker, "quick.setup.job");
            foreach (var (_, name) in choices) picker.Items.Add(name);
            picker.SelectedIndex = choices.ToList().FindIndex(j => j.Key == tile.Job);
            picker.SelectionChanged += (_, _) =>
            {
                var i = picker.SelectedIndex;
                tile = QuickTileRun.PickJob(tile, i >= 0 && i < choices.Count ? choices[i].Key : null, choices, nameTouched);
                if (nameBox != null && nameBox.Text != tile.Name) { following = true; nameBox.Text = tile.Name; following = false; }
                Refresh();
            };
            form.Children.Add(picker);
            fields.Add(picker);
            if (choices.Count == 0)
                form.Children.Add(PageKit.Text("Open Jobs once, and its jobs are listed here.", 12, color: PageKit.Secondary));
        }

        nameBox = new TextBox { Header = "Name", PlaceholderText = "Name", Text = tile.Name };
        AutomationProperties.SetAutomationId(nameBox, "quick.setup.name");
        nameBox.TextChanged += (_, _) =>
        {
            // TextChanged comes after the change: only words that differ from the tile's name are typed ones.
            if (!following && nameBox.Text != tile.Name) nameTouched = true;
            tile = tile with { Name = nameBox.Text };
            Refresh();
        };
        form.Children.Add(nameBox);
        fields.Add(nameBox);

        var colors = Enum.GetValues<QuickTileColor>();
        var colorPicker = new ComboBox { Header = "Color", HorizontalAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetAutomationId(colorPicker, "quick.setup.color");
        foreach (var c in colors) colorPicker.Items.Add(ColorName(c));
        colorPicker.SelectedIndex = Array.IndexOf(colors, tile.Tint);
        colorPicker.SelectionChanged += (_, _) => { if (colorPicker.SelectedIndex >= 0) tile = tile with { Color = colors[colorPicker.SelectedIndex].Raw() }; };
        form.Children.Add(colorPicker);
        fields.Add(colorPicker);

        dialog.Content = new ScrollViewer { Content = form, MaxHeight = 520 };
        Refresh();

        // What counts as a change is measured from the form as first shown (its own pre-fill is not the person's edit).
        var draft = new QuickActionSetupDraft(tile, isNew);
        var opened = false;
        Control? lastField = null;
        var (caret, selected) = (0, 0);
        foreach (var field in fields) { var f = field; f.GotFocus += (_, _) => lastField = f; }
        dialog.Opened += (_, _) =>
        {
            opened = true;
            // Keep Editing: back in the field that had focus, caret and selection included.
            if (lastField == null) return;
            lastField.Focus(FocusState.Programmatic);
            if (lastField is TextBox box && caret + selected <= box.Text.Length) box.Select(caret, selected);
        };
        dialog.Closing += (_, e) =>
        {
            draft.Tile = tile;
            if (lastField is TextBox box) (caret, selected) = (box.SelectionStart, box.SelectionLength);
            // Save / Add: the one write, handed back to the page; a tile that can't be saved keeps the form up.
            if (e.Result == ContentDialogResult.Primary && draft.Save() == null && !draft.Saved) e.Cancel = true;
        };
        // Cancel or Escape on an edit with changes: Discard Changes?, Keep Editing its default for Return and Escape.
        return await draft.RunAsync(async () =>
        {
            opened = false;
            await PageKit.ShowAsync(root, dialog);
            return opened;
        }, () => AskToDiscardAsync(root));
    }

    /// EditingGuard.askToDiscard: "Discard Changes?", Discard Changes, and Keep Editing as the default for Return and Escape.
    private static async Task<bool> AskToDiscardAsync(XamlRoot? root)
    {
        var ask = new ContentDialog
        {
            Title = QuickActionSetupDraft.DiscardTitle, PrimaryButtonText = QuickActionSetupDraft.DiscardConfirm,
            CloseButtonText = QuickActionSetupDraft.DiscardKeep, DefaultButton = ContentDialogButton.Close,
        };
        AutomationProperties.SetAutomationId(ask, "quick-actions.setup.discard");
        return await PageKit.ShowAsync(root, ask) == ContentDialogResult.Primary;
    }

    /// QuickTileLook.colorName.
    private static string ColorName(QuickTileColor color) => color switch
    {
        QuickTileColor.Accent => "Theme",
        QuickTileColor.Red => "Red",
        QuickTileColor.Orange => "Orange",
        QuickTileColor.Yellow => "Yellow",
        QuickTileColor.Green => "Green",
        QuickTileColor.Teal => "Teal",
        QuickTileColor.Indigo => "Indigo",
        QuickTileColor.Pink => "Pink",
        _ => "Grey",
    };
}
