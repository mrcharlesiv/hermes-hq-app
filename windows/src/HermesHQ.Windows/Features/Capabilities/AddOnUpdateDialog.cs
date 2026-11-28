using Hermes.Core;
using Hermes.Core.Capabilities;
using Hermes.Core.Gateways;
using Hermes.Core.Notifications;
using HermesHQ.Features.Transcript;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Features.Capabilities;

/// Unified 4-step update sheet for first-party Hermes HQ plugins (`hermes-hq-push`, `hermes-hq-browser`,
/// `hermes-hq-proactive`, and any future `hermes-hq-*` plugin): Check Hermes → Install → Restart Hermes
/// (with the "I’ll Restart Hermes Myself" toggle) → Check it’s on, plus live + built-in release-note cards
/// (port of App/Notifications/AddOnUpdate.swift).
public static class AddOnUpdateDialog
{
    public const string ByHandPrefPrefix = "push.addOnRestart.byHand.";
    private const int PreviewLimit = 3;

    private enum Phase { Checking, Asking, Working, UpToDate, Done, Yours, Unreachable, Failed }
    private enum StepState { Waiting, Active, Done, Skipped, Failed }

    private sealed class StepModel(string id, string title)
    {
        public string Id { get; } = id;
        public string Title { get; set; } = title;
        public StepState State { get; set; } = StepState.Waiting;
        public string? Detail { get; set; }
    }

    private sealed class ChangingCard(string plugin, string title)
    {
        public string Plugin { get; } = plugin;
        public string Title { get; } = title;
        public string? From { get; set; }
        public string? To { get; set; }
        public string? Note { get; set; }
        public List<AddOnChanges.Change> Lines { get; set; } = [];
        public string? Fallback { get; set; }
        public bool Loading { get; set; } = true;
        public bool Expanded { get; set; }
    }

    public static bool RestartsByHand(string accountId) =>
        !string.IsNullOrEmpty(accountId) && FilePreferences.Shared.Get(ByHandPrefPrefix + accountId) == "1";

    public static void SetRestartsByHand(string accountId, bool on)
    {
        if (string.IsNullOrEmpty(accountId)) return;
        FilePreferences.Shared.Set(ByHandPrefPrefix + accountId, on ? "1" : null);
    }

    public static async Task ShowAsync(XamlRoot? root, HermesClient client, string pluginName = "hermes-hq-push", string? currentVersion = null)
    {
        if (root == null) return;
        var ui = DispatcherQueue.GetForCurrentThread();
        var cts = new CancellationTokenSource();
        var api = CapabilitiesServices.Api is { } shared && ReferenceEquals(shared.Session, client.Session)
            ? shared
            : new CapabilitiesApi(client.Session, client.Rpc);

        var title = AddOnChanges.DisplayTitle(pluginName);
        var accountId = client.AccountId;
        var bots = (client.Bots ?? []).Where(b => !b.Hidden).ToList();
        var mainBot = bots.FirstOrDefault(b => b.Name == "default") ?? bots.FirstOrDefault();
        var mainBotName = mainBot?.DisplayName ?? "Hermes";
        var profilesToUpdate = new List<string> { "default" };
        var byHand = RestartsByHand(accountId);
        var setUp = string.IsNullOrWhiteSpace(currentVersion);
        var phase = Phase.Checking;
        string? endTitle = null;
        string? endReason = null;

        var cleanCurrent = !string.IsNullOrWhiteSpace(currentVersion) && AddOnChanges.IsValidVersion(currentVersion)
            ? currentVersion.Trim()
            : null;
        var initialBuiltIn = AddOnChanges.BuiltInChanges(pluginName, cleanCurrent, limit: setUp && cleanCurrent == null ? 5 : 25);
        var initialTarget = AddOnChanges.BestTargetVersion(AddOnChanges.Newest(initialBuiltIn), null, pluginName);
        var card = new ChangingCard(pluginName, title)
        {
            From = cleanCurrent,
            To = initialTarget,
            Lines = initialBuiltIn,
            Loading = true,
            Fallback = AddOnChanges.FallbackSummary(pluginName, cleanCurrent, initialTarget, setUp),
        };

        var steps = new List<StepModel>
        {
            new("check", "Check Hermes") { State = StepState.Active },
            new("install", setUp ? "Install the add-on" : "Install the update"),
            new("restart", "Restart Hermes") { Detail = byHand ? RestartPlanMine : RestartPlan(mainBotName) },
            new("verify", "Check it’s on"),
        };

        var body = new StackPanel { Spacing = 14, MinWidth = 420 };
        var scroll = new ScrollViewer
        {
            Content = body,
            MaxHeight = 540,
            HorizontalScrollMode = ScrollMode.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };

        var dialog = new ContentDialog
        {
            Title = setUp ? $"Set Up {title}?" : $"Update {title}?",
            Content = scroll,
            CloseButtonText = "Not Now",
            DefaultButton = ContentDialogButton.Close,
        };

        void Post(Action work)
        {
            if (AppShutdown.Stopping || cts.IsCancellationRequested) return;
            if (ui == null || ui.HasThreadAccess) work();
            else ui.TryEnqueue(() => { if (!AppShutdown.Stopping && !cts.IsCancellationRequested) work(); });
        }

        void Render()
        {
            body.Children.Clear();

            dialog.Title = phase switch
            {
                Phase.Checking => "Checking Hermes…",
                Phase.Asking => setUp ? $"Set Up {title}?" : $"Update {title}?",
                Phase.Working => steps.FirstOrDefault(s => s.State == StepState.Active)?.Id switch
                {
                    "restart" => "Restarting Hermes…",
                    "verify" => "Almost Done…",
                    _ => setUp ? "Setting Up…" : "Updating…",
                },
                Phase.UpToDate => $"{title} Is Up to Date",
                Phase.Done => card.To is { Length: > 0 } v ? $"{title} {v} Is On" : $"{title} Updated",
                Phase.Yours => "Restart Hermes to Finish",
                Phase.Unreachable => "Couldn’t Reach Hermes",
                Phase.Failed => endTitle ?? $"Couldn’t Update {title}",
                _ => title,
            };

            dialog.CloseButtonText = phase switch
            {
                Phase.Asking => "Not Now",
                Phase.Working => "Hide",
                _ => "Done",
            };

            var subtitle = phase switch
            {
                Phase.Checking => "Checking installed add-ons and release notes…",
                Phase.Asking => setUp
                    ? $"Installs {title} on {HostWord.Phrase}."
                    : $"A newer version of {title} is available for Hermes.",
                Phase.Working => "You can close this. The update keeps going.",
                Phase.UpToDate => $"Hermes already has the newest {title}. Nothing to do.",
                Phase.Done => $"Hermes has the newest {title}.",
                Phase.Yours => $"The {(setUp ? "add-on" : "update")} is installed. Now restart Hermes on its computer (hermes dashboard or hermes serve, and the gateway if it runs on its own). Hermes HQ finishes once it’s back.",
                Phase.Unreachable => "Hermes didn’t answer. It may be restarting. Try again in a moment.",
                Phase.Failed => endReason ?? "Hermes didn’t apply the update.",
                _ => null,
            };
            if (!string.IsNullOrEmpty(subtitle))
                body.Children.Add(Kit.Text(subtitle, 13, secondary: true));

            if (phase is Phase.Asking or Phase.Working)
                body.Children.Add(BuildChangingCard(card, setUp, Render));

            if (phase is not (Phase.Checking or Phase.UpToDate or Phase.Unreachable))
                body.Children.Add(BuildStepsCard(steps));

            if (phase == Phase.Asking)
            {
                var restartRow = new StackPanel { Spacing = 4 };
                var sw = Kit.SwitchRow(
                    "I’ll Restart Hermes Myself",
                    byHand,
                    on =>
                    {
                        byHand = on;
                        SetRestartsByHand(accountId, on);
                        if (steps[2].State == StepState.Waiting)
                            steps[2].Detail = on ? RestartPlanMine : RestartPlan(mainBotName);
                        Render();
                    },
                    subtitle: byHand
                        ? "After an add-on update, you restart it on its computer."
                        : $"After an add-on update, {mainBotName} restarts it from its chat.");
                restartRow.Children.Add(Kit.Section(null, [sw]));
                body.Children.Add(restartRow);

                var go = Kit.Button(setUp ? "Set Up" : "Update", () => _ = RunInstallAsync(), accent: true);
                go.HorizontalAlignment = HorizontalAlignment.Stretch;
                go.MinHeight = 36;
                body.Children.Add(go);
            }
            else if (phase == Phase.Yours)
            {
                var askInstead = Kit.Button($"Ask {mainBotName} Instead", () => _ = AskBotRestartAsync(openChatAndClose: true));
                askInstead.HorizontalAlignment = HorizontalAlignment.Stretch;
                body.Children.Add(askInstead);
            }
            else if (phase is Phase.Failed or Phase.Unreachable)
            {
                var retry = Kit.Button("Try Again", () => _ = CheckAsync(), accent: true);
                retry.HorizontalAlignment = HorizontalAlignment.Stretch;
                body.Children.Add(retry);
            }
        }

        async Task LoadReleaseNotesAsync()
        {
            var limit = setUp && card.From == null ? 5 : 25;
            var live = await AddOnChanges.FetchLiveAsync(pluginName, card.From, limit: limit, ct: cts.Token);
            if (cts.IsCancellationRequested) return;
            Post(() =>
            {
                var merged = AddOnChanges.Merge(live, pluginName, card.From, limit: limit);
                card.Lines = merged;
                card.To = AddOnChanges.BestTargetVersion(AddOnChanges.Newest(merged), card.To, pluginName);
                card.Fallback = AddOnChanges.FallbackSummary(pluginName, card.From, card.To, setUp, card.Note);
                card.Loading = false;
                Render();
            });
        }

        async Task CheckAsync()
        {
            Post(() =>
            {
                phase = Phase.Checking;
                endTitle = null;
                endReason = null;
                steps[0].State = StepState.Active;
                steps[1].State = StepState.Waiting;
                steps[2].State = StepState.Waiting;
                steps[3].State = StepState.Waiting;
                Render();
            });

            try
            {
                var list = await api.PluginsAsync("default", cts.Token);
                var copy = list.FirstOrDefault(p => string.Equals(p.Name, pluginName, StringComparison.OrdinalIgnoreCase));
                string? detectedVersion = copy != null && AddOnChanges.IsValidVersion(copy.Version) ? copy.Version : cleanCurrent;

                if (pluginName == AddOnChanges.PushPluginName && detectedVersion == null)
                {
                    var status = await PushPolicy.ReadStatusAsync(client.Session, cts.Token);
                    if (status.Installed && AddOnChanges.IsValidVersion(status.Version))
                        detectedVersion = status.Version;
                }

                var isSetUp = copy == null && detectedVersion == null;
                var rawTarget = copy?.NewVersion;
                var builtIn = AddOnChanges.BuiltInChanges(pluginName, detectedVersion, limit: isSetUp ? 5 : 25);
                var bestTarget = AddOnChanges.BestTargetVersion(AddOnChanges.Newest(builtIn), rawTarget, pluginName);

                profilesToUpdate = ["default"];
                foreach (var bot in bots.Where(b => b.Name != "default"))
                    profilesToUpdate.Add(bot.Name);

                Post(() =>
                {
                    setUp = isSetUp;
                    card.From = detectedVersion;
                    card.To = bestTarget;
                    card.Lines = builtIn;
                    card.Fallback = AddOnChanges.FallbackSummary(pluginName, detectedVersion, bestTarget, setUp, card.Note);
                    steps[0].State = StepState.Done;
                    steps[1].Title = setUp ? "Install the add-on" : "Install the update";
                    steps[2].Detail = byHand ? RestartPlanMine : RestartPlan(mainBotName);
                    phase = Phase.Asking;
                    Render();
                });

                _ = LoadReleaseNotesAsync();
            }
            catch (OperationCanceledException) { }
            catch (Exception ex)
            {
                AppLog.Note("plugins", $"addon update check failed: {CapabilitiesWords.Detail(ex)}");
                Post(() =>
                {
                    steps[0].State = StepState.Failed;
                    phase = Phase.Unreachable;
                    Render();
                });
            }
        }

        async Task RunInstallAsync()
        {
            Post(() =>
            {
                phase = Phase.Working;
                steps[1].State = StepState.Active;
                steps[1].Detail = title;
                Render();
            });

            try
            {
                var needsRestart = false;
                var unchanged = false;

                if (setUp)
                {
                    var identifier = $"{AddOnChanges.DefaultRepo}#{pluginName}";
                    var result = await api.PluginAsync(new PluginAction.Install(identifier, Force: false, Enable: true, Ref: null), "default");
                    if (!result.Ok)
                        throw new CapabilityException($"Couldn’t Install {title}", "Hermes didn’t apply the install.");
                    needsRestart = result.NeedsRestart;
                }
                else
                {
                    var result = await api.PluginAsync(new PluginAction.Update(pluginName, Accept: true, Force: false), "default");
                    if (result.ScanBlocked)
                        throw new CapabilityException($"Couldn’t Update {title}", PluginUpdateWords.ScanBlocked);
                    if (!result.Ok && !result.Unchanged)
                        throw new CapabilityException($"Couldn’t Update {title}", "Hermes didn’t apply the update.");
                    unchanged = result.Unchanged;
                    needsRestart = result.NeedsRestart;
                }

                if (unchanged && !needsRestart)
                {
                    await VerifyAsync(skipRestart: true, wasUnchanged: true);
                    return;
                }

                Post(() =>
                {
                    steps[1].State = StepState.Done;
                    steps[1].Detail = null;
                    Render();
                });

                if (!needsRestart)
                {
                    await VerifyAsync(skipRestart: true, wasUnchanged: false);
                    return;
                }

                if (byHand)
                {
                    Post(() =>
                    {
                        steps[2].State = StepState.Active;
                        steps[2].Detail = "Waiting for you to restart it on its computer.";
                        phase = Phase.Yours;
                        Render();
                    });
                    _ = WatchRestartAsync();
                }
                else
                {
                    Post(() =>
                    {
                        steps[2].State = StepState.Active;
                        steps[2].Detail = $"Asked {mainBotName} in its chat. Usually under a minute.";
                        Render();
                    });
                    await AskBotRestartAsync(openChatAndClose: false);
                    await WatchRestartAsync();
                }
            }
            catch (OperationCanceledException) { }
            catch (Exception ex)
            {
                var detail = McpEntryMask.Phone.Text(CapabilitiesWords.Detail(ex));
                Post(() =>
                {
                    steps[1].State = StepState.Failed;
                    steps[1].Detail = null;
                    endTitle = setUp ? $"Couldn’t Install {title}" : $"Couldn’t Update {title}";
                    endReason = detail;
                    phase = Phase.Failed;
                    Render();
                });
            }
        }

        async Task AskBotRestartAsync(bool openChatAndClose)
        {
            var prompt = PluginUpdateWords.RestartPrompt([pluginName], profilesToUpdate);
            if (mainBot != null)
            {
                try
                {
                    var chatId = await client.BotChatIdAsync(mainBot, cts.Token);
                    Post(() =>
                    {
                        Navigator.Go(new ChatDestination(mainBot.Name, chatId, mainBot.DisplayName, prompt));
                        if (openChatAndClose) dialog.Hide();
                    });
                    return;
                }
                catch (Exception ex)
                {
                    AppLog.Note("plugins", $"could not open bot chat for restart: {CapabilitiesWords.Detail(ex)}");
                }
            }
            // Fallback when no bot roster is present: trigger the gateway restart endpoint directly if available.
            try
            {
                await client.Session.SendAsync(HttpMethod.Post, "/api/gateway/restart", timeout: TimeSpan.FromSeconds(15), ct: cts.Token);
            }
            catch (Exception) { }
        }

        async Task WatchRestartAsync()
        {
            var deadline = DateTimeOffset.UtcNow.AddMinutes(4);
            while (DateTimeOffset.UtcNow < deadline && !cts.IsCancellationRequested && !AppShutdown.Stopping)
            {
                try { await Task.Delay(TimeSpan.FromSeconds(3), cts.Token); }
                catch (OperationCanceledException) { return; }

                try
                {
                    var list = await api.PluginsAsync("default", cts.Token);
                    var copy = list.FirstOrDefault(p => string.Equals(p.Name, pluginName, StringComparison.OrdinalIgnoreCase));
                    if (copy != null && !copy.UpdateAvailable)
                    {
                        await VerifyAsync(skipRestart: false, wasUnchanged: false, verifiedCopy: copy);
                        return;
                    }
                }
                catch (Exception) { }
            }
        }

        async Task VerifyAsync(bool skipRestart, bool wasUnchanged, PluginInfo? verifiedCopy = null)
        {
            Post(() =>
            {
                steps[1].State = StepState.Done;
                steps[1].Detail = null;
                steps[2].State = skipRestart ? StepState.Skipped : StepState.Done;
                steps[2].Detail = skipRestart ? "Not needed" : null;
                steps[3].State = StepState.Active;
                steps[3].Detail = "Checking it loaded";
                Render();
            });

            string? loadedVersion = verifiedCopy?.Version;
            try
            {
                if (loadedVersion == null)
                {
                    var list = await api.PluginsAsync("default", cts.Token);
                    loadedVersion = list.FirstOrDefault(p => string.Equals(p.Name, pluginName, StringComparison.OrdinalIgnoreCase))?.Version;
                }
                if (pluginName == AddOnChanges.PushPluginName)
                {
                    var status = await PushPolicy.ReadStatusAsync(client.Session, cts.Token);
                    if (status.Installed && !string.IsNullOrWhiteSpace(status.Version))
                        loadedVersion = status.Version;
                    AddOnReminder.Update(loadedVersion, card.To);
                }
            }
            catch (Exception) { }

            Post(() =>
            {
                if (!string.IsNullOrWhiteSpace(loadedVersion) && AddOnChanges.IsValidVersion(loadedVersion))
                    card.To = loadedVersion;
                steps[3].State = StepState.Done;
                steps[3].Detail = null;
                phase = wasUnchanged ? Phase.UpToDate : Phase.Done;
                Render();
            });
        }

        Render();
        dialog.Closed += (_, _) =>
        {
            try { cts.Cancel(); } catch (ObjectDisposedException) { }
            cts.Dispose();
        };
        _ = CheckAsync();
        await Kit.Show(root, dialog);
    }

    private const string RestartPlanMine = "You do it on Hermes’s computer. The app waits for it.";
    private static string RestartPlan(string botName) => $"Opens {botName}’s chat to do it. Replies pause a few seconds.";

    private static UIElement BuildChangingCard(ChangingCard card, bool setUp, Action rerender)
    {
        var rows = new List<UIElement>();
        var head = new Grid { ColumnSpacing = 10 };
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var left = new StackPanel { Spacing = 2 };
        left.Children.Add(Kit.Text(card.Title, 14, bold: true));
        if (!string.IsNullOrEmpty(card.Note))
            left.Children.Add(Kit.Text(card.Note, 12, secondary: true));
        head.Children.Add(left);

        if (AddOnChanges.VersionLine(card.From, card.To, setUp) is { } versions)
        {
            var vText = Kit.Text(versions, 13, secondary: true, wrap: false);
            vText.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(vText, 1);
            head.Children.Add(vText);
        }
        else if (card.Loading)
        {
            var sp = Kit.Spinner(14);
            Grid.SetColumn((FrameworkElement)sp, 1);
            head.Children.Add(sp);
        }
        rows.Add(Kit.Pad(head, 10));

        if (card.Loading && card.Lines.Count == 0)
        {
            rows.Add(Kit.Busy("Checking what’s new…"));
        }
        else if (card.Lines.Count == 0 && !string.IsNullOrWhiteSpace(card.Fallback))
        {
            rows.Add(Kit.Pad(Kit.Text(card.Fallback, 13), 10));
        }
        else
        {
            var shown = card.Expanded ? card.Lines : card.Lines.Take(PreviewLimit).ToList();
            foreach (var change in shown)
            {
                var lineGrid = new Grid { ColumnSpacing = 10 };
                lineGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto, MinWidth = 56 });
                lineGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                var ver = Kit.Text(change.Version, 12, bold: true, secondary: true, wrap: false);
                lineGrid.Children.Add(ver);
                var desc = Kit.Text(change.Line, 13);
                Grid.SetColumn(desc, 1);
                lineGrid.Children.Add(desc);
                rows.Add(Kit.Pad(lineGrid, 7));
            }

            var hidden = Math.Max(0, card.Lines.Count - PreviewLimit);
            if (hidden > 0)
            {
                var label = card.Expanded
                    ? "Show Fewer"
                    : $"Show {hidden} Earlier {(hidden == 1 ? "Update" : "Updates")}";
                rows.Add(Kit.Pad(Kit.Link(label, () => { card.Expanded = !card.Expanded; rerender(); }), 8));
            }
        }

        return Kit.Section(setUp ? "What’s Included" : "What’s Changing", rows);
    }

    private static UIElement BuildStepsCard(IReadOnlyList<StepModel> steps)
    {
        var rows = new List<UIElement>(steps.Count);
        foreach (var step in steps)
        {
            var g = new Grid { ColumnSpacing = 12 };
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(24) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

            UIElement icon = step.State switch
            {
                StepState.Done => Kit.Glyph("\uE73E", 14, Kit.Success),
                StepState.Active => Kit.Spinner(14),
                StepState.Failed => Kit.Glyph("\uE711", 14, Kit.Critical),
                StepState.Skipped => Kit.Glyph("\uE738", 13, Kit.Tertiary),
                _ => Kit.Glyph("\uEA3A", 12, Kit.Tertiary),
            };
            if (icon is FrameworkElement fe)
            {
                fe.HorizontalAlignment = HorizontalAlignment.Center;
                fe.VerticalAlignment = VerticalAlignment.Center;
            }
            g.Children.Add(icon);

            var words = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
            var muted = step.State is StepState.Waiting or StepState.Skipped;
            words.Children.Add(Kit.Text(step.Title, 14, secondary: muted));
            if (step.Detail is { Length: > 0 } detail && step.State != StepState.Done)
                words.Children.Add(Kit.Text(detail, 12, secondary: true));
            Grid.SetColumn(words, 1);
            g.Children.Add(words);

            rows.Add(Kit.Pad(g, 8));
        }
        return Kit.Section(null, rows);
    }
}
