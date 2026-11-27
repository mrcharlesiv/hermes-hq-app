namespace Hermes.Core.Kanban;

/// A card's words (App/Pages/Kanban/KanbanRowView.swift KanbanRowModel): the title, the face of who runs it, and the
/// meta bits under it.
public sealed record KanbanCardBit(string Text, bool Alert);

public sealed record KanbanCardModel(string Id, string Title, string? Assignee, IReadOnlyList<KanbanCardBit> Bits)
{
    /// What a screen reader hears.
    public string Spoken => $"{Title}. {string.Join(", ", Bits.Select(b => b.Text))}";

    /// The meta bits (`board-page.tsx` `rowMeta`): who, why blocked, no-one-assigned, running for, age, comments.
    public static IReadOnlyList<KanbanCardBit> BitsFor(KanbanTask task, string fallback, Func<string?, string> botName, DateTimeOffset now)
    {
        var who = task.Assignee ?? (task.Status == "ready" && fallback.Length > 0 ? fallback : null);
        var bits = new List<KanbanCardBit> { new(botName(who), false) };
        if (task.Status == "blocked") bits.Add(new(KanbanModel.BlockReason(task.BlockKind), true));
        if (task.Status == "ready" && task.Assignee == null && fallback.Length == 0) bits.Add(new("No one assigned, won’t run", true));
        if (task.Status == "running")
            bits.Add(new($"Running {KanbanModel.ShortAge(task.CurrentRunStartedAt ?? task.StartedAt, now)}".Trim(), false));
        var age = KanbanModel.ShortAge(task.Status == "done" ? task.CompletedAt ?? task.CreatedAt : task.CreatedAt, now);
        if (age.Length > 0 && task.Status != "running") bits.Add(new(age, false));
        if (task.CommentCount is > 0 and var count) bits.Add(new($"{count} {(count == 1 ? "comment" : "comments")}", false));
        return bits;
    }

    public static KanbanCardModel For(KanbanTask task, string fallback, Func<string?, string> botName, DateTimeOffset now)
    {
        var who = task.Assignee ?? (task.Status == "ready" && fallback.Length > 0 ? fallback : null);
        return new KanbanCardModel(task.Id, task.Title, who, BitsFor(task, fallback, botName, now));
    }
}

/// How a failed Kanban write is told (HermesKit/Pages/KanbanWriteWords.swift, UX study #134): a deliberate write gets a
/// "Couldn’t …" alert with Try Again; a board drag-move or a background read keeps the short notice.
public static class KanbanWriteWords
{
    public const string UndoArchive = "unarchive";
    public const string Restart = "restart";

    public static string? FailureTitle(string key) => key switch
    {
        "move" => "Couldn’t Move the Task",
        "assign" => "Couldn’t Assign the Task",
        "priority" => "Couldn’t Set the Priority",
        "body" => "Couldn’t Save the Description",
        "comment" or "requeue" => "Couldn’t Post the Comment",
        Restart => "Couldn’t Start the Task Again",
        "archive" => "Couldn’t Archive the Task",
        UndoArchive => "Couldn’t Undo the Archive",
        "delete" => "Couldn’t Delete the Task",
        _ => null,
    };

    public const string FallbackTitle = "Couldn’t Save the Change";
}

/// The page's own words (App/Pages/Kanban/*.swift), so the Windows screens say exactly what the Mac's do.
public static class KanbanCopy
{
    public const string Title = "Kanban";
    public const string SearchPlaceholder = "Search Tasks";
    public const string HowKanbanWorks = "How Kanban Works";
    public const string NewTask = "New Task";
    public const string NewTaskEllipsis = "New Task…";
    public const string NoTasks = "No tasks";
    public const string NoTasksYet = "No Tasks Yet";
    public const string NoTasksYetHelp = "Tasks you and your bots add to this board show here.";
    public const string CouldNotLoadBoard = "Couldn’t Load the Board";
    public const string TryAgain = "Try Again";
    public const string Trying = "Trying…";
    public const string Loading = "Loading…";
    public const string CouldNotRefresh = "Couldn’t refresh. Showing what was saved.";
    public const string Boards = "Boards";
    public const string OpenTask = "Open Task";
    public const string MoveTo = "Move To";
    public const string AssignTo = "Assign To";
    public const string Archive = "Archive";
    public const string DeleteTaskEllipsis = "Delete Task…";
    public const string DeleteThisTask = "Delete This Task?";
    public const string DeleteTask = "Delete Task";
    public const string Delete = "Delete";
    public const string Cancel = "Cancel";
    public const string Archived = "Archived";
    public const string ArchivedDetail = "Archived tasks are on the desktop board.";
    public const string Undo = "Undo";

    public static string DeleteMessage(string title) => $"“{title}” is deleted for every bot and device. This can’t be undone.";

    public static string NoResults(string query) => $"No Results for “{query}”";
    public const string TryAnotherWord = "Try another word.";

    public static string TaskCount(int total) => $"{total} {(total == 1 ? "task" : "tasks")}";

    public const string AboutIntro = "You don’t run the tasks; your bots do. Put a task in Ready with someone assigned and that bot picks it up within a minute.";
    /// The Mac's words, Control-click as right-click (PORTING.md).
    public const string AboutGestures = "Right‑click a task for Move To, Assign To and Delete.";

    // The task sheet (App/Pages/Kanban/KanbanTaskSheet.swift).
    public const string Task = "Task";
    public const string CloseTask = "Close Task";
    public const string More = "More";
    public const string CopyTitle = "Copy Title";
    public const string CopyTaskId = "Copy Task ID";
    public const string CouldNotLoadTask = "Couldn’t Load This Task";
    public const string CheckConnection = "Check your connection, then try again.";
    public const string WaitingOn = "Waiting On";
    public const string HoldingUp = "Holding Up";
    public const string Result = "Result";
    public const string LatestUpdate = "Latest Update";
    public const string LastError = "Last Error";
    public const string Attachments = "Attachments";
    public const string AttachmentsFooter = "Files you add here go to the bot with the task.";
    public const string AddAttachment = "Add Attachment";
    public const string ChooseFile = "Choose File";
    public const string PhotoLibrary = "Photo Library";
    public const string Adding = "Adding…";
    public const string AttachmentAdded = "Attachment Added";
    public const string EstimateEffort = "Estimate Effort";
    public const string Estimating = "Estimating…";
    public const string EstimateFooter = "Asks a model for a rough size of the work.";
    public const string Details = "Details";
    public const string Created = "Created";
    public const string CreatedBy = "Created By";
    public const string Finished = "Finished";
    public const string FailedRuns = "Failed Runs in a Row";
    public const string Model = "Model";
    public const string BotsOwnModel = "The bot’s own";
    public const string Workspace = "Workspace";
    public const string TaskId = "Task ID";
    public const string Description = "Description";
    public const string AddDescription = "Add a Description";
    public const string Edit = "Edit";
    public const string Save = "Save";
    public const string Comments = "Comments";
    public const string Activity = "Activity";
    public const string Runs = "Runs";
    public const string Log = "Log";
    public const string CommentsFooter = "Comments are part of what the bot reads when it picks this up.";
    public const string CommentsFooterRunning = "The bot reads new comments while it works.";
    public const string AddComment = "Add a comment";
    public const string MessageWorker = "Message the bot working on this";
    public const string PostAndStartOver = "Post and Start Over";
    public const string NotePosted = "Note posted. The task starts again with it.";
    public const string You = "You";
    public const string Moving = "Moving…";
    public const string AssignedTo = "Assigned To";
    public const string Priority = "Priority";
    public const string PriorityMenu = "Priority · Higher Goes First";
    public const string OtherNumber = "Other Number…";
    public const string PriorityPrompt = "Higher numbers are picked up first.";
    public const string PriorityWhole = "Priority is a whole number, 0 or more";
    public const string Set = "Set";
    public const string None = "None";
    public const string StartedJustNow = "Started just now";
    public const string BlockedDetail = "The bot stopped and is waiting. Add a comment with what it needs, then unblock it.";
    public const string WontRunYet = "Won’t Run Yet";
    public const string WontRunDetail = "No one is assigned and this board has no default bot. Assign it to a bot below.";
    public const string ShowMore = "Show More";
    public const string ShowLess = "Show Less";

    public static string WorkingOnIt(string? bot) => bot == null ? "A bot is working on it" : $"{bot} is working on it";
    public static string SoFar(string running) => running.Length == 0 ? StartedJustNow : $"{running} so far";
    public static string CommentsTab(int count) => count == 0 ? Comments : $"Comments {count}";
    public static string Copied(string what) => $"Copied {what}";

    // New Task (App/Pages/Kanban/NewTaskSheet.swift).
    public const string Add = "Add";
    public const string WhatNeedsDoing = "What needs doing?";
    public const string DetailsOptional = "Details (optional)";
    public const string WhoDoesIt = "Who Does It";
    public const string NoOneYet = "No One Yet";
    public const string WaitsUntilAssigned = "The task waits until you assign it.";
    public const string StartIn = "Start In";
    public const string MoreOptions = "More Options";
    public const string HigherGoesFirst = "Higher goes first.";
    public const string Skills = "Skills";
    public const string SkillsPlaceholder = "translation, github";
    public const string SkillsHelp = "Skills the bot loads for this task, separated by commas.";
    public const string GoalMode = "Goal Mode";
    public const string GoalModeHelp = "The bot keeps working until a judge agrees the task is done.";
    public const string BoardSettingsNote = "The task uses this board’s workspace and the bot’s own model. Change those on the desktop board.";
    public static string CouldNotAdd(string failure) => $"Couldn’t Add the Task. {failure}";
}
