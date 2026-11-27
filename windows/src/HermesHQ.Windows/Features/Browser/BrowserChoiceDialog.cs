// Bot Info › Browser dialog (C# twin of App/Browser/BrowserChoiceController.swift):
// lets the user pick a bot's Chrome profile copy, refresh sign-ins, toggle "Show as Normal Chrome", let Hermes HQ
// take over an externally managed browser, or switch between local / Hermes Cloud / Browser Use Cloud.
// All confirmations and API key entry render inline inside the single ContentDialog (WinUI 3 only permits one
// ContentDialog at a time).

using Hermes.Core.Browser;
using Hermes.Core.Gateways;
using HermesHQ.Features.Capabilities;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Features.Browser;

internal sealed class BrowserChoiceDialog
{
    private sealed record PendingConfirm(string Title, string Message, string Action, bool Destructive, Func<Task> Run);
    private sealed record PendingKeyEntry(bool ThenSwitch);

    private readonly BrowserChoiceModel _model;
    private readonly DispatcherQueue _ui;
    private readonly Grid _host = new() { MinWidth = 440, MaxWidth = 520 };
    private readonly CancellationTokenSource _life = new();

    private PendingConfirm? _confirm;
    private PendingKeyEntry? _keyEntry;

    private BrowserChoiceDialog(BrowserChoiceModel model, DispatcherQueue ui)
    {
        _model = model;
        _ui = ui;
    }

    public static async Task ShowAsync(BrowserChoiceModel model, XamlRoot root)
    {
        var ui = DispatcherQueue.GetForCurrentThread();
        var controller = new BrowserChoiceDialog(model, ui);
        model.Changed += controller.OnModelChanged;

        var dialog = new ContentDialog
        {
            Title = $"{model.BotName}’s Browser",
            Content = controller._host,
            CloseButtonText = "Done",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = root,
        };
        AutomationProperties.SetAutomationId(dialog, "browser.choice.dialog");

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
            body.Children.Add(Kit.Busy($"Reading {_model.BotName}’s browser…"));
        }
        else if (_model.LoadFailure is { Length: > 0 } loadFailure)
        {
            body.Children.Add(Kit.LoadError("Couldn’t Load Browser", loadFailure, () => _ = _model.LoadAsync(_life.Token)));
        }
        else if (_model.Choice is { } choice)
        {
            AddChoiceSections(body, choice, busy);
        }
        else
        {
            body.Children.Add(Kit.Plain("Browser choices aren’t available on this gateway yet."));
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

    private void AddChoiceSections(StackPanel body, BrowserChoice choice, bool busy)
    {
        if (BrowserChoiceModel.Explanation(choice, _model.BotName) is { } explanation)
        {
            var rows = new List<UIElement> { Kit.Plain(explanation, secondary: false) };
            if (BrowserChoiceModel.TakeOverTitle(choice, _model.BotName) is { } takeOverTitle)
            {
                rows.Add(Kit.Pad(Kit.Button(takeOverTitle, () =>
                {
                    _confirm = new PendingConfirm(
                        takeOverTitle,
                        BrowserChoiceModel.TakeOverMessage(choice, _model.BotName),
                        "Continue",
                        Destructive: false,
                        () => _model.ApplyAsync(BrowserChoiceChange.TakeOver.Instance, _life.Token));
                    Rebuild();
                }, accent: true, enabled: !busy)));
            }
            body.Children.Add(Kit.Section(null, rows));
        }

        // Local Chrome profile section (non-hosted bots)
        if (!choice.Hosted && (choice.Changeable || choice.Cloud))
        {
            var profileRows = new List<UIElement>
            {
                CheckRow(
                    "Its Own Profile",
                    "Starts fresh without your Chrome sign-ins.",
                    selected: !choice.Cloud && choice.Copy == null,
                    enabled: !busy,
                    click: () => _ = _model.ApplyAsync(BrowserChoiceChange.Own.Instance, _life.Token)),
            };

            if (_model.Profiles is { Supported: true } found)
            {
                foreach (var profile in found.Profiles)
                {
                    var p = profile;
                    var isCurrent = !choice.Cloud && choice.Copy?.Dir == p.Dir;
                    var subtitle = !string.IsNullOrEmpty(p.Account) ? p.Account : p.Dir;
                    profileRows.Add(CheckRow(
                        p.Name,
                        subtitle,
                        selected: isCurrent,
                        enabled: !busy,
                        click: () =>
                        {
                            if (isCurrent) return;
                            _confirm = new PendingConfirm(
                                $"Copy “{p.Name}”?",
                                $"Hermes HQ will copy your Chrome sign-ins for {_model.BotName} to use. Your own Chrome stays separate.",
                                "Copy Profile",
                                Destructive: false,
                                () => _model.ApplyAsync(new BrowserChoiceChange.Copy(p.Dir), _life.Token));
                            Rebuild();
                        }));
                }
            }

            if (!choice.Cloud && choice.Copy != null)
            {
                var subtitle = choice.CopiedAt is { } at
                    ? $"Last copied {at.ToLocalTime():g}"
                    : "Update the copy with your latest Chrome sign-ins.";
                profileRows.Add(Kit.Row(
                    "Refresh Sign-ins from My Chrome",
                    subtitle,
                    trailing: Kit.Button("Refresh", () => _ = _model.ApplyAsync(BrowserChoiceChange.Refresh.Instance, _life.Token), enabled: !busy)));
            }

            UIElement? footerElement = null;
            string? footerText = null;
            if (_model.Profiles is { Supported: false } unsupported)
            {
                var msg = BrowserChoiceModel.Unsupported(unsupported.Reason, unsupported.Program);
                if (unsupported.Program != null)
                {
                    var selectable = Kit.Text(msg, 12, secondary: true);
                    selectable.IsTextSelectionEnabled = true;
                    footerElement = selectable;
                }
                else footerText = msg;
            }
            body.Children.Add(Kit.Section("Profile", profileRows, footer: footerText, footerElement: footerElement));
        }

        // Hosted Hermes Cloud browser section
        if (choice.Hosted)
        {
            var hostedRows = new List<UIElement>
            {
                CheckRow(
                    "Hermes Cloud’s Browser",
                    "Runs in Hermes Cloud with no setup needed.",
                    selected: !choice.Cloud,
                    enabled: !busy,
                    click: () => _ = _model.ApplyAsync(BrowserChoiceChange.Own.Instance, _life.Token)),
            };
            body.Children.Add(Kit.Section("Browser", hostedRows));
        }

        // Browser Use Cloud section (plugin 3.9+)
        if (_model.Cloud is { } cloud)
        {
            var cloudRows = new List<UIElement>
            {
                CheckRow(
                    "Browser Use Cloud",
                    cloud.KeySet ? "Browses in Browser Use’s cloud." : "Add a Browser Use API key to browse in the cloud.",
                    selected: choice.Cloud,
                    enabled: !busy,
                    click: () =>
                    {
                        if (choice.Cloud) return;
                        if (cloud.KeySet)
                        {
                            _ = _model.ApplyAsync(BrowserChoiceChange.Cloud.Instance, _life.Token);
                        }
                        else
                        {
                            _keyEntry = new PendingKeyEntry(ThenSwitch: true);
                            Rebuild();
                        }
                    }),
                Kit.Row(
                    "Browser Use API Key",
                    cloud.KeySet ? (cloud.KeyHint ?? "Saved") : "Not set",
                    trailing: Kit.Button(cloud.KeySet ? "Change" : "Add", () =>
                    {
                        _keyEntry = new PendingKeyEntry(ThenSwitch: false);
                        Rebuild();
                    }, enabled: !busy)),
            };
            if (cloud.KeySet)
            {
                cloudRows.Add(Kit.Row(
                    "Remove API Key",
                    "Stops using Browser Use Cloud with this key.",
                    trailing: Kit.Button("Remove", () =>
                    {
                        _confirm = new PendingConfirm(
                            "Remove Browser Use API Key?",
                            $"Bots using Browser Use Cloud will switch back to {(choice.Hosted ? "Hermes Cloud’s browser" : $"their own browser on {HostWord.Phrase}")}.",
                            "Remove Key",
                            Destructive: true,
                            () => _model.ForgetKeyAsync(_life.Token));
                        Rebuild();
                    }, enabled: !busy)));
            }
            body.Children.Add(Kit.Section("In the Cloud", cloudRows));
        }

        // Window mode section (local changeable Chrome)
        if (choice.Changeable && !choice.Hosted)
        {
            var windowRow = Kit.SwitchRow(
                "Show as Normal Chrome",
                choice.NormalWindow,
                on =>
                {
                    if (_model.NeedsWindowConfirm)
                    {
                        _confirm = new PendingConfirm(
                            $"Restart {_model.BotName}’s Browser?",
                            $"{_model.BotName} is using its browser right now. Switching the window restarts Chrome and closes open tabs.",
                            "Restart Browser",
                            Destructive: false,
                            () => _model.ApplyAsync(new BrowserChoiceChange.Window(on), _life.Token));
                        Rebuild();
                    }
                    else
                    {
                        _ = _model.ApplyAsync(new BrowserChoiceChange.Window(on), _life.Token);
                    }
                },
                enabled: !busy,
                subtitle: $"Keep Chrome visible on {HostWord.Phrase} instead of running in the background.");
            body.Children.Add(Kit.Section("Window", [windowRow]));
        }
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
        AutomationProperties.SetAutomationId(input, "browser.cloud.keyInput");
        stack.Children.Add(input);

        var save = Kit.Button(entry.ThenSwitch ? "Save & Switch" : "Save Key", () =>
        {
            var typed = input.Password;
            _keyEntry = null;
            Rebuild();
            _ = _model.SaveKeyAsync(typed, entry.ThenSwitch, _life.Token);
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

    private static UIElement CheckRow(string title, string? subtitle, bool selected, bool enabled, Action click)
    {
        UIElement? trailing = selected ? Kit.Glyph(Kit.Check, 14, Kit.Accent) : null;
        return Kit.Row(title, subtitle, trailing: trailing, click: enabled ? click : null, boldTitle: selected);
    }
}
