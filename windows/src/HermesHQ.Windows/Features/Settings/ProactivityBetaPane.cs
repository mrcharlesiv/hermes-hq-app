using System.Text.Json.Nodes;
using Hermes.Core.Capabilities;
using Hermes.Core.Settings;
using HermesHQ.Features.Capabilities;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.Settings;

/// [proactivity-beta] Settings › General › Proactivity (Beta) (App/Settings/ProactivityBetaPage.swift,
/// commits `b446e2abf` & `6bedd2ea3`): per-bot picker, install flow, 404 Plugin Not Found -> NeedsRestart vs NotInstalled
/// classification, autonomy mode, 5 capability toggles, 24h offer budgets & open-loop counts, and on-demand signal check.
internal static class ProactivityBetaPane
{
    private enum PhaseKind { Loading, NotInstalled, NeedsRestart, Ready, Failed }

    public static FrameworkElement Make(SettingsPage page)
    {
        var host = new ContentControl { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetAutomationId(host, "settings.proactivity-beta-page");

        var bots = BotChoices();
        var profile = bots.FirstOrDefault(b => b.Id == "default").Id ?? (bots.Count > 0 ? bots[0].Id : "default");
        var phase = PhaseKind.Loading;
        ProactivityStatus? status = null;
        string? failedMessage = null;
        string? error = null;
        string? notice = null;
        var busy = false;
        var disposed = false;

        string BotName() => bots.FirstOrDefault(b => b.Id == profile).Name is { Length: > 0 } name
            ? name
            : (profile == "default" ? "Hermes" : DisplayName.Title(profile));

        void SetContent(FrameworkElement next)
        {
            if (disposed) return;
            UiTree.DeactivateProgressRings(host);
            host.Content = next;
        }

        void Dispatch(Action work)
        {
            if (disposed) return;
            if (host.DispatcherQueue is { } q) q.TryEnqueue(() => { if (!disposed) work(); });
            else work();
        }

        async Task RefreshAsync()
        {
            if (AppState.Client is not { } client)
            {
                phase = PhaseKind.Failed;
                failedMessage = "Sign in to a gateway to manage Proactivity (Beta).";
                Dispatch(Draw);
                return;
            }
            error = null;
            phase = PhaseKind.Loading;
            Dispatch(Draw);

            var api = new ProactivityBetaApi(client.Session);
            try
            {
                var loaded = await api.StatusAsync(profile);
                status = loaded;
                phase = PhaseKind.Ready;
                Dispatch(Draw);
                return;
            }
            catch (Exception ex) when (!ProactivityBetaApi.IsRouteMissing(ex))
            {
                phase = PhaseKind.Failed;
                failedMessage = ProactivityBetaApi.ErrorWords(ex);
                Dispatch(Draw);
                return;
            }
            catch (Exception)
            {
                // 404 on `/status`: check installed plugins to distinguish NeedsRestart vs NotInstalled (6bedd2ea3).
            }

            try
            {
                var caps = CapabilitiesServices.Api ?? new CapabilitiesApi(client.Session, client.Rpc);
                var installed = await caps.PluginsAsync(profile);
                var missing = ProactivityBetaApi.ClassifyMissingRoute(installed);
                if (missing == ProactivityMissingState.NeedsRestart)
                {
                    var found = installed.FirstOrDefault(ProactivityBetaApi.IsProactivityPlugin);
                    if (found is { Enabled: false })
                    {
                        try { await caps.PluginAsync(new PluginAction.Toggle(found.Key ?? found.Name, true), profile); }
                        catch (Exception) { /* best effort before restart */ }
                    }
                    phase = PhaseKind.NeedsRestart;
                }
                else
                {
                    phase = PhaseKind.NotInstalled;
                }
            }
            catch (Exception)
            {
                phase = PhaseKind.NotInstalled;
            }
            Dispatch(Draw);
        }

        async Task InstallAsync()
        {
            if (busy || AppState.Client is not { } client) return;
            busy = true;
            error = null;
            notice = null;
            Dispatch(Draw);
            try
            {
                var caps = CapabilitiesServices.Api ?? new CapabilitiesApi(client.Session, client.Rpc);
                var result = await caps.PluginAsync(new PluginAction.Install(ProactivityBeta.PluginSource, false, true, null), profile);
                if (result.ConsentRequired)
                {
                    error = $"Install requires confirmation in your Hermes terminal: hermes plugins install {ProactivityBeta.PluginSource} --enable";
                    return;
                }
                if (!result.Ok && result.Name == null)
                {
                    error = result.Warnings.FirstOrDefault() ?? "Couldn’t install Proactivity (Beta).";
                    return;
                }
                notice = $"Installed Proactivity (Beta) for {BotName()}. It starts off by default.";
                await RefreshAsync();
            }
            catch (Exception ex)
            {
                error = ProactivityBetaApi.ErrorWords(ex, "Couldn’t install Proactivity (Beta).");
            }
            finally
            {
                busy = false;
                Dispatch(Draw);
            }
        }

        async Task UpdateSettingsAsync(JsonObject fields, string? okNote = null)
        {
            if (busy || AppState.Client is not { } client) return;
            busy = true;
            error = null;
            Dispatch(Draw);
            try
            {
                var api = new ProactivityBetaApi(client.Session);
                status = await api.UpdateSettingsAsync(fields, profile);
                phase = PhaseKind.Ready;
                if (okNote != null) notice = okNote;
            }
            catch (Exception ex)
            {
                error = ProactivityBetaApi.ErrorWords(ex, "Couldn’t save Proactivity settings.");
            }
            finally
            {
                busy = false;
                Dispatch(Draw);
            }
        }

        async Task RunSweepAsync()
        {
            if (busy || AppState.Client is not { } client) return;
            busy = true;
            error = null;
            notice = null;
            Dispatch(Draw);
            try
            {
                var api = new ProactivityBetaApi(client.Session);
                var outcome = await api.SweepAsync(forceBrief: false, profile);
                notice = ProactivityBetaApi.SweepSummary(outcome);
                status = await api.StatusAsync(profile);
                phase = PhaseKind.Ready;
            }
            catch (Exception ex)
            {
                error = ProactivityBetaApi.ErrorWords(ex, "Signal check failed.");
            }
            finally
            {
                busy = false;
                Dispatch(Draw);
            }
        }

        async Task AskMainBotToRestartAsync()
        {
            if (busy || AppState.Client is not { } client) return;
            busy = true;
            error = null;
            Dispatch(Draw);
            try
            {
                var mainBot = client.Bots?.FirstOrDefault(b => b.IsDefault) ?? client.Bots?.FirstOrDefault(b => b.Name == "default");
                if (mainBot == null)
                {
                    error = "Couldn’t find your main bot to send a restart request.";
                    return;
                }
                var chatId = await client.BotChatIdAsync(mainBot);
                var prompt = ProactivityBetaApi.RestartPrompt(BotName());
                Navigator.Go(new ChatDestination(mainBot.Name, chatId, mainBot.DisplayName, Draft: prompt));
                notice = "Opened your main bot’s chat with a restart request. Click Check Again once Hermes reconnects.";
            }
            catch (Exception ex)
            {
                error = ProactivityBetaApi.ErrorWords(ex, "Couldn’t open your main bot’s chat.");
            }
            finally
            {
                busy = false;
                Dispatch(Draw);
            }
        }

        void Draw()
        {
            var sections = new List<UIElement?>();

            if (bots.Count > 1)
            {
                var options = bots.Select(b => (b.Name, b.Id)).ToList();
                sections.Add(Kit.Section("Bot Profile",
                    "Proactivity (Beta) is configured per bot so you can try it on one bot first.",
                    Kit.Picker(null, "Bot", null, options, profile, next =>
                    {
                        if (next == profile) return;
                        profile = next;
                        notice = null;
                        error = null;
                        _ = RefreshAsync();
                    }, "proactivity.bot-picker", enabled: !busy)));
            }

            if (!string.IsNullOrEmpty(error))
            {
                sections.Add(Kit.Section(null, null, new TextBlock
                {
                    Text = error,
                    FontSize = 12,
                    TextWrapping = TextWrapping.Wrap,
                    Margin = new Thickness(14, 10, 14, 10),
                    Foreground = Kit.B("SystemFillColorCriticalBrush"),
                }));
            }

            if (!string.IsNullOrEmpty(notice))
            {
                sections.Add(Kit.Section(null, null, new TextBlock
                {
                    Text = notice,
                    FontSize = 12,
                    TextWrapping = TextWrapping.Wrap,
                    Margin = new Thickness(14, 10, 14, 10),
                    Foreground = Kit.B("TextFillColorSecondaryBrush"),
                }));
            }

            switch (phase)
            {
                case PhaseKind.Loading:
                    var loadingRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Padding = new Thickness(14, 12, 14, 12) };
                    loadingRow.Children.Add(new ProgressRing { IsActive = true, Width = 18, Height = 18 });
                    loadingRow.Children.Add(new TextBlock
                    {
                        Text = "Checking Proactivity (Beta)…",
                        VerticalAlignment = VerticalAlignment.Center,
                        Foreground = Kit.B("TextFillColorSecondaryBrush"),
                    });
                    sections.Add(Kit.Section(null, null, loadingRow));
                    break;

                case PhaseKind.NotInstalled:
                    var intro = new StackPanel { Spacing = 6, Padding = new Thickness(14, 12, 14, 12) };
                    var titleRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
                    titleRow.Children.Add(new TextBlock { Text = "Proactivity", FontSize = 15, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
                    var badge = new Border
                    {
                        CornerRadius = new CornerRadius(9),
                        Padding = new Thickness(7, 2, 7, 2),
                        Background = new SolidColorBrush(Windows.UI.Color.FromArgb(40, 245, 158, 11)),
                        Child = new TextBlock { Text = "BETA", FontSize = 10, FontWeight = FontWeights.Bold, Foreground = Kit.B("HQOrangeBrush") },
                    };
                    titleRow.Children.Add(badge);
                    intro.Children.Add(titleRow);
                    intro.Children.Add(new TextBlock
                    {
                        Text = $"Off by default. Helps {BotName()} think one step ahead, track soft open loops, and prepare read-only drafts & daily briefs — never sending, booking, buying, paying, posting, or deleting without your approval.",
                        FontSize = 12,
                        TextWrapping = TextWrapping.Wrap,
                        Foreground = Kit.B("TextFillColorSecondaryBrush"),
                    });
                    var installBtn = Kit.Push(busy ? "Installing…" : "Install Proactivity (Beta)", () => _ = InstallAsync());
                    installBtn.IsEnabled = !busy;
                    AutomationProperties.SetAutomationId(installBtn, "proactivity.install");
                    var installWrap = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Padding = new Thickness(14, 10, 14, 10) };
                    installWrap.Children.Add(installBtn);
                    if (busy) installWrap.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
                    sections.Add(Kit.Section("Opt-In Beta Add-On",
                        $"Installs {ProactivityBeta.PluginName} from Hermes HQ plugins onto {BotName()}. Even after install, Proactivity stays off until you switch it on.",
                        intro, installWrap));
                    break;

                case PhaseKind.NeedsRestart:
                    var restartInfo = new StackPanel { Spacing = 6, Padding = new Thickness(14, 12, 14, 12) };
                    restartInfo.Children.Add(new TextBlock { Text = "Restart Hermes to Finish", FontSize = 15, FontWeight = FontWeights.SemiBold });
                    restartInfo.Children.Add(new TextBlock
                    {
                        Text = $"{ProactivityBeta.PluginName} is installed on {BotName()}, but Hermes loads a plugin’s web routes when it starts.",
                        FontSize = 12,
                        TextWrapping = TextWrapping.Wrap,
                        Foreground = Kit.B("TextFillColorSecondaryBrush"),
                    });
                    var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Padding = new Thickness(14, 10, 14, 10) };
                    var askRestart = Kit.Push("Ask Main Bot to Restart Hermes", () => _ = AskMainBotToRestartAsync());
                    askRestart.IsEnabled = !busy;
                    AutomationProperties.SetAutomationId(askRestart, "proactivity.ask-restart");
                    var checkAgain = Kit.Push("Check Again", () => _ = RefreshAsync());
                    checkAgain.IsEnabled = !busy;
                    AutomationProperties.SetAutomationId(checkAgain, "proactivity.check-again");
                    actions.Children.Add(askRestart);
                    actions.Children.Add(checkAgain);
                    sections.Add(Kit.Section("Almost Ready", null, restartInfo, actions));
                    break;

                case PhaseKind.Failed:
                    var failText = new TextBlock
                    {
                        Text = failedMessage ?? "Couldn’t reach Hermes.",
                        TextWrapping = TextWrapping.Wrap,
                        Margin = new Thickness(14, 10, 14, 10),
                        Foreground = Kit.B("TextFillColorSecondaryBrush"),
                    };
                    var retry = Kit.Push("Try Again", () => _ = RefreshAsync());
                    AutomationProperties.SetAutomationId(retry, "proactivity.retry");
                    var retryWrap = new StackPanel { Padding = new Thickness(14, 8, 14, 10) };
                    retryWrap.Children.Add(retry);
                    sections.Add(Kit.Section(null, null, failText, retryWrap));
                    break;

                case PhaseKind.Ready when status is { } s:
                    sections.Add(Kit.Section($"Beta · v{s.Version}",
                        "Hard safety fence: background sweeps are strictly read-only and draft-only. Sending, booking, buying, paying, posting, or deleting always wait for your approval.",
                        Kit.Toggle("\uE734", "Enable Proactivity (Beta)",
                            s.Enabled ? $"Active · v{s.Version}" : "Off by default · 0 overhead while off",
                            s.Enabled,
                            on => _ = UpdateSettingsAsync(new JsonObject { ["enabled"] = on },
                                on ? $"Proactivity (Beta) is on for {BotName()}." : $"Proactivity (Beta) is off for {BotName()}."),
                            "proactivity.enable-toggle", enabled: !busy)));

                    if (s.Enabled)
                    {
                        var modeOptions = AutonomyModes.All.Select(m => (m.Title(), m)).ToList();
                        sections.Add(Kit.Section("Autonomy", s.AutonomyMode.Detail(),
                            Kit.Picker(null, "Autonomy Mode", null, modeOptions, s.AutonomyMode, next =>
                            {
                                if (next == s.AutonomyMode) return;
                                _ = UpdateSettingsAsync(new JsonObject { ["autonomy_mode"] = next.Raw() }, $"Autonomy mode set to {next.Title()}.");
                            }, "proactivity.mode-picker", enabled: !busy)));

                        sections.Add(Kit.Section("Capabilities", null,
                            CapabilityToggle("In-Turn Next-Step Anticipation", "in_turn_enabled", s.InTurnEnabled),
                            CapabilityToggle("Open-Loop & Commitment Radar", "loop_radar_enabled", s.LoopRadarEnabled),
                            CapabilityToggle("Signal-Gated Idle Sweeps", "idle_sweep_enabled", s.IdleSweepEnabled),
                            CapabilityToggle("Unified Daily Brief", "daily_brief_enabled", s.DailyBriefEnabled),
                            CapabilityToggle("Repetition Spotter", "pattern_detection_enabled", s.PatternDetectionEnabled)));

                        var sweepBtn = Kit.Push(busy ? "Running Signal Check…" : "Run Signal Check Now", () => _ = RunSweepAsync());
                        sweepBtn.IsEnabled = !busy;
                        AutomationProperties.SetAutomationId(sweepBtn, "proactivity.run-sweep");
                        var sweepWrap = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Padding = new Thickness(14, 10, 14, 10) };
                        sweepWrap.Children.Add(sweepBtn);
                        if (PluginPagesService.PageFor(ProactivityBeta.PluginName, profile) is { } proactivityPage)
                        {
                            var openPageBtn = Kit.Push("Open Proactivity Page", () => PluginPagesService.Open(proactivityPage, profile));
                            AutomationProperties.SetAutomationId(openPageBtn, "proactivity.open-page");
                            sweepWrap.Children.Add(openPageBtn);
                        }
                        if (busy) sweepWrap.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });

                        sections.Add(Kit.Section("Brief, Offers & Calibration",
                            "Review pending offers, open loops, 24h offer budgets, and quiet hours for this bot.",
                            Kit.Value("Pending Offers", s.PendingOffers.ToString()),
                            Kit.Value("Open Loops", $"{s.OpenLoops} open · {s.SnoozedLoops} snoozed"),
                            Kit.Value("24h Offer Budget", $"{s.OffersUsed24h} / {s.OffersLimit24h}"),
                            Kit.Value("Quiet Hours", $"{s.QuietStart}–{s.QuietEnd}" + (s.QuietHoursActive ? " (Quiet)" : "")),
                            sweepWrap));
                    }
                    break;
            }

            SetContent(Kit.Page([.. sections]));
        }

        Grid CapabilityToggle(string title, string key, bool value) =>
            Kit.Toggle(null, title, null, value, on => _ = UpdateSettingsAsync(new JsonObject { [key] = on }), $"proactivity.{key}", enabled: !busy);

        host.Unloaded += (_, _) =>
        {
            disposed = true;
            UiTree.DeactivateProgressRings(host);
        };

        Draw();
        _ = RefreshAsync();
        return host;
    }

    private static List<(string Id, string Name)> BotChoices()
    {
        var visible = CapabilitiesServices.Bots().Select(b => (b.Name, b.DisplayName)).ToList();
        return visible.Count > 0 ? visible : [("default", "Hermes")];
    }
}
