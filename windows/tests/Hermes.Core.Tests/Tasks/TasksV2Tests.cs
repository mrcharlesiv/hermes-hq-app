using System.Text.Json.Nodes;
using Hermes.Core.Kanban;
using Hermes.Core.Tasks;

namespace Hermes.Core.Tests.Tasks;

public class TasksV2Tests
{
    private static readonly TimeZoneInfo Utc = TimeZoneInfo.Utc;
    private static readonly DateTimeOffset Now = new(2026, 11, 13, 10, 0, 0, TimeSpan.Zero);

    [Fact]
    public void TodoTaskAndListAnswerParseV2FieldsWithoutBreakingV1()
    {
        var json = new JsonObject
        {
            ["rev"] = 12,
            ["fields"] = true,
            ["files"] = true,
            ["lists"] = true,
            ["pages"] = true,
            ["goal_bots"] = true,
            ["custom_repeat"] = true,
            ["ideas"] = 2,
            ["tasks"] = new JsonArray(new JsonObject
            {
                ["id"] = "t1",
                ["rev"] = 3,
                ["title"] = "Book dentist",
                ["who"] = "together",
                ["bot"] = "ivy",
                ["status"] = "needs_you",
                ["chat"] = new JsonObject { ["profile"] = "ivy", ["session_id"] = "chat-99" },
                ["page_at"] = "2026-11-13T09:00:00Z",
                ["page"] = new JsonObject { ["summary"] = "Found two slots.", ["next"] = "Pick 10 AM or 2 PM." },
                ["from"] = new JsonObject { ["app"] = "email", ["who"] = "Clinic", ["at"] = "2026-11-12T14:00:00Z" },
                ["made"] = new JsonArray(
                    new JsonObject { ["id"] = "m1", ["title"] = "Portal", ["kind"] = "link", ["ref"] = "https://example.com/portal", ["by"] = "you" }),
            }),
            ["offers"] = new JsonArray(new JsonObject
            {
                ["id"] = "o1",
                ["bot"] = "ivy",
                ["list"] = "Home",
                ["section"] = "home",
                ["new"] = false,
                ["state"] = "new",
                ["why"] = "From your morning check-in",
                ["tasks"] = new JsonArray(new JsonObject { ["title"] = "Order filters" }),
            }),
        };

        var answer = TodoListAnswer.From(json);
        Assert.True(answer.Files);
        Assert.True(answer.Pages);
        Assert.True(answer.GoalBots);
        Assert.True(answer.CustomRepeat);
        Assert.Equal(2, answer.IdeasCount);
        var task = Assert.Single(answer.Tasks!);
        Assert.Equal("chat-99", task.Chat!.SessionId);
        Assert.True(task.ChatKnown);
        Assert.Equal("Found two slots.", task.Page!.Summary);
        Assert.Contains("Email · Clinic", task.SourceFrom!.Line(Now, Utc));
        Assert.True(task.Made[0].IsYours);
        Assert.Equal("https://example.com/portal", task.Made[0].LinkUrl);
        var offer = Assert.Single(answer.Offers!);
        Assert.Equal("ivy", offer.Bot);
        Assert.Equal("list", offer.Kind);
        Assert.True(offer.IsWaiting);
    }

    [Fact]
    public void TaskNowPicksBestActionAndFindsCallablePhoneNumbers()
    {
        var withPhone = new TodoTask("t-call") { Title = "Call clinic at (555) 010-0123", Notes = "Ignore https://example.com/555-019-9999" };
        Assert.Equal("(555) 010-0123", TaskNow.Callable(withPhone));
        var plan = TaskNow.Pick(withPhone, p => p ?? "Hermes");
        Assert.Equal(TaskNowKind.Call, plan.Primary!.Kind);

        var urlOnly = new TodoTask("t-url") { Title = "Check doc", Notes = "https://example.com/555-010-0123" };
        Assert.Null(TaskNow.Callable(urlOnly));

        var waiting = new TodoTask("t-ask") { Title = "Pick vendor", Who = "together", Bot = "ivy", Status = "needs_you" };
        Assert.Equal(TaskNowKind.Answer, TaskNow.Pick(waiting, _ => "Ivy").Primary!.Kind);

        var done = new TodoTask("t-done") { Title = "Filed taxes", Status = "done" };
        Assert.Equal(TaskNowKind.Reopen, TaskNow.Pick(done, _ => "Hermes").Primary!.Kind);

        Assert.Equal("Task: Pick vendor", TaskChatLinks.SessionTitle(waiting));
        Assert.Contains("Pick vendor", TaskChatLinks.OutgoingTaskPrompt(waiting, "Pick option B"));
    }

    [Fact]
    public void TodayCheckInUndoAndOfferAndCloseCardRulesWork()
    {
        var personal = new TodoTask("p1") { Title = "Pay rent" };
        var repeating = new TodoTask("p2") { Title = "Water plants", RepeatRule = "weekly" };
        Assert.True(TodayCheckIn.ShouldOfferUndo(personal, markingDone: true));
        Assert.False(TodayCheckIn.ShouldOfferUndo(personal, markingDone: false));
        Assert.False(TodayCheckIn.ShouldOfferUndo(repeating, markingDone: true));

        var overdue = new TodoTask("ov") { Title = "Overdue", Due = "2026-11-10" };
        var dueToday = new TodoTask("td") { Title = "Today", Due = "2026-11-13", Offer = new TodoCloseOffer("ivy", "Done?", null, false) };
        var offer = new TodoOffer("o1")
        {
            Kind = "list",
            Bot = "ivy",
            List = "Work",
            IsNew = true,
            Summary = "Suggested",
            Tasks = [new TodoOfferTask("Prep deck")],
        };
        var summary = TodayCheckIn.Compute([overdue, dueToday], [offer], Now, Utc);
        Assert.Equal(1, summary.Overdue);
        Assert.Equal(1, summary.DueToday);
        Assert.Equal(1, summary.CloseOffers);
        Assert.Equal(1, summary.PendingOffers);
        Assert.True(summary.HasActionItems);

        var listButtons = TodoOfferRules.OfferButtons(offer);
        Assert.Equal([TodoOfferAction.Accept, TodoOfferAction.AcceptNoList, TodoOfferAction.Decline], listButtons.Select(b => b.Action));

        Assert.Equal(TodoCloseCardState.Waiting, TodoCloseCards.StateOf(dueToday));
        Assert.Equal(TodoCloseCardState.Kept, TodoCloseCards.StateOf(dueToday, locallyKept: true));
        Assert.Equal(TodoCloseCardState.Gone, TodoCloseCards.StateOf(null));
    }

    [Fact]
    public async Task TaskIdeasStoreHandlesAddDismissRestoreAndTasksStoreHandlesAttachmentsAndOffers()
    {
        var rest = new FakeTasksV2Rest();
        var api = new TasksApi(rest);
        var ideas = new TaskIdeasStore(api);

        await ideas.RefreshAsync();
        Assert.True(ideas.Page.On);
        var idea = Assert.Single(ideas.VisibleIdeas);

        // Dismiss then restore
        Assert.True(await ideas.DismissAsync(idea));
        Assert.Empty(ideas.VisibleIdeas);
        Assert.True(await ideas.RestoreAsync(idea));
        Assert.Single(ideas.VisibleIdeas);

        // Add idea
        var created = await ideas.AddAsync(idea, letBotStart: true);
        Assert.NotNull(created);
        Assert.Empty(ideas.VisibleIdeas);

        // TasksStore v2 attachments + offer accept on single-threaded loop
        await MainLoop.Drive(async () =>
        {
            var store = new TasksStore(api);
            await store.RefreshAsync(force: true);
            Assert.True(store.FilesSupported);
            Assert.True(store.PagesSupported);
            Assert.Single(store.Offers);

            Assert.True(await store.AttachFileAsync("t1", "notes.txt", "hello"u8.ToArray()));
            Assert.Contains(store.Find("t1")!.Made, m => m.Title == "notes.txt");

            Assert.False(await store.AttachLinkAsync("t1", "Bad", "javascript:alert(1)"));
            Assert.True(await store.AttachLinkAsync("t1", "Spec", "https://example.com/spec"));
            Assert.Contains(store.Find("t1")!.Made, m => m.LinkUrl == "https://example.com/spec");

            Assert.True(await store.DetachMadeAsync("t1", "m-file"));
            Assert.DoesNotContain(store.Find("t1")!.Made, m => m.Id == "m-file");

            var answered = await store.AnswerOfferAsync("o1", TodoOfferAction.Accept);
            Assert.NotNull(answered);
            Assert.Equal("accepted", answered!.Offer!.State);
            Assert.Equal("accepted", store.Offers.Single().State);
            Assert.True(store.Offers.Single().Undoable);
        });
    }

    private sealed class FakeTasksV2Rest : IPagesRest
    {
        private readonly List<JsonObject> _made = [];
        private bool _ideaAdded;
        private string _offerState = "new";

        public Task<JsonNode?> JsonAsync(HttpMethod method, string path, IEnumerable<KeyValuePair<string, string>>? query = null,
            JsonNode? body = null, TimeSpan? timeout = null, CancellationToken ct = default)
        {
            if (path.EndsWith("/tasks/ideas", StringComparison.Ordinal))
            {
                var arr = new JsonArray();
                if (!_ideaAdded)
                    arr.Add(new JsonObject { ["id"] = "i1", ["title"] = "Renew domain", ["why"] = "Expires next week", ["who"] = "together", ["bot"] = "ivy" });
                return Task.FromResult<JsonNode?>(new JsonObject
                {
                    ["on"] = true,
                    ["bot"] = "ivy",
                    ["looking"] = false,
                    ["ideas"] = arr,
                });
            }
            if (path.EndsWith("/ideas/i1/add", StringComparison.Ordinal))
            {
                _ideaAdded = true;
                return Task.FromResult<JsonNode?>(new JsonObject { ["id"] = "t-from-idea", ["title"] = "Renew domain", ["status"] = "open" });
            }
            if (path.Contains("/ideas/i1/", StringComparison.Ordinal))
                return Task.FromResult<JsonNode?>(new JsonObject { ["ok"] = true });

            if (path.EndsWith("/tasks/t1/attach", StringComparison.Ordinal))
            {
                var kind = body.Str("kind") ?? "file";
                var id = kind == "file" ? "m-file" : "m-link";
                var title = kind == "file" ? (body.Str("name") ?? "file") : (body.Str("title") ?? "link");
                var r = kind == "file" ? title : (body.Str("url") ?? "");
                _made.Add(new JsonObject { ["id"] = id, ["title"] = title, ["kind"] = kind, ["ref"] = r, ["by"] = "you" });
                return Task.FromResult<JsonNode?>(TaskJson());
            }
            if (path.Contains("/tasks/t1/made/", StringComparison.Ordinal))
            {
                var madeId = path.Split('/')[^1];
                _made.RemoveAll(m => m.Str("id") == madeId);
                return Task.FromResult<JsonNode?>(TaskJson());
            }
            if (path.EndsWith("/tasks/offers/o1", StringComparison.Ordinal))
            {
                _offerState = body.Str("action") == "accept" ? "accepted" : "declined";
                return Task.FromResult<JsonNode?>(new JsonObject
                {
                    ["rev"] = 6,
                    ["offer"] = OfferJson(),
                    ["sections"] = new JsonArray(),
                    ["goals"] = new JsonArray(),
                });
            }

            return Task.FromResult<JsonNode?>(new JsonObject
            {
                ["rev"] = 5,
                ["fields"] = true,
                ["files"] = true,
                ["lists"] = true,
                ["pages"] = true,
                ["tasks"] = new JsonArray(TaskJson()),
                ["sections"] = new JsonArray(),
                ["goals"] = new JsonArray(),
                ["offers"] = new JsonArray(OfferJson()),
            });
        }

        private JsonObject OfferJson() => new()
        {
            ["id"] = "o1",
            ["kind"] = "tasks",
            ["bot"] = "ivy",
            ["goal"] = "g1",
            ["title"] = "Ship docs",
            ["state"] = _offerState,
            ["tasks"] = new JsonArray(new JsonObject { ["title"] = "Prep deck" }),
        };

        private JsonObject TaskJson() => new()
        {
            ["id"] = "t1",
            ["rev"] = 2,
            ["title"] = "Ship docs",
            ["status"] = "open",
            ["made"] = new JsonArray([.. _made.Select(m => (JsonNode)m.DeepClone())]),
        };

        public Task<string> UploadAsync(string path, IEnumerable<KeyValuePair<string, string>>? query, string contentType, string bodyFile,
            TimeSpan timeout, Action<long, long>? progress = null, CancellationToken ct = default) => Task.FromResult("{}");
        public Task DownloadAsync(string path, IEnumerable<KeyValuePair<string, string>>? query, string file, long ceiling,
            CancellationToken ct = default) => Task.CompletedTask;
    }
}
