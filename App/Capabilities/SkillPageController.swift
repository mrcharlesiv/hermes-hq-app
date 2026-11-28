// A skill's page (spec 1x-settings §9.1): its SKILL.md drawn with the chat's markdown renderer (front matter removed),
// a "Turned On" switch, and Uninstall for a skill installed from the hub.

import SwiftUI
import UIKit

final class SkillPageController: UIHostingController<HQScaledRoot<SkillPageView>> {
    /// `settingsPage`: opened under Settings, so on the Mac its rows are Settings' rows (as the list it came from).
    init(model: CapabilitiesModel, skill: SkillInfo, settingsPage: Bool = false) {
        let page = SkillPageModel(model: model, skill: skill)
        super.init(rootView: HQScaledRoot(SkillPageView(page: page, settingsPage: settingsPage)))
        title = DisplayName.title(skill.name)
        navigationItem.largeTitleDisplayMode = .never
        page.host = self
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

@MainActor @Observable
final class SkillPageModel {
    let model: CapabilitiesModel
    let name: String
    var content: NSAttributedString?
    var error: String?
    @ObservationIgnored weak var host: UIViewController?

    init(model: CapabilitiesModel, skill: SkillInfo) {
        self.model = model
        self.name = skill.name
    }

    var skill: SkillInfo? { model.skills?.first { $0.name == name } }

    func load() {
        guard let service = model.service else { return }
        error = nil
        let profile = model.profile, name = self.name
        let start = ContinuousClock.now
        Task {
            do {
                let text = try await service.skillContent(name, profile: profile)
                content = Self.render(Self.stripFrontMatter(text))
                AppLog.trace("capabilities", "skill \(name) content loaded in \(AppLog.ms(since: start)) ms, \(text.utf8.count) bytes")
            } catch {
                self.error = CapabilitiesStore.detail(error)
                AppLog.note("capabilities", "skill \(name) content load failed after \(AppLog.ms(since: start)) ms: \(self.error ?? "")")
            }
        }
    }

    /// The text between a leading `---` line and the next `---` line goes.
    nonisolated static func stripFrontMatter(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return text }
        return lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func render(_ markdown: String) -> NSAttributedString {
        let style = ChatStyleCache.shared.style(for: UIApplication.shared.preferredContentSizeCategory)
        let rendered = MarkdownRenderer.render(markdown, style: style, theme: .bot)
        let out = NSMutableAttributedString()
        for block in rendered.blocks {
            if out.length > 0 { out.append(NSAttributedString(string: "\n\n")) }
            switch block {
            case .text(let text), .quote(let text, _): out.append(text)
            case .code(_, _, let text, _): out.append(text)
            case .table(let table): out.append(table.flat)
            case .mermaid(let diagram): out.append(NSAttributedString(string: diagram.source))
            case .spacer, .linkChip, .pageCard, .phoneProposal: break
            case .media(let refs): out.append(NSAttributedString(string: refs.map(\.label).joined(separator: ", ")))   // [attachments]
            }
        }
        return out
    }

    func uninstall() {
        TextPrompt.confirm(title: "Uninstall \(DisplayName.title(name))?", message: nil, action: "Uninstall", from: host) { [weak self] in
            guard let self else { return }
            self.model.uninstall(self.name) { [weak self] in self?.host?.navigationController?.popViewController(animated: true) }
        }
    }
}

struct SkillPageView: View {
    @Bindable var page: SkillPageModel
    var settingsPage = false

    var body: some View {
        List {
            if let skill = page.skill {
                Section {
                    Toggle("Turned On", isOn: Binding(get: { skill.enabled }, set: { page.model.setSkill(skill, enabled: $0) }))
                        .disabled(page.model.toggling.contains(skill.name))
                    if !page.model.readOnly, skill.supportsLock {
                        Toggle("Lock Against Agent Edits", isOn: Binding(get: { skill.locked }, set: { page.model.setSkillLocked(skill, locked: $0) }))
                            .disabled(page.model.locking.contains(skill.name))
                            .accessibilityIdentifier("skill.lock")
                    }
                } footer: {
                    if !page.model.readOnly, skill.supportsLock {
                        HQSectionFooter {
                            Text("Locking prevents the agent from editing this skill. You can still edit it yourself.")
                        }
                    }
                }
            }
            Section {
                if let content = page.content {
                    AttributedTextView(text: content).padding(.vertical, 8)
                } else if let error = page.error {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Couldn’t load this skill").font(Font.hq(.headline))
                        Text(error).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                        Button("Try Again") { page.load() }.hqBorderedButtonStyle()
                    }
                    .padding(.vertical, 12)
                } else {
                    HStack(spacing: 8) { ProgressView(); Text("Loading skill…").foregroundStyle(Color.hqLabel2) }
                        .padding(.vertical, 12)
                }
            }
            if page.skill?.provenance == "hub" {
                Section {
                    // [macpass-settings2] While the gateway removes it (some seconds) the page says so: a greyed button
                    // alone read as a dead click.
                    if page.model.running.contains(page.name) {
                        let busy = HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Uninstalling…").foregroundStyle(Color.hqLabel2) }
                        if DeviceWord.isMac {   // where the push button stood, not in a card of its own
                            busy.listRowBackground(Color.clear).listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 0, leading: MacInset.side, bottom: 0, trailing: 0)).hqDesktopBareRow()
                        } else {
                            busy
                        }
                    } else {
                    Button("Uninstall", role: .destructive) { page.uninstall() }
                        .hqMacFormButton(destructive: true)   // [macpass-settings2] a red push button under the form, as Delete Bot
                    }
                }
            }
        }
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        // [macpass-settings2] The readable column and small switch of the list it opens from: the skill's page ran the
        // pane's whole width, its cards 60 pt further left than Skills' own.
        .hqMacForm(settings: settingsPage)
        .listStyle(.insetGrouped)
        .onAppear { if page.content == nil { page.load() } }
    }
}

// AttributedTextView: App/Pages/PagesMarkdown.swift (integration: the pages and settings streams each wrote one).
