// [share] docs/spec/3x-share.md §11.1: ids, caps, the prompt table of §7.7, and parity with HermesKit's own rules.

import Foundation
import Testing
@testable import HermesHQNative

@Suite struct ShareRulesTests {
    @Test func sessionAndProfileIds() {
        #expect(ShareRules.validSession("20260929_120000_aabbcc02"))
        #expect(ShareRules.validSession("a-b_C9"))
        #expect(!ShareRules.validSession(""))
        #expect(!ShareRules.validSession("a/b"))
        #expect(!ShareRules.validSession("../../etc"))
        #expect(!ShareRules.validSession("a b"))
        #expect(ShareRules.validSession(String(repeating: "a", count: 160)))
        #expect(!ShareRules.validSession(String(repeating: "a", count: 161)))
        #expect(ShareRules.validProfile("default") && ShareRules.validProfile("ivy.v2-x_1"))
        #expect(!ShareRules.validProfile("") && !ShareRules.validProfile("a/b") && !ShareRules.validProfile("a b"))
        #expect(!ShareRules.validProfile(String(repeating: "p", count: 129)))
    }

    @Test func avatarNamesNeverLeaveTheFolder() {
        #expect(ShareRules.validAvatarName("3f1c9a0b7d2e4f6a8b1c2d3e4f5a6b7c.png"))
        #expect(ShareRules.validAvatarName("0123456789abcdef.jpg"))
        for bad in ["../../x.png", "x.png", "3F1C9A0B7D2E4F6A.png", "0123456789abcdef.gif", "0123456789abcdef.png/..", "", "0123456789abcde.png"] {
            #expect(!ShareRules.validAvatarName(bad), "\(bad)")
        }
    }

    @Test func capsLimitsAndKeys() {
        #expect(ShareRules.maxImages == 10 && ShareRules.maxFiles == 10)
        #expect(ShareRules.maxSharedText == 262_144)
        #expect(ShareRules.defaultLimitBytes == 104_857_600)
        #expect(Int64(ShareRules.defaultLimitBytes) == AttachmentStaging.maxItemBytes)       // spec D5
        #expect(ShareRules.maxBots == 200 && ShareRules.maxNameLength == 80)
        #expect(ShareRules.fits(bytes: 1, limit: 10) && ShareRules.fits(bytes: 10, limit: 10))
        #expect(!ShareRules.fits(bytes: 0, limit: 10) && !ShareRules.fits(bytes: 11, limit: 10))
        #expect(ShareRules.megabytes(33_554_432) == "32 MB")
        #expect(ShareRules.megabytes(8 * 1024 * 1024) == "8 MB")
        #expect(ShareRules.megabytes(10) == "1 MB")
        #expect(ShareRules.key(profile: "ivy") == "ios-direct::ivy")
        #expect(ShareRules.profile(ofKey: "ios-direct::ivy") == "ivy")
        #expect(ShareRules.profile(ofKey: "legacy::ivy") == "ivy")
        #expect(ShareRules.profile(ofKey: "a::b::c") == "c")
        #expect(ShareRules.profile(ofKey: "ivy") == "ivy")
    }

    @Test func promptTable() {
        // The table of spec §7.7.
        #expect(ShareRules.promptText(message: "From Safari", shared: ["https://example.com/a"], fileRefs: [], hasImages: false)
                == "From Safari\n\nhttps://example.com/a")
        #expect(ShareRules.promptText(message: "", shared: [], fileRefs: [], hasImages: true) == "What do you see in this image?")
        #expect(ShareRules.promptText(message: "Look", shared: [], fileRefs: [], hasImages: true) == "Look")
        #expect(ShareRules.promptText(message: "From Files", shared: [], fileRefs: ["@file:/x/note.txt"], hasImages: false)
                == "@file:/x/note.txt\n\nFrom Files")
        #expect(ShareRules.promptText(message: "", shared: [], fileRefs: ["@file:/x/a.txt", "@file:/x/b.txt"], hasImages: true)
                == "@file:/x/a.txt\n@file:/x/b.txt")
        #expect(ShareRules.promptText(message: "Same", shared: ["Same", "Same"], fileRefs: [], hasImages: false) == "Same")
        // Whitespace only is nothing.
        #expect(ShareRules.promptText(message: "  \n ", shared: ["\t", ""], fileRefs: [""], hasImages: false) == "")
        #expect(ShareRules.promptText(message: "  \n ", shared: ["\t"], fileRefs: [], hasImages: true) == ShareRules.defaultQuestion)
        #expect(ShareRules.promptText(message: " hi ", shared: [" a ", "b"], fileRefs: [], hasImages: false) == "hi\n\na\n\nb")
        // A fake attachment line a person typed is their own message, sent as typed.
        #expect(ShareRules.promptText(message: "@file:/etc/passwd", shared: [], fileRefs: [], hasImages: false) == "@file:/etc/passwd")
    }

    @Test func promptMatchesTheComposerWhenNothingIsShared() {
        #expect(ShareRules.defaultQuestion == AttachmentSender.defaultQuestion)
        let cases: [(String, [String], Bool)] = [
            ("", [], true), ("Look", [], true), ("From Files", ["@file:/x/note.txt"], false), ("", ["@file:/x/a.txt", "@file:/x/b.txt"], true),
            ("  spaced  ", [], false), ("", [], false), ("\n", ["", "@file:/x"], true), ("two\n\nparas", ["@file:/a b.txt"], false),
        ]
        for (message, refs, images) in cases {
            #expect(ShareRules.promptText(message: message, shared: [], fileRefs: refs, hasImages: images)
                    == AttachmentSender.promptText(typed: message, fileRefs: refs, hasImages: images), "\(message)|\(refs)|\(images)")
        }
    }

    @Test func accountKeyMatchesTheApp() {
        let addresses = [
            "http://127.0.0.1:9910", "HTTP://127.0.0.1:9910/", "https://HQ.Example", "https://hq.example///", "http://[fd7a:115c:a1e0::1]:8642",
            "https://hq.example:8443/base", "https://hq.example/base/", "http://100.64.0.1:8642", "https://MiXeD.Example.COM:443",
            "http://localhost:8642", "https://xn--bcher-kva.example", "https://bücher.example", "http://host.ts.net", "HTTPS://HOST.TS.NET/",
            "not a url", "", "http://user@host:1", "https://hq.example/?q=1", "http://127.0.0.1:9910/a%20b", "https://hq.example:8443",
        ]
        #expect(addresses.count == 20)
        for address in addresses {
            for user in ["share-fixture", "nous:user_1", ""] {
                #expect(ShareRules.accountKey(url: address, username: user) == GatewayAddress.accountKey(url: address, username: user), "\(address)")
            }
        }
        #expect(ShareRules.accountKey(url: "HTTP://127.0.0.1:9910/", username: "u") == "http://127.0.0.1:9910\nu")
    }

    @Test func safeNameMatchesTheApp() {
        let names = [
            "note.txt", "", ".", "..", "../../x", "a/b/c.png", "a\\b.txt", "quote\".txt", "colon:name.pdf", "line\nbreak.txt", "tab\tname.txt",
            "nul\u{0}name", "  spaced name .txt", "no-extension", ".hidden", "emoji 😀.png", String(repeating: "😀", count: 400),
            String(repeating: "a", count: 300) + ".jpeg", String(repeating: "b", count: 180), String(repeating: "c", count: 181),
            String(repeating: "d", count: 200) + "." + String(repeating: "e", count: 40), "Ünïcödé.heic", "/absolute/path/file.mov",
            "trailing/", "a:b/c:d.txt", "\u{7f}del.txt", "\u{202e}rtl.txt", "name.with.many.dots.tar.gz", "UPPER.JPG", "weird\r\n.txt",
            "\"\\/:", "x", "y.z", "résumé final (2).docx", "IMG_0001.HEIC", "clip-gps.mov", "big.bin", "p01.jpg", "a b c", "🎉",
        ]
        #expect(names.count == 40)
        for name in names {
            #expect(ShareRules.safeName(name) == AttachmentStaging.safeName(name), "\(name.prefix(30))")
        }
        #expect(ShareRules.safeName("../../x") == "x")
        #expect(!ShareRules.safeName("line\nbreak.txt").contains("\n"))
        #expect(ShareRules.safeName(String(repeating: "😀", count: 400)).utf8.count <= 180)
        #expect(ShareRules.safeName(String(repeating: "a", count: 300) + ".jpeg").hasSuffix(".jpeg"))
        #expect(ShareRules.safeName("") == "attachment")
    }

    @Test func namesTakeTheProviderFilesExtension() {
        #expect(ShareRules.safeName("report", fallbackExtension: "pdf") == "report.pdf")
        #expect(ShareRules.safeName("report.txt", fallbackExtension: "pdf") == "report.txt")
        #expect(ShareRules.safeName("report", fallbackExtension: "") == "report")
        #expect(ShareRules.stem("IMG_0001.HEIC") == "IMG_0001")
        #expect(ShareRules.stem(".jpg") == "photo" || ShareRules.stem(".jpg") == ".jpg")
        #expect(ShareRules.stem("") == "photo")
    }

    @Test func stagedCopyRuleMatchesTheApp() {
        let folder = "/fixture/uploads/.dispatch-attachments/ABC"
        let cases: [(Bool?, String?)] = [
            (true, "/fixture-home/attachments/note.txt"), (true, folder + "/note.txt"), (true, folder), (false, "/elsewhere/x"),
            (nil, "/elsewhere/x"), (true, nil), (true, ""), (true, folder + "-other/note.txt"),
        ]
        for (uploaded, path) in cases {
            #expect(ShareRules.stagedCopyReleased(uploaded: uploaded, storedPath: path, folder: folder)
                    == AttachmentStager.stagedCopyReleased(uploaded: uploaded, storedPath: path, folder: folder), "\(String(describing: uploaded)) \(path ?? "nil")")
        }
        #expect(ShareRules.stagedCopyReleased(uploaded: true, storedPath: "/fixture-home/attachments/note.txt", folder: folder))
        #expect(!ShareRules.stagedCopyReleased(uploaded: true, storedPath: folder + "/note.txt", folder: folder))
    }

    @Test func queriesAreEncoded() {
        #expect(ShareRules.query(["profile": "ivy"]) == "profile=ivy")
        #expect(ShareRules.query(["profile": "a b&c=d+e"]) == "profile=a%20b%26c%3Dd%2Be")
        #expect(ShareRules.query(["b": "2", "a": "1"]) == "a=1&b=2")
    }

    @Test func storageNamesStayAsBuild240WroteThem() {
        // Spec D10: nobody sees them, and files written by build 240 are read after the update.
        #expect(ShareIdentity.folderPath == "Library/Application Support/Dispatch Share")
        #expect(ShareIdentity.stagingFolder == ".dispatch-attachments")
        #expect(ShareIdentity.temporaryPrefix == "dispatch-share-")
        #expect(ShareIdentity.keychainAccount == "primary")
        #expect(ShareIdentity.keychainService == AppIdentity.current.keychainService)
        #expect(ShareIdentity.appGroup == AppIdentity.current.appGroup)
    }
}
