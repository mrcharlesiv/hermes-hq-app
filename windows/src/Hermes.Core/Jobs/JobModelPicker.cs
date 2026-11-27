using Hermes.Core.Composer;

namespace Hermes.Core.Jobs;

/// One model row: the display name, its id as the note when another listed model reads the same, and the check.
public sealed record JobModelPickerRow(JobModelChoice Choice, string Title, string? Note, bool Checked)
{
    public string AutomationId => $"job.editor.model.{Choice.Provider}.{Choice.Model}";
}

/// One provider's section, in the gateway's provider order, with only the rows the search kept.
public sealed record JobModelPickerSection(string Slug, string Header, IReadOnlyList<JobModelPickerRow> Rows);

/// What the Model list shows: Default and an unlisted Current (empty search only), then the loading row, the failure
/// with Try Again, or the providers' sections.
public sealed record JobModelPickerList(
    bool ShowsDefault, bool DefaultChecked, JobModelPickerRow? Current, EditorLoad State, IReadOnlyList<JobModelPickerSection> Sections);

/// [WIN-JOB-MODEL-LIST] The job editor's pushed Model list (App/Pages/Jobs/JobEditorSheet.swift JobModelPickerView and
/// JobModelPickerViewController at 93f984bb1). Search Models shows only when the bot lists more than 20 models; hidden,
/// the search is empty. The words are trimmed and lowercased and match a model id, its display name, or its provider's
/// name. A display name two listed models share carries the id as a note. Default (global model) and a pinned model the
/// gateway no longer lists (Current) lead an empty search. Choosing writes the same editor's form; Back writes nothing.
public static class JobModelPicker
{
    public const string Title = "Model";
    public const string SearchPlaceholder = "Search Models";
    /// More than this many models (all providers together) and the list offers a search.
    public const int SearchThreshold = 20;
    public const string DefaultTitle = "Default (global model)";
    public const string DefaultNote = "Uses whatever model this bot is set to.";
    public const string CurrentHeader = "Current";
    public const string LoadFailed = "Couldn’t load the models.";
    public const string TryAgain = "Try Again";

    public static string Words(string? query) => (query ?? "").Trim().ToLowerInvariant();

    public static int ModelCount(IReadOnlyList<JobModelProvider> providers) => providers.Sum(p => p.Models.Count);

    public static bool ShowsSearch(IReadOnlyList<JobModelProvider> providers) => ModelCount(providers) > SearchThreshold;

    /// The section header: the catalog's provider name without its build notes (Swift's `ModelNames.plainProviderName`;
    /// Windows has no owner's provider names to prefer).
    public static string Header(JobModelProvider provider) => ModelNames.PlainProviderName(provider.Name);

    public static JobModelPickerList List(IReadOnlyList<JobModelProvider> providers, EditorLoad state, JobModelChoice? selected,
        JobModelChoice? unlisted, string? query)
    {
        // The search box exists only above the threshold; without it the words are empty (Swift clears `query.text`).
        var words = ShowsSearch(providers) ? Words(query) : "";
        var repeated = providers.SelectMany(p => p.Models.Select(ModelNames.DisplayModelName))
            .GroupBy(n => n).Where(g => g.Count() > 1).Select(g => g.Key).ToHashSet();
        JobModelPickerRow? current = null;
        if (words.Length == 0 && unlisted is { } pinned)
            current = new(pinned, ModelNames.DisplayModelName(pinned.Model), pinned.Model, true);
        var sections = new List<JobModelPickerSection>();
        if (state == EditorLoad.Loaded)
        {
            foreach (var provider in providers)
            {
                var rows = new List<JobModelPickerRow>();
                foreach (var id in provider.Models)
                {
                    var name = ModelNames.DisplayModelName(id);
                    if (words.Length > 0 && !id.ToLowerInvariant().Contains(words) && !name.ToLowerInvariant().Contains(words)
                        && !provider.Name.ToLowerInvariant().Contains(words)) continue;
                    var choice = new JobModelChoice(provider.Slug, id);
                    rows.Add(new(choice, name, repeated.Contains(name) ? id : null, selected == choice));
                }
                if (rows.Count > 0) sections.Add(new(provider.Slug, Header(provider), rows));
            }
        }
        return new(words.Length == 0, selected == null, current, state, sections);
    }

    /// A list opened from the editor's Model row, or null when the form has no Model row or a save is under way.
    public static JobModelPickerSession? Open(JobEditorModel model) =>
        model.ShowsModelRow && !model.Saving ? new JobModelPickerSession(model) : null;
}

/// One opening of the Model list: a fresh empty search; one choice or Back ends it, and a later click does nothing.
public sealed class JobModelPickerSession
{
    private readonly JobEditorModel _model;

    internal JobModelPickerSession(JobEditorModel model) => _model = model;

    public string Query { get; set; } = "";
    public bool Closed { get; private set; }

    /// Whether Search Models shows now (a reload can cross the threshold while the list is open).
    public bool ShowsSearch => JobModelPicker.ShowsSearch(_model.Providers);

    /// The rows for the current search, against what the editor holds now (a late load or a retry shows).
    public JobModelPickerList List =>
        JobModelPicker.List(_model.Providers, _model.ModelsState, _model.Form.Model, _model.UnlistedModel, Query);

    /// Writes the choice (null is Default) to the same editor's form and closes the list; the checked row closes it
    /// without a change. False (nothing written) once closed.
    public bool Choose(JobModelChoice? choice)
    {
        if (Closed) return false;
        Closed = true;
        if (_model.Form.Model != choice) _model.SetModel(choice);
        return true;
    }

    /// Try Again after a failed read: the same reload the Mac's button runs; nothing once closed.
    public Task RetryAsync() => Closed ? Task.CompletedTask : _model.ReloadModelsAsync();

    /// Back or Escape: closes the list without touching the form.
    public void Back() => Closed = true;
}
