// A Nous-hosted gateway's controls on its own Settings › Gateway page: the agent with Stop/Start and Restart at the
// top, then its size, disk, variables, Team Gateway and Hermes version, and Delete near Sign Out. The owner 2026-10-31:
// "It still isn't a very intuitive experience trying to manage a nous gateway" (it lived in a separate sheet with
// its own list). The same model as Hermes Cloud… (CloudGatewayFlow.swift), wired to the Settings stack instead.

import SwiftUI
import UIKit

extension CloudGatewayFlow {
    /// A model for the Gateway page: its confirmations come up over Settings, and its pages (size, variables, delete,
    /// another agent's) are pushed onto the Settings stack.
    static func settingsModel(settings: any SettingsServices, services: any AppServices, router: SettingsRouter) -> CloudGatewayModel {
        let saved = Set(settings.gateways.accounts.map { $0.account.baseURL.host?.lowercased() ?? "" })
        let model = CloudGatewayModel(driver: settings.makeSignInDriver(), savedHosts: saved)
        model.gateways = settings.gateways
        model.onRoute = { [weak router, weak model] route in
            guard let router, let model, let navigation = router.navigation else { return }
            switch route {
            case .agent(let id):
                let page = page(CloudAgentPage(model: model, id: id, connectable: false), title: model.agent(id)?.name ?? CloudCopy.title)
                page.navigationItem.title = ""
                router.push(page)
            case .resize(let id): router.push(page(CloudResizePage(model: model, id: id), title: CloudCopy.changeSize))
            case .variables(let id): router.push(page(CloudVariablesPage(model: model, id: id), title: CloudCopy.variables))
            case .delete(let id): router.push(page(CloudDeletePage(model: model, id: id), title: CloudCopy.deleteTitle))
            case .back: navigation.popViewController(animated: true)
            case .root:
                // Back to the Gateway page (after a delete, or from an agent's page).
                if let gateway = navigation.viewControllers.last(where: { $0 is GatewayPageController }) {
                    navigation.popToViewController(gateway, animated: true)
                }
            case .compose: present(from: router.presenter, services: services)
            }
        }
        model.onRenamed = { [weak router] id, name in
            for controller in router?.navigation?.viewControllers ?? [] where (controller as? CloudAgentHost)?.agentId == id { controller.title = name }
        }
        model.onTitleShown = { [weak router] id, shown in
            for case let controller as CloudAgentHost in router?.navigation?.viewControllers ?? [] where controller.agentId == id {
                controller.navigationItem.title = shown ? controller.title : ""
            }
        }
        model.onConfirm = { [weak router] title, message, action, destructive, done in
            guard let host = FailureAlert.topmost(router?.presenter) else { return }
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            let confirm = UIAlertAction(title: action, style: destructive ? .destructive : .default) { _ in done() }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(confirm)
            if !destructive { alert.preferredAction = confirm }
            host.present(alert, animated: true)
        }
        model.onPrompt = { [weak router] title, message, text, action, limit, done in
            TextPrompt.present(title: title, message: message, text: text, placeholder: CloudCopy.namePlaceholder, action: action,
                               maxLength: limit, requireChange: true, identifier: "cloud-agent.rename-field", selectText: true,
                               autocapitalization: .words, autocorrection: .no, from: router?.presenter, done: done)
        }
        return model
    }
}

extension CloudCopy {
    static let panelTitle = "Hermes Cloud"
    static let panelSignInTitle = "Control this agent from HQ"
    static let panelSignInDetail = "Stop it, restart it, change its size and more, right here. Sign in to Nous Portal once to turn these on."
    static let panelSignIn = "Sign In to Nous Portal"
    static let panelChecking = "Checking Nous…"
    static let panelMissingTitle = "Not on this Nous account"
    static func panelMissingDetail(_ host: String) -> String {
        "Nous Portal has no agent at \(host) for the account you signed in with. It may have been deleted, or it belongs to another account."
    }
    static let panelOtherAccount = SignInCopy.otherNousAccount
    static let agentLabel = "Agent"
    static let model = "Model"
    static func deletesOn(_ when: String) -> String { "Nous plans to delete it (\(when))." }
    static let panelDeleteFoot = "Deletes it on Nous and stops the billing. This can’t be undone."
    static func dayPrice(_ size: CloudSize) -> String { "\(CloudPrices.dollars(size.perDay)) a day" }

    /// The gateway list's line for a Nous gateway: "Running · Standard · $0.56 a day".
    static func gatewayRowLine(_ agent: CloudAgent) -> String {
        var parts = [statusWord(agent)]
        if !agent.size.isEmpty { parts.append(sizeWord(agent.size)) }
        // [app-store-review] Guideline 3.1.1: no dollar amount on the gateway list row in the App Store build.
        #if !APP_STORE
        let up = agent.isReady || agent.isRunning || agent.isSleeping
        if let size = CloudPrices.size(agent.size) { parts.append(dayPrice(up ? size : CloudSize.stopped(from: size))) }
        #endif
        return parts.joined(separator: " · ")
    }
}

private extension CloudSize {
    /// What a stopped agent of this size costs a day.
    static func stopped(from size: CloudSize) -> CloudSize {
        var stopped = size
        stopped.perDay = size.stoppedPerDay
        return stopped
    }
}

/// A power button's words and symbol in its colour (inside a List row the symbol took the page tint), dimmed when off.
private struct CloudPowerLabel: View {
    let title: String
    let symbol: String
    let tint: Color
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Label(title, systemImage: symbol)
            .font(Font.hq(.body).weight(.semibold))
            .foregroundStyle(enabled ? tint : Color.hqLabel3)
            .frame(maxWidth: .infinity, minHeight: 34)
    }
}

/// The top of a Nous gateway's page: the agent, its power, and its settings. `host`: the gateway's address.
struct CloudGatewayPanel: View {
    @Bindable var model: CloudGatewayModel
    let host: URL

    var body: some View {
        if let agent = model.agent(atHost: host) {
            CloudPanelAgent(model: model, agent: agent)
        } else {
            Section {
                switch model.phase {
                case .start, .signingIn: signInRow
                case .loading: checkingRow
                default: missingRow
                }
            } header: { HQSectionLabel { Text(CloudCopy.panelTitle) } }
        }
    }

    private var signInRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                CloudTile(symbol: "cloud.fill")
                VStack(alignment: .leading, spacing: 3) {
                    Text(CloudCopy.panelSignInTitle).font(Font.hq(.headline)).foregroundStyle(Color.hqLabel)
                    Text(CloudCopy.panelSignInDetail)
                        .font(Font.hq(.subheadline))
                        .foregroundStyle(Color.hqLabel2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !model.failure.isEmpty {
                Text(model.failure).font(Font.hq(.footnote)).foregroundStyle(Color.hqRed).fixedSize(horizontal: false, vertical: true)
            }
            Button { model.signIn() } label: {
                HStack(spacing: 8) {
                    if model.phase == .signingIn { ProgressView().controlSize(.small) }
                    Text(CloudCopy.panelSignIn).font(Font.hq(.body).weight(.semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.hqTint)
            .disabled(model.phase == .signingIn)
            .accessibilityIdentifier("gateway.cloud.sign-in")
            NousOtherAccountLink(id: "gateway.cloud.other-account", action: model.useOtherAccount)
                .disabled(model.phase == .signingIn)
        }
        .padding(.vertical, 6)
    }

    private var checkingRow: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(CloudCopy.panelChecking).font(Font.hq(.body)).foregroundStyle(Color.hqLabel2)
        }
        .padding(.vertical, 4)
    }

    private var missingRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.failure.isEmpty ? CloudCopy.panelMissingTitle : model.failure)
                .font(Font.hq(.headline))
                .foregroundStyle(Color.hqLabel)
                .fixedSize(horizontal: false, vertical: true)
            if model.failure.isEmpty {
                Text(CloudCopy.panelMissingDetail(host.host ?? host.absoluteString))
                    .font(Font.hq(.subheadline))
                    .foregroundStyle(Color.hqLabel2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(CloudCopy.panelOtherAccount) { model.useOtherAccount() }
                .font(Font.hq(.body))
                .foregroundStyle(Color.hqTintText)
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}

/// The agent found: who it is and what it's doing, its power buttons, then its settings.
private struct CloudPanelAgent: View {
    @Bindable var model: CloudGatewayModel
    var agent: CloudAgent
    @ScaledMetric(relativeTo: .title) private var face: CGFloat = 56
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let busy = model.busy[agent.id]
        let up = agent.isReady || agent.isRunning || agent.isSleeping
        let size = CloudPrices.size(agent.size)
        Section {
            // At accessibility sizes the face goes above, so the words keep the width.
            let large = typeSize.isAccessibilitySize
            AnyLayout(large ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 14))) {
                HeadImage(head: Head.defaultHead(profile: agent.name), size: min(face, 84), working: busy != nil)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(agent.name).font(Font.hq(.title3).weight(.semibold)).foregroundStyle(Color.hqLabel)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        CloudStatusMark(color: CloudCopy.statusColor(agent), busy: busy != nil, diameter: 7)
                        Text(busy?.words ?? CloudCopy.statusLine(agent))
                            .font(Font.hq(.subheadline))
                            .foregroundStyle(busy != nil ? Color.hqTintText : Color.hqLabel2)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentTransition(.opacity)
                    }
                    if let busy {
                        TimelineView(.periodic(from: busy.started, by: 1)) { context in
                            Text("\(CloudCopy.elapsed(max(0, Int(context.date.timeIntervalSince(busy.started))))) so far")
                                .font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel3).monospacedDigit()
                        }
                    } else if let line = costLine(size, up: up) {
                        Text(line).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel3).monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("gateway.cloud.agent")
            .listRowSeparator(.hidden)      // one card: the agent, any warning, then its buttons

            if let note = warning {
                Text(note.text)
                    .font(Font.hq(.footnote))
                    .foregroundStyle(note.red ? Color.hqRed : Color.hqOrange)
                    .fixedSize(horizontal: false, vertical: true)
                    .listRowSeparator(.hidden)
            }

            // Power: the two things done most, as buttons side by side (one above the other at accessibility sizes).
            AnyLayout(large ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))) {
                if agent.isStopped, !agent.isSleeping {
                    powerButton(CloudCopy.startWord, "play.fill", Color.green, "gateway.cloud.start") { model.startOnly(agent) }
                        .disabled(!model.can(.start))
                } else {
                    powerButton(CloudCopy.stopWord, "stop.fill", Color.hqOrange, "gateway.cloud.stop") { model.askStop(agent) }
                        .disabled(!model.can(.stop) || agent.isFailed)
                }
                powerButton(CloudCopy.restartWord, "arrow.clockwise", Color.hqTint, "gateway.cloud.restart") { model.askRestart(agent) }
                    .disabled(!up || !model.can(.restart))
            }
            .disabled(busy != nil)
            .padding(.vertical, 4)
            .listRowSeparator(.hidden)
        } header: { HQSectionLabel { Text(CloudCopy.panelTitle) } } footer: {
            // What Stop saves or Start costs; nothing while a change is under way.
            if busy == nil {
                HQSectionFooter { Text(agent.isStopped && !agent.isSleeping ? CloudCopy.startDetail(size) : CloudCopy.stopDetail(size)) }
            }
        }

        Section {
            Button { model.askRename(agent) } label: {
                LabeledContent { Text(agent.name).foregroundStyle(Color.hqLabel2) } label: { Text(CloudCopy.name).foregroundStyle(Color.hqLabel) }
            }
            .disabled(!model.can(.rename))
            .accessibilityIdentifier("gateway.cloud.rename")
            NavRow(title: CloudCopy.size, value: sizeValue) { model.onRoute?(.resize(agent.id)) }
                .disabled(!model.can(.resize) || agent.canResize == false)
                .accessibilityIdentifier("gateway.cloud.size")
            disk
            NavRow(title: CloudCopy.variables, value: variablesValue) { model.onRoute?(.variables(agent.id)) }
                .disabled(!model.can(.updateEnv))
                .accessibilityIdentifier("gateway.cloud.variables")
            if model.can(.setFeature) { teamGateway }
            if model.can(.updateImage) {
                Button { model.askUpdate(agent) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(CloudCopy.updateWord).font(Font.hq(.body)).foregroundStyle(Color.hqTintText)
                        Text(CloudCopy.updateDetail(agent)).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityIdentifier("gateway.cloud.update")
            }
            if !agent.region.isEmpty {
                LabeledContent { Text(CloudCopy.regionWord(agent.region)).foregroundStyle(Color.hqLabel2) } label: {
                    Text(CloudCopy.region).foregroundStyle(Color.hqLabel)
                }
            }
            if !agent.version.isEmpty {
                LabeledContent { Text(agent.version).foregroundStyle(Color.hqLabel2) } label: { Text(CloudCopy.version).foregroundStyle(Color.hqLabel) }
            }
        } header: { HQSectionLabel { Text(CloudCopy.agentLabel) } }
        .disabled(busy != nil)
    }

    private func powerButton(_ title: String, _ symbol: String, _ tint: Color, _ id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            CloudPowerLabel(title: title, symbol: symbol, tint: tint)
        }
        .buttonStyle(.bordered)
        .tint(tint)
        .accessibilityIdentifier(id)
    }

    private func costLine(_ size: CloudSize?, up: Bool) -> String? {
        // [app-store-review] Guideline 3.1.1: no dollar amount under the agent's name in the App Store build.
        #if APP_STORE
        return nil
        #else
        var parts: [String] = []
        if let size { parts.append("\(CloudPrices.dollars(up ? size.perDay : size.stoppedPerDay)) a day") }
        if let spent = model.spend[agent.id]?.toDate { parts.append("\(CloudPrices.dollars(spent)) so far") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
        #endif
    }

    /// What went wrong, or what Nous says is coming: a failure in red, the rest in orange.
    private var warning: (text: String, red: Bool)? {
        if let failure = model.actionFailure[agent.id] { return (failure, true) }
        if agent.isFailed, !agent.lastError.isEmpty { return (agent.lastError, true) }
        if !agent.deletesAt.isEmpty { return (CloudCopy.deletesOn(agent.deletesAt), true) }
        if agent.gatewayState == "degraded" || agent.gatewayState == "down", !agent.healthDetail.isEmpty { return (agent.healthDetail, false) }
        return nil
    }

    private var sizeValue: String {
        guard !agent.size.isEmpty else { return "" }
        return CloudPrices.size(agent.size).map { "\(CloudCopy.sizeWord(agent.size)) · \($0.memory)" } ?? CloudCopy.sizeWord(agent.size)
    }

    private var variablesValue: String {
        let count = model.envNames(agent).count
        return count == 0 ? "" : "\(count)"
    }

    private var disk: some View {
        let offers = model.diskOffers(agent)
        return Menu {
            Section(CloudCopy.growDiskWord) {
                ForEach(offers, id: \.self) { gb in
                    Button("\(gb) GB") { model.askDisk(agent, gb) }
                }
            }
        } label: {
            LabeledContent {
                Text(agent.diskGB.map { "\($0) GB" } ?? CloudCopy.unknownDisk).foregroundStyle(Color.hqLabel2)
            } label: { Text(CloudCopy.disk).foregroundStyle(Color.hqLabel) }
        }
        .disabled(offers.isEmpty || !model.can(.growDisk) || agent.canGrowDisk == false)
        .accessibilityIdentifier("gateway.cloud.disk")
    }

    private var teamGateway: some View {
        let state = model.teamGateways[agent.id]
        let enabled = state?.enabled ?? agent.relay ?? false
        let on = Binding(get: { enabled }, set: { model.setTeamGateway(agent, on: $0) })
        let platforms = state?.platforms ?? []
        let note = !platforms.isEmpty ? CloudCopy.teamGatewayLinked(platforms) : enabled ? CloudCopy.teamGatewayLink : CloudCopy.teamGatewayDetail
        return Toggle(isOn: on) {
            VStack(alignment: .leading, spacing: 2) {
                Text(CloudCopy.teamGateway).font(Font.hq(.body)).foregroundStyle(Color.hqLabel)
                Text(note).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(Color.hqTint)
        .accessibilityIdentifier("gateway.cloud.team-gateway")
    }
}

/// Delete Agent, near the page's Sign Out (it isn't something done often, and it can't be undone).
struct CloudGatewayDeleteSection: View {
    @Bindable var model: CloudGatewayModel
    let host: URL

    var body: some View {
        if let agent = model.agent(atHost: host), model.can(.destroy) {
            Section {
                Button(CloudCopy.deleteTitle + "…", role: .destructive) { model.onRoute?(.delete(agent.id)) }
                    .disabled(model.busy[agent.id] != nil)
                    .accessibilityIdentifier("gateway.cloud.delete")
                    .hqMacFormButton(destructive: true)
            } footer: { HQSectionFooter { Text(CloudCopy.panelDeleteFoot) } }
        }
    }
}

extension CloudGatewayModel {
    /// The agent whose address is this gateway's.
    func agent(atHost url: URL) -> CloudAgent? {
        guard let host = url.host?.lowercased() else { return nil }
        // Nous addresses carry no port; a port only tells two apart when both name one.
        return agents.first {
            guard let dashboard = $0.dashboardURL, dashboard.host?.lowercased() == host else { return false }
            return dashboard.port == nil || url.port == nil || dashboard.port == url.port
        }
    }
}
