namespace Hermes.Core.Kanban;

/// Where a pick comes from (App/Pages/Kanban/KanbanTaskAttachments.swift: the Add Attachment menu's two rows).
public enum KanbanAttachmentSource { PhotoLibrary, File }

/// The folder the system picker opens in. Only a starting place: the person picks, nothing is listed by the app.
public enum KanbanPickerStart { PicturesLibrary, DocumentsLibrary }

/// One row of the Add Attachment menu and how its system picker is set up.
public sealed record KanbanAttachmentChoice(KanbanAttachmentSource Source, string Label, string AutomationId, string Glyph,
    KanbanPickerStart Start, IReadOnlyList<string> FileTypes, bool Thumbnails);

/// What the panel shows now: the task and board it is on, a counter that moves whenever the panel leaves that task (a
/// linked task opened, the panel stopped or closed), and whether a write may start.
public sealed record KanbanAttachmentState(string? TaskId, string Board, int Epoch, bool ReadOnly, bool Online, bool Uploading);

/// The task and board a pick was started for. The upload goes here, never to whatever is showing when the picker returns.
public sealed record KanbanAttachmentTarget(string TaskId, string Board, int Epoch);

/// The file the person picked (read in place; never moved, changed or removed).
public sealed record KanbanAttachmentPick(string Path, string Name);

public enum KanbanAttachmentOutcome
{
    /// One upload ran and succeeded.
    Uploaded,
    /// One upload ran and failed (the uploader showed why).
    Failed,
    /// The picker closed without a file: nothing is sent.
    Cancelled,
    /// A picker is already open or an upload is running.
    Busy,
    NoTask,
    ReadOnly,
    Offline,
    /// The panel moved to another task or board (or closed) while the picker was open: nothing is sent.
    ContextChanged,
}

/// Add Attachment on a Kanban task: Photo Library (one photo or video, the picker opening in Pictures) then Choose File
/// (one file of any kind). The task and board are bound when a row is chosen and checked again when the picker returns,
/// so a cancel, a second click, a read-only or lost gateway, or a switch of task or board never sends a file, and never
/// sends it to the wrong board. The pickers themselves are user-mediated system pickers: no library is enumerated and
/// no broad picture permission is asked for.
public sealed class KanbanAttachmentFlow(Func<KanbanAttachmentState> state)
{
    /// Photos and videos the Photo Library picker shows (PHPicker's images and movies).
    public static readonly IReadOnlyList<string> MediaTypes =
    [
        ".jpg", ".jpeg", ".png", ".gif", ".heic", ".heif", ".webp", ".bmp", ".tif", ".tiff",
        ".mov", ".mp4", ".m4v", ".avi", ".wmv", ".3gp", ".mkv", ".webm",
    ];

    public static readonly KanbanAttachmentChoice PhotoLibrary = new(KanbanAttachmentSource.PhotoLibrary, KanbanCopy.PhotoLibrary,
        "kanban.task.add-attachment.photo", "\uE91B", KanbanPickerStart.PicturesLibrary, MediaTypes, Thumbnails: true);

    public static readonly KanbanAttachmentChoice ChooseFile = new(KanbanAttachmentSource.File, KanbanCopy.ChooseFile,
        "kanban.task.add-attachment.file", "\uE8B7", KanbanPickerStart.DocumentsLibrary, ["*"], Thumbnails: false);

    /// The menu, in the Mac's order.
    public static readonly IReadOnlyList<KanbanAttachmentChoice> Choices = [PhotoLibrary, ChooseFile];

    public static KanbanAttachmentChoice For(KanbanAttachmentSource source) => source == KanbanAttachmentSource.PhotoLibrary ? PhotoLibrary : ChooseFile;

    /// The row shows: the gateway takes writes and is reachable (`canAddAttachment`).
    public static bool CanOffer(KanbanAttachmentState s) => !s.ReadOnly && s.Online;

    /// A bar shows under "Adding…" past this size (`uploadProgress`).
    public static double? StartProgress(long size) => size > KanbanAttachmentUpload.ProgressFloor ? 0 : null;

    public static double? Fraction(long sent, long total) => total > 0 ? Math.Min(1, (double)sent / total) : null;

    /// Why the attachment was not added. A pick that can't be read where it lies (gone, locked, or a cloud file with no
    /// local path) says so instead of a raw exception.
    public static (string Text, bool Gone) Reason(Exception error) =>
        KanbanAttachmentUpload.Reason(error is ArgumentException or IOException or UnauthorizedAccessException
            ? new Attachments.MultipartBody.BuildException(Attachments.MultipartBody.Failure.Unreadable)
            : error);

    /// A system picker is open.
    public bool Picking { get; private set; }

    /// Why a write can't start now, or null.
    private static KanbanAttachmentOutcome? Refusal(KanbanAttachmentState s) =>
        s.Uploading ? KanbanAttachmentOutcome.Busy
        : s.TaskId is not { Length: > 0 } ? KanbanAttachmentOutcome.NoTask
        : s.ReadOnly ? KanbanAttachmentOutcome.ReadOnly
        : !s.Online ? KanbanAttachmentOutcome.Offline
        : null;

    /// `pick` shows the system picker for the choice (null: cancelled); `upload` sends the one file to the bound target
    /// and says whether it was added. At most one picker is open and at most one upload runs per pick.
    public async Task<KanbanAttachmentOutcome> RunAsync(KanbanAttachmentSource source,
        Func<KanbanAttachmentChoice, Task<KanbanAttachmentPick?>> pick,
        Func<KanbanAttachmentTarget, KanbanAttachmentPick, Task<bool>> upload)
    {
        if (Picking) return KanbanAttachmentOutcome.Busy;
        var before = state();
        if (Refusal(before) is { } refused) return refused;
        var target = new KanbanAttachmentTarget(before.TaskId!, before.Board, before.Epoch);
        KanbanAttachmentPick? picked;
        Picking = true;
        try { picked = await pick(For(source)); }
        finally { Picking = false; }
        if (picked == null) return KanbanAttachmentOutcome.Cancelled;
        var after = state();
        if (after.TaskId != target.TaskId || after.Board != target.Board || after.Epoch != target.Epoch) return KanbanAttachmentOutcome.ContextChanged;
        if (Refusal(after) is { } late) return late;
        return await upload(target, picked) ? KanbanAttachmentOutcome.Uploaded : KanbanAttachmentOutcome.Failed;
    }
}
