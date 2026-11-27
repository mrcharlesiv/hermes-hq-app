namespace Hermes.Core.Tasks;

// Sort By, dragging a task up or down its list, and Select (App/Pages/Tasks/TasksViewController.swift `menuItems`,
// "MARK: Drag a task up or down its list", "MARK: Select"). The sort itself is `TodoSettings.Sort`, kept on the gateway
// with the other Tasks settings (`PUT /tasks/settings`), so every device shows a list the same way; it orders a list's
// open tasks only (TodoSections.Ordered in TodoViews.Groups).

/// One Sort By choice.
public sealed record TodoSortOption(string Key, string Title, string Glyph);

public static class TodoSortBy
{
    public const string Title = "Sort By";
    public const string MyOrder = "smart";

    /// The menu's choices, in the Mac's order: My Order, Due Date, Priority (on an add-on that keeps one, 0.9.53, or
    /// when it is the sort already), Date Added. Glyphs stand in for hand.draw, calendar, flag, clock.
    public static IReadOnlyList<TodoSortOption> Options(bool fieldsSupported, string current)
    {
        var sorts = new List<TodoSortOption> { new("smart", "My Order", "\uE7C9"), new("due", "Due Date", "\uE787"), new("added", "Date Added", "\uE823") };
        if (fieldsSupported || current == "priority") sorts.Insert(2, new TodoSortOption("priority", "Priority", "\uE7C1"));
        return sorts;
    }

    /// The submenu's second line: the sort in force ("My Order"); none for a word the menu doesn't offer.
    public static string? Subtitle(string current) => current switch
    {
        "smart" => "My Order", "due" => "Due Date", "priority" => "Priority", "added" => "Date Added", _ => null,
    };

    /// "A list is in your order until you say otherwise": Sort By is in the menu only on a list's view.
    public static bool Shows(TodoView view) => view.ListId != null;
}

public static class TodoArrange
{
    /// How long the "Sorted by …" notice stays.
    public const int NoticeSeconds = 4;

    /// A list's open tasks can be put in your own order by hand: on a list, not while searching or selecting, on a
    /// gateway that takes writes. (Done rows don't drag.)
    public static bool CanArrange(TodoView view, bool searching, bool selecting, bool readOnly) =>
        view.ListId != null && !searching && !selecting && !readOnly;

    /// Where a task dropped at `target` (an index among the list's open rows as shown, the dragged one included)
    /// lands: halfway between its new neighbours (`performDropWith`).
    public static double DropPosition(IReadOnlyList<string> openIds, string id, int target, Func<string, TodoTask?> find, DateTimeOffset now)
    {
        var ids = openIds.ToList();
        var index = Math.Min(target, ids.Count);
        var from = ids.IndexOf(id);
        if (from >= 0)
        {
            ids.RemoveAt(from);
            if (from < index) index -= 1;
        }
        index = Math.Min(Math.Max(index, 0), ids.Count);
        var above = index > 0 ? find(ids[index - 1]) : null;
        var below = index < ids.Count ? find(ids[index]) : null;
        return TodoSections.Position(above, below, now);
    }

    /// A drop in another sort still saves the place (My Order will show it), and says why the row went back.
    public static string? SortedNotice(string sort) => sort == "smart" ? null
        : $"Sorted by {(sort == "due" ? "Due Date" : sort == "priority" ? "Priority" : "Date Added")}. Choose My Order in Sort By to arrange tasks by hand.";

    /// `itemsForBeginning`: a row lifts when the view can be arranged and its task is still open.
    public static bool CanLift(TodoTask? task, TodoView view, bool searching, bool selecting, bool readOnly) =>
        task is { IsDone: false } && CanArrange(view, searching, selecting, readOnly);

    /// `dropIndex`: where a drop over the row `overId` lands among the list's open rows, the Windows rows' stand-in for
    /// UIKit's destination index path in the open group. Its upper half (the middle included) is the row's own place,
    /// its lower half the place under it. Null over anything that isn't an open row of the list (`.forbidden`).
    public static int? DropIndex(IReadOnlyList<string> openIds, string overId, double pointerY, double rowHeight)
    {
        var at = -1;
        for (var i = 0; i < openIds.Count; i++) if (openIds[i] == overId) { at = i; break; }
        if (at < 0) return null;
        return rowHeight > 0 && pointerY > rowHeight / 2 ? at + 1 : at;
    }

    /// `performDropWith`: the one write a drop makes, `move([id], to: list, position:)` (PATCH /tasks/{id} with the
    /// position; the list is the one on show, so no section field), and the "Sorted by …" notice outside My Order.
    /// Null with no list on show or no place.
    public static TodoDropPlan? Plan(IReadOnlyList<string> openIds, string id, int? target, TodoView view, Func<string, TodoTask?> find,
        DateTimeOffset now, string sort)
    {
        if (view.ListId is not { } list || target is not { } at) return null;
        return new TodoDropPlan(id, list, DropPosition(openIds, id, at, find, now), SortedNotice(sort));
    }
}

/// What a drop writes: `id` into `List` (the list on show) at `Position`, and the notice to show (null in My Order).
public sealed record TodoDropPlan(string Id, string List, double Position, string? Notice);

/// `dropPlace`: where a held task would land. Each move to a new place is a tick (on the Mac `Haptics.play(.selection)`);
/// the first place is where the task was picked up, so it doesn't tick. Reset when the drag leaves or ends.
public sealed class TodoDropPlace
{
    public int? Current { get; private set; }

    /// True when this is a new place after the first (a tick).
    public bool Update(int index)
    {
        if (Current == index) return false;
        var tick = Current != null;
        Current = index;
        return tick;
    }

    public void Reset() => Current = null;
}

/// Select: the page's ⋯ › Select Tasks (or Select in a row's menu). Row circles become pick circles and a click picks a
/// task (any task row, done ones too; nothing opens, no menus, no drag); the bar holds Done, Delete, Mark Done and
/// Move To, the three greyed with nothing picked or on a read-only gateway. Done (or Esc) ends it.
public sealed class TodoSelection
{
    public const string MenuTitle = "Select Tasks";
    public const string RowMenuTitle = "Select";
    /// The bar, as the Mac's right-hand items read from the end inwards.
    public static readonly string[] BarOrder = [TasksCopy.Done, TasksCopy.Delete, TasksCopy.MarkDone, TasksCopy.MoveTo];

    public bool Active { get; private set; }
    private readonly List<string> _picked = [];
    /// The tasks picked, in the order they were clicked.
    public IReadOnlyList<string> Picked => _picked;

    public bool IsPicked(string id) => _picked.Contains(id);

    /// Select on; picking starts empty (turning it on again changes nothing).
    public void Start()
    {
        if (Active) return;
        Active = true;
        _picked.Clear();
    }

    /// A row's Select: Select on with that row picked.
    public void StartWith(string id)
    {
        Start();
        Toggle(id);
    }

    public enum EscapeAction { Nothing, CloseTask }

    /// Esc on the page: while selecting it decides nothing and keeps the picks (the Mac logs `[keys] escape: nothing`;
    /// only Done, an action or leaving the page ends Select); otherwise it closes the task beside the list.
    public EscapeAction OnEscape() => Active ? EscapeAction.Nothing : EscapeAction.CloseTask;

    /// Done, an action finishing, or leaving the page. False when it wasn't on.
    public bool End()
    {
        if (!Active) return false;
        Active = false;
        _picked.Clear();
        return true;
    }

    public void Toggle(string id)
    {
        if (!_picked.Remove(id)) _picked.Add(id);
    }

    /// The picks still on the list.
    public List<string> SelectedIds(Func<string, bool> exists) => [.. _picked.Where(exists)];

    /// Move To, Mark Done and Delete work with something picked on a gateway that takes writes.
    public bool CanAct(int count, bool readOnly) => count > 0 && !readOnly;

    public static string DeleteTitle(int count) => count == 1 ? "Delete 1 Task?" : $"Delete {count} Tasks?";

    /// Mark Done marks the open ones.
    public static List<string> ToMarkDone(IEnumerable<string> ids, Func<string, TodoTask?> find) =>
        [.. ids.Where(id => find(id) is { IsDone: false })];

    /// Move To's ticked place: the one list all of `ids` are in ("" = No List); null when they differ.
    public static string? MoveTick(IReadOnlyCollection<string> ids, Func<string, TodoTask?> find)
    {
        var places = ids.Select(id => find(id)?.Section ?? "").Distinct().ToList();
        return places.Count == 1 ? places[0] : null;
    }
}
