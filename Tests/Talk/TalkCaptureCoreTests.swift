// TalkCaptureCore's takes: the WAV is written outside the lock, but always before its event goes out, and holds every
// sample fed.

import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

@Suite struct TalkCaptureCoreTests {
    /// What the emit closure saw: each finished take, and whether its file was already on disk at that moment.
    nonisolated private final class Seen: Sendable {
        let takes = Mutex<[(take: TalkTake?, kind: String, fileBytes: Int?)]>([])
    }

    private func make() -> (TalkCaptureCore, Seen, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("talk-core-\(UUID().uuidString)", isDirectory: true)
        let seen = Seen()
        let core = TalkCaptureCore(folder: folder) { event in
            func bytes(_ take: TalkTake?) -> Int? {
                guard let take else { return nil }
                return (try? FileManager.default.attributesOfItem(atPath: take.url.path)[.size] as? Int) ?? nil
            }
            switch event {
            case .takeEnded(let take): seen.takes.withLock { $0.append((take, "take", bytes(take))) }
            case .bargeUtterance(let take): seen.takes.withLock { $0.append((take, "barge", bytes(take))) }
            case .level, .bargeSpeech: break
            }
        }
        return (core, seen, folder)
    }

    private func feed(_ core: TalkCaptureCore, value: Int16, buffers: Int, size: Int = 341) {
        let chunk = [Int16](repeating: value, count: size)
        for _ in 0..<buffers { chunk.withUnsafeBufferPointer { core.feed($0) } }
    }

    @Test func aTakeEndedBySilenceIsOnDiskWithEverySampleBeforeItsEventGoesOut() {
        let (core, seen, folder) = make()
        defer { try? FileManager.default.removeItem(at: folder) }
        core.beginTake(silenceMs: 250)
        feed(core, value: 8_000, buffers: 47)           // about 1 s of speech
        var quietBuffers = 0
        while seen.takes.withLock({ $0.isEmpty }), quietBuffers < 200 {
            feed(core, value: 0, buffers: 1)
            quietBuffers += 1
        }
        let takes = seen.takes.withLock { $0 }
        #expect(takes.count == 1)
        guard let first = takes.first, let take = first.take else { return }
        #expect(first.kind == "take")
        #expect(take.heardSpeech)
        let samples = (47 + quietBuffers) * 341
        #expect(first.fileBytes == 44 + samples * 2)
        #expect(take.ms == Int(Double(samples) / 16))
        #expect(!core.isTakeOpen)
    }

    @Test func sendNowWritesTheTakeBeforeItsEvent() {
        let (core, seen, folder) = make()
        defer { try? FileManager.default.removeItem(at: folder) }
        core.beginTake(silenceMs: 2_000)
        feed(core, value: 8_000, buffers: 3_000 / 341 + 1)
        core.finishTake()
        let takes = seen.takes.withLock { $0 }
        #expect(takes.count == 1)
        #expect(takes.first?.fileBytes == 44 + (3_000 / 341 + 1) * 341 * 2)
    }

    @Test func aBargeUtteranceIsOnDiskBeforeItsEvent() {
        let (core, seen, folder) = make()
        defer { try? FileManager.default.removeItem(at: folder) }
        core.armBarge(multiplier: nil, silenceMs: 250)
        feed(core, value: 0, buffers: 25)               // calibrates the quiet floor
        feed(core, value: 8_000, buffers: 30)           // sustained speech trips the monitor
        var quietBuffers = 0
        while seen.takes.withLock({ $0.isEmpty }), quietBuffers < 200 {
            feed(core, value: 0, buffers: 1)
            quietBuffers += 1
        }
        let takes = seen.takes.withLock { $0 }
        #expect(takes.count == 1)
        guard let first = takes.first, let take = first.take else { return }
        #expect(first.kind == "barge")
        // ms is the utterance's length rounded down, so the file holds between ms and ms + 1 milliseconds of samples.
        let bytes = first.fileBytes ?? 0
        #expect(take.ms > 0)
        #expect(bytes >= 44 + take.ms * 32 && bytes < 44 + (take.ms + 1) * 32)
    }
}
