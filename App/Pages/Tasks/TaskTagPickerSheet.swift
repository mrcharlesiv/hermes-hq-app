// Compact tappable Tag Picker sheet for Tasks: tap existing tags to toggle them without typos,
// or type a new tag (comma-separated entries supported too).

import SwiftUI
import UIKit

enum TaskTagPickerSheet {
    static func make(selected: [String], existing: [String], onSave: @escaping ([String]) -> Void) -> UIViewController {
        let model = TaskTagPickerModel(selected: selected, existing: existing, onSave: onSave)
        let host = TaskTagPickerHost(model: model)
        let nav = ChatSheet.wrap(host, title: "Tags", detents: [.medium(), .large()])
        nav.preferredContentSize = CGSize(width: 440, height: 420)
        return nav
    }
}

@MainActor @Observable
final class TaskTagPickerModel {
    var selected: [String]
    let existing: [String]
    var input = ""
    @ObservationIgnored var onSave: ([String]) -> Void
    @ObservationIgnored weak var controller: UIViewController?

    init(selected: [String], existing: [String], onSave: @escaping ([String]) -> Void) {
        self.selected = selected
        self.existing = existing
        self.onSave = onSave
    }

    var allKnown: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for tag in selected + existing {
            if seen.insert(tag.lowercased()).inserted { out.append(tag) }
        }
        return out
    }

    var query: String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix("#") { text.removeFirst() }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var filteredKnown: [String] {
        let q = query.lowercased()
        guard !q.isEmpty, !input.contains(",") else { return allKnown }
        return allKnown.filter { $0.lowercased().contains(q) }
    }

    var canAddTyped: Bool {
        let parsed = TodoViews.tags(from: input)
        guard !parsed.isEmpty else { return false }
        return parsed.contains { candidate in !isSelected(candidate) }
    }

    func isSelected(_ tag: String) -> Bool {
        selected.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }

    func toggle(_ tag: String) {
        PagesHaptics.selection()
        if let idx = selected.firstIndex(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            selected.remove(at: idx)
        } else if selected.count < 10 {
            selected.append(tag)
        }
    }

    func addFromInput() {
        let parsed = TodoViews.tags(from: input)
        guard !parsed.isEmpty else { return }
        PagesHaptics.selection()
        for tag in parsed where !isSelected(tag) && selected.count < 10 {
            selected.append(tag)
        }
        input = ""
    }

    /// Commits any typed tags in the field along with the tapped selection.
    func commit() {
        var final = selected
        for tag in TodoViews.tags(from: input) where !final.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) && final.count < 10 {
            final.append(tag)
        }
        onSave(final)
    }
}

final class TaskTagPickerHost: UIHostingController<HQScaledRoot<TaskTagPickerView>> {
    let model: TaskTagPickerModel

    init(model: TaskTagPickerModel) {
        self.model = model
        super.init(rootView: HQScaledRoot(TaskTagPickerView(model: model)))
        model.controller = self
        title = "Tags"
        let save = UIBarButtonItem(title: "Save", primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            self.model.commit()
            self.dismiss(animated: true)
        })
        save.style = .prominent
        save.accessibilityIdentifier = "task.tags.save"
        navigationItem.rightBarButtonItem = save
        let cancel = UIBarButtonItem.hqClose(DeviceWord.isMac ? .cancel : .close, action: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        cancel.accessibilityIdentifier = "sheet.close"
        navigationItem.hqPlaceFormClose(cancel)
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

struct TaskTagPickerView: View {
    @Bindable var model: TaskTagPickerModel
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "tag").foregroundStyle(Color.hqLabel2).accessibilityHidden(true)
                    TextField("Filter or add tags (e.g. hiring, q4)", text: $model.input)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit {
                            if model.canAddTyped { model.addFromInput() }
                        }
                        .accessibilityIdentifier("task.tags.field")
                    if model.canAddTyped {
                        Button("Add") { model.addFromInput() }
                            .font(Font.hq(.footnote).weight(.semibold))
                            .foregroundStyle(Color.hqTintText)
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("task.tags.add-typed")
                    }
                }
            } footer: {
                HQSectionFooter { Text("Tap existing tags below, or type new ones separated by commas. Up to 10 tags.") }
            }
            .hqSheetRows()

            if !model.filteredKnown.isEmpty {
                Section {
                    PagesFlowLayout(spacing: 8, lineSpacing: 8) {
                        ForEach(model.filteredKnown, id: \.self) { tag in
                            let on = model.isSelected(tag)
                            Button { model.toggle(tag) } label: {
                                HStack(spacing: 5) {
                                    if on { Image(systemName: "checkmark").font(Font.hq(.caption2).weight(.bold)).accessibilityHidden(true) }
                                    Text(tag).lineLimit(1)
                                }
                                .font(Font.hq(.footnote).weight(on ? .semibold : .regular))
                                .foregroundStyle(on ? Color.hqTintText : Color.hqLabel)
                                .padding(.horizontal, 11).padding(.vertical, 6)
                                .background(Capsule().fill(on ? Color.hqTint.opacity(0.16) : Color.hqFill3))
                                .overlay {
                                    if on { Capsule().strokeBorder(Color.hqTint.opacity(0.45), lineWidth: HQShape.hairline) }
                                }
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(on ? .isSelected : [])
                            .accessibilityIdentifier("task.tags.pick.\(tag)")
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    HQSectionLabel { Text(model.selected.isEmpty ? "Existing Tags" : "Tags (\(model.selected.count)/10)") }
                }
                .hqSheetRows()
            }
        }
        .hqGroupedPage()
        .onAppear { focused = true }
    }
}
