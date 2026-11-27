using System.Text.Json.Nodes;
using Hermes.Core.Composer;

namespace Hermes.Core.Jobs;

/// Everything the person can change in New Job / Edit Job, for "is the form as it was opened".
public sealed record JobForm
{
    public string Profile { get; set; } = "default";
    public string Name { get; set; } = "";
    public string Prompt { get; set; } = "";
    public JobFrequency Frequency { get; set; } = JobFrequency.Daily;
    public string Schedule { get; set; } = JobFrequency.Daily.PresetExpr() ?? "";
    public string Deliver { get; set; } = JobDelivery.Fallback;
    public JobModelChoice? Model { get; set; }
    public string? BlueprintKey { get; set; }
    public Dictionary<string, string> Slots { get; set; } = [];
    /// Create only: run the new job once as soon as it exists.
    public bool RunNow { get; set; }

    public JobForm Copy() => this with { Slots = new Dictionary<string, string>(Slots) };

    public bool Equals(JobForm? o) => o is not null && Profile == o.Profile && Name == o.Name && Prompt == o.Prompt
        && Frequency == o.Frequency && Schedule == o.Schedule && Deliver == o.Deliver && Model == o.Model
        && BlueprintKey == o.BlueprintKey && RunNow == o.RunNow
        && Slots.Count == o.Slots.Count && Slots.All(kv => o.Slots.TryGetValue(kv.Key, out var v) && v == kv.Value);

    public override int GetHashCode() => HashCode.Combine(Profile, Name, Prompt, Schedule);
}

public enum EditorLoad { Loading, Loaded, Failed }
public enum EditorOutcomeKind { Created, Saved, Failed }
public sealed record EditorOutcome(EditorOutcomeKind Kind, string? Key = null);

/// The gateway's clock as its jobs' next runs are written.
public abstract record HostClock
{
    public sealed record Unknown : HostClock;
    public sealed record Shared : HostClock;
    public sealed record Offset(int Minutes) : HostClock;
}

/// The New Job / Edit Job form's state (HermesKit/Pages/JobEditor.swift, docs/spec/3x-jobs.md §4, §6.5-§6.10): what
/// was typed, what the gateway offers (delivery targets, models, blueprints), whether the form is complete or changed,
/// and exactly what is sent: the create body, the blueprint values and, for an edit, only the keys that changed.
public sealed class JobEditorModel
{
    public JobsStore Store { get; }
    public CronJob? Job { get; private set; }
    /// Profile → display name, in the order the Bot row offers them.
    public IReadOnlyList<(string Id, string Name)> Bots { get; }

    public JobForm Form { get; private set; }
    public JobForm Baseline { get; private set; }

    public List<DeliveryTarget> Targets { get; private set; } = [];
    public EditorLoad TargetsState { get; private set; } = EditorLoad.Loading;
    public List<JobModelProvider> Providers { get; private set; } = [];
    public EditorLoad ModelsState { get; private set; } = EditorLoad.Loading;
    public bool Saving { get; private set; }
    /// The reason of the last failed save (shown on top of the form).
    public string? Failure { get; set; }
    /// The blueprint field the last refusal named.
    public string? FailedField { get; private set; }
    /// The gateway refused the Custom schedule as typed.
    public bool ScheduleRejected { get; private set; }
    /// The job made, as the gateway's answer named it.
    public CronJob? Created { get; private set; }
    private int _loadGeneration;

    /// Something on the form or what it offers changed (any thread).
    public event Action? Changed;
    private void Notify() => Changed?.Invoke();

    public JobEditorModel(JobsStore store, CronJob? edit, IReadOnlyList<(string Id, string Name)> bots, string profile, Blueprint? blueprint = null)
    {
        Store = store;
        Job = edit;
        Bots = bots;
        var form = new JobForm { Profile = profile };
        if (edit != null) form = FormFor(edit);
        else if (blueprint != null)
        {
            form.BlueprintKey = blueprint.Key;
            form.Slots = SeededSlots(blueprint);
            lock (store.BlueprintsByProfile)
            {
                if (!store.BlueprintsByProfile.TryGetValue(profile, out var list)) store.BlueprintsByProfile[profile] = list = [];
                if (!list.Any(b => b.Key == blueprint.Key)) list.Add(blueprint);
            }
        }
        Form = form;
        Baseline = form.Copy();
    }

    /// The form a stored job opens with.
    public static JobForm FormFor(CronJob job)
    {
        var form = new JobForm { Profile = job.Owner, Name = (job.Name ?? "").Trim(), Prompt = job.Prompt ?? "" };
        form.Schedule = JobWords.ScheduleExpr(job);
        form.Frequency = JobSchedule.Frequency(form.Schedule);
        var deliver = (job.Deliver ?? "").Trim();
        form.Deliver = deliver.Length == 0 ? JobDelivery.Fallback : deliver;
        var model = (job.Model ?? "").Trim();
        form.Model = model.Length == 0 ? null : new JobModelChoice((job.Provider ?? "").Trim(), model);
        return form;
    }

    /// A blueprint's first values, with a time the catalog left blank (or wrote badly) set to what the picker shows.
    public static Dictionary<string, string> SeededSlots(Blueprint blueprint)
    {
        var slots = JobBlueprints.InitialValues(blueprint);
        foreach (var field in blueprint.Fields.Where(f => JobBlueprints.Control(f) == BlueprintControl.Time))
        {
            if (JobBlueprints.Time(slots.GetValueOrDefault(field.Name, "")) is { } t) slots[field.Name] = JobBlueprints.TimeValue(t.Hour, t.Minute);
            else if (!field.Optional) slots[field.Name] = JobBlueprints.TimeValue(9, 0);
        }
        return slots;
    }

    // MARK: What the form is

    public bool IsEdit => Job != null;
    public bool ScriptOnly => Job != null && JobWords.JobIsScriptOnly(Job);
    public string Title => IsEdit ? "Edit Job" : "New Job";
    public string ActionTitle => IsEdit ? "Save" : "Create";
    public string Intro => IsEdit ? "Update the schedule, prompt, or delivery target. Changes apply on next run."
        : "Schedule a prompt to run automatically. Choose how often it runs.";

    /// The profile's blueprints (create only).
    public List<Blueprint> Blueprints
    {
        get
        {
            if (IsEdit) return [];
            lock (Store.BlueprintsByProfile) return [.. Store.BlueprintsByProfile.GetValueOrDefault(Form.Profile) ?? []];
        }
    }

    public Blueprint? Blueprint => Form.BlueprintKey is { } key ? Blueprints.FirstOrDefault(b => b.Key == key) : null;
    public bool ShowsBotRow => !IsEdit && Bots.Count >= 2;
    public bool ShowsModelRow => !ScriptOnly && Blueprint == null;
    public JobTimeFields Fields => JobSchedule.Fields(Form.Schedule);

    public void SetFrequency(JobFrequency next)
    {
        if (next == Form.Frequency) return;
        Form.Schedule = JobSchedule.Expression(next, Form.Schedule);
        Form.Frequency = next;
        ScheduleRejected = false;
        Notify();
    }

    /// A time or day control changed: the cron line is composed again.
    public void SetFields(JobTimeFields next)
    {
        if (!Form.Frequency.IsTimed() || next == Fields) return;
        Form.Schedule = JobSchedule.Compose(Form.Frequency, next);
        Notify();
    }

    /// Weekly's day buttons: turns a day on or off. False when nothing changed (the last day stays on).
    public bool ToggleWeekday(int day)
    {
        if (Form.Frequency != JobFrequency.Weekly) return false;
        var days = Fields.Weekdays.ToHashSet();
        if (days.Contains(day))
        {
            if (days.Count <= 1) return false;
            days.Remove(day);
        }
        else days.Add(day);
        SetFields(Fields with { Weekdays = JobTimeFields.CleanDays(days) });
        return true;
    }

    public void SetCustomSchedule(string text)
    {
        if (text == Form.Schedule) return;
        Form.Schedule = text;
        ScheduleRejected = false;
        Notify();
    }

    public void SetName(string text) { Form.Name = text; Notify(); }
    public void SetPrompt(string text) { Form.Prompt = text; Notify(); }
    public void SetRunNow(bool on) { Form.RunNow = on; Notify(); }
    public void SetModel(JobModelChoice? model) { Form.Model = model; Notify(); }

    /// The schedule as it is sent.
    public string ScheduleToSend => JobSchedule.CleanCustom(Form.Schedule);

    public Dictionary<string, string> BotNames
    {
        get
        {
            var d = new Dictionary<string, string>();
            foreach (var (id, name) in Bots) d.TryAdd(id, name);
            return d;
        }
    }

    public List<DeliveryRow> DeliveryRows =>
        JobDelivery.Rows(Targets, Form.Deliver, Job?.Origin, JobWords.KnownChatNames(Store.Jobs), BotNames);

    /// "Send Results To" as the editor draws it: places, the bots' chats, and the platforms still without a home channel.
    public (List<DeliveryRow> Places, List<DeliveryRow> Bots, List<string> NeedsHome) DeliveryGroups =>
        JobDelivery.Groups(JobDelivery.HistoryOnlyBeside(DeliveryRows));

    /// What Hermes calls a job saved without a name: its prompt's first 50 characters, on one line.
    public string? SuggestedName
    {
        get
        {
            var line = string.Join(" ", Form.Prompt.Split('\n', '\r').Where(l => l.Length > 0)).Trim();
            return line.Length == 0 ? null : (line.Length > 50 ? line[..50] : line).Trim();
        }
    }

    /// `Shared` when a written offset is the PC's own (at that moment or now), else the first job's offset; unknown
    /// when no job says.
    public HostClock HostClockFor(DateTimeOffset? now = null, TimeZoneInfo? zone = null)
    {
        var z = zone ?? TimeZoneInfo.Local;
        var n = now ?? DateTimeOffset.Now;
        var jobs = Store.Jobs;
        int? foreign = null;
        foreach (var job in jobs.Where(j => j.Owner == Form.Profile).Concat(jobs).Take(40))
        {
            if (JobWords.WrittenOffset(job.NextRunAt) is not { } offset || PagesDate.Parse(job.NextRunAt, z) is not { } at) continue;
            if (JobClock.OffsetMinutes(at, z) == offset || JobClock.OffsetMinutes(n, z) == offset) return new HostClock.Shared();
            foreign ??= offset;
        }
        return foreign is { } f ? new HostClock.Offset(f) : new HostClock.Unknown();
    }

    public int? HostOffset(DateTimeOffset? now = null, TimeZoneInfo? zone = null) =>
        HostClockFor(now, zone) is HostClock.Offset o ? o.Minutes : null;

    /// "First run: Tomorrow at 9:00 AM" (create) / "Next run: …" (edit); null when the schedule is not a line the app
    /// can read, or never fires.
    public string? NextRunWords(DateTimeOffset? now = null, TimeZoneInfo? zone = null)
    {
        var n = now ?? DateTimeOffset.Now;
        if (Blueprint != null || JobSchedule.NextRun(ScheduleToSend, HostOffset(n, zone), n, zone) is not { } next) return null;
        return (IsEdit ? "Next run: " : "First run: ") + JobWords.RelativeDateTime(next, n, zone);
    }

    /// The rows of a blueprint's deliver slot: one choice, a job's origin is not offered.
    public List<DeliveryRow> SlotDeliveryRows(string value) =>
        JobDelivery.Rows(Targets, value.Length == 0 || value == "origin" ? JobDelivery.Fallback : value, null,
            JobWords.KnownChatNames(Store.Jobs), BotNames);

    /// A click on a "Send Results To" row. False when nothing changed.
    public bool ToggleDelivery(string id)
    {
        var next = JobDelivery.Pick(Form.Deliver, id);
        if (JobDelivery.Same(next, Form.Deliver)) return false;
        Form.Deliver = next;
        Notify();
        return true;
    }

    public void SetSlot(string name, string value)
    {
        Form.Slots[name] = value;
        if (FailedField == name) FailedField = null;
        Notify();
    }

    /// "Start From": null is Write Your Own; a blueprint starts from its own values.
    public void ChooseBlueprint(string? key)
    {
        if (key == Form.BlueprintKey) return;
        Form.BlueprintKey = key;
        Form.Slots = key != null && Blueprints.FirstOrDefault(b => b.Key == key) is { } bp ? SeededSlots(bp) : [];
        Failure = null;
        FailedField = null;
        Notify();
    }

    /// The Bot row (create): the job's bot, and what that bot offers.
    public void ChooseProfile(string profile)
    {
        if (IsEdit || profile == Form.Profile) return;
        var moved = Baseline.Profile == Form.Profile && Form == Baseline;
        Form.Profile = profile;
        if (moved) Baseline = Form.Copy();
        Notify();
        _ = LoadAsync();
    }

    /// The model the job is pinned to that the gateway no longer lists (kept as a choice so a save never changes it).
    public JobModelChoice? UnlistedModel
    {
        get
        {
            if (Form.Model is not { } m) return null;
            return Providers.Any(p => p.Slug == m.Provider && p.Models.Contains(m.Model)) ? null : m;
        }
    }

    public string ModelWords => Form.Model is { } m ? ModelNames.DisplayModelName(m.Model) : "Default (global model)";

    // MARK: Complete, changed

    /// The validation sentence; null when the form can be sent.
    public string? Validate()
    {
        if (Blueprint is { } bp) return JobBlueprints.IsIncomplete(bp, Form.Slots) ? "Fill in every field." : null;
        var prompt = Form.Prompt.Trim();
        var schedule = ScheduleToSend;
        if (schedule.Length == 0 && prompt.Length == 0 && !ScriptOnly) return "Prompt and schedule are required.";
        if (schedule.Length == 0) return "Schedule is required.";
        if (!ScriptOnly && prompt.Length == 0) return "Prompt is required.";
        return null;
    }

    public bool IsComplete => Validate() == null;
    public bool IsDirty => Form != Baseline;
    public bool CanSave => !Saving && IsComplete && (!IsEdit || Updates() != null);

    // MARK: What is sent

    /// `POST /api/cron/jobs` (§3.2): no empty name, no model keys for the default model.
    public JsonObject CreateBody()
    {
        var body = new JsonObject
        {
            ["prompt"] = Form.Prompt.Trim(),
            ["schedule"] = ScheduleToSend,
            ["deliver"] = string.Join(",", JobDelivery.Parse(Form.Deliver)),
        };
        var name = Form.Name.Trim();
        if (name.Length > 0) body["name"] = name;
        if (Form.Model is { Model.Length: > 0 } m)
        {
            body["model"] = m.Model;
            body["provider"] = m.Provider;
        }
        return body;
    }

    /// The blueprint's values (§3.4): every field, an optional one left blank left out.
    public Dictionary<string, string> BlueprintValues()
    {
        var values = new Dictionary<string, string>();
        if (Blueprint is not { } bp) return values;
        foreach (var field in bp.Fields)
        {
            var value = Form.Slots.GetValueOrDefault(field.Name, "").Trim();
            if (field.Name == JobBlueprints.DeliverField && (value.Length == 0 || value == "origin")) value = JobDelivery.Fallback;
            if (value.Length == 0 && field.Optional) continue;
            values[field.Name] = value;
        }
        return values;
    }

    /// `PUT …` `updates` (§3.3, D-J1): only the keys whose value differs from the job as loaded; `model` and `provider`
    /// always together (null for both clears the pin); a script-only job never sends a prompt or a model. Null when
    /// nothing changed.
    public JsonObject? Updates()
    {
        if (!IsEdit) return null;
        var out_ = new JsonObject();
        if (Form.Name.Trim() != Baseline.Name.Trim()) out_["name"] = Form.Name.Trim();
        if (!ScriptOnly && Form.Prompt.Trim() != Baseline.Prompt.Trim()) out_["prompt"] = Form.Prompt.Trim();
        if (ScheduleToSend != JobSchedule.CleanCustom(Baseline.Schedule)) out_["schedule"] = ScheduleToSend;
        if (!JobDelivery.Same(Form.Deliver, Baseline.Deliver)) out_["deliver"] = string.Join(",", JobDelivery.Parse(Form.Deliver));
        if (!ScriptOnly && Form.Model != Baseline.Model)
        {
            out_["model"] = Form.Model?.Model;
            out_["provider"] = Form.Model is { Provider.Length: > 0 } m ? m.Provider : null;
        }
        return out_.Count == 0 ? null : out_;
    }

    // MARK: Reads

    /// What the editor reads when it opens (and again when the Bot row changes). Nothing here blocks the form.
    public async Task LoadAsync()
    {
        var generation = Interlocked.Increment(ref _loadGeneration);
        var profile = Form.Profile;
        if (Targets.Count == 0) TargetsState = EditorLoad.Loading;
        Notify();
        var targetsRead = Try(() => Store.DeliveryTargetsAsync(profile));
        var modelsRead = ScriptOnly ? Task.FromResult<List<JobModelProvider>?>([]) : Try(() => Store.ModelProvidersAsync(profile));
        if (!IsEdit)
            _ = Task.Run(async () => { await Store.LoadBlueprintsAsync(profile).ConfigureAwait(false); BlueprintsArrived(profile); });
        if (Job is { } job) _ = RefreshJobAsync(job);
        var gotTargets = await targetsRead.ConfigureAwait(false);
        var gotModels = await modelsRead.ConfigureAwait(false);
        if (generation != _loadGeneration) return;
        if (gotTargets != null) { Targets = gotTargets; TargetsState = EditorLoad.Loaded; } else { Targets = []; TargetsState = EditorLoad.Failed; }
        if (gotModels != null) { Providers = gotModels; ModelsState = EditorLoad.Loaded; } else { Providers = []; ModelsState = EditorLoad.Failed; }
        Notify();
    }

    private static async Task<T?> Try<T>(Func<Task<T>> read) where T : class
    {
        try { return await read().ConfigureAwait(false); }
        catch (Net.GatewayException) { return null; }
    }

    public async Task ReloadTargetsAsync()
    {
        var profile = Form.Profile;
        if (await Try(() => Store.DeliveryTargetsAsync(profile)).ConfigureAwait(false) is not { } got || profile != Form.Profile) return;
        Targets = got;
        TargetsState = EditorLoad.Loaded;
        Notify();
    }

    public async Task ReloadModelsAsync()
    {
        var profile = Form.Profile;
        ModelsState = EditorLoad.Loading;
        Notify();
        var got = await Try(() => Store.ModelProvidersAsync(profile)).ConfigureAwait(false);
        if (profile != Form.Profile) return;
        if (got != null) { Providers = got; ModelsState = EditorLoad.Loaded; } else ModelsState = EditorLoad.Failed;
        Notify();
    }

    private void BlueprintsArrived(string profile)
    {
        // A blueprint the new bot does not have goes back to Write Your Own.
        if (profile == Form.Profile && Form.BlueprintKey is { } key && !Blueprints.Any(b => b.Key == key))
        {
            var pristine = Form == Baseline;
            Form.BlueprintKey = null;
            Form.Slots = [];
            if (pristine) Baseline = Form.Copy();
        }
        Notify();
    }

    /// Edit opens on the list's copy, then takes the gateway's fresh one (a failed read changes nothing).
    private async Task RefreshJobAsync(CronJob job)
    {
        var (read, fresh) = await Store.ReloadAsync(job).ConfigureAwait(false);
        if (read && fresh != null) Absorb(fresh);
    }

    /// The job changed elsewhere. A pristine form takes the new values; a changed one keeps its own baseline, so only
    /// what the person changed is sent.
    public void Absorb(CronJob fresh)
    {
        if (Job is not { } job || fresh.Key != job.Key || Saving || Form != Baseline) return;
        Job = fresh;
        Form = FormFor(fresh);
        Baseline = Form.Copy();
        Notify();
    }

    // MARK: Save

    private void Fail(string reason) { Failure = reason; Notify(); }

    /// Sends the form once: a second call while one is on its way does nothing.
    public async Task<EditorOutcome> SaveAsync()
    {
        if (Saving) return new(EditorOutcomeKind.Failed);
        if (Validate() is { } invalid) { Fail(invalid); return new(EditorOutcomeKind.Failed); }
        Failure = null;
        FailedField = null;
        ScheduleRejected = false;
        Saving = true;
        Notify();
        try
        {
            JobEditResult result;
            var usedBlueprint = Blueprint;
            if (Job is { } job)
            {
                if (Updates() is not { } changes) return new(EditorOutcomeKind.Failed);
                result = await Store.UpdateAsync(job, changes).ConfigureAwait(false);
            }
            else if (usedBlueprint != null) result = await Store.InstantiateAsync(usedBlueprint.Key, BlueprintValues(), Form.Profile).ConfigureAwait(false);
            else result = await Store.CreateAsync(CreateBody(), Form.Profile).ConfigureAwait(false);
            switch (result.Kind)
            {
                case EditKind.Done:
                    Baseline = Form.Copy();
                    if (!IsEdit) Created = result.Job;
                    return IsEdit ? new(EditorOutcomeKind.Saved) : new(EditorOutcomeKind.Created, result.Job?.Key);
                case EditKind.Refused:
                    Fail(JobsStore.ReadOnlyNotice);
                    return new(EditorOutcomeKind.Failed);
                default:
                    var reason = result.Reason ?? JobErrors.NoReason;
                    if (usedBlueprint != null)
                    {
                        var cleaned = JobBlueprints.CleanFieldError(reason);
                        FailedField = JobBlueprints.FieldNamed(cleaned, usedBlueprint);
                        Fail(cleaned);
                    }
                    else
                    {
                        ScheduleRejected = result.Status == 400 && Form.Frequency == JobFrequency.Custom && reason.Contains("invalid", StringComparison.OrdinalIgnoreCase);
                        Fail(reason);
                    }
                    return new(EditorOutcomeKind.Failed);
            }
        }
        finally
        {
            Saving = false;
            Notify();
        }
    }
}
