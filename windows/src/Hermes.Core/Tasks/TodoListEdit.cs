using Hermes.Core.Kanban;

namespace Hermes.Core.Tasks;

/// [WIN-TASK-LIST-EDIT] The icons a list can take, in the order Edit List shows them (HermesKit/Pages/Tasks/
/// TodoLists.swift TodoListIcons, 93f984bb1). The names are the Mac's SF Symbol names, as `icon` carries them on the
/// wire; the Windows page draws each with its own glyph.
public static class TodoListIcons
{
    public static readonly IReadOnlyList<string> All =
    [
        "list.bullet", "briefcase", "house", "cart", "heart", "star", "book", "airplane", "dollarsign.circle",
        "person.2", "wrench.and.screwdriver", "leaf", "graduationcap", "gift", "pawprint", "flag",
    ];

    public const string Fallback = "list.bullet";

    private static readonly Dictionary<string, string> Words = new()
    {
        ["list.bullet"] = "List", ["house"] = "Home", ["cart"] = "Shopping", ["dollarsign.circle"] = "Money",
        ["person.2"] = "People", ["wrench.and.screwdriver"] = "Tools", ["graduationcap"] = "School", ["pawprint"] = "Pets",
    };

    /// "briefcase" → "Briefcase": what a screen reader says for an icon (TodoListIcons.spoken).
    public static string Spoken(string icon)
    {
        if (Words.TryGetValue(icon, out var word)) return word;
        var first = icon.Split('.')[0];
        return first.Length == 0 ? "Icon" : char.ToUpperInvariant(first[0]) + first[1..];
    }
}

/// The words of Edit List (App/Pages/Tasks/TaskListViews.swift TaskListEditView, 93f984bb1).
public static class TaskListEditCopy
{
    public const string Title = "Edit List";
    public const string NamePlaceholder = TodoListCopy.NamePlaceholder;
    /// The sheet's close (ChatSheet.wrap's Done).
    public const string Done = "Done";
    public const string Colour = "Colour";
    public const string ColourFooter = "A small dot in this colour marks the list’s tasks in Today, Upcoming and search.";
    public const string Icon = "Icon";
    public const string Bot = "Bot";
    public const string KeptBy = "Kept By";
    public const string NoOne = "No One";
    public const string NewTasks = "New Tasks";
    public const string AddWithoutAsking = "Add Without Asking";
    public const string AskFirst = "Ask First";
    public const string ShowInToday = "Show in Today";
    public const string DeleteList = TodoListCopy.DeleteListEllipsis;

    /// The Bot section's footer: what the keeper does, or what a keeper would do.
    public static string BotFooter(string? botName, bool asksFirst) => botName == null
        ? "A bot that keeps a list files what belongs there and tells you when a task looks settled."
        : asksFirst
            ? $"{botName} files what belongs here, and shows you new tasks as a card before they go on. It never marks your task done or rewords it: it offers, and you decide."
            : $"{botName} files what belongs here and adds new tasks as it finds them. It never marks your task done or rewords it: it offers, and you decide.";

    public static string TodayFooter => $"Today shows this list’s next {TodoViews.NextCount} tasks under the ones that are due, in the order you keep them.";
}

/// Delete List's confirmation, shared by the pill menu and Edit List (TasksViewController.swift deleteList):
/// “Delete “Home”?”, saying its tasks are kept in no list; nothing changes unless Delete List is pressed.
public static class TodoListDelete
{
    /// `confirm(title, message)` shows the question and answers whether Delete List was pressed. false when cancelled,
    /// for a list that is gone, or when the save was refused.
    public static async Task<bool> RunAsync(TasksStore store, string id, Func<string, string?, Task<bool>> confirm)
    {
        if (store.Sections.FirstOrDefault(s => s.Id == id) is not { } section) return false;
        var inside = store.Tasks.Where(t => t.Section == id).ToList();
        var message = TodoListCopy.DeleteMessage(inside.Count(t => !t.IsDone), inside.Count(t => t.IsDone));
        var name = section.Name.Length > 0 ? section.Name : TodoListCopy.FallbackName;
        if (!await confirm(TodoListCopy.DeleteTitle(name), message)) return false;
        return await store.DeleteSectionAsync(id);
    }
}

/// Edit List's state (TaskListViews.swift TaskListEditModel): a draft of one list, saved on each change as the whole
/// lists (`PUT /tasks/sections`, TasksStore.saveSection). A save that didn't land puts the controls back to what the
/// gateway keeps, unless another change has gone out since (which carries this one with it). Colour, icon, its bot,
/// New Tasks and Show in Today only on an add-on that keeps them (0.9.55, `lists: true`); an older one edits the name.
public sealed class TaskListEditModel
{
    public TasksStore Store { get; }
    public string Id { get; }
    /// The bots that could keep the list (id, name).
    public IReadOnlyList<(string Id, string Name)> Bots { get; }
    public TodoUserSection Draft { get; private set; }
    /// The name field as typed (it becomes the list's name on Enter, on leaving the field, or on Done).
    public string Name { get; set; }
    /// The draft changed (a control's value, or put back after a refused save).
    public event Action? Changed;

    private TaskListEditModel(TasksStore store, TodoUserSection section, IReadOnlyList<(string Id, string Name)> bots)
    {
        Store = store;
        Id = section.Id;
        Bots = bots;
        Draft = section;
        Name = section.Name;
    }

    /// Why Edit List can't open now (a read-only gateway, or an add-on without lists); null when it can.
    public static string? Refusal(TasksStore store, string id) =>
        store.ReadOnlyGateway ? KanbanRest.ReadOnlyNotice : !store.SectionsSupported ? TasksStore.SectionsNeedAddOn : null;

    /// The editor for a list, or null when it can't be edited (see Refusal) or is gone.
    public static TaskListEditModel? Open(TasksStore store, string id, IReadOnlyList<(string Id, string Name)> bots) =>
        Refusal(store, id) == null && store.Sections.FirstOrDefault(s => s.Id == id) is { } section ? new(store, section, bots) : null;

    /// Colour, Icon, Bot and Show in Today show (an add-on that keeps lists).
    public bool ShowsExtras => Store.ListsSupported;
    /// New Tasks (Add Without Asking / Ask First) shows once a bot keeps the list.
    public bool ShowsNewTasks => ShowsExtras && Draft.Bot != null;
    /// The picked colour, when it is one of the Mac's.
    public string? Color => Draft.Color is { } c && TodoListColors.All.Contains(c) ? c : null;
    /// The icon the pill shows.
    public string ShownIcon => Draft.Icon ?? TodoListIcons.Fallback;
    public string BotName(string id) => Bots.FirstOrDefault(b => b.Id == id) is { Name: { } name } ? name : id;
    public string BotFooter => TaskListEditCopy.BotFooter(Draft.Bot is { } bot ? BotName(bot) : null, Draft.AsksFirst);

    /// The name as typed, once it is one (commitName): trimmed and cut at 60 characters; a blank field keeps the old
    /// name; the same name sends nothing. false when nothing was saved.
    public Task<bool> CommitNameAsync()
    {
        if (TodoListCopy.CleanName(Name) is not { } clean)
        {
            Name = Draft.Name;
            Changed?.Invoke();
            return Task.FromResult(false);
        }
        Name = clean;
        if (clean == Draft.Name) return Task.FromResult(false);
        return Change(Draft with { Name = clean });
    }

    /// A swatch: picks the colour; the picked one again clears it.
    public Task<bool> PickColorAsync(string color) =>
        ShowsExtras && TodoListColors.All.Contains(color) ? Change(Draft with { Color = Color == color ? null : color }) : Task.FromResult(false);

    /// An icon: picks it; the picked one again clears it.
    public Task<bool> PickIconAsync(string icon) =>
        ShowsExtras && TodoListIcons.All.Contains(icon) ? Change(Draft with { Icon = Draft.Icon == icon ? null : icon }) : Task.FromResult(false);

    /// Kept By: a bot, or null / "" for No One.
    public Task<bool> SetBotAsync(string? bot)
    {
        var next = string.IsNullOrEmpty(bot) ? null : bot;
        if (!ShowsExtras || (next != null && !Bots.Any(b => b.Id == next))) return Task.FromResult(false);
        return Change(Draft with { Bot = next });
    }

    /// New Tasks: Ask First (true) or Add Without Asking (false); only while a bot keeps the list.
    public Task<bool> SetAsksFirstAsync(bool asksFirst) =>
        ShowsNewTasks ? Change(Draft with { AsksFirst = asksFirst }) : Task.FromResult(false);

    public Task<bool> SetInTodayAsync(bool inToday) => ShowsExtras ? Change(Draft with { InToday = inToday }) : Task.FromResult(false);

    /// Delete List…: asks first (`confirm(title, message)`), then deletes; Cancel changes nothing.
    public Task<bool> DeleteAsync(Func<string, string?, Task<bool>> confirm) => TodoListDelete.RunAsync(Store, Id, confirm);

    private Task<bool> Change(TodoUserSection next)
    {
        if (next == Draft) return Task.FromResult(true);   // already so: nothing to send
        Draft = next;
        Changed?.Invoke();
        return SaveAsync();
    }

    /// Saves the draft (nothing to do when it is what the gateway keeps). A refused save puts the draft back to the
    /// list the gateway keeps, only if no newer change has been made since.
    private async Task<bool> SaveAsync()
    {
        var next = Draft;
        if (Store.Sections.FirstOrDefault(s => s.Id == Id) == next) return true;
        if (await Store.SaveSectionAsync(next)) return true;
        if (Draft == next && Store.Sections.FirstOrDefault(s => s.Id == Id) is { } kept)
        {
            Draft = kept;
            Name = kept.Name;
            Changed?.Invoke();
        }
        return false;
    }
}
