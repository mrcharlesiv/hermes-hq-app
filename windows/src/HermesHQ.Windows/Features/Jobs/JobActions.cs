using Hermes.Core.Jobs;
using HermesHQ.Services;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Features.Jobs;

/// A job's actions as every entry point runs them (App/Pages/Jobs/JobActions.swift, docs/spec/1x-pages.md §3.6): Run Now
/// always asks ("Run “…” Now?"), Pause / Resume don't, Delete asks "Delete Job?". Results: the "Run Started" notice,
/// "Still Running on Your Gateway", alerts with Try Again for failures, "Changes are off for this gateway." when
/// read-only. The Mac's sheets and alerts are ContentDialogs here, one at a time.
internal sealed class JobActions(JobsStore store, Func<XamlRoot?> root, Action<string> hud)
{
    private static readonly SemaphoreSlim DialogGate = new(1, 1);
    private readonly DispatcherQueue _ui = DispatcherQueue.GetForCurrentThread();

    /// After a delete succeeds (the detail closes).
    public Action<CronJob>? OnDeleted { get; set; }
    /// A job was made (the list scrolls to it).
    public Action<string?>? OnCreated { get; set; }
    /// The page's bot, for New Job ("all" or a profile).
    public Func<string>? CurrentScope { get; set; }

    public JobsStore Store => store;

    /// Shows a dialog once no other is open (WinUI allows one at a time).
    public static async Task<ContentDialogResult> ShowAsync(ContentDialog dialog, XamlRoot? xamlRoot)
    {
        if (xamlRoot == null) return ContentDialogResult.None;
        await DialogGate.WaitAsync();
        try { return await SafeDialog.ShowAsync(xamlRoot, dialog); }
        finally { DialogGate.Release(); }
    }

    private void Refused() => hud(JobsStore.ReadOnlyNotice);

    private void OnUi(Action a) => _ui.TryEnqueue(() => a());

    // MARK: Run Now

    public (string Title, string Description) RunCopy(CronJob job)
    {
        var copy = JobWords.RunNowCopy(store.Title(job), job.Deliver ?? "local", job.Origin, JobDelivery.Labels, JobWords.KnownChatNames(store.Jobs));
        return (JobWords.RunAlertTitle(copy.Title), copy.Description);
    }

    public async void RunNow(CronJob job)
    {
        try
        {
            if (store.ReadOnlyGateway) { Refused(); return; }
            var copy = RunCopy(job);
            var ask = new ContentDialog
            {
                Title = copy.Title, Content = copy.Description, PrimaryButtonText = "Run", CloseButtonText = "Cancel",
                DefaultButton = ContentDialogButton.Primary,
            };
            if (await ShowAsync(ask, root()) != ContentDialogResult.Primary) return;
            await PerformRunAsync(job);
        }
        catch (Exception ex) { AppLog.Error("jobs", ex); }
    }

    private async Task PerformRunAsync(CronJob job)
    {
        var result = await store.RunNowAsync(job);
        OnUi(() =>
        {
            switch (result.Kind)
            {
                case RunKind.Started: hud("Run Started"); break;
                case RunKind.StillRunning: hud("Still Running on Your Gateway"); break;
                case RunKind.Refused: Refused(); break;
                case RunKind.AlreadyRunning: Failure("Couldn’t Run Job", result.Reason ?? "", null); break;
                case RunKind.RestorePauseFailed:
                    Failure("Couldn’t Restore Pause", "Couldn’t restore the job’s paused state after running. Check its schedule.", null);
                    break;
                default:
                    // A failed run may have started: Try Again asks again.
                    Failure("Couldn’t Run Job", result.Reason ?? "", () => RunNow(store.Job(job.Key) ?? job));
                    break;
            }
        });
    }

    // MARK: Pause / Resume

    public async void TogglePause(CronJob job)
    {
        try
        {
            if (store.ReadOnlyGateway) { Refused(); return; }
            var pause = !JobWords.IsPaused(job);
            var result = await store.SetPausedAsync(job, pause);
            OnUi(() =>
            {
                if (result.Kind == WriteKind.Refused) Refused();
                else if (result.Kind == WriteKind.Failed)
                    Failure(pause ? "Couldn’t Pause Job" : "Couldn’t Resume Job", result.Reason ?? "", () => TogglePause(store.Job(job.Key) ?? job));
            });
        }
        catch (Exception ex) { AppLog.Error("jobs", ex); }
    }

    // MARK: Delete

    public async void Delete(CronJob job)
    {
        try
        {
            if (store.ReadOnlyGateway) { Refused(); return; }
            var ask = new ContentDialog
            {
                Title = "Delete Job?",
                Content = $"This will remove “{store.Title(job)}” permanently. It will stop firing immediately.",
                PrimaryButtonText = "Delete Job", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close,
            };
            if (await ShowAsync(ask, root()) != ContentDialogResult.Primary) return;
            var result = await store.DeleteAsync(job);
            OnUi(() =>
            {
                switch (result.Kind)
                {
                    case WriteKind.Done: OnDeleted?.Invoke(job); break;
                    case WriteKind.Refused: Refused(); break;
                    default: Failure("Couldn’t Delete Job", result.Reason ?? "", () => Delete(job)); break;
                }
            });
        }
        catch (Exception ex) { AppLog.Error("jobs", ex); }
    }

    // MARK: New Job, Edit Job

    private static List<(string Id, string Name)> EditorBots() => [.. JobsServices.Bots().Select(b => (b.Name, b.DisplayName))];

    /// New Job, for the page's bot (the first bot under All Bots), optionally starting from a blueprint.
    public void NewJob(Blueprint? blueprint = null)
    {
        if (store.ReadOnlyGateway) { Refused(); return; }
        var bots = EditorBots();
        var scope = CurrentScope?.Invoke() ?? store.Scope;
        var profile = blueprint != null ? store.ListProfile : scope == "all" ? (bots.Count > 0 ? bots[0].Id : "default") : scope;
        _ = Present(new JobEditorModel(store, null, bots, profile, blueprint));
    }

    public void Edit(CronJob job)
    {
        if (store.ReadOnlyGateway) { Refused(); return; }
        var current = store.Job(job.Key) ?? job;
        _ = Present(new JobEditorModel(store, current, EditorBots(), current.Owner));
    }

    private async Task Present(JobEditorModel model)
    {
        var outcome = await JobEditorDialog.ShowAsync(model, root());
        switch (outcome.Kind)
        {
            case EditorOutcomeKind.Created:
                hud("Job Created");
                OnCreated?.Invoke(outcome.Key);
                // Run Once Now: the first run starts at once, with Run Now's own answers.
                if (model.Form.RunNow)
                {
                    var made = (outcome.Key != null ? store.Job(outcome.Key) : null) ?? model.Created;
                    if (made != null) await PerformRunAsync(made);
                    else Failure("Couldn’t Start the First Run", "The job was made. Run it from its page with Run Now.", null);
                }
                break;
            case EditorOutcomeKind.Saved:
                hud("Job Saved");
                break;
        }
    }

    // MARK: Failure alert

    public async void Failure(string title, string reason, Action? retry)
    {
        try
        {
            var alert = new ContentDialog { Title = title, Content = reason, CloseButtonText = "OK" };
            if (retry != null) { alert.PrimaryButtonText = "Try Again"; alert.DefaultButton = ContentDialogButton.Primary; }
            if (await ShowAsync(alert, root()) == ContentDialogResult.Primary) retry?.Invoke();
        }
        catch (Exception ex) { AppLog.Error("jobs", ex); }
    }

    // MARK: Menu

    /// Run Now, Pause / Resume, Edit Job…, then Delete Job in its own section.
    public MenuFlyout Menu(CronJob job)
    {
        var busy = store.IsBusy(job);
        var menu = new MenuFlyout();
        var run = new MenuFlyoutItem { Text = "Run Now", Icon = new FontIcon { Glyph = "" }, IsEnabled = !busy };
        run.Click += (_, _) => RunNow(store.Job(job.Key) ?? job);
        var paused = JobWords.IsPaused(job);
        var toggle = new MenuFlyoutItem { Text = paused ? "Resume" : "Pause", Icon = new FontIcon { Glyph = paused ? "" : "" }, IsEnabled = !busy };
        toggle.Click += (_, _) => TogglePause(store.Job(job.Key) ?? job);
        var edit = new MenuFlyoutItem { Text = "Edit Job…", Icon = new FontIcon { Glyph = "" }, IsEnabled = !busy };
        edit.Click += (_, _) => Edit(store.Job(job.Key) ?? job);
        var delete = new MenuFlyoutItem { Text = "Delete Job", Icon = new FontIcon { Glyph = "" }, Foreground = JobsUi.Red };
        delete.Click += (_, _) => Delete(store.Job(job.Key) ?? job);
        menu.Items.Add(run);
        menu.Items.Add(toggle);
        menu.Items.Add(edit);
        menu.Items.Add(QuickActions.FavoritesPinAction.ForJob(job.Key, store.Title(job), added => hud(added ? "Added to Favorites" : "Removed from Favorites")));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(delete);
        return menu;
    }
}
