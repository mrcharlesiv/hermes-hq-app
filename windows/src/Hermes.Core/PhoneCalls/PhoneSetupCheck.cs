namespace Hermes.Core.PhoneCalls;

public enum PhoneSetupCheckState
{
    Pass,
    Warn,
    Fail,
    Unknown,
}

public sealed record PhoneSetupCheckRow(
    string Id,
    string Title,
    PhoneSetupCheckState State,
    string Detail,
    string? Fix = null);

/// Raw samplehost read results fed into `PhoneSetupCheck.Evaluate`.
public sealed record PhoneSetupCheckReads
{
    public IReadOnlyList<samplehostNumber>? Numbers { get; init; }
    public samplehostCallControlApp? Connection { get; init; }
    public samplehostVoiceProfile? VoiceProfile { get; init; }
    public samplehostAssistantDetail? Assistant { get; init; }
    public samplehostBalance? Balance { get; init; }
    public string? KeyError { get; init; }
    public string? DestinationNumber { get; init; }
}

/// 8-point samplehost calling diagnostic checklist (`App/PhoneCalls/PhoneSetupCheck.swift` port).
public static class PhoneSetupCheck
{
    public const decimal MinRecommendedBalance = 1.00m;

    public static IReadOnlyList<PhoneSetupCheckRow> Evaluate(PhoneSetup setup, bool hasKey, PhoneSetupCheckReads reads)
    {
        var rows = new List<PhoneSetupCheckRow>();

        // 1. API Key
        if (!hasKey)
        {
            rows.Add(new("key", "samplehost API Key", PhoneSetupCheckState.Fail, "No samplehost API key saved.", "Paste your samplehost v2 API key in Phone Settings."));
            return rows;
        }
        if (!string.IsNullOrWhiteSpace(reads.KeyError))
        {
            rows.Add(new("key", "samplehost API Key", PhoneSetupCheckState.Fail, reads.KeyError!, "Check that your key is active in the samplehost portal."));
            return rows;
        }
        rows.Add(new("key", "samplehost API Key", PhoneSetupCheckState.Pass, "Connected to samplehost."));

        // 2. From Number
        if (!PhoneFormatting.IsE164(setup.FromNumber))
        {
            rows.Add(new("from", "From Number", PhoneSetupCheckState.Fail, "No outbound phone number selected.", "Choose one of your samplehost numbers."));
        }
        else if (reads.Numbers != null && !reads.Numbers.Any(n => string.Equals(n.PhoneNumber, setup.FromNumber, StringComparison.Ordinal)))
        {
            rows.Add(new("from", "From Number", PhoneSetupCheckState.Fail, $"{PhoneFormatting.FormatShown(setup.FromNumber)} wasn’t found on this account.", "Pick an active number from your samplehost account."));
        }
        else
        {
            rows.Add(new("from", "From Number", PhoneSetupCheckState.Pass, PhoneFormatting.FormatShown(setup.FromNumber)));
        }

        // 3. Voice Connection (Call Control App)
        if (string.IsNullOrWhiteSpace(setup.ConnectionId))
        {
            rows.Add(new("connection", "Voice Connection", PhoneSetupCheckState.Fail, "No Call Control application selected.", "Assign your number to a Call Control application in samplehost."));
        }
        else if (reads.Connection == null)
        {
            rows.Add(new("connection", "Voice Connection", PhoneSetupCheckState.Unknown, "Couldn’t inspect Call Control application."));
        }
        else if (!reads.Connection.Active)
        {
            rows.Add(new("connection", "Voice Connection", PhoneSetupCheckState.Fail, $"{reads.Connection.Name} is inactive.", "Enable the Call Control application in samplehost."));
        }
        else
        {
            rows.Add(new("connection", "Voice Connection", PhoneSetupCheckState.Pass, reads.Connection.Name));
        }

        // 4. Outbound Voice Profile & Allowed Country
        if (reads.Connection != null && string.IsNullOrWhiteSpace(reads.Connection.OutboundVoiceProfileId))
        {
            rows.Add(new("profile", "Outbound Voice Profile", PhoneSetupCheckState.Fail, "No outbound voice profile attached.", "Attach an Outbound Voice Profile to your Call Control app in samplehost."));
        }
        else if (reads.VoiceProfile == null)
        {
            rows.Add(new("profile", "Outbound Voice Profile", PhoneSetupCheckState.Unknown, "Couldn’t read outbound voice profile."));
        }
        else if (!reads.VoiceProfile.Enabled)
        {
            rows.Add(new("profile", "Outbound Voice Profile", PhoneSetupCheckState.Fail, $"{reads.VoiceProfile.Name} is disabled.", "Enable the Outbound Voice Profile in samplehost."));
        }
        else
        {
            var country = CountryOf(reads.DestinationNumber ?? setup.FromNumber);
            var allowed = reads.VoiceProfile.WhitelistedDestinations;
            if (country != null && allowed.Count > 0 && !allowed.Contains(country, StringComparer.OrdinalIgnoreCase))
            {
                rows.Add(new("profile", "Allowed Countries", PhoneSetupCheckState.Fail,
                    $"{country} is not whitelisted on {reads.VoiceProfile.Name}.",
                    $"Add {country} to Whitelisted Destinations in samplehost."));
            }
            else
            {
                rows.Add(new("profile", "Outbound Voice Profile", PhoneSetupCheckState.Pass,
                    country != null ? $"{reads.VoiceProfile.Name} ({country} allowed)" : reads.VoiceProfile.Name));
            }
        }

        // 5. AI Assistant Telephony
        if (string.IsNullOrWhiteSpace(setup.AssistantId))
        {
            rows.Add(new("assistant", "AI Assistant", PhoneSetupCheckState.Fail, "No AI Assistant selected.", "Pick or create a phone assistant in Phone Settings."));
        }
        else if (reads.Assistant == null)
        {
            rows.Add(new("assistant", "AI Assistant", PhoneSetupCheckState.Fail, "Selected AI Assistant wasn’t found.", "Pick or recreate an AI Assistant."));
        }
        else if (!reads.Assistant.TelephonyEnabled)
        {
            rows.Add(new("assistant", "Assistant Telephony", PhoneSetupCheckState.Fail, $"{reads.Assistant.Name} has telephony turned off.", "Enable Telephony on this assistant."));
        }
        else
        {
            rows.Add(new("assistant", "Assistant Telephony", PhoneSetupCheckState.Pass, $"{reads.Assistant.Name} ready for calls."));
        }

        // 6. Assistant Model check (GPT-Live / Realtime warning from Mac PhoneSetupCheck)
        if (reads.Assistant?.Model is { Length: > 0 } model)
        {
            var isLiveWarn = model.Contains("realtime", StringComparison.OrdinalIgnoreCase)
                || model.Contains("gpt-4o-mini-realtime", StringComparison.OrdinalIgnoreCase);
            rows.Add(new("model", "Assistant Model",
                isLiveWarn ? PhoneSetupCheckState.Warn : PhoneSetupCheckState.Pass,
                isLiveWarn ? $"{model} may skip ask_owner tool pauses reliably." : model,
                isLiveWarn ? "Consider switching to a standard tool-calling model if mid-call questions miss." : null));
        }

        // 7. Recording preference sync
        if (reads.Assistant != null)
        {
            var synced = reads.Assistant.RecordingEnabled == setup.RecordCalls;
            rows.Add(new("recording", "Call Recording Sync",
                synced ? PhoneSetupCheckState.Pass : PhoneSetupCheckState.Warn,
                synced
                    ? (setup.RecordCalls ? "Recording enabled." : "Recording off.")
                    : "Assistant recording setting differs; Hermes syncs it automatically when dialing."));
        }

        // 8. Balance check
        if (reads.Balance == null)
        {
            rows.Add(new("balance", "Account Balance", PhoneSetupCheckState.Unknown, "Couldn’t read account balance."));
        }
        else if (reads.Balance.Amount < MinRecommendedBalance)
        {
            rows.Add(new("balance", "Account Balance", PhoneSetupCheckState.Warn,
                $"Low balance: {reads.Balance.Amount:F2} {reads.Balance.Currency}.",
                "Add credit in the samplehost billing portal so calls don’t drop."));
        }
        else
        {
            rows.Add(new("balance", "Account Balance", PhoneSetupCheckState.Pass,
                $"{reads.Balance.Amount:F2} {reads.Balance.Currency} available."));
        }

        return rows;
    }

    public static async Task<IReadOnlyList<PhoneSetupCheckRow>> RunAsync(
        IsamplehostApi api,
        string? apiKey,
        PhoneSetup setup,
        string? destinationNumber = null,
        CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(apiKey))
            return Evaluate(setup, hasKey: false, new PhoneSetupCheckReads { DestinationNumber = destinationNumber });

        IReadOnlyList<samplehostNumber>? numbers = null;
        samplehostCallControlApp? app = null;
        samplehostVoiceProfile? profile = null;
        samplehostAssistantDetail? assistant = null;
        samplehostBalance? balance = null;

        try
        {
            numbers = await api.AllPhoneNumbersAsync(apiKey, ct);
        }
        catch (Exception ex)
        {
            return Evaluate(setup, hasKey: true, new PhoneSetupCheckReads
            {
                KeyError = PhoneMessages.Format(ex, apiKey),
                DestinationNumber = destinationNumber,
            });
        }

        if (!string.IsNullOrWhiteSpace(setup.ConnectionId))
        {
            try { app = await api.CallControlAppAsync(apiKey, setup.ConnectionId, ct); } catch (Exception) { }
        }
        if (!string.IsNullOrWhiteSpace(app?.OutboundVoiceProfileId))
        {
            try { profile = await api.VoiceProfileAsync(apiKey, app!.OutboundVoiceProfileId!, ct); } catch (Exception) { }
        }
        if (!string.IsNullOrWhiteSpace(setup.AssistantId))
        {
            try { assistant = await api.AssistantAsync(apiKey, setup.AssistantId, ct); } catch (Exception) { }
        }
        try { balance = await api.BalanceAsync(apiKey, ct); } catch (Exception) { }

        return Evaluate(setup, hasKey: true, new PhoneSetupCheckReads
        {
            Numbers = numbers,
            Connection = app,
            VoiceProfile = profile,
            Assistant = assistant,
            Balance = balance,
            DestinationNumber = destinationNumber,
        });
    }

    /// Maps an E.164 prefix to its ISO-3166 alpha-2 country code for samplehost whitelist checks.
    public static string? CountryOf(string? e164)
    {
        if (!PhoneFormatting.IsE164(e164)) return null;
        var s = e164!.Trim();
        if (s.StartsWith("+1", StringComparison.Ordinal)) return "US";
        if (s.StartsWith("+44", StringComparison.Ordinal)) return "GB";
        if (s.StartsWith("+61", StringComparison.Ordinal)) return "AU";
        if (s.StartsWith("+49", StringComparison.Ordinal)) return "DE";
        if (s.StartsWith("+33", StringComparison.Ordinal)) return "FR";
        if (s.StartsWith("+81", StringComparison.Ordinal)) return "JP";
        if (s.StartsWith("+34", StringComparison.Ordinal)) return "ES";
        if (s.StartsWith("+39", StringComparison.Ordinal)) return "IT";
        if (s.StartsWith("+31", StringComparison.Ordinal)) return "NL";
        if (s.StartsWith("+46", StringComparison.Ordinal)) return "SE";
        if (s.StartsWith("+41", StringComparison.Ordinal)) return "CH";
        if (s.StartsWith("+52", StringComparison.Ordinal)) return "MX";
        if (s.StartsWith("+55", StringComparison.Ordinal)) return "BR";
        if (s.StartsWith("+91", StringComparison.Ordinal)) return "IN";
        return null;
    }
}
