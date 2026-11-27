using System.Text.Json.Nodes;
using Hermes.Core.Kanban;
using Hermes.Core.Tasks;

namespace Hermes.Core.Tests;

/// New List, Rename List, Move Left/Right, Delete List and Tasks Settings (App/Pages/Tasks/TasksViewController.swift,
/// TaskViewsHeader.swift, TodoSettingsSheet.swift; HermesKit/Pages/Tasks/TasksStore.swift): the whole lists on
/// `PUT /tasks/sections`, a deleted list's tasks kept in no list, the Mac's words, and each setting on `PUT /tasks/settings`.
public class TasksListsTests
{
    /// A stand-in add-on keeping lists and settings as the stand-in gateway does (an empty id is a new list).
    private sealed class AddOn
    {
        public JsonArray Sections = [];
        public JsonObject Settings = new()
        {
            ["enabled"] = true, ["capture"] = "ask", ["prep_per_day"] = 6, ["quiet_start"] = "22:00", ["quiet_end"] = "08:00",
            ["prep_every_hours"] = 3, ["group"] = "smart", ["sort"] = "smart", ["ideas"] = false, ["ideas_bot"] = "default",
            ["ideas_at"] = "07:30", ["ideas_max"] = 3,
        };
        public JsonArray Tasks = [];
        public bool FailSections, FailSettings, Lists = true;
        private int _made;
        public FakeRest Rest => _rest ??= new FakeRest(Answer);
        private FakeRest? _rest;

        private JsonNode? Answer(FakeRest.Request r)
        {
            switch (r.Method, r.Path)
            {
                case ("GET", TasksApi.Base):
                    return new JsonObject
                    {
                        ["rev"] = 1, ["tasks"] = Tasks.DeepClone(), ["sections"] = Sections.DeepClone(), ["settings"] = Settings.DeepClone(),
                        ["fields"] = true, ["lists"] = Lists,
                    };
                case ("PUT", TasksApi.Base + "/sections"):
                    if (FailSections) throw FakeRest.Http(500, "disk full");
                    var saved = new JsonArray();
                    foreach (var s in r.Body.Arr("sections")!)
                    {
                        var row = (JsonObject)s!.DeepClone();
                        if (row.Str("id") is null or "") row["id"] = "sec_" + ++_made;
                        saved.Add(row);
                    }
                    var kept = saved.Select(s => s.Str("id")).ToHashSet();
                    foreach (var t in Tasks) if (t.Str("section") is { } id && !kept.Contains(id)) t!["section"] = null;
                    Sections = saved;
                    return new JsonObject { ["rev"] = 2, ["sections"] = saved.DeepClone() };
                case ("PUT", TasksApi.Base + "/settings"):
                    if (FailSettings) throw FakeRest.Http(500, "disk full");
                    foreach (var (k, v) in r.Body!.AsObject()) Settings[k] = v?.DeepClone();
                    return Settings.DeepClone();
                default:
                    return new JsonObject();
            }
        }
    }

    private static JsonObject Row(string id, string? section, string status = "open") =>
        new() { ["id"] = id, ["title"] = id, ["status"] = status, ["section"] = section, ["rev"] = 1, ["who"] = "me" };

    [Fact]
    public async Task NewListSendsEveryListWholeWithTheFirstFreeColourAndAnEmptyId()
    {
        var addOn = new AddOn { Sections = [new JsonObject { ["id"] = "sec_work", ["name"] = "Work", ["color"] = "blue", ["bot"] = "otto", ["adds"] = "ask", ["checked_at"] = "2026-11-20T08:00:00" }] };
        var store = new TasksStore(new TasksApi(addOn.Rest));
        await store.RefreshAsync();
        Assert.True(store.EditsLists && store.ListsSupported);
        Assert.Null(await store.AddSectionAsync("   "));   // a blank name adds nothing, and sends nothing
        Assert.DoesNotContain(addOn.Rest.Log, r => r.Method == "PUT");
        var made = await store.AddSectionAsync("  Errands  ");
        Assert.NotNull(made);
        Assert.Equal(("sec_1", "Errands", "green"), (made!.Id, made.Name, made.Color));
        var put = addOn.Rest.Log.Single(r => r.Method == "PUT").Body!;
        var lists = put.Arr("sections")!;
        Assert.Equal(2, lists.Count);
        // The kept list goes whole (its bot and Ask First), without the gateway's checked_at.
        Assert.Equal("""{"id":"sec_work","name":"Work","color":"blue","icon":"","bot":"otto","adds":"ask","today":true}""", lists[0]!.ToJsonString());
        Assert.Equal("""{"id":"","name":"Errands","color":"green","icon":"","bot":"","adds":"auto","today":true}""", lists[1]!.ToJsonString());
        Assert.Equal(["Work", "Errands"], store.Sections.Select(s => s.Name));
    }

    [Fact]
    public async Task AnOlderAddOnGetsNoColourAndOneWithoutSectionsIsAskedToUpdate()
    {
        var addOn = new AddOn { Lists = false };
        var store = new TasksStore(new TasksApi(addOn.Rest));
        await store.RefreshAsync();
        Assert.Null((await store.AddSectionAsync("Home"))!.Color);
        Assert.Equal("", addOn.Rest.Log.Single(r => r.Method == "PUT").Body.Arr("sections")![0].Str("color"));

        var none = new TasksStore(new TasksApi(new FakeRest(r => r.Method == "GET" ? new JsonObject { ["rev"] = 1, ["tasks"] = new JsonArray() } : null)));
        var notices = new List<string>();
        none.Notice += (t, _) => notices.Add(t);
        await none.RefreshAsync();
        Assert.False(none.EditsLists);
        Assert.Null(await none.AddSectionAsync("Home"));
        Assert.Equal(["Sections need the newest HQ add-on on your computer (0.9.36 or later)."], notices);
    }

    [Fact]
    public async Task RenameKeepsTheRestOfTheListAndCutsTheNameAtSixty()
    {
        var addOn = new AddOn { Sections = [new JsonObject { ["id"] = "a", ["name"] = "Home", ["color"] = "red", ["icon"] = "house" }, new JsonObject { ["id"] = "b", ["name"] = "Work" }] };
        var store = new TasksStore(new TasksApi(addOn.Rest));
        await store.RefreshAsync();
        Assert.True(await store.RenameSectionAsync("a", "  " + new string('x', 70) + " "));
        var sent = addOn.Rest.Log.Last(r => r.Method == "PUT").Body.Arr("sections")!;
        Assert.Equal((new string('x', 60), "red", "house"), (sent[0].Str("name"), sent[0].Str("color"), sent[0].Str("icon")));
        Assert.Equal("Work", sent[1].Str("name"));
        Assert.False(await store.RenameSectionAsync("a", " "));
        Assert.False(await store.RenameSectionAsync("gone", "X"));
        Assert.True(await store.MoveSectionAsync("b", -1));
        Assert.Equal(["b", "a"], store.Sections.Select(s => s.Id));
        Assert.False(await store.MoveSectionAsync("b", -1));   // the first has no Move Left
    }

    [Fact]
    public async Task DeleteListKeepsItsTasksInNoListAndComesBackWhenRefused()
    {
        var addOn = new AddOn
        {
            Sections = [new JsonObject { ["id"] = "a", ["name"] = "Home" }, new JsonObject { ["id"] = "b", ["name"] = "Work" }],
            Tasks = [Row("t1", "a"), Row("t2", "a", "done"), Row("t3", "b")],
        };
        var store = new TasksStore(new TasksApi(addOn.Rest));
        var notices = new List<string>();
        store.Notice += (t, _) => notices.Add(t);
        await store.RefreshAsync();

        addOn.FailSections = true;
        var shown = new List<string?>();
        store.Changed += () => shown.Add(store.Find("t1")?.Section);
        Assert.False(await store.DeleteSectionAsync("a"));
        Assert.Contains(null, shown);   // its tasks showed in no list at once
        Assert.Equal(["a", "b"], store.Sections.Select(s => s.Id));   // and everything is back
        Assert.Equal("a", store.Find("t1")!.Section);
        Assert.Equal(["Couldn’t save your sections. disk full"], notices);

        addOn.FailSections = false;
        Assert.True(await store.DeleteSectionAsync("a"));
        Assert.Equal(["b"], store.Sections.Select(s => s.Id));
        Assert.Equal((null, null, "b"), (store.Find("t1")!.Section, store.Find("t2")!.Section, store.Find("t3")!.Section));
        Assert.Equal(3, store.Tasks.Count);   // no task deleted
        Assert.Equal([new JsonObject { ["id"] = "b", ["name"] = "Work", ["color"] = "", ["icon"] = "", ["bot"] = "", ["adds"] = "auto", ["today"] = true }.ToJsonString()],
            addOn.Rest.Log.Last(r => r.Method == "PUT").Body.Arr("sections")!.Select(s => s!.ToJsonString()));
        store.ReadOnlyGateway = true;
        Assert.False(store.EditsLists);
        Assert.False(await store.DeleteSectionAsync("b"));
        Assert.Equal(KanbanRest.ReadOnlyNotice, notices.Last());
    }

    [Fact]
    public void TheMacsWords()
    {
        Assert.Null(TodoListCopy.DeleteMessage(0, 0));
        Assert.Equal("Its task is kept, in no list.", TodoListCopy.DeleteMessage(1, 0));
        Assert.Equal("Its done task is kept, in no list.", TodoListCopy.DeleteMessage(0, 1));
        Assert.Equal("Its 3 tasks are kept, in no list.", TodoListCopy.DeleteMessage(3, 0));
        Assert.Equal("Its 2 done tasks are kept, in no list.", TodoListCopy.DeleteMessage(0, 2));
        Assert.Equal("Its 1 task and 1 done task are kept, in no list.", TodoListCopy.DeleteMessage(1, 1));
        Assert.Equal("Its 4 tasks and 2 done tasks are kept, in no list.", TodoListCopy.DeleteMessage(4, 2));
        Assert.Equal("Delete “Home”?", TodoListCopy.DeleteTitle("Home"));
        Assert.Equal("Group your tasks your way, like Home, Work or Errands.", TodoListCopy.NewListMessage);
        Assert.Equal([TodoListMenuItem.EditList, TodoListMenuItem.Rename, TodoListMenuItem.MoveRight, TodoListMenuItem.Divider, TodoListMenuItem.DeleteList],
            TodoListCopy.Menu(0, 3));
        Assert.Equal(["Edit List…", "Rename…", "Move Left", "Move Right", "", "Delete List…"], TodoListCopy.Menu(1, 3).Select(TodoListCopy.Title));
        Assert.Equal([TodoListMenuItem.EditList, TodoListMenuItem.Rename, TodoListMenuItem.Divider, TodoListMenuItem.DeleteList], TodoListCopy.Menu(0, 1));
        Assert.Equal("purple", TodoListColors.Next([new("a", "A") { Color = "blue" }, new("b", "B") { Color = "green" }, new("c", "C") { Color = "orange" }, new("d", "D") { Color = "red" }]));
        Assert.Equal("blue", TodoListColors.Next(TodoListColors.All.Select(c => new TodoUserSection(c, c) { Color = c })));
        Assert.Equal(["Ask First", "Automatic", "Off"], TodoSettingsCopy.CaptureOptions.Select(o => o.Title));
        Assert.Equal("Bots add tasks only when you ask them to.", TodoSettingsCopy.CaptureFooter("off"));
        Assert.StartsWith("When you say you need to do something, a bot asks", TodoSettingsCopy.CaptureFooter("ask"));
        Assert.Equal(("Never", "6", "Up to 3"), (TodoSettingsCopy.PerDay(0), TodoSettingsCopy.PerDay(6), TodoSettingsCopy.UpTo(3)));
        Assert.Equal(new TimeSpan(7, 30, 0), TodoSettingsCopy.Time("07:30"));
        Assert.Equal("22:05", TodoSettingsCopy.Text(new TimeSpan(22, 5, 0)));
        Assert.Equal(TimeSpan.Zero, TodoSettingsCopy.Time("soon"));
    }

    [Fact]
    public async Task EachSettingSavesTheWholeSettingsUnderItsKeyAndComesBackWhenRefused()
    {
        var addOn = new AddOn();
        var store = new TasksStore(new TasksApi(addOn.Rest));
        var notices = new List<string>();
        store.Notice += (t, _) => notices.Add(t);
        await store.RefreshAsync();
        var model = new TodoSettingsModel(store, [("default", "Hermes"), ("otto", "Otto")]);
        var ideasSaved = 0;
        model.IdeasChanged += () => ideasSaved++;
        Assert.True(model.ShowsIdeas);
        Assert.False(model.ShowsWhoLooks);   // only while Suggest Tasks is on
        Assert.True(await model.CommitAsync());
        Assert.DoesNotContain(addOn.Rest.Log, r => r.Method == "PUT");   // nothing changed, nothing sent

        Assert.True(await model.SetCapture("auto"));
        Assert.True(await model.SetPrepPerDay(30));   // the stepper stops at 24
        Assert.True(await model.SetQuietStart(new TimeSpan(21, 15, 0)));
        Assert.True(await model.SetQuietEnd(new TimeSpan(7, 0, 0)));
        Assert.Equal(0, ideasSaved);
        Assert.True(await model.SetIdeas(true));
        Assert.True(model.ShowsWhoLooks);
        Assert.True(await model.SetIdeasBot("otto"));
        Assert.True(await model.SetIdeasAt(new TimeSpan(6, 45, 0)));
        Assert.True(await model.SetIdeasMax(0));   // and this one at 1
        Assert.Equal(4, ideasSaved);
        var puts = addOn.Rest.Log.Where(r => r.Method == "PUT").Select(r => r.Body!).ToList();
        Assert.Equal(8, puts.Count);
        Assert.All(puts, p => Assert.Equal(12, p.AsObject().Count));   // every save carries the whole settings
        var last = puts[^1];
        Assert.Equal(("auto", 24, "21:15", "07:00", true, "otto", "06:45", 1),
            (last.Str("capture"), (int)last.Int("prep_per_day")!, last.Str("quiet_start"), last.Str("quiet_end"), last.Bool("ideas"), last.Str("ideas_bot"), last.Str("ideas_at"), (int)last.Int("ideas_max")!));
        Assert.Equal("Otto", model.BotName(model.Looker));
        Assert.Equal("auto", store.Settings.Capture);

        addOn.FailSettings = true;
        Assert.False(await model.SetCapture("off"));
        Assert.Equal("auto", model.Draft.Capture);   // the control is back to what the gateway keeps
        Assert.Equal("auto", store.Settings.Capture);
        Assert.Equal(["Couldn’t save Tasks settings. disk full"], notices);
    }

    [Fact]
    public async Task AnAddOnWithoutIdeasHidesItAndNeverSendsIt()
    {
        var addOn = new AddOn();
        foreach (var k in new[] { "ideas", "ideas_bot", "ideas_at", "ideas_max" }) addOn.Settings.Remove(k);
        var store = new TasksStore(new TasksApi(addOn.Rest));
        await store.RefreshAsync();
        var model = new TodoSettingsModel(store, []);
        Assert.False(model.ShowsIdeas);
        Assert.True(await model.SetPrepPerDay(0));
        var put = addOn.Rest.Log.Single(r => r.Method == "PUT").Body!.AsObject();
        Assert.Equal(["enabled", "capture", "prep_per_day", "quiet_start", "quiet_end", "prep_every_hours", "group", "sort"], put.Select(p => p.Key));
        Assert.Equal(0, put.Int("prep_per_day"));
    }
}
