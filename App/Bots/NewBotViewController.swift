// New Bot (spec 1x-settings §8): Name, Title, Description in a sheet; Create makes the profile, its meta and its Bot
// Chat, closes the sheet, opens the chat and lets the bot introduce itself (or says it has no model provider yet).

import SwiftUI
import UIKit

@MainActor enum NewBotFlow {
    static func present(from presenter: UIViewController, services: any AppServices) {
        guard let settings = services as? SettingsServices, settings.botEditing != nil else { return }
        let page = NewBotController(services: services, settings: settings)
        let navigation = UINavigationController(rootViewController: page)
        SheetStyle.apply(navigation, from: presenter)   // [m9/ipad] a centred form sheet in two panes (§4.8)
        presenter.present(navigation, animated: true)
    }

    /// Steps 6–8: the chat opens from Bots, then the intro (or the no-model notice), and a success haptic.
    static func openChat(_ result: NewBotResult, services: any AppServices, settings: any SettingsServices) {
        guard let root = MainTabController.current else { return }
        root.select(.bots)
        let bots = root.botsViewController
        bots.navigationController?.popToRootViewController(animated: false)
        bots.reload(animated: false)
        bots.open(result.bot.id)
        waitForChat(root, attempts: 30) { chat in
            Haptics.play(.success)
            settings.startIntro(in: chat.session, result: result)
        }
    }

    private static func waitForChat(_ root: MainTabController, attempts: Int, _ done: @escaping (ChatViewController) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let chat = root.botsViewController.navigationController?.paneChat, chat.view.window != nil {
                done(chat)
            } else if attempts > 0 {
                waitForChat(root, attempts: attempts - 1, done)
            }
        }
    }
}

@MainActor @Observable
final class NewBotModel {
    var name = ""
    var title = ""
    var description = ""
    var creating = false
    var inlineError: String?
    @ObservationIgnored let editing: any BotEditing

    init(editing: any BotEditing) { self.editing = editing }

    var identity: (slug: String, title: String) { BotIdentity.profileIdentity(name: name, title: title) }
    var slug: String { identity.slug }
    var valid: Bool { BotIdentity.isValidProfileId(slug) }
    var taken: Bool { valid && editing.isTaken(profileName: slug) }
    var canCreate: Bool { valid && !taken && !creating }
}

final class NewBotController: UIHostingController<HQScaledRoot<NewBotView>> {
    let model: NewBotModel
    let services: any AppServices
    let settings: any SettingsServices
    private var createItem: UIBarButtonItem!

    init(services: any AppServices, settings: any SettingsServices) {
        let model = NewBotModel(editing: settings.botEditing!)
        self.model = model
        self.services = services
        self.settings = settings
        super.init(rootView: HQScaledRoot(NewBotView(model: model)))
        title = "New Bot"
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItem = UIBarButtonItem.hqClose(.cancel, action: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        createItem = UIBarButtonItem(title: "Create", style: .prominent, target: self, action: #selector(create))
        createItem.accessibilityIdentifier = "new-bot.create"
        navigationItem.rightBarButtonItem = createItem
        observe()
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func observe() {
        withObservationTracking {
            _ = model.canCreate
            _ = model.creating
            _ = model.name
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshBar()
                self.observe()
            }
        }
        refreshBar()
    }

    private func refreshBar() {
        createItem.title = model.creating ? "Creating…" : "Create"
        createItem.setProminentEnabled(model.canCreate)
        navigationItem.leftBarButtonItem?.isEnabled = !model.creating
        let typed = !model.name.isEmpty || !model.title.isEmpty || !model.description.isEmpty
        navigationController?.isModalInPresentation = typed || model.creating
    }

    override var keyCommands: [UIKeyCommand]? { (super.keyCommands ?? []) + (createItem?.isEnabled == true ? [.save("Create", #selector(create))] : []) }
    override var canBecomeFirstResponder: Bool { true }

    @objc private func create() {
        guard model.canCreate, let editing = settings.botEditing else { return }
        view.endEditing(true)
        model.creating = true
        model.inlineError = nil
        let name = model.name, title = model.title, description = model.description
        let services = self.services, settings = self.settings
        Task {
            do {
                let result = try await editing.createBot(name: name, title: title, description: description)
                model.creating = false
                dismiss(animated: true) { NewBotFlow.openChat(result, services: services, settings: settings) }
            } catch let error as NewBotError {
                model.creating = false
                model.inlineError = error.errorDescription
                Haptics.play(.error)
            } catch {
                model.creating = false
                let display = BotIdentity.displayName(name: model.slug, title: model.identity.title)
                FailureAlert.present(error, fallbackTitle: "Couldn’t Create \(display)", from: self) { self.create() }
            }
        }
    }
}

struct NewBotView: View {
    @Bindable var model: NewBotModel
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    Text("A named teammate with its own memory, skills, and chat. It can message your other bots.")
                        .font(Font.hq(.subheadline))
                        .foregroundStyle(Color.hqLabel2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    HeadImage(head: Head.defaultHead(profile: model.slug.isEmpty ? "new-bot" : model.slug), size: 72)
                    Text("The bot gets a shape from its name. You can change it once the bot is created.")
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqLabel2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 4)
                .listRowBackground(Color.clear)
            }
            .listSectionSpacing(.compact)
            Section {
                TextField("inbox-triage", text: $model.name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .accessibilityIdentifier("new-bot.name")
                if model.taken {
                    Text("A bot named “\(model.slug)” already exists.")
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqRed)
                        .accessibilityIdentifier("new-bot.taken")
                } else if let error = model.inlineError {
                    Text(error).font(Font.hq(.footnote)).foregroundStyle(Color.hqRed).accessibilityIdentifier("new-bot.error")
                }
            } header: { HQSectionLabel {
                Text("Name")
            } } footer: { HQSectionFooter {
                Text("Lowercase letters, numbers and dashes. Spaces become dashes.")
            } }
            Section {
                TextField("Inbox Triage", text: $model.title)
                    .textInputAutocapitalization(.words)
                    .accessibilityIdentifier("new-bot.title")
            } header: { HQSectionLabel { Text("Display Name") } } footer: { HQSectionFooter {   // Edit Bot's word for the same field (UX study #184)
                Text("The name shown in lists. Leave it blank to use the Name.")
            } }
            Section {
                TextField("What should this bot help with?", text: $model.description, axis: .vertical)
                    .lineLimit(3...8)
                    .accessibilityIdentifier("new-bot.description")
            } header: { HQSectionLabel { Text("Description") } }
        }
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .contentMargins(.top, 0, for: .scrollContent)
        .disabled(model.creating)
        .onAppear { focused = true }
    }
}
