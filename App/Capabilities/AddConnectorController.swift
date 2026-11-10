// "Add a Connector" (docs/spec/3x-capabilities.md §5.2): a sheet that adds an MCP server to the picked bot. A bearer
// token travels as `bearer_token`, never inside `config`, and is never logged or echoed.

import SwiftUI
import UIKit

struct ConnectorDraft: Equatable {
    struct Pair: Identifiable, Equatable { let id = UUID(); var key = ""; var value = "" }
    enum Kind: String, CaseIterable { case web, command }
    enum Auth: String, CaseIterable, Identifiable {
        case none, oauth, bearer
        var id: String { rawValue }
        var title: String { self == .none ? "None" : self == .oauth ? "OAuth" : "Bearer Token" }
    }

    var name = ""
    var kind = Kind.web
    var url = ""
    var auth = Auth.none
    var token = ""
    var headers: [Pair] = []
    var command = ""
    var args: [Pair] = []
    var env: [Pair] = []
    var cwd = ""

    static let nameRule = JSRegex(#"^[A-Za-z0-9._-]{1,64}$"#)

    var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    var nameValid: Bool { Self.nameRule.test(trimmedName) }
    func nameTaken(_ existing: [String]) -> Bool { existing.contains { $0.caseInsensitiveCompare(trimmedName) == .orderedSame } }

    var urlValid: Bool {
        guard let parts = URLComponents(string: url.trimmingCharacters(in: .whitespaces)), let scheme = parts.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && !(parts.host ?? "").isEmpty
    }

    private func pairsComplete(_ pairs: [Pair]) -> Bool {
        pairs.allSatisfy { $0.key.trimmingCharacters(in: .whitespaces).isEmpty ? $0.value.isEmpty : true }
    }

    /// The web's `isDraftComplete`: a valid, free name; a valid address or a command; every started pair has a key.
    func isComplete(existing: [String]) -> Bool {
        guard nameValid, !nameTaken(existing) else { return false }
        switch kind {
        case .web: return urlValid && pairsComplete(headers) && (auth != .bearer || !token.trimmingCharacters(in: .whitespaces).isEmpty)
        case .command: return !command.trimmingCharacters(in: .whitespaces).isEmpty && pairsComplete(env)
        }
    }

    var hasContent: Bool { self != ConnectorDraft() }

    private func map(_ pairs: [Pair]) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for pair in pairs {
            let key = pair.key.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { out[key] = .string(pair.value) }
        }
        return out
    }

    /// The mcp.json entry (`url` or `command`, `args`, `env`, `headers`, `auth`, `cwd`). The bearer token is not in it.
    var config: JSONValue {
        var out: [String: JSONValue] = [:]
        switch kind {
        case .web:
            out["url"] = .string(url.trimmingCharacters(in: .whitespaces))
            if auth == .oauth { out["auth"] = "oauth" }
            let headers = map(self.headers)
            if !headers.isEmpty { out["headers"] = .object(headers) }
        case .command:
            out["command"] = .string(command.trimmingCharacters(in: .whitespaces))
            let args = self.args.map(\.value).filter { !$0.isEmpty }
            if !args.isEmpty { out["args"] = .array(args.map(JSONValue.string)) }
            let env = map(self.env)
            if !env.isEmpty { out["env"] = .object(env) }
            let cwd = self.cwd.trimmingCharacters(in: .whitespaces)
            if !cwd.isEmpty { out["cwd"] = .string(cwd) }
        }
        return .object(out)
    }

    var bearer: String? { kind == .web && auth == .bearer ? token.trimmingCharacters(in: .whitespacesAndNewlines) : nil }

    /// The gateway's own refusals in the app's words; nil = "That name is already used." inline, no alert.
    static func reason(for error: Error) -> String? {
        guard let rpc = error as? RPCError else { return CapabilitiesStore.detail(error) }
        let message = rpc.message.lowercased()
        if rpc.code == 4090 { return message.contains("already exists") ? nil : "A plugin already provides a connector with this name." }
        if rpc.code == 4063 { return "Enter a web address or a command." }
        if rpc.code == 4001, message.contains("suspicious") {
            return "Your gateway refused this command because it looks unsafe. Check the command and its arguments."
        }
        return McpEntryMask.phone.text(rpc.message)
    }
}

final class AddConnectorController: UIHostingController<HQScaledRoot<AddConnectorView>>, UIAdaptivePresentationControllerDelegate {
    static func present(model: CapabilitiesModel, from presenter: UIViewController, added: @escaping (String) -> Void) {
        let controller = AddConnectorController(model: model, added: added)
        let navigation = UINavigationController(rootViewController: controller)
        navigation.presentationController?.delegate = controller
        presenter.present(navigation, animated: true)
    }

    private let state: AddConnectorState

    init(model: CapabilitiesModel, added: @escaping (String) -> Void) {
        state = AddConnectorState(model: model)
        super.init(rootView: HQScaledRoot(AddConnectorView(state: state)))
        title = "Add a Connector"
        navigationItem.largeTitleDisplayMode = .never
        state.presenter = self
        state.close = { [weak self] name in
            self?.dismiss(animated: true) { if let name { added(name) } }
        }
        navigationItem.leftBarButtonItem = UIBarButtonItem.hqClose(.cancel, action: UIAction { [weak self] _ in self?.cancel() })
        navigationItem.leftBarButtonItem?.accessibilityIdentifier = "add-connector.cancel"
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        observeLock()
    }

    /// [keys] Mac polish #20: the sheet holds while something is typed in it or an Add is on its way, as the other
    /// editor sheets do: Escape then asks as Cancel does (it closed the half-filled form), and New Chat and the ⌘1…⌘9
    /// places leave it up instead of closing it first (`KeyCommands.sheetGivesWay`).
    private func observeLock() {
        withObservationTracking {
            _ = state.draft
            _ = state.adding
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeLock() }
        }
        navigationController?.isModalInPresentation = state.draft.hasContent || state.adding
    }

    private func cancel() {
        guard state.draft.hasContent, !state.adding else { dismiss(animated: true); return }
        let alert = UIAlertController(title: "Discard This Connector?", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Discard", style: .destructive) { [weak self] _ in self?.dismiss(animated: true) })
        alert.addAction(UIAlertAction(title: "Keep Editing", style: .cancel))
        present(alert, animated: true)
    }

    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool { !state.draft.hasContent && !state.adding }
    /// A swipe or Escape while an Add is on its way changes nothing (Mac polish #20: Escape closed the sheet then), as a
    /// connector page's Back waits on its save; Cancel still closes it.
    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
        guard !state.adding else { return }
        cancel()
    }
}

@MainActor @Observable
final class AddConnectorState {
    let model: CapabilitiesModel
    var draft = ConnectorDraft()
    var adding = false
    /// A name the gateway itself refused as taken.
    var refused: Set<String> = []
    @ObservationIgnored weak var presenter: UIViewController?
    @ObservationIgnored var close: ((String?) -> Void)?

    init(model: CapabilitiesModel) { self.model = model }

    var existing: [String] { (model.servers ?? []).map(\.name) + Array(refused) }
    var canAdd: Bool { draft.isComplete(existing: existing) && !adding }

    func add() {
        guard let store = model.store, canAdd else { return }
        adding = true
        let name = draft.trimmedName, profile = model.profile, kind = draft.kind
        let config = draft.config, bearer = draft.bearer
        let start = ContinuousClock.now
        Task {
            defer { adding = false }
            do {
                try await store.mcpAdd(name, config: config, bearer: bearer, profile: profile)
            } catch {
                AppLog.note("connect", "connector add \(kind.rawValue) failed after \(AppLog.ms(since: start)) ms: \(type(of: error))")
                if let reason = ConnectorDraft.reason(for: error) {
                    FailureAlert.present(title: "Couldn’t Add \(name)", reason: reason, from: presenter)
                } else {
                    refused.insert(name)
                }
                return
            }
            draft.token = ""
            let reloaded = (try? await store.client.call("reload.mcp", ["confirm": true], timeout: .seconds(30))) != nil
            await model.reloadServers()
            if !reloaded { model.serversNotice = "Saved. Its tools load in new chats." }
            AppLog.trace("connect", "connector add \(kind.rawValue) ok in \(AppLog.ms(since: start)) ms, reloaded \(reloaded)")
            Haptics.play(.success)
            close?(name)
        }
    }
}

struct AddConnectorView: View {
    @Bindable var state: AddConnectorState

    var body: some View {
        let draft = state.draft
        Form {
            Section {
                TextField("Name", text: $state.draft.name)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("add-connector.name")
            } footer: { HQSectionFooter {
                if !draft.trimmedName.isEmpty, !draft.nameValid {
                    Text("Names use 1-64 letters, digits, dots, dashes, or underscores.").foregroundStyle(.red)
                } else if draft.nameTaken(state.existing) {
                    Text("That name is already used.").foregroundStyle(.red).accessibilityIdentifier("add-connector.name-taken")
                } else {
                    Text("Add a connector to \(state.model.botName).")
                }
            } }
            Section {
                HQSegmentedPicker("Type", options: [("Web Address", ConnectorDraft.Kind.web), ("Command", ConnectorDraft.Kind.command)],
                                  selection: $state.draft.kind)   // [desktoplook3]
                .accessibilityIdentifier("add-connector.type")
            } footer: { HQSectionFooter {
                Text(draft.kind == .web ? "A service on the internet." : "A program on the computer running Hermes.")
            } }
            if draft.kind == .web { web } else { command }
            Section {
                Button(state.adding ? "Adding…" : "Add") { state.add() }
                    .frame(maxWidth: .infinity)
                    .disabled(!state.canAdd)
                    .accessibilityIdentifier("add-connector.add")
            }
        }
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .disabled(state.adding)
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder private var web: some View {
        Section {
            TextField("https://example.com/mcp", text: $state.draft.url)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("add-connector.url")
            Picker("Sign-In", selection: $state.draft.auth) {
                ForEach(ConnectorDraft.Auth.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("add-connector.auth")
            if state.draft.auth == .bearer {
                HStack(spacing: 12) {
                    SecureField("Token", text: $state.draft.token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("add-connector.token")
                    Button("Paste") {
                        if let text = UIPasteboard.general.string { state.draft.token = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    }
                    .hqBorderedButtonStyle()
                }
            }
        } header: { HQSectionLabel { Text("Web Address") } }
        pairs("Headers", add: "Add Header", list: $state.draft.headers, secretValues: true)
    }

    @ViewBuilder private var command: some View {
        Section {
            TextField("npx", text: $state.draft.command)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("add-connector.command")
        } header: { HQSectionLabel { Text("Command") } }
        Section {
            ForEach($state.draft.args) { $pair in
                HStack {
                    TextField("Argument", text: $pair.value).textInputAutocapitalization(.never).autocorrectionDisabled()
                    MacRemoveButton { state.draft.args.removeAll { $0.id == pair.id } }   // [mac] no swipe with a mouse
                }
            }
            .onDelete { state.draft.args.remove(atOffsets: $0) }
            Button("Add Argument", systemImage: "plus") { state.draft.args.append(.init()) }
        } header: { HQSectionLabel { Text("Arguments") } }
        pairs("Environment Variables", add: "Add Environment Variable", list: $state.draft.env, secretValues: true)
        Section {
            TextField("Optional", text: $state.draft.cwd).textInputAutocapitalization(.never).autocorrectionDisabled()
        } header: { HQSectionLabel { Text("Working Directory") } }
    }

    @ViewBuilder private func pairs(_ title: String, add: String, list: Binding<[ConnectorDraft.Pair]>, secretValues: Bool) -> some View {
        Section(title) {
            ForEach(list) { $pair in
                HStack(spacing: 10) {
                    TextField("KEY", text: $pair.key).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(Font.hq(.body).monospaced()).frame(maxWidth: .infinity)
                    Divider()
                    if secretValues, McpEntryMask.SECRET_KEY.test(pair.key) {
                        SecureField("value", text: $pair.value).textInputAutocapitalization(.never).autocorrectionDisabled().frame(maxWidth: .infinity)
                    } else {
                        TextField("value", text: $pair.value).textInputAutocapitalization(.never).autocorrectionDisabled().frame(maxWidth: .infinity)
                    }
                    MacRemoveButton { list.wrappedValue.removeAll { $0.id == pair.id } }   // [mac] no swipe with a mouse
                }
            }
            .onDelete { list.wrappedValue.remove(atOffsets: $0) }
            Button(add, systemImage: "plus") { list.wrappedValue.append(.init()) }
        }
    }
}
