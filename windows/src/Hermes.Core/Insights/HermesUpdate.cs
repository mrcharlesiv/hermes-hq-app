namespace Hermes.Core.Insights;

/// Local gateway update vs Nous Hermes Cloud agent `update_image` flow (`HermesUpdate.Kind`).
public enum HermesUpdateKind { Gateway, Cloud }

/// The four steps of a Nous Hermes Cloud agent `update_image` flow (`HermesUpdateStepID.cloud`).
public enum CloudUpdateStepId { Ask, Reinstall, Answer, Version }

/// Signals fed into a `HermesUpdateKind.Cloud` run by the cloud settle loop (`CloudUpdateSignal`).
public abstract record CloudUpdateSignal
{
    /// `update_image` accepted by Nous; Nous is now reinstalling/restarting the agent.
    public sealed record Asked : CloudUpdateSignal;
    /// Progress text reported by Nous while the agent settles.
    public sealed record Settling(string Words) : CloudUpdateSignal;
    /// Nous reports the agent is ready; confirm its Hermes version.
    public sealed record Ready : CloudUpdateSignal;
    /// Update failed with reason.
    public sealed record Failed(string Reason) : CloudUpdateSignal;
}

/// One Hermes update of a gateway or a Nous Hermes Cloud agent (App/Pages/More/CommandCenter/HermesUpdate.swift,
/// `HermesUpdate`): it names what it updates ("Update Hermes on Studio" / "Update Research Bot", where it is,
/// 0.22.5 → 0.23.0, What's New) and asks first. Gateway steps tick off from the update's own log
/// (Check → Wait for Bots → Install → Restart → Confirm); cloud updates tick off Ask Nous → Nous Reinstalls →
/// Hermes Answers → Confirm Version. It ends in words that are true: "Updated to 0.23.0" only once the new version
/// is read back.
public sealed class HermesUpdate
{
    public enum PhaseKind { Checking, Asking, Working, Ended }

    public sealed record Step(HermesUpdateStepId Id, string Title)
    {
        public HermesUpdateStepState State { get; set; } = HermesUpdateStepState.Waiting;
        public string? Detail { get; set; }
        public DateTimeOffset? Started { get; set; }
        public DateTimeOffset? Finished { get; set; }
    }

    public sealed record CloudStep(CloudUpdateStepId Id, string Title)
    {
        public HermesUpdateStepState State { get; set; } = HermesUpdateStepState.Waiting;
        public string? Detail { get; set; }
        public DateTimeOffset? Started { get; set; }
        public DateTimeOffset? Finished { get; set; }
    }

    public string Key { get; }
    public HermesUpdateKind Kind { get; }
    /// "Studio", "Research Bot".
    public string Name { get; }
    /// "Gateway in use · studio.local:9119", "Nous Hermes Cloud agent".
    public string Place { get; }
    public string? From { get; set; }
    public string? To { get; private set; }
    public IReadOnlyList<HermesUpdateCommit> Commits { get; private set; } = [];
    public PhaseKind Phase { get; private set; } = PhaseKind.Checking;
    public HermesUpdateEnd? End { get; private set; }
    public List<Step> Steps { get; private set; } = [];
    public List<CloudStep> CloudSteps { get; private set; } = [];
    public string? Note { get; private set; }
    public GatewayActionRun? Action { get; private set; }
    public HermesUpdateProgress Progress { get; private set; } = new();
    public DateTimeOffset? WorkStarted { get; private set; }

    private readonly HermesUpdateApi? _api;
    private readonly Func<string, string> _botName;
    private readonly Func<Task<string?>>? _cloudRead;
    private readonly Action<HermesUpdate>? _cloudGo;
    private HermesUpdateRefusal? _refusal;
    private CancellationTokenSource? _ticker;
    private bool _abandoned;

    /// Raised after every change, on whatever thread the change came from.
    public event Action? Changed;
    /// The run ended (not after Not Now): its headline, for an announcement.
    public event Action<HermesUpdateEnd>? Ended;
    /// Set by the sheet while it is open.
    public bool SheetOpen { get; set; }
    /// A failed check or update, asked again (a fresh run).
    public Action? Again { get; set; }
    /// Runs when the sheet closes on "Updated to …".
    public Action? AfterUpdated { get; set; }
    /// Seconds between version reads after the run ended (tests shorten it).
    public TimeSpan VersionReadDelay { get; set; } = TimeSpan.FromSeconds(5);
    public TimeSpan PollInterval { get; set; } = TimeSpan.FromSeconds(2);

    public HermesUpdate(string key, string name, string place, HermesUpdateApi? api, Func<string, string>? botName = null)
    {
        Key = key; Kind = HermesUpdateKind.Gateway; Name = name; Place = place; _api = api;
        _botName = botName ?? (p => p);
    }

    private HermesUpdate(string key, string name, string place, Func<Task<string?>> readVersion, Action<HermesUpdate> startUpdate)
    {
        Key = key; Kind = HermesUpdateKind.Cloud; Name = name; Place = place;
        _botName = p => p;
        _cloudRead = readVersion;
        _cloudGo = startUpdate;
    }

    /// Creates a Nous Hermes Cloud agent `update_image` update flow (`HermesUpdate.Kind.cloud`).
    public static HermesUpdate ForCloud(string key, string name, Func<Task<string?>> readVersion,
        Action<HermesUpdate> startUpdate, string place = CloudAgentPlace) =>
        new(key, name, place, readVersion, startUpdate);

    public static string PlaceWords(bool inUse, string host) => inUse ? $"Gateway in use · {host}" : $"Saved gateway, not in use · {host}";

    public bool IsRunning => Phase is PhaseKind.Checking or PhaseKind.Working;
    /// The check before the question failed: nothing was started on the gateway.
    public bool CheckFailed => Kind == HermesUpdateKind.Gateway && Action == null && End is HermesUpdateEnd.Failed;
    /// Under way, or ended and not closed yet.
    public bool Busy => IsRunning || End != null || SheetOpen;

    private void Notify() => Changed?.Invoke();

    // ------------------------------------------------------------------ the gateway's & cloud's update

    /// The check before the question.
    public void Check()
    {
        Phase = PhaseKind.Checking;
        End = null;
        if (Kind == HermesUpdateKind.Cloud)
        {
            Steps = [];
            CloudSteps = [.. CloudFlow.Select(id => new CloudStep(id, CloudTitle(id)) { Detail = CloudPlan(id, Name) })];
            Notify();
            _ = CheckCloudAsync();
            return;
        }
        CloudSteps = [];
        Steps = [new Step(HermesUpdateStepId.Check, Title(HermesUpdateStepId.Check)) { State = HermesUpdateStepState.Active, Started = DateTimeOffset.Now }];
        Notify();
        if (_api == null) return;
        _ = CheckAsync(_api);
    }

    private async Task CheckCloudAsync()
    {
        if (_cloudRead != null)
        {
            try { From = await _cloudRead().ConfigureAwait(false); }
            catch (Exception) { From = null; }
        }
        if (Phase != PhaseKind.Checking) return;
        Phase = PhaseKind.Asking;
        Notify();
    }

    private async Task CheckAsync(HermesUpdateApi api)
    {
        HermesUpdateCheck check;
        try { check = await api.CheckAsync(force: true); }
        catch (Exception e) { Finish(new HermesUpdateEnd.Failed(Unreachable(Name, InsightsWire.Reason(e)))); return; }
        HermesUpdateCenter.Shared.Note(check, Key);
        From = check.CurrentVersion ?? await api.VersionAsync();
        To = check.SourceVersion ?? check.RollbackTo;
        Commits = check.Commits;
        if (check.CouldNotCheck) Finish(new HermesUpdateEnd.Failed(check.Message ?? "Hermes couldn’t reach its update source. Try again later."));
        else if (!check.UpdateAvailable) Finish(new HermesUpdateEnd.UpToDate(From));
        else if (!check.CanApply)
            Finish(new HermesUpdateEnd.CantUpdateHere(HermesInstallWords.Method(check.InstallMethod) ?? check.Message ?? NotInPlace, check.Command));
        else
        {
            var started = Steps.FirstOrDefault()?.Started;
            Steps = [.. Gateway.Select(id => new Step(id, Title(id)) { Detail = Plan(id) })];
            Steps[0].State = HermesUpdateStepState.Done;
            Steps[0].Started = started;
            Steps[0].Finished = DateTimeOffset.Now;
            Steps[0].Detail = null;
            if (check.RollbackTo is { } held) Note = $"This moves {Name} back to release {held}.";
            Phase = PhaseKind.Asking;
            Notify();
        }
    }

    public static readonly HermesUpdateStepId[] Gateway =
        [HermesUpdateStepId.Check, HermesUpdateStepId.Drain, HermesUpdateStepId.Install, HermesUpdateStepId.Restart, HermesUpdateStepId.Confirm];

    public static readonly CloudUpdateStepId[] CloudFlow =
        [CloudUpdateStepId.Ask, CloudUpdateStepId.Reinstall, CloudUpdateStepId.Answer, CloudUpdateStepId.Version];

    /// The sheet's Update.
    public void Confirm()
    {
        if (Phase != PhaseKind.Asking) return;
        if (Kind == HermesUpdateKind.Cloud)
        {
            Phase = PhaseKind.Working;
            WorkStarted = DateTimeOffset.Now;
            SetCloudStep(CloudUpdateStepId.Ask, HermesUpdateStepState.Active);
            Notify();
            _cloudGo?.Invoke(this);
            return;
        }
        if (_api is not { } api) return;
        Phase = PhaseKind.Working;
        WorkStarted = DateTimeOffset.Now;
        Begin(async () =>
        {
            try { return await api.StartAsync(); }
            catch (HermesUpdateRefusal r) { _refusal = r; throw; }
        });
    }

    /// What Nous reports while a `HermesUpdateKind.Cloud` update runs (`HermesUpdate.cloud(_:)`).
    public void Cloud(CloudUpdateSignal signal)
    {
        if (Phase != PhaseKind.Working || Kind != HermesUpdateKind.Cloud) return;
        switch (signal)
        {
            case CloudUpdateSignal.Asked:
                SetCloudStep(CloudUpdateStepId.Ask, HermesUpdateStepState.Done);
                SetCloudStep(CloudUpdateStepId.Reinstall, HermesUpdateStepState.Active, CloudUpdatingDetail);
                Notify();
                break;
            case CloudUpdateSignal.Settling s:
                if (CloudSteps.FirstOrDefault(st => st.Id == CloudUpdateStepId.Reinstall)?.State == HermesUpdateStepState.Active)
                {
                    SetCloudStep(CloudUpdateStepId.Reinstall, HermesUpdateStepState.Active, s.Words);
                    Notify();
                }
                break;
            case CloudUpdateSignal.Failed f:
                Finish(new HermesUpdateEnd.Failed(f.Reason));
                break;
            case CloudUpdateSignal.Ready:
                SetCloudStep(CloudUpdateStepId.Ask, HermesUpdateStepState.Done);
                SetCloudStep(CloudUpdateStepId.Reinstall, HermesUpdateStepState.Done);
                SetCloudStep(CloudUpdateStepId.Answer, HermesUpdateStepState.Active, Reading(Name));
                Notify();
                var before = From;
                _ = Task.Run(async () =>
                {
                    string? after = null;
                    for (var i = 0; i < 12; i++)
                    {
                        if (_cloudRead != null)
                        {
                            try { after = await _cloudRead().ConfigureAwait(false); }
                            catch (Exception) { after = null; }
                        }
                        if (after != null) break;
                        await Task.Delay(VersionReadDelay).ConfigureAwait(false);
                    }
                    SetCloudStep(CloudUpdateStepId.Answer, after != null ? HermesUpdateStepState.Done : HermesUpdateStepState.Skipped);
                    SetCloudStep(CloudUpdateStepId.Version, HermesUpdateStepState.Active);
                    Notify();
                    Finish(CloudEnd(before, after));
                });
                break;
        }
    }

    /// How a Nous Hermes Cloud update ended (`HermesUpdateEnd.cloud(before:after:)`).
    public static HermesUpdateEnd CloudEnd(string? before, string? after)
    {
        if (string.IsNullOrWhiteSpace(after)) return new HermesUpdateEnd.Unconfirmed();
        if (before != null && HermesUpdateEnd.VersionsMatch(before, after)) return new HermesUpdateEnd.Unchanged(after);
        if (before == null) return new HermesUpdateEnd.Unconfirmed();
        return new HermesUpdateEnd.Updated(after);
    }

    /// An update already running on the gateway: its steps from its log.
    public void Follow()
    {
        Steps = [.. Gateway.Select(id => new Step(id, Title(id)))];
        Steps[0].State = HermesUpdateStepState.Done;
        Phase = PhaseKind.Working;
        Begin(() => Task.FromResult("hermes-update"));
    }

    private void Begin(Func<Task<string>> begin)
    {
        if (_api is not { } api) return;
        var run = new GatewayActionRun((n, ct) => api.StatusAsync(n, ct))
        {
            Patience = TimeSpan.FromHours(3), // the bot wait alone can be half an hour; the steps say where it is
            Interval = PollInterval,
        };
        run.OnRead = Read;
        run.OnFinish = _ => ActionEnded();
        run.OnUntracked = ActionEnded;
        run.Changed += Notify;
        Action = run;
        Progress = new HermesUpdateProgress();
        Apply();
        Notify();
        run.Start(begin);
        _ticker?.Cancel();
        var t = _ticker = new CancellationTokenSource();
        // The wait's "up to 32 min" counts down between reads.
        _ = Task.Run(async () =>
        {
            while (!t.IsCancellationRequested)
            {
                try { await Task.Delay(TimeSpan.FromSeconds(20), t.Token); } catch (OperationCanceledException) { return; }
                if (Phase != PhaseKind.Working) return;
                Apply();
                Notify();
            }
        });
    }

    private void Read(GatewayActionStatus? answer)
    {
        if (answer != null) Progress.Read(answer); else Progress.Unanswered();
        Apply();
        Notify();
    }

    /// The steps from the progress.
    private void Apply()
    {
        if (Phase != PhaseKind.Working) return;
        foreach (var id in Gateway)
        {
            if (id == HermesUpdateStepId.Confirm) continue;
            var state = Progress.State(id);
            string? detail = id switch
            {
                HermesUpdateStepId.Drain => Progress.DrainDetail(_botName),
                HermesUpdateStepId.Install => state == HermesUpdateStepState.Active ? Installing : null,
                HermesUpdateStepId.Restart => state == HermesUpdateStepState.Active ? Restarting(Name) : null,
                _ => null,
            };
            SetStep(id, state, detail);
        }
    }

    private void ActionEnded()
    {
        _ticker?.Cancel();
        if (Phase != PhaseKind.Working || _api is not { } api) return;
        if (_refusal is { } refusal)
        {
            Finish(new HermesUpdateEnd.CantUpdateHere(HermesInstallWords.Method(refusal.Code) ?? refusal.Message, refusal.Command));
            return;
        }
        if (Action?.Phase is ActionPhase.Failed f) { Finish(new HermesUpdateEnd.Failed(f.Reason)); return; }
        var stopped = (Progress.ExitCode ?? 0) != 0 || Progress.Receipt?.Failed == true;
        if (!stopped)
        {
            foreach (var id in new[] { HermesUpdateStepId.Check, HermesUpdateStepId.Drain, HermesUpdateStepId.Install, HermesUpdateStepId.Restart })
            {
                var state = Steps.FirstOrDefault(s => s.Id == id)?.State;
                if (state is HermesUpdateStepState.Active or HermesUpdateStepState.Waiting)
                    SetStep(id, id == HermesUpdateStepId.Drain && Progress.Drain == null ? HermesUpdateStepState.Skipped : HermesUpdateStepState.Done);
            }
            SetStep(HermesUpdateStepId.Confirm, HermesUpdateStepState.Active, Reading(Name));
            Notify();
        }
        var lines = Action?.Lines ?? [];
        int? exit = Progress.ExitCode ?? (Action?.Phase is ActionPhase.Finished fin ? (fin.Ok ? 0 : 1) : null);
        var before = From;
        _ = Task.Run(async () =>
        {
            var receipt = Progress.Receipt ?? await api.ReceiptAsync();
            // The dashboard restarts last: read until the version moves, for up to a minute and a half.
            string? after = null;
            for (var attempt = 0; attempt < 18; attempt++)
            {
                if (await api.VersionAsync() is { } read)
                {
                    after = read;
                    if (before == null || !HermesUpdateEnd.VersionsMatch(before, read)) break;
                    if (HermesUpdateEnd.StopsReading(attempt, exit)) break;
                }
                await Task.Delay(VersionReadDelay);
            }
            var ending = HermesUpdateEnd.Gateway(exit, receipt, before, after, lines);
            var installed = receipt?.PostVersion ?? HermesUpdateLog.Completed(lines)?.To;
            if (ending is HermesUpdateEnd.Unchanged { Version: { } version } && installed != null && !HermesUpdateEnd.VersionsMatch(installed, version))
                Note = $"Hermes says it installed {installed}, but {Name} still reports {version}. Restarting Hermes may finish it.";
            else if (ending is HermesUpdateEnd.Updated) Note = receipt?.Owed;
            if (ending is HermesUpdateEnd.Updated && HermesUpdateCenter.Shared.CheckFor(Key) is { } check)
                HermesUpdateCenter.Shared.Note(check with { UpdateAvailable = false, Behind = 0, CurrentVersion = after }, Key);
            Finish(ending);
        });
    }

    // ------------------------------------------------------------------ steps and the end

    private void SetStep(HermesUpdateStepId id, HermesUpdateStepState state, string? detail = null)
    {
        var step = Steps.FirstOrDefault(s => s.Id == id);
        if (step == null) return;
        var was = step.State;
        if (was == state && step.Detail == detail) return;
        step.State = state;
        step.Detail = state == HermesUpdateStepState.Done ? null : detail;
        if (state == HermesUpdateStepState.Active && was != HermesUpdateStepState.Active) step.Started = DateTimeOffset.Now;
        if (state == HermesUpdateStepState.Active && Phase == PhaseKind.Working && WorkStarted == null) WorkStarted = DateTimeOffset.Now;
        if (state is HermesUpdateStepState.Done or HermesUpdateStepState.Skipped && was != state) step.Finished = DateTimeOffset.Now;
    }

    private void SetCloudStep(CloudUpdateStepId id, HermesUpdateStepState state, string? detail = null)
    {
        var step = CloudSteps.FirstOrDefault(s => s.Id == id);
        if (step == null) return;
        var was = step.State;
        if (was == state && step.Detail == detail) return;
        step.State = state;
        step.Detail = state == HermesUpdateStepState.Done ? null : detail;
        if (state == HermesUpdateStepState.Active && was != HermesUpdateStepState.Active) step.Started = DateTimeOffset.Now;
        if (state == HermesUpdateStepState.Active && Phase == PhaseKind.Working && WorkStarted == null) WorkStarted = DateTimeOffset.Now;
        if (state is HermesUpdateStepState.Done or HermesUpdateStepState.Skipped && was != state) step.Finished = DateTimeOffset.Now;
    }

    private void Finish(HermesUpdateEnd end)
    {
        _ticker?.Cancel();
        foreach (var step in Steps)
        {
            if (step.State == HermesUpdateStepState.Active)
            {
                switch (end)
                {
                    case HermesUpdateEnd.Updated or HermesUpdateEnd.Unchanged:
                        step.State = HermesUpdateStepState.Done; step.Finished = DateTimeOffset.Now; break;
                    case HermesUpdateEnd.Failed:
                        step.State = HermesUpdateStepState.Failed; step.Finished = DateTimeOffset.Now; step.Detail = null; break;
                    default:
                        step.State = HermesUpdateStepState.Waiting; break;
                }
            }
            if (step.State == HermesUpdateStepState.Waiting) step.Detail = null;
        }
        foreach (var step in CloudSteps)
        {
            if (step.State == HermesUpdateStepState.Active)
            {
                switch (end)
                {
                    case HermesUpdateEnd.Updated or HermesUpdateEnd.Unchanged:
                        step.State = HermesUpdateStepState.Done; step.Finished = DateTimeOffset.Now; step.Detail = null; break;
                    case HermesUpdateEnd.Failed:
                        step.State = HermesUpdateStepState.Failed; step.Finished = DateTimeOffset.Now; step.Detail = null; break;
                    default:
                        step.State = HermesUpdateStepState.Waiting; break;
                }
            }
            if (step.State == HermesUpdateStepState.Waiting) step.Detail = null;
        }
        Phase = PhaseKind.Ended;
        End = end;
        Notify();
        if (!_abandoned) Ended?.Invoke(end);
    }

    /// The sheet closed (Not Now, Hide, Done).
    public void SheetClosed()
    {
        SheetOpen = false;
        if (Phase == PhaseKind.Ended && HermesUpdateCenter.Shared.Run(Key) == this) HermesUpdateCenter.Shared.Forget(Key);
        if (End is HermesUpdateEnd.Updated && AfterUpdated is { } after) { AfterUpdated = null; after(); }
        // Not Now (or closed while checking): nothing started.
        if ((Phase == PhaseKind.Asking || (Phase == PhaseKind.Checking && Action == null)) && HermesUpdateCenter.Shared.Run(Key) == this)
        {
            HermesUpdateCenter.Shared.Forget(Key);
            _abandoned = true;
        }
        Notify();
    }

    /// Copy Details: what happened, never a token.
    public string Details()
    {
        var lines = new List<string> { Kind == HermesUpdateKind.Cloud ? $"Update {Name}" : $"Update Hermes on {Name}", Headline };
        if (Line is { } l) lines.Add(l);
        lines.AddRange(Action?.Lines ?? []);
        return InsightsWire.Scrubbed(string.Join("\n", lines));
    }

    public string? CommandToCopy => End is HermesUpdateEnd.CantUpdateHere { Command: { } c } ? c : null;

    // ------------------------------------------------------------------ words

    public const string CloudAgentPlace = "Nous Hermes Cloud agent";
    public const string CloudAskingLine = "Nous moves it to the newest Hermes and restarts it. This can take a few minutes. Chats, files and settings are kept.";
    public const string CloudUpdatingDetail = "Updating Hermes…";

    public static string Title(HermesUpdateStepId id) => id switch
    {
        HermesUpdateStepId.Check => "Check",
        HermesUpdateStepId.Drain => "Wait for Bots",
        HermesUpdateStepId.Install => "Install",
        HermesUpdateStepId.Restart => "Restart",
        _ => "Confirm",
    };

    public static string CloudTitle(CloudUpdateStepId id) => id switch
    {
        CloudUpdateStepId.Ask => "Ask Nous",
        CloudUpdateStepId.Reinstall => "Nous Reinstalls",
        CloudUpdateStepId.Answer => "Hermes Answers",
        _ => "Confirm Version",
    };

    /// Before the tap: what each step will do.
    public static string? Plan(HermesUpdateStepId id) => id switch
    {
        HermesUpdateStepId.Drain => "Bots finish the replies they’re working on first. This can take a while.",
        HermesUpdateStepId.Restart => "Replies pause for a minute or two.",
        _ => null,
    };

    public static string? CloudPlan(CloudUpdateStepId id, string name) =>
        id == CloudUpdateStepId.Reinstall ? $"Nous moves {name} to its newest Hermes and restarts it." : null;

    public static string CloudUnchanged(string name, string? version) =>
        $"Nous restarted {name} on {(version != null ? HermesUpdateEnd.Normalized(version) : "the same Hermes")}. Nous hasn’t released a newer Hermes yet.";

    public static string? SkippedWords(HermesUpdateStepId id) => id == HermesUpdateStepId.Drain ? "No bots were busy" : "Not needed";

    public const string Installing = "Installing the new Hermes";
    public static string Restarting(string name) => $"Waiting for {name} to come back";
    public static string Reading(string name) => $"Reading {name}’s version";
    public const string NotInPlace = "Hermes here wasn’t installed in a way it can update itself";
    public static string Unreachable(string name, string reason) => $"Couldn’t check {name} for updates. {reason}";
    public const string KeepsGoing = "You can close this. The update keeps going, and Settings shows how it’s doing.";
    public const string AskingLine = "Bots finish the replies they’re working on, then Hermes installs the update and restarts. Hermes can’t skip that wait.";

    /// Status & Maintenance's row while it runs.
    public string RowTitle => Phase == PhaseKind.Checking ? $"Checking {Name} for Updates…" : $"Updating {Name}…";

    public string? RowStatus
    {
        get
        {
            switch (Phase)
            {
                case PhaseKind.Ended: return Headline;
                case PhaseKind.Working:
                    if (Kind == HermesUpdateKind.Cloud)
                    {
                        var cs = CloudSteps.FirstOrDefault(s => s.State == HermesUpdateStepState.Active);
                        if (cs == null) return null;
                        return cs.Detail is { } cd ? $"{cs.Title}: {cd}" : cs.Title;
                    }
                    var step = Steps.FirstOrDefault(s => s.State == HermesUpdateStepState.Active);
                    if (step == null) return null;
                    return step.Detail is { } d ? $"{step.Title}: {d}" : step.Title;
                default: return null;
            }
        }
    }

    public string Headline => Phase switch
    {
        PhaseKind.Checking => $"Checking {Name}…",
        PhaseKind.Asking => Kind == HermesUpdateKind.Cloud ? $"Update {Name}" : $"Update Hermes on {Name}",
        PhaseKind.Working => Kind == HermesUpdateKind.Cloud
            ? $"Updating {Name}…"
            : Steps.FirstOrDefault(s => s.State == HermesUpdateStepState.Active)?.Id == HermesUpdateStepId.Drain
                ? "Waiting for Bots…" : $"Updating Hermes on {Name}…",
        _ => End switch
        {
            HermesUpdateEnd.Updated u => $"Updated to {HermesUpdateEnd.Normalized(u.To)}",
            HermesUpdateEnd.UpToDate => "Hermes Is Up to Date",
            HermesUpdateEnd.CantUpdateHere => $"{Name} Can’t Update Itself",
            HermesUpdateEnd.Unchanged c => c.Version is { } v ? $"Still on {HermesUpdateEnd.Normalized(v)}" : "Version Unchanged",
            HermesUpdateEnd.Unconfirmed => "Couldn’t Confirm the Version",
            _ => CheckFailed ? "Couldn’t Check for Updates" : "The Update Didn’t Finish",
        },
    };

    /// "0.22.5 → 0.23.0" under the headline.
    public string? Versions => Phase switch
    {
        PhaseKind.Checking => null,
        PhaseKind.Ended when End is HermesUpdateEnd.Updated u => HermesUpdateWords.Versions(From, u.To),
        PhaseKind.Ended when End is HermesUpdateEnd.UpToDate up => up.Version is { } v ? HermesUpdateEnd.Normalized(v) : null,
        PhaseKind.Ended when End is HermesUpdateEnd.Unchanged c => (c.Version ?? From) is { } v ? HermesUpdateEnd.Normalized(v) : null,
        _ => HermesUpdateWords.Versions(From, To),
    };

    public string? Line => Phase switch
    {
        PhaseKind.Checking => null,
        PhaseKind.Asking => Kind == HermesUpdateKind.Cloud ? CloudAskingLine : AskingLine,
        PhaseKind.Working => KeepsGoing,
        _ => End switch
        {
            HermesUpdateEnd.Updated => Note ?? (Kind == HermesUpdateKind.Cloud
                ? $"{Name} answers on its new Hermes."
                : $"{Name} is back and running the new Hermes."),
            HermesUpdateEnd.UpToDate => $"{Name} runs the newest Hermes. Nothing to do.",
            HermesUpdateEnd.CantUpdateHere c => c.Command == null
                ? $"{c.Method}, so it’s updated wherever it’s run from, not from here." : $"{c.Method}. Run this on {Name} to update it:",
            HermesUpdateEnd.Unchanged c => Kind == HermesUpdateKind.Cloud
                ? CloudUnchanged(Name, c.Version)
                : Note ?? $"The update finished, but {Name} still reports the same version.",
            HermesUpdateEnd.Unconfirmed => Kind == HermesUpdateKind.Cloud
                ? $"Nous restarted {Name}, but HQ couldn’t read its Hermes version, so it can’t say whether it changed."
                : $"The update finished, but {Name} didn’t answer with its version. Check Status & Maintenance in a minute.",
            HermesUpdateEnd.Failed f => f.Reason,
            _ => null,
        },
    };

    public bool ShowsSteps => Phase switch
    {
        PhaseKind.Checking => false,
        PhaseKind.Asking or PhaseKind.Working => Kind == HermesUpdateKind.Cloud ? CloudSteps.Count > 1 : Steps.Count > 1,
        _ => End switch
        {
            HermesUpdateEnd.UpToDate or HermesUpdateEnd.CantUpdateHere => false,
            HermesUpdateEnd.Failed => Kind == HermesUpdateKind.Cloud
                ? CloudSteps.Any(s => s.State is HermesUpdateStepState.Done or HermesUpdateStepState.Failed)
                : Steps.Any(s => s.Id != HermesUpdateStepId.Check && s.State == HermesUpdateStepState.Done) || Action != null,
            _ => Kind == HermesUpdateKind.Cloud ? CloudSteps.Count > 1 : Steps.Count > 1,
        },
    };

    public bool ShowsWhatsNew => Commits.Count > 0 && (Phase is PhaseKind.Asking or PhaseKind.Working || End is HermesUpdateEnd.Updated);

    public enum Mark { None, Asking, Good, Unsure, Terminal, Problem }

    /// The headline's symbol: none while it works.
    public Mark Symbol => Phase switch
    {
        PhaseKind.Checking or PhaseKind.Working => Mark.None,
        PhaseKind.Asking => Mark.Asking,
        _ => End switch
        {
            HermesUpdateEnd.Updated or HermesUpdateEnd.UpToDate => Mark.Good,
            HermesUpdateEnd.Unchanged or HermesUpdateEnd.Unconfirmed => Mark.Unsure,
            HermesUpdateEnd.CantUpdateHere => Mark.Terminal,
            _ => Mark.Problem,
        },
    };

    /// A step row's line: how long a finished step took, why a step was skipped, or what it does.
    public static string? StepDetail(Step step) => step.State switch
    {
        HermesUpdateStepState.Done => step.Started is { } s && step.Finished is { } f ? HermesUpdateWords.Elapsed((int)Math.Max(0, (f - s).TotalSeconds)) : null,
        HermesUpdateStepState.Skipped => SkippedWords(step.Id),
        _ => step.Detail,
    };

    public static string? CloudStepDetail(CloudStep step) => step.State switch
    {
        HermesUpdateStepState.Done => step.Started is { } s && step.Finished is { } f ? HermesUpdateWords.Elapsed((int)Math.Max(0, (f - s).TotalSeconds)) : null,
        HermesUpdateStepState.Skipped => "Not needed",
        _ => step.Detail,
    };

    public bool HasOutput => Action?.Lines.Count > 0;
}

/// Every Hermes update this app run knows of, by gateway account key (or `"cloud:<agent id>"`), and the last update check per gateway.
public sealed class HermesUpdateCenter
{
    public static HermesUpdateCenter Shared { get; } = new();
    private readonly Dictionary<string, HermesUpdate> _runs = [];
    private readonly Dictionary<string, HermesUpdateCheck> _checks = [];
    private readonly object _lock = new();

    /// A run started, ended or was forgotten, or a check came in.
    public event Action<string>? Changed;

    public HermesUpdate? Run(string key) { lock (_lock) return _runs.GetValueOrDefault(key); }
    public HermesUpdateCheck? CheckFor(string key) { lock (_lock) return _checks.GetValueOrDefault(key); }

    public void Note(HermesUpdateCheck check, string key)
    {
        lock (_lock) _checks[key] = check;
        Changed?.Invoke(key);
    }

    public void Forget(string key)
    {
        lock (_lock) _runs.Remove(key);
        Changed?.Invoke(key);
    }

    /// The sidebar row's word: "Updating…" while it runs, "Update" when the gateway has one.
    public string? RowStatus(string key)
    {
        if (Run(key) is { IsRunning: true }) return "Updating…";
        return CheckFor(key)?.UpdateAvailable == true ? "Update" : null;
    }

    /// A run under way (or ended and not yet seen) for this key comes back; otherwise a new one starts checking.
    public HermesUpdate Update(string key, Func<HermesUpdate> make)
    {
        HermesUpdate run;
        lock (_lock)
        {
            if (_runs.TryGetValue(key, out var existing) && existing.Busy) return existing;
            run = make();
            _runs[key] = run;
        }
        run.Ended += _ => Changed?.Invoke(key);
        run.Check();
        Changed?.Invoke(key);
        return run;
    }

    /// Starts or returns a Nous Hermes Cloud agent `update_image` update run (`HermesUpdateCenter.updateCloud`).
    public HermesUpdate UpdateCloud(string id, string name, Func<Task<string?>> readVersion,
        Action<HermesUpdate> startUpdate, string place = HermesUpdate.CloudAgentPlace)
    {
        var key = "cloud:" + id;
        return Update(key, () => HermesUpdate.ForCloud(key, name, readVersion, startUpdate, place));
    }

    /// An update that was already running when Status & Maintenance opened: follow it without asking.
    public HermesUpdate? Attach(string key, Func<HermesUpdate> make)
    {
        HermesUpdate run;
        lock (_lock)
        {
            if (_runs.TryGetValue(key, out var existing) && existing.IsRunning) return null;
            run = make();
            _runs[key] = run;
        }
        run.Ended += _ => Changed?.Invoke(key);
        run.Follow();
        Changed?.Invoke(key);
        return run;
    }
}
