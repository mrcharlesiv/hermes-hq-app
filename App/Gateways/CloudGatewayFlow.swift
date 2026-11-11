// Hermes Cloud…: a Hermes that Nous hosts, set up from the phone. Sign in to Nous Portal once
// (HermesKit/Cloud/PortalAuth.swift), pick one of your Hermes Cloud agents or make one (name, size cards with prices,
// region nearest you; fields come from Portal's own schema), watch it come up step by step, then Sign in with Nous to
// its dashboard with no typing. Success saves the gateway and switches to it, the same as Add Gateway
// (App/Gateways/AddGatewayFlow.swift). Screens: CloudGatewayScreens.swift; the face that builds itself while Nous works:
// CloudForgeView.swift. Nous can take a quarter of an hour (17 minutes on 2026-10-30): the sheet may be closed while it
// builds, and opening Hermes Cloud again picks the same agent back up (`CloudPending`). Tapping an agent opens its own
// page: stop, start, restart, rename, resize, update, variables, disk, Team Gateway and delete
// (CloudAgentControls.swift, CloudAgentScreens.swift).

import SwiftUI
import UIKit

@MainActor enum CloudGatewayFlow {
    /// A gateway Nous hosts (`<name>.agents.nousresearch.com`): its row and the title menu offer Manage on Hermes Cloud….
    static func isCloud(_ url: URL?) -> Bool {
        #if DEBUG
        // Screenshots: the fixture gateway passes for a Nous one (`-HQDebugCloudHost YES`).
        if url != nil, UserDefaults.standard.bool(forKey: "HQDebugCloudHost") { return true }
        #endif
        return url?.host?.lowercased().hasSuffix(".agents.nousresearch.com") == true
    }

    /// `agent`: a saved Nous gateway's address; the sheet opens on that agent's page once Your Agents has loaded.
    /// `connected`: what success does instead of switching the running app (signed out, onboarding hands it to the launch);
    /// it gets the account and the sheet, and closes the sheet itself.
    static func present(from presenter: UIViewController?, services: any AppServices, agent: URL? = nil, demo: String? = nil,
                        connected: ((GatewayAccount, UIViewController) -> Void)? = nil) {
        guard let settings = services as? SettingsServices, let host = FailureAlert.topmost(presenter) else { return }
        let saved = Set(settings.gateways.accounts.map { $0.account.baseURL.host?.lowercased() ?? "" })
        let model = CloudGatewayModel(driver: settings.makeSignInDriver(), savedHosts: saved)
        model.gateways = settings.gateways
        model.openHost = agent?.host?.lowercased()
        let root = page(CloudGatewayView(model: model), title: CloudCopy.title)
        (root as? CloudPage<HQScaledRoot<CloudGatewayView>>)?.keyRefresh = { [weak model] in Task { await model?.refresh() } }   // ⌘R, as a pull (the Mac has no pull)
        let nav = UINavigationController(rootViewController: root)
        let close = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak nav, weak model] _ in
            // Once signed in to the new agent its gateway is saved: closing switches to it, as Open does.
            // While Nous builds, closing only stops the phone waiting: the agent carries on, and Hermes Cloud picks it up.
            if model?.phase == .success { model?.finish() } else { model?.leave(); nav?.dismiss(animated: true) }
        })
        close.accessibilityIdentifier = "cloud-gateway.cancel"
        root.navigationItem.leftBarButtonItem = close
        var moreActions = [UIAction(title: CloudCopy.manage, image: UIImage(systemName: "safari")) { _ in UIApplication.shared.open(Portal.agentsPage) }]
        // [app-store-review] Guideline 3.1.1: Portal.newAgentPage is Nous Portal's priced "create an agent" page;
        // Manage on Nous Portal above only opens agent management, so it stays.
        #if !APP_STORE
        moreActions.append(UIAction(title: CloudCopy.prices, image: UIImage(systemName: "tag")) { _ in UIApplication.shared.open(Portal.newAgentPage) })
        #endif
        moreActions.append(UIAction(title: CloudCopy.signOut, image: UIImage(systemName: "rectangle.portrait.and.arrow.right"), attributes: .destructive) {
            [weak model, weak nav] _ in
            nav?.popToRootViewController(animated: true)
            model?.signOut()
        })
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: UIMenu(children: moreActions))
        more.accessibilityLabel = CloudCopy.moreLabel
        more.accessibilityIdentifier = "cloud-gateway.more"
        model.onSignedIn = { [weak root] signedIn in root?.navigationItem.rightBarButtonItem = signedIn ? more : nil }
        model.onModal = { [weak nav, weak close, weak more] modal, closable in
            // A sign-in saves the new gateway and ends the current one's client: nothing may close the sheet halfway.
            nav?.isModalInPresentation = modal
            close?.isEnabled = closable
            more?.isEnabled = !modal
        }
        model.onRoute = { [weak nav, weak model] route in
            guard let nav, let model else { return }
            switch route {
            case .compose:
                guard nav.viewControllers.count == 1 else { return }
                nav.pushViewController(page(CloudComposeView(model: model, first: false), title: CloudCopy.newAgent), animated: demo == nil)
            case .root:
                nav.popToRootViewController(animated: true)
            case .back:
                nav.popViewController(animated: true)
            case .agent(let id):
                let name = model.agent(id)?.name ?? CloudCopy.title
                let agentPage = page(CloudAgentPage(model: model, id: id), title: name)
                // The name is under the face until it scrolls away (`onTitleShown`).
                agentPage.navigationItem.title = ""
                nav.pushViewController(agentPage, animated: demo == nil)
            case .resize(let id):
                nav.pushViewController(page(CloudResizePage(model: model, id: id), title: CloudCopy.changeSize), animated: demo == nil)
            case .variables(let id):
                nav.pushViewController(page(CloudVariablesPage(model: model, id: id), title: CloudCopy.variables), animated: demo == nil)
            case .delete(let id):
                nav.pushViewController(page(CloudDeletePage(model: model, id: id), title: CloudCopy.deleteTitle), animated: demo == nil)
            case .desktop(let id):
                // [cloud-desktop] The agent's own Hermes Desktop, pushed in the sheet (Back returns to its page).
                guard let agent = model.agent(id), let url = CloudDesktopWeb.address(agent.dashboardURL) else { return }
                nav.pushViewController(CloudDesktopWebController(url: url, agentName: agent.name), animated: demo == nil)
            }
        }
        model.onRenamed = { [weak nav] id, name in
            // The agent's page keeps its title in step with Nous.
            for controller in nav?.viewControllers ?? [] where (controller as? CloudAgentHost)?.agentId == id { controller.title = name }
        }
        model.onTitleShown = { [weak nav] id, shown in
            for case let controller as CloudAgentHost in nav?.viewControllers ?? [] where controller.agentId == id {
                controller.navigationItem.title = shown ? controller.title : ""
            }
        }
        model.onConfirm = { [weak nav] title, message, action, destructive, done in
            guard let host = FailureAlert.topmost(nav?.topViewController) else { return }
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            let confirm = UIAlertAction(title: action, style: destructive ? .destructive : .default) { _ in done() }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(confirm)
            if !destructive { alert.preferredAction = confirm }
            host.present(alert, animated: true)
        }
        model.onPrompt = { [weak nav] title, message, text, action, limit, done in
            TextPrompt.present(title: title, message: message, text: text, placeholder: CloudCopy.namePlaceholder, action: action,
                               maxLength: limit, requireChange: true, identifier: "cloud-agent.rename-field", selectText: true,
                               autocapitalization: .words, autocorrection: .no, from: nav?.topViewController, done: done)
        }
        model.onConnected = { [weak nav] account in
            if let connected, let nav { connected(account, nav); return }
            settings.adoptSignedInAccount(account)
            nav?.dismiss(animated: true)
        }
        #if DEBUG
        if let demo { model.debugShow(demo) }
        #endif
        SheetStyle.apply(nav, from: host)
        nav.sheetPresentationController?.detents = [.large()]
        host.present(nav, animated: true)
    }

    static func page<V: View>(_ view: V, title: String) -> UIViewController {
        let controller: UIViewController
        if let agentPage = view as? CloudAgentPage {
            controller = CloudAgentHost(rootView: HQScaledRoot(agentPage), agentId: agentPage.id)
        } else {
            controller = CloudPage(rootView: HQScaledRoot(view))
        }
        controller.title = title
        controller.view.backgroundColor = HQPalette.groupedPage
        controller.navigationItem.largeTitleDisplayMode = .never
        return controller
    }
}

/// A page of the sheet; Your Agents refreshes on ⌘R (`KeyCommands.sheetRefresh`).
final class CloudPage<Content: View>: UIHostingController<Content>, KeyRefreshing {
    var keyRefresh: (() -> Void)?
}

/// The screens' words.
enum CloudCopy {
    static let title = "Hermes Cloud"
    static let menuTitle = "Hermes Cloud…"
    static let manageAgent = "Manage Agent…"
    static let moreLabel = "More"

    static let heading = "Hermes, in the cloud"
    static let lead = "Nous runs a Hermes for you, around the clock. Make one here and HQ signs you in."
    static var points: [(symbol: String, title: String, text: String)] {
        #if APP_STORE
        // [app-store-review] Guideline 3.1.1: no price or "paid from your credit" wording in the App Store build.
        [("bolt.fill", "Always on", "It keeps working when your computer sleeps, or when you don’t have one."),
         ("wand.and.stars", "Nothing to set up", "No terminal, no Tailscale, no address to type. HQ signs you in."),
         ("creditcard.fill", "Runs on your Nous account", costNote)]
        #else
        [("bolt.fill", "Always on", "It keeps working when your computer sleeps, or when you don’t have one."),
         ("wand.and.stars", "Nothing to set up", "No terminal, no Tailscale, no address to type. HQ signs you in."),
         ("creditcard.fill", startsAt, "Paid from your Nous credit for the time it runs. \(CloudPrices.dollars(CloudPrices.stoppedPerDay)) a day while stopped.")]
        #endif
    }
    static var startsAt: String {
        CloudPrices.lowestPerDay.map { "From \(CloudPrices.dollars($0)) a day" } ?? "Paid from your Nous credit"
    }
    /// The App Store build's one neutral line, everywhere `startsAt` and the cost card's price would otherwise show
    /// a dollar figure or a link to Nous Portal's pricing (Guideline 3.1.1).
    static let costNote = "Hermes Cloud runs on your Nous account. Its cost is shown in your Nous account."
    static let signIn = "Continue with Nous"
    static let signInNote = "Use the account you sign in to Nous Portal with."
    static let loading = "Looking for your agents…"

    static let yourAgents = "Your Agents"
    static let newAgent = "New Agent"
    static let newAgentDetail = "Pick a name and a size. Ready in a few minutes."
    static let homeFoot = "Nous bills your credit once a day for the time each agent ran."
    static let connect = "Connect"
    static let start = "Start"
    static let open = "Open"

    static let firstHeading = "Make your first agent"
    static let firstLead = "Pick a name and a size. Nous runs it, and HQ signs you in when it’s ready."
    static let name = "Name"
    static let namePlaceholder = "Research Bot"
    static let nameTaken = "You already have an agent with this name."
    static let size = "Size"
    /// Screen on Hermes Cloud (CloudScreen): the agent page's row and the line under the size cards.
    static let screen = "Screen"
    static func screenValue(_ included: Bool) -> String { included ? "Included" : "Needs 8 GB" }
    // The Max card under Standard and Pro (CloudScreenSizeCard).
    static let includesScreen = "Screen"
    static let screenWhat = "Its own desktop and browser. Watch it work, and take over for a login or a payment."
    static let bigDisk = "100 GB disk"
    static let region = "Region"
    static let closest = "Closest to you"
    static let create = "Create Agent"
    static let manage = "Manage on Nous Portal"
    static let prices = "Prices on Nous Portal"
    static let signOut = "Sign Out of Nous Portal"

    static func specs(_ size: CloudSize) -> String { "\(size.memory) · \(size.cpus) CPUs" }
    static func chats(_ size: CloudSize) -> String { "Up to \(size.chats) chats at once" }
    static func perDay(_ size: CloudSize) -> String { "About \(CloudPrices.dollars(size.perDay)) a day while it runs" }
    static func costDetail(_ size: CloudSize) -> String {
        "Around \(CloudPrices.dollars(CloudPrices.month(size.perDay))) a month if it never stops, \(CloudPrices.dollars(size.stoppedPerDay)) a day while stopped. "
            + "Nous bills your credit once a day for the time it actually ran; you need \(CloudPrices.dollars(CloudPrices.minimumCredit)) of credit to start."
    }
    #if APP_STORE
    // [app-store-review] Guideline 3.1.1: no "paid from your credit" wording in the App Store build.
    static let costUnknown = costNote
    #else
    static let costUnknown = "Paid from your Nous credit while it runs, and a little for storage while stopped."
    #endif

    static func confirmTitle(_ name: String) -> String { "Create “\(name)”?" }
    static func confirmMessage(size: String, region: String?, price: CloudSize?) -> String {
        let place = [size, region].compactMap { $0 }.joined(separator: " in ")
        #if APP_STORE
        // [app-store-review] Guideline 3.1.1: no "$X a day" or "paid from your credit" wording in the App Store build.
        let cost = costNote
        #else
        let cost = price.map { "About \(CloudPrices.dollars($0.perDay)) a day while it runs, from your Nous credit." } ?? "It’s paid from your Nous credit while it runs."
        #endif
        return "\(place). \(cost) You can stop or delete it anytime in Settings › Gateways or on Nous Portal."
    }

    // Progress
    static func settingUp(_ name: String) -> String { "Building \(name)" }
    static func connecting(_ name: String) -> String { "Connecting \(name)" }
    static let usuallyTakes = "Nous is building it from scratch. This can take up to 20 minutes."
    static let connectTakes = "This takes a few seconds, or a minute or two if it was stopped."
    static let slow = "Taking longer than usual. Nous is still on it."
    static let stepCreate = "Ask Nous for a machine"
    static func stepBuild(_ name: String) -> String { "Build and start \(name)" }
    static func stepStart(_ name: String) -> String { "Start \(name)" }
    static let stepCheck = "Check it’s answering"
    static let stepSignIn = "Sign you in"
    static func asking(region: String?) -> String { region.map { "In \($0)" } ?? "Waiting for Nous to answer" }
    static let leaveNote = "You can close this. Nous keeps building, and Hermes Cloud picks up where it left off."
    /// "4:05", and past an hour "1:15:03" (a bot wait and an install can run that long; "75:03" read as a time of day).
    static func elapsed(_ seconds: Int) -> String {
        let seconds = max(0, seconds)
        guard seconds >= 3600 else { return String(format: "%d:%02d", seconds / 60, seconds % 60) }
        return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
    static let whileYouWait = "While You Wait"
    static var tips: [(symbol: String, title: String, text: String)] {
        // [app-store-review] Guideline 3.1.1: no dollar amount in the App Store build.
        #if APP_STORE
        let stopTip = "In Settings › Gateways or on Nous Portal. \(costNote)"
        #else
        let stopTip = "In Settings › Gateways or on Nous Portal. Stopped, it costs \(CloudPrices.dollars(CloudPrices.stoppedPerDay)) a day and keeps everything."
        #endif
        return [("moon.stars.fill", "It never sleeps", "Jobs you schedule run on time, even with your phone and computer off."),
                ("person.badge.key.fill", "Signs in with Nous", "Your Nous account is the key. There’s no password to keep."),
                ("pause.circle.fill", "Stop it anytime", stopTip),
                ("square.stack.3d.up.fill", "Beside your other gateways", "Switch between them from the name at the top of Bots.")]
    }

    /// What Nous says the agent is doing, in plain words (Portal's status words aren't documented: unknown ones show as
    /// they come).
    static func live(_ agent: CloudAgent) -> String {
        let status = agent.status.lowercased()
        if agent.isReady { return "It’s up. Opening the door…" }
        if agent.isFailed { return "Nous says it failed" }
        if ["provision", "creat", "pending", "queue", "schedul", "alloc"].contains(where: status.contains) { return "Nous is getting a machine ready" }
        if ["deploy", "build", "image", "install", "pull"].contains(where: status.contains) { return "Installing Hermes" }
        if ["start", "boot", "launch", "initial"].contains(where: status.contains) { return "Starting Hermes" }
        if agent.isRunning, agent.dashboardURL == nil { return "Running. Waiting for its address" }
        if agent.isRunning { return "Running. Waiting for it to answer" }
        if agent.isStopped { return "Stopped. Starting it" }
        return "Nous says: \(CloudToolSchema.title(agent.status))"
    }

    // Done
    static func ready(_ name: String) -> String { "Meet \(name)" }
    static let readyLead = "It’s running on Nous, saved with your gateways, and you’re signed in."
    static func openAgent(_ name: String) -> String { "Open \(name)" }
    static let address = "Address"
    static let cost = "Cost"

    // Failed
    static let failedTitle = "That didn’t work"
    static let tryAgain = "Try Again"
    static let stuck = "It’s taking longer than usual. Check the agent on Nous Portal, or try again in a minute."

    /// The face these screens wear: a dot-matrix head like a new bot's, the same on every phone.
    static var mascot: Head { Head.defaultHead(profile: "hermes-cloud") }

    static func statusWord(_ agent: CloudAgent) -> String {
        if agent.isSleeping, agent.dashboardURL != nil { return "Asleep" }
        if agent.isReady { return "Running" }
        if agent.isStopped { return "Stopped" }
        if agent.isFailed { return "Failed" }
        if agent.dashboardURL == nil { return "Setting up" }
        return CloudToolSchema.title(agent.status)
    }

    static func sizeWord(_ key: String) -> String { CloudToolSchema.title(key) }
    static func regionWord(_ key: String) -> String { CloudToolSchema.regionNames[key.lowercased()] ?? key.uppercased() }
}

@MainActor @Observable final class CloudGatewayModel {
    enum Phase: Equatable { case start, signingIn, loading, home, working, success, failed }
    enum Route: Equatable { case compose, root, back, agent(String), resize(String), variables(String), delete(String), desktop(String) }

    struct Step: Identifiable, Equatable {
        enum State: Equatable { case waiting, active, done }
        var id: String
        var title: String
        var state: State = .waiting
        var started: Date?
        var finished: Date?
        /// What's happening in it right now (Portal's status, in words).
        var detail: String?
    }

    private(set) var phase: Phase = .start
    private(set) var agents: [CloudAgent] = []
    // Managing agents that exist (CloudAgentControls.swift).
    /// Agent id → what's being done to it right now.
    var busy: [String: CloudBusy] = [:]
    /// Agent id → why the last action on it didn't finish.
    var actionFailure: [String: String] = [:]
    /// The agent to open once the list loads (`CloudGatewayFlow.present(agent:)`).
    var openHost: String?
    /// Agent id → Team Gateway as Portal last said.
    var teamGateways: [String: CloudTeamGateway] = [:]
    /// The `agent` actions this Portal offers; empty until read (everything shows meanwhile).
    var offered: Set<CloudAction> = []
    /// Sizes resize takes (the schema's), else the price table's.
    var sizeChoices: [String] = []
    /// Disk sizes grow_disk takes, when Nous has said (an agent row, or a refusal listing them).
    var diskChoices: [Int] = []
    var actionTasks: [String: Task<Void, Never>] = [:]
    /// The phone's saved gateways: whether an agent is one, and the row to rename or remove with it.
    weak var gateways: (any GatewayAccounts)?
    var onRenamed: ((_ id: String, _ name: String) -> Void)?
    /// An agent's page scrolled its name out of sight (true) or back (false): the bar's title follows.
    var onTitleShown: ((_ id: String, _ shown: Bool) -> Void)?
    /// A system alert over the top page: title, message, the action's word, whether it's destructive, and what it does.
    var onConfirm: ((_ title: String, _ message: String?, _ action: String, _ destructive: Bool, _ done: @escaping () -> Void) -> Void)?
    /// A one-field alert (Rename): title, message, starting text, the action's word, the longest text, and what it does.
    var onPrompt: ((_ title: String, _ message: String?, _ text: String, _ action: String, _ limit: Int, _ done: @escaping (String) -> Void) -> Void)?
    private(set) var spend: [String: CloudSpend] = [:]
    private(set) var fields: [CloudField] = []
    private(set) var failure = ""
    private(set) var steps: [Step] = []
    private(set) var workTitle = ""
    private(set) var workStarted = Date()
    private(set) var slow = false
    private(set) var connectedAgent: CloudAgent?
    /// The agent being built or connected: its name picks the face that builds itself.
    private(set) var agentName = ""
    private(set) var finishedAt: Date?
    private(set) var connectedSize: String?
    private(set) var nameLimit = 64
    private(set) var signedIn = false { didSet { if signedIn != oldValue { onSignedIn?(signedIn) } } }
    var name = "" { didSet { if name.count > nameLimit { name = String(name.prefix(nameLimit)) } } }
    var values: [String: String] = [:]

    var onModal: ((_ modal: Bool, _ closable: Bool) -> Void)?
    var onSignedIn: ((Bool) -> Void)?
    var onRoute: ((Route) -> Void)?
    var onConnected: ((GatewayAccount) -> Void)?

    private let driver: SignInServiceDriver
    let client: HermesCloudClient
    private let login: PortalLogin
    private let savedHosts: Set<String>
    private var connectedAccount: GatewayAccount?
    private var work: Task<Void, Never>?
    /// DEBUG screenshots: nothing goes to Portal.
    private(set) var demo = false

    init(driver: SignInServiceDriver, savedHosts: Set<String>, client: HermesCloudClient = HermesCloudClient(), login: PortalLogin = .shared) {
        self.driver = driver; self.savedHosts = savedHosts; self.client = client; self.login = login
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Names must differ: after a create that outlasted the wait, the new agent is found by its name.
    var nameTaken: Bool { agents.contains { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame } }
    var canCreate: Bool {
        !trimmedName.isEmpty && !nameTaken && fields.allSatisfy { !$0.required || !(values[$0.name] ?? "").isEmpty }
    }
    func isSaved(_ agent: CloudAgent) -> Bool {
        if gateways != nil { return savedGateway(agent) != nil }
        return agent.dashboardURL?.host.map { savedHosts.contains($0.lowercased()) } ?? false
    }

    /// The saved gateway that is this agent (same address), if the phone has one.
    func savedGateway(_ agent: CloudAgent) -> GatewayAccountRow? {
        guard let host = agent.dashboardURL?.host?.lowercased() else { return nil }
        return gateways?.accounts.first { $0.account.baseURL.host?.lowercased() == host }
    }

    func agent(_ id: String) -> CloudAgent? { agents.first { $0.id == id } }

    /// A fresher row for one agent (an action's answer, a poll). Fields the new row doesn't carry keep what was known.
    func update(_ fresh: CloudAgent) {
        guard let index = agents.firstIndex(where: { $0.id == fresh.id }) else { return }
        var merged = fresh
        let old = agents[index]
        if merged.size.isEmpty { merged.size = old.size }
        if merged.region.isEmpty { merged.region = old.region }
        if merged.diskGB == nil { merged.diskGB = old.diskGB }
        if merged.diskChoices.isEmpty { merged.diskChoices = old.diskChoices }
        if merged.envNames.isEmpty { merged.envNames = old.envNames }
        if merged.relay == nil { merged.relay = old.relay }
        if merged.version.isEmpty { merged.version = old.version }
        if merged.updateAvailable == nil { merged.updateAvailable = old.updateAvailable }
        if merged.dashboardURL == nil, merged.isChanging || merged.isRunning { merged.dashboardURL = old.dashboardURL }
        if merged != old { agents[index] = merged }
    }

    /// A change to one agent's row made here (a variable removed, a debug action played out).
    func edit(_ id: String, _ change: (inout CloudAgent) -> Void) {
        guard let index = agents.firstIndex(where: { $0.id == id }) else { return }
        change(&agents[index])
    }

    /// Gone from Nous (deleted).
    func drop(_ id: String) {
        agents.removeAll { $0.id == id }
        spend[id] = nil
        teamGateways[id] = nil
        busy[id] = nil
    }

    /// A name Nous now has (rename), before the next read of the list confirms it.
    func renamed(_ id: String, to name: String) {
        guard let index = agents.firstIndex(where: { $0.id == id }) else { return }
        agents[index].name = name
        onRenamed?(id, name)
    }

    var sizeField: CloudField? { fields.first { $0.name == "size" } }
    var regionField: CloudField? { fields.first { $0.name == "region" } }
    var otherFields: [CloudField] { fields.filter { $0.name != "size" && $0.name != "region" } }
    var chosenSize: CloudSize? { CloudPrices.size(values["size"]) }
    var closestRegion: String? { regionField.flatMap { CloudRegions.closest(among: $0.choices) } }

    private func set(_ next: Phase) {
        phase = next
        signalModal()
    }

    /// A sign-in saves the new gateway and ends the current one's client, so nothing may close the sheet during one;
    /// while Nous builds, Close only stops the waiting (`leave`).
    private func signalModal() {
        let signing = steps.contains { $0.id == "signin" && $0.state == .active }
        let modal = [.signingIn, .working, .success].contains(phase)
        onModal?(modal, phase != .signingIn && !(phase == .working && signing))
    }

    /// The face's moment, from the steps.
    var forgeStage: CloudForge.Stage {
        if phase == .success { return .done(at: finishedAt ?? Date()) }
        func began(_ id: String) -> Date? { steps.first { $0.id == id && $0.state != .waiting }?.started }
        if let at = began("signin") { return .waking(since: at) }
        if let step = steps.first(where: { $0.id == "start" }), step.state == .active { return .building(since: step.started ?? workStarted) }
        if let step = steps.first(where: { $0.id == "create" }), step.state == .active { return .gathering(since: step.started ?? workStarted) }
        return .gathering(since: workStarted)
    }

    /// Close while Nous builds: stop waiting here. The agent carries on; `CloudPending` brings it back next time.
    func leave() {
        work?.cancel()
        work = nil
        // An action already sent carries on at Nous; only the phone's watching stops.
        actionTasks.values.forEach { $0.cancel() }
        actionTasks = [:]
    }

    func appear() {
        guard phase == .start, !demo else { return }
        Task {
            if await login.isSignedIn { signedIn = true; load() }
        }
    }

    func signIn() {
        guard phase == .start else { return }
        set(.signingIn)
        failure = ""
        work = Task {
            do {
                try await PortalSignIn.run(browser: WebAuthBrowser(anchor: Self.keyWindow, isPrivate: NousSheetLogin.isPrivate))
                AppLog.trace("cloud", "portal signed in")
                signedIn = true
                Haptics.play(.success)
                load()
            } catch {
                if case GatewayFailure.nousCancelled = error { set(.start); return }
                AppLog.trace("cloud", "portal sign-in failed: \(Self.words(error))")
                Haptics.play(.error)
                failure = Self.words(error)
                set(.start)
            }
        }
    }

    func signOut() {
        NousSheetLogin.chooseAccount()   // [nous-different-account] signing out of Nous is how to change accounts
        work?.cancel()
        Task { await forget() }
    }

    /// [nous-different-account] Use Another Nous Account: signs out, then opens a private sheet at once, so Safari's
    /// saved Nous login can't pick the account again.
    func useOtherAccount() {
        NousSheetLogin.chooseAccount()
        work?.cancel()
        Task {
            await forget()
            signIn()
        }
    }

    private func forget() async {
        await login.signOut()
        agents = []; fields = []; spend = [:]; failure = ""
        busy = [:]; actionFailure = [:]; teamGateways = [:]
        signedIn = false
        set(.start)
    }

    func load() {
        set(.loading)
        work = Task {
            do {
                async let list = client.listAgents()
                async let form = client.createFields()
                let (found, made) = try await (list, form)
                nameLimit = await client.nameLimit()
                agents = found
                fields = made
                for field in made where values[field.name] == nil {
                    if field.name == "region", let near = CloudRegions.closest(among: field.choices) { values[field.name] = near }
                    else if let given = field.defaultValue { values[field.name] = given }
                    else if field.kind == .choice, let first = field.choices.first { values[field.name] = first }
                }
                AppLog.trace("cloud", "agents \(found.count), create fields \(made.map(\.name).joined(separator: ","))")
                set(.home)
                loadSpend(found)
                resumePending(found)
                // Opened from a Nous gateway's row or the title menu: straight to that agent's page.
                if let host = openHost {
                    openHost = nil
                    if let agent = found.first(where: { $0.dashboardURL?.host?.lowercased() == host }) { open(agent) }
                    else { AppLog.trace("cloud", "no agent at \(host) on this Nous account") }
                }
            } catch {
                handle(error)
            }
        }
    }

    /// Pull to refresh on Your Agents: the list again, staying on the page; a failure keeps the rows already shown.
    func refresh() async {
        guard phase == .home, !demo else { return }
        do {
            let found = try await client.listAgents()
            agents = found
            loadSpend(found)
        } catch let error as PortalError where error.kind == .signedOut {
            handle(error)
        } catch {
            AppLog.trace("cloud", "refresh failed: \(Self.words(error))")
        }
    }

    /// Portal's cost estimate for each agent, beside its row; quietly nothing when it has none.
    func loadSpend(_ agents: [CloudAgent]) {
        let client = self.client
        for agent in agents where !agent.isFailed {
            Task {
                if let found = await client.spend(agent.id) { spend[agent.id] = found }
            }
        }
    }

    /// An agent this phone asked for and stopped waiting on (the sheet closed, the app went away): back to its progress.
    private func resumePending(_ found: [CloudAgent]) {
        guard let pending = CloudPending.load() else { return }
        guard let agent = found.first(where: pending.matches) else {
            // Not listed yet, or gone: forgotten after an hour.
            if Date().timeIntervalSince(pending.made) > 3600 { CloudPending.clear() }
            return
        }
        if agent.isFailed || isSaved(agent) { CloudPending.clear(); return }
        AppLog.trace("cloud", "resume \(agent.id) status=\(agent.status) after \(Int(Date().timeIntervalSince(pending.made)))s")
        connect(agent, resuming: pending)
    }

    func compose() { onRoute?(.compose) }

    /// An existing agent: start it if it's stopped, wait until it answers, sign in.
    func connect(_ agent: CloudAgent, resuming pending: CloudPending? = nil) {
        guard phase == .home, busy[agent.id] == nil else { return }
        // From the agent's own page: the progress is on the root.
        onRoute?(.root)
        let starts = agent.isStopped && !agent.isSleeping
        let building = pending != nil || (!agent.isReady && !agent.isStopped)
        var list: [Step] = []
        if pending != nil { list.append(Step(id: "create", title: CloudCopy.stepCreate, state: .done)) }
        list.append(Step(id: "start", title: building ? CloudCopy.stepBuild(agent.name) : starts ? CloudCopy.stepStart(agent.name) : CloudCopy.stepCheck))
        list.append(Step(id: "signin", title: CloudCopy.stepSignIn))
        agentName = agent.name
        begin(building ? CloudCopy.settingUp(agent.name) : CloudCopy.connecting(agent.name), list, since: pending?.made, building: building)
        connectedSize = agent.size.isEmpty ? pending?.size : agent.size
        work = Task {
            do {
                step("start", .active)
                if starts { try await client.start(agent.id) }
                let ready = agent.isReady ? agent : try await waitUntilReady(agent)
                step("start", .done)
                try await signIn(to: ready)
            } catch {
                handle(error)
            }
        }
    }

    func create() {
        guard phase == .home, canCreate else { return }
        let name = trimmedName
        connectedSize = values["size"]
        agentName = name
        begin(CloudCopy.settingUp(name), [Step(id: "create", title: CloudCopy.stepCreate), Step(id: "start", title: CloudCopy.stepBuild(name)),
                                         Step(id: "signin", title: CloudCopy.stepSignIn)], building: true)
        onRoute?(.root)
        // Remembered before it's sent: if the phone stops waiting, the next visit finds the agent by name and carries on.
        let pending = CloudPending(id: nil, name: name, size: values["size"], made: Date())
        pending.save()
        work = Task {
            do {
                AppLog.trace("cloud", "create \(name) \(values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
                step("create", .active, detail: CloudCopy.asking(region: values["region"].map(CloudCopy.regionWord)))
                var made: CloudAgent?
                do {
                    made = try await client.create(name: name, values: typedValues())
                } catch let error as PortalError where error.mayHaveRun {
                    // The answer didn't come back in time, but the create carries on at Portal: never send it again.
                    AppLog.trace("cloud", "create \(name) unanswered (\(error.message)); looking for it by name")
                }
                if made == nil { made = try await findCreated(name) }
                guard let made else { throw CloudToolError(message: "Nous Portal didn’t say which agent it made. Check Nous Portal, then try again.") }
                AppLog.trace("cloud", "made \(made.id) status=\(made.status) gateway=\(made.gatewayState) url=\(made.dashboardURL == nil ? "no" : "yes")")
                var known = pending
                known.id = made.id
                known.save()
                step("create", .done)
                step("start", .active)
                let ready = made.isReady ? made : try await waitUntilReady(made)
                step("start", .done)
                try await signIn(to: ready)
            } catch {
                handle(error)
            }
        }
    }

    /// Done: switch to the new gateway and close.
    func finish() {
        guard let connectedAccount else { return }
        onConnected?(connectedAccount)
    }

    func retry() {
        failure = ""
        Task { await login.isSignedIn ? load() : set(.start) }
    }

    // MARK: Steps

    /// Whether the agent is being built (minutes) rather than connected (seconds): what the page says to expect.
    private(set) var building = false

    private func begin(_ title: String, _ list: [Step], since: Date? = nil, building: Bool = false) {
        workTitle = title
        steps = list
        workStarted = since ?? Date()
        self.building = building
        slow = false
        failure = ""
        finishedAt = nil
        set(.working)
    }

    private func step(_ id: String, _ state: Step.State, detail: String? = nil) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[index].state = state
        steps[index].detail = state == .done ? nil : detail
        if state == .active { steps[index].started = Date() }
        if state == .done { steps[index].finished = Date(); Haptics.play(.light) }
        if id == "signin" { signalModal() }
    }

    private func detail(_ id: String, _ words: String) {
        guard let index = steps.firstIndex(where: { $0.id == id }), steps[index].detail != words else { return }
        steps[index].detail = words
    }

    /// The agent a create made, by name (names are unique here: `canCreate`); a few minutes for it to show up.
    private func findCreated(_ name: String) async throws -> CloudAgent? {
        let deadline = Date().addingTimeInterval(5 * 60)
        while true {
            do {
                if let found = try await client.listAgents().first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return found }
            } catch let error as PortalError where error.kind == .network {
                AppLog.trace("cloud", "list while finding \(name): \(error.message)")
            }
            guard Date() < deadline else { return nil }
            try await Task.sleep(for: .seconds(5))
        }
    }

    /// Polls until the agent answers. Nous took 17 minutes for a new Pro agent on 2026-10-30: up to 30 here, "taking
    /// longer than usual" after 20. Each change of Portal's status is logged and shown under the step.
    private func waitUntilReady(_ agent: CloudAgent) async throws -> CloudAgent {
        let deadline = Date().addingTimeInterval(30 * 60)
        var last: CloudAgent?
        detail("start", CloudCopy.live(agent))
        while Date() < deadline {
            try await Task.sleep(for: .seconds(building ? 5 : 3))
            if building, Date().timeIntervalSince(workStarted) > 20 * 60 { slow = true }
            guard let now = try await client.agent(agent.id) else { continue }
            if now.status != last?.status || now.gatewayState != last?.gatewayState || (now.dashboardURL == nil) != (last?.dashboardURL == nil) {
                AppLog.trace("cloud", "agent \(now.id) status=\(now.status) gateway=\(now.gatewayState) url=\(now.dashboardURL == nil ? "no" : "yes") sleeping=\(now.isSleeping) at \(Int(Date().timeIntervalSince(workStarted)))s")
            }
            last = now
            detail("start", CloudCopy.live(now))
            if now.isReady { return now }
            if now.isFailed { throw CloudToolError(message: "\(now.name) didn’t start on Nous’s side. Check it on Nous Portal.") }
        }
        AppLog.trace("cloud", "agent \(agent.id) still \(last?.status ?? "?")/\(last?.gatewayState ?? "?") after 30 min")
        throw CloudToolError(message: CloudCopy.stuck)
    }

    /// Sign in with Nous to the agent's own dashboard. Just after it comes up, the address can answer 502 for a few
    /// seconds: those tries happen before the browser opens, so they're repeated.
    private func signIn(to agent: CloudAgent) async throws {
        guard let url = agent.dashboardURL else { throw CloudToolError(message: CloudCopy.stuck) }
        step("signin", .active)
        var attempt = 0
        while true {
            do {
                try await driver.signInWithNous(address: url.absoluteString, label: agent.name)
                break
            } catch let error as SignInError where ["unreachable", "timeout", "gateway-error", "not-hermes", "unavailable"].contains(error.code) && attempt < 6 {
                attempt += 1
                AppLog.trace("cloud", "sign-in to \(url.host ?? "?") \(error.code), retry \(attempt)")
                try await Task.sleep(for: .seconds(5))
            }
        }
        guard let account = driver.signedIn else { throw CloudToolError(message: "The sign-in didn’t finish. Try again.") }
        step("signin", .done)
        AppLog.trace("cloud", "connected to \(url.host ?? "?")")
        connectedAgent = agent
        connectedAccount = account
        if CloudPending.load()?.matches(agent) == true { CloudPending.clear() }
        finishedAt = Date()
        Haptics.play(.success)
        set(.success)
    }

    func handle(_ error: any Error) {
        if let error = error as? SignInError, error.code == "nous-cancelled" { set(.home); return }
        // Closed while it built (`leave`): nothing to show, nothing to buzz.
        if error is CancellationError || Task.isCancelled { return }
        if let error = error as? PortalError, error.kind == .signedOut {
            agents = []
            signedIn = false
            failure = error.message
            set(.start)
            return
        }
        AppLog.trace("cloud", "failed: \(Self.words(error))")
        Haptics.play(.error)
        failure = Self.words(error)
        set(.failed)
    }

    private func typedValues() -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for field in fields {
            guard let raw = values[field.name], !raw.isEmpty else { continue }
            switch field.kind {
            case .number: if let number = Double(raw) { out[field.name] = .number(number) }
            case .toggle: out[field.name] = .bool(raw == "true")
            case .choice, .text: out[field.name] = .string(raw)
            }
        }
        return out
    }

    static func words(_ error: any Error) -> String {
        switch error {
        case let error as PortalError: return error.message.isEmpty ? "Nous Portal had a problem. Try again." : error.message
        case let error as CloudToolError: return error.message
        case let error as SignInError: return SignInCopy.message(for: error)
        case let error as GatewayFailure: return error.message
        default: return "Something went wrong. Try again."
        }
    }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.hqKeyWindow   // [mac] the Settings window when it's in front (Mac polish #36)
    }

    #if DEBUG
    /// Screenshots (`-HQDebugCloudShot start|home|first|compose|gathering|working|waking|success|failed`, and an agent's
    /// pages: `agent|agent-stopped|agent-busy|resize|variables|delete`; App/Debug/DebugHooks.swift):
    /// a state with made-up agents and fields, no Portal.
    /// When the debug success screen's sign-in finishes: 5 s before it opens, or `-HQDebugCloudDoneIn <seconds>` after
    /// (a video of the hop, blink and burst). Seconds, not a negative "ago": a launch argument's value may not start with "-".
    private var debugDoneAgo: TimeInterval {
        UserDefaults.standard.object(forKey: "HQDebugCloudDoneIn") == nil ? -5 : UserDefaults.standard.double(forKey: "HQDebugCloudDoneIn")
    }

    /// Tests: agents as if Portal had listed them, with nothing else shown.
    func debugSetAgents(_ list: [CloudAgent]) {
        agents = list
        phase = .home
    }

    /// Screenshots of the Gateway page's panel (`-HQDebugCloudHost YES`): made-up agents, the first at `host` (the
    /// gateway in use), the second at another saved one when there is one. `state`: "panel", "panel-stopped",
    /// "panel-busy", "panel-signin".
    func debugPanel(_ state: String, host: URL, other: URL?) {
        demo = true
        guard state != "panel-signin" else { phase = .start; return }
        let stopped = state == "panel-stopped"
        var mine = CloudAgent(id: "a1", name: "Hermes", status: stopped ? "stopped" : "running", dashboardURL: host,
                              gatewayState: stopped ? "down" : "active", size: "standard", region: "iad")
        mine.diskGB = 10; mine.version = "v0.22.5"; mine.envNames = ["OPENAI_API_KEY", "TZ"]; mine.memoryMB = 2048; mine.cpus = 2
        var theirs = CloudAgent(id: "a2", name: "Hermes Cloud", status: "running",
                                dashboardURL: other ?? URL(string: "https://hermes-cloud-1234.agents.nousresearch.com"),
                                gatewayState: "active", size: "pro", region: "iad")
        theirs.memoryMB = 4096; theirs.cpus = 4
        agents = [mine, theirs]
        spend = ["a1": CloudSpend(toDate: 0.21, monthly: 16.8), "a2": CloudSpend(toDate: 0.98, monthly: 32.7)]
        teamGateways = ["a1": CloudTeamGateway(enabled: false)]
        signedIn = true
        phase = .home
        if state == "panel-busy" { busy["a1"] = CloudBusy(action: .restart, words: "Starting Hermes…", started: Date().addingTimeInterval(-38)) }
    }

    func debugShow(_ state: String) {
        demo = true
        let host = URL(string: "https://research-bot-3f2a.agents.nousresearch.com")
        var research = CloudAgent(id: "a1", name: "Research Bot", status: "running", dashboardURL: host, gatewayState: "active", size: "pro", region: "iad")
        research.memoryMB = 4096; research.cpus = 4
        var night = CloudAgent(id: "a2", name: "Night Shift", status: "stopped", dashboardURL: nil, gatewayState: "down", size: "standard", region: "lhr")
        night.memoryMB = 2048; night.cpus = 2
        agents = state == "first" ? [] : [research, night]
        spend = ["a1": CloudSpend(toDate: 3.24, monthly: 32.7), "a2": CloudSpend(toDate: 0.41, monthly: 0.9)]
        fields = [CloudField(name: "size", title: "Size", detail: "", choices: ["standard", "pro", "max"],
                             choiceTitles: ["standard": "Standard · 2 GB", "pro": "Pro · 4 GB"], defaultValue: "standard", required: false, kind: .choice),
                  CloudField(name: "region", title: "Region", detail: "", choices: ["iad", "sjc", "lhr", "nrt", "syd", "gru"],
                             choiceTitles: CloudToolSchema.regionNames, defaultValue: "iad", required: false, kind: .choice)]
        values = ["size": "standard", "region": CloudRegions.closest(among: fields[1].choices) ?? "iad"]
        signedIn = state != "start"
        switch state {
        case "home": phase = .home
        case "first": phase = .home; name = "Research Bot"
        case "compose":
            phase = .home; name = "Inbox Helper"; values["size"] = UserDefaults.standard.bool(forKey: "HQDebugCloudMax") ? "max" : "pro"
            DispatchQueue.main.async { self.onRoute?(.compose) }
        case "working", "gathering", "waking":
            agentName = "Research Bot"; building = true
            workTitle = CloudCopy.settingUp("Research Bot"); workStarted = Date().addingTimeInterval(-252)
            let create = Step(id: "create", title: CloudCopy.stepCreate, state: state == "gathering" ? .active : .done,
                              started: Date().addingTimeInterval(state == "gathering" ? -20 : -252), finished: state == "gathering" ? nil : Date().addingTimeInterval(-229),
                              detail: state == "gathering" ? CloudCopy.asking(region: "Virginia, US") : nil)
            let start = Step(id: "start", title: CloudCopy.stepBuild("Research Bot"), state: state == "working" ? .active : state == "waking" ? .done : .waiting,
                             started: Date().addingTimeInterval(-229), finished: state == "waking" ? Date().addingTimeInterval(-2) : nil,
                             detail: state == "working" ? "Nous is getting a machine ready" : nil)
            let signin = Step(id: "signin", title: CloudCopy.stepSignIn, state: state == "waking" ? .active : .waiting,
                              started: state == "waking" ? Date().addingTimeInterval(-1) : nil)
            steps = [create, start, signin]
            if state == "gathering" { workStarted = Date().addingTimeInterval(-20) }
            phase = .working
        case "success":
            agentName = "Research Bot"; connectedAgent = agents.first; connectedSize = "pro"
            finishedAt = Date().addingTimeInterval(debugDoneAgo); phase = .success
        case "failed": phase = .failed; failure = CloudCopy.stuck
        case "agent", "agent-stopped", "agent-busy", "resize", "variables", "delete":
            phase = .home
            agents[0].diskGB = 10; agents[0].version = "v0.22.5"; agents[0].envNames = ["OPENAI_API_KEY", "TZ"]
            agents[1].diskGB = 10
            teamGateways = ["a1": CloudTeamGateway(enabled: false), "a2": CloudTeamGateway(enabled: false)]
            let id = state == "agent-stopped" ? "a2" : "a1"
            if state == "agent-busy" { busy["a1"] = CloudBusy(action: .restart, words: "Starting Hermes…", started: Date().addingTimeInterval(-38)) }
            DispatchQueue.main.async {
                self.onRoute?(.agent(id))
                switch state {
                case "resize": self.onRoute?(.resize(id))
                case "variables": self.onRoute?(.variables(id))
                case "delete": self.onRoute?(.delete(id))
                default: break
                }
            }
        default: phase = .start
        }
    }
    #endif
}

/// A Hermes Cloud agent this phone asked Nous for and hasn't signed in to yet: found again by id (or by name, when the
/// phone stopped waiting before Portal answered) the next time Hermes Cloud opens, so its progress carries on.
nonisolated struct CloudPending: Codable, Equatable, Sendable {
    var id: String?
    var name: String
    var size: String?
    var made: Date

    static let key = "hqn.cloud.pending"

    static func load(_ defaults: UserDefaults = .standard) -> CloudPending? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(CloudPending.self, from: $0) }
    }

    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }

    static func clear(_ defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }

    func matches(_ agent: CloudAgent) -> Bool {
        if let id { return agent.id == id }
        return agent.name.caseInsensitiveCompare(name) == .orderedSame
    }
}
