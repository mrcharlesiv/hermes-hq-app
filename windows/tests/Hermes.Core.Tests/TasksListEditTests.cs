using System.Text.Json.Nodes;
using Hermes.Core.Kanban;
using Hermes.Core.Tasks;

namespace Hermes.Core.Tests;

/// [WIN-TASK-LIST-EDIT] Edit List (App/Pages/Tasks/TaskListViews.swift TaskListEditModel/TaskListEditView, 93f984bb1;
/// HermesKit TasksStore.saveSection): the name, and on an add-on that keeps lists (0.9.55, `lists: true`) its colour,
/// icon, the bot that keeps it, Ask First and Show in Today, each saved at once as the whole lists on
/// `PUT /tasks/sections`; Delete List… asks first. Synthetic data only.
public class TasksListEditTests
{
    /// A stand-in add-on keeping lists as the stand-in gateway does. `Hold` keeps the next PUT waiting.
    private sealed class AddOn
    {
        public JsonArray Sections = [];
        public JsonArray Tasks = [];
        public bool FailSections, Lists = true;
        public TaskCompletionSource? Hold;
        public FakeRest Rest => _rest ??= new FakeRest(Answer);
        private FakeRest? _rest;

        private JsonNode? Answer(FakeRest.Request r)
        {
            switch (r.Method, r.Path)
            {
                case ("GET", TasksApi.Base):
                    return new JsonObject
                    {
                        ["rev"] = 1, ["tasks"] = Tasks.DeepClone(), ["sections"] = Sections.DeepClone(), ["fields"] = true, ["lists"] = Lists,
                    };
                case ("PUT", TasksApi.Base + "/sections"):
                    if (FailSections) throw FakeRest.Http(500, "disk full");
                    Sections = (JsonArray)r.Body.Arr("sections")!.DeepClone();
                    // A list left out takes its tasks back to no list, as the gateway does.
                    var kept = Sections.Select(x => x.Str("id")).ToHashSet();
                    foreach (var t in Tasks) if (t.Str("section") is { } id && !kept.Contains(id)) t!["section"] = null;
                    return new JsonObject { ["rev"] = 2, ["sections"] = Sections.DeepClone() };
                default:
                    return new JsonObject();
            }
        }
    }

    /// A rest whose PUT waits for the test to let it go (an edit made while a save is out).
    private sealed class HeldRest(AddOn addOn) : Hermes.Core.Kanban.IPagesRest
    {
        public TaskCompletionSource Gate = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public bool HoldPuts;
        public Task<JsonNode?> JsonAsync(HttpMethod method, string path, IEnumerable<KeyValuePair<string, string>>? query = null,
            JsonNode? body = null, TimeSpan? timeout = null, CancellationToken ct = default)
        {
            if (method == HttpMethod.Put && HoldPuts) return Later();
            return addOn.Rest.JsonAsync(method, path, query, body, timeout, ct);
            async Task<JsonNode?> Later()
            {
                await Gate.Task;
                return await addOn.Rest.JsonAsync(method, path, query, body, timeout, ct);
            }
        }
        public Task<string> UploadAsync(string path, IEnumerable<KeyValuePair<string, string>>? query, string contentType, string bodyFile,
            TimeSpan timeout, Action<long, long>? progress = null, CancellationToken ct = default) => addOn.Rest.UploadAsync(path, query, contentType, bodyFile, timeout, progress, ct);
        public Task DownloadAsync(string path, IEnumerable<KeyValuePair<string, string>>? query, string file, long ceiling, CancellationToken ct = default) =>
            addOn.Rest.DownloadAsync(path, query, file, ceiling, ct);
    }

    private static readonly IReadOnlyList<(string Id, string Name)> Bots = [("otto", "Otto"), ("ivy", "Ivy")];

    private static AddOn Synthetic(bool lists = true) => new()
    {
        Lists = lists,
        Sections =
        [
            new JsonObject { ["id"] = "sec_home", ["name"] = "Home", ["color"] = "red", ["icon"] = "house", ["checked_at"] = "2026-11-20T08:00:00" },
            new JsonObject { ["id"] = "sec_work", ["name"] = "Work", ["color"] = "blue", ["bot"] = "otto", ["adds"] = "ask", ["today"] = false },
        ],
        Tasks =
        [
            new JsonObject { ["id"] = "t1", ["title"] = "Water plants", ["status"] = "open", ["section"] = "sec_home", ["rev"] = 1, ["who"] = "me" },
            new JsonObject { ["id"] = "t2", ["title"] = "Sweep", ["status"] = "done", ["section"] = "sec_home", ["rev"] = 1, ["who"] = "me" },
        ],
    };

    private static async Task<(TasksStore Store, TaskListEditModel Model)> Open(AddOn addOn, string id = "sec_home", Hermes.Core.Kanban.IPagesRest? rest = null)
    {
        var store = new TasksStore(new TasksApi(rest ?? addOn.Rest));
        await store.RefreshAsync();
        var model = TaskListEditModel.Open(store, id, Bots)!;
        Assert.NotNull(model);
        return (store, model);
    }

    private static List<FakeRest.Request> Puts(AddOn addOn) => [.. addOn.Rest.Log.Where(r => r.Method == "PUT")];
    private static JsonNode Sent(AddOn addOn, string id) => Puts(addOn).Last().Body.Arr("sections")!.Single(s => s.Str("id") == id)!;

    [Fact]
    public void ThePillMenuOffersEditListFirstAndKeepsTheRest()
    {
        Assert.Equal([TodoListMenuItem.EditList, TodoListMenuItem.Rename, TodoListMenuItem.MoveLeft, TodoListMenuItem.MoveRight, TodoListMenuItem.Divider, TodoListMenuItem.DeleteList],
            TodoListCopy.Menu(1, 3));
        Assert.Equal("Edit List…", TodoListCopy.Title(TodoListMenuItem.EditList));
    }

    [Fact]
    public void TheMacsWords()
    {
        Assert.Equal(("Edit List", "List Name", "Done", "Colour", "Icon", "Bot", "Kept By", "No One", "New Tasks"),
            (TaskListEditCopy.Title, TaskListEditCopy.NamePlaceholder, TaskListEditCopy.Done, TaskListEditCopy.Colour, TaskListEditCopy.Icon,
             TaskListEditCopy.Bot, TaskListEditCopy.KeptBy, TaskListEditCopy.NoOne, TaskListEditCopy.NewTasks));
        Assert.Equal(("Add Without Asking", "Ask First", "Show in Today", "Delete List…"),
            (TaskListEditCopy.AddWithoutAsking, TaskListEditCopy.AskFirst, TaskListEditCopy.ShowInToday, TaskListEditCopy.DeleteList));
        Assert.Equal("A small dot in this colour marks the list’s tasks in Today, Upcoming and search.", TaskListEditCopy.ColourFooter);
        Assert.Equal("A bot that keeps a list files what belongs there and tells you when a task looks settled.", TaskListEditCopy.BotFooter(null, false));
        Assert.Equal("Otto files what belongs here and adds new tasks as it finds them. It never marks your task done or rewords it: it offers, and you decide.",
            TaskListEditCopy.BotFooter("Otto", false));
        Assert.Equal("Otto files what belongs here, and shows you new tasks as a card before they go on. It never marks your task done or rewords it: it offers, and you decide.",
            TaskListEditCopy.BotFooter("Otto", true));
        Assert.Equal("Today shows this list’s next 3 tasks under the ones that are due, in the order you keep them.", TaskListEditCopy.TodayFooter);
        Assert.Equal(16, TodoListIcons.All.Count);
        Assert.Equal(("list.bullet", "List", "Home", "Briefcase", "Money", "Tools", "Pets", "Flag"),
            (TodoListIcons.Fallback, TodoListIcons.Spoken("list.bullet"), TodoListIcons.Spoken("house"), TodoListIcons.Spoken("briefcase"),
             TodoListIcons.Spoken("dollarsign.circle"), TodoListIcons.Spoken("wrench.and.screwdriver"), TodoListIcons.Spoken("pawprint"), TodoListIcons.Spoken("flag")));
        Assert.Equal(("Blue", "Gray"), (TodoListColors.Name("blue"), TodoListColors.Name("gray")));
    }

    [Fact]
    public async Task BlankNameKeepsTheOldOneAndUnchangedNameSendsNothing()
    {
        var addOn = Synthetic();
        var (_, model) = await Open(addOn);
        model.Name = "   \n ";
        Assert.False(await model.CommitNameAsync());
        Assert.Equal("Home", model.Name);   // the field shows the name it keeps
        model.Name = "  Home  ";
        Assert.False(await model.CommitNameAsync());
        Assert.Equal("Home", model.Name);   // trimmed in the field, and nothing to save
        Assert.Empty(Puts(addOn));
    }

    [Fact]
    public async Task ANewNameIsTrimmedCutAtSixtyCharactersAndSavedWithTheRestOfTheList()
    {
        var addOn = Synthetic();
        var (store, model) = await Open(addOn);
        var name = "  " + string.Concat(Enumerable.Repeat("🏡", 59)) + "👍🏽 and more ";
        model.Name = name;
        Assert.True(await model.CommitNameAsync());
        var clean = string.Concat(Enumerable.Repeat("🏡", 59)) + "👍🏽";
        Assert.Equal(clean, model.Name);
        Assert.Equal(clean, model.Draft.Name);
        Assert.Single(Puts(addOn));
        var sent = Puts(addOn).Single().Body.Arr("sections")!;
        // The whole lists, in order; only this one's name changed; no checked_at goes back.
        var expected = new JsonObject
        {
            ["id"] = "sec_home", ["name"] = clean, ["color"] = "red", ["icon"] = "house", ["bot"] = "", ["adds"] = "auto", ["today"] = true,
        };
        Assert.True(JsonNode.DeepEquals(expected, sent[0]), sent[0]!.ToJsonString());
        Assert.Equal(clean, sent[0].Str("name"));
        Assert.Equal("""{"id":"sec_work","name":"Work","color":"blue","icon":"","bot":"otto","adds":"ask","today":false}""", sent[1]!.ToJsonString());
        Assert.Equal(clean, store.Sections[0].Name);
        // Committing the same name again (the field losing focus, then Done) sends nothing more.
        Assert.False(await model.CommitNameAsync());
        Assert.Single(Puts(addOn));
    }

    [Fact]
    public async Task OnAnAddOnThatKeepsListsEveryControlSavesAtOnce()
    {
        var addOn = Synthetic();
        var (store, model) = await Open(addOn);
        Assert.True(model.ShowsExtras);
        Assert.Equal("red", model.Color);

        Assert.True(await model.PickColorAsync("green"));
        Assert.Equal("green", Sent(addOn, "sec_home").Str("color"));
        Assert.True(await model.PickColorAsync("green"));   // the picked one again clears it
        Assert.Equal("", Sent(addOn, "sec_home").Str("color"));
        Assert.Null(model.Color);
        Assert.False(await model.PickColorAsync("mauve"));   // not one of the Mac's colours
        Assert.True(await model.PickIconAsync("cart"));
        Assert.Equal("cart", Sent(addOn, "sec_home").Str("icon"));
        Assert.True(await model.PickIconAsync("cart"));   // the picked icon again clears it (the pill shows the fallback)
        Assert.Equal(("", "list.bullet"), (Sent(addOn, "sec_home").Str("icon"), model.ShownIcon));
        Assert.False(await model.PickIconAsync("rocket"));

        Assert.False(model.ShowsNewTasks);   // no bot: no Ask First
        Assert.True(await model.SetBotAsync("ivy"));
        Assert.True(model.ShowsNewTasks);
        Assert.Equal(("ivy", "auto"), (Sent(addOn, "sec_home").Str("bot"), Sent(addOn, "sec_home").Str("adds")));
        Assert.Equal(TaskListEditCopy.BotFooter("Ivy", false), model.BotFooter);
        Assert.True(await model.SetAsksFirstAsync(true));
        Assert.Equal("ask", Sent(addOn, "sec_home").Str("adds"));
        Assert.Equal(TaskListEditCopy.BotFooter("Ivy", true), model.BotFooter);
        Assert.True(await model.SetBotAsync(null));   // No One
        Assert.Equal("", Sent(addOn, "sec_home").Str("bot"));
        Assert.Equal(TaskListEditCopy.BotFooter(null, false), model.BotFooter);

        Assert.True(await model.SetInTodayAsync(false));
        Assert.False(Sent(addOn, "sec_home")["today"]!.GetValue<bool>());
        var before = Puts(addOn).Count;
        Assert.True(await model.SetInTodayAsync(false));   // already so: nothing sent
        Assert.Equal(before, Puts(addOn).Count);
        // The other list went along untouched every time.
        Assert.All(Puts(addOn), p => Assert.Equal("""{"id":"sec_work","name":"Work","color":"blue","icon":"","bot":"otto","adds":"ask","today":false}""",
            p.Body.Arr("sections")![1]!.ToJsonString()));
        Assert.False(store.Sections[0].InToday);
    }

    [Fact]
    public async Task AnOlderAddOnEditsOnlyTheNameAndKeepsTheRestOfTheListAsItWas()
    {
        var addOn = Synthetic(lists: false);
        var (store, model) = await Open(addOn);
        Assert.True(store.EditsLists);
        Assert.False(model.ShowsExtras);
        Assert.False(await model.PickColorAsync("green"));
        Assert.False(await model.PickIconAsync("cart"));
        Assert.False(await model.SetBotAsync("otto"));
        Assert.False(await model.SetAsksFirstAsync(true));
        Assert.False(await model.SetInTodayAsync(false));
        Assert.Empty(Puts(addOn));
        Assert.Equal(store.Sections[0], model.Draft);

        model.Name = "Chores";
        Assert.True(await model.CommitNameAsync());
        Assert.Equal("""{"id":"sec_home","name":"Chores","color":"red","icon":"house","bot":"","adds":"auto","today":true}""",
            Puts(addOn).Single().Body.Arr("sections")![0]!.ToJsonString());
    }

    [Fact]
    public async Task ARefusedSavePutsTheControlsBackToWhatTheGatewayKeeps()
    {
        var addOn = Synthetic();
        var (store, model) = await Open(addOn);
        var notices = new List<string>();
        store.Notice += (t, _) => notices.Add(t);
        var changed = 0;
        model.Changed += () => changed++;
        addOn.FailSections = true;
        model.Name = "Chores";
        Assert.False(await model.CommitNameAsync());
        Assert.Equal(("Home", "Home"), (model.Name, model.Draft.Name));
        Assert.False(await model.PickColorAsync("teal"));
        Assert.Equal("red", model.Color);
        Assert.False(await model.SetBotAsync("otto"));
        Assert.Null(model.Draft.Bot);
        Assert.Equal(store.Sections[0], model.Draft);
        Assert.Equal("Home", store.Sections[0].Name);
        Assert.True(changed >= 6);   // each change, and each put back
        Assert.Equal(3, notices.Count);
        Assert.All(notices, n => Assert.Equal("Couldn’t save your sections. disk full", n));
    }

    [Fact]
    public async Task ARefusedSaveNeverOverwritesANewerEdit()
    {
        var addOn = Synthetic();
        var held = new HeldRest(addOn);
        var (store, model) = await Open(addOn, rest: held);
        held.HoldPuts = true;
        var first = model.PickColorAsync("green");   // goes out, and waits
        Assert.Equal("green", model.Color);
        model.Name = "Garden";   // typed while the colour is out (not committed yet)
        held.HoldPuts = false;
        Assert.True(await model.PickIconAsync("leaf"));   // a newer change than the colour (it carries the colour too)
        addOn.FailSections = true;
        held.Gate.SetResult();
        Assert.False(await first);   // the older save is refused after the newer one went out
        // The colour's refusal came after a newer edit: it puts nothing back over it, nor over the name being typed.
        Assert.Equal(("green", "leaf", "Garden"), (model.Color, model.Draft.Icon, model.Name));
        Assert.Equal("Home", model.Draft.Name);
        Assert.Equal(2, addOn.Rest.Log.Count(r => r.Method == "PUT"));
        _ = store;
    }

    [Fact]
    public async Task ARefusedSaveRestoresTheConfirmedListNotTheOptimisticOne()
    {
        var addOn = Synthetic();
        var (store, model) = await Open(addOn);
        Assert.True(await model.PickColorAsync("teal"));   // confirmed by the gateway
        addOn.FailSections = true;
        Assert.False(await model.PickIconAsync("star"));
        // Back to the last confirmed draft: teal (saved), its old icon (the refused star gone).
        Assert.Equal(("teal", "house"), (model.Color, model.Draft.Icon));
        Assert.Equal(store.Sections.Single(s => s.Id == "sec_home"), model.Draft);
    }

    [Fact]
    public async Task ASaveThatLandsKeepsTheDraftAsTheGatewaySavedIt()
    {
        var addOn = Synthetic();
        var (store, model) = await Open(addOn);
        Assert.True(await model.PickColorAsync("purple"));
        Assert.Equal(store.Sections.Single(s => s.Id == "sec_home").Color, model.Color);
        Assert.Equal(["sec_home", "sec_work"], store.Sections.Select(s => s.Id));
    }

    [Fact]
    public async Task DeleteListAsksFirstAndCancelKeepsEverything()
    {
        var addOn = Synthetic();
        var (store, model) = await Open(addOn);
        (string Title, string? Message)? asked = null;
        Assert.False(await model.DeleteAsync((title, message) => { asked = (title, message); return Task.FromResult(false); }));
        Assert.Equal(("Delete “Home”?", "Its 1 task and 1 done task are kept, in no list."), asked);
        Assert.Empty(Puts(addOn));
        Assert.Equal(["sec_home", "sec_work"], store.Sections.Select(s => s.Id));
        Assert.Equal("sec_home", store.Find("t1")!.Section);

        Assert.True(await model.DeleteAsync((_, _) => Task.FromResult(true)));
        Assert.Equal(["sec_work"], store.Sections.Select(s => s.Id));
        Assert.Equal((null, null), (store.Find("t1")!.Section, store.Find("t2")!.Section));
        Assert.Equal(2, store.Tasks.Count);   // no task deleted
    }

    [Fact]
    public async Task OpeningIsRefusedOnAReadOnlyGatewayOrAListThatIsGone()
    {
        var addOn = Synthetic();
        var store = new TasksStore(new TasksApi(addOn.Rest));
        await store.RefreshAsync();
        Assert.Null(TaskListEditModel.Open(store, "sec_gone", Bots));
        store.ReadOnlyGateway = true;
        Assert.Null(TaskListEditModel.Open(store, "sec_home", Bots));
        Assert.Equal(KanbanRest.ReadOnlyNotice, TaskListEditModel.Refusal(store, "sec_home"));
        store.ReadOnlyGateway = false;
        Assert.Null(TaskListEditModel.Refusal(store, "sec_home"));
        var model = TaskListEditModel.Open(store, "sec_work", Bots)!;
        Assert.Equal(("Work", "otto", true, false, "Otto"), (model.Name, model.Draft.Bot, model.Draft.AsksFirst, model.Draft.InToday, model.BotName("otto")));
        Assert.Equal("ghost", model.BotName("ghost"));
    }
}
