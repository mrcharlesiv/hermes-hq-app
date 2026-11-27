using Hermes.Core.PhoneCalls;
using HermesHQ.Features.Kanban;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Windows.UI;
using static HermesHQ.Features.Kanban.PageKit;

namespace HermesHQ.Features.PhoneCalls;

/// Phone & Voice settings dialog (`App/PhoneCalls/PhoneCalls.swift` setup + `App/Settings/Voice/PhoneVoicePage.swift` port):
/// samplehost API key connect/disconnect, From number, Voice connection, AI Assistant (+ Create), Owner name,
/// Record calls, Send results to chat, Preferred Voice, and 8-point `Check My Setup` diagnostics.
public static class PhoneSettingsDialog
{
    private static readonly string[] VoicePresets =
    [
        "samplehost.KokoroTTS.af_heart",
        "samplehost.KokoroTTS.am_adam",
        "samplehost.NaturalHD.astra",
        "samplehost.NaturalHD.orion",
    ];

    public static async Task PresentAsync(
        XamlRoot? root,
        PhoneCallController controller,
        IsamplehostApi api,
        IPhoneKeyStore keys)
    {
        var draft = controller.Setup;
        var numbers = new List<samplehostNumber>();
        var assistants = new List<samplehostAssistant>();
        IReadOnlyList<PhoneSetupCheckRow>? diagnostics = null;
        string? statusMessage = null;
        bool busy = false;

        var body = new StackPanel { Spacing = 8, MinWidth = 460 };

        async Task LoadAccountResourcesAsync(string apiKey)
        {
            busy = true;
            statusMessage = "Loading samplehost numbers and assistants…";
            Render();
            try
            {
                numbers = [.. await api.AllPhoneNumbersAsync(apiKey)];
                assistants = [.. await api.AssistantsAsync(apiKey)];
                if (draft.FromNumber == null && numbers.FirstOrDefault() is { } firstNum)
                    draft = draft with { FromNumber = firstNum.PhoneNumber, ConnectionId = firstNum.ConnectionId ?? draft.ConnectionId };
                if (draft.AssistantId == null && assistants.FirstOrDefault() is { } firstAsst)
                    draft = draft with { AssistantId = firstAsst.Id };
                statusMessage = $"Loaded {numbers.Count} numbers and {assistants.Count} assistants.";
            }
            catch (Exception ex)
            {
                statusMessage = PhoneMessages.Format(ex, apiKey);
            }
            finally
            {
                busy = false;
                Render();
            }
        }

        async Task RunDiagnosticsAsync()
        {
            busy = true;
            statusMessage = "Checking samplehost setup…";
            Render();
            try
            {
                controller.SaveSetup(draft);
                diagnostics = await PhoneSetupCheck.RunAsync(api, keys.ReadKey(controller.AccountId), draft);
                statusMessage = null;
            }
            finally
            {
                busy = false;
                Render();
            }
        }

        void Render()
        {
            body.Children.Clear();
            var hasKey = !string.IsNullOrWhiteSpace(keys.ReadKey(controller.AccountId));

            // 1. samplehost Account Connection
            body.Children.Add(Header("samplehost Account"));
            if (!hasKey)
            {
                var keyBox = new PasswordBox { PlaceholderText = "KEY019…" };
                AutomationProperties.SetAutomationId(keyBox, "phone.settings.key");
                var connectBtn = Push("Connect samplehost", () =>
                {
                    var key = keyBox.Password.Trim();
                    if (key.Length == 0) return;
                    controller.SaveApiKey(key);
                    _ = LoadAccountResourcesAsync(key);
                }, accent: true);
                connectBtn.IsEnabled = !busy;
                var row = new Grid { ColumnSpacing = 8 };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                row.Children.Add(keyBox);
                Grid.SetColumn(connectBtn, 1);
                row.Children.Add(connectBtn);
                body.Children.Add(row);
            }
            else
            {
                var row = new Grid { ColumnSpacing = 8 };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                row.Children.Add(Text("samplehost API key saved in Windows Credential Locker.", 13, color: Secondary));
                var btns = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
                btns.Children.Add(Quiet("Refresh", () =>
                {
                    if (keys.ReadKey(controller.AccountId) is { } k) _ = LoadAccountResourcesAsync(k);
                }));
                var disconnect = Quiet("Disconnect", () =>
                {
                    controller.RemoveApiKey();
                    numbers.Clear();
                    assistants.Clear();
                    diagnostics = null;
                    Render();
                });
                disconnect.Foreground = Critical;
                btns.Children.Add(disconnect);
                Grid.SetColumn(btns, 1);
                row.Children.Add(btns);
                body.Children.Add(Card(row, 10));
            }

            // 2. Number, Connection & Assistant
            body.Children.Add(Header("Calling Configuration"));
            var fromBox = new ComboBox { MinWidth = 200, PlaceholderText = "Select or type in samplehost" };
            foreach (var n in numbers)
                fromBox.Items.Add(new ComboBoxItem { Content = PhoneFormatting.FormatShown(n.PhoneNumber), Tag = n });
            if (draft.FromNumber != null && !numbers.Any(n => n.PhoneNumber == draft.FromNumber))
                fromBox.Items.Add(new ComboBoxItem { Content = PhoneFormatting.FormatShown(draft.FromNumber), Tag = new samplehostNumber(draft.FromNumber, draft.ConnectionId) });
            var numIdx = fromBox.Items.OfType<ComboBoxItem>().ToList().FindIndex(i => (i.Tag as samplehostNumber)?.PhoneNumber == draft.FromNumber);
            if (numIdx >= 0) fromBox.SelectedIndex = numIdx;
            fromBox.SelectionChanged += (_, _) =>
            {
                if (fromBox.SelectedItem is ComboBoxItem { Tag: samplehostNumber picked })
                    draft = draft with { FromNumber = picked.PhoneNumber, ConnectionId = picked.ConnectionId ?? draft.ConnectionId };
            };
            body.Children.Add(Row("From number", fromBox));

            var connBox = new TextBox { Text = draft.ConnectionId ?? "", PlaceholderText = "Call Control Application ID", Width = 200 };
            connBox.TextChanged += (_, _) => draft = draft with { ConnectionId = string.IsNullOrWhiteSpace(connBox.Text) ? null : connBox.Text.Trim() };
            body.Children.Add(Row("Voice connection ID", connBox));

            var asstRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            var asstBox = new ComboBox { MinWidth = 160 };
            foreach (var a in assistants)
                asstBox.Items.Add(new ComboBoxItem { Content = a.Name, Tag = a.Id });
            if (draft.AssistantId != null && !assistants.Any(a => a.Id == draft.AssistantId))
                asstBox.Items.Add(new ComboBoxItem { Content = draft.AssistantId, Tag = draft.AssistantId });
            var asstIdx = asstBox.Items.OfType<ComboBoxItem>().ToList().FindIndex(i => (i.Tag as string) == draft.AssistantId);
            if (asstIdx >= 0) asstBox.SelectedIndex = asstIdx;
            asstBox.SelectionChanged += (_, _) =>
            {
                if (asstBox.SelectedItem is ComboBoxItem { Tag: string id })
                    draft = draft with { AssistantId = id };
            };
            asstRow.Children.Add(asstBox);
            var createBtn = Quiet("Create", () =>
            {
                if (keys.ReadKey(controller.AccountId) is not { } k) return;
                _ = CreateAssistantAsync(k);
            });
            createBtn.IsEnabled = hasKey && !busy;
            asstRow.Children.Add(createBtn);
            body.Children.Add(Row("AI Assistant", asstRow));

            // 3. Voice & Call Preferences (`PhoneVoicePage.swift` parity)
            body.Children.Add(Header("Voice & Preferences"));
            var ownerBox = new TextBox { Text = draft.OwnerName, PlaceholderText = "Your name (spoken on calls)", Width = 200 };
            ownerBox.TextChanged += (_, _) => draft = draft with { OwnerName = ownerBox.Text.Trim() };
            body.Children.Add(Row("Your name", ownerBox));

            var voiceBox = new ComboBox { MinWidth = 200 };
            voiceBox.Items.Add(new ComboBoxItem { Content = "Assistant default", Tag = "" });
            foreach (var v in VoicePresets)
                voiceBox.Items.Add(new ComboBoxItem { Content = v, Tag = v });
            var vIdx = voiceBox.Items.OfType<ComboBoxItem>().ToList().FindIndex(i => (i.Tag as string) == (draft.PreferredVoice ?? ""));
            voiceBox.SelectedIndex = vIdx >= 0 ? vIdx : 0;
            voiceBox.SelectionChanged += (_, _) =>
            {
                if (voiceBox.SelectedItem is ComboBoxItem { Tag: string v })
                    draft = draft with { PreferredVoice = v.Length == 0 ? null : v };
            };
            body.Children.Add(Row("Call voice", voiceBox));

            var recordSwitch = new ToggleSwitch { IsOn = draft.RecordCalls, OnContent = "", OffContent = "" };
            recordSwitch.Toggled += (_, _) => draft = draft with { RecordCalls = recordSwitch.IsOn };
            body.Children.Add(Row("Record calls", recordSwitch));

            var resultsSwitch = new ToggleSwitch { IsOn = draft.SendResultsToChat, OnContent = "", OffContent = "" };
            resultsSwitch.Toggled += (_, _) => draft = draft with { SendResultsToChat = resultsSwitch.IsOn };
            body.Children.Add(Row("Post call results in chat", resultsSwitch));

            // 4. Diagnostics (`PhoneSetupCheck`)
            body.Children.Add(Header("Diagnostics"));
            var checkBtn = Push(busy ? "Checking…" : "Check My Setup", () => _ = RunDiagnosticsAsync());
            checkBtn.IsEnabled = !busy;
            AutomationProperties.SetAutomationId(checkBtn, "phone.settings.check");
            body.Children.Add(checkBtn);

            if (!string.IsNullOrEmpty(statusMessage))
                body.Children.Add(Text(statusMessage, 12, color: Secondary));

            if (diagnostics != null)
            {
                var diagStack = new StackPanel { Spacing = 6 };
                foreach (var row in diagnostics)
                {
                    var dGrid = new Grid { ColumnSpacing = 8 };
                    dGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                    dGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                    var color = row.State switch
                    {
                        PhoneSetupCheckState.Pass => Green,
                        PhoneSetupCheckState.Warn => Orange,
                        PhoneSetupCheckState.Fail => Red,
                        _ => Rgb(0x8E, 0x8E, 0x93),
                    };
                    dGrid.Children.Add(Dot(color, 8));
                    var info = new StackPanel { Spacing = 1 };
                    info.Children.Add(Text(row.Title, 13, bold: true));
                    info.Children.Add(Text(row.Detail, 12, color: Secondary));
                    if (!string.IsNullOrEmpty(row.Fix))
                        info.Children.Add(Text(row.Fix, 12, color: Solid(color)));
                    Grid.SetColumn(info, 1);
                    dGrid.Children.Add(info);
                    diagStack.Children.Add(dGrid);
                }
                body.Children.Add(Card(diagStack, 10));
            }
        }

        async Task CreateAssistantAsync(string apiKey)
        {
            busy = true;
            statusMessage = "Creating samplehost AI Assistant…";
            Render();
            try
            {
                var created = await api.CreateAssistantAsync(apiKey, "Hermes Phone Assistant", draft.OwnerName, draft.PreferredVoice);
                assistants.Add(created);
                draft = draft with { AssistantId = created.Id };
                statusMessage = $"Created assistant “{created.Name}”.";
            }
            catch (Exception ex)
            {
                statusMessage = PhoneMessages.Format(ex, apiKey);
            }
            finally
            {
                busy = false;
                Render();
            }
        }

        Render();
        if (keys.ReadKey(controller.AccountId) is { Length: > 0 } existingKey)
            _ = LoadAccountResourcesAsync(existingKey);

        var dialog = new ContentDialog
        {
            Title = "Phone & Voice Settings",
            Content = new ScrollViewer { Content = body, MaxHeight = 560, VerticalScrollBarVisibility = ScrollBarVisibility.Auto },
            PrimaryButtonText = "Save",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await ShowAsync(root, dialog) == ContentDialogResult.Primary)
            controller.SaveSetup(draft);
    }

    private static FrameworkElement Row(string label, FrameworkElement control)
    {
        var grid = new Grid { ColumnSpacing = 12, MinHeight = 36 };
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
