// Hermes Cloud…'s screens (the flow and its model: CloudGatewayFlow.swift). One root that follows the
// model's phase (welcome, your agents or the first agent's form, progress, ready, failed) and the New Agent page pushed
// over it. Cards are iOS's grouped cards with Desktop Look off and its 4 pt outlined boxes with it on; the face is a
// dot-matrix head like a new bot's, working while the agent comes up.

import SwiftUI

struct CloudGatewayView: View {
    @Bindable var model: CloudGatewayModel

    var body: some View {
        ZStack {
            Color.hqGroupedPage.ignoresSafeArea()
            switch model.phase {
            case .start, .signingIn: CloudWelcomeView(model: model)
            case .loading:
                CloudCentered {
                    CloudHero(working: true, size: 72)
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(CloudCopy.loading).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                    }
                }
            case .home:
                if model.agents.isEmpty { CloudComposeView(model: model, first: true) } else { CloudHomeView(model: model) }
            case .working: CloudProgressView(model: model)
            case .success: CloudReadyView(model: model)
            case .failed: CloudFailedView(model: model)
            }
        }
        .animation(HQMotion.swiftUI(.smooth(duration: 0.3), fades: true), value: model.phase)
        .onAppear { model.appear() }
        .accessibilityIdentifier("cloud-gateway")
    }
}

// MARK: - Welcome

private struct CloudWelcomeView: View {
    @Bindable var model: CloudGatewayModel

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                CloudHero(size: 84)
                Text(CloudCopy.heading)
                    .font(Font.hq(.largeTitle).weight(.bold))
                    .foregroundStyle(Color.hqLabel)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(CloudCopy.lead)
                    .font(Font.hq(.body))
                    .foregroundStyle(Color.hqLabel2)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(CloudCopy.points.enumerated()), id: \.offset) { index, point in
                        if index > 0 { Divider().padding(.leading, 64) }
                        HStack(alignment: .top, spacing: 14) {
                            CloudTile(symbol: point.symbol)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(point.title).font(Font.hq(.headline)).foregroundStyle(Color.hqLabel)
                                Text(point.text).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .accessibilityElement(children: .combine)
                    }
                }
                .cloudCard()
                .padding(.top, 28)
            }
            .frame(maxWidth: CloudLayout.narrow)
            .padding(.horizontal, CloudLayout.gutter)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .hqCloudActionBar {
            CloudActionBar {
                GuideActionButton(title: CloudCopy.signIn, id: "cloud-gateway.sign-in", action: model.signIn)
                    .disabled(model.phase == .signingIn)
                Text(model.failure.isEmpty ? CloudCopy.signInNote : model.failure)
                    .font(Font.hq(.footnote))
                    .foregroundStyle(model.failure.isEmpty ? Color.hqLabel2 : Color.hqRed)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("cloud-gateway.note")
                NousOtherAccountLink(id: "cloud-gateway.other-account", action: model.useOtherAccount)
                    .disabled(model.phase == .signingIn)
            }
        }
    }
}

// MARK: - Your agents

private struct CloudHomeView: View {
    @Bindable var model: CloudGatewayModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                CloudLabel(text: CloudCopy.yourAgents)
                VStack(spacing: 0) {
                    ForEach(Array(model.agents.enumerated()), id: \.element.id) { index, agent in
                        if index > 0 { Divider().padding(.leading, 68) }
                        CloudAgentRow(model: model, agent: agent)
                    }
                }
                .cloudCard()
                Button(action: model.compose) {
                    HStack(spacing: 14) {
                        CloudTile(symbol: "plus")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(CloudCopy.newAgent).font(Font.hq(.headline)).foregroundStyle(Color.hqLabel)
                            Text(CloudCopy.newAgentDetail).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        SettingsChevron()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(CloudPressStyle())
                .cloudCard()
                .padding(.top, 16)
                .accessibilityIdentifier("cloud-gateway.new-agent")
                Text(CloudCopy.homeFoot)
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqLabel2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
            .frame(maxWidth: CloudLayout.wide)
            .padding(.horizontal, CloudLayout.gutter)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await model.refresh() }
    }
}

/// An agent's status dot, or a spinner while an action runs, its middle at the middle of the status line's x-height: it
/// stays beside the first line when the words wrap at large text sizes.
struct CloudStatusMark: View {
    var color: Color
    var busy = false
    var diameter: CGFloat = 8
    @ScaledMetric(relativeTo: .subheadline) private var scale: CGFloat = 1

    var body: some View {
        Group {
            if busy {
                ProgressView().controlSize(diameter < 8 ? .mini : .small)
            } else {
                Circle().fill(color).frame(width: min(diameter * scale, 14), height: min(diameter * scale, 14))
            }
        }
        .alignmentGuide(.firstTextBaseline) { $0.height / 2 + (HQFont.preferred(.subheadline).xHeight / 2).rounded() }
        .accessibilityHidden(true)
    }
}

private struct CloudAgentRow: View {
    @Bindable var model: CloudGatewayModel
    var agent: CloudAgent
    @ScaledMetric(relativeTo: .body) private var face: CGFloat = 40
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // At the accessibility sizes the buttons go under the words (beside them it broke into "Con-nect").
        let stacked = typeSize.isAccessibilitySize
        let side = min(face, 56)
        let busy = model.busy[agent.id]
        let saved = model.isSaved(agent)
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        layout {
            // Tapping the face or the words opens the agent's page (stop, rename, resize, delete …).
            Button { model.open(agent) } label: {
                HStack(spacing: 12) {
                    HeadImage(head: Head.defaultHead(profile: agent.name), size: side, working: busy != nil)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(agent.name).font(Font.hq(.headline)).foregroundStyle(Color.hqLabel).lineLimit(2)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            CloudStatusMark(color: CloudCopy.statusColor(agent), busy: busy != nil, diameter: 7)
                            Text(busy?.words ?? details)
                                .font(Font.hq(.subheadline))
                                .foregroundStyle(busy != nil ? Color.hqTintText : Color.hqLabel2)
                                .lineLimit(stacked ? 2 : 1)
                        }
                        if !place.isEmpty {
                            // Where and what it cost on one line; the cost alone when both don't fit (the page has both).
                            if stacked {
                                Text(place).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel3).monospacedDigit().lineLimit(3)
                            } else {
                                ViewThatFits(in: .horizontal) {
                                    placeText(place)
                                    if let spent { placeText(spent) }
                                }
                            }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(CloudPressStyle())
            .accessibilityElement(children: .combine)
            .accessibilityHint(CloudCopy.details)
            .accessibilityIdentifier("cloud-agent-row-\(agent.name)")
            HStack(spacing: 6) {
                if !agent.isFailed {
                    // Tapping signs in (starting a stopped agent first); one already on this phone signs in again and opens.
                    Button { model.connect(agent) } label: {
                        Text(saved ? CloudCopy.open : agent.isStopped && !agent.isSleeping ? CloudCopy.start : CloudCopy.connect)
                    }
                    .hqRowActionButtonStyle(prominent: !saved)
                    .disabled(busy != nil)
                    .accessibilityIdentifier("cloud-agent-\(agent.name)")
                }
                CloudAgentMenu(model: model, agent: agent)
            }
            .padding(.leading, stacked ? side + 12 : 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 13)
        .contextMenu { CloudAgentActions(model: model, agent: agent) }
    }

    /// "Running · Pro": short enough to stay on one line beside the buttons.
    private var details: String {
        var parts = [CloudCopy.statusWord(agent)]
        if !agent.size.isEmpty { parts.append(CloudCopy.sizeWord(agent.size)) }
        return parts.joined(separator: " · ")
    }

    /// "Virginia, US · $3.24 so far": where it runs and what it has cost (or would cost a month, before any spend).
    private var place: String {
        var parts: [String] = []
        if !agent.region.isEmpty { parts.append(CloudCopy.regionWord(agent.region)) }
        if let spent { parts.append(spent) }
        return parts.joined(separator: " · ")
    }

    private var spent: String? {
        // [app-store-review] Guideline 3.1.1: no dollar amount on the agent row in the App Store build.
        #if APP_STORE
        return nil
        #else
        if let spent = model.spend[agent.id]?.toDate { return "\(CloudPrices.dollars(spent)) so far" }
        if let month = model.spend[agent.id]?.monthly { return "about \(CloudPrices.dollars(month)) a month" }
        return nil
        #endif
    }

    private func placeText(_ text: String) -> some View {
        Text(text).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel3).monospacedDigit().lineLimit(1)
    }
}

// MARK: - New agent

struct CloudComposeView: View {
    @Bindable var model: CloudGatewayModel
    /// No agents yet: the form is the page itself, under a heading.
    var first: Bool
    @State private var confirming = false
    @FocusState private var nameFocused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if first {
                    VStack(spacing: 0) {
                        CloudHero(size: 64)
                        Text(CloudCopy.firstHeading)
                            .font(Font.hq(.title2).weight(.bold))
                            .foregroundStyle(Color.hqLabel)
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)
                        Text(CloudCopy.firstLead)
                            .font(Font.hq(.subheadline))
                            .foregroundStyle(Color.hqLabel2)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 6)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 24)
                }
                CloudLabel(text: CloudCopy.name)
                TextField(CloudCopy.name, text: $model.name, prompt: Text(CloudCopy.namePlaceholder))
                    .font(Font.hq(.title3))
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($nameFocused)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 54)
                    .cloudCard()
                    .accessibilityIdentifier("cloud-gateway.name")
                if model.nameTaken {
                    Text(CloudCopy.nameTaken)
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqRed)
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                }
                if let field = model.sizeField {
                    CloudLabel(text: CloudCopy.size).padding(.top, 14)
                    sizes(field)
                }
                if let field = model.regionField {
                    CloudLabel(text: CloudCopy.region).padding(.top, 14)
                    region(field)
                }
                ForEach(model.otherFields) { field in
                    CloudLabel(text: field.title).padding(.top, 14)
                    CloudFieldRow(field: field, value: Binding(get: { model.values[field.name] ?? "" }, set: { model.values[field.name] = $0 }))
                }
                cost.padding(.top, 22)
            }
            .frame(maxWidth: CloudLayout.wide)
            .padding(.horizontal, CloudLayout.gutter)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .hqCloudActionBar {
            CloudActionBar {
                GuideActionButton(title: CloudCopy.create, id: "cloud-gateway.create") {
                    nameFocused = false
                    confirming = true
                }
                .keyboardShortcut(.return, modifiers: .command)   // ⌘Return, as Save in New Job (asks first, as a click does)
                .disabled(!model.canCreate)
            }
        }
        .background(Color.hqGroupedPage.ignoresSafeArea())
        .alert(CloudCopy.confirmTitle(model.trimmedName), isPresented: $confirming) {
            Button("Create") { model.create() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(CloudCopy.confirmMessage(size: model.values["size"].map(CloudCopy.sizeWord) ?? "",
                                          region: model.values["region"].map(CloudCopy.regionWord), price: model.chosenSize))
        }
    }

    private func sizes(_ field: CloudField) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        return VStack(alignment: .leading, spacing: 12) {
            layout {
                ForEach(field.choices.filter { $0 != CloudScreen.size(in: field.choices) }, id: \.self) { key in
                    CloudSizeCard(key: key, fallback: field.title(of: key), selected: model.values[field.name] == key) {
                        guard model.values[field.name] != key else { return }
                        Haptics.play(.selection)
                        model.values[field.name] = key
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            if let max = CloudScreen.size(in: field.choices) {
                CloudScreenSizeCard(key: max, selected: model.values[field.name] == max) {
                    guard model.values[field.name] != max else { return }
                    Haptics.play(.selection)
                    model.values[field.name] = max
                }
            }
        }
    }

    private func region(_ field: CloudField) -> some View {
        let chosen = model.values[field.name] ?? ""
        return Menu {
            ForEach(field.choices, id: \.self) { key in
                Button { model.values[field.name] = key } label: {
                    if key == chosen { Label(field.title(of: key), systemImage: "checkmark") } else { Text(field.title(of: key)) }
                    if key == model.closestRegion { Text(CloudCopy.closest) }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(chosen.isEmpty ? "" : field.title(of: chosen)).font(Font.hq(.body)).foregroundStyle(Color.hqLabel)
                Spacer(minLength: 8)
                if !chosen.isEmpty, chosen == model.closestRegion {
                    Text(CloudCopy.closest).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel3)
                }
                Image(systemName: "chevron.up.chevron.down").font(Font.hq(.footnote).weight(.semibold)).foregroundStyle(Color.hqLabel3)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
            .cloudCard()
        }
        .accessibilityLabel(CloudCopy.region)
        .accessibilityValue(chosen.isEmpty ? "" : field.title(of: chosen))
        .accessibilityIdentifier("cloud-field-region")
    }

    private var cost: some View {
        VStack(alignment: .leading, spacing: 6) {
            // [app-store-review] Guideline 3.1.1: no dollar amount for the chosen size in the App Store build.
            #if APP_STORE
            Label {
                Text(CloudCopy.costNote).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "creditcard.fill").foregroundStyle(Color.hqTint)
            }
            #else
            if let size = model.chosenSize {
                Label {
                    Text(CloudCopy.perDay(size)).font(Font.hq(.headline)).foregroundStyle(Color.hqLabel)
                } icon: {
                    Image(systemName: "creditcard.fill").foregroundStyle(Color.hqTint)
                }
                Text(CloudCopy.costDetail(size))
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqLabel2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(CloudCopy.costUnknown).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2).fixedSize(horizontal: false, vertical: true)
            }
            #endif
            // [app-store-review] Guideline 3.1.1: no link to Nous Portal's priced "create an agent" page.
            #if !APP_STORE
            Link(CloudCopy.prices, destination: Portal.newAgentPage)
                .font(Font.hq(.footnote).weight(.medium))
                .foregroundStyle(Color.hqTintText)
                .padding(.top, 2)
            #endif
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cloudCard()
        .accessibilityIdentifier("cloud-gateway.cost")
    }
}

struct CloudSizeCard: View {
    var key: String
    /// The schema's words for a size the price table doesn't know ("Max · 8 GB").
    var fallback: String
    var selected: Bool
    /// "Now": the size an agent has, on Change Size.
    var badge: String? = nil
    var choose: () -> Void

    var body: some View {
        let info = CloudPrices.size(key)
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(CloudCopy.sizeWord(key)).font(Font.hq(.headline)).foregroundStyle(Color.hqLabel)
                    if let badge {
                        Text(badge)
                            .font(Font.hq(.caption).weight(.semibold))
                            .foregroundStyle(Color.hqTintText)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.hqTint.opacity(0.14), in: Capsule())
                    }
                    Spacer(minLength: 4)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(Font.hq(.body))
                        .foregroundStyle(selected ? Color.hqTint : Color.hqLabel3)
                        .contentTransition(.symbolEffect(.replace))
                }
                if let info {
                    Text(CloudCopy.specs(info)).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                    Text(CloudCopy.chats(info)).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel3)
                } else {
                    Text(fallback).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                }
                Spacer(minLength: 12)
                // [app-store-review] Guideline 3.1.1: no per-size dollar amount on the size picker in the App Store build.
                #if !APP_STORE
                if let info {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(CloudPrices.dollars(info.perDay)).font(Font.hq(.title2).weight(.semibold)).foregroundStyle(Color.hqLabel).monospacedDigit()
                        Text("a day").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                    }
                }
                #endif
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(CloudPressStyle())
        .cloudCard(selected: selected)
        .animation(HQMotion.swiftUI(.smooth(duration: 0.2)), value: selected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("cloud-size-\(key)")
    }
}

/// Under Standard and Pro, full width: Max, the 8 GB size and the only one Hermes Cloud gives Screen (CloudScreen),
/// picked like any other size.
struct CloudScreenSizeCard: View {
    var key: String
    var selected: Bool
    /// "Now": the size an agent has, on Change Size.
    var badge: String? = nil
    var choose: () -> Void

    var body: some View {
        Button(action: choose) { content }
            .buttonStyle(CloudPressStyle())
            .cloudCard(selected: selected)
            .animation(HQMotion.swiftUI(.smooth(duration: 0.2)), value: selected)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("cloud-size-\(key)")
    }

    private var content: some View {
        let info = CloudPrices.size(key)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(CloudCopy.sizeWord(key)).font(Font.hq(.headline)).foregroundStyle(Color.hqLabel)
                pill(CloudCopy.includesScreen, symbol: "display")
                if let badge { pill(badge, symbol: nil) }
                Spacer(minLength: 4)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(Font.hq(.body))
                    .foregroundStyle(selected ? Color.hqTint : Color.hqLabel3)
                    .contentTransition(.symbolEffect(.replace))
            }
            if let info {
                Text("\(CloudCopy.specs(info)) · \(CloudCopy.bigDisk)").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                Text(CloudCopy.chats(info)).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel3)
            }
            Text(CloudCopy.screenWhat).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            // [app-store-review] Guideline 3.1.1: no per-size dollar amount on the size picker in the App Store build.
            #if !APP_STORE
            if let info {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(CloudPrices.dollars(info.perDay)).font(Font.hq(.title2).weight(.semibold)).foregroundStyle(Color.hqLabel).monospacedDigit()
                    Text("a day").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                }
                .padding(.top, 10)
            }
            #endif
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
    }

    private func pill(_ text: String, symbol: String?) -> some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(Font.hq(.caption).weight(.semibold))
        .foregroundStyle(Color.hqTintText)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Color.hqTint.opacity(0.14), in: Capsule())
    }
}

/// A field the schema adds that the form has no special place for.
private struct CloudFieldRow: View {
    var field: CloudField
    @Binding var value: String

    var body: some View {
        Group {
            switch field.kind {
            case .choice:
                Picker(field.title, selection: $value) {
                    ForEach(field.choices, id: \.self) { Text(field.title(of: $0)).tag($0) }
                }
                .hqMenuPicker()
            case .toggle:
                Toggle(field.title, isOn: Binding(get: { value == "true" }, set: { value = $0 ? "true" : "false" }))
            case .number:
                TextField(field.title, text: $value, prompt: Text(field.required ? field.title : "\(field.title) (optional)")).keyboardType(.numberPad)
            case .text:
                TextField(field.title, text: $value, prompt: Text(field.required ? field.title : "\(field.title) (optional)"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
        .font(Font.hq(.body))
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .cloudCard()
        .accessibilityIdentifier("cloud-field-\(field.name)")
    }
}

// MARK: - Progress, ready, failed

private struct CloudProgressView: View {
    @Bindable var model: CloudGatewayModel
    @ScaledMetric(relativeTo: .largeTitle) private var face: CGFloat = 132

    var body: some View {
        let side = min(face, 180)
        let signing = model.steps.contains { $0.id == "signin" && $0.state == .active }
        CloudCentered {
            // The picture leaves room round the face for the loose LEDs; the words tuck up into it.
            CloudForge(seed: model.agentName, stage: model.forgeStage, side: side)
                .padding(.vertical, -side * (CloudForge.room - 1) / 2 + 6)
            Text(model.workTitle)
                .font(Font.hq(.title2).weight(.bold))
                .foregroundStyle(Color.hqLabel)
                .multilineTextAlignment(.center)
                .padding(.top, 14)
                .accessibilityAddTraits(.isHeader)
            Text(model.slow ? CloudCopy.slow : model.building ? CloudCopy.usuallyTakes : CloudCopy.connectTakes)
                .font(Font.hq(.subheadline))
                .foregroundStyle(Color.hqLabel2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .accessibilityIdentifier("cloud-gateway.status")
            VStack(spacing: 0) {
                ForEach(Array(model.steps.enumerated()), id: \.element.id) { index, step in
                    if index > 0 { Divider().padding(.leading, 54) }
                    CloudStepRow(step: step)
                }
            }
            .cloudCard()
            .padding(.top, 22)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("\(CloudCopy.elapsed(max(0, Int(context.date.timeIntervalSince(model.workStarted))))) so far")
                    .font(Font.hq(.footnote))
                    .monospacedDigit()
                    .foregroundStyle(Color.hqLabel3)
            }
            .padding(.top, 10)
            .accessibilityHidden(true)
            if model.building {
                CloudTips(started: model.workStarted).padding(.top, 18)
                if !signing {
                    Text(CloudCopy.leaveNote)
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqLabel2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 14)
                        .padding(.horizontal, 8)
                }
            }
        }
    }
}

private struct CloudStepRow: View {
    var step: CloudGatewayModel.Step

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            ZStack {
                switch step.state {
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green).transition(.hqMotion(.scale.combined(with: .opacity)))
                case .active:
                    ProgressView().controlSize(.small)
                case .waiting:
                    Image(systemName: "circle").foregroundStyle(Color.hqLabel3)
                }
            }
            .font(Font.hq(.title3))
            // [ui-sizing 2026-11-09] As big as the glyph it holds: a fixed 24 pt box let the title3 glyph spill into the
            // step's title at 150 % or a larger text size.
            .frame(width: max(24, HQFont.preferred(.title3).lineHeight), height: max(24, HQFont.preferred(.title3).lineHeight))
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(Font.hq(.body))
                    .foregroundStyle(step.state == .waiting ? Color.hqLabel3 : Color.hqLabel)
                if let detail = step.detail, step.state == .active {
                    Text(detail)
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqTintText)
                        .contentTransition(.opacity)
                        .accessibilityIdentifier("cloud-step-detail")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if step.state == .done, let started = step.started, let finished = step.finished {
                Text(CloudCopy.elapsed(max(0, Int(finished.timeIntervalSince(started)))))
                    .font(Font.hq(.footnote))
                    .monospacedDigit()
                    .foregroundStyle(Color.hqLabel3)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .animation(HQMotion.swiftUI(.smooth(duration: 0.3)), value: step.state)
        .animation(HQMotion.swiftUI(.smooth(duration: 0.3), fades: true), value: step.detail)
        .accessibilityElement(children: .combine)
        .accessibilityValue(step.state == .done ? "Done" : step.state == .active ? "In progress" : "Waiting")
    }
}

/// Something to read while Nous builds: a tip every seven seconds.
private struct CloudTips: View {
    var started: Date

    var body: some View {
        TimelineView(.periodic(from: started, by: 7)) { context in
            let tips = CloudCopy.tips
            let index = max(0, Int(context.date.timeIntervalSince(started) / 7)) % tips.count
            let tip = tips[index]
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(CloudCopy.whileYouWait).font(Font.hq(.footnote).weight(.semibold)).foregroundStyle(Color.hqLabel2)
                    Spacer()
                    HStack(spacing: 5) {
                        ForEach(tips.indices, id: \.self) { dot in
                            Circle().fill(dot == index ? Color.hqTint : Color.hqLabel3.opacity(0.4)).frame(width: 6, height: 6)
                        }
                    }
                    .accessibilityHidden(true)
                }
                HStack(alignment: .top, spacing: 14) {
                    CloudTile(symbol: tip.symbol)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tip.title).font(Font.hq(.headline)).foregroundStyle(Color.hqLabel)
                        Text(tip.text).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .id(index)
                .transition(.hqMotion(.asymmetric(insertion: .opacity.combined(with: .offset(x: 18)), removal: .opacity.combined(with: .offset(x: -18)))))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cloudCard()
            .animation(HQMotion.swiftUI(.smooth(duration: 0.45), fades: true), value: index)
            .accessibilityElement(children: .combine)
        }
    }
}

private struct CloudReadyView: View {
    @Bindable var model: CloudGatewayModel

    var body: some View {
        let agent = model.connectedAgent
        let name = agent?.name ?? CloudCopy.title
        CloudCentered {
            ReadyFace(model: model)
            Text(CloudCopy.ready(name))
                .font(Font.hq(.title2).weight(.bold))
                .foregroundStyle(Color.hqLabel)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(CloudCopy.readyLead)
                .font(Font.hq(.subheadline))
                .foregroundStyle(Color.hqLabel2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            VStack(spacing: 0) {
                let rows = details(agent)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider().padding(.leading, 16) }
                    // A long value (the agent's address) goes under its title instead of breaking beside it.
                    let layout = row.value.count > 22 ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                        : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
                    layout {
                        Text(row.title).font(Font.hq(.body)).foregroundStyle(Color.hqLabel)
                        if row.value.count <= 22 { Spacer(minLength: 8) }
                        Text(row.value).font(Font.hq(row.value.count > 22 ? .subheadline : .body)).foregroundStyle(Color.hqLabel2)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .accessibilityElement(children: .combine)
                }
            }
            .cloudCard()
            .padding(.top, 26)
        } bar: {
            GuideActionButton(title: CloudCopy.openAgent(name), id: "cloud-gateway.open", action: model.finish)
        }
    }

    private func details(_ agent: CloudAgent?) -> [(title: String, value: String)] {
        var rows: [(title: String, value: String)] = []
        if let host = agent?.dashboardURL?.host { rows.append((CloudCopy.address, host)) }
        if let size = model.connectedSize { rows.append((CloudCopy.size, CloudPrices.size(size).map { "\(CloudCopy.sizeWord(size)) · \($0.memory)" } ?? CloudCopy.sizeWord(size))) }
        if let region = agent?.region, !region.isEmpty { rows.append((CloudCopy.region, CloudCopy.regionWord(region))) }
        // [app-store-review] Guideline 3.1.1: no dollar amount on the Ready screen in the App Store build.
        #if !APP_STORE
        if let price = CloudPrices.size(model.connectedSize) { rows.append((CloudCopy.cost, "\(CloudPrices.dollars(price.perDay)) a day")) }
        #endif
        return rows
    }
}

/// The agent's finished face: eyes open, a blink and a burst as the page appears.
private struct ReadyFace: View {
    var model: CloudGatewayModel
    @ScaledMetric(relativeTo: .largeTitle) private var face: CGFloat = 112

    var body: some View {
        let side = min(face, 150)
        CloudForge(seed: model.agentName, stage: model.forgeStage, side: side)
            .padding(.vertical, -side * (CloudForge.room - 1) / 2 + 6)
            .padding(.bottom, 14)
    }
}

private struct CloudFailedView: View {
    @Bindable var model: CloudGatewayModel
    @ScaledMetric(relativeTo: .title) private var badge: CGFloat = 84

    var body: some View {
        CloudCentered {
            ZStack {
                Circle().fill(Color.hqOrange.opacity(0.14))
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: badge * 0.4, weight: .semibold)).foregroundStyle(Color.hqOrange)
            }
            .frame(width: badge, height: badge)
            .accessibilityHidden(true)
            Text(CloudCopy.failedTitle)
                .font(Font.hq(.title2).weight(.bold))
                .foregroundStyle(Color.hqLabel)
                .padding(.top, 18)
                .accessibilityAddTraits(.isHeader)
            Text(model.failure)
                .font(Font.hq(.body))
                .foregroundStyle(Color.hqLabel2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .accessibilityIdentifier("cloud-gateway.failure")
        } bar: {
            GuideActionButton(title: CloudCopy.tryAgain, id: "cloud-gateway.retry", action: model.retry)
            GuideActionButton(title: CloudCopy.manage, id: "cloud-gateway.manage", prominent: false) { UIApplication.shared.open(Portal.agentsPage) }
        }
    }
}

// MARK: - Pieces

enum CloudLayout {
    static let gutter: CGFloat = 20
    static let narrow: CGFloat = 460
    static let wide: CGFloat = 560
    /// iOS 26's grouped-card corner.
    static let radius: CGFloat = 24
}

struct CloudCardModifier: ViewModifier {
    var selected: Bool

    func body(content: Content) -> some View {
        let _ = Theme.touch()
        if Theme.isDesktop {
            content
                .background(Color.hqPage, in: RoundedRectangle(cornerRadius: DesktopRows.radius))
                .overlay(RoundedRectangle(cornerRadius: DesktopRows.radius)
                    .strokeBorder(selected ? Color.hqTintText : Color.hqStroke, lineWidth: selected ? 2 : 1))
        } else {
            content
                // The system's grouped card (hqGroupedCard is the page's grey in light: UX study #94).
                .background(Color(uiColor: HQPalette.card), in: RoundedRectangle(cornerRadius: CloudLayout.radius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: CloudLayout.radius, style: .continuous)
                        .strokeBorder(Color.hqTint, lineWidth: 2)
                        .opacity(selected ? 1 : 0)
                }
        }
    }
}

extension View {
    /// iOS's grouped card with the look off; the look's 4 pt outlined box with it on. `selected`: an accent edge.
    func cloudCard(selected: Bool = false) -> some View { modifier(CloudCardModifier(selected: selected)) }
}

/// A grouped page's section label, over a card.
struct CloudLabel: View {
    var text: String

    var body: some View {
        let _ = Theme.touch()
        Group {
            if Theme.isDesktop {
                Text(text).hqDesktopLabel()
            } else {
                Text(text).font(Font.hq(.subheadline).weight(.semibold)).foregroundStyle(Color.hqLabel2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A Settings-style symbol tile.
struct CloudTile: View {
    var symbol: String
    var tint: Color = .hqTint
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 34

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: min(side, 48) * 0.47, weight: .semibold))
            .foregroundStyle(Color.hqOnTint)
            .frame(width: min(side, 48), height: min(side, 48))
            .background(tint, in: RoundedRectangle(cornerRadius: min(side, 48) * 0.27, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The face on a soft glow: breathing while the agent comes up, with a tick once it's ready.
struct CloudHero: View {
    var working = false
    var done = false
    var size: CGFloat
    @State private var breathe = false

    var body: some View {
        let _ = Theme.touch()
        ZStack {
            if !Theme.isDesktop {
                Circle()
                    .fill(RadialGradient(colors: [Color.hqTint.opacity(0.3), Color.hqTint.opacity(0)], center: .center,
                                         startRadius: size * 0.15, endRadius: size * 1.1))
                    .frame(width: size * 2.2, height: size * 2.2)
                    .scaleEffect(breathe ? 1.08 : 0.92)
            }
            HeadImage(head: CloudCopy.mascot, size: size, working: working)
            if done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, Color.green)
                    .background(Circle().fill(Color.hqGroupedPage).padding(-3))
                    .offset(x: size * 0.42, y: size * 0.42)
                    .transition(.hqMotion(.scale.combined(with: .opacity)))
            }
        }
        .frame(height: size * 1.75)
        .accessibilityHidden(true)
        .onAppear {
            guard working, !HQMotion.decorativeStill else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}

/// Words and a card centred in the space above an optional pinned bar.
struct CloudCentered<Content: View, Bar: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var bar: Bar

    var body: some View {
        let built = VStack(spacing: 0) { content }
        GeometryReader { proxy in
            ScrollView {
                built
                    .frame(maxWidth: CloudLayout.narrow)
                    .padding(.horizontal, CloudLayout.gutter)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
        .hqCloudActionBar {
            if Bar.self != EmptyView.self { CloudActionBar { bar } }
        }
    }
}

extension CloudCentered where Bar == EmptyView {
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
        self.bar = EmptyView()
    }
}

/// The pinned actions under a page. [glass-audit] In the iOS look nothing is painted behind them: the buttons are glass
/// and the page fades under them with the system's scroll edge (`hqCloudActionBar`), as iOS 26's own bottom bars do.
/// The Desktop Look has no glass: there they sit on the page colour.
struct CloudActionBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        let _ = Theme.touch()
        VStack(spacing: 10) { content }
            .frame(maxWidth: CloudLayout.narrow)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity)
            .background((Theme.isDesktop ? Color.hqGroupedPage : Color.clear).ignoresSafeArea(edges: .bottom))
    }
}

extension View {
    /// [glass-audit] A Hermes Cloud page's pinned actions: a bar the page scrolls under (the soft edge), not an inset.
    func hqCloudActionBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        safeAreaBar(edge: .bottom, spacing: 0, content: bar)
    }
}

/// A card that is a button: it dims a little while pressed.
struct CloudPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.65 : 1)
            .scaleEffect(configuration.isPressed && !HQMotion.reduced ? 0.985 : 1)
            .animation(HQMotion.swiftUI(.smooth(duration: 0.15)), value: configuration.isPressed)
    }
}
