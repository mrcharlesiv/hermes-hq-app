import SwiftUI
import Testing
import UIKit
@testable import HermesHQNative

/// The gateway card on More and Settings: the address wraps between its parts and the status line never ends a line
/// on a dangling " · " (UI hunt 2026-10-15: "127.0.0.1:995" / "1" and "Connected · 6 Bots ·" at large text).
struct GatewayCardWrapTests {
    @Test func numberAddressBreaksOnlyAfterColonsAndSlashes() {
        // UX study 2026-10-19: "127.0.0." / "1:10067" at AX5 read as a different address.
        let wrapped = SettingsRootModel.wrappable("127.0.0.1:9951")
        #expect(wrapped == "127.0.0.1:\u{200B}9951")
        #expect(wrapped.replacingOccurrences(of: "\u{200B}", with: "") == "127.0.0.1:9951")
        #expect(SettingsRootModel.wrappable("http://10.0.0.2:8642/") == "http:\u{200B}/\u{200B}/\u{200B}10.0.0.2:\u{200B}8642/\u{200B}")
        #expect(SettingsRootModel.wrappable("studio") == "studio")
    }

    @Test func hostnamesKeepTheirDotBreaks() {
        #expect(SettingsRootModel.wrappable("mac.tail1234.ts.net:9951")
                == "mac.\u{200B}tail1234.\u{200B}ts.\u{200B}net:\u{200B}9951")
        // Word by word: a name beside a number address breaks each its own way.
        #expect(SettingsRootModel.wrappable("alex · 10.0.0.2:8642") == "alex · 10.0.0.2:\u{200B}8642")
    }

    @Test func statusLinesBreakOnlyBetweenPieces() {
        let pieces = ["Connected", "6\u{00A0}Bots", "Hermes\u{00A0}0.21.5"]
        #expect(DotSeparatedText.lines(pieces, joined: 3) == ["Connected · 6\u{00A0}Bots · Hermes\u{00A0}0.21.5"])
        #expect(DotSeparatedText.lines(pieces, joined: 2) == ["Connected · 6\u{00A0}Bots", "Hermes\u{00A0}0.21.5"])
        #expect(DotSeparatedText.lines(pieces, joined: 1) == ["Connected", "6\u{00A0}Bots", "Hermes\u{00A0}0.21.5"])
        for joined in 1...3 { #expect(!DotSeparatedText.lines(pieces, joined: joined).contains { $0.hasSuffix("·") }) }
    }

    /// A tester's recording: holding More near Workspace and slowly scrolling back toward Settings bounced the list back
    /// ~16 pt every few frames. Recycled gateway cells measured two status lines before `onGeometryChange` reported the
    /// row width, then shrank to one line on the next turn and fell back off the top of the viewport.
    @MainActor @Test func gatewayCardKeepsStableHeightAndNeverSnapsSlowUpwardScroll() async throws {
        func makeCardModel() -> SettingsRootModel {
            let model = SettingsRootModel(services: FakeAppServices())
            model.gatewayName = "Studio"
            model.connection = .ready
            model.rosterCount = 6
            model.version = "0.21.5"
            return model
        }

        func plainRow(_ id: String, _ title: String) -> MoreRow {
            MoreRow(id: id, title: title, symbol: "folder.fill", image: nil, tile: .systemBlue) { nil }
        }

        let sections: [MoreSection] = [
            MoreSection(id: "account", header: nil) {
                [
                    MoreRow(id: "gateway", title: "Gateway", symbol: nil, image: nil, tile: .clear, make: { nil }, card: {
                        UIHostingConfiguration { GatewayCardView(model: makeCardModel()) }.margins(.vertical, 0)
                    }),
                    plainRow("settings", "Settings"),
                ]
            },
            MoreSection(id: "workspace", header: "Workspace") {
                ["Quick Actions", "Files", "Changes", "Terminal", "Kanban", "Artifacts"].map { plainRow($0.lowercased(), $0) }
            },
            MoreSection(id: "apps", header: "Apps & Extensions") {
                ["Marketplace", "Capabilities", "Connectors", "Composio", "Messaging", "Webhooks"].map { plainRow($0.lowercased(), $0) }
            },
            MoreSection(id: "insights", header: "Insights") {
                ["Usage", "Spawn Tree", "Star Map", "Profiles", "Passwords", "Status"].map { plainRow($0.lowercased(), $0) }
            },
        ]

        let more = MoreViewController(sections: { sections })
        let nav = PageChrome.navigation(more)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = nav
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }

        func findCollectionView(in view: UIView) -> UICollectionView? {
            if let cv = view as? UICollectionView { return cv }
            for sub in view.subviews { if let found = findCollectionView(in: sub) { return found } }
            return nil
        }

        nav.view.layoutIfNeeded()
        let list = try #require(findCollectionView(in: more.view))
        let gatewayPath = IndexPath(item: 0, section: 0)
        let firstWorkspacePath = IndexPath(item: 0, section: 1)
        let initialGatewayHeight = try #require(list.collectionViewLayout.layoutAttributesForItem(at: gatewayPath)?.frame.height)

        for _ in 0..<6 {
            try await Task.sleep(for: .milliseconds(20))
            nav.view.layoutIfNeeded()
        }
        let gatewayFrame = try #require(list.collectionViewLayout.layoutAttributesForItem(at: gatewayPath)?.frame)
        #expect(abs(initialGatewayHeight - gatewayFrame.height) < 0.5,
                "gateway card initial height (\(initialGatewayHeight)) must equal settled height (\(gatewayFrame.height))")
        #expect(gatewayFrame.height <= 70, "one-line status must fit at standard 393 pt iPhone width (got \(gatewayFrame.height))")

        // Scroll down past the gateway card, then slowly scroll back up across its bottom edge (the exact sawtooth zone).
        let startOffset = gatewayFrame.maxY + 48
        list.setContentOffset(CGPoint(x: 0, y: startOffset), animated: false)
        list.layoutIfNeeded()
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(20))
            list.layoutIfNeeded()
        }

        var previousScreenY = try #require(list.collectionViewLayout.layoutAttributesForItem(at: firstWorkspacePath)?.frame.minY) - list.contentOffset.y
        var offset = startOffset
        while offset > gatewayFrame.minY - 20 {
            offset -= 4
            list.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
            list.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
            list.layoutIfNeeded()
            let rowMinY = try #require(list.collectionViewLayout.layoutAttributesForItem(at: firstWorkspacePath)?.frame.minY)
            let screenY = rowMinY - list.contentOffset.y
            #expect(screenY > previousScreenY + 2.5,
                    "scrolling up 4 pt must move rows smoothly down on screen (was \(previousScreenY), now \(screenY) at offset \(offset))")
            previousScreenY = screenY
        }

        // Also check narrow width (320 pt): wraps cleanly to two status lines without post-layout height bounce.
        let narrowWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 680))
        let narrowMore = MoreViewController(sections: { sections })
        let narrowNav = PageChrome.navigation(narrowMore)
        narrowWindow.rootViewController = narrowNav
        narrowWindow.makeKeyAndVisible()
        defer { narrowWindow.isHidden = true; narrowWindow.rootViewController = nil }

        narrowNav.view.layoutIfNeeded()
        let narrowList = try #require(findCollectionView(in: narrowMore.view))
        let narrowInitial = try #require(narrowList.collectionViewLayout.layoutAttributesForItem(at: gatewayPath)?.frame.height)
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(20))
            narrowNav.view.layoutIfNeeded()
        }
        let narrowSettled = try #require(narrowList.collectionViewLayout.layoutAttributesForItem(at: gatewayPath)?.frame.height)
        #expect(abs(narrowInitial - narrowSettled) < 0.5,
                "narrow gateway card initial height (\(narrowInitial)) must equal settled height (\(narrowSettled))")

        // Also check Settings root list (`SettingsRootController`) and More with App Background + Soft Cards on.
        let previousPreset: BackdropPreset? = {
            if case .preset(let preset) = Backdrop.app.source { return preset }
            return nil
        }()
        let previousCards = Backdrop.app.cards
        Backdrop.app.setPreset(.aurora)
        Backdrop.app.setCards(true)
        defer {
            if let previousPreset { Backdrop.app.setPreset(previousPreset) } else { Backdrop.app.clear() }
            Backdrop.app.setCards(previousCards)
        }

        let softMore = MoreViewController(sections: { sections })
        let softNav = PageChrome.navigation(softMore)
        window.rootViewController = softNav
        softNav.view.layoutIfNeeded()
        for _ in 0..<6 {
            try await Task.sleep(for: .milliseconds(20))
            softNav.view.layoutIfNeeded()
        }
        let softList = try #require(findCollectionView(in: softMore.view))
        let softGateway = try #require(softList.collectionViewLayout.layoutAttributesForItem(at: gatewayPath)?.frame)
        var softOffset = softGateway.maxY + 48
        softList.setContentOffset(CGPoint(x: 0, y: softOffset), animated: false)
        softList.layoutIfNeeded()
        for _ in 0..<4 {
            try await Task.sleep(for: .milliseconds(20))
            softList.layoutIfNeeded()
        }
        var softPrevY = try #require(softList.collectionViewLayout.layoutAttributesForItem(at: firstWorkspacePath)?.frame.minY) - softList.contentOffset.y
        while softOffset > softGateway.minY - 20 {
            softOffset -= 4
            softList.setContentOffset(CGPoint(x: 0, y: softOffset), animated: false)
            softList.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
            softList.layoutIfNeeded()
            let rowMinY = try #require(softList.collectionViewLayout.layoutAttributesForItem(at: firstWorkspacePath)?.frame.minY)
            let screenY = rowMinY - softList.contentOffset.y
            #expect(screenY > softPrevY + 2.5,
                    "Soft Cards More list must scroll up smoothly without snapping (was \(softPrevY), now \(screenY) at offset \(softOffset))")
            softPrevY = screenY
        }

        let settings = SettingsScreens.makeSettings(services: FakeAppServices())
        let settingsNav = PageChrome.navigation(settings)
        window.rootViewController = settingsNav
        settingsNav.view.layoutIfNeeded()
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(20))
            settingsNav.view.layoutIfNeeded()
        }
        let settingsList = try #require(findCollectionView(in: settings.view))
        let settingsGateway = try #require(settingsList.collectionViewLayout.layoutAttributesForItem(at: gatewayPath)?.frame)
        let secondSectionFirst = IndexPath(item: 0, section: 1)
        var settingsOffset = settingsGateway.maxY + 48
        settingsList.setContentOffset(CGPoint(x: 0, y: settingsOffset), animated: false)
        settingsList.layoutIfNeeded()
        for _ in 0..<4 {
            try await Task.sleep(for: .milliseconds(20))
            settingsList.layoutIfNeeded()
        }
        var settingsPrevY = try #require(settingsList.collectionViewLayout.layoutAttributesForItem(at: secondSectionFirst)?.frame.minY) - settingsList.contentOffset.y
        while settingsOffset > settingsGateway.minY - 20 {
            settingsOffset -= 4
            settingsList.setContentOffset(CGPoint(x: 0, y: settingsOffset), animated: false)
            settingsList.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
            settingsList.layoutIfNeeded()
            let rowMinY = try #require(settingsList.collectionViewLayout.layoutAttributesForItem(at: secondSectionFirst)?.frame.minY)
            let screenY = rowMinY - settingsList.contentOffset.y
            #expect(screenY > settingsPrevY + 2.5,
                    "Settings root list must scroll up smoothly without snapping (was \(settingsPrevY), now \(screenY) at offset \(settingsOffset))")
            settingsPrevY = screenY
        }
    }
}
