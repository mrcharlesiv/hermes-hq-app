// Build 3 crash fixes: `withChildTasks` (the app's task groups without a TaskGroup) keeps the group contract, and the
// small trap/raise guards found on the way.

import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

@MainActor
struct ChildTasksTests {
    @Test func resultsComeBackInCompletionOrderThenNil() async {
        let order = await withChildTasks(of: Int.self) { group -> [Int] in
            group.addTask { try? await Task.sleep(for: .milliseconds(60)); return 1 }
            group.addTask { try? await Task.sleep(for: .milliseconds(5)); return 2 }
            group.addTask { 3 }
            var out: [Int] = []
            while let value = await group.next() { out.append(value) }
            #expect(await group.next() == nil, "nothing pending")
            return out
        }
        #expect(Set(order) == [1, 2, 3])
        #expect(order.last == 1)
    }

    @Test func returnsOnlyAfterEveryChildFinished() async {
        let finished = Atomic<Int>(0)
        await withChildTasks(of: Void.self) { group in
            for n in 0..<8 {
                group.addTask { try? await Task.sleep(for: .milliseconds(5 * n)); finished.add(1, ordering: .relaxed) }
            }
        }
        #expect(finished.load(ordering: .relaxed) == 8)
    }

    @Test func cancellingTheCallerCancelsTheChildren() async {
        let sawCancel = Atomic<Int>(0)
        let task = Task {
            await withChildTasks(of: Void.self) { group in
                for _ in 0..<4 {
                    group.addTask {
                        do { try await Task.sleep(for: .seconds(30)) } catch { sawCancel.add(1, ordering: .relaxed) }
                    }
                }
                while await group.next() != nil {}
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await task.value
        #expect(sawCancel.load(ordering: .relaxed) == 4)
    }

    @Test func aCancelledGroupStillHandsBackEveryChild() async {
        // 2026-11-09: the group's `next()` was an AsyncStream's, which answers nil as soon as the caller is cancelled;
        // the group returned with its children still running. A TaskGroup's `next()` waits for them, and so must this.
        for _ in 0..<50 {
            let task = Task {
                await withChildTasks(of: Int.self) { group -> Int in
                    for n in 0..<4 { group.addTask { try? await Task.sleep(for: .seconds(30)); return n } }
                    withUnsafeCurrentTask { $0?.cancel() }
                    var seen = 0
                    while await group.next() != nil { seen += 1 }
                    return seen
                }
            }
            #expect(await task.value == 4)
        }
    }

    @Test func childrenAddedAfterCancelAllStartCancelled() async {
        let cancelled = await withChildTasks(of: Bool.self) { group -> Bool in
            group.cancelAll()
            group.addTask { Task.isCancelled }
            return await group.next() ?? false
        }
        #expect(cancelled)
    }

    @Test func firstWinsThenTheRestIsCancelled() async {
        // `withSignOutBudget`'s shape: the first answer wins; the slower child is cancelled and still awaited.
        let answer = await withSignOutBudget { 7 }
        #expect(answer == 7)
    }

    /// Thousands of short groups with children finishing on the pool at random moments (the pattern build 3 died in).
    @Test(.timeLimit(.minutes(2))) func manyGroupsUnderLoad() async {
        var total = 0
        for round in 0..<2000 {
            total += await withChildTasks(of: (Int, Result<Int, Error>).self) { group -> Int in
                var queue = (0..<12)[...], running = 0, sum = 0
                while true {
                    while running < 3, let i = queue.first {
                        queue.removeFirst()
                        running += 1
                        group.addTask {
                            if i % 3 == 0 { await Task.yield() }
                            if (i + round) % 5 == 0 { return (i, .failure(CancellationError())) }
                            return (i, .success(i))
                        }
                    }
                    guard let (_, outcome) = await group.next() else { break }
                    running -= 1
                    if case .success(let v) = outcome { sum += v }
                }
                return sum
            }
        }
        #expect(total > 0)
    }

    /// The group came back twice after build 4 (Spawn Tree, which build 278 aborted in, and the reconnect's reattach):
    /// every concurrent fan-out goes through `withChildTasks`.
    @Test func noTaskGroupsInTheSources() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("App").path) else { return }   // no sources here
        let group = try NSRegularExpression(pattern: #"\bwith(Throwing)?(Discarding)?(Throwing)?TaskGroup\s*\("#)
        var offenders: [String] = []
        for folder in ["App", "HermesKit", "Shared", "ShareKit", "ShareExtension", "NotificationService"] {
            let files = FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)
            while let file = files?.nextObject() as? URL {
                guard file.pathExtension == "swift" else { continue }
                let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                for (index, line) in lines.enumerated() {
                    let code = line.components(separatedBy: "//")[0]
                    if group.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil {
                        offenders.append("\(file.lastPathComponent):\(index + 1)")
                    }
                }
            }
        }
        #expect(offenders.isEmpty, "use withChildTasks (HermesKit/Net/ChildTasks.swift): \(offenders.sorted().joined(separator: ", "))")
    }

    // MARK: Guards found on the way

    @Test func jsonIntNeverTrapsOnOddNumbers() {
        #expect(JSONValue.string("1e400").int == nil)
        #expect(JSONValue.string("nan").int == nil)
        #expect(JSONValue.string("-inf").int == nil)
        #expect(JSONValue.number(1e19).int == nil)
        #expect(JSONValue.number(42.9).int == 42)
        #expect(JSONValue.string("100").int == 100)
    }

    @Test func oddTableCellsRender() {
        let style = ChatStyleCache.shared.style(for: .large)
        let cells = ["\u{2028}e\u{301}\u{301}", "\u{00A0}ﬁ", "\u{3000}👩‍👩‍👧‍👦\u{FE0F}", "<br>x<br>", "\u{0F73}\u{0344}"]
        let table = "| " + cells.joined(separator: " | ") + " |\n|" + String(repeating: "---|", count: cells.count) + "\n| " +
            cells.reversed().joined(separator: " | ") + " |"
        let rendered = MarkdownRenderer.render(table, style: style, theme: .bot)
        #expect(!rendered.blocks.isEmpty)
    }
}
