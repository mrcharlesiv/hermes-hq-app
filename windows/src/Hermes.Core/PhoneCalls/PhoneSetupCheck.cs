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
    /// True when `GET /v2/call_control_applications/{id}` returned HTTP 404 (TeXML / SIP / missing app, H6).
    public bool ConnectionNotFound { get; init; }
    public samplehostVoiceProfile? VoiceProfile { get; init; }
    public samplehostAssistantDetail? Assistant { get; init; }
    /// True when `GET /v2/ai/assistants/{id}` returned HTTP 404 (H6).
    public bool AssistantNotFound { get; init; }
    public samplehostBalance? Balance { get; init; }
    public string? KeyError { get; init; }
    public string? DestinationNumber { get; init; }
}

/// samplehost calling diagnostic checklist (`App/PhoneCalls/PhoneSetupCheck.swift` port, H6/H14 hardened).
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

        // 2. From Number (H14: checks status == "active" and connection_id == setup.ConnectionId)
        if (!PhoneFormatting.IsE164(setup.FromNumber))
        {
            rows.Add(new("from", "From Number", PhoneSetupCheckState.Fail, "No outbound phone number selected.", "Choose one of your samplehost numbers."));
        }
        else if (reads.Numbers == null)
        {
            rows.Add(new("from", "From Number", PhoneSetupCheckState.Unknown, "Couldn’t check your From number right now."));
        }
        else if (reads.Numbers.FirstOrDefault(n => string.Equals(n.PhoneNumber, setup.FromNumber, StringComparison.Ordinal)) is not { } matchedNumber)
        {
            rows.Add(new("from", "From Number", PhoneSetupCheckState.Fail, $"{PhoneFormatting.FormatShown(setup.FromNumber)} wasn’t found on this account.", "Pick an active number from your samplehost account."));
        }
        else if (matchedNumber.Status != null && !string.Equals(matchedNumber.Status, "active", StringComparison.OrdinalIgnoreCase))
        {
            rows.Add(new("from", "From Number", PhoneSetupCheckState.Fail,
                $"{PhoneFormatting.FormatShown(setup.FromNumber)} isn’t active ({matchedNumber.Status}).",
                "Wait until samplehost shows it as active, or choose another number."));
        }
        else if (!string.IsNullOrWhiteSpace(setup.ConnectionId)
            && !string.Equals(matchedNumber.ConnectionId, setup.ConnectionId, StringComparison.Ordinal))
        {
            rows.Add(new("from", "From Number", PhoneSetupCheckState.Fail,
                $"{PhoneFormatting.FormatShown(setup.FromNumber)} isn’t on the voice connection you chose.",
                "Click Fix Voice Connection in Phone Settings, or assign the number to this Voice API connection in the samplehost portal."));
        }
        else
        {
            rows.Add(new("from", "From Number", PhoneSetupCheckState.Pass,
                $"{PhoneFormatting.FormatShown(setup.FromNumber)} is active and on your voice connection."));
        }

        // 3. Voice Connection (Call Control App; H6 404 -> TeXML/SIP fail; H14 invalid/nil webhook -> fail)
        if (string.IsNullOrWhiteSpace(setup.ConnectionId))
        {
            rows.Add(new("connection", "Voice Connection", PhoneSetupCheckState.Fail, "No Voice API (Call Control) application selected.", "Click Create Voice Connection in Phone Settings."));
        }
        else if (reads.ConnectionNotFound)
        {
            rows.Add(new("connection", "Voice Connection", PhoneSetupCheckState.Fail,
                "The voice connection isn’t a Voice API (Call Control) application — TeXML and SIP connections can’t place calls here.",
                "Click Fix Voice Connection or choose a Voice API application in Phone Settings."));
        }
        else if (reads.Connection == null)
        {
            rows.Add(new("connection", "Voice Connection", PhoneSetupCheckState.Unknown, "Couldn’t inspect Call Control application."));
        }
        else if (!reads.Connection.Active)
        {
            rows.Add(new("connection", "Voice Connection", PhoneSetupCheckState.Fail, $"{reads.Connection.Name} is inactive.", "Click Fix Voice Connection or enable the Call Control application in samplehost."));
        }
        else if (!samplehostApi.HasValidWebhookUrl(reads.Connection.WebhookEventUrl))
        {
            rows.Add(new("connection", "Voice Connection", PhoneSetupCheckState.Fail,
                "The voice connection has no valid https:// webhook URL, so samplehost won’t place calls on it.",
                "Click Fix Voice Connection or set an https:// webhook URL in the samplehost portal (Voice › Programmable Voice › Voice API)."));
        }
        else
        {
            rows.Add(new("connection", "Voice Connection", PhoneSetupCheckState.Pass, $"{reads.Connection.Name} is an active Call Control application."));
        }

        // 4. Outbound Voice Profile & Allowed Country
        if (reads.Connection != null && string.IsNullOrWhiteSpace(reads.Connection.OutboundVoiceProfileId))
        {
            rows.Add(new("profile", "Outbound Voice Profile", PhoneSetupCheckState.Fail, "No outbound voice profile attached.", "Click Fix Voice Connection or attach an Outbound Voice Profile to your Call Control app in samplehost."));
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

        // 5. AI Assistant Telephony (H6 404 -> fail)
        if (string.IsNullOrWhiteSpace(setup.AssistantId))
        {
            rows.Add(new("assistant", "AI Assistant", PhoneSetupCheckState.Fail, "No AI Assistant selected.", "Pick or create a phone assistant in Phone Settings."));
        }
        else if (reads.AssistantNotFound)
        {
            rows.Add(new("assistant", "AI Assistant", PhoneSetupCheckState.Fail, "The chosen assistant isn’t on this samplehost account.", "Pick or create an AI Assistant in Phone Settings."));
        }
        else if (reads.Assistant == null)
        {
            rows.Add(new("assistant", "AI Assistant", PhoneSetupCheckState.Unknown, "Couldn’t inspect the selected AI Assistant right now."));
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
                || model.Contains("gpt-live", StringComparison.OrdinalIgnoreCase)
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

        // 8. Assistant call quality tuning (H14)
        if (reads.Assistant?.CallQualityIssues is { Count: > 0 } qualityIssues)
        {
            rows.Add(new("voice", "Assistant Call Quality", PhoneSetupCheckState.Warn,
                $"Assistant call settings can be tuned for smoother conversations ({string.Join("; ", qualityIssues)}).",
                "Click Optimize assistant for calls in Phone Settings."));
        }

        // 9. Balance check
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
        var connectionNotFound = false;
        samplehostVoiceProfile? profile = null;
        samplehostAssistantDetail? assistant = null;
        var assistantNotFound = false;
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
            try { app = await api.CallControlAppAsync(apiKey, setup.ConnectionId, ct); }
            catch (samplehostException ex) when (ex.IsNotFound) { connectionNotFound = true; }
            catch (Exception) { }
        }
        if (!string.IsNullOrWhiteSpace(app?.OutboundVoiceProfileId))
        {
            try { profile = await api.VoiceProfileAsync(apiKey, app!.OutboundVoiceProfileId!, ct); } catch (Exception) { }
        }
        if (!string.IsNullOrWhiteSpace(setup.AssistantId))
        {
            try { assistant = await api.AssistantAsync(apiKey, setup.AssistantId, ct); }
            catch (samplehostException ex) when (ex.IsNotFound) { assistantNotFound = true; }
            catch (Exception) { }
        }
        try { balance = await api.BalanceAsync(apiKey, ct); } catch (Exception) { }

        return Evaluate(setup, hasKey: true, new PhoneSetupCheckReads
        {
            Numbers = numbers,
            Connection = app,
            ConnectionNotFound = connectionNotFound,
            VoiceProfile = profile,
            Assistant = assistant,
            AssistantNotFound = assistantNotFound,
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
