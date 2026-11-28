// Wave 5A parity tests for Tasks & Goals upgrades:
// TodoQuickParse, TasksNavigationLayout, TodoWords.RepeatLabel custom repeats, TodoSections.Filtered,
// TodoViews (Suggested, Logbook, DayGroups, DayEmptyText, WeekRangeTitle, RescheduledDue, AllTags, AskActionLinks,
// AsksYou, Today priority-first default sort, paused-goal exclusion from Next in <List>),
// TasksStore (offline queue + add-folding + FIFO replay + disk cache + 3-way step merge + Duplicate/Reschedule/
// SetPriority/SetGoalBatch/MoveStep/ReorderStep/SetStepWho/EditStep/DeleteStep/PromoteStep/ReconcilePrep/
// AcceptSuggestedTitle/EditGoalMilestone/MoveGoalMilestone/ApplyTasksChangedEvent/Forget),
// and TodoCloseCards / TodoTaskStates.

using System.Net.Http;
using System.Text.Json.Nodes;
using Hermes.Core.Kanban;
using Hermes.Core.Net;
using Hermes.Core.Tasks;

namespace Hermes.Core.Tests.Tasks;

public sealed class TasksAndGoalsUpgradesParityTests
{
    private static readonly TimeZoneInfo Chicago = TimeZoneInfo.FindSystemTimeZoneById("America/Chicago");
    /// Wednesday, November 4, 2026 at 09:41 local (America/Chicago, UTC-6).
    private static readonly DateTimeOffset Now = new(2026, 11, 4, 9, 41, 0, TimeSpan.FromHours(-6));

    private static string TempDir()
    {
        var dir = Path.Combine(Path.GetTempPath(), "HermesTasksParityTests_" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        return dir;
    }

    private static JsonObject TaskJson(
        string id,
        int rev = 1,
        string title = "Task",
        string who = "me",
        string? bot = null,
        string status = "open",
        string? due = null,
        string? section = null,
        int priority = 0,
        string[]? tags = null,
        string? starts = null,
        string? goal = null,
        string? milestone = null,
        string? doneAt = null,
        string? statusNote = null,
        string? suggestedTitle = null,
        string? suggestedForTitle = null,
        JsonArray? steps = null,
        JsonArray? choices = null,
        JsonArray? made = null,
        JsonObject? offer = null,
        bool prep = false,
        double position = 0)
    {
        var o = new JsonObject
        {
            ["id"] = id,
            ["rev"] = rev,
            ["title"] = title,
            ["who"] = who,
            ["status"] = status,
            ["priority"] = priority,
            ["prep"] = prep,
            ["position"] = position,
            ["created_at"] = "2026-11-01T08:00:00-06:00",
            ["updated_at"] = "2026-11-04T08:00:00-06:00",
            ["steps"] = steps ?? new JsonArray(),
        };
        if (bot != null) o["bot"] = bot;
        if (due != null) o["due"] = due;
        if (section != null) o["section"] = section;
        if (tags != null) o["tags"] = new JsonArray([.. tags.Select(t => (JsonNode)t)]);
        if (starts != null) o["starts"] = starts;
        if (goal != null) o["goal"] = goal;
        if (milestone != null) o["milestone"] = milestone;
        if (doneAt != null) o["done_at"] = doneAt;
        if (statusNote != null) o["status_note"] = statusNote;
        if (suggestedTitle != null) o["suggested_title"] = suggestedTitle;
        if (suggestedForTitle != null) o["suggested_for_title"] = suggestedForTitle;
        if (choices != null) o["choices"] = choices.DeepClone();
        if (made != null) o["made"] = made.DeepClone();
        if (offer != null) o["offer"] = offer.DeepClone();
        return o;
    }

    // ------------------------------------------------------------------ 1. TodoQuickParse

    [Fact]
    public void QuickParseReadsRelativeAndCalendarDatesAndTimes()
    {
        var t1 = TodoQuickParse.Read("Call mom tomorrow at 9:30 pm", Now, Chicago);
        Assert.Equal("Call mom", t1.Title);
        Assert.True(t1.HasTime);
        Assert.Equal(new DateTime(2026, 11, 5, 21, 30, 0), TimeZoneInfo.ConvertTime(t1.Due!.Value, Chicago).DateTime);

        var t2 = TodoQuickParse.Read("Dentist tmrw 9:30a", Now, Chicago);
        Assert.Equal("Dentist", t2.Title);
        Assert.True(t2.HasTime);
        Assert.Equal(new DateTime(2026, 11, 5, 9, 30, 0), TimeZoneInfo.ConvertTime(t2.Due!.Value, Chicago).DateTime);

        var t3 = TodoQuickParse.Read("Renew tags in 3 days", Now, Chicago);
        Assert.Equal("Renew tags", t3.Title);
        Assert.False(t3.HasTime);
        Assert.Equal(new DateTime(2026, 11, 7), TodoDates.LocalDay(t3.Due!.Value, Chicago));

        var t4 = TodoQuickParse.Read("Audit in two weeks", Now, Chicago);
        Assert.Equal("Audit", t4.Title);
        Assert.Equal(new DateTime(2026, 11, 18), TodoDates.LocalDay(t4.Due!.Value, Chicago));

        var t5 = TodoQuickParse.Read("Ship release may 3", Now, Chicago);
        Assert.Equal("Ship release", t5.Title);
        Assert.Equal(new DateTime(2027, 5, 3), TodoDates.LocalDay(t5.Due!.Value, Chicago));

        var t6 = TodoQuickParse.Read("Submit form 3rd may", Now, Chicago);
        Assert.Equal("Submit form", t6.Title);
        Assert.Equal(new DateTime(2027, 5, 3), TodoDates.LocalDay(t6.Due!.Value, Chicago));

        var t7 = TodoQuickParse.Read("Tax prep 11/20", Now, Chicago);
        Assert.Equal("Tax prep", t7.Title);
        Assert.Equal(new DateTime(2026, 11, 20), TodoDates.LocalDay(t7.Due!.Value, Chicago));

        var t8 = TodoQuickParse.Read("Lease renewal 11/20/26", Now, Chicago);
        Assert.Equal("Lease renewal", t8.Title);
        Assert.Equal(new DateTime(2026, 11, 20), TodoDates.LocalDay(t8.Due!.Value, Chicago));

        // Time-only in the past (9am < 9:41am) rolls forward to tomorrow; future time stays today.
        var pastTime = TodoQuickParse.Read("Standup 9am", Now, Chicago);
        Assert.Equal("Standup", pastTime.Title);
        Assert.True(pastTime.HasTime);
        Assert.Equal(new DateTime(2026, 11, 5, 9, 0, 0), TimeZoneInfo.ConvertTime(pastTime.Due!.Value, Chicago).DateTime);

        var futureTime = TodoQuickParse.Read("Call bank 17:00", Now, Chicago);
        Assert.Equal("Call bank", futureTime.Title);
        Assert.Equal(new DateTime(2026, 11, 4, 17, 0, 0), TimeZoneInfo.ConvertTime(futureTime.Due!.Value, Chicago).DateTime);

        var atFive = TodoQuickParse.Read("Dinner at 5", Now, Chicago);
        Assert.Equal("Dinner", atFive.Title);
        Assert.Equal(new DateTime(2026, 11, 4, 17, 0, 0), TimeZoneInfo.ConvertTime(atFive.Due!.Value, Chicago).DateTime);

        var noon = TodoQuickParse.Read("Lunch at noon", Now, Chicago);
        Assert.Equal("Lunch", noon.Title);
        Assert.Equal(new DateTime(2026, 11, 4, 12, 0, 0), TimeZoneInfo.ConvertTime(noon.Due!.Value, Chicago).DateTime);

        var tonight = TodoQuickParse.Read("Read book tonight", Now, Chicago);
        Assert.Equal("Read book", tonight.Title);
        Assert.Equal(new DateTime(2026, 11, 4, 20, 0, 0), TimeZoneInfo.ConvertTime(tonight.Due!.Value, Chicago).DateTime);
    }

    [Fact]
    public void QuickParseReadsRepeatsTagsPrioritiesAndAvoidsFalsePositives()
    {
        var r1 = TodoQuickParse.Read("Take vitamins every day 8am #health #Health !high", Now, Chicago);
        Assert.Equal("Take vitamins", r1.Title);
        Assert.Equal("daily", r1.RepeatRule);
        Assert.Equal(1, r1.Priority);
        Assert.Equal(["health"], r1.Tags);
        Assert.True(r1.HasTime);

        var r2 = TodoQuickParse.Read("Clean filter every sun p2 #Home", Now, Chicago);
        Assert.Equal("Clean filter", r2.Title);
        Assert.Equal("weekly", r2.RepeatRule);
        Assert.Equal(2, r2.Priority);
        Assert.Equal(["Home"], r2.Tags);
        Assert.Equal(DayOfWeek.Sunday, TodoDates.LocalDay(r2.Due!.Value, Chicago).DayOfWeek);

        var r3 = TodoQuickParse.Read("Budget review weekly p3", Now, Chicago);
        Assert.Equal("Budget review", r3.Title);
        Assert.Equal("weekly", r3.RepeatRule);
        Assert.Equal(3, r3.Priority);

        var r4 = TodoQuickParse.Read("Clear flag p4", Now, Chicago);
        Assert.Equal("Clear flag", r4.Title);
        Assert.Equal(0, r4.Priority);

        var r5 = TodoQuickParse.Read("No priority !none", Now, Chicago);
        Assert.Equal("No priority", r5.Title);
        Assert.Equal(0, r5.Priority);

        // False-positive guards matching TodoQuickParse.swift:
        Assert.Null(TodoQuickParse.Read("Buy sun cream", Now, Chicago).Due);
        Assert.Null(TodoQuickParse.Read("Study for SAT", Now, Chicago).Due);
        Assert.Null(TodoQuickParse.Read("Buy 1/2 gallon milk", Now, Chicago).Due);
        Assert.Null(TodoQuickParse.Read("Buy 2a fuses", Now, Chicago).Due);
        Assert.Null(TodoQuickParse.Read("Send weekly report", Now, Chicago).RepeatRule);

        // All-date-only text keeps literal title rather than returning an empty title
        var dateOnly = TodoQuickParse.Read("tomorrow", Now, Chicago);
        Assert.Equal("tomorrow", dateOnly.Title);

        // keepLiteral skips all stripping
        var lit = TodoQuickParse.Read("Call mom tomorrow !high #family", Now, Chicago, keepLiteral: true);
        Assert.Equal("Call mom tomorrow !high #family", lit.Title);
        Assert.Null(lit.Due);
        Assert.Null(lit.Priority);
        Assert.Empty(lit.Tags);

        // Goal mode: strips leading "by"/"before"/"until" with date, ignores time/priority/tags
        var goal = TodoQuickParse.Read("Run a 10K by may 3 #1 p1 9am", Now, Chicago, goal: true);
        Assert.Equal("Run a 10K #1 p1 9am", goal.Title);
        Assert.Equal(new DateTime(2027, 5, 3), TodoDates.LocalDay(goal.Due!.Value, Chicago));
        Assert.False(goal.HasTime);
        Assert.Null(goal.Priority);
        Assert.Empty(goal.Tags);
    }

    // ------------------------------------------------------------------ 2. TasksNavigationLayout

    [Fact]
    public void TasksNavigationLayoutConstantsAndModelsMatchMac()
    {
        Assert.Equal(216, TasksNavigationLayout.SidebarWidth);
        Assert.Equal(640, TasksNavigationLayout.SidebarMinPaneWidth);
        Assert.Equal(760, TasksNavigationLayout.TableMinContentWidth);
        Assert.Equal(3, TasksNavigationLayout.OverviewSuggestedLimit);

        Assert.True(TasksNavigationLayout.ShouldShowSidebar(true, 640, false, true, false));
        Assert.False(TasksNavigationLayout.ShouldShowSidebar(true, 639, false, true, false));
        Assert.False(TasksNavigationLayout.ShouldShowSidebar(true, 900, true, true, false));
        Assert.False(TasksNavigationLayout.ShouldShowSidebar(true, 900, false, false, false));
        Assert.False(TasksNavigationLayout.ShouldShowSidebar(true, 900, false, true, true));

        Assert.True(TasksNavigationLayout.ShouldUseTable(true, 760));
        Assert.False(TasksNavigationLayout.ShouldUseTable(true, 759));

        var sections = new[] { new TodoUserSection("work", "Work") { Icon = "briefcase" } };
        Assert.Equal("Suggested", TasksNavigationLayout.Title(TodoView.Suggested, sections));
        Assert.Equal("sparkle", TasksNavigationLayout.Symbol(TodoView.Suggested, sections));
        Assert.Equal("Work", TasksNavigationLayout.Title(TodoView.List("work"), sections));
        Assert.Equal("briefcase", TasksNavigationLayout.Symbol(TodoView.List("work"), sections));

        var tile = new TasksSmartTileModel(TodoView.Goals, "Goals", "smallcircle.filled.circle", 2);
        Assert.Equal("tasks.view.goals", tile.Identifier);
        Assert.Equal("Goals, 2 goals", tile.Spoken);

        var sug = new TasksOverviewSuggestedRowModel(3, IsOn: true, Looking: false);
        Assert.Equal("Suggested, 3 ideas", sug.Spoken);
        var agents = new TasksOverviewAgentsModel(sug, 4);
        Assert.False(agents.IsEmpty);
        Assert.Equal("Bots’ Tasks, 4 tasks", agents.BotsSpoken);
    }

    // ------------------------------------------------------------------ 3. TodoWords.RepeatLabel & TodoSections.Filtered & TodoViews

    [Fact]
    public void RepeatLabelHandlesStandardAndCustomEveryAfterRules()
    {
        Assert.Equal("Every Day", TodoWords.RepeatLabel("daily"));
        Assert.Equal("Every Day", TodoWords.RepeatLabel("every:1:day"));
        Assert.Equal("Every 2 Weeks", TodoWords.RepeatLabel("every:2:weeks"));
        Assert.Equal("Every 3 Months", TodoWords.RepeatLabel("every:3:months"));
        Assert.Equal("Every Year", TodoWords.RepeatLabel("every:1:year"));
        Assert.Equal("1 Week After Completion", TodoWords.RepeatLabel("after:1:week"));
        Assert.Equal("3 Days After Completion", TodoWords.RepeatLabel("after:3:days"));
        Assert.Equal("Never", TodoWords.RepeatLabel("custom_unknown"));
        Assert.Equal("every:bad", TodoWords.RepeatLabel("every:bad"));
    }

    [Fact]
    public void FilteredAppliesPriorityTagScopeAndQueryTogether()
    {
        var goals = new[]
        {
            Goal.From(new JsonObject
            {
                ["id"] = "g1",
                ["title"] = "Marathon",
                ["milestones"] = new JsonArray(new JsonObject { ["id"] = "m1", ["title"] = "Base Miles" }),
            })!,
        };
        var tasks = new[]
        {
            TodoTask.From(TaskJson("t1", title: "Buy shoes", priority: 1, tags: ["Running", "gear"], goal: "g1", milestone: "m1"))!,
            TodoTask.From(TaskJson("t2", title: "Book flight", priority: 2, tags: ["travel"], who: "together", bot: "ivy"))!,
            TodoTask.From(TaskJson("t3", title: "Track pace", priority: 1, tags: ["running"], who: "together", bot: "ivy"))!,
        };

        Assert.Equal(["t1", "t3"], TodoSections.Filtered(tasks, "", goals, priority: 1).Select(t => t.Id));
        Assert.Equal(["t1", "t3"], TodoSections.Filtered(tasks, "", goals, tag: "RUNNING").Select(t => t.Id));
        Assert.Equal(["t1"], TodoSections.Filtered(tasks, "", goals, priority: 1, tag: "running", scope: "@me").Select(t => t.Id));
        Assert.Equal(["t3"], TodoSections.Filtered(tasks, "", goals, priority: 1, scope: "ivy").Select(t => t.Id));
        Assert.Equal(["t1"], TodoSections.Filtered(tasks, "Base Miles", goals).Select(t => t.Id));
        Assert.Equal(["t1"], TodoSections.Filtered(tasks, "#ge", goals).Select(t => t.Id));
    }

    [Fact]
    public void ViewsCoverSuggestedLogbookDayGroupsRescheduleTagsAskLinksPrioritySortAndPausedGoals()
    {
        Assert.Equal(TodoView.Suggested, TodoView.FromKey("suggested"));

        // Logbook buckets
        var doneTasks = new[]
        {
            TodoTask.From(TaskJson("d_today", title: "Shipped today", status: "done", doneAt: "2026-11-04T09:00:00-06:00"))!,
            TodoTask.From(TaskJson("d_yest", title: "Done yesterday", status: "done", doneAt: "2026-11-03T15:00:00-06:00"))!,
            TodoTask.From(TaskJson("d_week", title: "Done this week", status: "done", doneAt: "2026-11-01T12:00:00-06:00"))!,
            TodoTask.From(TaskJson("d_oct", title: "Done in October", status: "done", doneAt: "2026-10-12T12:00:00-05:00"))!,
            TodoTask.From(TaskJson("open_1", title: "Not done", status: "open"))!,
        };
        var logbook = TodoViews.Logbook(doneTasks, "", Now, Chicago);
        Assert.Equal(["Today", "Yesterday", "This Week", "October 2026"], logbook.Select(g => g.Title));
        Assert.Single(TodoViews.Logbook(doneTasks, "October", Now, Chicago));

        // WeekRangeTitle
        var sameMonth = Enumerable.Range(0, 7).Select(i => new DateTimeOffset(2026, 11, 4 + i, 0, 0, 0, TimeSpan.FromHours(-6))).ToList();
        Assert.Equal("November 2026", TodoViews.WeekRangeTitle(sameMonth, Chicago));
        var crossMonth = Enumerable.Range(0, 7).Select(i => new DateTimeOffset(2026, 11, 28, 0, 0, 0, TimeSpan.FromHours(-6)).AddDays(i)).ToList();
        Assert.Equal("Nov – Dec 2026", TodoViews.WeekRangeTitle(crossMonth, Chicago));
        var crossYear = Enumerable.Range(0, 7).Select(i => new DateTimeOffset(2026, 12, 29, 0, 0, 0, TimeSpan.FromHours(-6)).AddDays(i)).ToList();
        Assert.Equal("Dec 2026 – Jan 2027", TodoViews.WeekRangeTitle(crossYear, Chicago));

        // RescheduledDue preserves clock time when present
        var timed = TodoTask.From(TaskJson("timed", due: "2026-11-04T14:30:00-06:00"))!;
        var newDay = new DateTimeOffset(2026, 11, 10, 0, 0, 0, TimeSpan.FromHours(-6));
        var resched = TodoViews.RescheduledDue(timed, newDay, Chicago, preserveTime: true);
        var parsedResched = TodoDates.Due(resched, Chicago)!.Value;
        Assert.True(parsedResched.HasTime);
        Assert.Equal(new DateTime(2026, 11, 10, 14, 30, 0), TimeZoneInfo.ConvertTime(parsedResched.Date, Chicago).DateTime);

        var dateOnly = TodoTask.From(TaskJson("dayonly", due: "2026-11-04"))!;
        Assert.Equal("2026-11-10", TodoViews.RescheduledDue(dateOnly, newDay, Chicago, preserveTime: true));

        // DayGroups & DayEmptyText
        var upcomingTasks = new[]
        {
            TodoTask.From(TaskJson("u1", due: "2026-11-04"))!,
            TodoTask.From(TaskJson("u2", due: "2026-11-06"))!,
        };
        Assert.Equal(["u1"], TodoViews.DayGroups(upcomingTasks, "2026-11-04", [], [], Now, Chicago).SelectMany(g => g.Tasks).Select(t => t.Id));
        Assert.Equal(["u2"], TodoViews.DayGroups(upcomingTasks, "2026-11-06", [], [], Now, Chicago).SelectMany(g => g.Tasks).Select(t => t.Id));
        Assert.Equal("Nothing due today.", TodoViews.DayEmptyText("2026-11-04", Now, Chicago));
        Assert.Contains("Nov 7", TodoViews.DayEmptyText("2026-11-07", Now, Chicago));

        // AllTags: frequency desc then alphabetical, case-insensitive dedup
        var tagged = new[]
        {
            TodoTask.From(TaskJson("a1", tags: ["beta", "alpha"]))!,
            TodoTask.From(TaskJson("a2", tags: ["ALPHA", "gamma"]))!,
            TodoTask.From(TaskJson("a3", tags: ["beta"]))!,
        };
        Assert.Equal(["alpha", "beta", "gamma"], TodoViews.AllTags(tagged));

        // AskActionLinks & AsksYou & CurrentSuggestedTitle
        var botLinks = new JsonArray(
            new JsonObject { ["id"] = "m1", ["title"] = "Approve Stripe Invoice", ["kind"] = "link", ["ref"] = "https://stripe.com/inv/1", ["by"] = "ivy" },
            new JsonObject { ["id"] = "m2", ["title"] = "User Doc", ["kind"] = "link", ["ref"] = "https://docs.example.com/1", ["by"] = "you" },
            new JsonObject { ["id"] = "m3", ["title"] = "Calendar Slot", ["kind"] = "link", ["ref"] = "https://cal.example.com/slot", ["by"] = "ivy" });
        var askNoChoices = TodoTask.From(TaskJson("ask1", who: "together", bot: "ivy", status: "needs_you", statusNote: "Ready for approval", made: botLinks))!;
        Assert.True(TodoViews.AsksYou(askNoChoices));
        Assert.Equal(["m3", "m1"], TodoViews.AskActionLinks(askNoChoices).Select(m => m.Id));

        var askWithChoices = TodoTask.From(TaskJson(
            "ask2",
            who: "together",
            bot: "ivy",
            status: "needs_you",
            statusNote: "Please approve the Stripe invoice before Friday",
            choices: new JsonArray("Approve", "Decline"),
            made: botLinks,
            suggestedTitle: "Approve Q4 Stripe Invoice",
            suggestedForTitle: "Task"))!;
        Assert.Equal(["m1"], TodoViews.AskActionLinks(askWithChoices).Select(m => m.Id));
        Assert.Equal("Approve Q4 Stripe Invoice", TodoViews.CurrentSuggestedTitle(askWithChoices));

        // Today priority-first default sort + paused goal exclusion from Next in <List>
        var sections = new[] { new TodoUserSection("work", "Work") { InToday = true } };
        var todayTasks = new[]
        {
            TodoTask.From(TaskJson("p_none", due: "2026-11-04T09:00:00-06:00", priority: 0))!,
            TodoTask.From(TaskJson("p_low", due: "2026-11-04T10:00:00-06:00", priority: 3))!,
            TodoTask.From(TaskJson("p_high", due: "2026-11-04T18:00:00-06:00", priority: 1))!,
            TodoTask.From(TaskJson("p_med", due: "2026-11-04T12:00:00-06:00", priority: 2))!,
            TodoTask.From(TaskJson("next_active", section: "work", goal: "g_active"))!,
            TodoTask.From(TaskJson("next_paused", section: "work", goal: "g_paused"))!,
            TodoTask.From(TaskJson("dated_paused", due: "2026-11-04T19:00:00-06:00", section: "work", goal: "g_paused"))!,
        };
        var paused = new HashSet<string>(["g_paused"], StringComparer.Ordinal);
        var todayGroups = TodoViews.Groups(todayTasks, TodoView.Today, sections, [], Now, Chicago, sort: "smart", pausedGoals: paused);
        var todayIds = todayGroups.Single(g => g.Kind == TodoGroupKind.Today).Tasks.Select(t => t.Id).ToList();
        Assert.Equal(["p_high", "p_med", "p_low", "p_none", "dated_paused"], todayIds);
        var nextIds = todayGroups.Single(g => g.Kind == TodoGroupKind.Next("work")).Tasks.Select(t => t.Id).ToList();
        Assert.Equal(["next_active"], nextIds);
    }

    // ------------------------------------------------------------------ 4. TasksStore: Offline Queue, Add-Folding, FIFO Replay & Disk Cache

    [Fact]
    public async Task OfflineQueueFoldsPatchesCancelsLocalDeletePersistsAndReplaysFifoWithIdMap()
    {
        var dir = TempDir();
        try
        {
            var online = false;
            var serverNextId = 1;
            var serverTasks = new Dictionary<string, JsonObject>(StringComparer.Ordinal)
            {
                ["t_srv"] = TaskJson("t_srv", rev: 1, title: "Server task", priority: 0),
            };
            var rest = new FakeRest(r =>
            {
                if (!online) throw new HttpRequestException("offline");
                if (r.Method == "GET" && r.Path == TasksApi.Base)
                {
                    return new JsonObject
                    {
                        ["rev"] = 10,
                        ["fields"] = true,
                        ["goals"] = new JsonArray(),
                        ["tasks"] = new JsonArray([.. serverTasks.Values.Select(v => v.DeepClone())]),
                    };
                }
                if (r.Method == "POST" && r.Path == TasksApi.Base)
                {
                    var id = "t_created_" + serverNextId++;
                    var created = TaskJson(id, rev: 1, title: r.Body!.Str("title") ?? "Untitled", priority: (int)(r.Body!.Int("priority") ?? 0));
                    serverTasks[id] = created;
                    return created.DeepClone();
                }
                if (r.Method == "PATCH" && r.Path.StartsWith(TasksApi.Base + "/", StringComparison.Ordinal))
                {
                    var id = r.Path[(TasksApi.Base.Length + 1)..];
                    var cur = serverTasks[id];
                    foreach (var (k, v) in r.Body!.AsObject())
                        if (k != "rev") cur[k] = v?.DeepClone();
                    cur["rev"] = (int)(cur.Int("rev") ?? 1) + 1;
                    return cur.DeepClone();
                }
                if (r.Method == "DELETE" && r.Path.StartsWith(TasksApi.Base + "/", StringComparison.Ordinal))
                {
                    var id = r.Path[(TasksApi.Base.Length + 1)..];
                    serverTasks.Remove(id);
                    return new JsonObject { ["ok"] = true };
                }
                return new JsonObject();
            });

            // 1) Start online, fetch initial list so disk cache `tasks.json` is written.
            online = true;
            var store1 = new TasksStore(new TasksApi(rest), cacheDirectory: dir);
            await store1.RefreshAsync(force: true);
            Assert.True(File.Exists(Path.Combine(dir, "tasks.json")));

            // 2) Go offline: add local task A, patch A (folds into Add!), add local task B and delete B (cancels cleanly!),
            //    and patch server task twice (coalesces into one Patch op keeping earliest baseline!).
            online = false;
            var localA = await store1.AddAsync(TodoWire.NewTask("Draft spec", TodoWho.Me, null, null, null, false));
            Assert.NotNull(localA);
            Assert.True(TodoIds.IsLocal(localA!.Id));
            Assert.True(await store1.PatchAsync(localA.Id, new JsonObject { ["title"] = "Final spec", ["priority"] = 1 }));

            var localB = await store1.AddAsync(TodoWire.NewTask("Throwaway", TodoWho.Me, null, null, null, false));
            Assert.NotNull(localB);
            Assert.True(await store1.DeleteAsync(localB!.Id));
            Assert.Null(store1.Find(localB.Id));

            Assert.True(await store1.PatchAsync("t_srv", new JsonObject { ["title"] = "First edit" }));
            Assert.True(await store1.PatchAsync("t_srv", new JsonObject { ["title"] = "Second edit", ["priority"] = 2 }));

            // Expect only 2 pending ops on disk: 1 folded Add for localA, 1 coalesced Patch for t_srv (localB cancelled!).
            Assert.Equal(2, store1.PendingCount);
            Assert.True(File.Exists(Path.Combine(dir, "tasks-pending.json")));

            // 3) Simulate cold restart: fresh store paints cache + loads pending ops from disk before network.
            var store2 = new TasksStore(new TasksApi(rest), cacheDirectory: dir);
            store2.Prepare();
            Assert.True(store2.HasList);
            Assert.Equal(2, store2.PendingCount);
            Assert.Equal("Final spec", store2.Find(localA.Id)!.Title);

            // 4) Gateway reconnects -> GatewayReadyAsync replays FIFO, replaces local id, clears pending file.
            online = true;
            rest.Log.Clear();
            await store2.GatewayReadyAsync();
            Assert.Equal(0, store2.PendingCount);
            Assert.False(File.Exists(Path.Combine(dir, "tasks-pending.json")));
            Assert.Equal("Final spec", store2.Find("t_created_1")!.Title);
            Assert.Equal(1, store2.Find("t_created_1")!.Priority);
            Assert.Equal("Second edit", store2.Find("t_srv")!.Title);
            Assert.Equal(2, store2.Find("t_srv")!.Priority);
        }
        finally
        {
            try { Directory.Delete(dir, recursive: true); } catch (IOException) { }
        }
    }

    [Fact]
    public async Task OfflineFlushDropsPermanent422WithoutBlockingLaterOps()
    {
        var dir = TempDir();
        try
        {
            var online = false;
            var notices = new List<string>();
            var rest = new FakeRest(r =>
            {
                if (!online) throw new HttpRequestException("offline");
                if (r.Method == "POST" && r.Path == TasksApi.Base)
                {
                    if (r.Body!.Str("title") == "Bad op") throw FakeRest.Http(422, "invalid field");
                    return TaskJson("t_good", rev: 1, title: r.Body!.Str("title")!);
                }
                return new JsonObject { ["rev"] = 2, ["tasks"] = new JsonArray(TaskJson("t_good", rev: 1, title: "Good op")) };
            });

            var store = new TasksStore(new TasksApi(rest), cacheDirectory: dir);
            store.Notice += (msg, _) => notices.Add(msg);
            await store.AddAsync(TodoWire.NewTask("Bad op", TodoWho.Me, null, null, null, false));
            await store.AddAsync(TodoWire.NewTask("Good op", TodoWho.Me, null, null, null, false));
            Assert.Equal(2, store.PendingCount);

            online = true;
            await store.FlushPendingAsync();
            Assert.Equal(0, store.PendingCount);
            Assert.NotNull(store.Find("t_good"));
            Assert.Contains(notices, n => n.Contains("couldn\u2019t sync", StringComparison.OrdinalIgnoreCase));
        }
        finally
        {
            try { Directory.Delete(dir, recursive: true); } catch (IOException) { }
        }
    }

    // ------------------------------------------------------------------ 5. 3-Way Step Merge & Live 409 Step Merge

    [Fact]
    public async Task MergeStepsHandlesDisjointEditsConcurrentAddsConflictsAndLive409Retry()
    {
        var s1 = new TodoStep("s1", "Gather quotes", "me", false);
        var s2 = new TodoStep("s2", "Book venue", "bot", false);
        var @base = new[] { s1, s2 };

        // Disjoint step edits merge cleanly
        var current = new[] { s1 with { Done = true }, s2 };
        var ours = new[] { s1, s2 with { Title = "Book downtown venue" } };
        var merged = TasksStore.MergeSteps(@base, current, ours);
        Assert.NotNull(merged);
        Assert.True(merged![0].Done);
        Assert.Equal("Book downtown venue", merged[1].Title);

        // Same step, different fields merge cleanly
        var diffFields = TasksStore.MergeSteps(@base, [s1 with { Done = true }, s2], [s1 with { Who = "bot" }, s2]);
        Assert.NotNull(diffFields);
        Assert.True(diffFields![0].Done);
        Assert.Equal("bot", diffFields[0].Who);

        // Concurrent additions merge cleanly
        var s3 = new TodoStep("s3", "Remote step", "bot", false);
        var s4 = new TodoStep("s4", "Local step", "me", false);
        var adds = TasksStore.MergeSteps(@base, [s1, s2, s3], [s1, s2, s4]);
        Assert.Equal(["s1", "s2", "s3", "s4"], adds!.Select(s => s.Id));

        // Same-field clash returns null
        Assert.Null(TasksStore.MergeSteps(@base, [s1 with { Title = "A" }, s2], [s1 with { Title = "B" }, s2]));
        // Edit-vs-delete returns null
        Assert.Null(TasksStore.MergeSteps(@base, [s2], [s1 with { Done = true }, s2]));

        // Live 409 PATCH retries with merged steps!
        var retriedSteps = new List<JsonArray>();
        var rest = new FakeRest(r =>
        {
            if (r.Method == "GET")
            {
                return new JsonObject
                {
                    ["rev"] = 1,
                    ["tasks"] = new JsonArray(TaskJson("t1", rev: 1, steps: TodoWire.Steps(@base))),
                };
            }
            if (r.Method == "PATCH" && r.Body!.Int("rev") == 1)
            {
                throw new GatewayException("http", "409", 409,
                    new JsonObject
                    {
                        ["detail"] = new JsonObject
                        {
                            ["task"] = TaskJson("t1", rev: 2, steps: TodoWire.Steps(current)),
                        },
                    }.ToJsonString());
            }
            if (r.Method == "PATCH" && r.Body!.Int("rev") == 2)
            {
                retriedSteps.Add((JsonArray)r.Body!["steps"]!.DeepClone());
                return TaskJson("t1", rev: 3, steps: (JsonArray)r.Body!["steps"]!.DeepClone());
            }
            return new JsonObject();
        });

        var store = new TasksStore(new TasksApi(rest));
        await store.RefreshAsync(force: true);
        Assert.True(await store.EditStepAsync("t1", "s2", "Book downtown venue"));
        Assert.Single(retriedSteps);
        var live = store.Find("t1")!;
        Assert.Equal(3, live.Rev);
        Assert.True(live.Steps[0].Done);
        Assert.Equal("Book downtown venue", live.Steps[1].Title);
    }

    // ------------------------------------------------------------------ 6. TasksStore Actions: Duplicate, Reschedule, Steps, Promote, Prep, SuggestedTitle, Milestones

    [Fact]
    public async Task StoreSupportsDuplicateRescheduleBatchStepsPromotePrepSuggestedTitleAndMilestones()
    {
        var nextId = 1;
        var prepProfiles = new List<string>();
        var serverTasks = new Dictionary<string, JsonObject>(StringComparer.Ordinal)
        {
            ["t1"] = TaskJson(
                "t1",
                rev: 1,
                title: "Plan trip",
                who: "together",
                bot: "ivy",
                due: "2026-11-05T14:00:00-06:00",
                section: "travel",
                priority: 1,
                tags: ["vacation"],
                starts: "2026-11-04",
                goal: "g1",
                milestone: "m1",
                prep: true,
                suggestedTitle: "Plan Japan Trip",
                suggestedForTitle: "Plan trip",
                steps: new JsonArray(
                    new JsonObject { ["id"] = "s1", ["title"] = "Book flights", ["who"] = "bot", ["done"] = true },
                    new JsonObject { ["id"] = "s2", ["title"] = "Pack bags", ["who"] = "me", ["done"] = false })),
        };
        var serverGoals = new Dictionary<string, JsonObject>(StringComparer.Ordinal)
        {
            ["g1"] = new JsonObject
            {
                ["id"] = "g1",
                ["rev"] = 1,
                ["title"] = "Travel More",
                ["milestones"] = new JsonArray(
                    new JsonObject { ["id"] = "m1", ["title"] = "Spring", ["done"] = false },
                    new JsonObject { ["id"] = "m2", ["title"] = "Autumn", ["done"] = false }),
            },
        };

        var rest = new FakeRest(r =>
        {
            if (r.Method == "GET" && r.Path == TasksApi.Base)
            {
                return new JsonObject
                {
                    ["rev"] = 5,
                    ["fields"] = true,
                    ["sections"] = new JsonArray(new JsonObject { ["id"] = "travel", ["name"] = "Travel" }),
                    ["goals"] = new JsonArray([.. serverGoals.Values.Select(v => v.DeepClone())]),
                    ["goal_bots"] = true,
                    ["tasks"] = new JsonArray([.. serverTasks.Values.Select(v => v.DeepClone())]),
                };
            }
            if (r.Method == "POST" && r.Path == TasksApi.Base)
            {
                var id = "t_new_" + nextId++;
                var body = (JsonObject)r.Body!.DeepClone();
                body["id"] = id;
                body["rev"] = 1;
                body["status"] = "open";
                serverTasks[id] = body;
                return body.DeepClone();
            }
            if (r.Method == "PATCH" && r.Path.StartsWith(TasksApi.Base + "/", StringComparison.Ordinal))
            {
                var id = r.Path[(TasksApi.Base.Length + 1)..];
                var cur = serverTasks[id];
                foreach (var (k, v) in r.Body!.AsObject())
                    if (k != "rev") cur[k] = v?.DeepClone();
                cur["rev"] = (int)(cur.Int("rev") ?? 1) + 1;
                return cur.DeepClone();
            }
            if (r.Method == "PATCH" && r.Path.StartsWith(TasksApi.Route + "/goals/", StringComparison.Ordinal))
            {
                var gid = r.Path[(TasksApi.Route.Length + "/goals/".Length)..];
                var cur = serverGoals[gid];
                foreach (var (k, v) in r.Body!.AsObject())
                    if (k != "rev") cur[k] = v?.DeepClone();
                cur["rev"] = (int)(cur.Int("rev") ?? 1) + 1;
                return cur.DeepClone();
            }
            if (r.Method == "POST" && r.Path.StartsWith(TasksApi.Base + "/prep-job/", StringComparison.Ordinal))
            {
                prepProfiles.Add(r.Path[(TasksApi.Base.Length + "/prep-job/".Length)..]);
                return new JsonObject { ["ok"] = true };
            }
            return new JsonObject();
        });

        var store = new TasksStore(new TasksApi(rest));
        await store.RefreshAsync(force: true);

        // AcceptSuggestedTitleAsync: refuses stale, accepts matching
        Assert.False(await store.AcceptSuggestedTitleAsync("t1", "Wrong", "Plan trip"));
        Assert.True(await store.AcceptSuggestedTitleAsync("t1", "Plan Japan Trip", "Plan trip"));
        Assert.Equal("Plan Japan Trip", store.Find("t1")!.Title);

        // DuplicateAsync: clones fields, resets steps to unticked
        var dup = await store.DuplicateAsync("t1");
        Assert.NotNull(dup);
        Assert.Equal("Plan Japan Trip", dup!.Title);
        Assert.Equal(1, dup.Priority);
        Assert.Equal(["vacation"], dup.Tags);
        Assert.Equal("2026-11-04", dup.Starts);
        Assert.Equal("g1", dup.Goal);
        Assert.Equal(2, dup.Steps.Count);
        Assert.All(dup.Steps, s => Assert.False(s.Done));

        // RescheduleAsync preserving clock time + SetPriorityAsync + SetGoalBatchAsync
        var targetDay = new DateTimeOffset(2026, 11, 12, 0, 0, 0, TimeSpan.FromHours(-6));
        Assert.True(await store.RescheduleAsync(["t1"], targetDay, preserveTime: true, zone: Chicago));
        Assert.Equal(new DateTime(2026, 11, 12, 14, 0, 0), TimeZoneInfo.ConvertTime(TodoDates.Due(store.Find("t1")!.Due, Chicago)!.Value.Date, Chicago).DateTime);
        Assert.True(await store.SetPriorityAsync(["t1", dup.Id], 2));
        Assert.Equal(2, store.Find("t1")!.Priority);
        Assert.True(await store.SetGoalBatchAsync([dup.Id], "g1", "m2"));
        Assert.Equal("m2", store.Find(dup.Id)!.Milestone);

        // Step reorder, move, handoff, edit, promote ("Turn into Task")
        Assert.True(await store.MoveStepAsync("t1", "s2", -1));
        Assert.Equal(["s2", "s1"], store.Find("t1")!.Steps.Select(s => s.Id));
        Assert.True(await store.ReorderStepAsync("t1", "s2", "s1"));
        Assert.Equal(["s1", "s2"], store.Find("t1")!.Steps.Select(s => s.Id));
        Assert.True(await store.SetStepWhoAsync("t1", "s2", "bot"));
        Assert.Equal("bot", store.Find("t1")!.Steps[1].Who);

        var promoted = await store.PromoteStepAsync("t1", "s1");
        Assert.NotNull(promoted);
        Assert.Equal("Book flights", promoted!.Title);
        Assert.Equal(TodoWho.Bot, promoted.WhoKind);
        Assert.Equal("ivy", promoted.Helper);
        Assert.Equal("travel", promoted.Section);
        Assert.Equal("g1", promoted.Goal);
        Assert.Single(store.Find("t1")!.Steps);

        // ReconcilePrepAsync hits POST /tasks/prep-job/{profile}
        Assert.True(await store.ReconcilePrepAsync("ivy"));
        Assert.Contains("ivy", prepProfiles);

        // Goal milestone edit & reorder
        Assert.True(await store.EditGoalMilestoneAsync("g1", "m1", title: "Spring Trip", due: "2027-04-01"));
        Assert.Equal(("Spring Trip", "2027-04-01"), (store.FindGoal("g1")!.Milestones[0].Title, store.FindGoal("g1")!.Milestones[0].Due));
        Assert.True(await store.MoveGoalMilestoneAsync("g1", "m1", 1));
        Assert.Equal(["m2", "m1"], store.FindGoal("g1")!.Milestones.Select(m => m.Id));

        // Lifecycle helpers: SetVisible, SetForeground, ApplyTasksChangedEvent, Forget
        store.SetVisible(true);
        store.SetForeground(true);
        store.ApplyTasksChangedEvent();
        store.Forget();
        Assert.Empty(store.Tasks);
        Assert.False(store.HasList);
    }

    // ------------------------------------------------------------------ 7. TodoCloseCards & TodoTaskStates

    [Fact]
    public void CloseCardsStateMachineAndFromTasksUpdateMatchSwift()
    {
        var offer1 = new TodoCloseOffer("ivy", "Booked and confirmed", "2026-11-04T09:00:00Z", Kept: false);
        var offer2 = new TodoCloseOffer("ivy", "Updated confirmation", "2026-11-04T10:00:00Z", Kept: false);

        // Before gateway read, missing task resolves to null (avoids button flash)
        var unread = TodoTaskStates.Snapshot.Empty;
        Assert.Null(TodoCloseCards.State(asked: false, offer: offer1, id: "t1", newest: true, snapshot: unread));

        // After gateway read, missing task is Gone
        var readEmpty = unread with { Read = true };
        var gone = TodoCloseCards.State(false, offer1, "t1", true, readEmpty)!;
        Assert.Equal(TodoCloseCardState.Gone, gone.State);
        Assert.Equal("No longer on your list", TodoCloseCards.Words(gone));

        // Done offers Undo only when newest and writable
        var doneSnap = new TodoTaskStates.Snapshot(
            new Dictionary<string, TodoTaskStates.Entry> { ["t1"] = new(Done: true, Offer: null) },
            Read: true,
            ReadOnly: false,
            Reopened: new HashSet<string>());
        Assert.Equal(new TodoCloseCardResolution(TodoCloseCardState.Done, Undo: true), TodoCloseCards.State(false, offer1, "t1", newest: true, doneSnap));
        Assert.Equal(new TodoCloseCardResolution(TodoCloseCardState.Done, Undo: false), TodoCloseCards.State(false, offer1, "t1", newest: false, doneSnap));
        Assert.Equal(new TodoCloseCardResolution(TodoCloseCardState.Done, Undo: false), TodoCloseCards.State(false, offer1, "t1", newest: true, doneSnap with { ReadOnly = true }));

        // Waiting -> Kept -> Superseded (newer offer) -> Reopened
        var waitSnap = doneSnap with { Tasks = new Dictionary<string, TodoTaskStates.Entry> { ["t1"] = new(false, offer1) } };
        Assert.Equal(TodoCloseCardState.Waiting, TodoCloseCards.State(false, offer1, "t1", true, waitSnap)!.State);
        Assert.Null(TodoCloseCards.Words(TodoCloseCardState.Waiting));
        Assert.Equal(TodoCloseCardState.Settled, TodoCloseCards.State(false, offer1, "t1", newest: false, waitSnap)!.State);
        Assert.Equal(TodoCloseCardState.Reopened, TodoCloseCards.State(asked: true, offer: null, id: "t1", newest: true, waitSnap)!.State);

        var keptSnap = doneSnap with { Tasks = new Dictionary<string, TodoTaskStates.Entry> { ["t1"] = new(false, offer1 with { Kept = true }) } };
        Assert.Equal(TodoCloseCardState.Kept, TodoCloseCards.State(false, offer1, "t1", true, keptSnap)!.State);

        var supersededSnap = doneSnap with { Tasks = new Dictionary<string, TodoTaskStates.Entry> { ["t1"] = new(false, offer2) } };
        Assert.Equal(TodoCloseCardState.Settled, TodoCloseCards.State(false, offer1, "t1", true, supersededSnap)!.State);
        Assert.True(TodoCloseCards.Newer(offer2.At, offer1.At));
        Assert.False(TodoCloseCards.Newer(offer1.At, offer2.At));

        var reopenedSnap = doneSnap with
        {
            Tasks = new Dictionary<string, TodoTaskStates.Entry> { ["t1"] = new(false, null) },
            Reopened = new HashSet<string>(["t1"]),
        };
        Assert.Equal(TodoCloseCardState.Reopened, TodoCloseCards.State(false, offer1, "t1", true, reopenedSnap)!.State);
        Assert.Equal(5, TodoCloseCards.AllWords.Count);

        // FromTasksUpdate parses both offer_done and status=done + asked=true
        var p1 = TodoCloseCards.FromTasksUpdate(
            args: new JsonObject { ["id"] = "t1", ["offer_done"] = "Sent the email" },
            result: new JsonObject { ["task"] = TaskJson("t1", title: "Email Alex", bot: "ivy") });
        Assert.NotNull(p1);
        Assert.False(p1!.Asked);
        Assert.Equal("Sent the email", p1.Offer!.Text);
        Assert.Equal("ivy", p1.Bot);

        var p2 = TodoCloseCards.FromTasksUpdate(
            args: new JsonObject { ["id"] = "t2", ["status"] = "done", ["asked"] = true },
            result: new JsonObject { ["task"] = TaskJson("t2", title: "Pay rent", status: "done", bot: "finance") });
        Assert.NotNull(p2);
        Assert.True(p2!.Asked);
        Assert.Null(p2.Offer);
        Assert.Equal("finance", p2.Bot);

        // Regular tasks_update without offer_done or asked returns null
        Assert.Null(TodoCloseCards.FromTasksUpdate(
            args: new JsonObject { ["id"] = "t3", ["title"] = "Rename" },
            result: new JsonObject { ["task"] = TaskJson("t3", title: "Rename") }));

        // TodoTaskStates singleton notifications
        TodoTaskStates.Forget();
        TodoTaskStates.Note([TodoTask.From(TaskJson("t9", status: "open"))!]);
        TodoTaskStates.NoteRead();
        TodoTaskStates.NoteReopened("t9");
        var snap = TodoTaskStates.GetSnapshot();
        Assert.True(snap.Read);
        Assert.True(snap.Tasks.ContainsKey("t9"));
        Assert.Contains("t9", snap.Reopened);
        TodoTaskStates.Forget();
    }
}
