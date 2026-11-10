// [share] docs/spec/3x-share.md §7.6 check 3: what the sheet reads out of real item providers, and what it never reads.

import Foundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import HermesHQNative

@Suite(.serialized) struct ShareItemLoaderTests {
    private func staging() -> URL { ShareItemLoader.newFolder(in: ShareTemp.folder("loader")) }

    @Test func theEleventhPhotoIsNeverRead() async throws {
        let source = ShareTemp.folder("loader-photos"), counter = LoadCounter()
        let providers = (1...12).map { index -> NSItemProvider in
            let name = String(format: "p%02d", index)
            return ShareProviders.file(ShareTestMedia.photo(name + ".jpg", in: source), type: .jpeg, name: name, counter: counter)
        }
        let folder = staging()
        let loaded = await ShareItemLoader.load([ShareProviders.item(providers)], into: folder)
        #expect(loaded.items.count == 10 && loaded.failures.isEmpty)
        #expect(loaded.items.allSatisfy { $0.kind == .image })
        #expect(loaded.items.map(\.name) == (1...10).map { String(format: "p%02d.jpg", $0) })
        #expect(counter.total == 10)
        #expect(counter.count("p11") == 0 && counter.count("p12") == 0)             // no decode, no copy
        #expect(loaded.skipped == ShareSkipped(photos: 2, files: 0))                  // counted, so the sheet can say so
        // Each staged photo is a JPEG in its own folder, with nothing of the original's details, and a small preview.
        for item in loaded.items {
            let file = try #require(item.file)
            #expect(file.path.hasPrefix(folder.path + "/"))
            #expect(file.deletingLastPathComponent().deletingLastPathComponent().path == folder.path)
            #expect(folder.lastPathComponent.hasPrefix("dispatch-share-"))
            let data = try Data(contentsOf: file)
            #expect(ShareTestMedia.carriesNothing(data))
            #expect(item.bytes == data.count && item.bytes > 0)
            #expect(item.thumbnail != nil)
            #expect(item.attachment == ShareAttachment(kind: .image, file: file, name: item.name))
            #expect(item.sharedText == nil)
        }
        #expect(Set(loaded.items.compactMap { $0.file?.deletingLastPathComponent().lastPathComponent }).count == 10)
    }

    @Test func theEleventhFileIsNeverReadAndLinksAreNotCounted() async throws {
        let source = ShareTemp.folder("loader-files"), counter = LoadCounter()
        var providers = (1...12).map { index -> NSItemProvider in
            let name = "doc\(index).bin"
            return ShareProviders.file(ShareTemp.file(name, bytes: 100 + index, in: source), type: .data, name: name, counter: counter)
        }
        providers.append(NSItemProvider(object: URL(string: "https://example.com/after")! as NSURL))
        providers.append(NSItemProvider(object: "words after the files" as NSString))
        let loaded = await ShareItemLoader.load([ShareProviders.item(providers)], into: staging())
        #expect(loaded.items.filter { $0.kind == .file }.count == 10)
        #expect(counter.total == 10 && counter.count("doc11.bin") == 0 && counter.count("doc12.bin") == 0)
        #expect(loaded.items.compactMap(\.sharedText) == ["https://example.com/after", "words after the files"])
        #expect(loaded.failures.isEmpty)
        #expect(loaded.skipped == ShareSkipped(photos: 0, files: 2))
    }

    @Test func theSameLinkOrTextIsKeptOnce() async {
        let link = URL(string: "https://example.com/a")!
        let providers = [NSItemProvider(object: link as NSURL), NSItemProvider(object: link as NSURL),
                         NSItemProvider(object: "https://example.com/a" as NSString), NSItemProvider(object: "Same" as NSString),
                         NSItemProvider(object: "  Same \n" as NSString), NSItemProvider(object: "https://example.com/b" as NSString)]
        let loaded = await ShareItemLoader.load([ShareProviders.item(providers)], into: staging())
        #expect(loaded.items.map(\.kind) == [.link(link), .text("Same"), .link(URL(string: "https://example.com/b")!)])
        #expect(loaded.items.compactMap(\.sharedText) == ["https://example.com/a", "Same", "https://example.com/b"])
        #expect(loaded.failures.isEmpty)
    }

    @Test func aLoneAddressIsALinkAndTheRestIsText() {
        #expect(ShareItemLoader.link("https://example.com/a?b=1#c") != nil)
        #expect(ShareItemLoader.link("HTTP://EXAMPLE.COM") != nil)
        for text in ["see https://example.com", "https://example.com and more", "ftp://example.com/file", "javascript:alert(1)", "example.com",
                     "mailto:someone@example.com", "file:///etc/passwd", "https://", "hermes://session/abc", "https://exa mple.com", ""] {
            #expect(ShareItemLoader.link(text) == nil, "\(text)")
        }
    }

    @Test func textIsCutAtTheCap() async {
        let long = String(repeating: "x", count: 300_000)
        let loaded = await ShareItemLoader.load([ShareProviders.item([NSItemProvider(object: long as NSString)])], into: staging())
        #expect(loaded.items.count == 1)
        #expect(loaded.items.first?.sharedText?.count == 262_144)
        // Whitespace alone is nothing to share.
        let blank = await ShareItemLoader.load([ShareProviders.item([NSItemProvider(object: " \n\t " as NSString)])], into: staging())
        #expect(blank.items.isEmpty && blank.failures.isEmpty)
    }

    @Test func aFileOverTheLimitIsMeasuredNeverCopied() async throws {
        let source = ShareTemp.folder("loader-big"), counter = LoadCounter()
        let limit = 32 * 1024 * 1024
        let big = ShareTemp.file("big.bin", bytes: 33 * 1024 * 1024, in: source)
        let exact = ShareTemp.file("exact.bin", bytes: limit, in: source)
        let folder = staging()
        let loaded = await ShareItemLoader.load([ShareProviders.item([
            ShareProviders.file(big, type: .data, name: "big.bin", counter: counter),
            ShareProviders.file(exact, type: .data, name: "exact.bin", counter: counter),
        ])], into: folder, limit: limit)
        #expect(loaded.items.map(\.name) == ["big.bin", "exact.bin"] && loaded.failures.isEmpty)
        let over = loaded.items[0], fits = loaded.items[1]
        #expect(over.bytes == 33 * 1024 * 1024 && over.kind == .file)
        let overFile = try #require(over.file), fitsFile = try #require(fits.file)
        #expect(!FileManager.default.fileExists(atPath: overFile.path))          // named for the sheet, not on disk
        #expect(fits.bytes == limit)
        #expect(FileManager.default.fileExists(atPath: fitsFile.path))
        // Only the one that fits was copied.
        let staged = try FileManager.default.subpathsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".bin") }
        #expect(staged.count == 1 && staged[0].hasSuffix("/exact.bin"))
    }

    @Test func filesKeepSafeNamesAndTakeTheProviderFilesExtension() async throws {
        let source = ShareTemp.folder("loader-names")
        let pdf = ShareTemp.file("B7F0-provider-copy.pdf", bytes: 2048, in: source)
        let note = ShareTemp.file("note.txt", text: "a note", in: source)
        let loaded = await ShareItemLoader.load([ShareProviders.item([
            ShareProviders.file(pdf, type: .pdf, name: "Quarterly: \"report\""),
            ShareProviders.file(pdf, type: .pdf, name: nil),
            ShareProviders.file(note, type: .data, name: "../../etc/note.txt"),
        ])], into: staging())
        #expect(loaded.items.map(\.name) == ["Quarterly report.pdf", "B7F0-provider-copy.pdf", "note.txt"])
        #expect(loaded.items.allSatisfy { $0.kind == .file && $0.file?.lastPathComponent == $0.name })
        #expect(loaded.items[2].attachment?.kind == .file)
        let noteFile = try #require(loaded.items[2].file)
        #expect(try Data(contentsOf: noteFile) == Data("a note".utf8))
        #expect(loaded.failures.isEmpty)
    }

    @Test func whatCannotBeReadIsNamed() async throws {
        let source = ShareTemp.folder("loader-broken")
        let broken = ShareTemp.file("broken.mov", text: String(repeating: "text bytes, not a movie\n", count: 50), in: source)
        let empty = ShareTemp.file("empty.bin", bytes: 0, in: source)
        let failing = NSItemProvider()
        failing.suggestedName = "vanished.pdf"
        failing.registerFileRepresentation(forTypeIdentifier: UTType.pdf.identifier, fileOptions: [], visibility: .all) { completion in
            completion(nil, false, CocoaError(.fileNoSuchFile)); return nil
        }
        let notAPicture = ShareProviders.file(ShareTemp.file("fake.jpg", text: "not a picture", in: source), type: .jpeg, name: "fake")
        let unknown = NSItemProvider()
        unknown.suggestedName = "contact"
        unknown.registerDataRepresentation(forTypeIdentifier: "com.example.not-a-real-type", visibility: .all) { completion in
            completion(Data("x".utf8), nil); return nil
        }
        let folder = staging()
        let loaded = await ShareItemLoader.load([ShareProviders.item([
            ShareProviders.file(broken, type: .quickTimeMovie, name: "broken.mov"),
            ShareProviders.file(empty, type: .data, name: "empty.bin"),
            failing, notAPicture, unknown,
            NSItemProvider(object: "a note that still goes" as NSString),
        ])], into: folder)
        #expect(loaded.failures == ["broken.mov", "empty.bin", "vanished.pdf", "fake.jpg", "contact"])
        #expect(loaded.items.map(\.kind) == [.text("a note that still goes")])                  // the rest of the share can still go
        // Nothing of the unreadable ones is left staged.
        let left = (try? FileManager.default.subpathsOfDirectory(atPath: folder.path)) ?? []
        #expect(left.filter { !$0.isEmpty && ($0 as NSString).pathExtension != "" }.isEmpty, "\(left)")
    }

    @Test func aVideoIsCopiedAndLosesItsLocation() async throws {
        let source = ShareTemp.folder("loader-movie")
        let clip = source.appendingPathComponent("clip-gps.mov")
        try ShareTestMedia.movie(at: clip)
        let original = try Data(contentsOf: clip)
        let loaded = await ShareItemLoader.load([ShareProviders.item([ShareProviders.file(clip, type: .quickTimeMovie, name: "clip-gps.mov")])], into: staging())
        #expect(loaded.failures.isEmpty)
        let item = try #require(loaded.items.first)
        #expect(item.kind == .file && item.name == "clip-gps.mov")
        let staged = try #require(item.file)
        #expect(try await ShareTestMedia.locations(inMovieAt: staged) == [])
        #expect(try await ShareTestMedia.facts(ofMovieAt: staged).playable)
        #expect(item.bytes == ShareItemLoader.size(staged) && item.bytes > 0)
        #expect(try Data(contentsOf: clip) == original)                                        // the other app's file is untouched
        // Over the limit: measured and named, never copied and never rewritten.
        let folder = staging()
        let over = await ShareItemLoader.load([ShareProviders.item([ShareProviders.file(clip, type: .quickTimeMovie, name: "clip-gps.mov")])],
                                              into: folder, limit: 1000)
        #expect(over.items.first?.bytes == original.count && over.failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func aCaptionAloneIsText() async {
        let caption = await ShareItemLoader.load([ShareProviders.item([], caption: "  Just words  ")], into: staging())
        #expect(caption.items.map(\.kind) == [.text("Just words")])
        // With an attachment, the provider is what was shared; the caption is not added.
        let both = await ShareItemLoader.load([ShareProviders.item([NSItemProvider(object: "the text" as NSString)], caption: "a caption")], into: staging())
        #expect(both.items.map(\.kind) == [.text("the text")])
        let nothing = await ShareItemLoader.load([ShareProviders.item([])], into: staging())
        #expect(nothing.items.isEmpty && nothing.failures.isEmpty)
        let none = await ShareItemLoader.load([], into: staging())
        #expect(none.items.isEmpty)
    }

    @Test func anAddressThatIsNotAWebLinkIsNeverStagedAsAFile() async {
        // DECISION (report): a URL of another scheme is not a link and not a file; it is named as unreadable.
        let providers = [NSItemProvider(object: URL(string: "hermes://session/abc")! as NSURL), NSItemProvider(object: URL(string: "https://example.com/ok")! as NSURL)]
        let folder = staging()
        let loaded = await ShareItemLoader.load([ShareProviders.item(providers)], into: folder)
        #expect(loaded.items.map(\.kind) == [.link(URL(string: "https://example.com/ok")!)])
        #expect(loaded.failures.count == 1)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func mixedSharesKeepTheirOrderAndKinds() async throws {
        let source = ShareTemp.folder("loader-mixed")
        let providers = [
            NSItemProvider(object: URL(string: "https://example.com/a")! as NSURL),
            ShareProviders.file(ShareTestMedia.photo("IMG_0001.jpg", in: source), type: .jpeg, name: "IMG_0001"),
            ShareProviders.file(ShareTemp.fixtures.appendingPathComponent("photo-gps.heic"), type: .heic, name: "IMG_0002.HEIC"),
            ShareProviders.file(ShareTemp.fixtures.appendingPathComponent("report.pdf"), type: .pdf, name: "report.pdf"),
            NSItemProvider(object: "Have a look" as NSString),
        ]
        let loaded = await ShareItemLoader.load([ShareProviders.item(providers)], into: staging())
        #expect(loaded.failures.isEmpty)
        #expect(loaded.items.map(\.name) == ["", "IMG_0001.jpg", "IMG_0002.jpg", "report.pdf", ""])
        #expect(loaded.items.map(\.kind) == [.link(URL(string: "https://example.com/a")!), .image, .image, .file, .text("Have a look")])
        #expect(ShareItemLoader.slot(of: providers[0]) == nil && ShareItemLoader.slot(of: providers[1]) == .image)
        #expect(ShareItemLoader.slot(of: providers[3]) == .file && ShareItemLoader.slot(of: providers[4]) == nil)
        // The HEIC went out as an upright JPEG without its location.
        let heic = try Data(contentsOf: #require(loaded.items[2].file))
        #expect(ShareTestMedia.carriesNothing(heic))
        #expect((ShareTestMedia.properties(of: heic)[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 3072)
    }

    /// A picture an app hands over as itself or as bytes, with no file behind it (a screenshot, a drawing): the UI
    /// test with ten such pictures showed ten "couldn't read" lines before the loader read them this way too.
    @Test func aPictureWithNoFileBehindItIsRead() async throws {
        // As itself, on its side (the way UIActivityViewController hands over a UIImage).
        let sideways = UIImage(cgImage: ShareTestMedia.marked(width: 96, height: 64), scale: 1, orientation: .right)
        let asItself = NSItemProvider(item: sideways, typeIdentifier: UTType.image.identifier)
        // As bytes: a PNG that is transparent all over.
        let clear = ShareTestMedia.encode(ShareTestMedia.bitmap(width: 40, height: 20, alpha: true) { _ in }, as: .png)
        let asBytes = NSItemProvider(item: clear as NSData, typeIdentifier: UTType.png.identifier)
        asBytes.suggestedName = "drawing"
        // As an object the newer way, and larger than a shared photo may be.
        let wide = UIImage(cgImage: ShareTestMedia.bitmap(width: 4000, height: 1000) { context in
            context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 4000, height: 1000))
        })
        let asObject = NSItemProvider(object: wide)
        let providers = [asItself, asBytes, asObject]
        #expect(providers.allSatisfy { ShareItemLoader.slot(of: $0) == .image })
        let folder = staging()
        let loaded = await ShareItemLoader.load([ShareProviders.item(providers)], into: folder, picture: { SharePictures.bitmap($0) })
        #expect(loaded.failures.isEmpty, "\(loaded.failures)")
        #expect(loaded.items.map(\.kind) == [.image, .image, .image])
        #expect(loaded.items.count == 3)
        guard loaded.items.count == 3 else { return }
        #expect(loaded.items[1].name == "drawing.jpg")
        var sizes: [[Int]] = []
        for item in loaded.items {
            let data = try Data(contentsOf: #require(item.file))
            #expect(ShareTestMedia.type(of: data) == UTType.jpeg.identifier)
            #expect(ShareTestMedia.carriesNothing(data))
            #expect(item.bytes == data.count && item.thumbnail != nil)
            let picture = try #require(ShareTestMedia.pixels(of: data))
            sizes.append([picture.width, picture.height])
        }
        // On its side became upright (64 wide, 96 tall); the wide one came down to 3072 on its long side.
        #expect(sizes == [[64, 96], [40, 20], [3072, 768]], "\(sizes)")
        // Transparent pixels went onto white.
        let drawing = try Data(contentsOf: #require(loaded.items[1].file))
        let white = try #require(ShareTestMedia.pixels(of: drawing))
        let middle = ShareTestMedia.colour(white, x: 20, y: 10)
        #expect(middle.r > 245 && middle.g > 245 && middle.b > 245, "\(middle)")
    }

    /// Without the sheet's reader, a picture that arrives only as an object is named as unreadable, never dropped silently.
    @Test func anObjectPictureWithoutAReaderIsNamed() async {
        let image = UIImage(cgImage: ShareTestMedia.marked(width: 32, height: 32))
        let provider = NSItemProvider(item: image, typeIdentifier: UTType.image.identifier)
        provider.suggestedName = "sketch"
        let loaded = await ShareItemLoader.load([ShareProviders.item([provider])], into: staging())
        // Either the system turned it into bytes by itself (then it is a photo) or it is named: nothing in between.
        #expect(loaded.items.count + loaded.failures.count == 1)
        #expect(loaded.failures.isEmpty || loaded.failures == ["sketch.jpg"])
    }

    @Test func cancelReadsNothingMore() async {
        let source = ShareTemp.folder("loader-cancel"), counter = LoadCounter()
        let providers = (1...6).map { index in
            ShareProviders.file(ShareTestMedia.photo("c\(index).jpg", in: source), type: .jpeg, name: "c\(index)", counter: counter)
        }
        let folder = staging()
        nonisolated(unsafe) let inputs = [ShareProviders.item(providers)]
        let task = Task.detached { () -> Int in
            withUnsafeCurrentTask { $0?.cancel() }
            return await ShareItemLoader.load(inputs, into: folder).items.count
        }
        #expect(await task.value == 0)
        #expect(counter.total == 0)
    }

    /// Cancel (or a swipe away) while the sheet says "Preparing…": the read in flight finishes afterwards (a provider
    /// cannot be stopped half way) and stages its copy. The folder goes all the same, and nothing is handed back.
    @Test func cancelDuringAReadLeavesNothingStaged() async throws {
        let source = ShareTemp.folder("loader-cancel-slow"), counter = LoadCounter()
        let photo = ShareTestMedia.photo("slow.jpg", in: source)
        let asked = DispatchSemaphore(value: 0), go = DispatchSemaphore(value: 0)
        let slow = NSItemProvider()
        slow.suggestedName = "slow"
        slow.registerFileRepresentation(forTypeIdentifier: UTType.jpeg.identifier, fileOptions: [], visibility: .all) { completion in
            asked.signal()
            DispatchQueue.global().async { go.wait(); counter.hit("slow done"); completion(photo, false, nil) }
            return nil
        }
        let next = ShareProviders.file(ShareTestMedia.photo("next.jpg", in: source), type: .jpeg, name: "next", counter: counter)
        let folder = staging()
        nonisolated(unsafe) let inputs = [ShareProviders.item([slow, next])]
        let task = Task.detached { await ShareItemLoader.load(inputs, into: folder) }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { asked.wait(); continuation.resume() }
        }
        task.cancel()                 // the person cancels while the first photo is being read…
        go.signal()                   // …and the read then finishes and writes its copy
        let loaded = await task.value
        #expect(counter.count("slow done") == 1)
        #expect(loaded.items.isEmpty && loaded.failures.isEmpty && loaded.skipped == ShareSkipped())
        #expect(counter.count("next") == 0)                                            // nothing more was read
        #expect(!FileManager.default.fileExists(atPath: folder.path), "\((try? FileManager.default.subpathsOfDirectory(atPath: folder.path)) ?? [])")
        // The same share read to the end keeps its copies (the folder is removed only for a cancelled read).
        let whole = staging()
        let kept = await ShareItemLoader.load([ShareProviders.item([ShareProviders.file(photo, type: .jpeg, name: "slow")])], into: whole)
        #expect(kept.items.count == 1 && FileManager.default.fileExists(atPath: whole.path))
    }

    @Test func staleFoldersAreSweptAndFreshOnesKept() throws {
        let temporary = ShareTemp.folder("loader-sweep")
        let old = temporary.appendingPathComponent("dispatch-share-OLD", isDirectory: true)
        let fresh = temporary.appendingPathComponent("dispatch-share-FRESH", isDirectory: true)
        let other = temporary.appendingPathComponent("someone-elses-folder", isDirectory: true)
        for folder in [old, fresh, other] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            ShareTemp.file("left.jpg", bytes: 10, in: folder)
        }
        let twoHoursAgo = Date().addingTimeInterval(-7200)
        try FileManager.default.setAttributes([.modificationDate: twoHoursAgo], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: twoHoursAgo], ofItemAtPath: other.path)
        ShareItemLoader.removeStaleFolders(in: temporary)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(FileManager.default.fileExists(atPath: other.path))                    // only this extension's own
        let made = ShareItemLoader.newFolder(in: temporary)
        #expect(made.lastPathComponent.hasPrefix("dispatch-share-") && made.deletingLastPathComponent().path == temporary.path)
        #expect(!FileManager.default.fileExists(atPath: made.path))                    // made only when something is staged
    }
}
