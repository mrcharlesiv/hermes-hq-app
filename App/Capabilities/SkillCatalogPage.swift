// [marketplace] A Marketplace skill's page, as the website's (/marketplace/skills/<slug>): what it does, who made it and
// where it comes from, Install for the bot (the Skills Hub's install, after asking), the terminal command, its tags,
// the whole SKILL.md to read, and more of the same kind.

import SwiftUI
import UIKit

final class SkillCatalogEntryController: UIHostingController<HQScaledRoot<SkillCatalogEntryView>> {
    private let page: SkillCatalogEntryModel

    init(model: CapabilitiesModel, entry: MarketSkill, router: SettingsRouter) {
        let page = SkillCatalogEntryModel(parent: model, entry: entry)
        self.page = page
        super.init(rootView: HQScaledRoot(SkillCatalogEntryView(page: page, router: router)))
        title = entry.name
        navigationItem.largeTitleDisplayMode = .never
        page.host = self
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// An install link's confirm sheet asks as soon as the page is up.
    func installWhenShown() { page.installOnAppear = true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        page.parent.presenter = self
        if page.installOnAppear {
            page.installOnAppear = false
            page.install()
        }
    }
}

@MainActor @Observable
final class SkillCatalogEntryModel {
    let parent: CapabilitiesModel
    let entry: MarketSkill
    var installOnAppear = false
    @ObservationIgnored weak var host: UIViewController?

    init(parent: CapabilitiesModel, entry: MarketSkill) {
        self.parent = parent
        self.entry = entry
    }

    var installed: Bool { parent.skillInstalled(entry) }
    var installing: Bool { parent.running.contains(entry.installIdentifier) }
    var canInstall: Bool { !installed && !installing && !parent.readOnly && parent.service != nil && parent.isConnected }

    func install() {
        guard canInstall else { return }
        Haptics.play(.light)
        parent.presenter = host
        parent.install(entry)
    }

    /// Other skills of its kind, official first (the website's "More …").
    var related: [MarketSkill] {
        let all = SkillCatalogStore.shared.entries ?? []
        return Array(all.filter { $0.category == entry.category && $0.installIdentifier != entry.installIdentifier }
            .sorted { $0.isOfficial && !$1.isOfficial }.prefix(4))
    }

    func readSkill() {
        guard let url = entry.skillFileURL, let navigation = host?.navigationController else { return }
        let page = ArtifactTextViewController(title: entry.name, markdown: true, language: nil) {
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.cachePolicy = .returnCacheDataElseLoad
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.fileDoesNotExist) }
            return SkillCatalogEntryModel.body(of: String(decoding: data.prefix(2 * 1024 * 1024), as: UTF8.self))
        }
        navigation.pushViewController(page, animated: true)
    }

    /// SKILL.md without its `---` front matter (the page already shows the name, tags and the rest).
    nonisolated static func body(of text: String) -> String {
        guard text.hasPrefix("---") else { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return text }
        return lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct SkillCatalogEntryView: View {
    @Bindable var page: SkillCatalogEntryModel
    let router: SettingsRouter
    @State private var copied = false

    private var entry: MarketSkill { page.entry }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 14) {
                        ConnectorSymbolTile(name: entry.name, symbol: SkillCatalogRow.symbol(entry), size: 56)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.name).font(Font.hq(.title3).weight(.bold)).foregroundStyle(Color.hqLabel)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 6) {
                                PluginTierBadge(words: entry.badge)
                                Text(entry.categoryLabel).font(Font.hq(.caption)).foregroundStyle(Color.hqLabel2).lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !entry.description.isEmpty {
                        Text(entry.description).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 6)
            }
            installSection
            if entry.skillFileURL != nil {
                Section {
                    Button { page.readSkill() } label: {
                        HStack {
                            Label("Read the Skill", systemImage: "doc.text")
                            Spacer()
                            SettingsChevron()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("skill-catalog.read")
                } footer: { HQSectionFooter {
                    Text("The instructions \(page.parent.botName) follows when the skill is loaded.")
                } }
            }
            Section {
                if !entry.author.isEmpty { detail("Made by", entry.author) }
                detail("Comes from", entry.sourceWord)
                detail("Kind", entry.categoryLabel)
                if !entry.tags.isEmpty { detail("Tags", entry.tags.prefix(12).joined(separator: ", ")) }
                if let site = entry.pageURL { link("See in the Hermes Marketplace", site, id: "skill-catalog.website") }
            } header: { HQSectionLabel { Text("Details") } } footer: { HQSectionFooter {
                Text(entry.isOfficial
                     ? "An official skill from Nous. The gateway checks it before it is installed."
                     : "Published by \(entry.sourceWord) and listed in the Hermes Marketplace. The gateway checks it before it is installed.")
            } }
            let related = page.related
            if !related.isEmpty {
                Section {
                    ForEach(related) { other in
                        SkillCatalogRow(entry: other, installed: page.parent.skillInstalled(other)) {
                            router.push(SkillCatalogEntryController(model: page.parent, entry: other, router: router))
                        }
                    }
                } header: { HQSectionLabel { Text("More \(entry.categoryLabel) Skills") } }
            }
        }
        .hqGroupedPage()
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("skill-catalog.page")
    }

    // [marketplace] Install To stands in its own card: in the same section as the clear button row, the card ended
    // half-drawn with Desktop Look off.
    @ViewBuilder private var installSection: some View {
        if page.parent.bots.count > 1 {
            Section { MarketplaceInstallTo(model: page.parent).disabled(page.installing) }
        }
        Section {
            VStack(spacing: 10) {
                if page.installed {
                    Label("Installed for \(page.parent.botName)", systemImage: "checkmark.circle.fill")
                        .font(Font.hq(.subheadline).weight(.semibold)).foregroundStyle(.green)
                        .accessibilityIdentifier("skill-catalog.installed")
                } else {
                    Button { page.install() } label: {
                        HStack(spacing: 8) {
                            if page.installing { ProgressView().tint(Color.hqOnTint) }
                            Text(page.installing ? "Installing…" : "Install for \(page.parent.botName)").font(Font.hq(.body).weight(.semibold))
                        }
                        .frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .hqGlassProminentButtonStyle()
                    .disabled(!page.canInstall)
                    .accessibilityIdentifier("skill-catalog.install")
                    if let note {
                        Text(note).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    }
                }
                MarketplaceCommand(command: entry.installCommand)
            }
            .padding(.vertical, 4)
            .listRowBackground(Color.clear)
        }
    }

    private var note: String? {
        if page.parent.readOnly { return "This gateway is read-only. Install from a gateway you can change." }
        if !page.parent.isConnected { return "Waiting for the gateway…" }
        if page.installing { return "The gateway is downloading and checking it." }
        if entry.isBuiltIn { return "It comes with Hermes. Install it again if it was removed from \(page.parent.botName)." }
        return nil
    }

    private func detail(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
            Text(value).foregroundStyle(Color.hqLabel).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private func link(_ title: String, _ url: URL, id: String) -> some View {
        Button {
            if let host = page.host { LinkOpener.open(url, from: host) }
        } label: {
            HStack {
                Text(title).foregroundStyle(Color.hqTint)
                Spacer()
                Image(systemName: "arrow.up.right").font(Font.hq(.footnote).weight(.semibold)).foregroundStyle(Color.hqLabel3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

/// "Or from a terminal:" and the command, with Copy (the website's Install box).
struct MarketplaceCommand: View {
    let command: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Or from a terminal:").font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
            HStack(spacing: 8) {
                Text(command).font(Font.hq(.footnote).monospaced()).foregroundStyle(Color.hqLabel)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    UIPasteboard.general.string = command
                    Haptics.play(.light)
                    copied = true
                    HQAnnounce.say("Copied")
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(Font.hq(.subheadline).weight(.semibold))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle().inset(by: -7))   // a 44 pt target (audit 10-18)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(copied ? "Copied" : "Copy Command")
                .accessibilityIdentifier("marketplace.copy-command")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.hqFill3, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
