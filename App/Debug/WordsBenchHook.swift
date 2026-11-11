// DEBUG-only: `-HQDebugWordsBench <speed> -HQDebugWordsBenchURL http://127.0.0.1:<port>` plays recordings through More
// Accurate Words (the real model, as a memo would be heard: fed as it "arrives", `speed` times faster than life). The
// Mac app is sandboxed, so the recordings come from a stand-in server on this machine (scripts/fixtures/words-bench.py):
// GET /list.txt names the 16 kHz mono WAVs, GET /<name> gives one, POST /status and POST /out.json take the progress
// and what was heard. How the 2026-11-10 study's memos were checked on the model inside the app
// (docs/spec/3x-live-words.md §7). The words go to that server only: nothing is logged.

#if DEBUG
import AVFAudio
import Foundation

@MainActor enum WordsBenchHook {
    static func applyBeforeLaunch() {
        let speed = UserDefaults.standard.double(forKey: "HQDebugWordsBench")
        guard speed > 0, let base = UserDefaults.standard.string(forKey: "HQDebugWordsBenchURL").flatMap(URL.init(string:)) else { return }
        Task { await run(speed: speed, base: base) }
    }

    private static func post(_ data: Data, to url: URL) async {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        _ = try? await URLSession.shared.upload(for: request, from: data)
    }

    private static func run(speed: Double, base: URL) async {
        func note(_ status: String) { Task { await post(Data(status.utf8), to: base.appendingPathComponent("status")) } }
        LiveWords.prepare()
        let started = Date()
        while ParakeetWords.readiness != .ready {
            if case .unavailable(let why) = ParakeetWords.readiness { return note("unavailable: \(why)") }
            note("waiting for the model: \(ParakeetWords.diagnosticsLine ?? "off") after \(Int(Date().timeIntervalSince(started))) s")
            try? await Task.sleep(for: .seconds(1))
        }
        let loaded = Date().timeIntervalSince(started)
        guard let list = try? await URLSession.shared.data(from: base.appendingPathComponent("list.txt")).0 else { return note("no list") }
        let files = String(decoding: list, as: UTF8.self).split(separator: "\n").map(String.init)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("words-bench.wav")
        let tidy = LiveWordsVocabulary.tidy()
        var out: [[String: Any]] = []
        for (index, file) in files.enumerated() {
            note("model ready after \(Int(loaded)) s; hearing \(index + 1) of \(files.count)")
            guard let sound = try? await URLSession.shared.data(from: base.appendingPathComponent(file)).0,
                  (try? sound.write(to: scratch)) != nil,
                  let audio = try? AVAudioFile(forReading: scratch, commonFormat: .pcmFormatInt16, interleaved: true),
                  audio.processingFormat.sampleRate == 16_000, audio.processingFormat.channelCount == 1,
                  let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)),
                  (try? audio.read(into: buffer)) != nil, let channel = buffer.int16ChannelData?[0] else { continue }
            var updates = 0
            var firstWords: Double?
            let begun = Date()
            guard let listener = ParakeetWords.listen(onText: { text in
                updates += 1
                if firstWords == nil, !text.isEmpty { firstWords = Date().timeIntervalSince(begun) * speed }
            }) else { return note("the model went away") }
            let total = Int(buffer.frameLength), chunk = 1_600
            var at = 0
            while at < total {
                let count = min(chunk, total - at)
                listener.feed(UnsafeBufferPointer(start: channel + at, count: count))
                at += count
                try? await Task.sleep(for: .seconds(0.1 / speed))
            }
            let ending = Date()
            let words = await listener.finish()
            let wholeBegun = Date()
            let whole = await ParakeetWords.hearWhole((0..<total).map { Float(channel[$0]) / 32_768 }) ?? ""
            let wholeIn = Date().timeIntervalSince(wholeBegun)
            out.append(["file": file, "words": words, "whole": whole, "wholeIn": wholeIn, "tidied": tidy.apply(words), "seconds": Double(total) / 16_000,
                        "updates": updates, "firstWordsAfter": firstWords ?? -1, "settledIn": Date().timeIntervalSince(ending)])
        }
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
            await post(data, to: base.appendingPathComponent("out.json"))
        }
        note("done: \(out.count) of \(files.count) heard")
    }
}
#endif
