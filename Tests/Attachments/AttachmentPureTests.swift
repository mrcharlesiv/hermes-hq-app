import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers
import Testing
import Synchronization
@testable import HermesHQNative

// Acceptance checks 1–4, 10–13 of docs/spec/1x-attachments.md §15.1: multipart bytes, the photo normaliser, safe
// names, the prompt text, retention, the remote-image policy, media layout and markdown media.

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "hqn-attach-tests-" + UUID().uuidString, directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("Attachments: multipart body (§3.3, check 1)")
struct MultipartBodyTests {
    @Test func bodyIsByteExact() throws {
        let dir = tempDir()
        let source = dir.appending(path: "a.pdf")
        try Data("xyz".utf8).write(to: source)
        let built = try MultipartBody.build(source: source, destination: "/r/.dispatch-attachments/F/a.pdf", filename: "a.pdf",
                                            boundary: "hermes-B", in: dir)
        let expected = "--hermes-B\r\nContent-Disposition: form-data; name=\"path\"\r\n\r\n/r/.dispatch-attachments/F/a.pdf\r\n"
            + "--hermes-B\r\nContent-Disposition: form-data; name=\"overwrite\"\r\n\r\nfalse\r\n"
            + "--hermes-B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.pdf\"\r\n"
            + "Content-Type: application/octet-stream\r\n\r\nxyz\r\n--hermes-B--\r\n"
        #expect(try Data(contentsOf: built.url) == Data(expected.utf8))
        #expect(built.length == Int64(expected.utf8.count))
        #expect(built.contentType == "multipart/form-data; boundary=hermes-B")
    }

    @Test func unsafeNamesAreRefused() throws {
        let dir = tempDir()
        let source = dir.appending(path: "a.pdf")
        try Data("xyz".utf8).write(to: source)
        for bad in ["a\rb.pdf", "a\nb.pdf", "a\r\nb.pdf", "a\"b.pdf", "a\\b.pdf"] {
            #expect(throws: MultipartBody.Failure.unsafeName) {
                try MultipartBody.build(source: source, destination: "/r/x/" + bad, filename: bad, boundary: "hermes-B", in: dir)
            }
        }
    }

    /// A Windows gateway's upload folder has backslashes (a tester's screenshot was stopped by them, build 382).
    @Test func aWindowsFolderIsSent() throws {
        let dir = tempDir()
        let source = dir.appending(path: "a.png")
        try Data("xyz".utf8).write(to: source)
        let destination = #"C:\Users\Ann\.hermes\files/.dispatch-attachments/F/a.png"#
        let built = try MultipartBody.build(source: source, destination: destination, filename: "a.png", boundary: "hermes-B", in: dir)
        let body = String(decoding: try Data(contentsOf: built.url), as: UTF8.self)
        #expect(body.contains("name=\"path\"\r\n\r\n" + destination + "\r\n"))
        #expect(throws: MultipartBody.Failure.unsafeName) {
            try MultipartBody.build(source: source, destination: "C:\\x\r\ny/a.png", filename: "a.png", boundary: "hermes-B", in: dir)
        }
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func tooLargeStopsAndLeavesNoBody() throws {
        let dir = tempDir()
        let out = dir.appending(path: "bodies", directoryHint: .isDirectory)
        let source = dir.appending(path: "big.bin")
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(AttachmentStaging.maxItemBytes) + 1024 * 1024)   // past the limit, whatever it is (100 MB since the tester fixes)
        try handle.close()
        #expect(throws: MultipartBody.Failure.tooLarge) {
            try MultipartBody.build(source: source, destination: "/r/x/big.bin", filename: "big.bin", boundary: "hermes-B", in: out)
        }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []
        #expect(left.isEmpty)
    }
}

@Suite("Attachments: photo normaliser (§5.1, check 2)")
struct PhotoNormalizerTests {
    private func write(_ image: CGImage, type: UTType, to url: URL, properties: [CFString: Any]? = nil, frames: Int = 1) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, frames, nil) else { return false }
        for _ in 0..<frames { CGImageDestinationAddImage(dest, image, properties as CFDictionary?) }
        return CGImageDestinationFinalize(dest)
    }

    private func image(_ w: Int, _ h: Int, alpha: Bool = false, clearCorner: Bool = false) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        if clearCorner { ctx.clear(CGRect(x: 0, y: 0, width: w / 2, height: h / 2)) }
        return ctx.makeImage()!
    }

    @Test func phonePhotoBecomesAMetadataFreePortraitJPEG() throws {
        let dir = tempDir()
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 37.33, kCGImagePropertyGPSLatitudeRef: "N",
                                    kCGImagePropertyGPSLongitude: 122.0, kCGImagePropertyGPSLongitudeRef: "W"]
        let props: [CFString: Any] = [kCGImagePropertyOrientation: 6, kCGImagePropertyGPSDictionary: gps,
                                      kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Phone", kCGImagePropertyTIFFModel: "One"],
                                      kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:10 09:00:00"]]
        var source = dir.appending(path: "IMG_0001.heic")
        if !write(image(4032, 3024), type: .heic, to: source, properties: props) {
            source = dir.appending(path: "IMG_0001.jpg")        // no HEIC encoder here: the same photo as JPEG
            #expect(write(image(4032, 3024), type: .jpeg, to: source, properties: props))
        }
        let folder = dir.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let out = try PhotoNormalizer.normalize(source, stem: "photo", into: folder)
        #expect(out.name == "photo.jpg")
        #expect(out.typeIdentifier == UTType.jpeg.identifier)
        #expect(max(out.pixelWidth, out.pixelHeight) == 3072)
        #expect(out.pixelWidth < out.pixelHeight)                 // orientation 6 applied to the pixels
        let check = try #require(CGImageSourceCreateWithURL(out.url as CFURL, nil))
        let read = try #require(CGImageSourceCopyPropertiesAtIndex(check, 0, nil) as? [CFString: Any])
        #expect(read[kCGImagePropertyGPSDictionary] == nil)
        let tiff = read[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect(tiff?[kCGImagePropertyTIFFMake] == nil)
        #expect(tiff?[kCGImagePropertyTIFFModel] == nil)
        let exif = read[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifDateTimeOriginal] == nil)
        let orientation = (read[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        #expect(orientation == 1)
    }

    @Test func transparencyKeepsPNGOpaquePNGBecomesJPEG() throws {
        let dir = tempDir()
        let clear = dir.appending(path: "clear.png"), opaque = dir.appending(path: "opaque.png")
        #expect(write(image(200, 200, alpha: true, clearCorner: true), type: .png, to: clear))
        #expect(write(image(200, 200, alpha: true), type: .png, to: opaque))
        let a = try PhotoNormalizer.normalize(clear, stem: "clear", into: dir)
        let b = try PhotoNormalizer.normalize(opaque, stem: "opaque", into: dir)
        #expect(a.name == "clear.png")
        #expect(b.name == "opaque.jpg")
    }

    @Test func animatedGIFIsCopiedUnchanged() throws {
        let dir = tempDir()
        let gif = dir.appending(path: "spin.gif")
        #expect(write(image(40, 40), type: .gif, to: gif, frames: 3))
        let folder = dir.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let out = try PhotoNormalizer.normalize(gif, stem: "spin", into: folder)
        #expect(out.name == "spin.gif")
        #expect(try Data(contentsOf: out.url) == Data(contentsOf: gif))
    }

    /// A pick of many photos normalises at most two at a time.
    @Test func thePrepGateRunsTwoAtATime() async {
        PhotoPrepGate.debugInFlight.withLock { $0.peak = 0 }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            for _ in 0..<6 {
                DispatchQueue.global(qos: .userInitiated).async(group: group) { @Sendable in PhotoPrepGate.run { Thread.sleep(forTimeInterval: 0.05) } }
            }
            group.notify(queue: .global()) { @Sendable in done.resume() }
        }
        let peak = PhotoPrepGate.debugInFlight.withLock { $0.peak }
        #expect(peak >= 1 && peak <= 2)
    }

    /// A pasted image is written and normalised off the main thread.
    @Test @MainActor func aPastedImageIsPreparedOffMain() async throws {
        let dir = tempDir()
        let png = dir.appending(path: "paste.png")
        #expect(write(image(300, 200), type: .png, to: png))
        let provider = NSItemProvider(item: try Data(contentsOf: png) as NSData, typeIdentifier: UTType.png.identifier)
        let staging = AttachmentStaging(accountId: "paste-test", base: dir)
        let id = UUID().uuidString
        let out = try await LibraryImport.loadPasted(provider, id: id, staging: staging)
        #expect(out.name == "clipboard.jpg")
        #expect(out.pixelWidth == 300)
        #expect(LibraryImport.debugPasteOnMain.withLock { $0 } == false)
    }
}

@Suite("Attachments: names, prompt text, retention (checks 3, 4, 10)")
struct AttachmentNamingTests {
    @Test func safeNamesMatchTheWebs() {
        #expect(AttachmentStaging.safeName("../x") == "x")
        #expect(AttachmentStaging.safeName("a\"b.pdf") == "ab.pdf")
        #expect(AttachmentStaging.safeName("con:trol") == "control")
        #expect(AttachmentStaging.safeName(".") == "attachment")
        #expect(AttachmentStaging.safeName("") == "attachment")
        let emoji = String(repeating: "😀", count: 75) + ".pdf"       // 300 + 4 bytes
        let safe = AttachmentStaging.safeName(emoji)
        #expect(safe.utf8.count <= 180)
        #expect(safe.hasSuffix(".pdf"))
        #expect(safe.unicodeScalars.dropLast(4).allSatisfy { $0 == "😀".unicodeScalars.first! })
    }

    @Test func promptTextTable() {
        typealias S = AttachmentSender
        #expect(S.promptText(typed: "hello", fileRefs: [], hasImages: true) == "hello")
        #expect(S.promptText(typed: "", fileRefs: [], hasImages: true) == "What do you see in this image?")
        #expect(S.promptText(typed: "  \n ", fileRefs: [], hasImages: true) == "What do you see in this image?")
        #expect(S.promptText(typed: "summarise", fileRefs: ["@file:/Users/ivy/.hermes/attachments/report.pdf"], hasImages: false)
            == "@file:/Users/ivy/.hermes/attachments/report.pdf\n\nsummarise")
        #expect(S.promptText(typed: "", fileRefs: ["@file:/a/report.pdf", "@file:`/a/My Notes.md`"], hasImages: false)
            == "@file:/a/report.pdf\n@file:`/a/My Notes.md`")
        #expect(S.promptText(typed: "look", fileRefs: ["@file:/a/report.pdf"], hasImages: true) == "@file:/a/report.pdf\n\nlook")
        #expect(S.promptText(typed: "", fileRefs: [], hasImages: false) == "")
    }

    @Test func stagedCopyReleasedTable() {
        let folder = "/r/.dispatch-attachments/F"
        #expect(AttachmentStager.stagedCopyReleased(uploaded: true, storedPath: "/home/.hermes/attachments/a.pdf", folder: folder))
        #expect(!AttachmentStager.stagedCopyReleased(uploaded: true, storedPath: folder + "/a.pdf", folder: folder))
        #expect(!AttachmentStager.stagedCopyReleased(uploaded: true, storedPath: folder, folder: folder))
        #expect(!AttachmentStager.stagedCopyReleased(uploaded: false, storedPath: "/elsewhere/a.pdf", folder: folder))
        #expect(!AttachmentStager.stagedCopyReleased(uploaded: nil, storedPath: "/elsewhere/a.pdf", folder: folder))
        #expect(!AttachmentStager.stagedCopyReleased(uploaded: true, storedPath: "", folder: folder))
    }

    @Test func sweepKeepsReferencedAndYoungFolders() throws {
        let base = tempDir()
        let staging = AttachmentStaging(accountId: "sweep-test", base: base)
        let old = UUID().uuidString, kept = UUID().uuidString, young = UUID().uuidString
        for id in [old, kept, young] { _ = try staging.write(Data("x".utf8), id: id, name: "a.txt") }
        let past = Date().addingTimeInterval(-3600)
        for id in [old, kept] {
            try FileManager.default.setAttributes([.creationDate: past, .modificationDate: past],
                                                  ofItemAtPath: staging.root.appending(path: id).path)
        }
        let removed = staging.sweep(keeping: [kept])
        #expect(removed == [old])
        #expect(FileManager.default.fileExists(atPath: staging.root.appending(path: kept).path))
        #expect(FileManager.default.fileExists(atPath: staging.root.appending(path: young).path))
        #expect(staging.url(forLocalFile: "../etc/passwd") == nil)
        #expect(staging.url(forLocalFile: "not-a-uuid/a.txt") == nil)
    }
}

@Suite("Attachments: remote images (§8.4, check 11)")
struct RemoteImagePolicyTests {
    @Test func onlyPublicHTTPSHostsAreFetched() {
        let publicResolver: (String) -> [String] = { _ in ["93.184.216.34"] }
        for refused in ["http://example.com/a.png", "https://10.0.0.1/a.png", "https://192.168.1.2/a.png", "https://172.20.0.1/a.png",
                        "https://100.100.1.1/a.png", "https://127.0.0.1/a.png", "https://[::1]/a.png", "https://[fd7a:115c:a1e0::1]/a.png",
                        "https://x.local/a.png", "https://box.tail1234.ts.net/a.png", "https://localhost/a.png"] {
            #expect(!RemoteImagePolicy.admits(URL(string: refused)!, resolver: publicResolver), "\(refused)")
        }
        #expect(RemoteImagePolicy.admits(URL(string: "https://images.example.com/a.png")!, resolver: publicResolver))
        // A public name that resolves to a private address (DNS rebinding, a redirect target) is refused too.
        #expect(!RemoteImagePolicy.admits(URL(string: "https://evil.example.com/a.png")!, resolver: { _ in ["10.1.2.3"] }))
        #expect(!RemoteImagePolicy.admits(URL(string: "https://mixed.example.com/a.png")!, resolver: { _ in ["8.8.8.8", "100.64.0.1"] }))
        #expect(RemoteImagePolicy.maxRedirects == 5)
    }

    @Test func theAsyncCheckMatchesTheBlockingOne() async {
        #expect(await RemoteImagePolicy.admitsAsync(URL(string: "https://images.example.com/a.png")!, resolver: { _ in ["93.184.216.34"] }))
        #expect(!(await RemoteImagePolicy.admitsAsync(URL(string: "https://evil.example.com/a.png")!, resolver: { _ in ["10.1.2.3"] })))
        #expect(!(await RemoteImagePolicy.admitsAsync(URL(string: "https://mixed.example.com/a.png")!, resolver: { _ in ["8.8.8.8", "100.64.0.1"] })))
        #expect(!(await RemoteImagePolicy.admitsAsync(URL(string: "https://none.example.com/a.png")!, resolver: { _ in [] })))
    }

    /// A lookup that hangs answers "timed out" (nil) by the deadline, which the fetch treats as unreachable.
    @Test func aSlowLookupTimesOut() async {
        let started = ContinuousClock.now
        let answer = await RemoteImagePolicy.admission(URL(string: "https://slow.example.com/a.png")!, timeout: .milliseconds(50),
                                                       resolver: { _ in Thread.sleep(forTimeInterval: 1); return ["93.184.216.34"] })
        #expect(answer == nil)
        #expect(ContinuousClock.now - started < .milliseconds(800))
    }

    /// Literals and refused names answer without a lookup.
    @Test func cheapChecksSkipTheLookup() async {
        let calls = Mutex(0)
        let counting: @Sendable (String) -> [String] = { _ in calls.withLock { $0 += 1 }; return ["93.184.216.34"] }
        #expect(await RemoteImagePolicy.admitsAsync(URL(string: "https://93.184.216.34/a.png")!, resolver: counting))
        #expect(!(await RemoteImagePolicy.admitsAsync(URL(string: "https://10.0.0.1/a.png")!, resolver: counting)))
        #expect(!(await RemoteImagePolicy.admitsAsync(URL(string: "http://example.com/a.png")!, resolver: counting)))
        #expect(!(await RemoteImagePolicy.admitsAsync(URL(string: "https://x.local/a.png")!, resolver: counting)))
        #expect(calls.withLock { $0 } == 0)
    }
}

@Suite("Attachments: media layout (§7.3, check 12)")
struct MediaLayoutTests {
    @Test func singlePhotoRules() {
        #expect(MediaLayout.single(width: 1200, height: 800, maxWidth: 320) == CGSize(width: 260, height: 173))
        #expect(MediaLayout.single(width: 1000, height: 3000, maxWidth: 320) == CGSize(width: 150, height: 320))   // tall: ≥ 150 wide
        #expect(MediaLayout.single(width: 3000, height: 400, maxWidth: 320) == CGSize(width: 260, height: 100))    // wide: ≥ 100 tall
        #expect(MediaLayout.single(width: nil, height: nil, maxWidth: 320) == CGSize(width: 260, height: 195))     // unknown
        #expect(MediaLayout.single(width: nil, height: nil, maxWidth: 200) == CGSize(width: 200, height: 195))
    }

    @Test func albumsFollowFromTheWidthAlone() {
        let unknown: (Int?, Int?) = (nil, nil)
        for maxW in [260.0, 320.0] as [CGFloat] {
            let two = MediaLayout.frames(sizes: Array(repeating: unknown, count: 2), maxWidth: maxW)
            #expect(two.size == CGSize(width: 260, height: 129))
            #expect(two.frames.map(\.width) == [129, 129])
            let three = MediaLayout.frames(sizes: Array(repeating: unknown, count: 3), maxWidth: maxW)
            #expect(three.frames[0] == CGRect(x: 0, y: 0, width: 260, height: 130))
            #expect(three.frames[1].width == three.frames[1].height)
            #expect(three.size.height == CGFloat(261))
            let four = MediaLayout.frames(sizes: Array(repeating: unknown, count: 4), maxWidth: maxW)
            #expect(four.size == CGSize(width: 260, height: 260))
            let five = MediaLayout.frames(sizes: Array(repeating: unknown, count: 5), maxWidth: maxW)
            #expect(five.frames.count == 5)
            #expect(five.frames[3].width == 129 && five.frames[4].maxX == 260)          // the last row shares its width
            let seven = MediaLayout.frames(sizes: Array(repeating: unknown, count: 7), maxWidth: maxW)
            #expect(seven.frames[6].width == 260)
            let sixteen = MediaLayout.frames(sizes: Array(repeating: unknown, count: 16), maxWidth: maxW)
            #expect(sixteen.frames.count == 16)
            #expect(sixteen.size.height == CGFloat(520))
            // Known pixel sizes never change an album's geometry (heights never wait for pixels).
            let known = MediaLayout.frames(sizes: Array(repeating: (4000, 1000), count: 5), maxWidth: maxW)
            #expect(known.frames == five.frames)
        }
        #expect(MediaLayout.frames(sizes: [(nil, nil), (nil, nil)], maxWidth: 200).size.width == 200)
    }

    @Test func fileRowsGetRealPadding() {
        let style = ChatStyleCache.shared.style(for: .large)
        let item = FileItem(attachment: MessageAttachment(kind: .file, source: .gateway(path: "/a/report.pdf"), name: "report.pdf"),
                            index: 0, context: nil, detail: "PDF · 2.4 MB")
        let one = MediaLayout.row(item, at: .zero, width: 260, mine: true, style: style)
        #expect(one.nameLines == 1)
        #expect(one.frame.height == CGFloat(64))
        let long = FileItem(attachment: MessageAttachment(kind: .file, source: .gateway(path: "/a/x.pdf"),
                                                          name: String(repeating: "Quarterly financial report ", count: 3) + ".pdf"),
                            index: 0, context: nil, detail: "PDF")
        let two = MediaLayout.row(long, at: .zero, width: 260, mine: true, style: style)
        #expect(two.nameLines == 2)
        #expect(two.frame.height >= 12 + two.name.height + 2 + two.detail.height + 12 - 0.5)
        #expect(two.name.minY >= 12 && two.frame.height - two.detail.maxY >= 12)
    }

    @Test func generatedCardFrames() {
        let portrait = GeneratedImageInfo(source: nil, aspect: .portrait, success: true)
        #expect(MediaLayout.generated(portrait, column: 370).height == 400)                  // 9:16 capped at 400
        let square = GeneratedImageInfo(source: "/f.png", pixelWidth: 1024, pixelHeight: 1024, aspect: .landscape, success: true)
        #expect(MediaLayout.generated(square, column: 370) == CGSize(width: 320, height: 320)) // pixel size beats the hint
        let landscape = GeneratedImageInfo(source: nil, aspect: .landscape, success: true)
        #expect(MediaLayout.generated(landscape, column: 370) == CGSize(width: 320, height: 180))
    }
}

@Suite("Attachments: markdown media (§7.5, check 13)")
struct MarkdownMediaTests {
    private let style = ChatStyleCache.shared.style(for: .large)

    private func refs(_ markdown: String) -> [MediaRef]? {
        let r = MarkdownRenderer.render(markdown, style: style)
        guard r.blocks.count == 1, case .media(let refs) = r.blocks[0] else { return nil }
        return refs
    }

    @Test func mediaAloneIsABlock() throws {
        let block = try #require(refs("MEDIA:/fixture/media/result.png"))
        #expect(block.count == 1)
        #expect(block[0].kind == .image)
        #expect(block[0].attachment.source == .gateway(path: "/fixture/media/result.png"))
        #expect(refs("![chart](https://images.example.com/chart.png)")?.first?.attachment.source
            == .remote(URL(string: "https://images.example.com/chart.png")!))
        #expect(refs("![a](/p.png)")?.first?.attachment.source == .gateway(path: "/p.png"))
        #expect(refs("[notes](/x/notes.md)")?.first?.kind == .file)
        #expect(refs("MEDIA:/a/vector.svg")?.first?.kind == .file)               // svg is a file row
        #expect(MarkdownPreprocess.mediaKind("/a/vector.svg") == "File")
    }

    @Test func mediaLineInsideTextIsItsOwnParagraph() throws {
        let r = MarkdownRenderer.render("Here you go:\nMEDIA:/fixture/media/result.png\nAnd the data: MEDIA:/fixture/media/data.csv", style: style)
        #expect(r.blocks.count == 3)
        guard r.blocks.count == 3, case .media(let refs) = r.blocks[1], case .text(let tail) = r.blocks[2] else {
            Issue.record("blocks: \(r.blocks.count)")
            return
        }
        #expect(refs.first?.kind == .image)
        // Inline: a glyph, then the name as a link to the media.
        #expect(tail.string.contains("data.csv"))
        #expect(!tail.string.contains("File: "))
        var link: URL?
        tail.enumerateAttribute(.chatLink, in: NSRange(location: 0, length: tail.length)) { value, _, _ in if let u = value as? URL { link = u } }
        let url = try #require(link)
        #expect(MarkdownMedia.ref(fromLink: url)?.attachment.source == .gateway(path: "/fixture/media/data.csv"))
        var glyph = false
        tail.enumerateAttribute(.attachment, in: NSRange(location: 0, length: tail.length)) { value, _, _ in if value != nil { glyph = true } }
        #expect(glyph)
    }

    @Test func ordinaryLinksStayLinks() {
        let r = MarkdownRenderer.render("See [docs](https://example.com/docs) for more.", style: style)
        #expect(r.blocks.count == 1)
        guard case .text(let t)? = r.blocks.first else { Issue.record("not text"); return }
        var link: URL?
        t.enumerateAttribute(.chatLink, in: NSRange(location: 0, length: t.length)) { value, _, _ in if let u = value as? URL { link = u } }
        #expect(link?.absoluteString == "https://example.com/docs")
    }
}

// A pasted phone screenshot with words: the bubble isn't a 150 pt sliver, and the stored row's plugin steer stays hidden.
@MainActor
struct CaptionedScreenshotTests {
    let style = ChatStyle.make(category: .large)

    private func layout(_ text: String, width px: Int = 1179, height ph: Int = 2556) -> BubbleLayout? {
        var a = MessageAttachment(kind: .image, source: .gateway(path: "/tmp/shot.jpg"), name: "shot.jpg")
        a.pixelWidth = px
        a.pixelHeight = ph
        var b = BubbleRow(mine: true, text: text, markdown: false, partIndex: 0, joinsAbove: false, joinsBelow: false,
                          tail: true, time: nil, pending: false, streaming: false)
        b.media = [MediaItem(attachment: a, index: 0, context: nil, label: "Photo")]
        let row = ChatRow(id: "m1|b0", messageId: "m1", scope: "acct|default|s1",
                          fingerprint: ChatRowBuilder.bubbleFingerprint(text, mine: true, speaker: nil),
                          kind: .bubble(b), gapAbove: 6, variant: 0)
        guard case .bubble(let box) = AttachmentBubbleLayout.bubble(b, row: row, width: 402, style: style, keep: false).content
        else { return nil }
        return box
    }

    @Test func longCaptionWidensATallPhoto() throws {
        let box = try #require(layout("This is what I see in the app, and it wraps over a few lines at least"))
        #expect(box.frame.width == 260)
        #expect(box.mediaGroups.first?.fits == true)
        #expect(box.mediaGroups.first?.tiles.first?.frame.size == CGSize(width: 260, height: 320))
    }

    @Test func photoAloneOrShortCaptionKeepsItsShape() throws {
        let alone = try #require(layout(""))
        #expect(alone.frame.width == 150)
        #expect(alone.mediaGroups.first?.fits == false)
        let short = try #require(layout("Hi"))
        #expect(short.frame.width == 150)
        let wide = try #require(layout("This is a landscape photo with a long caption under it", width: 1600, height: 900))
        #expect(wide.mediaGroups.first?.fits == false)
    }

    @Test func pluginSteerAndMemoryLeaveTheStoredRow() {
        let steer = "(Hermes HQ: for websites use your own browser tools (browser_exec). Sign in yourself.)"
        let memory = "<memory-context>\n[System note: recalled]\n\n- likes tea\n</memory-context>"
        #expect(Hydration.strippingTurnContext("This is what I see\n[screenshot]\n" + steer) == "This is what I see\n[screenshot]")
        #expect(Hydration.strippingTurnContext("Look\n" + memory + "\n\n" + steer) == "Look")
        #expect(Hydration.strippingTurnContext("My note (Hermes HQ: is great)") == "My note (Hermes HQ: is great)")   // mid-line: theirs
        #expect(Hydration.strippingTurnContext("Plain words") == "Plain words")
        let rows: [JSONValue] = [.object(["role": "user", "id": 1, "timestamp": 1,
                                          "content": .string("This is what I see\n\n[Image attached at: /tmp/a.jpg]\n[screenshot]\n" + steer)])]
        let folded = Hydration.fold(rows, pageSeq: 1)
        let shown = folded.messages.first?.parts.compactMap { part -> String? in if case .text(let t) = part { t } else { nil } }
            .joined() ?? ""
        #expect(!shown.contains("Hermes HQ:"))
        #expect(shown.contains("This is what I see"))
    }
}

/// [mac] Drag and drop and Finder paste: what attaches, what stays text, and the copy that leaves the original alone.
@Suite("Attachments: drop and file paste")
struct AttachmentDropTests {
    @Test func whatAttaches() {
        #expect(AttachmentDrop.fileType(["public.file-url", "public.utf8-plain-text"]) == "public.file-url")
        #expect(AttachmentDrop.fileType(["com.adobe.pdf"]) == "com.adobe.pdf")
        #expect(AttachmentDrop.fileType(["public.png"]) == "public.png")
        #expect(AttachmentDrop.fileType(["public.utf8-plain-text"]) == nil, "text stays the field's")
        #expect(AttachmentDrop.fileType(["public.url", "public.utf8-plain-text"]) == nil, "a link stays the field's")
        // [mac] A file dragged from the Finder reaches a Catalyst app as its own type alone (measured 2026-11-07: a .txt
        // as public.plain-text, a .png as public.png); a text snippet always carries a UTF-8 or UTF-16 flavour.
        #expect(AttachmentDrop.fileType(["public.plain-text"]) == "public.plain-text", "a dragged .txt")
        #expect(AttachmentDrop.fileType(["public.html"]) == "public.html", "a dragged .html")
        #expect(AttachmentDrop.fileType(["public.html", "public.utf8-plain-text"]) == nil, "a rich text selection")
        #expect(AttachmentDrop.fileType(["public.rtf", "public.utf16-external-plain-text"]) == nil)
    }

    @Test func whatTheMessageFieldAttaches() {
        #expect(AttachmentDrop.isFile(["public.file-url"]))
        #expect(AttachmentDrop.isFile(["public.plain-text"]), "a dragged .txt attaches, not its contents typed in")
        #expect(AttachmentDrop.isFile(["com.adobe.pdf"]))
        #expect(!AttachmentDrop.isFile(["public.png"]), "a picture is the picture paste's")
        #expect(!AttachmentDrop.isFile(["public.utf8-plain-text"]), "text is typed in")
    }

    @Test func whenAPasteIsFiles() {
        // A Finder copy: the file URL, its name as text and its icon as a picture.
        #expect(AttachmentDrop.pastesFiles(types: [["public.file-url", "public.utf8-plain-text", "public.tiff"]], hasStrings: true))
        // A copy in Files: the file alone.
        #expect(AttachmentDrop.pastesFiles(types: [["com.adobe.pdf"]], hasStrings: false))
        // A screenshot is the picture paste's, and copied text is text.
        #expect(!AttachmentDrop.pastesFiles(types: [["public.png"]], hasStrings: false))
        #expect(!AttachmentDrop.pastesFiles(types: [["public.utf8-plain-text"]], hasStrings: true))
    }

    @Test func names() {
        let file = URL(fileURLWithPath: "/tmp/x/abc.png")
        #expect(AttachmentDrop.name("Screenshot", file: file, type: "public.png") == "Screenshot.png")
        #expect(AttachmentDrop.name("Report.pdf", file: file, type: "com.adobe.pdf") == "Report.pdf")
        #expect(AttachmentDrop.name(nil, file: file, type: "public.png") == "abc.png")
    }

    @Test func aDroppedFileIsCopiedAndTheOriginalKept() async throws {
        let dir = tempDir()
        let original = dir.appending(path: "notes.pdf")
        try Data("%PDF-1.4 hello".utf8).write(to: original)
        for provider in [NSItemProvider(object: original as NSURL), try #require(NSItemProvider(contentsOf: original))] {
            let copy = try await AttachmentDrop.copyOut(provider)
            #expect(copy.lastPathComponent.hasSuffix(".pdf"))
            #expect(try Data(contentsOf: copy) == Data("%PDF-1.4 hello".utf8))
            #expect(copy.deletingLastPathComponent() != dir)
            try FileManager.default.removeItem(at: copy.deletingLastPathComponent())
            #expect(FileManager.default.fileExists(atPath: original.path), "the original is never touched")
        }
        try? FileManager.default.removeItem(at: dir)
    }
}

@Suite("Attachments: upload refusals say the gateway's reason")
struct UploadRefusalTests {
    @Test func a400ShowsTheGatewaysDetail() {
        let body = #"{"detail":"Invalid Host header. Dashboard requests must use the bound hostname or the configured public hostname."}"#
        let error = AttachmentStager.map(HTTPError(status: 400, body: body), name: "Screenshot.png", reading: false)
        #expect(error as? AttachmentUploadError == AttachmentUploadError(kind: .final, reason:
            "Your gateway refused “Screenshot.png”: Invalid Host header. Dashboard requests must use the bound hostname or the configured public hostname."))
    }

    /// Audit 14-6: reading the upload folder, a gateway restarting (502) is worth a retry and a 401 a session ended;
    /// only "not there" is no folder.
    @Test func readingTheFolderTellsAMissingOneFromAPassingError() {
        func kind(_ status: Int) -> AttachmentUploadError.Kind? {
            (AttachmentStager.map(HTTPError(status: status, body: nil), name: "", reading: true) as? AttachmentUploadError)?.kind
        }
        #expect(AttachmentStager.map(HTTPError(status: 404, body: nil), name: "", reading: true) as? AttachmentUploadError == .noFolder)
        #expect(kind(403) == .final)
        #expect(kind(502) == .retryable && kind(500) == .retryable && kind(429) == .retryable)
        #expect(kind(401) == .sessionEnded)
    }

    @Test func a400WithoutADetailSaysTheStatusNotTheName() {
        for body in [nil, "", "<html>Bad Request</html>", #"{"detail":"  "}"#] {
            let error = AttachmentStager.map(HTTPError(status: 400, body: body), name: "a.png", reading: false)
            #expect((error as? AttachmentUploadError)?.reason == "Your gateway refused “a.png” (HTTP 400).")
        }
    }
}

@Suite("Attachments: a failed tile's Try Again")
struct FailedTileRetryTests {
    private func tile(_ upload: DraftAttachment.Upload) -> DraftAttachment {
        DraftAttachment(id: "a", kind: .image, name: "a.png", localFile: "a/a.png", byteSize: 3, pixelWidth: 30, pixelHeight: 40,
                        typeIdentifier: "public.png", upload: upload)
    }

    @Test func aFinalRefusalOffersOnlyRemove() {
        #expect(tile(.failed(reason: AttachmentUploadError.connection("a.png").reason, retryable: true)).offersRetry)
        #expect(!tile(.failed(reason: AttachmentUploadError.tooBig("a.png").reason, retryable: false)).offersRetry)
        #expect(!tile(.failed(reason: AttachmentUploadError.badName.reason, retryable: false)).offersRetry)
        // The gateway's owner can add the upload folder meanwhile.
        #expect(tile(.failed(reason: AttachmentUploadError.noFolder.reason, retryable: false)).offersRetry)
        #expect(!tile(.waiting).offersRetry)
    }
}

@Suite("Attachments: a Windows gateway's paths")
struct WindowsGatewayPathTests {
    /// The gateway answers with backslashes for a folder the app named with slashes: a copy still inside it stays.
    @Test func aCopyInsideTheStagingFolderStays() {
        let folder = #"C:\Users\Ann\.hermes\files/.dispatch-attachments/F"#
        #expect(!AttachmentStager.stagedCopyReleased(uploaded: true, storedPath: #"C:\Users\Ann\.hermes\files\.dispatch-attachments\F\a.png"#, folder: folder))
        #expect(AttachmentStager.stagedCopyReleased(uploaded: true, storedPath: #"C:\Users\Ann\.hermes\uploads\a.png"#, folder: folder))
        #expect(!MemoUploader.stagedCopyReleased(uploaded: true, storedPath: #"C:\Users\Ann\.hermes\files\.dispatch-attachments\F\m.m4a"#, folder: folder))
    }
}

// Owner 2026-10-30: several photos "sit on top of each other where you can swipe through them".
@MainActor
@Suite("Attachments: photo stacks")
struct PhotoStackTests {
    let style = ChatStyle.make(category: .large)

    private func photo(_ name: String, _ w: Int?, _ h: Int?, index: Int = 0) -> MediaItem {
        var a = MessageAttachment(kind: .image, source: .gateway(path: "/tmp/\(name)"), name: name)
        a.pixelWidth = w
        a.pixelHeight = h
        return MediaItem(attachment: a, index: index, context: nil, label: "Photo")
    }

    private func bubble(_ text: String, _ media: [MediaItem]) -> BubbleLayout? {
        var b = BubbleRow(mine: true, text: text, markdown: false, partIndex: 0, joinsAbove: false, joinsBelow: false,
                          tail: true, time: Date(timeIntervalSince1970: 1_793_389_000), pending: false, streaming: false)
        b.media = media
        let row = ChatRow(id: "m1|b0", messageId: "m1", scope: "acct|default|s1",
                          fingerprint: ChatRowBuilder.bubbleFingerprint(text, mine: true, speaker: nil),
                          kind: .bubble(b), gapAbove: 6, variant: 0)
        guard case .bubble(let box) = AttachmentBubbleLayout.bubble(b, row: row, width: 402, style: style, keep: false).content
        else { return nil }
        return box
    }

    @Test func oneCardSizeFromTheMiddleShape() {
        let pad = MediaLayout.stackPadY
        let photos = MediaLayout.stack(sizes: Array(repeating: (1600, 1200), count: 3), maxWidth: 320)
        #expect(photos.card == CGRect(x: 0, y: pad, width: 260, height: 195))
        #expect(photos.size == CGSize(width: 260, height: 195 + 2 * pad))
        // Unknown sizes: the 4:3 card, never waiting for pixels.
        #expect(MediaLayout.stack(sizes: [(nil, nil), (nil, nil)], maxWidth: 320).card.size == CGSize(width: 260, height: 195))
        // Phone screenshots: one photo's tall rule.
        #expect(MediaLayout.stack(sizes: Array(repeating: (1179, 2556), count: 3), maxWidth: 320).card.size == CGSize(width: 150, height: 320))
        // The odd one out doesn't set the shape: the middle one does.
        #expect(MediaLayout.stack(sizes: [(1179, 2556), (1200, 1200), (1600, 1200)], maxWidth: 320).card.size == CGSize(width: 260, height: 260))
        // Two: halfway (in proportion) between them, 16:9 and square → 4:3.
        #expect(MediaLayout.stack(sizes: [(1920, 1080), (1200, 1200)], maxWidth: 320).card.size == CGSize(width: 260, height: 195))
        #expect(MediaLayout.stack(sizes: [(1600, 1200), (nil, nil)], maxWidth: 320).card.size == CGSize(width: 260, height: 195))
    }

    @Test func photosAloneAreAStackWithTheTimeOnTheCard() throws {
        let box = try #require(bubble("", (0..<3).map { photo("p\($0).png", 1600, 1200, index: $0) }))
        #expect(box.mediaOnly)
        let group = try #require(box.mediaGroups.first)
        let card = try #require(group.stack)
        #expect(box.mediaGroups.count == 1 && group.tiles.count == 3)
        #expect(group.tiles.allSatisfy { $0.frame == card }, "every photo is the same card")
        #expect(card.size == CGSize(width: 260, height: 195))
        #expect(group.frame.height == card.height + 2 * MediaLayout.stackPadY, "room for the fanned corners")
        #expect(group.radius == ChatMetrics.bubbleRadius)
        let capsule = try #require(box.timeCapsule)
        let onCard = card.offsetBy(dx: group.frame.minX, dy: group.frame.minY)
        #expect(onCard.contains(capsule), "the time sits on the top card, not in the room around it: \(capsule) \(onCard)")
    }

    @Test func aCaptionedStackSitsInTheBubble() throws {
        let box = try #require(bubble("Which of these three works best for the header?",
                                      (0..<3).map { photo("p\($0).png", 1600, 1200, index: $0) }))
        #expect(!box.mediaOnly)
        let group = try #require(box.mediaGroups.first)
        let card = try #require(group.stack)
        #expect(card.minX == MediaLayout.stackPadY && card.minY == MediaLayout.stackPadY, "in from the fill's edges")
        #expect(group.frame.minX >= 0 && group.frame.maxX <= ceil(box.frame.width))
        #expect(group.radius ?? 0 < ChatMetrics.bubbleRadius, "a smaller corner inside the bubble's")
        #expect(box.blocks.allSatisfy { $0.frame.minY >= group.frame.maxY }, "the caption comes under the stack")
        // Tall screenshots: the caption gets a photo's width and the stack sits centred over it.
        let tall = try #require(bubble("These are the three screens from the new onboarding flow, in order",
                                       (0..<3).map { photo("s\($0).png", 1179, 2556, index: $0) }))
        let tallGroup = try #require(tall.mediaGroups.first)
        #expect(tall.frame.width > tallGroup.frame.width)
        #expect(abs(tallGroup.frame.midX - tall.frame.width / 2) <= 1)
    }

    @Test func onePhotoIsNotAStack() throws {
        let box = try #require(bubble("", [photo("p.png", 1600, 1200)]))
        #expect(box.mediaGroups.first?.stack == nil)
    }

    @Test func aRepliesPicturesAreAStack() {
        let refs = ["a", "b", "c"].compactMap { MarkdownMedia.ref(destination: "#media:%2Ftmp%2F\($0).png", title: "Image: \($0).png", image: false) }
        let block = AttachmentBubbleLayout.mediaBlock(refs, context: nil, maxText: 300, mine: false, style: ChatStyle.make(category: .large))
        #expect(block.media.groups.count == 1)
        let group = block.media.groups[0]
        #expect(group.stack != nil && group.tiles.count == 3)
        #expect(block.size.height == (group.stack?.height ?? 0) + 2 * MediaLayout.stackPadY)
        #expect(group.radius == MediaLayout.replyRadius)
        // A reply's pictures come without sizes: once their first load learns them, the card takes their shape.
        let tall = MediaPixelSize(width: 1179, height: 2556)
        let learnt = AttachmentBubbleLayout.mediaBlock(refs, context: nil, maxText: 300, mine: false, style: ChatStyle.make(category: .large),
                                                       sizes: ["/tmp/a.png": tall, "/tmp/b.png": tall, "/tmp/c.png": tall])
        #expect(learnt.media.groups.first?.stack?.size == CGSize(width: 150, height: 320))
        #expect(learnt.media.groups.first?.tiles.first?.item.attachment.pixelHeight == 2556)
        // And the row re-measures: its fingerprint follows the learnt sizes.
        #expect(ChatRowBuilder.bubbleFingerprint("MEDIA:/tmp/a.png", mine: false, speaker: nil)
            != ChatRowBuilder.bubbleFingerprint("MEDIA:/tmp/a.png", mine: false, speaker: nil, sizes: ["/tmp/a.png": tall]))
        // A reply of pictures alone (no fill) takes them too: each card gets its own photo's shape.
        let text = "MEDIA:/tmp/wide.png\nMEDIA:/tmp/square.png"
        var b = BubbleRow(mine: false, text: text, markdown: true, partIndex: 0, joinsAbove: false, joinsBelow: false,
                          tail: true, time: Date(timeIntervalSince1970: 1_793_389_000), pending: false, streaming: false)
        b.mediaSizes = ["/tmp/wide.png": MediaPixelSize(width: 1920, height: 1080), "/tmp/square.png": MediaPixelSize(width: 1200, height: 1200)]
        let row = ChatRow(id: "m2|b0", messageId: "m2", scope: "acct|default|s1",
                          fingerprint: ChatRowBuilder.bubbleFingerprint(text, mine: false, speaker: nil, sizes: b.mediaSizes),
                          kind: .bubble(b), gapAbove: 6, variant: 0)
        let style = ChatStyle.make(category: .large)
        let rendered = MarkdownRenderer.render(text, style: style)
        guard case .bubble(let box)? = AttachmentBubbleLayout.photoOnlyReply(rendered, b, row: row, width: 402, style: style)?.content,
              let items = box.mediaGroups.first?.tiles.map(\.item) else { Issue.record("no photo-only reply"); return }
        #expect(items.map(\.attachment.pixelWidth) == [1920, 1200])
        #expect(items.map { PhotoStackView.cardSize($0, in: CGSize(width: 260, height: 195)) }
            == [CGSize(width: 260, height: 146), CGSize(width: 195, height: 195)])
    }

    @Test func picturesNextToEachOtherMakeOneStack() {
        let style = ChatStyleCache.shared.style(for: .large)
        let media = { (markdown: String) in
            MarkdownRenderer.render(markdown, style: style).blocks.compactMap { if case .media(let r) = $0 { r } else { nil } }
        }
        #expect(media("Here are the screenshots:\n\n/tmp/a.png\n\n/tmp/b.png\n\n/tmp/c.png").map(\.count) == [3])
        #expect(media("- /tmp/a.png\n- /tmp/b.png\n- /tmp/c.png\n\nAll three use demo data.").map(\.count) == [3])
        #expect(media("MEDIA:/tmp/a.png\nMEDIA:/tmp/b.png").map(\.count) == [2])
        // Words between them keep them apart.
        #expect(media("/tmp/a.png\n\nThen the second:\n\n/tmp/b.png").map(\.count) == [1, 1])
    }

    @Test func theFanKeepsItsCornersInTheRoom() {
        for size in [CGSize(width: 260, height: 195), CGSize(width: 150, height: 320), CGSize(width: 260, height: 100),
                     CGSize(width: 260, height: 320), CGSize(width: 280, height: 210)] {
            let a = PhotoStackView.fan(for: size)
            #expect(a > 0 && a <= 4.5 * .pi / 180, "\(size)")
            let s: CGFloat = 0.985
            let tall = s * (size.width * sin(a) + size.height * cos(a)), wide = s * (size.width * cos(a) + size.height * sin(a))
            #expect((tall - size.height) / 2 <= MediaLayout.stackPadY - 2, "\(size)")
            #expect((wide - size.width) / 2 <= 10, "\(size)")
        }
        #expect(PhotoStackView.fan(for: .zero) == 0)
    }

    /// [perf] A 16-photo stack loads the cards that can show: the top three, the next under them, and the bottom one.
    @Test func onlyTheCardsNearTheTopLoad() {
        #expect((0..<16).filter { PhotoStackView.loads(depth: $0, count: 16) } == [0, 1, 2, 3, 15])
        #expect((0..<3).allSatisfy { PhotoStackView.loads(depth: $0, count: 3) })
        #expect((0..<5).allSatisfy { PhotoStackView.loads(depth: $0, count: 5) })
    }

    @Test func eachCardTakesItsPhotosShapeInTheBox() {
        let box = CGSize(width: 260, height: 195)
        #expect(PhotoStackView.cardSize(photo("a.png", 1600, 1200), in: box) == box)
        #expect(PhotoStackView.cardSize(photo("wide.png", 1920, 1080), in: box) == CGSize(width: 260, height: 146))
        #expect(PhotoStackView.cardSize(photo("square.png", 1200, 1200), in: box) == CGSize(width: 195, height: 195))
        #expect(PhotoStackView.cardSize(photo("shot.png", 1179, 2556), in: box) == CGSize(width: 130, height: 195),
                "never under half the box")
        #expect(PhotoStackView.cardSize(photo("new.png", nil, nil), in: box) == box)
    }

    @Test func aPhotoOfAnotherShapeShowsWhole() {
        let card = CGSize(width: 260, height: 195)
        #expect(!MediaTileView.differs(CGSize(width: 1600, height: 1200), card))
        #expect(!MediaTileView.differs(CGSize(width: 1500, height: 1200), card), "close enough fills")
        #expect(MediaTileView.differs(CGSize(width: 1179, height: 2556), card))
        #expect(MediaTileView.differs(CGSize(width: 1200, height: 1200), card))
        #expect(!MediaTileView.differs(.zero, card))
    }

    @Test func theTopPhotoIsRememberedAndShown() throws {
        let items = (0..<3).map { photo("r\($0).png", 1600, 1200, index: $0) }
        let laid = MediaLayout.stack(sizes: items.map { ($0.attachment.pixelWidth, $0.attachment.pixelHeight) }, maxWidth: 320)
        let group = MediaGroupLayout(frame: CGRect(origin: .zero, size: laid.size), radius: 12, tiles: items.map { ($0, laid.card) },
                                     stack: laid.card)
        let key = "remember-\(UUID().uuidString)#0"
        let stack = PhotoStackView(frame: .zero)
        stack.makeTile = { MediaTileView(frame: .zero) }
        stack.configure(group, key: key)
        #expect(stack.top == 0 && stack.tiles.count == 3)
        #expect(stack.accessibilityLabel == "3 photos")
        #expect(stack.accessibilityValue?.hasPrefix("1 of 3") == true)
        stack.show(2)
        #expect(stack.top == 2 && stack.topTile === stack.tiles[2])
        #expect(stack.accessibilityValue?.hasPrefix("3 of 3") == true)
        // Only the top card takes touches.
        #expect(stack.tiles.enumerated().allSatisfy { $0.element.isUserInteractionEnabled == ($0.offset == 2) })
        // Scrolled away and back in another cell: the same photo on top.
        let again = PhotoStackView(frame: .zero)
        again.makeTile = { MediaTileView(frame: .zero) }
        again.configure(group, key: key)
        #expect(again.top == 2)
        again.configure(group, key: "other-\(UUID().uuidString)#0")
        #expect(again.top == 0)
    }
}
