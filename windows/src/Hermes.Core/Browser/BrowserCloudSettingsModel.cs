// Settings › Browser Use Cloud (C# twin of App/Browser/BrowserCloudSettings.swift `BrowserCloudSettingsModel`):
// the person's Browser Use API key, and "Use for All Bots" (browser add-on 3.10+).

using Hermes.Core.Gateways;
using Hermes.Core.Net;

namespace Hermes.Core.Browser;

public sealed class BrowserCloudSettingsModel
{
    public BrowserService? Service { get; }
    public BrowserCloud? Cloud { get; private set; }
    public bool OffersAll { get; private set; }
    public bool Hosted { get; private set; }
    public bool AddOnMissing { get; private set; }
    public Action? SetUp { get; set; }
    public bool Loading { get; private set; } = true;
    public string? LoadFailure { get; private set; }
    public string? Working { get; private set; }
    public string? Failure { get; private set; }
    public IReadOnlyList<string> Skipped { get; private set; } = [];

    public event Action? Changed;
    public Action<BrowserHaptic>? OnHaptic { get; set; }

    public BrowserCloudSettingsModel(BrowserService? service, Action? setUp = null)
    {
        Service = service;
        SetUp = setUp;
    }

    public string OtherBrowser => Hosted ? "the browser Hermes Cloud gives it" : $"its own browser on {HostWord.Phrase}";

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
            if (Service == null) return;
            var found = await Service.CloudSettingsAsync(ct).ConfigureAwait(false);
            Cloud = found?.Cloud;
            OffersAll = found?.OffersAll ?? false;
            Hosted = found?.Hosted ?? false;
            AddOnMissing = false;
        }
        catch (Exception e) when (BrowserService.IsMissing(e))
        {
            Cloud = null;
            AddOnMissing = true;
        }
        catch (OperationCanceledException) { }
        catch (Exception e)
        {
            Service?.Note?.Invoke($"read Browser Use Cloud failed ({e.GetType().Name})");
            LoadFailure = e is GatewayException ge && ge.Message.Length > 0
                ? ge.Message
                : "Couldn’t read Browser Use Cloud. Try again.";
        }
        finally
        {
            Loading = false;
            Changed?.Invoke();
        }
    }

    public async Task SaveKeyAsync(string typed, bool thenAll, CancellationToken ct = default)
    {
        var key = typed.Trim();
        if (Service == null || key.Length == 0 || Working != null) return;
        Working = "Checking the key with Browser Use…";
        Changed?.Invoke();
        try
        {
            Cloud = await Service.SaveCloudKeyAsync(key, ct).ConfigureAwait(false);
            Service.Note?.Invoke("cloud key: saved");
            Working = null;
            Changed?.Invoke();
            if (thenAll) await ApplyAllAsync(true, ct).ConfigureAwait(false);
            else OnHaptic?.Invoke(BrowserHaptic.Success);
        }
        catch (Exception e)
        {
            Working = null;
            var status = e is GatewayException ge ? ge.Status : 0;
            Service.Note?.Invoke(status > 0 ? $"cloud key: refused (HTTP {status})" : "cloud key: failed");
            Failure = BrowserChoiceModel.Detail((e as GatewayException)?.Body)
                ?? (e is GatewayException g2 && g2.Status == 0 && g2.Message.Length > 0 ? g2.Message : null)
                ?? $"{HostWord.Sentence} couldn’t check the key. Try again.";
            OnHaptic?.Invoke(BrowserHaptic.Warning);
            Changed?.Invoke();
        }
    }

    public async Task ForgetKeyAsync(CancellationToken ct = default)
    {
        if (Service == null || Working != null) return;
        Working = "Removing the key…";
        Changed?.Invoke();
        try
        {
            if (Cloud?.All == true) await Service.SetCloudForAllAsync(false, ct).ConfigureAwait(false);
            Cloud = await Service.SaveCloudKeyAsync("", ct).ConfigureAwait(false);
            Skipped = [];
            Service.Note?.Invoke("cloud key: removed");
        }
        catch (Exception e)
        {
            Service.Note?.Invoke($"remove Browser Use key failed ({e.GetType().Name})");
            Failure = $"{HostWord.Sentence} couldn’t remove the key. Try again.";
        }
        finally
        {
            Working = null;
            Changed?.Invoke();
        }
    }

    public async Task ApplyAllAsync(bool on, CancellationToken ct = default)
    {
        if (Service == null || Working != null) return;
        Working = on
            ? "Switching every bot to Browser Use Cloud…"
            : Hosted ? "Switching every bot back to Hermes Cloud’s browser…" : "Giving every bot its own browser back…";
        Changed?.Invoke();
        try
        {
            var answer = await Service.SetCloudForAllAsync(on, ct).ConfigureAwait(false);
            Cloud = answer;
            Skipped = on ? answer.SkippedList : [];
            Service.Note?.Invoke($"cloud for all bots: {(on ? "on" : "off")}, {answer.SkippedList.Count} skipped");
            OnHaptic?.Invoke(BrowserHaptic.Success);
        }
        catch (Exception e)
        {
            var status = e is GatewayException ge ? ge.Status : 0;
            Service.Note?.Invoke(status > 0 ? $"cloud for all bots: failed (HTTP {status})" : "cloud for all bots: failed");
            Failure = BrowserChoiceModel.Detail((e as GatewayException)?.Body)
                ?? (e is GatewayException g2 && g2.Status == 0 && g2.Message.Length > 0 ? g2.Message : null)
                ?? $"{HostWord.Sentence} didn’t make that change. Try again.";
            OnHaptic?.Invoke(BrowserHaptic.Warning);
        }
        finally
        {
            Working = null;
            Changed?.Invoke();
        }
    }

    /// "otto" · "otto and ivy" · "otto, ivy and 2 more": the bots left as they were.
    public static string? SkippedLine(IReadOnlyList<string> names)
    {
        if (names.Count == 0) return null;
        var who = names.Count switch
        {
            1 => names[0],
            2 => $"{names[0]} and {names[1]}",
            _ => $"{names[0]}, {names[1]} and {names.Count - 2} more",
        };
        return $"{who} {(names.Count == 1 ? "was" : "were")} left as {(names.Count == 1 ? "it was" : "they were")}: "
            + $"{(names.Count == 1 ? "its" : "their")} browser tools or the browser add\u2011on are turned off.";
    }
}
