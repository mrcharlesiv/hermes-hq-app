// Bot Info › Browser (C# twin of App/Browser/BrowserChoiceController.swift `BrowserChoiceModel`):
// per-bot browser profile (its own, or a copy of one of the person's Chrome profiles, with Refresh Sign-ins),
// Show as Normal Chrome, Browser Use Cloud (3.9+), hosted Hermes Cloud (3.11+), and Let Hermes HQ Run <Bot>'s Browser (3.6.2+).

using Hermes.Core.Gateways;
using Hermes.Core.Net;

namespace Hermes.Core.Browser;

public sealed class BrowserChoiceModel
{
    public BrowserService Service { get; }
    public string BotId { get; }
    public string BotName { get; }

    public BrowserChoice? Choice { get; private set; }
    public ChromeProfiles? Profiles { get; private set; }
    public BrowserCloud? Cloud { get; private set; }
    public bool Loading { get; private set; } = true;
    public string? Working { get; private set; }
    public string? Failure { get; private set; }
    public string? LoadFailure { get; private set; }

    public event Action? Changed;
    public Action<BrowserHaptic>? OnHaptic { get; set; }

    public BrowserChoiceModel(BrowserService service, string botId, string botName)
    {
        Service = service;
        BotId = botId;
        BotName = botName;
    }

    public void DismissFailure()
    {
        if (Failure == null) return;
        Failure = null;
        Changed?.Invoke();
    }

    public async Task LoadAsync(CancellationToken ct = default)
    {
        Loading = true;
        LoadFailure = null;
        Changed?.Invoke();
        try
        {
            Choice = await Service.ChoiceAsync(BotId, ct).ConfigureAwait(false);
            if (Choice != null)
            {
                Cloud = await Service.CloudAsync(ct).ConfigureAwait(false);
                if (!Choice.Cloud && !Choice.Hosted)
                {
                    try { Profiles = await Service.ChromeProfilesAsync(ct).ConfigureAwait(false); }
                    catch (Exception) { }
                }
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception e)
        {
            Service.Note?.Invoke($"read browser choice failed ({e.GetType().Name})");
            LoadFailure = e is GatewayException ge && ge.Message.Length > 0
                ? ge.Message
                : "Couldn’t read this bot’s browser. Try again.";
        }
        finally
        {
            Loading = false;
            Changed?.Invoke();
        }
    }

    /// True when the bot is actively using its browser now (restarting closes the page, so confirm first).
    public bool NeedsWindowConfirm => Service.Activity.Rows.Any(r => r.Profile == BotId && r.InUse);

    public async Task ApplyAsync(BrowserChoiceChange change, CancellationToken ct = default)
    {
        if (Working != null) return;
        Working = change switch
        {
            BrowserChoiceChange.Copy => "Copying your Chrome profile…",
            BrowserChoiceChange.Refresh => "Copying your sign-ins again…",
            BrowserChoiceChange.Own => Choice?.Hosted == true
                ? "Switching back to Hermes Cloud’s browser…"
                : "Switching back to its own profile…",
            BrowserChoiceChange.Window => $"Restarting {BotName}’s browser…",
            BrowserChoiceChange.TakeOver => $"Setting up {BotName}’s browser…",
            BrowserChoiceChange.Cloud => "Switching to Browser Use Cloud…",
            _ => "Updating browser…",
        };
        Changed?.Invoke();
        try
        {
            Choice = await Service.SetChoiceAsync(BotId, change, ct).ConfigureAwait(false);
            Service.Note?.Invoke(Outcome(change, status: null));
            OnHaptic?.Invoke(BrowserHaptic.Success);
            if ((change is BrowserChoiceChange.TakeOver or BrowserChoiceChange.Own) && Choice?.Hosted != true)
                await SettleAsync(ct).ConfigureAwait(false);
        }
        catch (GatewayException e)
        {
            Service.Note?.Invoke(Outcome(change, status: e.Status));
            Failure = Detail(e.Body) ?? (e.Status == 0 && e.Message.Length > 0 ? e.Message : $"{HostWord.Sentence} didn’t make that change. Try again.");
            OnHaptic?.Invoke(BrowserHaptic.Warning);
        }
        catch (Exception e)
        {
            Service.Note?.Invoke(Outcome(change, status: 0));
            Failure = e.Message.Length > 0 ? e.Message : $"{HostWord.Sentence} didn’t make that change. Try again.";
            OnHaptic?.Invoke(BrowserHaptic.Warning);
        }
        finally
        {
            Working = null;
            Changed?.Invoke();
        }
    }

    private async Task SettleAsync(CancellationToken ct)
    {
        if (Profiles == null)
        {
            try { Profiles = await Service.ChromeProfilesAsync(ct).ConfigureAwait(false); }
            catch (Exception) { }
        }
        for (var i = 0; i < 10 && Choice?.Blocked == "starting" && !ct.IsCancellationRequested; i++)
        {
            try { await Task.Delay(TimeSpan.FromSeconds(3), ct).ConfigureAwait(false); }
            catch (OperationCanceledException) { return; }
            try
            {
                if (await Service.ChoiceAsync(BotId, ct).ConfigureAwait(false) is { } fresh)
                {
                    Choice = fresh;
                    Changed?.Invoke();
                }
            }
            catch (Exception) { }
        }
    }

    public async Task SaveKeyAsync(string typed, bool thenSwitch, CancellationToken ct = default)
    {
        var key = typed.Trim();
        if (key.Length == 0 || Working != null) return;
        Working = "Checking the key with Browser Use…";
        Changed?.Invoke();
        try
        {
            Cloud = await Service.SaveCloudKeyAsync(key, ct).ConfigureAwait(false);
            Service.Note?.Invoke("cloud key: saved");
            Working = null;
            Changed?.Invoke();
            if (thenSwitch) await ApplyAsync(BrowserChoiceChange.Cloud.Instance, ct).ConfigureAwait(false);
            else OnHaptic?.Invoke(BrowserHaptic.Success);
        }
        catch (Exception e)
        {
            Working = null;
            var status = e is GatewayException ge ? ge.Status : 0;
            Service.Note?.Invoke(status > 0 ? $"cloud key: refused (HTTP {status})" : "cloud key: failed");
            Failure = Detail((e as GatewayException)?.Body)
                ?? (e is GatewayException g2 && g2.Status == 0 && g2.Message.Length > 0 ? g2.Message : null)
                ?? $"{HostWord.Sentence} couldn’t check the key. Try again.";
            OnHaptic?.Invoke(BrowserHaptic.Warning);
            Changed?.Invoke();
        }
    }

    public async Task ForgetKeyAsync(CancellationToken ct = default)
    {
        if (Working != null) return;
        Working = "Removing the key…";
        Changed?.Invoke();
        try
        {
            Cloud = await Service.SaveCloudKeyAsync("", ct).ConfigureAwait(false);
            Service.Note?.Invoke("cloud key: removed");
        }
        catch (Exception e)
        {
            Service.Note?.Invoke($"remove cloud key failed ({e.GetType().Name})");
            Failure = $"{HostWord.Sentence} couldn’t remove the key. Try again.";
        }
        finally
        {
            Working = null;
            Changed?.Invoke();
        }
    }

    // ------------------------------------------------------------------ Pure wording helpers (tested 1:1 with Swift)

    /// The diagnostic line for a change: its kind and how it went (HTTP status on failure; 0 when none).
    public static string Outcome(BrowserChoiceChange change, int? status)
    {
        var kind = change switch
        {
            BrowserChoiceChange.Own => "own",
            BrowserChoiceChange.Copy => "copy",
            BrowserChoiceChange.Refresh => "refresh",
            BrowserChoiceChange.Window w => w.Normal ? "normal window" : "hidden window",
            BrowserChoiceChange.TakeOver => "take over",
            BrowserChoiceChange.Cloud => "cloud",
            _ => "change",
        };
        if (status is not { } code) return $"choice {kind}: ok";
        return code > 0 ? $"choice {kind}: failed (HTTP {code})" : $"choice {kind}: failed";
    }

    /// Why the page can't change this bot's browser, in plain words; null when it can.
    public static string? Explanation(BrowserChoice choice, string name)
    {
        if (choice.Changeable || choice.Cloud) return null;
        if (choice.Hosted && choice.Blocked == "hosted") return null;
        return choice.Blocked switch
        {
            "real_profile" => $"{name} is set to use your real Chrome profile through Hermes’s own setting, so Hermes HQ doesn’t run its browser.",
            "released" => $"{name}’s browser was turned off in its Hermes settings.",
            "external" or "fixed" => $"{name} is connected to a Chrome you started yourself, so Hermes HQ doesn’t run its browser.",
            "remote" => $"{name} uses a browser on another computer, so Hermes HQ leaves it alone.",
            "camofox" => $"{name} browses through Camofox, so Hermes HQ leaves it alone.",
            "off" => $"Hermes HQ’s browser add\u2011on is switched off for {name}, so its browser can’t be changed here.",
            "no_browser" => $"{name} doesn’t use a browser. Its browser tools are turned off in Hermes.",
            "starting" => $"Hermes HQ is still starting {name}’s browser. This takes a moment.",
            _ => $"Hermes HQ doesn’t run {name}’s browser, so its profile and window can’t be changed here.",
        };
    }

    /// Bot Info's one-word summary beside "Profile and Window".
    public static string Summary(BrowserChoice choice)
    {
        if (choice.Changeable) return choice.Copy is { } copy ? $"Copy of {copy.Name}" : "Its Own";
        return choice.Blocked switch
        {
            "cloud" => "Browser Use Cloud",
            "hosted" => "Hermes Cloud",
            "real_profile" => "Real Chrome",
            "released" or "off" => "Off",
            "no_browser" => "No Browser",
            "external" or "fixed" => "Your Chrome",
            "remote" => "Another Computer",
            "camofox" => "Camofox",
            "starting" => "Starting",
            _ => "Not Set Up",
        };
    }

    /// The take-over button's title, when the plugin offers it.
    public static string? TakeOverTitle(BrowserChoice choice, string name) =>
        choice.CanTakeOver && !choice.Changeable && !choice.Cloud ? $"Let Hermes HQ Run {name}’s Browser" : null;

    /// What taking over changes, for the confirm dialog.
    public static string TakeOverMessage(BrowserChoice choice, string name)
    {
        var change = choice.Blocked switch
        {
            "real_profile" => "its “use real Chrome profile” setting in Hermes is turned off",
            "released" => "its browser setting in Hermes is turned back on",
            _ => "it stops using the Chrome you started yourself",
        };
        return $"Hermes HQ will run a Chrome just for {name} on {HostWord.Phrase}, and {change}. Then you can give it a copy of "
            + "your Chrome profile and watch it here. You can switch back in Hermes’s settings at any time.";
    }

    /// FastAPI's `{"detail": "…"}`, the plugin's plain-words reason.
    public static string? Detail(string? body)
    {
        if (string.IsNullOrEmpty(body) || J.Parse(body) is not { } parsed) return null;
        return BrowserJson.Str(parsed, "detail") is { Length: > 0 } detail ? BrowserJson.Prefix(detail, 200) : null;
    }

    public static string Unsupported(string? reason, string? program = null) => reason switch
    {
        "no_chrome" => $"Google Chrome isn’t installed on {HostWord.Phrase}.",
        "no_access" =>
            "The computer running Hermes is blocking Hermes from reading Chrome’s profiles. Grant Full Disk Access to "
            + (program != null ? $"“{program}”" : "Hermes’s Python") + ", then quit and reopen Hermes.",
        _ => $"No Chrome profiles were found on {HostWord.Phrase}. Open Chrome there once, then come back.",
    };
}
