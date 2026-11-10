import Foundation
import UIKit
import Testing
@testable import HermesHQNative

// Acceptance checks 5–7 of docs/spec/1x-attachments.md §15.1: every history shape the attachments fixture seeds
// (§14.2 rows 1–16) folds to the expected words and attachments; the display key matches the local bubble, the
// in-flight prompt and the stored row; the HQT2 cache round-trips attachments and generated images.

private func tinyPNG(_ w: Int, _ h: Int) -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).pngData { ctx in
        UIColor.orange.setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    }
}

private func dataURL(_ data: Data) -> String { "data:image/png;base64," + data.base64EncodedString() }

private func historyRows() -> [JSONValue] {
    var row = 100
    func r(_ role: String, _ content: JSONValue, _ extra: [String: JSONValue] = [:]) -> JSONValue {
        row += 1
        var o: [String: JSONValue] = ["role": .string(role), "content": content, "row_id": .number(Double(row)), "timestamp": 1791640000]
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }
    let part = tinyPNG(240, 180), a = tinyPNG(300, 300), b = tinyPNG(301, 300)
    return [
        r("user", "Here is the chart\n@image:/fixture/media/chart.png"),                                                    // 1
        r("assistant", "Got it."),                                                                                          // 2
        r("user", "@image:`/fixture/media/two words.png`\n[screenshot]"),                                                   // 3
        r("user", [["type": "text", "text": "what is this?"], ["type": "image_url", "image_url": ["url": .string(dataURL(part))]]]),  // 4
        r("user", [["type": "text", "text": "compare these\n@image:/fixture/media/a.png\n@image:/fixture/media/b.png"],
                   ["type": "image_url", "image_url": ["url": .string(dataURL(a))]],
                   ["type": "image_url", "image_url": ["url": .string(dataURL(b))]]]),                                      // 5
        r("user", "@file:/fixture-home/attachments/report.pdf\n\nPlease summarise this"),                                   // 6
        r("user", "@file:/fixture-home/attachments/report.pdf\n@file:`/fixture-home/attachments/My Notes.md`"),             // 7
        r("user", "What do you see in this image?\n@image:/fixture/media/chart.png"),                                       // 8
        r("user", "[Image attached at: /fixture/media/a.png]"),                                                             // 9
        r("assistant", "Here you go:\nMEDIA:/fixture/media/result.png\nAnd the data: MEDIA:/fixture/media/data.csv"),        // 10
        r("assistant", "![diagram](/fixture/media/diagram.png)\n\nSee [the notes](/fixture/media/notes.md)"),               // 11
        r("user", "Draw a fox"),
        r("assistant", "", ["tool_calls": [["id": "gen-fox", "type": "function", "function": [
            "name": "image_generate", "arguments": "{\"prompt\":\"a red fox\",\"aspect_ratio\":\"square\"}"]]]]),           // 12
        r("tool", "{\"success\":true,\"image\":\"/fixture/media/fox.png\",\"pixel_size\":\"1024x1024\"}",
          ["tool_call_id": "gen-fox", "tool_name": "image_generate"]),
        r("assistant", "Here's the fox."),
        r("user", "Draw another"),
        r("assistant", "", ["tool_calls": [["id": "gen-fail", "type": "function", "function": [
            "name": "image_generate", "arguments": "{\"aspect_ratio\":\"square\"}"]]]]),                                    // 13
        r("tool", "{\"success\":false,\"error\":\"No image backend configured\"}", ["tool_call_id": "gen-fail", "tool_name": "image_generate"]),
        r("user", "@image:/fixture/media/missing.png"),                                                                     // 14
        r("user", "@image:/fixture/media/huge.png"),                                                                        // 15
        r("assistant", "MEDIA:/fixture/media/clip.mov"),                                                                    // 16
    ]
}

@Suite("Attachments: history (§7.1, checks 5–7)")
struct AttachmentHydrationTests {
    private func fold() -> HydratedPage { Hydration.fold(historyRows(), pageSeq: 1) }

    private func user(_ page: HydratedPage, row: Int) throws -> (ChatMessage, [MessageAttachment]) {
        let m = try #require(page.messages.first { $0.id == "stored-row-\(row)-user" })
        return (m, page.meta[m.id]?.attachments ?? [])
    }

    @Test func everyShapeFoldsToWordsAndAttachments() throws {
        let page = fold()
        // 1: caption + one image
        var (m, a) = try user(page, row: 101)
        #expect(m.plainText == "Here is the chart")
        #expect(a.map(\.source) == [.gateway(path: "/fixture/media/chart.png")])
        #expect(a.first?.name == "chart.png")
        // 3: a quoted path with a space; [screenshot] dropped (it describes the picture)
        (m, a) = try user(page, row: 103)
        #expect(m.plainText == "")
        #expect(a.map(\.source) == [.gateway(path: "/fixture/media/two words.png")])
        // 4: an inline data part, decoded off the text, its size from the header
        (m, a) = try user(page, row: 104)
        #expect(m.plainText == "what is this?")
        #expect(a.count == 1)
        guard case .inline(let key)? = a.first?.source else { Issue.record("not inline"); return }
        #expect(key.hasPrefix("i|"))
        #expect(a.first?.pixelWidth == 240 && a.first?.pixelHeight == 180)
        // 5: native-vision pairs: two refs and two parts are the same two pictures
        (m, a) = try user(page, row: 105)
        #expect(m.plainText == "compare these")
        #expect(a.count == 2)
        #expect(a.map(\.name) == ["a.png", "b.png"])
        #expect(a.allSatisfy { if case .inline = $0.source { return true } else { return false } })
        #expect(a.last?.pixelWidth == 301)
        // 6: a leading file and words
        (m, a) = try user(page, row: 106)
        #expect(m.plainText == "Please summarise this")
        #expect(a.map(\.kind) == [.file])
        #expect(a.first?.source == .gateway(path: "/fixture-home/attachments/report.pdf"))
        // 7: files only, one quoted
        (m, a) = try user(page, row: 107)
        #expect(m.plainText == "")
        #expect(a.map(\.name) == ["report.pdf", "My Notes.md"])
        #expect(a.last?.source == .gateway(path: "/fixture-home/attachments/My Notes.md"))
        // 8: the default question stays the text (the row builder hides it under the photo)
        (m, a) = try user(page, row: 108)
        #expect(m.plainText == "What do you see in this image?")
        #expect(a.count == 1)
        // 9: the older native-vision hint is an image
        (m, a) = try user(page, row: 109)
        #expect(m.plainText == "")
        #expect(a.map(\.source) == [.gateway(path: "/fixture/media/a.png")])
        // 14, 15: plain refs
        #expect(try user(page, row: 119).1.first?.name == "missing.png")
        #expect(try user(page, row: 120).1.first?.name == "huge.png")
        // No text, part or meta anywhere holds image bytes.
        for message in page.messages {
            #expect(!message.plainText.contains("data:image"))
            #expect(!(page.meta[message.id]?.attachmentRefs ?? []).contains { $0.contains("data:image") })
        }
    }

    @Test func generatedImagesComeFromTheToolRow() throws {
        let page = fold()
        let fox = try #require(page.messages.first { m in
            m.parts.contains { if case .tool(let c) = $0 { return c.id == "gen-fox" } else { return false } }
        })
        let info = try #require(page.meta[fox.id]?.tools["gen-fox"]?.generatedImage)
        #expect(info.source == "/fixture/media/fox.png")
        #expect(info.pixelWidth == 1024 && info.aspect == .square)
        let failed = try #require(page.messages.first { m in
            m.parts.contains { if case .tool(let c) = $0 { return c.id == "gen-fail" } else { return false } }
        })
        #expect(page.meta[failed.id]?.tools["gen-fail"]?.generatedImage == nil)     // the existing failed step
    }

    @Test func rowBuilderDrawsMediaBubbles() throws {
        let page = fold()
        var attachments: [String: [MessageAttachment]] = [:]
        var generated: [String: [String: GeneratedImageInfo]] = [:]
        for (id, meta) in page.meta {
            if !meta.attachments.isEmpty { attachments[id] = meta.attachments }
            for (tid, d) in meta.tools { if let g = d.generatedImage { generated[id, default: [:]][tid] = g } }
        }
        var input = ChatRowBuilder.Input(messages: page.messages, isRunning: false, botName: "Hermes", expanded: [])
        input.media = ChatMediaSnapshot(attachments: attachments, generated: generated, context: MediaContext(accountId: "a", profile: "default"))
        let rows = ChatRowBuilder.build(input)
        func bubble(_ id: String) -> BubbleRow? {
            for r in rows where r.id == id { if case .bubble(let b) = r.kind { return b } }
            return nil
        }
        // 8: the default question draws no words under the photo
        #expect(bubble("stored-row-108-user|b0")?.text == "")
        #expect(bubble("stored-row-108-user|b0")?.media.count == 1)
        // 7: files only
        #expect(bubble("stored-row-107-user|b0")?.files.count == 2)
        // 12: the generated card replaces the tool step
        let card = rows.first { $0.id.hasSuffix("|ggen-fox") }
        #expect(card != nil)
        // 13: the failed generation stays a step
        #expect(rows.contains { if case .toolRun(let t) = $0.kind { return t.tools.first?.id == "gen-fail" } else { return false } })
    }

    @Test func displayKeyMatchesLocalInflightAndStored() {
        let local = "look"
        let inflight = "@file:/x/report.pdf\n\nlook"
        let stored = "@file:/x/report.pdf\n\nlook\n@image:/u/photo.jpg"
        #expect(Hydration.userDisplayKey(local) == Hydration.userDisplayKey(inflight))
        #expect(Hydration.userDisplayKey(stored) == Hydration.userDisplayKey(local))
        let question = AttachmentSender.defaultQuestion
        #expect(Hydration.userDisplayKey(question) == Hydration.userDisplayKey(question + "\n@image:/u/photo.jpg"))
        #expect(Hydration.userDisplayKey("plain words") == "plain words")
    }

    @Test func hqt2RoundTripsAndHQT1IsAMiss() throws {
        let page = fold()
        var meta = page.meta
        // A local send's attachments: the uploaded one is kept as its gateway path, the unfinished one dropped.
        var local = MessageMeta()
        local.attachments = [
            MessageAttachment(kind: .image, source: .local(draftId: "D1"), name: "photo.jpg", pixelWidth: 3024, pixelHeight: 4032,
                              uploadedPath: "/r/.dispatch-attachments/F/photo.jpg"),
            MessageAttachment(kind: .file, source: .local(draftId: "D2"), name: "report.pdf"),
        ]
        let localMessage = ChatMessage(id: "stored-row-900-user", role: .user, parts: [.text("look")], timestamp: Date(), rowId: 900)
        meta[localMessage.id] = local
        let entry = TranscriptEntry(messages: page.messages + [localMessage], meta: meta, savedAt: Date())
        let data = entry.encoded()
        #expect(Array(data.prefix(4)) == Array("HQT5".utf8))
        #expect(!String(decoding: data, as: UTF8.self).contains("data:image"))
        let back = try TranscriptEntry.decode(data)
        #expect(back.meta["stored-row-105-user"]?.attachments == page.meta["stored-row-105-user"]?.attachments)
        #expect(back.meta["stored-row-101-user"]?.attachments.first?.source == .gateway(path: "/fixture/media/chart.png"))
        let restored = try #require(back.meta[localMessage.id]?.attachments)
        #expect(restored.count == 1)
        #expect(restored.first?.source == .gateway(path: "/r/.dispatch-attachments/F/photo.jpg"))
        #expect(restored.first?.pixelWidth == 3024)
        let fox = try #require(page.messages.first { m in m.parts.contains { if case .tool(let c) = $0 { return c.id == "gen-fox" } else { return false } } })
        #expect(back.meta[fox.id]?.tools["gen-fox"]?.generatedImage?.source == "/fixture/media/fox.png")
        // An HQT1/HQT2 file reads as a miss (a throw the cache turns into a fresh read), never a crash.
        for magic in ["HQT1", "HQT2"] {
            var old = data
            old.replaceSubrange(0..<4, with: Array(magic.utf8))
            #expect(throws: (any Error).self) { try TranscriptEntry.decode(old) }
        }
    }
}
