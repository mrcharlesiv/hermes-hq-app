using System.Collections.Concurrent;
using System.Text.Json.Nodes;
using Hermes.Core.Chat;
using Hermes.Core.Net;

namespace Hermes.Core.Composer;

// The model menus' context and the switcher (HermesKit/Chat/ModelMenuModel.swift ModelMenuContext,
// ModelSwitcher.swift, ModelMutation.swift; spec 1x §3–§5).
public sealed partial class ChatComposer
{
    /// Runtime ids with a model switch in flight, app-wide.
    private static readonly ConcurrentDictionary<string, byte> PendingSwitches = new();

    public static readonly TimeSpan SwitchTimeout = TimeSpan.FromSeconds(45);
    public static readonly TimeSpan OptionTimeout = TimeSpan.FromSeconds(15);
    public static readonly TimeSpan OptionsTimeout = TimeSpan.FromSeconds(30);
    public static readonly TimeSpan NoticeFor = TimeSpan.FromSeconds(5);
    /// How long a pick made while the chat is still opening waits for it.
    public TimeSpan OpeningWait { get; set; } = TimeSpan.FromSeconds(15);

    public ModelCatalogCache.Key ModelKey => new(Client.AccountId, Session.Profile, Session.RuntimeId ?? "global");

    /// This chat's catalog as cached (null before its first read).
    public ModelOptions? Options => _models.Cached(ModelKey);
    public bool ModelsLoadFailed => Options == null && _models.LoadFailed(ModelKey);

    public ModelChoice Describe(string id, string provider) =>
        Options?.Describe(id, provider) ?? ModelOptions.DescribeWith(id, provider, null);

    public IReadOnlyList<ModelChoice> Models() => Options?.Choices ?? [];

    public ModelChoice Current()
    {
        var state = ModelState;
        var o = Options;
        var selection = ModelNames.CurrentPickerSelection((state.Model, state.Provider), o == null ? null : (o.Model, o.Provider));
        return Describe(selection.Model, selection.Provider);
    }

    public ModelCapabilities? CapabilitiesOf(ModelChoice model) => Options?.CapabilitiesOf(model.Provider, model.Id);

    /// How Fast works for the current model: the model's own tier, a `-fast` sibling id, or (neither) only while Fast is
    /// on, so it can be turned off.
    public (bool Supported, bool On, (string Base, string Sibling)? Variant) FastControl()
    {
        var model = Current();
        var fastOn = ModelState.Fast;
        if (CapabilitiesOf(model)?.Fast == true) return (true, fastOn, null);
        var ids = Options?.Row(model.Provider)?.Models ?? [];
        var b = System.Text.RegularExpressions.Regex.Replace(model.Id, "-fast$", "", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
        var sibling = b + "-fast";
        if (ids.Contains(b) && ids.Contains(sibling)) return (true, model.Id == sibling, (b, sibling));
        return (fastOn, fastOn, null);
    }

    /// The profile's own reasoning default once read; null until then.
    public string? ProfileDefaultEffort => _models.ProfileEffort(Client.AccountId, Session.Profile);

    /// The starred models: this chat's catalog rows (or the bot's newest catalog's); none before any is read.
    public IReadOnlyList<ModelChoice> FavoriteModels()
    {
        var catalog = Options?.Choices ?? _models.Sibling(ModelKey)?.Choices;
        return catalog == null ? [] : ModelSheetModel.FavoriteRows(catalog, Prefs.Favorites);
    }

    public ModelMenuInput MenuInput()
    {
        var model = Current();
        var caps = CapabilitiesOf(model);
        var catalog = Models();
        var recents = Prefs.Recents.Select(r => catalog.FirstOrDefault(c => c.Id == r.Id && c.Provider == r.Provider))
            .OfType<ModelChoice>().ToList();
        var effort = ModelState.ReasoningEffort;
        var fast = FastControl();
        return new ModelMenuInput(model, recents, FavoriteModels(),
            caps?.Reasoning == false || model.Id.Length == 0 ? [] : ModelNames.ReasoningEfforts,
            effort.Length == 0 ? ProfileDefaultEffort ?? ModelNames.DefaultReasoningEffort : effort,
            caps?.CanDisableReasoning != false, fast.Supported, fast.On, Offline, ModelState.ApprovalMode, ModelState.Yolo);
    }

    // ------------------------------------------------------------------ loading (spec 1x §3.1)

    /// The catalog's models: the cached answer while fresh (30 s) unless `refresh`/`reread`; offline, the cached one or
    /// "You’re offline.". A failed read is tried once more at once where that can help.
    public async Task<IReadOnlyList<ModelChoice>> LoadModelsAsync(bool refresh = false, bool reread = false, CancellationToken ct = default)
    {
        if (Offline)
        {
            if (Options == null) throw new GatewayException("offline", MenusText.Offline);
            return Models();
        }
        if (!refresh && !reread && _models.Fresh(ModelKey) != null) return Models();
        for (var attempt = 1; ; attempt++)
        {
            var key = ModelKey;
            try
            {
                var p = new JsonObject { ["explicit_only"] = true };
                if (refresh) p["refresh"] = true;
                var res = await Session.CallAsync("model.options", p, OptionsTimeout, SessionNeed.Optional, ct);
                var loaded = ModelOptions.Parse(res);
                _models.Store(loaded, key);
                _models.SetLoadFailed(false, key);
                StateChanged?.Invoke();
                return Models();
            }
            catch (Exception e) when (e is GatewayException or OperationCanceledException)
            {
                if (attempt < ModelLoad.Tries && !ct.IsCancellationRequested && !Offline && ModelLoad.SecondTryHelps(e)) continue;
                if (e is not OperationCanceledException) _models.SetLoadFailed(true, key);
                throw;
            }
        }
    }

    /// The ⋯ menu's background read: no UI, errors swallowed; the profile's reasoning default is read with it.
    public void WarmUp()
    {
        if (Offline) return;
        if (ProfileDefaultEffort == null) _ = LoadProfileDefaultAsync();
        if (Options == null) _ = Task.Run(async () => { try { await LoadModelsAsync(); } catch (Exception) { } });
    }

    /// `config.get {key: "reasoning", profile}` with no session id: the profile's config.yaml effort.
    public async Task<string?> LoadProfileDefaultAsync()
    {
        if (Offline) return ProfileDefaultEffort;
        try
        {
            var res = await Client.Rpc.RequestAsync("config.get", new JsonObject { ["key"] = "reasoning", ["profile"] = Session.Profile },
                TimeSpan.FromSeconds(10));
            if (ModelNames.NormalizeConfigEffort(res.Get("value")) is { } value)
            {
                _models.StoreProfileEffort(Client.AccountId, Session.Profile, value);
                return value;
            }
        }
        catch (GatewayException) { }
        return ProfileDefaultEffort;
    }

    // ------------------------------------------------------------------ switching (spec 1x §5)

    private void AssertWritable()
    {
        if (Offline) throw new GatewayException("offline", MenusText.Offline);
        if (Session.RuntimeId == null) throw new GatewayException("loading", MenusText.Loading);
    }

    /// A pick made while the chat is still opening waits for it (a notice under the title meanwhile).
    private async Task UntilWritable(IModelSwitchUi? ui)
    {
        if (Session.RuntimeId != null || Offline) { AssertWritable(); return; }
        ui?.SwitchNotice("Waiting for the chat to load…", null, true);
        var until = DateTimeOffset.UtcNow + OpeningWait;
        while (Session.RuntimeId == null && !Offline && DateTimeOffset.UtcNow < until) await Task.Delay(100);
        ui?.HideSwitchNotice();
        AssertWritable();
    }

    private static void Report(Exception e, IModelSwitchUi? ui)
    {
        if (e is OperationCanceledException) return;
        ui?.ModelChangeFailed(MenusText.Of(e));
    }

    /// A pre-deferral gateway refusing a switch while a turn runs.
    public static bool IsBusySwitch(Exception e)
    {
        var text = MenusText.Of(e);
        return text.Contains("session busy", StringComparison.OrdinalIgnoreCase) && text.Contains("switching models", StringComparison.OrdinalIgnoreCase);
    }

    /// Picks a model for the chat's next reply. False when it didn't happen (cancelled, failed, or one already in flight).
    public async Task<bool> SwitchModelAsync(ModelChoice picked, IModelSwitchUi? ui, bool restorePreset = true)
    {
        try { return await PerformSwitch(picked, ui, restorePreset); }
        catch (Exception e) when (e is GatewayException or OperationCanceledException)
        {
            Report(e, ui);
            return false;
        }
    }

    private void Paint(ModelChoice model)
    {
        SetState(s => s with { Model = model.Id, Provider = model.Provider });
        _models.Paint(ModelKey, model.Id, model.Provider);
    }

    private async Task<bool> PerformSwitch(ModelChoice picked, IModelSwitchUi? ui, bool restorePreset)
    {
        await UntilWritable(ui);
        var runtimeId = Session.RuntimeId!;
        if (PendingSwitches.ContainsKey(runtimeId)) return false;
        var before = Current();
        var preset = Prefs.Preset(picked.Provider, picked.Id);
        var caps = CapabilitiesOf(picked);
        var providerModels = Options?.Row(picked.Provider)?.Models ?? [];
        var target = restorePreset && caps?.Fast != true && preset.Fast == true && providerModels.Contains($"{picked.Id}-fast")
            ? Describe($"{picked.Id}-fast", picked.Provider) : picked;
        Paint(target);
        var value = $"{target.Id} --provider {target.Provider}" + (target.Provider.Equals("moa", StringComparison.OrdinalIgnoreCase) ? " --session" : "");
        try
        {
            var result = await SendSwitch(runtimeId, target.Id, target.Provider, value, confirmed: false, ui);
            if (result.Bool("confirm_required") == true)
            {
                Paint(before);
                var message = ModelSwitchWording.Plain(result.Str("confirm_message") ?? "");
                if (ui == null || !await ui.ConfirmModelChange(message)) return false;
                AssertWritable();
                var now = Current();
                if (now.Id != before.Id || now.Provider != before.Provider) throw new GatewayException("rpc", "The model changed. Choose it again.");
                result = await SendSwitch(Session.RuntimeId ?? runtimeId, target.Id, target.Provider, value, confirmed: true, ui);
                if (result.Bool("confirm_required") == true)
                {
                    var text = result.Str("confirm_message") ?? "";
                    throw new GatewayException("rpc", text.Length == 0 ? "The model switch still requires confirmation." : text);
                }
            }
            Paint(target);
            if (result.Bool("deferred") != true) _models.MarkStale(ModelKey);
        }
        catch (GatewayException e)
        {
            if (!IsBusySwitch(e))
            {
                Paint(before);
                throw;
            }
            Paint(target);
        }
        Prefs.Remember(before);
        Prefs.Remember(target);
        if (restorePreset)
        {
            if (caps?.Reasoning != false)
            {
                // The model's saved effort, else the profile's own default; unknown, the session's is left alone.
                var effort = preset.Effort ?? ProfileDefaultEffort ?? await LoadProfileDefaultAsync();
                if (effort != null) await PatchOption(effort, null, target, ui);
            }
            if (caps?.Fast == true) await PatchOption(null, preset.Fast ?? false, target, ui);
        }
        return true;
    }

    /// One `config.set key=model` with its notices; a gateway-hosted Hermes's session authority takes it as
    /// `session.mutate` (at once when the socket named the authority, else after the refusal).
    private async Task<JsonNode> SendSwitch(string runtimeId, string model, string provider, string value, bool confirmed, IModelSwitchUi? ui)
    {
        var trimmed = model.Trim();
        var label = trimmed.Length == 0 ? "the selected model" : ModelNames.FormatModelPillLabel(trimmed);
        PendingSwitches[runtimeId] = 0;
        _switchPending = true;
        ui?.SwitchNotice($"Switching to {label}…", null, true);
        try
        {
            JsonNode result;
            if (Client.Rpc.ReadyPayload.Bool("session_authority") == true)
                result = await ModelMutation.SendAsync(this, Session.RuntimeId ?? runtimeId, model, provider, confirmed, SwitchTimeout);
            else
            {
                try
                {
                    var p = new JsonObject { ["key"] = "model", ["value"] = value };
                    if (confirmed) p["confirm_expensive_model"] = true;
                    result = await Session.CallAsync("config.set", p, SwitchTimeout, SessionNeed.Required);
                }
                catch (GatewayException e) when (ModelMutation.IsRefusal(e))
                {
                    result = await ModelMutation.SendAsync(this, Session.RuntimeId ?? runtimeId, model, provider, confirmed, SwitchTimeout);
                }
            }
            if (result.Bool("confirm_required") == true) ui?.HideSwitchNotice();
            else if (result.Bool("deferred") == true) ui?.SwitchNotice($"{label} will be used for your next message.", NoticeFor, false);
            else ui?.SwitchNotice($"Model changed to {label}.", NoticeFor, false);
            return result;
        }
        catch (GatewayException e)
        {
            if (IsBusySwitch(e)) ui?.SwitchNotice($"{label} will be used for your next message.", NoticeFor, false);
            else ui?.HideSwitchNotice();
            throw;
        }
        finally
        {
            PendingSwitches.TryRemove(runtimeId, out _);
            _switchPending = false;
        }
    }

    /// Saves the preset, paints the value, then `config.set`; a failure restores both.
    private async Task PatchOption(string? effort, bool? fast, ModelChoice? model, IModelSwitchUi? ui)
    {
        await UntilWritable(ui);
        model ??= Current();
        var previous = ModelState;
        var oldPreset = Prefs.Preset(model.Provider, model.Id);
        Prefs.SetPreset(model.Provider, model.Id, new ModelPreset(effort, fast));
        SetState(s => s with { ReasoningEffort = effort ?? s.ReasoningEffort, Fast = fast ?? s.Fast });
        try
        {
            if (effort != null)
                await Session.CallAsync("config.set", new JsonObject { ["key"] = "reasoning", ["value"] = effort }, OptionTimeout, SessionNeed.Required);
            if (fast is { } f)
                await Session.CallAsync("config.set", new JsonObject { ["key"] = "fast", ["value"] = f ? "fast" : "normal" }, OptionTimeout, SessionNeed.Required);
        }
        catch (GatewayException)
        {
            var restored = Prefs.Preset(model.Provider, model.Id);
            if (effort != null) restored = restored with { Effort = oldPreset.Effort ?? previous.ReasoningEffort };
            if (fast != null) restored = restored with { Fast = oldPreset.Fast ?? previous.Fast };
            Prefs.ReplacePreset(model.Provider, model.Id, restored);
            SetState(s => s with
            {
                ReasoningEffort = effort != null ? previous.ReasoningEffort : s.ReasoningEffort,
                Fast = fast != null ? previous.Fast : s.Fast,
            });
            throw;
        }
    }

    /// Model › Reasoning › a level.
    public async Task<bool> SetReasoningAsync(string level, IModelSwitchUi? ui)
    {
        try { await PatchOption(level, null, null, ui); return true; }
        catch (Exception e) when (e is GatewayException or OperationCanceledException) { Report(e, ui); return false; }
    }

    /// Model › Fast.
    public async Task<bool> SetFastAsync(bool on, IModelSwitchUi? ui)
    {
        try
        {
            await UntilWritable(ui);
            var control = FastControl();
            var model = Current();
            if (!control.Supported) throw new GatewayException("rpc", "Fast is unavailable for this model.");
            if (control.Variant is { } variant)
            {
                var ok = await SwitchModelAsync(Describe(on ? variant.Sibling : variant.Base, model.Provider), ui, restorePreset: false);
                if (ok) Prefs.SetPreset(model.Provider, variant.Base, new ModelPreset(Fast: on));
                return ok;
            }
            await PatchOption(null, on, null, ui);
            return true;
        }
        catch (Exception e) when (e is GatewayException or OperationCanceledException) { Report(e, ui); return false; }
    }

    /// The bot's approval mode (`approvals.mode` in its config): shown at once; put back if the write fails.
    public async Task SetApprovalModeAsync(string mode)
    {
        if (Offline) throw new GatewayException("offline", MenusText.Offline);
        var previous = ModelState.ApprovalMode;
        SetState(s => s with { ApprovalMode = mode });
        try
        {
            var res = await Session.CallAsync(ModelSettingsFoot.SetMethod, ModelSettingsFoot.ApprovalModeSet(mode), OptionTimeout, SessionNeed.Optional);
            if (ModelSettingsFoot.KeptApprovalMode(res) is { } kept) SetState(s => s with { ApprovalMode = kept });
        }
        catch (GatewayException)
        {
            SetState(s => s with { ApprovalMode = previous });
            throw;
        }
    }

    /// This chat's approval bypass, as `/yolo` sets it.
    public async Task SetYoloAsync(bool on)
    {
        if (Offline) throw new GatewayException("offline", MenusText.Offline);
        var res = await Session.CallAsync(ModelSettingsFoot.SetMethod, ModelSettingsFoot.YoloSet(on), OptionTimeout, SessionNeed.ResumeFirst);
        SetState(s => s with { Yolo = ModelSettingsFoot.KeptYolo(res) });
    }

    /// An older Hermes leaves the bot's approval mode out of the chat's info: read it once (`config.get
    /// approvals.mode`). Quiet on failure: the pop-up then shows no word, as the Mac's does.
    public async Task LoadApprovalModeAsync(CancellationToken ct = default)
    {
        if (!ModelSettingsFoot.ShouldLoadApprovals(ModelState.ApprovalMode, Offline)) return;
        JsonNode? res;
        try { res = await Session.CallAsync(ModelSettingsFoot.GetMethod, ModelSettingsFoot.ApprovalModeGet(), OptionTimeout, SessionNeed.Optional, ct); }
        catch (Exception e) when (e is GatewayException or OperationCanceledException) { return; }
        if (ModelSettingsFoot.KeptApprovalMode(res) is { } mode && ModelState.ApprovalMode.Length == 0)
            SetState(s => s with { ApprovalMode = mode });
    }
}

/// A model pick on a gateway-hosted Hermes's session authority (HermesKit/Chat/ModelMutation.swift): the owner refuses
/// `config.set key=model` by name, so a pick is the revision-fenced `session.mutate`; its answer is put in
/// `config.set`'s shape.
public static class ModelMutation
{
    public const string Refusal = "use_session_mutation_model";
    private static readonly ConcurrentDictionary<string, string> Tokens = new();

    public static bool IsRefusal(GatewayException e) =>
        e.Message == Refusal || J.Parse(e.Body ?? "").Str("reason") == Refusal;

    private static bool IsFenceRefusal(GatewayException e)
    {
        var reason = J.Parse(e.Body ?? "").Str("reason") ?? e.Message;
        return reason is "revision_conflict" or "stale_generation";
    }

    internal static async Task<JsonNode> SendAsync(ChatComposer chat, string session, string model, string provider, bool confirmed, TimeSpan timeout)
    {
        var key = string.Join('\u001f', chat.Client.AccountId, session, provider, model);
        var payload = new JsonObject { ["model"] = model };
        if (provider.Length > 0) payload["provider"] = provider;
        if (confirmed && Tokens.TryGetValue(key, out var token)) payload["confirm"] = token;
        JsonNode snapshot;
        try
        {
            snapshot = await chat.Client.Session.GetJsonAsync($"/api/sessions/{Uri.EscapeDataString(session)}/mutation-snapshot",
                [new("profile", chat.Session.Profile)]);
        }
        catch (GatewayException e) when (e.Status is 404 or 405) { snapshot = new JsonObject(); }
        if (snapshot.Bool("exists") != true || snapshot.Int("runtime_revision") is not { } revision || snapshot.Int("runtime_generation") is not { } generation)
            throw new GatewayException("rpc", "This chat isn’t ready for a model change yet. Try again in a moment.");
        var requestId = Guid.NewGuid().ToString().ToLowerInvariant();
        for (var attempt = 0; attempt < 2; attempt++)
        {
            var p = new JsonObject
            {
                ["session_id"] = session, ["request_id"] = requestId, ["expected_revision"] = revision,
                ["expected_generation"] = generation, ["operation"] = "model", ["payload"] = payload.DeepClone(),
                ["profile"] = chat.Session.Profile,
            };
            try
            {
                var answer = await chat.Client.Rpc.RequestAsync("session.mutate", p, timeout);
                if (payload.ContainsKey("confirm")) Tokens.TryRemove(key, out _);
                return Reshaped(answer, key);
            }
            catch (GatewayException e) when (attempt == 0 && IsFenceRefusal(e))
            {
                var data = J.Parse(e.Body ?? "");
                if (data.Int("revision") is not { } next) throw;
                revision = next;
                generation = data.Int("execution_generation") ?? generation;
                requestId = Guid.NewGuid().ToString().ToLowerInvariant();
            }
            catch (GatewayException)
            {
                if (payload.ContainsKey("confirm")) Tokens.TryRemove(key, out _);
                throw;
            }
        }
        throw new GatewayException("rpc", "revision_conflict", rpcCode: 4001);
    }

    private static JsonNode Reshaped(JsonNode answer, string key)
    {
        if (answer is not JsonObject o) return answer;
        o = (JsonObject)o.DeepClone();
        switch (o.Str("status"))
        {
            case "confirmation_required":
                if (o.Str("confirm") is { } token) Tokens[key] = token;
                o["confirm_required"] = true;
                break;
            case "deferred":
                o["deferred"] = true;
                break;
        }
        o["ok"] = true;
        return o;
    }
}
