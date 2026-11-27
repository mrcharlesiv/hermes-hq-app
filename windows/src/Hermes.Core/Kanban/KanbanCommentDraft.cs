namespace Hermes.Core.Kanban;

/// The task panel's comment field (App/Pages/Kanban/KanbanTaskSheet.swift comments(_:), KanbanTaskModel.sendComment):
/// a wrapping field that keeps every line break pasted into it, a trailing one too, until the comment is sent. Return
/// posts the draft once (its typed line break is never kept); Shift+Return makes a new line, as the chat field does.
/// Nothing posts while the draft is blank or a comment or Post and Start Over is already on its way. Post and Start
/// Over is its own button, never Return.
public static class KanbanCommentDraft
{
    /// What Return in the field does.
    public enum ReturnAction
    {
        /// Post the draft once (the Send button's comment, never Post and Start Over).
        Post,
        /// Take the key and do nothing: a blank draft, a comment already sending, or a held-down key repeating.
        Swallow,
        /// Leave the key to the field, which makes a new line (Shift+Return).
        NewLine,
    }

    /// The draft as the panel keeps it: a WinUI TextBox holds a line break as "\r" (and a paste may bring "\r\n"), the
    /// Mac and the gateway use "\n". Every break is kept, the last one too.
    public static string Normalize(string? fieldText) =>
        (fieldText ?? "").Replace("\r\n", "\n").Replace('\r', '\n');

    /// The field shows a different draft than the one kept (so a redraw must put the kept one back). Only the line
    /// break spelling differing is not a difference, so a redraw never moves the caret for it.
    public static bool FieldDiffers(string? fieldText, string draft) => Normalize(fieldText) != Normalize(draft);

    /// Send and Return post only words, and only once at a time.
    public static bool CanSend(string draft, bool sending) => !sending && Body(draft).Length > 0;

    /// What is posted: the draft with its line breaks, trimmed at the ends as the Mac's sendComment (pgTrim) does.
    public static string Body(string draft) => Normalize(draft).Trim();

    /// Return in the field. `repeat` is the key auto-repeating while held, which must not post a second time.
    public static ReturnAction OnReturn(string draft, bool sending, bool shift, bool repeat)
    {
        if (shift) return ReturnAction.NewLine;
        if (repeat) return ReturnAction.Swallow;
        return CanSend(draft, sending) ? ReturnAction.Post : ReturnAction.Swallow;
    }
}
