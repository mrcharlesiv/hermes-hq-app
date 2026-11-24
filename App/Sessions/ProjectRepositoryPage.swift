// [pr-manage] A coding project's ⋯ › Repository…: which git repository on the computer running Hermes this project's
// chats work in, so their marks can be read from its branches (owner 2026-11-19: "Should a project have a setup to
// integrate to a GitHub repo so that everything is linked that way?"). The folder a project is named for is often not
// the repository its chats commit to, so it is asked, with the project's own folder as the first guess.

import SwiftUI

struct ProjectRepositoryPage: View {
    let project: String
    let store: SessionStore
    @State private var folder = ""
    @State private var publicRepo = ""
    @State private var linked: SessionPRRepo?
    @State private var problem: String?
    @State private var statusNote: String?
    @State private var loadFailed = false
    @State private var busy = false
    @State private var loaded = false

    @State private var othersOpen = false
    @State private var choices: (here: [String], elsewhere: [String]) = ([], [])
    @State private var publicChoices: [String] = []

    var body: some View {
        List { Group {
            if loadFailed {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(Color.hqOrange)
                            .accessibilityHidden(true)
                        Text("Couldn’t load linked repositories from the gateway.")
                            .font(Font.hq(.footnote))
                            .foregroundStyle(Color.hqLabel2)
                        Spacer(minLength: 8)
                        Button("Retry") { reloadRepos() }
                            .font(Font.hq(.footnote).weight(.semibold))
                            .foregroundStyle(Color.hqTintText)
                            .disabled(busy)
                            .accessibilityIdentifier("project.repository.retry")
                    }
                }
            }
            Section {
                TextField("Folder", text: $folder, prompt: Text("/Users/you/Projects/app"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("project.repository.folder")
                if let problem {
                    Text(problem).font(Font.hq(.footnote)).foregroundStyle(Color.hqRed)
                        .accessibilityIdentifier("project.repository.error")
                }
                if let statusNote {
                    Text(statusNote).font(Font.hq(.footnote)).foregroundStyle(Color.hqGreen)
                        .accessibilityIdentifier("project.repository.status")
                }
                // [repo-pickers] The repositories Hermes already knows, one tap each (owner 2026-11-21: "These fields
                // need to be more than just free-type. It's to hard to manually type these things."). The field stays
                // for a folder none of them is.
                ForEach(choices.here, id: \.self) { folderChoice($0) }
                if !choices.elsewhere.isEmpty { otherFolders }
            } header: { HQSectionLabel { Text("Folder") } } footer: { HQSectionFooter {
                Text("The git repository on the computer running Hermes that this project’s chats work in. Each chat’s mark is read from the branches it made there.")
            } }
            Section {
                TextField("Public Repository", text: $publicRepo, prompt: Text("owner/repo or a GitHub link"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityIdentifier("project.repository.public")
                choiceRow(publicRepo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, id: "public.own") {
                    Text("The Folder’s Own").foregroundStyle(Color.hqLabel)
                    Text("Whatever GitHub repository its origin is").font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                } pick: { publicRepo = "" }
                ForEach(publicChoices, id: \.self) { name in
                    choiceRow(SessionStore.ownerRepo(from: publicRepo).lowercased() == name.lowercased(), id: "public.\(name)") {
                        Text(name).foregroundStyle(Color.hqLabel).lineLimit(1).truncationMode(.middle)
                    } pick: { publicRepo = name }
                }
            } header: { HQSectionLabel { Text("Public Repository") } } footer: { HQSectionFooter {
                Text("Leave it on The Folder’s Own unless the code is published to a different GitHub repository than the folder’s own. You can paste a GitHub link.")
            } }
            if let linked {
                Section {
                    row("Main Branch", linked.main, id: "main")
                    if let name = linked.publicRepo { row(linked.mirror ? "Publishes To" : "On GitHub", name, id: "github") }
                } header: { HQSectionLabel { Text("Linked") } }
            }
            Section {
                Button(linked == nil ? "Link Repository" : "Update Link") { link() }
                    .disabled(busy || folder.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("project.repository.link")
                if linked != nil {
                    Button("Unlink", role: .destructive) { unlink() }
                        .disabled(busy)
                        .accessibilityIdentifier("project.repository.unlink")
                }
            }
        }.hqMacSettingsRowInsets() }
        .settingsList()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(linked == nil ? "Link" : "Save") { link() }
                    .disabled(busy || folder.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("project.repository.toolbarLink")
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            show(store.prRepo(forProject: project))
            readChoices()
            let state = await store.loadPRRepos()
            loadFailed = (state == .failed && store.prRepos == nil)
            if linked == nil { show(store.prRepo(forProject: project)) }
            readChoices()
        }
    }

    private func reloadRepos() {
        busy = true
        loadFailed = false
        Task {
            defer { busy = false }
            let state = await store.loadPRRepos()
            loadFailed = (state == .failed && store.prRepos == nil)
            show(store.prRepo(forProject: project))
            readChoices()
        }
    }

    private func readChoices() {
        choices = store.repositoryFolderChoices(forProject: project)
        publicChoices = store.publicRepoChoices()
        // The folder in use is one of the others: they start open so its tick shows.
        if choices.elsewhere.contains(SessionStore.tidyFolder(folder)) { othersOpen = true }
    }

    /// Every other repository known here, folded under one row (there can be dozens).
    @ViewBuilder private var otherFolders: some View {
        let label = HStack {
            Text(choices.here.isEmpty ? "Repositories" : "Other Repositories").foregroundStyle(Color.hqLabel)
            Spacer(minLength: 8)
            Text("\(choices.elsewhere.count)").foregroundStyle(Color.hqLabel2)
        }
        if DeviceWord.isMac {
            Button {
                withAnimation(HQMotion.swiftUI(.smooth(duration: HQMotion.pane))) { othersOpen.toggle() }
            } label: {
                HStack(spacing: 8) {
                    label.frame(maxWidth: .infinity, alignment: .leading)
                    MacChevron().rotationEffect(.degrees(othersOpen ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .accessibilityValue(othersOpen ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("project.repository.others")
            if othersOpen { ForEach(choices.elsewhere, id: \.self) { folderChoice($0) } }
        } else {
            DisclosureGroup(isExpanded: $othersOpen) {
                ForEach(choices.elsewhere, id: \.self) { folderChoice($0) }
            } label: { label }
            .tint(Color.hqLabel2)
            .accessibilityIdentifier("project.repository.others")
        }
    }

    private func folderChoice(_ path: String) -> some View {
        choiceRow(SessionStore.tidyFolder(folder) == path, id: "folder.\(SessionStore.folderName(path))") {
            Text(SessionStore.folderName(path)).foregroundStyle(Color.hqLabel).lineLimit(1)
            Text((path as NSString).deletingLastPathComponent).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                .lineLimit(1).truncationMode(.head)
        } pick: {
            folder = path
            problem = nil
        }
    }

    /// A row that fills a field in when tapped, with a tick on the one the field holds.
    private func choiceRow<Label: View>(_ picked: Bool, id: String, @ViewBuilder label: () -> Label,
                                        pick: @escaping () -> Void) -> some View {
        Button {
            guard !picked else { return }
            Haptics.play(.selection)
            pick()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) { label() }
                Spacer(minLength: 8)
                if picked { Image(systemName: "checkmark").foregroundStyle(Color.hqTintText).fontWeight(.semibold) }
            }
            .contentShape(Rectangle())
        }
        .disabled(busy)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("project.repository.\(id)")
    }

    private func row(_ title: String, _ value: String, id: String) -> some View {
        HStack {
            Text(title).foregroundStyle(Color.hqLabel)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(Color.hqLabel2).lineLimit(1).truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("project.repository.\(id)")
    }

    private func show(_ repo: SessionPRRepo?) {
        linked = repo
        if let repo {
            folder = repo.path
            publicRepo = repo.mirror ? (repo.publicRepo ?? "") : ""
        } else if folder.isEmpty, project.hasPrefix("/") {
            folder = project
        }
    }

    private func link() {
        busy = true
        problem = nil
        statusNote = nil
        Task {
            defer { busy = false }
            do {
                let saved = try await store.linkPRRepo(project: project, path: folder,
                                                       publicRepo: SessionStore.ownerRepo(from: publicRepo))
                show(saved)
                loadFailed = false
                readChoices()
                statusNote = "Linked to \(SessionStore.folderName(saved.path)) (\(saved.main)). Checking pull requests…"
                Haptics.play(.success)
            } catch SessionPRRepoError.notARepository {
                problem = "That folder isn’t a git repository on the computer running Hermes."
            } catch SessionPRRepoError.invalidPublicRepo {
                problem = "Write the public repository as owner/repo."
            } catch {
                problem = "Couldn’t link the repository. Check the folder and try again."
            }
        }
    }

    private func unlink() {
        busy = true
        problem = nil
        statusNote = nil
        Task {
            defer { busy = false }
            do {
                try await store.unlinkPRRepo(project: project)
                linked = nil
            } catch {
                problem = "Couldn’t unlink the repository. Try again."
            }
        }
    }
}
