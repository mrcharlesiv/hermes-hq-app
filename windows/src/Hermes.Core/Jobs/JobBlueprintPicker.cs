namespace Hermes.Core.Jobs;

/// One row of New Job's Blueprints list: Write Your Own (Key null) or a blueprint, with its description as the note.
public sealed record JobBlueprintPickerRow(string? Key, string Title, string Note, bool Checked)
{
    public string AutomationId => "job.editor.start." + (Key ?? "custom");
}

/// What the list shows for a search: the rows in the catalog's order, and the no-results title when a search found none.
public sealed record JobBlueprintPickerList(bool ShowsWriteYourOwn, IReadOnlyList<JobBlueprintPickerRow> Rows, string? NoResultsTitle);

/// [WIN-JOB-BLUEPRINT-PICKER] New Job's "See All" (App/Pages/Jobs/JobEditorSheet.swift JobBlueprintPickerView and
/// JobEditorView.swift's Start From header at 93f984bb1): create only, a searchable list of the bot's blueprints. The
/// words are trimmed and lowercased (Swift's `pgTrim.lowercased()`) and match a title or description
/// (`JobBlueprints.Matches`); Write Your Own leads only an empty search; a search that finds nothing says so
/// (`ContentUnavailableView.search`). Choosing writes the editor's form through `ChooseBlueprint`; Back writes nothing.
public static class JobBlueprintPicker
{
    public const string SeeAll = "See All";
    public const string Title = "Blueprints";
    public const string SearchPlaceholder = "Search Blueprints";
    public const string WriteYourOwn = "Write Your Own";
    public const string NoResultsNote = "Check the spelling or try a new search.";

    /// The search's words as the Mac matches them.
    public static string Words(string? query) => (query ?? "").Trim().ToLowerInvariant();

    /// See All shows on Start From, which is drawn only when creating and the bot has blueprints.
    public static bool Offered(JobEditorModel model) => !model.IsEdit && model.Blueprints.Count > 0;

    public static JobBlueprintPickerList List(IReadOnlyList<Blueprint> blueprints, string? checkedKey, string? query)
    {
        var words = Words(query);
        var rows = new List<JobBlueprintPickerRow>();
        if (words.Length == 0) rows.Add(new(null, WriteYourOwn, "", checkedKey == null));
        foreach (var bp in blueprints.Where(b => JobBlueprints.Matches(b, words)))
            rows.Add(new(bp.Key, bp.Title, bp.Description, checkedKey == bp.Key));
        var noResults = words.Length > 0 && rows.Count == 0 ? $"No Results for “{(query ?? "").Trim()}”" : null;
        return new(words.Length == 0, rows, noResults);
    }

    /// A list opened from the editor, or null when the editor offers none (an edit, no blueprints, a save under way).
    public static JobBlueprintPickerSession? Open(JobEditorModel model) =>
        Offered(model) && !model.Saving ? new JobBlueprintPickerSession(model) : null;
}

/// One opening of the list: a fresh empty search; one choice or Back ends it, and a later click does nothing.
public sealed class JobBlueprintPickerSession
{
    private readonly JobEditorModel _model;

    internal JobBlueprintPickerSession(JobEditorModel model) => _model = model;

    public string Query { get; set; } = "";
    public bool Closed { get; private set; }

    /// The rows for the current search, against what the editor holds now (a late blueprint load shows).
    public JobBlueprintPickerList List => JobBlueprintPicker.List(_model.Blueprints, _model.Form.BlueprintKey, Query);

    /// Writes the choice to the same editor's form and closes the list; false (nothing written) once closed.
    public bool Choose(string? key)
    {
        if (Closed) return false;
        Closed = true;
        _model.ChooseBlueprint(key);
        return true;
    }

    /// Back or Escape: closes the list without touching the form.
    public void Back() => Closed = true;
}
