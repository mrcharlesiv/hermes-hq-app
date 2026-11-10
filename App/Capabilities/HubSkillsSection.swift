// [hub] The Skills Hub on the Skills tab (the desktop's `HubSkillsSection`, skills-hub.tsx): under a search,
// "Search the Skills Hub" for what is typed, then its results, each with where it comes from and how far Hermes
// trusts that source (community skills marked), and Get. Hidden on a gateway without hub search.

import SwiftUI

struct HubSection: View {
    @Bindable var model: CapabilitiesModel

    var body: some View {
        let term = model.hubTerm
        if !term.isEmpty, !model.hubUnsupported {
            let results = model.shownHub
            Section {
                if model.hubSearching {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Searching the Skills Hub…").foregroundStyle(Color.hqLabel2)
                    }
                    .padding(.vertical, 3)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("skills.hub.searching")
                } else if let results {
                    if results.isEmpty {
                        Text("No matching skills found in the hub.").foregroundStyle(Color.hqLabel2).padding(.vertical, 3)
                            .accessibilityIdentifier("skills.hub.none")
                    }
                    ForEach(results) { skill in
                        HubSkillRow(skill: skill, installed: model.hubIsInstalled(skill), installing: model.running.contains(skill.identifier),
                                    readOnly: model.readOnly) { model.install(skill) }
                    }
                } else {
                    if let error = model.hubError {
                        Text(error).font(Font.hq(.subheadline)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("skills.hub.error")
                    }
                    Button {
                        model.searchHub()
                    } label: {
                        Label("Search the Skills Hub for “\(term)”", systemImage: "magnifyingglass")
                    }
                    .accessibilityIdentifier("skills.hub.search")
                }
            } header: { HQSectionLabel {
                Text("Skills Hub")
            } } footer: { HQSectionFooter {
                if model.hubSearching {
                    Text("This can take a while. Hermes asks every hub it knows.")
                } else if results == nil {
                    Text("Find skills beyond Hermes’s own: the official index, GitHub and community sources.")
                } else if results?.contains(where: \.isCommunity) == true {
                    Text("Community skills come from outside Nous. The gateway checks each one before it is installed.")
                }
            } }
        }
    }
}

struct HubSkillRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let skill: HubSkill
    let installed: Bool
    let installing: Bool
    let readOnly: Bool
    let install: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: Theme.isDesktop ? 3 : 1) {
                Text(DisplayName.title(skill.name)).font(Font.hq(.body).weight(SkillRowMetrics.titleWeight)).foregroundStyle(Color.hqLabel)
                if !skill.description.isEmpty {
                    Text(skill.description).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : Density.compact ? 1 : 2)   // [ui-sizing] Compact: one line
                }
                HStack(spacing: 6) {
                    Text(skill.trustWord).font(Font.hq(.caption).weight(.semibold)).foregroundStyle(trustTint)
                        .padding(.horizontal, 7).padding(.vertical, 1)
                        .background(trustTint.opacity(0.14), in: Capsule())
                    Text(([skill.sourceWord] + (skill.repo.map { [$0] } ?? [])).joined(separator: " · "))
                        .font(Font.hq(.caption)).foregroundStyle(Color.hqLabel2).lineLimit(1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(skill.provenance)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if installed {
                Label("Installed", systemImage: "checkmark").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                    .accessibilityIdentifier("skill-hub-installed-\(skill.name)")
            } else if installing {
                ProgressView().frame(minWidth: 52)
                    .accessibilityLabel("Installing \(skill.name)")
            } else if !readOnly {
                Button("Get", action: install)
                    .hqRowActionButtonStyle()
                    .font(Font.hq(.subheadline).weight(.semibold))
                    .accessibilityLabel("Get \(skill.name)")
                    .accessibilityIdentifier("skill-hub-get-\(skill.name)")
            }
        }
        .padding(.vertical, Theme.isDesktop ? 3 : 0) // [compact] iOS look: the list row's own inset only
    }

    /// Community stands out (orange); trusted and built-in read as plain.
    private var trustTint: Color { skill.isCommunity ? .orange : Color.hqLabel2 }
}
