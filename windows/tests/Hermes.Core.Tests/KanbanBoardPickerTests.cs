using System.Text.Json.Nodes;
using Hermes.Core.Kanban;

namespace Hermes.Core.Tests;

/// The board picker (App/Pages/Kanban/KanbanViewController.swift `configureBoardButton`, `KanbanBoardListController`):
/// up to eight boards are a pop-up menu on the board button; more than eight, the button opens a pushed "Boards" list
/// instead, searchable over twelve. Every board name here is synthetic.
public class KanbanBoardPickerTests
{
    private static readonly string[] Names =
    [
        "Alpha Ops", "Beta Launch", "Gamma Research", "Delta QA", "Epsilon Design", "Zeta Infra", "Eta Support",
        "Theta Docs", "Iota Billing", "Kappa Growth", "Lambda Mobile", "Mu Data", "Nu Ops Review", "Xi Archive",
    ];

    /// `count` synthetic boards: board-1 … board-N, the first current; board-2 has no name (its slug is read as words),
    /// board-3 has no total.
    private static JsonNode BoardsJson(int count)
    {
        var list = new JsonArray();
        for (var i = 1; i <= count; i++)
        {
            var b = new JsonObject { ["slug"] = $"board-{i}" };
            if (i != 2) b["name"] = Names[i - 1];
            if (i != 3) b["total"] = i == 4 ? 1 : i * 2;
            if (i == 1) b["is_current"] = true;
            list.Add(b);
        }
        return new JsonObject { ["boards"] = list, ["current"] = "board-1" };
    }

    /// Read as the wire sends it (text), as `KanbanApi.BoardsAsync` does.
    private static KanbanBoards Seed(int count) => KanbanBoards.From(JsonNode.Parse(BoardsJson(count).ToJsonString()));

    [Theory]
    [InlineData(1, KanbanBoardPickerStyle.Menu)]
    [InlineData(7, KanbanBoardPickerStyle.Menu)]
    [InlineData(8, KanbanBoardPickerStyle.Menu)]
    [InlineData(9, KanbanBoardPickerStyle.List)]
    [InlineData(12, KanbanBoardPickerStyle.List)]
    [InlineData(13, KanbanBoardPickerStyle.List)]
    public void EightBoardsAreAMenuAndMoreAreAList(int count, KanbanBoardPickerStyle style)
    {
        Assert.Equal(style, KanbanBoardPicker.StyleFor(Seed(count).Boards.Count));
    }

    [Fact]
    public void NoBoardsYetIsAMenuWithNothingInIt()
    {
        Assert.Equal(KanbanBoardPickerStyle.Menu, KanbanBoardPicker.StyleFor(0));
        Assert.Empty(KanbanBoardPicker.Choices((KanbanBoards?)null, ""));
    }

    [Fact]
    public void TheMenuNamesEveryBoardInOrderTicksTheCurrentAndCountsItsTasks()
    {
        var choices = KanbanBoardPicker.Choices(Seed(8), "board-1");
        Assert.Equal(8, choices.Count);
        Assert.Equal(["board-1", "board-2", "board-3", "board-4", "board-5", "board-6", "board-7", "board-8"], choices.Select(c => c.Slug));
        Assert.Equal("Alpha Ops", choices[0].Title);
        Assert.Equal("Board 2", choices[1].Title);   // no name: the slug in words
        Assert.Equal("2 tasks", choices[0].Subtitle);
        Assert.Null(choices[2].Subtitle);           // no total: no subtitle
        Assert.Equal("1 task", choices[3].Subtitle);
        Assert.Equal([true, false, false, false, false, false, false, false], choices.Select(c => c.IsCurrent));
        Assert.Equal("Alpha Ops  ·  2 tasks", choices[0].MenuText);
        Assert.Equal("Gamma Research", choices[2].MenuText);
    }

    [Fact]
    public void TheListIsTitledBoardsTicksTheCurrentAndHasNoSearchUpToTwelve()
    {
        var nine = new KanbanBoardList(Seed(9).Boards, "board-5");
        Assert.Equal("Boards", nine.Title);
        Assert.False(nine.HasSearch);
        Assert.Equal(9, nine.Shown.Count);
        Assert.Equal(["board-5"], nine.Shown.Where(c => c.IsCurrent).Select(c => c.Slug));
        Assert.False(new KanbanBoardList(Seed(12).Boards, "board-1").HasSearch);
        Assert.True(new KanbanBoardList(Seed(13).Boards, "board-1").HasSearch);
    }

    [Fact]
    public void SearchMatchesTheReadNameIgnoringCaseAndEdgesAndAnEmptySearchShowsAll()
    {
        var list = new KanbanBoardList(Seed(14).Boards, "board-1");
        list.Search("  OPS ");
        Assert.Equal(["board-1", "board-13"], list.Shown.Select(c => c.Slug));
        list.Search("board 2");   // a board with no name is found by its words, not its slug
        Assert.Equal(["board-2"], list.Shown.Select(c => c.Slug));
        list.Search("board-2");
        Assert.Empty(list.Shown);
        list.Search("no such board");
        Assert.Empty(list.Shown);   // the Mac's list just has no rows (no empty-state words)
        list.Search("   ");
        Assert.Equal(14, list.Shown.Count);
    }

    [Fact]
    public void PickingTheCurrentBoardChangesNothing()
    {
        Assert.False(KanbanBoardPicker.Switches("board-1", "board-1"));
        Assert.True(KanbanBoardPicker.Switches("board-9", "board-1"));
    }

    [Theory]
    [InlineData(8, KanbanBoardPickerStyle.Menu)]
    [InlineData(9, KanbanBoardPickerStyle.List)]
    public Task TheStoreSaysWhichPickerItsBoardsTakeAndAPickSwitchesAndIsKept(int count, KanbanBoardPickerStyle style) => MainLoop.Drive(async () =>
    {
        var rest = new FakeRest(r => (r.Method, r.Path) switch
        {
            ("GET", "/api/plugins/kanban/boards") => BoardsJson(count),
            ("GET", "/api/plugins/kanban/board") => KanbanStoreTests.BoardJson(("t_" + r.Query.GetValueOrDefault("board", "x"), "A", "todo")),
            _ => new JsonObject(),
        });
        var prefs = new MemoryKanbanPrefs();
        var store = new KanbanStore(new KanbanApi(rest), "acct", prefs);
        Assert.Equal(KanbanBoardPickerStyle.Menu, store.BoardPickerStyle);   // nothing read yet
        await store.ReadBoardsAsync();
        Assert.Equal(style, store.BoardPickerStyle);
        Assert.Equal(count, store.BoardChoices.Count);
        Assert.True(store.BoardChoices[0].IsCurrent);

        var last = $"board-{count}";
        store.Select(last);
        Assert.Equal(last, prefs.Get(KanbanStore.SlugKey("acct")));
        Assert.Equal(Names[count - 1], store.BoardTitle);
        Assert.Equal([last], store.BoardChoices.Where(c => c.IsCurrent).Select(c => c.Slug));
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (store.Board == null && DateTime.UtcNow < deadline) await Task.Delay(20);
        Assert.Contains(rest.Log, r => r.Path == "/api/plugins/kanban/board" && r.Query.GetValueOrDefault("board") == last);
    });
}
