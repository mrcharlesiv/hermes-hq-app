// 3x-morepages §7 (U6): the bundled notices are complete: every Swift package Xcode resolved is there at its version,
// Hermes is first, nothing is empty.

import Foundation
import Testing
@testable import HermesHQNative

struct LicenseNoticesTests {
    /// The repository's own files (the tests run on the Mac that built them).
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func bundled() async throws -> [LicenseNotice] {
        try #require(await LicenseNotices.load(bundle: Bundle(for: AppDelegate.self)))
    }

    @Test func theBundledListDecodesWithHermesFirstAndNothingEmpty() async throws {
        let notices = try await bundled()
        #expect(notices.first?.name == "Hermes Agent (Nous Research)")
        #expect(notices.dropFirst().map(\.name) == notices.dropFirst().map(\.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        for notice in notices {
            #expect(!notice.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(notice.name)")
            #expect(!notice.license.isEmpty, "\(notice.name) names its license")
        }
        #expect(notices.contains { $0.name == "Lucide" && $0.license == "ISC" })
        #expect(notices.first?.text.contains("Nous Research") == true)
    }

    @Test func everyResolvedPackageIsListedAtItsVersion() async throws {
        let notices = try await bundled()
        let resolved = Self.root.appending(path: "HermesHQNative.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        guard let data = try? Data(contentsOf: resolved) else { return }   // not on this machine (a device run): nothing to compare
        let pins = try #require((try JSONValue.parse(data))["pins"]?.array)
        #expect(!pins.isEmpty)
        for pin in pins {
            let identity = try #require(pin["identity"]?.string)
            let version = pin["state"]?["version"]?.string ?? ""
            let notice = notices.first { $0.name == identity }
            #expect(notice != nil, "\(identity) is in Package.resolved but not in licenses.json (run scripts/licenses.py)")
            #expect(notice?.version == version, "\(identity): licenses.json has \(notice?.version ?? "nothing"), Package.resolved \(version)")
        }
    }

    @Test func theWordsUnderAName() {
        #expect(LicenseNotice(name: "a", version: "1.2", license: "MIT", text: "x").meta == "1.2 · MIT")
        #expect(LicenseNotice(name: "a", version: "", license: "MIT", text: "x").meta == "MIT")
        #expect(LicenseNotice(name: "a", version: "1.2", license: "", text: "x").meta == "1.2")
        #expect(LicenseNotice(name: "a", version: "", license: "", text: "x").meta == "")
    }

    @Test func aBadFileIsRefusedAndBadEntriesAreSkipped() {
        #expect(LicenseNotices.decode(Data("not json".utf8)) == nil)
        #expect(LicenseNotices.decode(Data("{}".utf8)) == nil)
        #expect(LicenseNotices.decode(Data("[]".utf8)) == nil)
        let mixed = #"[{"name":"zeta","text":"z"},{"name":"","text":"x"},{"name":"empty","text":"  "},7,null,{"name":"zeta","text":"again"},"#
            + #"{"name":"Hermes Agent (Nous Research)","license":"MIT","text":"h"},{"name":"Alpha","version":3,"text":"a"}]"#
        let notices = LicenseNotices.decode(Data(mixed.utf8))
        #expect(notices?.map(\.name) == ["Hermes Agent (Nous Research)", "Alpha", "zeta"])
        #expect(notices?[1].version == "")
    }

    @Test func theWordsAreTheWebs() {
        #expect(LicenseNotices.intro == "This app is built on Hermes Agent by Nous Research and the open-source software below. Tap one to read its license.")
        #expect(LicenseNotices.failure == "The licenses couldn’t load.")
    }
}
