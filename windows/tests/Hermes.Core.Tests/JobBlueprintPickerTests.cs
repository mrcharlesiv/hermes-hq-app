using System.Text.RegularExpressions;
using Hermes.Core.Jobs;
using Xunit;

namespace Hermes.Core.Tests;

/// [WIN-JOB-BLUEPRINT-PICKER] New Job's "See All" list (App/Pages/Jobs/JobEditorSheet.swift JobBlueprintPickerView at
/// 93f984bb1): Swift's match rules (trimmed, lowercased, title or description), the catalog's order, the checked row,
/// Write Your Own only for an empty search, a truthful no-results state; choosing writes the same editor's form, Back or
/// Escape writes nothing. Synthetic blueprints and forms only; no job is created or run.
public class JobBlueprintPickerTests
{
    private sealed class FakeApi() : JobsApi(null!)
    {
        public override Task<System.Text.Json.Nodes.JsonNode?> SendAsync(HttpMethod method, string path, IEnumerable<KeyValuePair<string, string>>? query = null,
            System.Text.Json.Nodes.JsonNode? body = null, TimeSpan? timeout = null, CancellationToken ct = default) =>
            throw new InvalidOperationException("the picker never calls the gateway");
    }

    private static readonly List<Blueprint> Catalog =
    [
        new("morning-brief", "Morning Brief", "A short summary of the day ahead."),
        new("inbox-sweep", "Inbox Sweep", "Sort unread mail and flag what needs a reply."),
        new("weekly-review", "Weekly Review", "Look back at the week's notes."),
        new("price-watch", "Price Watch", "Check a page and say when the price drops.",
            FieldList: [new BlueprintField("url", "url", "Page")]),
    ];

    private static (JobsStore Store, JobEditorModel Model) Editor(string? chosen = null)
    {
        var store = new JobsStore(new FakeApi());
        store.BlueprintsByProfile["otto"] = [.. Catalog];
        var model = new JobEditorModel(store, null, [("otto", "Otto")], "otto");
        if (chosen != null) model.ChooseBlueprint(chosen);
        return (store, model);
    }

    private static string[] Keys(JobBlueprintPickerList list) => [.. list.Rows.Select(r => r.Key ?? "custom")];

    [Fact]
    public void AnEmptySearchOffersWriteYourOwnThenEveryBlueprintInOrder()
    {
        var list = JobBlueprintPicker.List(Catalog, checkedKey: null, query: "");
        Assert.True(list.ShowsWriteYourOwn);
        Assert.Equal(["custom", "morning-brief", "inbox-sweep", "weekly-review", "price-watch"], Keys(list));
        Assert.Equal("Write Your Own", list.Rows[0].Title);
        Assert.Equal("", list.Rows[0].Note);
        Assert.True(list.Rows[0].Checked);
        Assert.Single(list.Rows, r => r.Checked);
        Assert.Equal("A short summary of the day ahead.", list.Rows[1].Note);
        Assert.Null(list.NoResultsTitle);
        Assert.Equal("job.editor.start.custom", list.Rows[0].AutomationId);
        Assert.Equal("job.editor.start.inbox-sweep", list.Rows[2].AutomationId);

        // Spaces alone are an empty search (Swift's pgTrim), so Write Your Own stays.
        var blank = JobBlueprintPicker.List(Catalog, "inbox-sweep", "  \t\n ");
        Assert.True(blank.ShowsWriteYourOwn);
        Assert.Equal(5, blank.Rows.Count);
        Assert.Equal("inbox-sweep", Assert.Single(blank.Rows, r => r.Checked).Key);
    }

    [Fact]
    public void ATrimmedSearchMatchesTitlesWithoutCaseAndHidesWriteYourOwn()
    {
        var list = JobBlueprintPicker.List(Catalog, "weekly-review", "  WEEK \n");
        Assert.False(list.ShowsWriteYourOwn);
        Assert.Equal(["weekly-review"], Keys(list));
        Assert.True(list.Rows[0].Checked);
        Assert.Null(list.NoResultsTitle);
        Assert.Equal("week", JobBlueprintPicker.Words("  WEEK \n"));
    }

    [Fact]
    public void ASearchMatchesDescriptionsAndKeepsTheCatalogOrder()
    {
        // "the" is in Morning Brief's and Price Watch's descriptions and Weekly Review's ("the week's"), not in any title.
        var list = JobBlueprintPicker.List(Catalog, "price-watch", "the");
        Assert.False(list.ShowsWriteYourOwn);
        Assert.Equal(["morning-brief", "weekly-review", "price-watch"], Keys(list));
        Assert.Equal([false, false, true], list.Rows.Select(r => r.Checked));
        Assert.Equal(["inbox-sweep"], Keys(JobBlueprintPicker.List(Catalog, null, "reply")));
    }

    [Fact]
    public void ASearchWithNoMatchSaysSoTruthfully()
    {
        var list = JobBlueprintPicker.List(Catalog, null, "  zebra  ");
        Assert.False(list.ShowsWriteYourOwn);
        Assert.Empty(list.Rows);
        Assert.Equal("No Results for “zebra”", list.NoResultsTitle);
        Assert.Equal("Check the spelling or try a new search.", JobBlueprintPicker.NoResultsNote);

        // An empty catalog with an empty search is not a "no results" search.
        var none = JobBlueprintPicker.List([], null, "");
        Assert.Null(none.NoResultsTitle);
        Assert.Equal(["custom"], Keys(none));
    }

    [Fact]
    public void SeeAllIsOfferedOnlyWhenCreatingWithBlueprints()
    {
        var (store, create) = Editor();
        using (store) Assert.True(JobBlueprintPicker.Offered(create));

        using var empty = new JobsStore(new FakeApi());
        Assert.False(JobBlueprintPicker.Offered(new JobEditorModel(empty, null, [("otto", "Otto")], "otto")));

        using var editStore = new JobsStore(new FakeApi());
        editStore.BlueprintsByProfile["otto"] = [.. Catalog];
        var job = new CronJob("j1") { Name = "Plan", Prompt = "Plan the day", Schedule = new CronSchedule { Kind = "cron", Expr = "0 9 * * *" } };
        Assert.False(JobBlueprintPicker.Offered(new JobEditorModel(editStore, job, [("otto", "Otto")], "otto")));
        Assert.Null(JobBlueprintPicker.Open(new JobEditorModel(editStore, job, [("otto", "Otto")], "otto")));
    }

    [Fact]
    public void ChoosingWritesTheSameEditorsFormOnce()
    {
        var (store, model) = Editor();
        using var _ = store;
        model.SetPrompt("Draft words");
        var changes = 0;
        model.Changed += () => changes++;
        var session = JobBlueprintPicker.Open(model)!;
        session.Query = "  price ";
        Assert.Equal(["price-watch"], Keys(session.List));

        Assert.True(session.Choose("price-watch"));
        Assert.True(session.Closed);
        Assert.Equal("price-watch", model.Form.BlueprintKey);
        Assert.Same(Catalog[3], model.Blueprint);
        Assert.True(model.Form.Slots.ContainsKey("url"));
        Assert.Equal(1, changes);

        // A late second click on a closed list writes nothing.
        Assert.False(session.Choose("inbox-sweep"));
        Assert.Equal("price-watch", model.Form.BlueprintKey);
        Assert.Equal(1, changes);

        // Write Your Own from a fresh list goes back to the prompt form; the typed prompt survived the template.
        var again = JobBlueprintPicker.Open(model)!;
        Assert.True(again.List.Rows.Single(r => r.Key == "price-watch").Checked);
        Assert.True(again.Choose(null));
        Assert.Null(model.Form.BlueprintKey);
        Assert.Empty(model.Form.Slots);
        Assert.Equal("Draft words", model.Form.Prompt);
    }

    [Fact]
    public void ChoosingTheCheckedRowReturnsWithoutAChange()
    {
        var (store, model) = Editor("inbox-sweep");
        using var _ = store;
        var before = model.Form.Copy();
        var changes = 0;
        model.Changed += () => changes++;
        var session = JobBlueprintPicker.Open(model)!;
        Assert.True(session.Choose("inbox-sweep"));
        Assert.True(session.Closed);
        Assert.Equal(before, model.Form);
        Assert.Equal(0, changes);
    }

    [Fact]
    public void BackOrEscapeWithoutChoosingChangesNothing()
    {
        var (store, model) = Editor("morning-brief");
        using var _ = store;
        model.SetSlot("extra", "kept");
        model.Failure = "Couldn’t reach the gateway.";
        var before = model.Form.Copy();
        var baseline = model.Baseline.Copy();
        var dirty = model.IsDirty;
        var changes = 0;
        model.Changed += () => changes++;

        var session = JobBlueprintPicker.Open(model)!;
        session.Query = "zebra";
        Assert.Empty(session.List.Rows);
        session.Query = "week";
        session.Back();
        Assert.True(session.Closed);
        Assert.False(session.Choose("weekly-review"), "a click after Back is ignored");

        Assert.Equal(before, model.Form);
        Assert.Equal("kept", model.Form.Slots["extra"]);
        Assert.Equal(baseline, model.Baseline);
        Assert.Equal(dirty, model.IsDirty);
        Assert.Equal("Couldn’t reach the gateway.", model.Failure);
        Assert.Equal(0, changes);

        // Each See All starts with an empty search, as the Mac pushes a new list.
        Assert.Equal("", JobBlueprintPicker.Open(model)!.Query);
    }

    // MARK: The WinUI dialog's source (headless: it shows the wiring, not a WinUI window being driven)

    private static string Dialog()
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        return File.ReadAllText(Path.Combine(dir, "src", "HermesHQ.Windows", "Features", "Jobs", "JobEditorDialog.cs"));
    }

    private static string Body(string source, string signature)
    {
        var m = Regex.Match(source, Regex.Escape(signature) + @"[^\n]*\n    \{(?<body>.*?)\n    \}", RegexOptions.Singleline);
        Assert.True(m.Success, signature + " not found");
        return m.Groups["body"].Value;
    }

    [Fact]
    public void StartFromHasSeeAllThatOpensThePickerInTheSameDialog()
    {
        var src = Dialog();
        var section = Body(src, "private void TemplateSection()");
        Assert.Contains("JobBlueprintPicker.SeeAll", section);
        Assert.Contains("\"job.editor.start.all\"", section);
        Assert.Matches(@"Click \+= \(_, _\) => OpenPicker\(\)", section);
        Assert.Contains("JobBlueprintPicker.Offered(_model)", Body(src, "private void Render()"));

        var open = Body(src, "private void OpenPicker()");
        Assert.Contains("_model.Saving", open);
        Assert.Contains("JobBlueprintPicker.Open(_model)", open);
        Assert.Contains("_dialog.Content = ", open);
        Assert.DoesNotContain("new ContentDialog", open);   // one dialog: the picker replaces the form inside it
        Assert.Contains("\"job.editor.blueprints\"", src);
        Assert.Contains("JobBlueprintPicker.SearchPlaceholder", src);
    }

    [Fact]
    public void ThePickerChoosesThroughTheSessionAndBackWritesNothing()
    {
        var src = Dialog();
        var fill = Body(src, "private void FillPicker()");
        Assert.Contains("session.List", fill);
        Assert.Contains("NoResultsTitle", fill);
        Assert.Contains("JobBlueprintPicker.NoResultsNote", fill);
        Assert.Matches(@"session\.Choose\(key\)", fill);
        Assert.DoesNotContain("_model.ChooseBlueprint", fill);

        var back = Body(src, "private void ClosePicker(");
        Assert.DoesNotContain("_model.", back.Replace("_model.Title", "").Replace("_model.ActionTitle", "").Replace("_model.CanSave", ""));
        Assert.Contains("_dialog.Content = _body", back);

        // Escape (or the dialog's close) while picking goes back to the form: no Discard bar, no close.
        var closing = Body(src, "private void OnClosing(");
        var picking = closing.IndexOf("_picker != null", StringComparison.Ordinal);
        Assert.True(picking >= 0 && picking < closing.IndexOf("IsDirty", StringComparison.Ordinal), "the picker is checked before the discard question");
        Assert.Contains("VirtualKey.Escape", Body(src, "private UIElement PickerPage("));
    }
}
