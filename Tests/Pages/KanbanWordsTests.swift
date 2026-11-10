import Testing
@testable import HermesHQNative

/// UX study 2026-10-19 #115: the task sheet's words say who is working and which way Priority counts.
struct KanbanWordsTests {
    @Test func aRunningTaskNamesItsBot() {
        #expect(KanbanModel.statusLine("running", worker: "Deploys") == "Deploys is working on it.")
        #expect(KanbanModel.statusLine("running", worker: nil) == "A bot is working on it.")
        #expect(KanbanModel.statusLine("todo", worker: "Deploys") == "Waits until the tasks it depends on are done.")
    }

    @Test func priorityWordsSayWhichWayItCounts() {
        #expect(KanbanModel.priorityWords(0) == "None")
        #expect(KanbanModel.priorityWords(3) == "3 (higher goes first)")
    }
}
