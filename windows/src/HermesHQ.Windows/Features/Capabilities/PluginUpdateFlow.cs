using Hermes.Core;
using Hermes.Core.Capabilities;
using Hermes.Core.Net;
using Hermes.Core.Notifications;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Features.Capabilities;

/// Third-party plugin update flow with capability delta, security scan caution, and Python package consent
/// via `PluginUpdateConsent` (`POST`/`GET /api/plugins/hermes-hq-push/plugins/update`), plus bulk
/// "Check for Updates" sweeps from the Plugins `⋯` menu (port of App/Capabilities/PluginUpdates.swift).
internal static class PluginUpdateFlow
{
    /// Updates one plugin for `profile`. First-party HQ plugins (`hermes-hq-*`) route to `AddOnUpdateDialog`.
    public static async Task UpdateSingleAsync(XamlRoot? root, CapabilitiesModel model, PluginInfo plugin, string profile)
    {
        if (AddOnChanges.IsHQPlugin(plugin.Name) && CapabilitiesServices.Client is { } client)
        {
            await AddOnUpdateDialog.ShowAsync(root, client, plugin.Name, plugin.Version);
            await model.ReloadPlugins();
            return;
        }

        if (model.Api is not { } api) return;

        var accepted = false;
        var forced = false;
        IReadOnlyList<string>? acceptedLines = null;

        try
        {
            var result = await api.PluginAsync(new PluginAction.Update(plugin.Name, Accept: false), profile);

            if (result.ConsentRequired)
            {
                if (!await ConfirmCapabilitiesAsync(root, plugin.Title, result.DeltaLines)) return;
                accepted = true;
                acceptedLines = result.DeltaLines;
                result = await api.PluginAsync(new PluginAction.Update(plugin.Name, Accept: true), profile);
            }

            if (result.ScanBlocked)
            {
                if (result.ScanVerdict == "caution")
                {
                    if (!await ConfirmCautionAsync(root, plugin.Title, result.ScanFindings)) return;
                    forced = true;
                    var support = await PluginUpdateConsent.GetSupportAsync(api.Session);
                    if (support.Checked)
                    {
                        var applied = await ApplyWithConsentAsync(
                            root,
                            api.Session,
                            profile,
                            plugin,
                            new PluginUpdateConsent.Approved(
                                findings: [],
                                capabilities: acceptedLines,
                                acceptCapabilities: accepted,
                                force: true));
                        await FinishCopyResultAsync(root, model, api, profile, plugin, applied, accepted, forced, acceptedLines);
                        return;
                    }
                    result = await api.PluginAsync(new PluginAction.Update(plugin.Name, Accept: true, Force: true), profile);
                }

                if (result.ScanBlocked)
                {
                    Kit.Fail(root, PluginUpdateWords.Couldnt([plugin.Name]), PluginUpdateWords.ScanBlocked);
                    return;
                }
            }

            if (result.Unchanged)
            {
                model.PluginNotice = $"{plugin.Title} is up to date.";
                model.Notify();
            }
            else if (result.Ok)
            {
                model.PluginNotice = result.NeedsRestart
                    ? $"{plugin.Title} updated. Restart your gateway to apply."
                    : $"{plugin.Title} updated.";
                await model.ReloadPlugins();
            }
            else
            {
                Kit.Fail(root, PluginUpdateWords.Couldnt([plugin.Name]), "Hermes didn’t apply the update.");
            }
        }
        catch (GatewayException rpc) when (rpc.Code == "rpc" && PluginUpdateWords.IsForComputer(rpc.Message))
        {
            var packages = PluginUpdateWords.PackagesIn(rpc.Message);
            await HandlePythonPackagesAsync(root, model, api, profile, plugin, packages, accepted, forced, acceptedLines);
        }
        catch (Exception ex)
        {
            Kit.Fail(root, PluginUpdateWords.Couldnt([plugin.Name]), McpEntryMask.Phone.Text(CapabilitiesWords.Detail(ex)));
        }
    }

    /// Runs an on-demand serial check across all visible bots and offers to update any outdated plugins.
    public static async Task CheckAndUpdateAllAsync(XamlRoot? root, CapabilitiesModel model)
    {
        if (model.Api is not { } api || CapabilitiesServices.Client is not { } client) return;

        var bots = CapabilitiesServices.Bots();
        var profiles = bots.Count > 0 ? bots.Select(b => b.Name).ToList() : [model.Profile];
        if (!profiles.Contains(model.Profile)) profiles.Insert(0, model.Profile);

        var progressDialog = new ContentDialog
        {
            Title = "Checking for Updates…",
            Content = Kit.Busy("Checking each bot’s plugins"),
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
        };
        using var cts = new CancellationTokenSource();
        progressDialog.Closed += (_, _) => { try { cts.Cancel(); } catch (ObjectDisposedException) { } };

        var lists = new Dictionary<string, List<PluginInfo>>(StringComparer.Ordinal);
        Exception? firstError = null;

        var checkTask = Task.Run(async () =>
        {
            foreach (var profile in profiles)
            {
                if (cts.IsCancellationRequested) break;
                try
                {
                    lists[profile] = await api.PluginsAsync(profile, cts.Token);
                }
                catch (OperationCanceledException) { break; }
                catch (Exception ex)
                {
                    firstError ??= ex;
                    if (CapabilitiesApi.IsTimeout(ex)) break;
                }
            }
        });

        Task<ContentDialogResult>? showTask = null;
        if (root != null && !checkTask.IsCompleted)
        {
            var opened = false;
            var finished = false;
            progressDialog.Opened += (_, _) =>
            {
                opened = true;
                if (finished) { try { progressDialog.Hide(); } catch (Exception) { } }
            };
            showTask = Kit.Show(root, progressDialog);
            _ = checkTask.ContinueWith(_ =>
            {
                try
                {
                    progressDialog.DispatcherQueue?.TryEnqueue(() =>
                    {
                        finished = true;
                        if (opened) { try { progressDialog.Hide(); } catch (Exception) { } }
                    });
                }
                catch (Exception) { }
            });
            await showTask;
        }
        await checkTask;
        if (cts.IsCancellationRequested) return;

        await model.ReloadPlugins();

        if (lists.Count == 0 && firstError != null)
        {
            Kit.Fail(root, "Couldn’t Check for Updates", McpEntryMask.Phone.Text(CapabilitiesWords.Detail(firstError)));
            return;
        }

        var outdated = new List<(string Profile, PluginInfo Plugin)>();
        foreach (var (profile, plugins) in lists)
        {
            foreach (var p in plugins)
            {
                if (!p.UpdateAvailable) continue;
                if (!AddOnChanges.IsHQPlugin(p.Name) && PluginUpdateReminder.NeedsComputer(p.Name, p.NewVersion))
                    continue;
                outdated.Add((profile, p));
            }
        }

        if (outdated.Count == 0)
        {
            var upToDate = new ContentDialog
            {
                Title = "Plugins Are Up to Date",
                Content = Kit.Text("Every plugin on Hermes is at its newest version. Nothing to do.", 14),
                CloseButtonText = "OK",
                DefaultButton = ContentDialogButton.Close,
            };
            await Kit.Show(root, upToDate);
            return;
        }

        var distinctNames = PluginUpdateWords.Distinct(outdated.Select(o => o.Plugin.Name));
        var friendlyTitles = distinctNames.Select(AddOnChanges.DisplayTitle).ToList();
        var summaryLines = new StackPanel { Spacing = 6 };
        summaryLines.Children.Add(Kit.Text(PluginUpdateWords.Why(friendlyTitles), 13, secondary: true));
        foreach (var name in distinctNames)
        {
            var sample = outdated.First(o => o.Plugin.Name == name).Plugin;
            var target = DisplayUpdateVersion(sample);
            var versionWords = target != null ? $" ({sample.Version} → {target})" : "";
            summaryLines.Children.Add(Kit.Text($"• {AddOnChanges.DisplayTitle(name)}{versionWords}", 13));
        }

        var confirm = new ContentDialog
        {
            Title = PluginUpdateWords.Asking(friendlyTitles),
            Content = summaryLines,
            PrimaryButtonText = distinctNames.Count == 1 ? "Update" : "Update All",
            CloseButtonText = "Not Now",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await Kit.Show(root, confirm) != ContentDialogResult.Primary) return;

        // First-party HQ plugins get their unified release-note update sheet.
        var handledHq = new HashSet<string>(StringComparer.Ordinal);
        foreach (var (profile, plugin) in outdated)
        {
            if (AddOnChanges.IsHQPlugin(plugin.Name))
            {
                if (handledHq.Add(plugin.Name))
                    await AddOnUpdateDialog.ShowAsync(root, client, plugin.Name, plugin.Version);
            }
            else
            {
                await UpdateSingleAsync(root, model, plugin, profile);
            }
        }
        await model.ReloadPlugins();
    }

    /// Clean update target label for a plugin: never displays a raw Git commit SHA.
    public static string? DisplayUpdateVersion(PluginInfo plugin)
    {
        if (plugin.NewVersion is { Length: > 0 } raw && !AddOnChanges.IsCommitSha(raw))
            return raw;
        if (AddOnChanges.IsHQPlugin(plugin.Name))
        {
            var known = AddOnChanges.BestTargetVersion(
                AddOnChanges.Newest(AddOnChanges.BuiltInChanges(plugin.Name, plugin.Version, limit: 1)),
                null,
                plugin.Name);
            if (!string.IsNullOrEmpty(known) && !AddOnChanges.IsCommitSha(known)
                && (string.IsNullOrWhiteSpace(plugin.Version) || !AddOnChanges.VersionAtLeast(plugin.Version, known)))
                return known;
        }
        return null;
    }

    private static async Task FinishCopyResultAsync(
        XamlRoot? root,
        CapabilitiesModel model,
        CapabilitiesApi api,
        string profile,
        PluginInfo plugin,
        PluginUpdateCopyResult outcome,
        bool accepted,
        bool forced,
        IReadOnlyList<string>? acceptedLines)
    {
        switch (outcome)
        {
            case PluginUpdateCopyResult.Done:
                model.PluginNotice = $"{plugin.Title} updated.";
                await model.ReloadPlugins();
                break;
            case PluginUpdateCopyResult.DoneNeedsRestart:
                model.PluginNotice = $"{plugin.Title} updated. Restart your gateway to apply.";
                await model.ReloadPlugins();
                break;
            case PluginUpdateCopyResult.Computer(var packages):
                await HandlePythonPackagesAsync(root, model, api, profile, plugin, packages, accepted, forced, acceptedLines);
                break;
            case PluginUpdateCopyResult.Failed(var reason):
                Kit.Fail(root, PluginUpdateWords.Couldnt([plugin.Name]), McpEntryMask.Phone.Text(reason));
                break;
        }
    }

    private static async Task HandlePythonPackagesAsync(
        XamlRoot? root,
        CapabilitiesModel model,
        CapabilitiesApi api,
        string profile,
        PluginInfo plugin,
        string packages,
        bool accepted,
        bool forced,
        IReadOnlyList<string>? acceptedLines)
    {
        var support = await PluginUpdateConsent.GetSupportAsync(api.Session);
        if (support.Offered)
        {
            if (!await ConfirmPackagesAsync(root, plugin.Title, packages)) return;
            var applied = await ApplyWithConsentAsync(
                root,
                api.Session,
                profile,
                plugin,
                new PluginUpdateConsent.Approved(
                    packages: packages,
                    capabilities: acceptedLines,
                    acceptCapabilities: accepted,
                    force: forced));
            await FinishCopyResultAsync(root, model, api, profile, plugin, applied, accepted, forced, acceptedLines);
            return;
        }

        PluginUpdateReminder.NoteNeedsComputer(api.Session.Account.Key, plugin.Name, plugin.NewVersion);
        var bots = CapabilitiesServices.Bots();
        var mainBot = bots.FirstOrDefault(b => b.Name == "default") ?? bots.FirstOrDefault();
        var botName = mainBot?.DisplayName ?? "Hermes";
        var promptDialog = new ContentDialog
        {
            Title = PluginUpdateWords.AddsPackages([plugin.Name]),
            Content = Kit.Text(PluginUpdateWords.NeedsBot([plugin.Name], [packages], botName), 14),
            PrimaryButtonText = mainBot != null ? PluginUpdateWords.AskBot(botName, 1) : "",
            CloseButtonText = "OK",
            DefaultButton = mainBot != null ? ContentDialogButton.Primary : ContentDialogButton.Close,
        };
        if (await Kit.Show(root, promptDialog) == ContentDialogResult.Primary && mainBot != null && CapabilitiesServices.Client is { } client)
        {
            try
            {
                var chatId = await client.BotChatIdAsync(mainBot);
                var prompt = PluginUpdateWords.BotUpdatePrompt([(plugin.Name, packages, [profile])]);
                Navigator.Go(new ChatDestination(mainBot.Name, chatId, mainBot.DisplayName, prompt));
            }
            catch (Exception ex)
            {
                AppLog.Note("plugins", $"could not open bot chat for plugin update: {CapabilitiesWords.Detail(ex)}");
                Kit.Fail(root, $"Couldn’t Ask {botName}", McpEntryMask.Phone.Text(CapabilitiesWords.Detail(ex)));
            }
        }
    }

    private static async Task<PluginUpdateCopyResult> ApplyWithConsentAsync(
        XamlRoot? root,
        GatewaySession session,
        string profile,
        PluginInfo plugin,
        PluginUpdateConsent.Approved approved)
    {
        var busy = new ContentDialog
        {
            Title = $"Updating {plugin.Title}…",
            Content = Kit.Busy($"Applying update for {plugin.Title}"),
            CloseButtonText = "Cancel",
        };
        using var cts = new CancellationTokenSource();
        busy.Closed += (_, _) => { try { cts.Cancel(); } catch (ObjectDisposedException) { } };

        var applyTask = PluginUpdateConsent.ApplyAsync(session, profile, plugin.Name, approved, ct: cts.Token);
        if (root != null && !applyTask.IsCompleted)
        {
            var opened = false;
            var finished = false;
            busy.Opened += (_, _) =>
            {
                opened = true;
                if (finished) { try { busy.Hide(); } catch (Exception) { } }
            };
            var showTask = Kit.Show(root, busy);
            _ = applyTask.ContinueWith(_ =>
            {
                try
                {
                    busy.DispatcherQueue?.TryEnqueue(() =>
                    {
                        finished = true;
                        if (opened) { try { busy.Hide(); } catch (Exception) { } }
                    });
                }
                catch (Exception) { }
            });
            await showTask;
        }
        try { return await applyTask; }
        catch (OperationCanceledException) { return new PluginUpdateCopyResult.Declined(); }
    }

    private static Task<bool> ConfirmCapabilitiesAsync(XamlRoot? root, string title, IReadOnlyList<string> lines)
    {
        var shown = lines.Take(12).ToList();
        if (lines.Count > 12) shown.Add($"and {lines.Count - 12} more");
        var message = "The new version adds things the installed one does not have. Apply it only if you trust them:\n"
            + string.Join("\n", shown);
        return Kit.Confirm(root, $"{title} asks for more", message, "Apply Update");
    }

    private static Task<bool> ConfirmCautionAsync(XamlRoot? root, string title, IReadOnlyList<string> findings)
    {
        var shown = findings.Take(8).ToList();
        if (findings.Count > 8) shown.Add($"and {findings.Count - 8} more");
        var found = shown.Count == 0 ? "" : ":\n" + string.Join("\n", shown);
        var message = $"Its security scan of the new version said caution{found}\nUpdate only if you trust the plugin.";
        return Kit.Confirm(root, $"Hermes’s scan flagged {title}", message, "Update Anyway");
    }

    private static Task<bool> ConfirmPackagesAsync(XamlRoot? root, string title, string packages)
    {
        var names = PluginUpdateWords.PackageNames([packages]);
        var list = names.Count == 0
            ? "The new version adds Python packages to Hermes."
            : "The new version adds to Hermes:\n" + string.Join("\n", names);
        var message = $"{list}\nInstall {(names.Count == 1 ? "it" : "them")} only if you trust the plugin.";
        return Kit.Confirm(root, $"{title} adds Python packages", message, "Install and Update");
    }
}
