namespace Hermes.Core.Tasks;

/// A list's colour (HermesKit/Pages/Tasks/TodoLists.swift TodoListColor), in the Mac's order.
public static class TodoListColors
{
    public static readonly IReadOnlyList<string> All = ["blue", "green", "orange", "red", "purple", "pink", "teal", "yellow", "gray"];

    /// The first colour no list has yet (a new list's), else the first (TodoLists.nextColor).
    public static string Next(IEnumerable<TodoUserSection> sections)
    {
        var used = sections.Select(s => s.Color).OfType<string>().ToHashSet();
        return All.FirstOrDefault(c => !used.Contains(c)) ?? "blue";
    }

    /// "blue" → "Blue": a swatch's spoken name (TodoListColor.name).
    public static string Name(string color) => color.Length == 0 ? color : char.ToUpperInvariant(color[0]) + color[1..];
}

/// What a list's pill menu holds, top to bottom (App/Pages/Tasks/TaskViewsHeader.swift `menu(for:)`): Edit List…,
/// Rename…, Move Left (not on the first), Move Right (not on the last), a divider, Delete List….
public enum TodoListMenuItem { EditList, Rename, MoveLeft, MoveRight, Divider, DeleteList }

/// The words of New List, Rename List, Delete List and Move To › New List… (App/Pages/Tasks/TasksViewController.swift,
/// TaskViewsHeader.swift; HermesKit TodoModel.swift TodoWords.deleteListMessage).
public static class TodoListCopy
{
    /// The pill after the lists, and the name prompt's title.
    public const string NewList = "New List";
    public const string NewListMessage = "Group your tasks your way, like Home, Work or Errands.";
    public const string Add = "Add";
    public const string RenameList = "Rename List";
    public const string Save = "Save";
    public const string Cancel = "Cancel";
    public const string NamePlaceholder = "List Name";
    /// Move To's last choice.
    public const string NewListEllipsis = "New List…";
    public const string EditList = "Edit List…";
    public const string Rename = "Rename…";
    public const string MoveLeft = "Move Left";
    public const string MoveRight = "Move Right";
    public const string DeleteListEllipsis = "Delete List…";
    public const string DeleteList = "Delete List";
    /// A name gone from the lists (deleteList's `listName(id) ?? "List"`).
    public const string FallbackName = "List";
    public static string DeleteTitle(string name) => $"Delete “{name}”?";

    /// The confirmation's message: a list is where a task is filed, not the task; deleting it keeps every task, in no
    /// list. null for an empty list (the Mac's alert has no message then).
    public static string? DeleteMessage(int open, int done) => (open, done) switch
    {
        (0, 0) => null,
        (1, 0) => "Its task is kept, in no list.",
        (0, 1) => "Its done task is kept, in no list.",
        (_, 0) => $"Its {open} tasks are kept, in no list.",
        (0, _) => $"Its {done} done tasks are kept, in no list.",
        _ => $"Its {(open == 1 ? "1 task" : $"{open} tasks")} and {(done == 1 ? "1 done task" : $"{done} done tasks")} are kept, in no list.",
    };

    public static string CouldNotSaveSections(string reason) => $"Couldn’t save your sections. {reason}";

    /// The longest name a list keeps, in characters as you see them (Swift `prefix(60)` counts Characters).
    public const int NameLimit = 60;

    /// A typed name as saved: trimmed, at most 60 characters; null when blank (Add or Save waits for a name).
    /// [WIN-TASK-LIST-EDIT] Counted as text elements (grapheme clusters), as the Mac's Characters are, so an emoji, a
    /// flag or an accent at the cut is kept whole or dropped whole, never split into a broken character.
    public static string? CleanName(string? text)
    {
        var clean = (text ?? "").Trim();
        if (clean.Length == 0) return null;
        if (clean.Length <= NameLimit) return clean;
        var info = new System.Globalization.StringInfo(clean);
        return info.LengthInTextElements > NameLimit ? info.SubstringByTextElements(0, NameLimit) : clean;
    }

    /// The pill menu for the list at `index` of `count` (TaskViewsHeader.swift `menu(for:)`).
    public static IReadOnlyList<TodoListMenuItem> Menu(int index, int count)
    {
        var items = new List<TodoListMenuItem> { TodoListMenuItem.EditList, TodoListMenuItem.Rename };
        if (index > 0) items.Add(TodoListMenuItem.MoveLeft);
        if (index < count - 1) items.Add(TodoListMenuItem.MoveRight);
        items.Add(TodoListMenuItem.Divider);
        items.Add(TodoListMenuItem.DeleteList);
        return items;
    }

    public static string Title(TodoListMenuItem item) => item switch
    {
        TodoListMenuItem.EditList => EditList,
        TodoListMenuItem.Rename => Rename,
        TodoListMenuItem.MoveLeft => MoveLeft,
        TodoListMenuItem.MoveRight => MoveRight,
        TodoListMenuItem.DeleteList => DeleteListEllipsis,
        _ => "",
    };
}

/// Tasks Settings (App/Pages/Tasks/TodoSettingsSheet.swift): the page's ⋯ › Tasks Settings…. Every control saves at
/// once with the whole settings (`PUT /tasks/settings`), so every device and bot sees the same.
public static class TodoSettingsCopy
{
    public const string MenuTitle = "Tasks Settings…";
    public const string Title = "Tasks Settings";
    public const string Done = "Done";

    public const string CatchTasks = "Catch Tasks in Chats";
    /// The segments in the Mac's order: (title, `capture`).
    public static readonly IReadOnlyList<(string Title, string Key)> CaptureOptions = [("Ask First", "ask"), ("Automatic", "auto"), ("Off", "off")];
    public static string CaptureFooter(string capture) => capture switch
    {
        "auto" => "When you say you need to do something, a bot adds it to Tasks, takes the part it can do, and tells you. Undo takes it back.",
        "off" => "Bots add tasks only when you ask them to.",
        _ => "When you say you need to do something, a bot asks what it could do for it first. Pick what it should do, or just add it; skip, and nothing goes on your list.",
    };

    public const string GettingReady = "Getting Tasks Ready";
    public const string TimesADay = "Times a Day";
    public const int PerDayMin = 0, PerDayMax = 24;
    public static string PerDay(int n) => n == 0 ? "Never" : n.ToString(System.Globalization.CultureInfo.InvariantCulture);
    public const string QuietFrom = "Quiet From";
    public const string QuietUntil = "Quiet Until";
    public const string GettingReadyFooter = "How often your bots may work on tasks set to get ready, across every bot. Nothing runs in the quiet hours.";

    public const string Ideas = "Ideas";
    public const string SuggestTasks = "Suggest Tasks";
    public const string WhoLooks = "Who Looks";
    public const string EachDayAt = "Each Day At";
    public const string IdeasADay = "Ideas a Day";
    public const int IdeasMin = 1, IdeasMax = 5;
    public const string DefaultIdeasAt = "07:30";
    public const int DefaultIdeasMax = 3;
    public static string UpTo(int n) => $"Up to {n}";
    public static string IdeasFooter(string botName) =>
        $"Once a day, {botName} looks through your recent chats and whatever else it can reach, like your calendar or email, and suggests a few tasks under Ideas. It can’t put anything on your list itself: nothing goes there until you add it.";

    /// "22:00" → 22 h (TodoSettingsModel.time); what can't be read is midnight.
    public static TimeSpan Time(string? text)
    {
        var parts = (text ?? "").Split(':').Select(p => int.TryParse(p, out var n) ? (int?)n : null).OfType<int>().ToList();
        var hour = parts.Count > 0 ? parts[0] : 0;
        var minute = parts.Count > 1 ? parts[1] : 0;
        return new TimeSpan(Math.Clamp(hour, 0, 23), Math.Clamp(minute, 0, 59), 0);
    }

    /// 7 h 30 → "07:30" (TodoSettingsModel.text).
    public static string Text(TimeSpan time) => $"{time.Hours:00}:{time.Minutes:00}";
}

/// The sheet's state (TodoSettingsSheet.swift TodoSettingsModel): a draft of the settings, saved on each change. A
/// save that didn't land puts the controls back to what the gateway keeps, unless another change has gone out since
/// (which carries this one with it).
public sealed class TodoSettingsModel(TasksStore store, IReadOnlyList<(string Id, string Name)> bots)
{
    public TasksStore Store { get; } = store;
    public TodoSettings Draft { get; private set; } = store.Settings;
    /// The bots that could look for ideas (id, name).
    public IReadOnlyList<(string Id, string Name)> Bots { get; } = bots;
    /// An Ideas setting was saved: the Ideas page reads again.
    public event Action? IdeasChanged;
    /// The draft changed (a control's value, or put back after a refused save).
    public event Action? Changed;

    /// Ideas shows only on an add-on that keeps it (0.9.39+).
    public bool ShowsIdeas => Draft.Ideas != null;
    public bool IdeasOn => Draft.Ideas == true;
    public string Looker => Draft.IdeasBot ?? "default";
    public bool ShowsWhoLooks => IdeasOn && Bots.Count > 1;
    public string BotName(string id) => Bots.FirstOrDefault(b => b.Id == id) is { Name: { } name } ? name : id;

    public Task<bool> SetCapture(string capture) => Change(Draft with { Capture = capture });
    public Task<bool> SetPrepPerDay(int n) => Change(Draft with { PrepPerDay = Math.Clamp(n, TodoSettingsCopy.PerDayMin, TodoSettingsCopy.PerDayMax) });
    public Task<bool> SetQuietStart(TimeSpan t) => Change(Draft with { QuietStart = TodoSettingsCopy.Text(t) });
    public Task<bool> SetQuietEnd(TimeSpan t) => Change(Draft with { QuietEnd = TodoSettingsCopy.Text(t) });
    public Task<bool> SetIdeas(bool on) => Change(Draft with { Ideas = on });
    public Task<bool> SetIdeasBot(string bot) => Change(Draft with { IdeasBot = bot });
    public Task<bool> SetIdeasAt(TimeSpan t) => Change(Draft with { IdeasAt = TodoSettingsCopy.Text(t) });
    public Task<bool> SetIdeasMax(int n) => Change(Draft with { IdeasMax = Math.Clamp(n, TodoSettingsCopy.IdeasMin, TodoSettingsCopy.IdeasMax) });

    private Task<bool> Change(TodoSettings next)
    {
        Draft = next;
        Changed?.Invoke();
        return CommitAsync();
    }

    /// Saves the draft (nothing to do when it is what the gateway keeps). false when the save was refused.
    public async Task<bool> CommitAsync()
    {
        if (Draft == Store.Settings) return true;
        var next = Draft;
        var before = Store.Settings;
        var ideas = next.Ideas != before.Ideas || next.IdeasBot != before.IdeasBot || next.IdeasAt != before.IdeasAt || next.IdeasMax != before.IdeasMax;
        if (!await Store.SaveSettingsAsync(next))
        {
            if (Draft == next) { Draft = Store.Settings; Changed?.Invoke(); }
            return false;
        }
        if (ideas) IdeasChanged?.Invoke();
        return true;
    }
}
