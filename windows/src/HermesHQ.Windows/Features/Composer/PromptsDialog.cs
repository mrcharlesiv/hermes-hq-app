using Hermes.Core.Composer;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Windows.ApplicationModel.DataTransfer;

namespace HermesHQ.Features.Composer;

/// ⋯ › Prompts (App/Chat/Menus/PromptsSheet.swift): the library kept on this PC, for a bot's chat and a group room's
/// ⋯ alike. A click puts a prompt in the message box (an empty box takes it whole, otherwise it goes in at the caret, as
/// ComposerView.swift `insertPrompt`) and sends nothing; right-click offers Put in Message Box, Edit…, Copy and Delete; New Prompt… writes one, and Save Current Message
/// keeps what the box holds. Deleting says so with Undo.
internal static class PromptsDialog
{
    public static async Task ShowAsync(XamlRoot root, PromptLibrary library, TextBox composer)
    {
        var dialog = new ContentDialog { Title = PromptLibrary.Title, CloseButtonText = "Done", DefaultButton = ContentDialogButton.Close };
        var list = new StackPanel();
        var undo = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Visibility = Visibility.Collapsed };
        var undoText = Ui.Text("", 13, secondary: true, wrap: false);
        var undoButton = new HyperlinkButton { Content = "Undo" };
        undo.Children.Add(undoText);
        undo.Children.Add(undoButton);
        IReadOnlyList<DeletedPrompt> lastDeleted = [];
        undoButton.Click += (_, _) => { library.Restore(lastDeleted); undo.Visibility = Visibility.Collapsed; };

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var add = new Button { Content = PromptLibrary.NewPrompt };
        buttons.Children.Add(add);
        var current = ComposerText.SendText(composer.Text);
        if (current.Length > 0 && !library.Contains(current))
        {
            var save = new Button { Content = PromptLibrary.SaveCurrent };
            save.Click += (_, _) => { library.Add(current); save.Visibility = Visibility.Collapsed; };
            buttons.Children.Add(save);
        }

        var editor = new StackPanel { Spacing = 8, Visibility = Visibility.Collapsed };
        var title = new TextBox { PlaceholderText = PromptLibrary.TitlePlaceholder };
        var body = new TextBox { PlaceholderText = PromptLibrary.TextPlaceholder, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Height = 180 };
        AutomationProperties.SetName(title, "Title");
        AutomationProperties.SetName(body, "Prompt");
        var editorButtons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right };
        var cancel = new Button { Content = "Cancel" };
        var saveEdit = new Button { Content = "Save", Style = Ui.Res<Style>("AccentButtonStyle") };
        editorButtons.Children.Add(cancel);
        editorButtons.Children.Add(saveEdit);
        var editorTitle = Ui.Text("", 14, bold: true);
        editor.Children.Add(editorTitle);
        editor.Children.Add(title);
        editor.Children.Add(body);
        editor.Children.Add(editorButtons);
        Guid? editing = null;

        var browse = new StackPanel { Spacing = 8 };
        browse.Children.Add(buttons);
        browse.Children.Add(new ScrollViewer { Content = list, Height = 340 });
        browse.Children.Add(undo);
        browse.Children.Add(Ui.Text(PromptLibrary.Footer, 12, secondary: true));
        var content = new Grid { Width = 460 };
        content.Children.Add(browse);
        content.Children.Add(editor);
        dialog.Content = content;

        void Edit(SavedPrompt? prompt)
        {
            editing = prompt?.Id;
            editorTitle.Text = prompt == null ? "New Prompt" : PromptLibrary.EditPrompt;
            title.Text = prompt?.Title ?? "";
            body.Text = prompt?.Text ?? "";
            browse.Visibility = Visibility.Collapsed;
            editor.Visibility = Visibility.Visible;
            body.Focus(FocusState.Programmatic);
        }

        void Browse()
        {
            editor.Visibility = Visibility.Collapsed;
            browse.Visibility = Visibility.Visible;
        }

        void Use(SavedPrompt prompt)
        {
            dialog.Hide();
            var (text, caret) = ComposerText.InsertPrompt(composer.Text, composer.SelectionStart, composer.SelectionLength, prompt.Text);
            composer.Text = text;
            composer.SelectionStart = caret;
            composer.Focus(FocusState.Programmatic);
        }

        void Draw()
        {
            list.Children.Clear();
            if (library.Prompts.Count == 0)
            {
                var empty = new StackPanel { Spacing = 6, Margin = new Thickness(12, 30, 12, 30), HorizontalAlignment = HorizontalAlignment.Center };
                empty.Children.Add(new TextBlock { Text = PromptLibrary.EmptyTitle, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center });
                var t = Ui.Text(PromptLibrary.EmptyText, 13, secondary: true);
                t.TextAlignment = TextAlignment.Center;
                empty.Children.Add(t);
                list.Children.Add(empty);
                return;
            }
            foreach (var prompt in library.Prompts)
            {
                var words = new StackPanel();
                words.Children.Add(Ui.Text(prompt.DisplayTitle, 14, bold: true, wrap: false));
                if (prompt.Preview.Length > 0) words.Children.Add(Ui.Text(prompt.Preview, 12, secondary: true, wrap: false));
                var row = Ui.Row(words, (_, _) => Use(prompt));
                AutomationProperties.SetName(row, prompt.DisplayTitle);
                var menu = new MenuFlyout();
                var put = new MenuFlyoutItem { Text = PromptLibrary.PutInBox };
                put.Click += (_, _) => Use(prompt);
                var edit = new MenuFlyoutItem { Text = "Edit…" };
                edit.Click += (_, _) => Edit(prompt);
                var copy = new MenuFlyoutItem { Text = "Copy" };
                copy.Click += (_, _) => HermesHQ.Services.SafeClipboard.TrySetText(prompt.Text);
                var delete = new MenuFlyoutItem { Text = "Delete", Foreground = Ui.Res<Microsoft.UI.Xaml.Media.Brush>("SystemFillColorCriticalBrush") };
                delete.Click += (_, _) =>
                {
                    lastDeleted = library.Delete([prompt.Id]);
                    undoText.Text = $"Deleted “{prompt.DisplayTitle}”";
                    undo.Visibility = Visibility.Visible;
                };
                menu.Items.Add(put);
                menu.Items.Add(edit);
                menu.Items.Add(copy);
                menu.Items.Add(new MenuFlyoutSeparator());
                menu.Items.Add(delete);
                row.ContextFlyout = menu;
                list.Children.Add(row);
            }
        }

        add.Click += (_, _) => Edit(null);
        cancel.Click += (_, _) => Browse();
        body.TextChanged += (_, _) => saveEdit.IsEnabled = body.Text.Trim().Length > 0;
        saveEdit.IsEnabled = body.Text.Trim().Length > 0;
        saveEdit.Click += (_, _) =>
        {
            if (body.Text.Trim().Length == 0) return;
            if (editing is { } id) library.Update(id, title.Text, body.Text);
            else library.Add(body.Text, title.Text);
            Browse();
        };
        library.Changed += Draw;
        Draw();
        try { await Ui.Show(root, dialog); }
        finally { library.Changed -= Draw; }
    }
}
