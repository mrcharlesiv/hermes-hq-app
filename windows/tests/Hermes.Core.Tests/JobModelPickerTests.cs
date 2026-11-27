using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Jobs;
using Hermes.Core.Net;
using Xunit;

namespace Hermes.Core.Tests;

/// [WIN-JOB-MODEL-LIST] The job editor's pushed Model list (App/Pages/Jobs/JobEditorSheet.swift JobModelPickerView and
/// JobModelPickerViewController at 93f984bb1): Search Models only above 20 models, matching id / display name / provider
/// name, ids under repeated names, Default and an unlisted Current on an empty search, loading and failure with Try Again,
/// the gateway's provider order, choosing into the same editor's form and Back or Escape writing nothing; the list
/// follows a Bot change. Synthetic providers and profiles only; no gateway is reached and no job is created or run.
public class JobModelPickerTests
{
    /// Answers the editor's reads from memory: per-profile model options, empty targets, a blueprint read left pending.
    private sealed class FakeApi : JobsApi
    {
        public FakeApi() : base(null!) { }
        public Dictionary<string, JsonNode> Options { get; } = [];
        public bool FailModels { get; set; }
        public int ModelReads { get; private set; }

        public override Task<JsonNode?> SendAsync(HttpMethod method, string path, IEnumerable<KeyValuePair<string, string>>? query = null,
            JsonNode? body = null, TimeSpan? timeout = null, CancellationToken ct = default)
        {
            // The editor's background blueprint read never answers here, so no late change lands mid-test.
            if (path == "/api/cron/blueprints") return new TaskCompletionSource<JsonNode?>().Task;
            if (path != "/api/model/options") return Task.FromResult<JsonNode?>(new JsonObject());
            ModelReads++;
            if (FailModels) throw new GatewayException("http", "synthetic failure", 500);
            var profile = query?.FirstOrDefault(q => q.Key == "profile").Value ?? "";
            return Task.FromResult<JsonNode?>(Options.TryGetValue(profile, out var o) ? o.DeepClone() : new JsonObject());
        }
    }

    /// `{ providers: [...] }` with each provider's models as given.
    private static JsonNode Options(params (string Slug, string Name, string[] Models)[] providers) => new JsonObject
    {
        ["providers"] = new JsonArray([.. providers.Select(p => (JsonNode)new JsonObject
        {
            ["slug"] = p.Slug, ["name"] = p.Name, ["authenticated"] = true,
            ["models"] = new JsonArray([.. p.Models.Select(m => (JsonNode)JsonValue.Create(m))]),
        })]),
    };

    private static string[] Synthetic(string prefix, int n) => [.. Enumerable.Range(1, n).Select(i => $"{prefix}-{i:00}")];

    private static List<JobModelProvider> Providers(params (string Slug, string Name, string[] Models)[] providers) =>
        [.. providers.Select(p => new JobModelProvider(p.Slug, p.Name, p.Models))];

    private static string[] Ids(JobModelPickerList list) => [.. list.Sections.SelectMany(s => s.Rows.Select(r => $"{r.Choice.Provider}/{r.Choice.Model}"))];

    private static async Task Until(Func<bool> done)
    {
        for (var i = 0; i < 200 && !done(); i++) await Task.Delay(10);
        Assert.True(done(), "timed out");
    }

    private static async Task<(JobsStore Store, FakeApi Api, JobEditorModel Model)> Editor(Action<FakeApi> setup, string profile = "otto")
    {
        var api = new FakeApi();
        setup(api);
        var store = new JobsStore(api);
        var model = new JobEditorModel(store, null, [("otto", "Otto"), ("ivy", "Ivy")], profile);
        await model.LoadAsync();
        return (store, api, model);
    }

    // MARK: Search threshold

    [Fact]
    public void TwentyModelsHaveNoSearchAndIgnoreAnyWords()
    {
        var providers = Providers(("alpha", "Alpha Cloud", Synthetic("alpha", 12)), ("beta", "Beta", Synthetic("beta", 8)));
        Assert.Equal(20, JobModelPicker.ModelCount(providers));
        Assert.False(JobModelPicker.ShowsSearch(providers));
        var list = JobModelPicker.List(providers, EditorLoad.Loaded, null, null, "beta-03");
        Assert.True(list.ShowsDefault, "no search box, so the words are empty");
        Assert.Equal(20, Ids(list).Length);
    }

    [Fact]
    public void TwentyOneModelsOfferSearchModels()
    {
        var providers = Providers(("alpha", "Alpha Cloud", Synthetic("alpha", 12)), ("beta", "Beta", Synthetic("beta", 9)));
        Assert.Equal(21, JobModelPicker.ModelCount(providers));
        Assert.True(JobModelPicker.ShowsSearch(providers));
        Assert.Equal("Search Models", JobModelPicker.SearchPlaceholder);
        var list = JobModelPicker.List(providers, EditorLoad.Loaded, null, null, "  BETA-03 \n");
        Assert.False(list.ShowsDefault);
        Assert.Equal(["beta/beta-03"], Ids(list));
    }

    // MARK: Matching, order, names

    private static readonly List<JobModelProvider> Many = Providers(
        ("zeta", "Zeta Labs", ["claude-opus-4-5", "gpt-5.5", .. Synthetic("zeta", 8)]),
        ("anthropic", "Anthropic", ["claude-opus-4-5", "claude-sonnet-4-5", .. Synthetic("anth", 5)]),
        ("routehub", "Route Hub (Experimental)", ["gpt-5.5", .. Synthetic("route", 4)]));

    [Fact]
    public void ASearchMatchesIdDisplayNameOrProviderNameInProviderOrder()
    {
        Assert.True(JobModelPicker.ShowsSearch(Many));
        // Display name: "Sonnet 4.5" is the name, not the id ("claude-sonnet-4-5").
        Assert.Equal(["anthropic/claude-sonnet-4-5"], Ids(JobModelPicker.List(Many, EditorLoad.Loaded, null, null, "sonnet 4.5")));
        // Id: "opus-4-5" only in ids, kept in the gateway's provider order (zeta before anthropic).
        Assert.Equal(["zeta/claude-opus-4-5", "anthropic/claude-opus-4-5"], Ids(JobModelPicker.List(Many, EditorLoad.Loaded, null, null, "opus-4-5")));
        // Provider name: every model of the provider.
        var labs = JobModelPicker.List(Many, EditorLoad.Loaded, null, null, "labs");
        Assert.Equal(["zeta"], labs.Sections.Select(s => s.Slug));
        Assert.Equal(10, labs.Sections[0].Rows.Count);
        // Nothing found: no sections, no Default, no Current.
        var none = JobModelPicker.List(Many, EditorLoad.Loaded, null, new JobModelChoice("gone", "old-model"), "zebra");
        Assert.Empty(none.Sections);
        Assert.False(none.ShowsDefault);
        Assert.Null(none.Current);
    }

    [Fact]
    public void ARepeatedDisplayNameShowsItsIdAndSectionsUsePlainProviderNames()
    {
        var list = JobModelPicker.List(Many, EditorLoad.Loaded, new JobModelChoice("anthropic", "claude-opus-4-5"), null, "");
        Assert.Equal(["zeta", "anthropic", "routehub"], list.Sections.Select(s => s.Slug));
        Assert.Equal(["Zeta Labs", "Anthropic", "Route Hub"], list.Sections.Select(s => s.Header));
        var opus = list.Sections.SelectMany(s => s.Rows).Where(r => r.Choice.Model == "claude-opus-4-5").ToList();
        Assert.Equal(2, opus.Count);
        Assert.All(opus, r => Assert.Equal("claude-opus-4-5", r.Note));
        Assert.Equal(opus[0].Title, opus[1].Title);
        Assert.Equal([false, true], opus.Select(r => r.Checked));
        Assert.Null(list.Sections[1].Rows.Single(r => r.Choice.Model == "claude-sonnet-4-5").Note);
        Assert.Equal("job.editor.model.anthropic.claude-opus-4-5", opus[1].AutomationId);
        Assert.False(list.DefaultChecked);
        Assert.Single(list.Sections.SelectMany(s => s.Rows), r => r.Checked);
    }

    [Fact]
    public void DefaultAndAnUnlistedCurrentLeadAnEmptySearch()
    {
        var def = JobModelPicker.List(Many, EditorLoad.Loaded, null, null, "");
        Assert.True(def.ShowsDefault);
        Assert.True(def.DefaultChecked);
        Assert.Null(def.Current);
        Assert.Equal("Default (global model)", JobModelPicker.DefaultTitle);
        Assert.Equal("Uses whatever model this bot is set to.", JobModelPicker.DefaultNote);

        var pinned = new JobModelChoice("gone", "retired-model-9");
        var cur = JobModelPicker.List(Many, EditorLoad.Loaded, pinned, pinned, "  ");
        Assert.NotNull(cur.Current);
        Assert.True(cur.Current!.Checked);
        Assert.Equal("retired-model-9", cur.Current.Note);
        Assert.Equal(pinned, cur.Current.Choice);
        Assert.False(cur.DefaultChecked);
    }

    [Fact]
    public void LoadingAndFailureShowNoModelRowsButKeepDefaultAndCurrent()
    {
        var pinned = new JobModelChoice("gone", "retired-model-9");
        foreach (var state in new[] { EditorLoad.Loading, EditorLoad.Failed })
        {
            var list = JobModelPicker.List(Many, state, pinned, pinned, "");
            Assert.Equal(state, list.State);
            Assert.Empty(list.Sections);
            Assert.True(list.ShowsDefault);
            Assert.NotNull(list.Current);
        }
        Assert.Equal("Couldn’t load the models.", JobModelPicker.LoadFailed);
        Assert.Equal("Try Again", JobModelPicker.TryAgain);
    }

    // MARK: The session against a real editor model (synthetic gateway)

    [Fact]
    public async Task ChoosingWritesTheSameEditorsFormOnceAndBackWritesNothing()
    {
        var (store, _, model) = await Editor(api => api.Options["otto"] = Options(("alpha", "Alpha", Synthetic("alpha", 21))));
        using var _ = store;
        model.SetPrompt("Draft words");
        var before = model.Form.Copy();
        var dirty = model.IsDirty;
        var changes = 0;
        model.Changed += () => changes++;

        var back = JobModelPicker.Open(model)!;
        Assert.True(back.ShowsSearch);
        back.Query = "alpha-07";
        Assert.Equal(["alpha/alpha-07"], Ids(back.List));
        back.Back();
        Assert.True(back.Closed);
        Assert.False(back.Choose(new JobModelChoice("alpha", "alpha-07")), "a click after Back is ignored");
        Assert.Equal(before, model.Form);
        Assert.Equal(dirty, model.IsDirty);
        Assert.Equal(0, changes);

        var session = JobModelPicker.Open(model)!;
        Assert.Equal("", session.Query);
        Assert.True(session.Choose(new JobModelChoice("alpha", "alpha-07")));
        Assert.Equal(new JobModelChoice("alpha", "alpha-07"), model.Form.Model);
        Assert.Equal("Draft words", model.Form.Prompt);
        Assert.Equal(1, changes);
        Assert.False(session.Choose(null));
        Assert.Equal(new JobModelChoice("alpha", "alpha-07"), model.Form.Model);

        // The checked row closes without a change; Default clears the pin.
        var same = JobModelPicker.Open(model)!;
        Assert.True(same.Choose(new JobModelChoice("alpha", "alpha-07")));
        Assert.Equal(1, changes);
        Assert.True(JobModelPicker.Open(model)!.Choose(null));
        Assert.Null(model.Form.Model);
        Assert.Equal(2, changes);
    }

    [Fact]
    public async Task TryAgainReloadsTheSameBotsModels()
    {
        var (store, api, model) = await Editor(api =>
        {
            api.Options["otto"] = Options(("alpha", "Alpha", Synthetic("alpha", 3)));
            api.FailModels = true;
        });
        using var _ = store;
        var session = JobModelPicker.Open(model)!;
        Assert.Equal(EditorLoad.Failed, session.List.State);
        Assert.Empty(session.List.Sections);
        api.FailModels = false;
        await session.RetryAsync();
        Assert.Equal(EditorLoad.Loaded, session.List.State);
        Assert.Equal(["alpha/alpha-01", "alpha/alpha-02", "alpha/alpha-03"], Ids(session.List));
        Assert.Null(model.Form.Model);

        var reads = api.ModelReads;
        session.Back();
        await session.RetryAsync();
        Assert.Equal(reads, api.ModelReads);
    }

    [Fact]
    public async Task ABotChangeBringsThatBotsListAndItsSearchThreshold()
    {
        var (store, _, model) = await Editor(api =>
        {
            api.Options["otto"] = Options(("alpha", "Alpha", Synthetic("alpha", 20)));
            api.Options["ivy"] = Options(("beta", "Beta", Synthetic("beta", 11)), ("alpha", "Alpha", Synthetic("alpha", 10)));
        });
        using var _ = store;
        var first = JobModelPicker.Open(model)!;
        Assert.False(first.ShowsSearch);
        Assert.True(first.Choose(new JobModelChoice("alpha", "alpha-15")));
        Assert.Null(model.UnlistedModel);

        model.ChooseProfile("ivy");
        await Until(() => model.Providers.Count == 2 && model.ModelsState == EditorLoad.Loaded);
        var second = JobModelPicker.Open(model)!;
        Assert.True(second.ShowsSearch);
        Assert.Equal(["beta", "alpha"], second.List.Sections.Select(s => s.Slug));
        // Ivy lists only alpha-01..10, so Otto's pick stays as Current and nothing in the list is checked.
        Assert.Equal(new JobModelChoice("alpha", "alpha-15"), second.List.Current?.Choice);
        Assert.DoesNotContain(second.List.Sections.SelectMany(s => s.Rows), r => r.Checked);
        second.Query = "beta-1";
        Assert.Equal(["beta/beta-10", "beta/beta-11"], Ids(second.List));
        second.Back();
        Assert.Equal(new JobModelChoice("alpha", "alpha-15"), model.Form.Model);

        model.ChooseProfile("otto");
        await Until(() => model.Providers.Count == 1);
        Assert.False(JobModelPicker.Open(model)!.ShowsSearch);
    }

    [Fact]
    public async Task TheListIsOfferedOnlyWithAModelRowAndNotWhileSaving()
    {
        var (store, _, model) = await Editor(api => api.Options["otto"] = Options(("alpha", "Alpha", Synthetic("alpha", 2))));
        using var _ = store;
        Assert.NotNull(JobModelPicker.Open(model));
        store.BlueprintsByProfile["otto"] = [new Blueprint("brief", "Brief", "A brief.")];
        model.ChooseBlueprint("brief");
        Assert.False(model.ShowsModelRow);
        Assert.Null(JobModelPicker.Open(model));
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
    public void TheModelRowPushesTheListInsideTheSameDialog()
    {
        var src = Dialog();
        Assert.DoesNotContain("MenuFlyout", src);   // the flat flyout is gone
        var section = Body(src, "private void ModelSection()");
        Assert.Contains("\"job.editor.model\"", section);
        Assert.Matches(@"Click \+= \(_, _\) => OpenModels\(\)", section);

        var open = Body(src, "private void OpenModels()");
        Assert.Contains("JobModelPicker.Open(_model)", open);
        Assert.Contains("_dialog.Content = ", open);
        Assert.DoesNotContain("new ContentDialog", open);
        Assert.Contains("\"job.editor.models\"", src);
        Assert.Contains("JobModelPicker.SearchPlaceholder", src);
    }

    [Fact]
    public void TheListChoosesThroughTheSessionAndBackOrEscapeWritesNothing()
    {
        var src = Dialog();
        var fill = Body(src, "private void FillModels()");
        Assert.Contains("session.List", fill);
        Assert.Contains("session.ShowsSearch", fill);
        Assert.Contains("session.Choose(", fill);
        Assert.Contains("session.RetryAsync()", fill);
        Assert.Contains("JobModelPicker.TryAgain", fill);
        Assert.DoesNotContain("_model.SetModel", src);

        var closing = Body(src, "private void OnClosing(");
        var picking = closing.IndexOf("_models != null", StringComparison.Ordinal);
        Assert.True(picking >= 0 && picking < closing.IndexOf("IsDirty", StringComparison.Ordinal), "the list is checked before the discard question");
        Assert.Contains("_models != null", Body(src, "private async void OnSave("));
        Assert.Contains("VirtualKey.Escape", Body(src, "private UIElement ModelsPage("));
        var back = Body(src, "private void BackFromModels(");
        Assert.Contains(".Back()", back);
        Assert.DoesNotContain("_model.", back);
    }
}
