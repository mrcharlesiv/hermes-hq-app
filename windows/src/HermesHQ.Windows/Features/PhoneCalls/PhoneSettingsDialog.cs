using Hermes.Core.PhoneCalls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using static HermesHQ.Features.Kanban.PageKit;

namespace HermesHQ.Features.PhoneCalls;

/// Phone & Voice settings dialog (`App/PhoneCalls/PhoneCalls.swift` setup + `App/Settings/Voice/PhoneVoicePage.swift` port):
/// samplehost API key connect/disconnect, From number, Call Control Applications picker (never a raw Connection ID textbox),
/// one-click Create/Fix Voice Connection with custom webhook URL field, TeXML orange warning card, AI Assistant
/// (+ Create & Optimize assistant for calls), Owner name, Record calls, Send results to chat, Preferred Voice,
/// Setup & how to use guide, and `Check My Setup` diagnostics.
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
        List<samplehostCallControlAppSummary>? apps = null;
        var assistants = new List<samplehostAssistant>();
        IReadOnlyList<PhoneSetupCheckRow>? diagnostics = null;
        string customWebhookUrl = "";
        bool needsCustomWebhookUrl = false;
        string? statusMessage = null;
        string? errorMessage = null;
        bool busy = false;
        bool loaded = false;
        bool openGuideRequested = false;
        ContentDialog? activeDialog = null;

        var body = new StackPanel { Spacing = 8, MinWidth = 480 };

        string EffectiveWebhookUrl()
        {
            var trimmed = customWebhookUrl.Trim();
            return trimmed.Length == 0 ? PhoneLimits.VoiceWebhookUrl : trimmed;
        }

        void HandleWebhookRejectionIfNeeded(Exception ex, string apiKey)
        {
            var msg = PhoneMessages.Format(ex, apiKey).ToLowerInvariant();
            if (string.IsNullOrWhiteSpace(customWebhookUrl)
                && (msg.Contains("webhook", StringComparison.Ordinal)
                    || msg.Contains("url", StringComparison.Ordinal)
                    || msg.Contains("10003", StringComparison.Ordinal)))
            {
                needsCustomWebhookUrl = true;
            }
        }

        async Task LoadAccountResourcesAsync(string apiKey)
        {
            busy = true;
            errorMessage = null;
            statusMessage = "Loading samplehost numbers, voice connections, and assistants…";
            Render();
            try
            {
                numbers = [.. await api.AllPhoneNumbersAsync(apiKey)];
                try { apps = [.. await api.CallControlAppsAsync(apiKey)]; }
                catch (Exception) { apps = null; }
                assistants = [.. await api.AssistantsAsync(apiKey)];

                if (string.IsNullOrWhiteSpace(draft.FromNumber) && numbers.FirstOrDefault() is { } firstNum)
                    draft = draft with { FromNumber = firstNum.PhoneNumber };

                if (!string.IsNullOrWhiteSpace(draft.FromNumber))
                {
                    var preferred = PhoneConnectionResolver.PreferredConnection(
                        draft.FromNumber!, numbers, apps, draft.ConnectionId ?? "");
                    if (!PhoneConnectionResolver.IsInvalidSavedConnection(draft.ConnectionId, apps) || preferred.Length > 0)
                        draft = draft with { ConnectionId = preferred.Length == 0 ? null : preferred };
                }
                else if (apps is { Count: 1 } && string.IsNullOrWhiteSpace(draft.ConnectionId))
                {
                    draft = draft with { ConnectionId = apps[0].Id };
                }

                if (string.IsNullOrWhiteSpace(draft.AssistantId) && assistants.Count == 1)
                    draft = draft with { AssistantId = assistants[0].Id };

                loaded = true;
                var appCount = apps?.Count ?? 0;
                statusMessage = $"Loaded {numbers.Count} numbers, {appCount} Voice API connections, and {assistants.Count} assistants.";
            }
            catch (Exception ex)
            {
                errorMessage = PhoneMessages.Format(ex, apiKey);
                statusMessage = null;
            }
            finally
            {
                busy = false;
                Render();
            }
        }

        async Task CreateVoiceConnectionAsync(string apiKey)
        {
            busy = true;
            errorMessage = null;
            statusMessage = "Creating Voice API connection…";
            Render();
            try
            {
                var selectedNumber = numbers.FirstOrDefault(n => n.PhoneNumber == draft.FromNumber)
                    ?? (numbers.Count == 1 ? numbers[0] : null);
                var webhook = EffectiveWebhookUrl();
                var (app, updatedNumber) = await api.ProvisionVoiceConnectionAsync(apiKey, selectedNumber, webhook);
                apps ??= [];
                if (!apps.Any(a => a.Id == app.Id)) apps.Add(app);
                if (updatedNumber != null)
                {
                    var idx = numbers.FindIndex(n => !string.IsNullOrWhiteSpace(n.Id) && n.Id == updatedNumber.Id);
                    if (idx >= 0) numbers[idx] = updatedNumber;
                }
                draft = draft with
                {
                    FromNumber = string.IsNullOrWhiteSpace(draft.FromNumber) ? selectedNumber?.PhoneNumber : draft.FromNumber,
                    ConnectionId = app.Id,
                };
                needsCustomWebhookUrl = false;
                statusMessage = $"Created Voice API connection “{app.ApplicationName ?? PhoneLimits.VoiceAppName}”.";
            }
            catch (Exception ex)
            {
                HandleWebhookRejectionIfNeeded(ex, apiKey);
                errorMessage = PhoneMessages.Format(ex, apiKey);
                statusMessage = null;
            }
            finally
            {
                busy = false;
                Render();
            }
        }

        async Task FixVoiceConnectionAsync(string apiKey)
        {
            busy = true;
            errorMessage = null;
            statusMessage = "Fixing Voice API connection…";
            Render();
            try
            {
                var selectedNumber = numbers.FirstOrDefault(n => n.PhoneNumber == draft.FromNumber)
                    ?? (numbers.Count == 1 ? numbers[0] : null);
                var webhook = EffectiveWebhookUrl();
                var (connectionId, connectionName, updatedNumber) = await api.RepairVoiceConnectionAsync(
                    apiKey, draft.ConnectionId, selectedNumber, webhook);
                try { apps = [.. await api.CallControlAppsAsync(apiKey)]; }
                catch (Exception)
                {
                    apps = [new samplehostCallControlAppSummary(connectionId, connectionName, true, webhook, "configured")];
                }
                if (updatedNumber != null)
                {
                    var idx = numbers.FindIndex(n => !string.IsNullOrWhiteSpace(n.Id) && n.Id == updatedNumber.Id);
                    if (idx >= 0) numbers[idx] = updatedNumber;
                }
                draft = draft with
                {
                    FromNumber = string.IsNullOrWhiteSpace(draft.FromNumber) ? selectedNumber?.PhoneNumber : draft.FromNumber,
                    ConnectionId = connectionId,
                };
                needsCustomWebhookUrl = false;
                statusMessage = $"Updated Voice API connection “{connectionName}”.";
            }
            catch (Exception ex)
            {
                HandleWebhookRejectionIfNeeded(ex, apiKey);
                errorMessage = PhoneMessages.Format(ex, apiKey);
                statusMessage = null;
            }
            finally
            {
                busy = false;
                Render();
            }
        }

        async Task CreateAssistantAsync(string apiKey)
        {
            busy = true;
            errorMessage = null;
            statusMessage = "Creating samplehost AI Assistant…";
            Render();
            try
            {
                var created = await api.CreateAssistantAsync(apiKey, PhoneAskOwner.AssistantName, draft.OwnerName, draft.PreferredVoice);
                assistants.Add(created);
                draft = draft with { AssistantId = created.Id };
                statusMessage = $"Created assistant “{created.Name}”.";
            }
            catch (Exception ex)
            {
                errorMessage = PhoneMessages.Format(ex, apiKey);
                statusMessage = null;
            }
            finally
            {
                busy = false;
                Render();
            }
        }

        async Task OptimizeAssistantAsync(string apiKey)
        {
            if (string.IsNullOrWhiteSpace(draft.AssistantId)) return;
            busy = true;
            errorMessage = null;
            statusMessage = "Optimizing assistant for phone calls…";
            Render();
            try
            {
                await api.OptimizeAssistantAsync(apiKey, draft.AssistantId!, draft.RecordCalls);
                statusMessage = "Assistant updated for smoother phone calls (deepgram/flux, interruptions, aicoustics).";
            }
            catch (Exception ex)
            {
                errorMessage = PhoneMessages.Format(ex, apiKey);
                statusMessage = null;
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
            errorMessage = null;
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
            var apiKey = keys.ReadKey(controller.AccountId);
            var hasKey = !string.IsNullOrWhiteSpace(apiKey);
            var selectedNumber = numbers.FirstOrDefault(n => n.PhoneNumber == draft.FromNumber);
            var selectedApp = apps?.FirstOrDefault(a => a.Id == draft.ConnectionId);
            var savedConnectionInvalid = PhoneConnectionResolver.IsInvalidSavedConnection(draft.ConnectionId, apps);
            var selectedAppNeedsFix = selectedApp != null && PhoneConnectionResolver.NeedsFix(selectedApp);
            var nonCallControlWarning = loaded
                ? PhoneConnectionResolver.NonCallControlWarning(selectedNumber, draft.ConnectionId, apps)
                : null;
            var connectionOptions = PhoneConnectionResolver.Options(numbers, apps);

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
                var refreshBtn = Quiet("Refresh", () =>
                {
                    if (keys.ReadKey(controller.AccountId) is { } k) _ = LoadAccountResourcesAsync(k);
                });
                refreshBtn.IsEnabled = !busy;
                btns.Children.Add(refreshBtn);
                var disconnect = Quiet("Disconnect", () =>
                {
                    controller.RemoveApiKey();
                    numbers.Clear();
                    apps = null;
                    assistants.Clear();
                    diagnostics = null;
                    loaded = false;
                    needsCustomWebhookUrl = false;
                    customWebhookUrl = "";
                    statusMessage = null;
                    errorMessage = null;
                    Render();
                });
                disconnect.Foreground = Critical;
                disconnect.IsEnabled = !busy;
                btns.Children.Add(disconnect);
                Grid.SetColumn(btns, 1);
                row.Children.Add(btns);
                body.Children.Add(Card(row, 10));
            }

            if (!string.IsNullOrEmpty(errorMessage))
                body.Children.Add(Text(errorMessage, 12, color: Critical));
            if (!string.IsNullOrEmpty(statusMessage))
                body.Children.Add(Text(statusMessage, 12, color: Secondary));

            // 2. Number, Call Control Applications Picker & Assistant
            body.Children.Add(Header("Calling Configuration"));
            var fromBox = new ComboBox { MinWidth = 220, PlaceholderText = "Select a samplehost number" };
            AutomationProperties.SetAutomationId(fromBox, "phone.settings.from");
            foreach (var n in numbers)
                fromBox.Items.Add(new ComboBoxItem { Content = PhoneFormatting.FormatShown(n.PhoneNumber), Tag = n });
            if (draft.FromNumber != null && !numbers.Any(n => n.PhoneNumber == draft.FromNumber))
                fromBox.Items.Add(new ComboBoxItem { Content = PhoneFormatting.FormatShown(draft.FromNumber), Tag = new samplehostNumber(draft.FromNumber, draft.ConnectionId) });
            var numIdx = fromBox.Items.OfType<ComboBoxItem>().ToList().FindIndex(i => (i.Tag as samplehostNumber)?.PhoneNumber == draft.FromNumber);
            if (numIdx >= 0) fromBox.SelectedIndex = numIdx;
            fromBox.SelectionChanged += (_, _) =>
            {
                if (fromBox.SelectedItem is ComboBoxItem { Tag: samplehostNumber picked }
                    && !string.Equals(picked.PhoneNumber, draft.FromNumber, StringComparison.Ordinal))
                {
                    var preferred = PhoneConnectionResolver.PreferredConnection(
                        picked.PhoneNumber, numbers, apps, draft.ConnectionId ?? "");
                    draft = draft with
                    {
                        FromNumber = picked.PhoneNumber,
                        ConnectionId = preferred.Length == 0 ? null : preferred,
                    };
                    Render();
                }
            };
            body.Children.Add(Row("From number", fromBox));

            // Call Control Applications picker (not a raw Connection ID textbox)
            var connBox = new ComboBox { MinWidth = 220, PlaceholderText = "Select Voice API connection" };
            AutomationProperties.SetAutomationId(connBox, "phone.settings.connection");
            foreach (var opt in connectionOptions)
                connBox.Items.Add(new ComboBoxItem { Content = opt.Name, Tag = opt.Id });
            var connIdx = connBox.Items.OfType<ComboBoxItem>().ToList().FindIndex(i => (i.Tag as string) == draft.ConnectionId);
            if (connIdx >= 0) connBox.SelectedIndex = connIdx;
            connBox.SelectionChanged += (_, _) =>
            {
                if (connBox.SelectedItem is ComboBoxItem { Tag: string id }
                    && !string.Equals(id, draft.ConnectionId, StringComparison.Ordinal))
                {
                    draft = draft with { ConnectionId = id };
                    Render();
                }
            };
            body.Children.Add(Row("Voice connection", connBox));

            // Orange TeXML / SIP warning card
            if (!string.IsNullOrEmpty(nonCallControlWarning))
            {
                var warnRow = new Grid { ColumnSpacing = 8 };
                warnRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                warnRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                var warnIcon = new FontIcon
                {
                    Glyph = "\uE7BA",
                    FontSize = 15,
                    Foreground = Solid(Orange),
                    VerticalAlignment = VerticalAlignment.Top,
                    Margin = new Thickness(0, 2, 0, 0),
                };
                warnRow.Children.Add(warnIcon);
                var warnText = Text(nonCallControlWarning, 12, color: Solid(Orange));
                Grid.SetColumn(warnText, 1);
                warnRow.Children.Add(warnText);
                var warnCard = Card(warnRow, 10);
                warnCard.BorderBrush = Solid(Orange);
                AutomationProperties.SetAutomationId(warnCard, "phone.settings.texml-warning");
                body.Children.Add(warnCard);
            }

            // One-click Voice Connection creation / repair + custom webhook URL field
            if (hasKey && loaded && apps != null && (apps.Count == 0 || selectedAppNeedsFix || savedConnectionInvalid || needsCustomWebhookUrl))
            {
                var connCardBody = new StackPanel { Spacing = 8 };
                if (apps.Count == 0)
                {
                    connCardBody.Children.Add(Text(
                        "This samplehost account has no Voice API (Call Control) application yet. TeXML applications created for AI Assistants can’t place outbound calls here. Hermes HQ can create a Voice API connection, set up its Outbound Voice Profile, and link your number in one click.",
                        12, color: Secondary));
                }
                else if (selectedAppNeedsFix)
                {
                    connCardBody.Children.Add(Text(
                        "The chosen Voice API application is missing an https:// webhook URL or Outbound Voice Profile, which samplehost requires before placing calls.",
                        12, color: Secondary));
                }

                var webhookBox = new TextBox
                {
                    Text = customWebhookUrl,
                    PlaceholderText = PhoneLimits.VoiceWebhookUrl,
                    Header = needsCustomWebhookUrl ? "Webhook URL (required by samplehost)" : "Custom webhook URL (optional)",
                };
                AutomationProperties.SetAutomationId(webhookBox, "phone.settings.webhook-url");
                webhookBox.TextChanged += (_, _) => customWebhookUrl = webhookBox.Text;
                connCardBody.Children.Add(webhookBox);
                connCardBody.Children.Add(Text(
                    "Leave blank to use Hermes HQ’s no-server webhook address, or enter any https:// URL you own.",
                    11, color: Tertiary));

                if (apps.Count == 0)
                {
                    var createConnBtn = Push(busy ? "Setting up…" : "Create Voice Connection", () =>
                    {
                        if (keys.ReadKey(controller.AccountId) is { } k) _ = CreateVoiceConnectionAsync(k);
                    }, accent: true);
                    createConnBtn.IsEnabled = !busy;
                    AutomationProperties.SetAutomationId(createConnBtn, "phone.settings.create-connection");
                    connCardBody.Children.Add(createConnBtn);
                }
                else if (selectedAppNeedsFix || savedConnectionInvalid)
                {
                    var fixConnBtn = Push(busy ? "Fixing…" : "Fix Voice Connection", () =>
                    {
                        if (keys.ReadKey(controller.AccountId) is { } k) _ = FixVoiceConnectionAsync(k);
                    }, accent: true);
                    fixConnBtn.IsEnabled = !busy;
                    AutomationProperties.SetAutomationId(fixConnBtn, "phone.settings.fix-connection");
                    connCardBody.Children.Add(fixConnBtn);
                }

                body.Children.Add(Card(connCardBody, 10));
            }

            // AI Assistant picker + Create
            var asstRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            var asstBox = new ComboBox { MinWidth = 170 };
            AutomationProperties.SetAutomationId(asstBox, "phone.settings.assistant");
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
                if (keys.ReadKey(controller.AccountId) is { } k) _ = CreateAssistantAsync(k);
            });
            createBtn.IsEnabled = hasKey && !busy;
            AutomationProperties.SetAutomationId(createBtn, "phone.settings.create-assistant");
            asstRow.Children.Add(createBtn);
            body.Children.Add(Row("AI Assistant", asstRow));

            // 3. Voice & Call Preferences (`PhoneVoicePage.swift` parity)
            body.Children.Add(Header("Voice & Preferences"));
            var ownerBox = new TextBox { Text = draft.OwnerName, PlaceholderText = "Your name (spoken on calls)", Width = 220 };
            AutomationProperties.SetAutomationId(ownerBox, "phone.settings.name");
            ownerBox.TextChanged += (_, _) => draft = draft with { OwnerName = ownerBox.Text.Trim() };
            body.Children.Add(Row("Your name", ownerBox));

            var voiceBox = new ComboBox { MinWidth = 220 };
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
            AutomationProperties.SetAutomationId(recordSwitch, "phone.settings.record");
            recordSwitch.Toggled += (_, _) => draft = draft with { RecordCalls = recordSwitch.IsOn };
            body.Children.Add(Row("Record calls", recordSwitch));

            var resultsSwitch = new ToggleSwitch { IsOn = draft.SendResultsToChat, OnContent = "", OffContent = "" };
            AutomationProperties.SetAutomationId(resultsSwitch, "phone.settings.results");
            resultsSwitch.Toggled += (_, _) => draft = draft with { SendResultsToChat = resultsSwitch.IsOn };
            body.Children.Add(Row("Post call results in chat", resultsSwitch));

            // 4. Diagnostics, Optimization & Setup Guide
            body.Children.Add(Header("Diagnostics & Guide"));
            var actionBar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            var checkBtn = Push(busy ? "Checking…" : "Check My Setup", () => _ = RunDiagnosticsAsync());
            checkBtn.IsEnabled = !busy;
            AutomationProperties.SetAutomationId(checkBtn, "phone.settings.check");
            actionBar.Children.Add(checkBtn);

            if (hasKey && !string.IsNullOrWhiteSpace(draft.AssistantId))
            {
                var optimizeBtn = Quiet("Optimize assistant for calls", () =>
                {
                    if (keys.ReadKey(controller.AccountId) is { } k) _ = OptimizeAssistantAsync(k);
                });
                optimizeBtn.IsEnabled = !busy;
                AutomationProperties.SetAutomationId(optimizeBtn, "phone.settings.optimize");
                actionBar.Children.Add(optimizeBtn);
            }

            var guideBtn = Quiet("Setup & how to use", () =>
            {
                openGuideRequested = true;
                activeDialog?.Hide();
            });
            AutomationProperties.SetAutomationId(guideBtn, "phone.settings.guide");
            actionBar.Children.Add(guideBtn);
            body.Children.Add(actionBar);

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

        Render();
        if (keys.ReadKey(controller.AccountId) is { Length: > 0 } existingKey)
            _ = LoadAccountResourcesAsync(existingKey);

        // WinUI permits only one ContentDialog per XamlRoot at a time: temporarily close this dialog to show the guide,
        // then reopen with the in-progress draft preserved.
        while (true)
        {
            openGuideRequested = false;
            var scroll = new ScrollViewer
            {
                Content = body,
                MaxHeight = 560,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            };
            var dialog = new ContentDialog
            {
                Title = "Phone & Voice Settings",
                Content = scroll,
                PrimaryButtonText = "Save",
                CloseButtonText = "Cancel",
                DefaultButton = ContentDialogButton.Primary,
            };
            activeDialog = dialog;
            var result = await ShowAsync(root, dialog);
            activeDialog = null;
            scroll.Content = null;

            if (openGuideRequested)
            {
                await PhoneGuideDialog.PresentAsync(root);
                Render();
                continue;
            }

            if (result == ContentDialogResult.Primary)
                controller.SaveSetup(draft);
            break;
        }
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
