using Hermes.Core.Workspace;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.Workspace;

/// Choose Folder… (MoreWorkspaceController in `.chooser` mode): folders only, the enclosing folder first so any folder
/// on the computer can be reached, and Use This Folder. One dialog that walks the folders in place.
internal static class FolderChooser
{
    public static async Task<string?> ShowAsync(XamlRoot? root, WorkspaceVisit visit, string start)
    {
        if (root == null) return null;
        var ui = DispatcherQueue.GetForCurrentThread();
        var path = WorkspaceRoot.Folder(start) ?? "/";
        var heading = W.Text("", 12, W.Secondary);
        var list = new StackPanel { Spacing = 2 };
        var footer = W.Text("Files and Changes will show the folder you choose.", 12, W.Secondary, wrap: true);
        var content = new StackPanel { Width = 460, Spacing = 8 };
        content.Children.Add(heading);
        content.Children.Add(new ScrollViewer { Content = list, Height = 360 });
        content.Children.Add(footer);
        var dialog = new ContentDialog
        {
            Title = WorkspaceRoot.Name(path), Content = content, XamlRoot = root, PrimaryButtonText = "Use This Folder",
            CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary,
        };
        AutomationProperties.SetAutomationId(content, "workspace.chooser");
        CancellationTokenSource? load = null;

        Button Row(string glyph, string title, string? detail, string id, Action click)
        {
            var row = new Grid { ColumnSpacing = 10 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(22) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.Children.Add(W.Glyph(glyph, 15, glyph == "" ? W.Accent : W.Secondary));
            var words = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            words.Children.Add(W.Text(title, 14));
            if (detail != null) words.Children.Add(W.Text(detail, 12, W.Secondary));
            Grid.SetColumn(words, 1);
            row.Children.Add(words);
            var chevron = W.Glyph("", 10, W.Tertiary);
            Grid.SetColumn(chevron, 2);
            row.Children.Add(chevron);
            var b = new Button
            {
                Content = row, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
                Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0), Padding = new Thickness(8, 7, 8, 7),
            };
            AutomationProperties.SetAutomationId(b, id);
            AutomationProperties.SetName(b, title);
            b.Click += (_, _) => click();
            return b;
        }

        void Go(string next)
        {
            path = next;
            dialog.Title = WorkspaceRoot.Name(path);
            heading.Text = visit.Display(path);
            list.Children.Clear();
            list.Children.Add(W.Loading());
            dialog.IsPrimaryButtonEnabled = false;
            load?.Cancel();
            var cts = load = new CancellationTokenSource();
            var asked = path;
            _ = Task.Run(async () =>
            {
                ListingContent result;
                try { result = await WorkspaceListing.ReadAsync(visit, asked, isRoot: false, chooser: true, cts.Token); }
                catch (OperationCanceledException) { return; }
                ui.TryEnqueue(() =>
                {
                    if (cts.IsCancellationRequested) return;
                    list.Children.Clear();
                    if (WorkspaceRoot.Parent(asked) is { } parent)
                        list.Children.Add(Row("", "Enclosing Folder", visit.Display(parent), "workspace.parent", () => Go(parent)));
                    switch (result)
                    {
                        case ListingContent.Entries { Rows.Count: 0 }:
                            var none = W.Text("No folders here", 14, W.Secondary);
                            none.Margin = new Thickness(40, 8, 8, 8);
                            AutomationProperties.SetAutomationId(none, "workspace.no-folders");
                            list.Children.Add(none);
                            dialog.IsPrimaryButtonEnabled = true;
                            break;
                        case ListingContent.Entries e:
                            foreach (var folder in e.Rows)
                            {
                                var target = folder.Path;
                                list.Children.Add(Row("", folder.Name, null, "workspace.entry." + folder.Name, () => Go(target)));
                            }
                            dialog.IsPrimaryButtonEnabled = true;
                            break;
                        case ListingContent.State s:
                            list.Children.Add(W.State(s.Glyph, s.Words.Title, s.Words.Body, s.Retry ? ("Try Again", () => Go(asked)) : null));
                            dialog.IsPrimaryButtonEnabled = !s.Retry;
                            break;
                    }
                });
            });
        }

        Go(path);
        try
        {
            var answer = await dialog.ShowAsync();
            load?.Cancel();
            return answer == ContentDialogResult.Primary ? path : null;
        }
        catch (Exception e) when (e is InvalidOperationException or System.Runtime.InteropServices.COMException) { return null; }
    }
}
