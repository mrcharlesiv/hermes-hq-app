// Settings › Browser Use Cloud dialog & embeddable content (C# twin of App/Browser/BrowserCloudSettings.swift):
// manages the person's Browser Use Cloud API key and the "Use for All Bots" switch (plugin 3.10+).
// Confirmations and key entry render inline inside the same view so ContentDialog hosting never nests dialogs.

using Hermes.Core.Browser;
using Hermes.Core.Gateways;
using HermesHQ.Features.Capabilities;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Features.Browser;

public sealed class BrowserCloudSettingsDialog
{
    private sealed record PendingConfirm(string Title, string Message, string Action, bool Destructive, Func<Task> Run);
    private sealed record PendingKeyEntry(bool ThenAll);

    private readonly BrowserCloudSettingsModel _model;
    private readonly DispatcherQueue _ui;
    private readonly Grid _host = new() { MinWidth = 440, MaxWidth = 520 };
    private CancellationTokenSource _life = new();

    private PendingConfirm? _confirm;
    private PendingKeyEntry? _keyEntry;

    private BrowserCloudSettingsDialog(BrowserCloudSettingsModel model, DispatcherQueue ui)
    {
        _model = model;
        _ui = ui;
    }

    public static async Task ShowAsync(BrowserCloudSettingsModel model, XamlRoot root)
    {
        var ui = DispatcherQueue.GetForCurrentThread();
        var controller = new BrowserCloudSettingsDialog(model, ui);
        model.Changed += controller.OnModelChanged;

        var dialog = new ContentDialog
        {
            Title = "Browser Use Cloud",
            Content = controller._host,
            CloseButtonText = "Done",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = root,
        };
        AutomationProperties.SetAutomationId(dialog, "browser.cloud.dialog");

        controller.Rebuild();
        _ = model.LoadAsync(controller._life.Token);

        try { await dialog.ShowAsync(); }
        catch (Exception) { }
        finally
        {
            model.Changed -= controller.OnModelChanged;
            controller._life.Cancel();
            controller._life.Dispose();
        }
    }

    /// Reusable settings pane content for embedding Browser Use Cloud settings directly in Settings pages.
    public static FrameworkElement BuildContent(BrowserCloudSettingsModel model)
    {
        var ui = DispatcherQueue.GetForCurrentThread();
        var controller = new BrowserCloudSettingsDialog(model, ui);
        controller._host.MinWidth = 0;
        controller._host.MaxWidth = double.PositiveInfinity;
        controller._host.Loaded += (_, _) =>
        {
            if (controller._life.IsCancellationRequested)
            {
                controller._life.Dispose();
                controller._life = new CancellationTokenSource();
            }
            model.Changed -= controller.OnModelChanged;
            model.Changed += controller.OnModelChanged;
            _ = model.LoadAsync(controller._life.Token);
        };
        controller._host.Unloaded += (_, _) =>
        {
            model.Changed -= controller.OnModelChanged;
            controller._life.Cancel();
        };
        controller.Rebuild();
        return controller._host;
    }

    private void OnModelChanged() => _ui.TryEnqueue(Rebuild);

    private void Rebuild()
    {
        _host.Children.Clear();

        if (_confirm is { } confirm)
        {
            _host.Children.Add(BuildConfirmView(confirm));
            return;
        }
        if (_keyEntry is { } keyEntry)
        {
            _host.Children.Add(BuildKeyEntryView(keyEntry));
            return;
        }

        var body = new StackPanel { Spacing = 0 };
        var busy = _model.Working != null;

        if (_model.Failure is { Length: > 0 } failure)
        {
            body.Children.Add(Kit.Section(null, [
                Kit.Notice(failure, Kit.Warning, Kit.Critical, close: _model.DismissFailure),
            ]));
        }

        if (_model.Loading)
        {
            body.Children.Add(Kit.Busy("Reading Browser Use Cloud…"));
        }
        else if (_model.LoadFailure is { Length: > 0 } loadFailure)
        {
            body.Children.Add(Kit.LoadError("Couldn’t Load Browser Use Cloud", loadFailure, () => _ = _model.LoadAsync(_life.Token)));
        }
        else if (_model.AddOnMissing)
        {
            var rows = new List<UIElement>
            {
                Kit.Plain("Install or update the browser add-on to use Browser Use Cloud.", secondary: false),
            };
            if (_model.SetUp is { } setUp)
            {
                rows.Add(Kit.Pad(Kit.Button("Set Up Browser Add-on", setUp, accent: true)));
            }
            body.Children.Add(Kit.Section(null, rows));
        }
        else if (_model.Cloud is { } cloud)
        {
            var keyRows = new List<UIElement>
            {
                Kit.Row(
                    "Browser Use API Key",
                    cloud.KeySet ? (cloud.KeyHint ?? "Saved") : "Not set",
                    trailing: Kit.Button(cloud.KeySet ? "Change" : "Add Key", () =>
                    {
                        _keyEntry = new PendingKeyEntry(ThenAll: false);
                        Rebuild();
                    }, accent: !cloud.KeySet, enabled: !busy)),
            };
            if (cloud.KeySet)
            {
                keyRows.Add(Kit.Row(
                    "Remove API Key",
                    "Stops using Browser Use Cloud across your bots.",
                    trailing: Kit.Button("Remove", () =>
                    {
                        _confirm = new PendingConfirm(
                            "Remove Browser Use API Key?",
                            $"Every bot using Browser Use Cloud will switch back to {_model.OtherBrowser}.",
                            "Remove Key",
                            Destructive: true,
                            () => _model.ForgetKeyAsync(_life.Token));
                        Rebuild();
                    }, enabled: !busy)));
            }
            body.Children.Add(Kit.Section(
                "API Key",
                keyRows,
                footer: $"Stored on {HostWord.Phrase} and used only to open cloud browsers for your bots."));

            if (_model.OffersAll)
            {
                var allRow = Kit.SwitchRow(
                    "Use for All Bots",
                    cloud.All,
                    on =>
                    {
                        if (on)
                        {
                            if (cloud.KeySet)
                            {
                                _ = _model.ApplyAllAsync(true, _life.Token);
                            }
                            else
                            {
                                _keyEntry = new PendingKeyEntry(ThenAll: true);
                                Rebuild();
                            }
                        }
                        else
                        {
                            _confirm = new PendingConfirm(
                                "Turn Off Browser Use Cloud for All Bots?",
                                $"Each bot will switch back to {_model.OtherBrowser}.",
                                "Turn Off",
                                Destructive: false,
                                () => _model.ApplyAllAsync(false, _life.Token));
                            Rebuild();
                        }
                    },
                    enabled: !busy,
                    subtitle: "Switch every bot with browser tools enabled to Browser Use Cloud.");

                var skipped = BrowserCloudSettingsModel.SkippedLine(_model.Skipped);
                body.Children.Add(Kit.Section(
                    "All Bots",
                    [allRow],
                    footer: skipped ?? "You can also switch individual bots in their Browser settings."));
            }
        }
        else
        {
            body.Children.Add(Kit.Plain("Browser Use Cloud requires a newer version of the browser add-on on this gateway."));
        }

        if (_model.Working is { Length: > 0 } working)
        {
            body.Children.Add(Kit.Busy(working));
        }

        _host.Children.Add(new ScrollViewer
        {
            Content = body,
            MaxHeight = 520,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        });
    }

    private UIElement BuildConfirmView(PendingConfirm confirm)
    {
        var stack = new StackPanel { Spacing = 12, Padding = new Thickness(0, 4, 0, 4) };
        stack.Children.Add(Kit.Text(confirm.Title, 16, bold: true));
        stack.Children.Add(Kit.Text(confirm.Message, 14, secondary: true));

        var actions = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 8, 0, 0),
        };
        actions.Children.Add(Kit.Button("Cancel", () => { _confirm = null; Rebuild(); }));
        var ok = Kit.Button(confirm.Action, () =>
        {
            var run = confirm.Run;
            _confirm = null;
            Rebuild();
            _ = run();
        }, accent: !confirm.Destructive);
        if (confirm.Destructive) ok.Foreground = Kit.Critical;
        actions.Children.Add(ok);
        stack.Children.Add(actions);
        return stack;
    }

    private UIElement BuildKeyEntryView(PendingKeyEntry entry)
    {
        var stack = new StackPanel { Spacing = 10, Padding = new Thickness(0, 4, 0, 4) };
        stack.Children.Add(Kit.Text("Browser Use API Key", 16, bold: true));
        stack.Children.Add(Kit.Text($"Paste your Browser Use Cloud API key. It is stored on {HostWord.Phrase} and checked with Browser Use.", 13, secondary: true));

        var input = new PasswordBox { PlaceholderText = "bu_…" };
        AutomationProperties.SetName(input, "Browser Use API Key");
        AutomationProperties.SetAutomationId(input, "browser.cloud.settings.keyInput");
        stack.Children.Add(input);

        var save = Kit.Button(entry.ThenAll ? "Save & Use for All Bots" : "Save Key", () =>
        {
            var typed = input.Password;
            _keyEntry = null;
            Rebuild();
            _ = _model.SaveKeyAsync(typed, entry.ThenAll, _life.Token);
        }, accent: true, enabled: false);
        input.PasswordChanged += (_, _) => save.IsEnabled = input.Password.Trim().Length > 0;

        var actions = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 6, 0, 0),
        };
        actions.Children.Add(Kit.Button("Cancel", () => { _keyEntry = null; Rebuild(); }));
        actions.Children.Add(save);
        stack.Children.Add(actions);
        return stack;
    }
}
