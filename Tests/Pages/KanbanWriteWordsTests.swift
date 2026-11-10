import Foundation
import Testing
@testable import HermesHQNative

/// UX study 2026-10-19 #134: a deliberate Kanban write that fails is an alert with Try Again; the rest keep the notice.
@Suite struct KanbanWriteWordsTests {
    @Test func deliberateWritesGetAnAlertTitle() {
        #expect(KanbanWriteWords.failureTitle("comment") == "Couldn’t Post the Comment")
        #expect(KanbanWriteWords.failureTitle("requeue") == "Couldn’t Post the Comment")
        #expect(KanbanWriteWords.failureTitle("body") == "Couldn’t Save the Description")
        #expect(KanbanWriteWords.failureTitle("delete") == "Couldn’t Delete the Task")
        #expect(KanbanWriteWords.failureTitle("archive") == "Couldn’t Archive the Task")
        #expect(KanbanWriteWords.failureTitle(KanbanWriteWords.undoArchive) == "Couldn’t Undo the Archive")
        #expect(KanbanWriteWords.failureTitle("move") == "Couldn’t Move the Task")
        #expect(KanbanWriteWords.failureTitle("assign") == "Couldn’t Assign the Task")
        #expect(KanbanWriteWords.failureTitle("priority") == "Couldn’t Set the Priority")
        // Audit 863 (08c-4): Post and Start Over's comment posted, its start again failed.
        #expect(KanbanWriteWords.failureTitle(KanbanWriteWords.restart) == "Couldn’t Start the Task Again")
    }

    @Test func quieterWritesKeepTheNotice() {
        #expect(KanbanWriteWords.failureTitle("estimate") == nil)
        #expect(KanbanWriteWords.failureTitle("reclaim") == nil)
        #expect(KanbanWriteWords.failureTitle("") == nil)
    }
}
