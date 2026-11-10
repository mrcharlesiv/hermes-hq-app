// [diagnostics] Build 292: a hang record says what the main thread was doing (MainTrail), and a MetricKit hang report
// keeps its main thread's frames (LogUploader.hangFrames).

import Foundation
import Testing
@testable import HermesHQNative

@Suite("Main-thread trail and hang frames", .serialized)
struct MainTrailTests {
    @Test func theSpansThatOverlappedAStallAreNamedLongestFirst() {
        let spans: [MainTrail.Span] = [
            .init(name: "chat.flush", begun: 9.0, ended: 9.01),           // before the stall
            .init(name: "chat.deliver", begun: 10.0, ended: 10.02),
            .init(name: "chat.apply", begun: 10.05, ended: 11.70),
            .init(name: "chat.deliver", begun: 11.70, ended: 11.73),
            .init(name: "browser.frame", begun: 11.74, ended: nil),       // still running
        ]
        let text = MainTrail.summary(spans, from: 10.0, to: 11.75)
        #expect(text == "chat.apply 1650ms, chat.deliver×2 50ms, browser.frame 10ms open")
        #expect(MainTrail.summary(spans, from: 5, to: 6).isEmpty)
        #expect(MainTrail.summary(spans, from: 20, to: 21) == "browser.frame 1000ms open")   // still running then
    }

    @Test func spansAndFactsAreRecordedAndAged() {
        let t = MainTrail.begin("chat.merge", at: 100)
        MainTrail.end(t, at: 100.4)
        let open = MainTrail.begin("chat.apply", at: 100.5)
        let text = MainTrail.during(from: 100, to: 101)
        #expect(text.contains("chat.apply 500ms open"))
        #expect(text.contains("chat.merge 400ms"))
        MainTrail.end(open)
        // (Keys of its own: chat suites running beside this one set the app's.)
        MainTrail.set("test.rows", "212", aged: false)
        MainTrail.set("test.catchUp", "done")
        let facts = MainTrail.facts(at: MainTrail.now() + 8)
        #expect(facts.contains("test.catchUp done 8s ago, test.rows 212"))
        MainTrail.set("test.catchUp", nil)
        #expect(!MainTrail.facts().contains("test.catchUp"))
        MainTrail.set("test.rows", nil)
    }

    @Test func aMetricKitHangKeepsItsMainThreadFramesInnermostFirst() throws {
        let json = """
        {"hangDiagnostics":[{"diagnosticMetaData":{"hangDuration":"1.7 sec","appVersion":"1.0","appBuildVersion":"292"},
         "callStackTree":{"callStackPerThread":true,"callStacks":[
          {"threadAttributed":false,"callStackRootFrames":[{"binaryName":"libsystem_kernel.dylib","binaryUUID":"AAAA","offsetIntoBinaryTextSegment":1,"sampleCount":9}]},
          {"threadAttributed":true,"callStackRootFrames":[
            {"binaryName":"CoreText","binaryUUID":"BBBBBBBB-0000","offsetIntoBinaryTextSegment":4096,"sampleCount":17,"subFrames":[
              {"binaryName":"HermesHQNative","binaryUUID":"CCCC","offsetIntoBinaryTextSegment":512,"sampleCount":2},
              {"binaryName":"UIKitCore","binaryUUID":"DDDD","offsetIntoBinaryTextSegment":64,"sampleCount":15,"subFrames":[
                {"binaryName":"HermesHQNative","binaryUUID":"CCCC","offsetIntoBinaryTextSegment":2048,"sampleCount":15}]}]}]}]}}]}
        """
        let root = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let hang = try #require((root["hangDiagnostics"] as? [[String: Any]])?.first)
        let frames = LogUploader.hangFrames(hang) { uuid, _ in uuid.hasPrefix("BBBB") ? "CTLineCreateWithAttributedString" : nil }
        #expect(frames.map(\.binary) == ["CoreText", "UIKitCore", "HermesHQNative"])
        #expect(frames.map(\.offset) == [4096, 64, 2048])
        #expect(frames.first?.symbol == "CTLineCreateWithAttributedString")
        #expect(frames.first?.uuid == "BBBBBBBB")
        let lines = LogUploader.metricKitEvents(Data(json.utf8), rec: "r1", date: Date())
        #expect(lines.contains { $0.contains("\"k\":\"hang.mk\"") && $0.contains("\"bld\":\"292\"") })
        #expect(lines.filter { $0.contains("\"k\":\"hang.mk.frame\"") }.count == 3)
    }
}
