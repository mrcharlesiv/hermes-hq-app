// One Hermes Cloud agent's pages, pushed over Your Agents (CloudGatewayScreens.swift): the agent's own page (what it
// costs, power, settings, details, delete), Change Size, Variables and Delete Agent. What each control does, and the
// watching after it, is in CloudAgentControls.swift; confirmations are the system's alerts, asked for by the model.

import SwiftUI

extension CloudCopy {
    /// The dot beside an agent's status.
    static func statusColor(_ agent: CloudAgent) -> Color {
        if agent.isFailed { return Color.hqRed }
        if agent.isSleeping { return Color.hqTint }
        if agent.isReady { return Color.green }
        if agent.isStopped { return Color.hqLabel3 }
        return Color.hqOrange
    }

    /// "Running · Pro · Virginia, US".
    static func statusLine(_ agent: CloudAgent) -> String {
        var parts = [statusWord(agent)]
        if !agent.size.isEmpty { parts.append(sizeWord(agent.size)) }
        if !agent.region.isEmpty { parts.append(regionWord(agent.region)) }
        return parts.joined(separator: " · ")
    }
}

/// The same actions as the agent's page, for its row's ⋯ button and its context menu.
struct CloudAgentActions: View {
    var model: CloudGatewayModel
    var agent: CloudAgent

    var body: some View {
        let busy = model.busy[agent.id] != nil
        let up = agent.isReady || agent.isRunning || agent.isSleeping
        Group {
            if agent.isStopped, !agent.isSleeping, model.can(.start) {
                Button(CloudCopy.startWord, systemImage: "play.fill") { model.startOnly(agent) }
            } else if up, model.can(.stop) {
                Button(CloudCopy.stopWord + "…", systemImage: "stop.fill") { model.askStop(agent) }
            }
            if up, model.can(.restart) {
                Button(CloudCopy.restartWord + "…", systemImage: "arrow.clockwise") { model.askRestart(agent) }
            }
            Section {
                if model.can(.rename) { Button(CloudCopy.renameWord + "…", systemImage: "pencil") { model.askRename(agent) } }
                if model.can(.resize) { Button(CloudCopy.changeSize + "…", systemImage: "memorychip") { model.onRoute?(.resize(agent.id)) } }
                if model.can(.updateImage) { Button(CloudCopy.updateWord + "…", systemImage: "arrow.down.circle") { model.askUpdate(agent) } }
            }
            Section {
                Button(CloudCopy.details, systemImage: "info.circle") { model.open(agent) }
                if model.can(.destroy) {
                    Button(CloudCopy.deleteTitle + "…", systemImage: "trash", role: .destructive) { model.onRoute?(.delete(agent.id)) }
                }
            }
        }
        .disabled(busy)
    }
}

/// The ⋯ beside an agent's Connect button.
struct CloudAgentMenu: View {
    var model: CloudGatewayModel
    var agent: CloudAgent
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 30

    var body: some View {
        Menu {
            CloudAgentActions(model: model, agent: agent)
        } label: {
            Image(systemName: "ellipsis")
                .font(Font.hq(.body).weight(.semibold))
                .foregroundStyle(Color.hqLabel2)
                .frame(width: min(side, 44), height: min(side, 44))
                // [ui-sizing] A 44 pt touch around the drawn ⋯ (it was 30 pt at the default size).
                .contentShape(Rectangle().inset(by: -max(0, 44 - min(side, 44)) / 2))
        }
        .accessibilityLabel(CloudCopy.moreWord)
        .accessibilityIdentifier("cloud-agent-more-\(agent.name)")
    }
}

// MARK: - The agent's page

struct CloudAgentPage: View {
    @Bindable var model: CloudGatewayModel
    let id: String
    /// False when pushed from Settings › Gateways: a tap on the gateway's row switches to it there.
    var connectable = true

    var body: some View {
        ZStack {
            Color.hqGroupedPage.ignoresSafeArea()
            if let agent = model.agent(id) {
                CloudAgentDetail(model: model, agent: agent, connectable: connectable)
            }
        }
        .accessibilityIdentifier("cloud-agent-page")
    }
}

private struct CloudAgentDetail: View {
    @Bindable var model: CloudGatewayModel
    var agent: CloudAgent
    var connectable = true

    var body: some View {
        let busy = model.busy[agent.id]
        let up = agent.isReady || agent.isRunning || agent.isSleeping
        let size = CloudPrices.size(agent.size)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                CloudAgentHeader(agent: agent, busy: busy, failure: model.actionFailure[agent.id])
                    .padding(.bottom, 26)

                CloudLabel(text: CloudCopy.cost)
                CloudCostCard(agent: agent, spend: model.spend[agent.id], up: up)

                CloudLabel(text: CloudCopy.power).padding(.top, 22)
                VStack(spacing: 0) {
                    if agent.isStopped, !agent.isSleeping {
                        CloudActionRow(symbol: "play.fill", tint: Color.green, title: CloudCopy.startWord, detail: CloudCopy.startDetail(size),
                                       id: "cloud-agent.start") { model.startOnly(agent) }
                            .disabled(!model.can(.start))
                    } else {
                        CloudActionRow(symbol: "stop.fill", tint: Color.hqOrange, title: CloudCopy.stopWord, detail: CloudCopy.stopDetail(size),
                                       id: "cloud-agent.stop") { model.askStop(agent) }
                            .disabled(!model.can(.stop) || agent.isFailed)
                    }
                    if up, model.can(.restart) {
                        Divider().padding(.leading, 64)
                        CloudActionRow(symbol: "arrow.clockwise", tint: Color.hqTint, title: CloudCopy.restartWord, detail: CloudCopy.restartDetail,
                                       id: "cloud-agent.restart") { model.askRestart(agent) }
                    }
                    if model.can(.updateImage) {
                        Divider().padding(.leading, 64)
                        CloudActionRow(symbol: "arrow.down", tint: Color.hqTint, title: CloudCopy.updateWord, detail: CloudCopy.updateDetail(agent),
                                       id: "cloud-agent.update") { model.askUpdate(agent) }
                    }
                }
                .cloudCard()
                .disabled(busy != nil)

                CloudLabel(text: CloudCopy.settingsLabel).padding(.top, 22)
                VStack(spacing: 0) {
                    Button { model.askRename(agent) } label: {
                        CloudValueLabel(title: CloudCopy.name, value: agent.name)
                    }
                    .buttonStyle(CloudPressStyle())
                    .disabled(!model.can(.rename))
                    .accessibilityIdentifier("cloud-agent.rename")
                    Divider().padding(.leading, 16)
                    Button { model.onRoute?(.resize(agent.id)) } label: {
                        CloudValueLabel(title: CloudCopy.size, value: sizeValue, chevron: true)
                    }
                    .buttonStyle(CloudPressStyle())
                    .disabled(!model.can(.resize) || agent.canResize == false)
                    .accessibilityIdentifier("cloud-agent.size")
                    if let screen = CloudScreen.included(memoryMB: agent.memoryMB) {
                        Divider().padding(.leading, 16)
                        CloudValueLabel(title: CloudCopy.screen, value: CloudCopy.screenValue(screen))
                            .accessibilityIdentifier("cloud-agent.screen")
                    }
                    Divider().padding(.leading, 16)
                    disk
                    Divider().padding(.leading, 16)
                    Button { model.onRoute?(.variables(agent.id)) } label: {
                        let count = model.envNames(agent).count
                        CloudValueLabel(title: CloudCopy.variables, value: count == 0 ? "" : "\(count)", chevron: true)
                    }
                    .buttonStyle(CloudPressStyle())
                    .disabled(!model.can(.updateEnv))
                    .accessibilityIdentifier("cloud-agent.variables")
                    if model.can(.setFeature) {
                        Divider().padding(.leading, 16)
                        teamGateway
                    }
                }
                .cloudCard()
                .disabled(busy != nil)

                let rows = details
                if !rows.isEmpty {
                    CloudLabel(text: CloudCopy.detailsLabel).padding(.top, 22)
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            if index > 0 { Divider().padding(.leading, 16) }
                            CloudValueLabel(title: row.title, value: row.value, selectable: true)
                        }
                    }
                    .cloudCard()
                }

                if model.can(.destroy) {
                    Button { model.onRoute?(.delete(agent.id)) } label: {
                        Text(CloudCopy.deleteTitle)
                            .font(Font.hq(.body))
                            .foregroundStyle(Color.hqRed)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(CloudPressStyle())
                    .cloudCard()
                    .padding(.top, 28)
                    .disabled(busy != nil)
                    .accessibilityIdentifier("cloud-agent.delete")
                }

                Link(CloudCopy.manage, destination: Portal.agentsPage)
                    .font(Font.hq(.footnote).weight(.medium))
                    .foregroundStyle(Color.hqTintText)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
            }
            .frame(maxWidth: CloudLayout.wide)
            .padding(.horizontal, CloudLayout.gutter)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await model.refreshAgent(agent) }
        // The bar's title shows once the name under the face has scrolled away (it would say the same thing twice).
        .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 150 } action: { _, past in
            model.onTitleShown?(agent.id, past)
        }
        #if DEBUG
        .defaultScrollAnchor(UserDefaults.standard.bool(forKey: "HQDebugCloudBottom") ? .bottom : .top)
        #endif
        .hqCloudActionBar {
            if !agent.isFailed, connectable {
                CloudActionBar {
                    GuideActionButton(title: CloudCopy.connectTitle(agent, saved: model.isSaved(agent)), id: "cloud-agent.connect") {
                        model.connect(agent)
                    }
                    .disabled(busy != nil)
                }
            }
        }
        .animation(HQMotion.swiftUI(.smooth(duration: 0.3), fades: true), value: busy)
        .animation(HQMotion.swiftUI(.smooth(duration: 0.3), fades: true), value: agent)
    }

    private var sizeValue: String {
        guard !agent.size.isEmpty else { return "" }
        // The row's own memory first (Portal's MCP rows say it); the price table's for a row that doesn't.
        if let mb = agent.memoryMB, mb > 0 { return "\(CloudCopy.sizeWord(agent.size)) · \(mb / 1024) GB" }
        return CloudPrices.size(agent.size).map { "\(CloudCopy.sizeWord(agent.size)) · \($0.memory)" } ?? CloudCopy.sizeWord(agent.size)
    }

    /// Grow Disk: a menu of the sizes larger than the one it has.
    private var disk: some View {
        let offers = model.diskOffers(agent)
        return Menu {
            Section(CloudCopy.growDiskWord) {
                ForEach(offers, id: \.self) { gb in
                    Button("\(gb) GB") { model.askDisk(agent, gb) }
                }
            }
        } label: {
            CloudValueLabel(title: CloudCopy.disk, value: agent.diskGB.map { "\($0) GB" } ?? CloudCopy.unknownDisk, menu: true)
        }
        .disabled(offers.isEmpty || !model.can(.growDisk) || agent.canGrowDisk == false)
        .accessibilityIdentifier("cloud-agent.disk")
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
                Text(note)
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqLabel2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(Color.hqTint)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityIdentifier("cloud-agent.team-gateway")
    }

    private var details: [(title: String, value: String)] {
        var rows: [(title: String, value: String)] = []
        if let host = agent.dashboardURL?.host { rows.append((CloudCopy.address, host)) }
        if !agent.region.isEmpty { rows.append((CloudCopy.region, CloudCopy.regionWord(agent.region))) }
        if !agent.version.isEmpty { rows.append((CloudCopy.version, agent.version)) }
        if !agent.model.isEmpty { rows.append((CloudCopy.model, agent.model)) }
        return rows
    }
}

/// The face, the name, and what it's doing (or what Nous says while an action settles).
private struct CloudAgentHeader: View {
    var agent: CloudAgent
    var busy: CloudBusy?
    var failure: String?
    @ScaledMetric(relativeTo: .largeTitle) private var face: CGFloat = 84

    var body: some View {
        VStack(spacing: 0) {
            HeadImage(head: Head.defaultHead(profile: agent.name), size: min(face, 120), working: busy != nil)
                .padding(.bottom, 14)
                .accessibilityHidden(true)
            Text(agent.name)
                .font(Font.hq(.title2).weight(.bold))
                .foregroundStyle(Color.hqLabel)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                CloudStatusMark(color: CloudCopy.statusColor(agent), busy: busy != nil)
                Text(busy?.words ?? CloudCopy.statusLine(agent))
                    .font(Font.hq(.subheadline))
                    .foregroundStyle(busy != nil ? Color.hqTintText : Color.hqLabel2)
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
            }
            .padding(.top, 6)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("cloud-agent.status")
            if let busy {
                TimelineView(.periodic(from: busy.started, by: 1)) { context in
                    Text("\(CloudCopy.elapsed(max(0, Int(context.date.timeIntervalSince(busy.started))))) so far")
                        .font(Font.hq(.footnote))
                        .monospacedDigit()
                        .foregroundStyle(Color.hqLabel3)
                }
                .padding(.top, 4)
                .accessibilityHidden(true)
            }
            if let failure, busy == nil {
                Text(failure)
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqRed)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .accessibilityIdentifier("cloud-agent.failure")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }
}

/// What it costs a day now, what it has cost, and what a month would be.
private struct CloudCostCard: View {
    var agent: CloudAgent
    var spend: CloudSpend?
    var up: Bool

    var body: some View {
        // [app-store-review] Guideline 3.1.1: no dollar amount, running cost or spend total in the App Store build.
        // (Each branch repeats the trailing modifiers: chaining them after #endif breaks the ViewBuilder's inference.)
        #if APP_STORE
        VStack(alignment: .leading, spacing: 4) {
            Text(CloudCopy.costNote).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cloudCard()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("cloud-agent.cost")
        #else
        let size = CloudPrices.size(agent.size)
        VStack(alignment: .leading, spacing: 4) {
            if let size {
                // One run of text, so the words wrap under the price at large sizes instead of in a column beside it.
                let price = Text(CloudPrices.dollars(up ? size.perDay : size.stoppedPerDay))
                    .font(Font.hq(.title2).weight(.semibold))
                    .foregroundStyle(Color.hqLabel)
                    .monospacedDigit()
                Text("\(price) \(up ? "a day while it runs" : "a day while stopped")")
                    .font(Font.hq(.subheadline))
                    .foregroundStyle(Color.hqLabel2)
                if !up {
                    Text("\(CloudPrices.dollars(size.perDay)) a day once it’s started.").font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                }
            } else {
                Text(CloudCopy.costUnknown).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).fixedSize(horizontal: false, vertical: true)
            }
            if let line = CloudCopy.spendLine(spend) {
                Text(line).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel3).monospacedDigit()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cloudCard()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("cloud-agent.cost")
        #endif
    }
}

/// A power row: a tile, what it does, and what it costs or saves.
private struct CloudActionRow: View {
    var symbol: String
    var tint: Color
    var title: String
    var detail: String
    var id: String
    var action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                CloudTile(symbol: symbol, tint: tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Font.hq(.body)).foregroundStyle(Color.hqLabel)
                    Text(detail).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(CloudPressStyle())
        .accessibilityIdentifier(id)
    }
}

/// "Size        Pro · 4 GB ›": a settings row's title and value.
private struct CloudValueLabel: View {
    var title: String
    var value: String
    var chevron = false
    var menu = false
    var selectable = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // A long value (an address) or a big text size puts the value under its title.
        let stacked = typeSize.isAccessibilitySize || value.count > 24
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        HStack(spacing: 8) {
            layout {
                Text(title).font(Font.hq(.body)).foregroundStyle(Color.hqLabel)
                if !stacked { Spacer(minLength: 8) }
                if !value.isEmpty {
                    let text = Text(value).font(Font.hq(stacked && !typeSize.isAccessibilitySize ? .subheadline : .body)).foregroundStyle(Color.hqLabel2)
                        .lineLimit(stacked ? 2 : 1).truncationMode(.middle)
                    if selectable { text.textSelection(.enabled) } else { text }
                }
            }
            if stacked { Spacer(minLength: 0) }
            if chevron {
                Image(systemName: "chevron.right").font(Font.hq(.footnote).weight(.semibold)).foregroundStyle(Color.hqLabel3).accessibilityHidden(true)
            } else if menu {
                Image(systemName: "chevron.up.chevron.down").font(Font.hq(.footnote).weight(.semibold)).foregroundStyle(Color.hqLabel3).accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .frame(minHeight: 50)
        .padding(.vertical, stacked ? 8 : 0)
        .contentShape(Rectangle())
        .opacity(enabled ? 1 : 0.45)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Change Size

struct CloudResizePage: View {
    @Bindable var model: CloudGatewayModel
    let id: String
    @State private var choice: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ZStack {
            Color.hqGroupedPage.ignoresSafeArea()
            if let agent = model.agent(id) { content(agent) }
        }
        .accessibilityIdentifier("cloud-resize")
    }

    private func content(_ agent: CloudAgent) -> some View {
        let current = agent.size.lowercased()
        let chosen = choice ?? current
        var choices = model.sizeChoices.isEmpty ? CloudPrices.sizes.sorted { $0.value.perDay < $1.value.perDay }.map(\.key) : model.sizeChoices
        if !current.isEmpty, !choices.contains(current) { choices.insert(current, at: 0) }
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        let up = agent.isReady || agent.isRunning || agent.isSleeping
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(CloudCopy.resizeLead)
                    .font(Font.hq(.subheadline))
                    .foregroundStyle(Color.hqLabel2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                layout {
                    ForEach(choices.filter { $0 != CloudScreen.size(in: choices) }, id: \.self) { key in
                        CloudSizeCard(key: key, fallback: CloudToolSchema.title(key), selected: chosen == key, badge: key == current ? CloudCopy.now : nil) {
                            guard choice != key else { return }
                            Haptics.play(.selection)
                            choice = key
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                if let max = CloudScreen.size(in: choices) {
                    CloudScreenSizeCard(key: max, selected: chosen == max, badge: max == current ? CloudCopy.now : nil) {
                        guard choice != max else { return }
                        Haptics.play(.selection)
                        choice = max
                    }
                    .padding(.top, 12)
                }
                if chosen != current {
                    VStack(alignment: .leading, spacing: 6) {
                        // [app-store-review] Guideline 3.1.1: no dollar amount for the price difference in the App Store build.
                        #if !APP_STORE
                        if let change = CloudCopy.priceChange(from: CloudPrices.size(current), to: CloudPrices.size(chosen)) {
                            Label {
                                Text(change).font(Font.hq(.headline)).foregroundStyle(Color.hqLabel).fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "creditcard.fill").foregroundStyle(Color.hqTint)
                            }
                        }
                        #endif
                        Text(up ? "It restarts to change, which takes a minute or two." : "It takes the new size when it next starts.")
                            .font(Font.hq(.footnote))
                            .foregroundStyle(Color.hqLabel2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cloudCard()
                    .padding(.top, 18)
                    .transition(.hqMotion(.opacity))
                }
            }
            .frame(maxWidth: CloudLayout.wide)
            .padding(.horizontal, CloudLayout.gutter)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .hqCloudActionBar {
            CloudActionBar {
                GuideActionButton(title: chosen == current ? CloudCopy.changeSize : CloudCopy.changeTo(chosen), id: "cloud-resize.change") {
                    model.askResize(agent, to: chosen)
                }
                .disabled(chosen == current || model.busy[agent.id] != nil)
            }
        }
        .animation(HQMotion.swiftUI(.smooth(duration: 0.25), fades: true), value: chosen)
    }
}

// MARK: - Variables

struct CloudVariablesPage: View {
    @Bindable var model: CloudGatewayModel
    let id: String
    @State private var name = ""
    @State private var value = ""
    @FocusState private var focus: Field?

    private enum Field { case name, value }

    var body: some View {
        ZStack {
            Color.hqGroupedPage.ignoresSafeArea()
            if let agent = model.agent(id) { content(agent) }
        }
        .accessibilityIdentifier("cloud-variables")
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nameOK: Bool { CloudEnvNames.isValid(trimmedName) }

    private func content(_ agent: CloudAgent) -> some View {
        let names = model.envNames(agent)
        let busy = model.busy[agent.id]
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(CloudCopy.variablesLead)
                    .font(Font.hq(.subheadline))
                    .foregroundStyle(Color.hqLabel2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                if let busy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(busy.words).font(Font.hq(.subheadline)).foregroundStyle(Color.hqTintText)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                } else if let failure = model.actionFailure[agent.id] {
                    Text(failure)
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqRed)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)
                }
                CloudLabel(text: CloudCopy.variables)
                VStack(spacing: 0) {
                    if names.isEmpty {
                        Text(CloudCopy.variablesNone)
                            .font(Font.hq(.body))
                            .foregroundStyle(Color.hqLabel2)
                            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                            .padding(.horizontal, 16)
                    }
                    ForEach(Array(names.enumerated()), id: \.element) { index, key in
                        if index > 0 { Divider().padding(.leading, 16) }
                        HStack(spacing: 10) {
                            Text(key).font(Font.hq(.body).monospaced()).foregroundStyle(Color.hqLabel).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Button { model.askRemoveVariable(agent, name: key) } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(Font.hq(.title3))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(Color.white, Color.hqRed)
                                    .contentShape(Rectangle().inset(by: -10))   // [ui-sizing] a 44 pt touch (was ~22)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(key)")
                            .accessibilityIdentifier("cloud-variable-remove-\(key)")
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 50)
                    }
                }
                .cloudCard()
                .disabled(busy != nil)
                Text(CloudCopy.variablesFoot)
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqLabel2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                CloudLabel(text: CloudCopy.addVariable).padding(.top, 22)
                VStack(spacing: 0) {
                    TextField(CloudCopy.variableName, text: $name, prompt: Text(CloudCopy.variableNamePlaceholder))
                        .font(Font.hq(.body).monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focus, equals: .name)
                        .onSubmit { focus = .value }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 50)
                        .accessibilityIdentifier("cloud-variable-name")
                    Divider().padding(.leading, 16)
                    TextField(CloudCopy.variableValue, text: $value, prompt: Text(CloudCopy.variableValuePlaceholder))
                        .font(Font.hq(.body).monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()
                        .submitLabel(.done)
                        .focused($focus, equals: .value)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 50)
                        .accessibilityIdentifier("cloud-variable-value")
                }
                .cloudCard()
                if !trimmedName.isEmpty, !nameOK {
                    Text(CloudCopy.variableBadName)
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqRed)
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: CloudLayout.wide)
            .padding(.horizontal, CloudLayout.gutter)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .hqCloudActionBar {
            CloudActionBar {
                GuideActionButton(title: CloudCopy.setVariable, id: "cloud-variable.set") {
                    focus = nil
                    let key = trimmedName
                    model.askSetVariable(agent, name: key, value: value) {
                        name = ""
                        value = ""
                    }
                }
                .disabled(!nameOK || value.isEmpty || busy != nil)
            }
        }
    }
}

// MARK: - Delete

struct CloudDeletePage: View {
    @Bindable var model: CloudGatewayModel
    let id: String
    @State private var typed = ""
    @ScaledMetric(relativeTo: .title) private var badge: CGFloat = 76
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 34

    var body: some View {
        ZStack {
            Color.hqGroupedPage.ignoresSafeArea()
            if let agent = model.agent(id) { content(agent) }
        }
        .accessibilityIdentifier("cloud-delete")
    }

    private func content(_ agent: CloudAgent) -> some View {
        let busy = model.busy[agent.id]
        let saved = model.savedGateway(agent)
        let matches = typed.trimmingCharacters(in: .whitespacesAndNewlines) == agent.name
        return CloudCentered {
            ZStack {
                Circle().fill(Color.hqRed.opacity(0.12))
                Image(systemName: "trash.fill").font(.system(size: min(badge, 110) * 0.4, weight: .semibold)).foregroundStyle(Color.hqRed)
            }
            .frame(width: min(badge, 110), height: min(badge, 110))
            .accessibilityHidden(true)
            Text(CloudCopy.deleteHeading(agent.name))
                .font(Font.hq(.title2).weight(.bold))
                .foregroundStyle(Color.hqLabel)
                .multilineTextAlignment(.center)
                .padding(.top, 18)
                .accessibilityAddTraits(.isHeader)
            Text(CloudCopy.deleteLead)
                .font(Font.hq(.body))
                .foregroundStyle(Color.hqLabel2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            if let saved {
                Text(saved.isCurrent ? CloudCopy.deleteCurrent : CloudCopy.deleteAlsoGateway)
                    .font(Font.hq(.footnote))
                    .foregroundStyle(saved.isCurrent ? Color.hqOrange : Color.hqLabel2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
            TextField(CloudCopy.deleteType(agent.name), text: $typed, prompt: Text(CloudCopy.deleteType(agent.name)))
                .font(Font.hq(.body))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
                .cloudCard()
                .padding(.top, 24)
                .disabled(busy != nil)
                .accessibilityIdentifier("cloud-delete.name")
            if let busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busy.words).font(Font.hq(.subheadline)).foregroundStyle(Color.hqTintText)
                }
                .padding(.top, 14)
            } else if let failure = model.actionFailure[agent.id] {
                Text(failure)
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqRed)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
        } bar: {
            Button(role: .destructive) { model.destroy(agent) } label: {
                Text(CloudCopy.deleteTitle).font(Font.hq(.headline)).frame(maxWidth: .infinity, minHeight: height)
            }
            .controlSize(.large)
            .hqGlassProminentButtonStyle()
            .tint(Color.hqRed)
            .disabled(!matches || busy != nil)
            .accessibilityIdentifier("cloud-delete.confirm")
        }
    }
}
