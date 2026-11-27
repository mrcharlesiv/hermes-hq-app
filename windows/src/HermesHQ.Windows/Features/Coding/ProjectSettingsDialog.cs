using Hermes.Core.Coding;
using HermesHQ.Features.Kanban;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Shapes;
using static HermesHQ.Features.Kanban.PageKit;

namespace HermesHQ.Features.Coding;

/// Project Settings dialog (`App/Sessions/ProjectSettingsPage.swift` + `ProjectIconGuide.swift` port):
/// Keep Chats in Project, Pins Stay in Project, Move Quiet Chats to Done (days & on merge), Coding Project + Repository,
/// Notifications (All / Needs Me / Mute), New Chats defaults (Model & Reasoning), and Look (Icon, Swatch, Branch on rows).
public static class ProjectSettingsDialog
{
    private static readonly (string Label, int? Days)[] AutoDoneOptions =
    [
        ("Off", null),
        ("After 3 days", 3),
        ("After 7 days", 7),
        ("After 14 days", 14),
        ("After 30 days", 30),
    ];

    private static readonly string[] ReasoningOptions = ["Default", "Low", "Medium", "High", "Max"];

    public static async Task<ProjectSettings?> PresentAsync(
        XamlRoot? root,
        string projectKey,
        string projectLabel,
        string? defaultFolder,
        CodingStore store)
    {
        var draft = store.SettingsFor(projectKey);
        var repo = store.RepoFor(projectKey);
        var body = new StackPanel { Spacing = 8, MinWidth = 440 };

        void Render()
        {
            body.Children.Clear();

            // Organization
            body.Children.Add(Header("Chats"));
            var keepToggle = new ToggleSwitch { IsOn = draft.KeepChatsInProject, OnContent = "", OffContent = "" };
            keepToggle.Toggled += (_, _) => draft = draft with { KeepChatsInProject = keepToggle.IsOn };
            body.Children.Add(SettingRow("Keep chats in this project", keepToggle));

            var pinsToggle = new ToggleSwitch { IsOn = draft.PinsStayInProject, OnContent = "", OffContent = "" };
            pinsToggle.Toggled += (_, _) => draft = draft with { PinsStayInProject = pinsToggle.IsOn };
            body.Children.Add(SettingRow("Pinned chats stay in project", pinsToggle));

            var autoDays = new ComboBox { MinWidth = 150 };
            foreach (var (label, days) in AutoDoneOptions)
                autoDays.Items.Add(new ComboBoxItem { Content = label, Tag = days });
            autoDays.SelectedIndex = Math.Max(0, Array.FindIndex(AutoDoneOptions, x => x.Days == draft.AutoDone.Days));
            autoDays.SelectionChanged += (_, _) =>
            {
                if (autoDays.SelectedItem is ComboBoxItem item)
                    draft = draft with { AutoDone = draft.AutoDone with { Days = item.Tag as int? } };
            };
            body.Children.Add(SettingRow("Move quiet chats to Done", autoDays));

            var onMergeToggle = new ToggleSwitch { IsOn = draft.AutoDone.OnMerge, OnContent = "", OffContent = "" };
            onMergeToggle.Toggled += (_, _) => draft = draft with { AutoDone = draft.AutoDone with { OnMerge = onMergeToggle.IsOn } };
            body.Children.Add(SettingRow("Move to Done when PR merges", onMergeToggle));

            // Coding & Repository
            body.Children.Add(Header("Coding"));
            var codingToggle = new ToggleSwitch { IsOn = draft.CodingProject, OnContent = "", OffContent = "" };
            codingToggle.Toggled += (_, _) => { draft = draft with { CodingProject = codingToggle.IsOn }; Render(); };
            body.Children.Add(SettingRow("Coding Project (PR Pipeline)", codingToggle));

            if (draft.CodingProject)
            {
                var repoDesc = repo != null ? (repo.PublicRepo ?? repo.Path) : "Not linked";
                var repoBtn = Quiet(repo != null ? "Change…" : "Link…", () =>
                {
                    store.SaveSettings(draft);
                    CodingFeature.OpenProjectRepository(new CodingProjectContext(projectKey, projectLabel, defaultFolder));
                });
                body.Children.Add(SettingRow($"Repository ({repoDesc})", repoBtn));
            }

            // Notifications
            body.Children.Add(Header("Notifications"));
            var notifyBox = new ComboBox { MinWidth = 150 };
            notifyBox.Items.Add(new ComboBoxItem { Content = "All Activity", Tag = ProjectNotifyMode.All });
            notifyBox.Items.Add(new ComboBoxItem { Content = "Needs Me Only", Tag = ProjectNotifyMode.NeedsMe });
            notifyBox.Items.Add(new ComboBoxItem { Content = "Mute", Tag = ProjectNotifyMode.Mute });
            notifyBox.SelectedIndex = draft.Notify switch
            {
                ProjectNotifyMode.NeedsMe => 1,
                ProjectNotifyMode.Mute => 2,
                _ => 0,
            };
            notifyBox.SelectionChanged += (_, _) =>
            {
                if (notifyBox.SelectedItem is ComboBoxItem { Tag: ProjectNotifyMode mode })
                    draft = draft with { Notify = mode };
            };
            body.Children.Add(SettingRow("Project notifications", notifyBox));

            // New Chats defaults
            body.Children.Add(Header("New Chats"));
            var modelBox = new TextBox { Text = draft.NewChat.Model ?? "", PlaceholderText = "Bot default", Width = 190 };
            modelBox.TextChanged += (_, _) => draft = draft with { NewChat = draft.NewChat with { Model = string.IsNullOrWhiteSpace(modelBox.Text) ? null : modelBox.Text.Trim() } };
            body.Children.Add(SettingRow("Model override", modelBox));

            var reasonBox = new ComboBox { MinWidth = 150 };
            foreach (var r in ReasoningOptions) reasonBox.Items.Add(new ComboBoxItem { Content = r, Tag = r == "Default" ? null : r.ToLowerInvariant() });
            var curReasonIdx = Array.FindIndex(ReasoningOptions, r => string.Equals(r, draft.NewChat.Reasoning, StringComparison.OrdinalIgnoreCase));
            reasonBox.SelectedIndex = curReasonIdx >= 0 ? curReasonIdx : 0;
            reasonBox.SelectionChanged += (_, _) =>
            {
                if (reasonBox.SelectedItem is ComboBoxItem item)
                    draft = draft with { NewChat = draft.NewChat with { Reasoning = item.Tag as string } };
            };
            body.Children.Add(SettingRow("Reasoning effort", reasonBox));

            // Look & Icon Guide
            body.Children.Add(Header("Look"));
            var iconRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
            foreach (var (emoji, label) in RepoPathHelpers.IconPresets)
            {
                var em = emoji;
                var picked = draft.Look.Emoji == em;
                var btn = new Button
                {
                    Content = em,
                    Padding = new Thickness(6, 4, 6, 4),
                    Background = picked ? AccentWash(0.18) : Solid(Microsoft.UI.Colors.Transparent),
                };
                ToolTipService.SetToolTip(btn, label);
                btn.Click += (_, _) => { draft = draft with { Look = draft.Look with { Emoji = picked ? null : em } }; Render(); };
                iconRow.Children.Add(btn);
            }
            body.Children.Add(iconRow);

            var swatchRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 4, 0, 4) };
            foreach (var (key, label, r, g, b) in RepoPathHelpers.Swatches)
            {
                var k = key;
                var picked = draft.Look.Color == k;
                var circle = new Ellipse
                {
                    Width = 20,
                    Height = 20,
                    Fill = Solid(Rgb(r, g, b)),
                    Stroke = picked ? Brush("TextFillColorPrimaryBrush") : null,
                    StrokeThickness = picked ? 2 : 0,
                };
                var btn = new Button { Content = circle, Padding = new Thickness(2), Style = Style("QuietButtonStyle") };
                AutomationProperties.SetName(btn, label);
                btn.Click += (_, _) => { draft = draft with { Look = draft.Look with { Color = k } }; Render(); };
                swatchRow.Children.Add(btn);
            }
            body.Children.Add(swatchRow);

            var branchToggle = new ToggleSwitch { IsOn = draft.Look.ShowBranchOnRows, OnContent = "", OffContent = "" };
            branchToggle.Toggled += (_, _) => draft = draft with { Look = draft.Look with { ShowBranchOnRows = branchToggle.IsOn } };
            body.Children.Add(SettingRow("Show branch on rows", branchToggle));
        }

        Render();
        var dialog = new ContentDialog
        {
            Title = $"{projectLabel} Settings",
            Content = new ScrollViewer { Content = body, MaxHeight = 560, VerticalScrollBarVisibility = ScrollBarVisibility.Auto },
            PrimaryButtonText = "Save",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await ShowAsync(root, dialog) != ContentDialogResult.Primary) return null;
        store.SaveSettings(draft);
        return draft;
    }

    private static FrameworkElement SettingRow(string label, FrameworkElement control)
    {
        var grid = new Grid { ColumnSpacing = 12, MinHeight = 34 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var t = Text(label, 14);
        t.VerticalAlignment = VerticalAlignment.Center;
        grid.Children.Add(t);
        control.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(control, 1);
        grid.Children.Add(control);
        return grid;
    }
}
