// How a failed Kanban write is told (UX study 2026-10-19 #134): a deliberate write the person made or typed (a comment,
// an edit, a delete, an archive or its Undo, a move or assignment from the task sheet) gets a "Couldn’t …" alert with
// Try Again, so typed work is never lost to a 3-second line; a board drag-move or a background read keeps the short
// notice (the card snaps back, which is feedback enough). Pure, so the choice is unit-tested without UIKit.

import Foundation

nonisolated enum KanbanWriteWords {
    /// The task sheet's write keys (`KanbanTaskModel.run`) and the board's Undo.
    static let undoArchive = "unarchive"
    /// Post and Start Over's second step (its comment is posted; only the start again is tried again).
    static let restart = "restart"

    /// The alert's title for a failed write, or nil when the short notice is enough.
    static func failureTitle(_ key: String) -> String? {
        switch key {
        case "move": "Couldn’t Move the Task"
        case "assign": "Couldn’t Assign the Task"
        case "priority": "Couldn’t Set the Priority"
        case "body": "Couldn’t Save the Description"
        case "comment", "requeue": "Couldn’t Post the Comment"
        case restart: "Couldn’t Start the Task Again"
        case "archive": "Couldn’t Archive the Task"
        case undoArchive: "Couldn’t Undo the Archive"
        case "delete": "Couldn’t Delete the Task"
        default: nil
        }
    }
}
