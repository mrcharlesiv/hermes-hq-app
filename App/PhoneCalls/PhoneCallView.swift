import SwiftUI
import UIKit

struct PhoneCallView: View {
    enum Page: Hashable {
        case call(String)
        case transcript(String)
        case again(String, leave: Bool)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var path: [Page] = []
    let accountID: String
    let sessionID: String
    let profile: String?
    var proposal: PhoneProposal? = nil
    var callID: String? = nil
    var matchingSessions: Set<String> = []
    var botName: String? = nil
    var chatContext: String? = nil

    private var controller: PhoneCallController { .shared(for: accountID) }
    private var mine: [PhoneCallRecord] {
        controller.calls.filter { $0.sessionID == sessionID || matchingSessions.contains($0.sessionID) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let id = callID {
                    screen(id)
                } else {
                    newCall(prefill: proposal, suggested: proposal != nil)
                }
            }
            .navigationDestination(for: Page.self) { page in
                switch page {
                case .call(let id):
                    screen(id)
                case .transcript(let id):
                    if let call = controller.call(id) {
                        VStack(spacing: 8) {
                            let who = [call.name, phoneShown(call.to)].compactMap { $0 }.joined(separator: " · ")
                            PhoneScreenHeader(title: "Transcript", subtitle: who,
                                              back: { path.removeLast() })
                            PhoneConversation(lines: call.shownLines, catchingUp: false, readOnly: true,
                                              botName: call.botName, calleeName: call.name,
                                              callingOwner: call.callingOwner == true)
                        }
                        .phonePage()
                        .toolbar(.hidden, for: .navigationBar)
                    }
                case .again(let id, let leave):
                    if let call = controller.call(id) {
                        newCall(prefill: PhoneProposal(to: call.to, goal: call.purpose,
                                                       voicemail: leave ? .leaveMessage : call.voicemailChoice,
                                                       name: call.name, callingOwner: call.callingOwner == true),
                                suggested: false, session: call.sessionID, profile: call.profile,
                                botName: call.botName ?? botName, canGoBack: true)
                    }
                }
            }
        }
    }

    private func screen(_ id: String) -> some View {
        PhoneCallScreen(controller: controller, id: id, close: { dismiss() }, open: { path.append($0) })
            .toolbar(.hidden, for: .navigationBar)
    }

    private func newCall(prefill: PhoneProposal?, suggested: Bool, session: String? = nil, profile: String? = nil,
                         botName: String? = nil, canGoBack: Bool = false) -> some View {
        PhoneNewCallView(controller: controller, sessionID: session ?? sessionID, profile: profile ?? self.profile,
                         botName: botName ?? self.botName, chatContext: chatContext,
                         recent: mine.filter { !$0.active }.reversed(), prefill: prefill, suggested: suggested,
                         close: { dismiss() }, back: canGoBack ? { path.removeLast() } : nil,
                         open: { path.append(.call($0)) })
            .toolbar(.hidden, for: .navigationBar)
    }
}

private struct PhoneNewCallView: View {
    let controller: PhoneCallController
    let sessionID: String
    let profile: String?
    let botName: String?
    let chatContext: String?
    let recent: [PhoneCallRecord]
    let suggested: Bool
    let close: () -> Void
    let back: (() -> Void)?
    let open: (String) -> Void
    @State private var to: String
    @State private var name: String
    @State private var goal: String
    @State private var voicemail: PhoneVoicemailChoice
    @State private var callingOwner: Bool
    @State private var userPickedCallingOwner = false
    @State private var includeChatContext: Bool
    @State private var userPickedChatContext = false
    @State private var customGreeting: String
    @State private var error: String?
    @State private var confirming = false
    @State private var busy = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @FocusState private var editing: Field?
    private enum Field: Hashable { case number, name, goal }

    init(controller: PhoneCallController, sessionID: String, profile: String?, botName: String?, chatContext: String?,
         recent: [PhoneCallRecord], prefill: PhoneProposal?, suggested: Bool, close: @escaping () -> Void,
         back: (() -> Void)?, open: @escaping (String) -> Void) {
        self.controller = controller; self.sessionID = sessionID; self.profile = profile
        self.botName = botName; self.chatContext = chatContext; self.recent = recent
        self.suggested = suggested; self.close = close; self.back = back; self.open = open
        let initialTo = prefill?.to ?? ""
        let initialName = prefill?.name ?? ""
        let initialGoal = prefill?.goal ?? ""
        let initialSelf = prefill?.callingOwner == true
            || PhoneAskOwner.infersCallingOwner(ownerName: controller.setup?.name ?? "", calleeName: initialName,
                                                purpose: initialGoal)
        _to = State(initialValue: initialTo)
        _name = State(initialValue: initialName)
        _goal = State(initialValue: initialGoal)
        _voicemail = State(initialValue: prefill?.voicemail ?? .hangUp)
        _callingOwner = State(initialValue: initialSelf)
        _includeChatContext = State(initialValue: initialSelf && chatContext != nil)
        _customGreeting = State(initialValue: prefill?.greeting ?? "")
    }

    private var destination: String { phoneDestination(to, from: controller.setup?.fromNumber) }
    private var purpose: String { goal.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var activeChatContext: String? { includeChatContext ? chatContext : nil }
    private var callerBotName: String { PhoneAskOwner.normalizedBotName(botName) }
    private var openingLinePreview: String {
        PhoneAskOwner.greeting(botName: botName ?? "", ownerName: controller.setup?.name ?? "",
                               calleeName: name.trimmingCharacters(in: .whitespacesAndNewlines),
                               callingOwner: callingOwner, purpose: purpose, customGreeting: customGreeting,
                               hasChatContext: activeChatContext != nil, recorded: controller.setup?.records == true)
    }

    var body: some View {
        VStack(spacing: 10) {
            // [phone-review] Owner 2026-11-22: "That little pop up to confirm is awful ux." Review is a step of this
            // screen: the call laid out as it will be placed, a green Place call, and Edit to go back.
            PhoneScreenHeader(title: confirming ? "Review call" : "New call",
                              back: confirming ? { confirming = false } : back, close: confirming ? nil : close)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if controller.ready, confirming {
                        review
                    } else if controller.ready {
                        fields
                        let contextCopy = activeChatContext != nil
                            ? "Includes a brief summary of recent messages from this chat."
                            : "The voice assistant only knows what you enter here."
                        Text("\(contextCopy) Calling from \(phoneShown(controller.setup?.fromNumber ?? "your samplehost number")). \(PhoneLimits.stayCopy) Calls are billed to your samplehost account.")
                            .font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                        if !callingOwner, (controller.setup?.name ?? "").isEmpty {
                            Text("Tip: Add your name in Settings › Phone Calls (Beta) so \(callerBotName) can say who it's calling for.")
                                .font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                        }
                        if !to.isEmpty && !phoneIsE164(destination) {
                            Text("Enter the full phone number, including the country code for international calls.")
                                .foregroundStyle(Color.hqRed).accessibilityIdentifier("phone.to.hint")
                        }
                        if let error { Text(error).foregroundStyle(Color.hqRed).accessibilityIdentifier("phone.error") }
                        if controller.hasActiveCall && !busy {
                            Text("A call is already going. Hang it up before placing another.")
                                .font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                        }
                        Button(busy ? "Placing call…" : "Review call") { editing = nil; confirming = true }
                            .buttonStyle(PhoneActionStyle(fill: Color.hqTint, ink: Color(uiColor: PhoneCardColors.onAccent)))
                            .disabled(!phoneIsE164(destination) || purpose.isEmpty || busy || controller.hasActiveCall)
                    } else {
                        Text("Connect samplehost in Settings › Phone Calls (Beta) to place calls.")
                    }
                    if !recent.isEmpty, !confirming {
                        Text("Recent").font(Font.hq(.headline)).padding(.top, 10).accessibilityAddTraits(.isHeader)
                        ForEach(recent) { call in
                            Button { open(call.id) } label: {
                                PhoneRecentRow(call: call).padding(12).phoneCard(radius: 18)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("phone.recent.row")
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .phonePage()
        .onChange(of: name) { _, _ in syncAutoCallingOwner() }
        .onChange(of: goal) { _, _ in syncAutoCallingOwner() }
    }

    private func syncAutoCallingOwner() {
        guard !userPickedCallingOwner else { return }
        let inferred = PhoneAskOwner.infersCallingOwner(ownerName: controller.setup?.name ?? "",
                                                        calleeName: name, purpose: goal)
        if inferred != callingOwner {
            callingOwner = inferred
            if !userPickedChatContext { includeChatContext = inferred && chatContext != nil }
        }
    }

    /// The review step: who, why, what the assistant will say on pickup, and the one button that dials.
    private var review: some View {
        let who = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 6) {
                PhoneMarkView(mark: .proposal, size: 54)
                Text(who.isEmpty ? phoneShown(destination) : who).font(Font.hq(.title2).weight(.bold))
                    .multilineTextAlignment(.center)
                if !who.isEmpty { Text(phoneShown(destination)).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2) }
            }
            .frame(maxWidth: .infinity).padding(18).phoneCard(radius: 22)
            .accessibilityElement(children: .combine).accessibilityIdentifier("phone.review.who")
            VStack(alignment: .leading, spacing: 6) {
                Text("GOAL").font(Font.hq(.caption).weight(.semibold)).foregroundStyle(Color.hqLabel2)
                Text(purpose).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(14).phoneCard(radius: 18)
            .accessibilityElement(children: .combine).accessibilityIdentifier("phone.review.goal")
            VStack(alignment: .leading, spacing: 6) {
                Text("OPENING LINE").font(Font.hq(.caption).weight(.semibold)).foregroundStyle(Color.hqLabel2)
                Text("“\(openingLinePreview)”").fixedSize(horizontal: false, vertical: true)
                Text("Spoken right when they answer").font(Font.hq(.caption)).foregroundStyle(Color.hqLabel2)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(14).phoneCard(radius: 18)
            .accessibilityElement(children: .combine).accessibilityIdentifier("phone.review.greeting")
            VStack(spacing: 8) {
                reviewRow("Calling as", callerBotName)
                if callingOwner {
                    reviewRow("Calling", "You directly")
                } else if let owner = controller.setup?.name, !owner.isEmpty {
                    reviewRow("Calling for", owner)
                }
                if activeChatContext != nil {
                    reviewRow("Chat context", "Included")
                }
                reviewRow("From", phoneShown(controller.setup?.fromNumber ?? ""))
                reviewRow("If voicemail answers", voicemail.title)
                reviewRow("Recording", controller.setup?.records == true ? "On" : "Off")
                reviewRow("Billed to", "Your samplehost account")
            }
            .padding(14).phoneCard(radius: 18)
            Text("An AI assistant talks for you. \(PhoneLimits.stayCopy) Only call people who expect it.")
                .font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
            if let error { Text(error).foregroundStyle(Color.hqRed).accessibilityIdentifier("phone.error") }
            Button { start() } label: {
                Label(busy ? "Placing call…" : "Place call", systemImage: "phone.fill")
            }
            .buttonStyle(PhoneActionStyle(fill: Color.hqGreen, ink: Color(uiColor: PhoneCardColors.ink(on: PhoneMark.phone.uiColor, minimum: 3)),
                                          radius: 16, minHeight: 54))
            .disabled(busy || controller.hasActiveCall)
            .accessibilityIdentifier("phone.place")
            Button("Edit") { confirming = false }
                .buttonStyle(PhoneActionStyle())
                .disabled(busy)
                .accessibilityIdentifier("phone.review.edit")
        }
    }

    private func reviewRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(Color.hqLabel2).multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private var fields: some View {
        let whoBinding = Binding<Bool>(
            get: { callingOwner },
            set: { next in
                userPickedCallingOwner = true
                callingOwner = next
                if !userPickedChatContext { includeChatContext = next && chatContext != nil }
            }
        )
        let contextBinding = Binding<Bool>(
            get: { includeChatContext },
            set: { next in
                userPickedChatContext = true
                includeChatContext = next
            }
        )
        return VStack(alignment: .leading, spacing: 8) {
            if suggested {
                Label("Suggested by your agent", systemImage: "sparkles")
                    .font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                    .accessibilityIdentifier("phone.suggested")
            }
            Picker("Who is being called", selection: whoBinding) {
                Text("Someone else").tag(false)
                Text("Myself").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("phone.calling-who")
            TextField("To", text: $to)
                .keyboardType(.phonePad).textContentType(.telephoneNumber).focused($editing, equals: .number)
                .accessibilityIdentifier("phone.to")
                .padding(.horizontal, 12).frame(minHeight: 44).background(Color.hqGroupedPage, in: .rect(cornerRadius: 12))
            TextField("Who is this? (optional)", text: $name)
                .focused($editing, equals: .name).accessibilityIdentifier("phone.name")
                .padding(.horizontal, 12).frame(minHeight: 44).background(Color.hqGroupedPage, in: .rect(cornerRadius: 12))
            TextField("Purpose, context, and what to say or ask", text: $goal, axis: .vertical)
                .focused($editing, equals: .goal).accessibilityIdentifier("phone.purpose")
                .padding(12).frame(minHeight: 48).background(Color.hqGroupedPage, in: .rect(cornerRadius: 12))
            if chatContext != nil {
                Toggle("Share recent chat context", isOn: contextBinding)
                    .font(Font.hq(.subheadline))
                    .padding(.horizontal, 12).frame(minHeight: 44)
                    .accessibilityIdentifier("phone.include-context")
            }
            let voicemailLayout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0)) : AnyLayout(HStackLayout(spacing: 8))
            voicemailLayout {
                Text("If voicemail answers").foregroundStyle(Color.hqLabel2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityHidden(true)
                Picker("If voicemail answers", selection: $voicemail) {
                    ForEach(PhoneVoicemailChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minHeight: 44)
                .accessibilityIdentifier("phone.voicemail")
            }
            .padding(.leading, 12)
        }
        .padding(14)
        .phoneCard(radius: 18)
    }

    private func start() {
        guard !busy else { return }
        busy = true; error = nil
        let number = destination, words = purpose, choice = voicemail
        let place = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(PhoneProposal.maxName))
        let isSelf = callingOwner
        let greetingOverride = customGreeting.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = activeChatContext
        let bot = botName
        Task {
            defer { busy = false }
            let result = await Result.of {
                try await controller.place(sessionID: sessionID, profile: profile, to: number, purpose: words,
                                           voicemail: choice, suggested: suggested, name: place.isEmpty ? nil : place,
                                           botName: bot, callingOwner: isSelf,
                                           greeting: greetingOverride.isEmpty ? nil : greetingOverride,
                                           chatContext: context)
            }
            switch result {
            case .success(let id): open(id)
            case .failure(let failure): error = phoneMessage(failure)
            }
        }
    }
}

struct PhoneRecentRow: View {
    let call: PhoneCallRecord
    var body: some View {
        HStack(spacing: 12) {
            PhoneMarkView(mark: call.active ? .phone : .outcome(call.outcome), size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(call.name ?? phoneShown(call.to)).font(Font.hq(.headline)).foregroundStyle(Color.hqLabel)
                let details = [call.name.map { _ in phoneShown(call.to) }, call.statusText,
                               call.placedAt.formatted(date: .abbreviated, time: .shortened)]
                Text(details.compactMap { $0 }.joined(separator: " · "))
                    .font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(Font.hq(.footnote).weight(.semibold))
                .foregroundStyle(Color.hqLabel2).accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

struct PhoneScreenHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var back: (() -> Void)? = nil
    var close: (() -> Void)? = nil
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(spacing: 4) {
                    HStack {
                        leading
                        Spacer()
                        trailing().frame(minWidth: 44, minHeight: 44)
                    }
                    identity
                }
            } else {
                HStack(spacing: 10) {
                    leading
                    identity
                    trailing().frame(minWidth: 44, minHeight: 44)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private var identity: some View {
        VStack(spacing: 3) {
            Text(title).font(Font.hq(.headline)).accessibilityAddTraits(.isHeader)
            if let subtitle { Text(subtitle).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2) }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var leading: some View {
        if let back {
            SheetCloseDiscView(glyph: .back, action: back).frame(width: 44, height: 44)
        } else if let close {
            #if targetEnvironment(macCatalyst)
            Button("Close", action: close)
                .font(Font(MacCloseItem.font(semibold: false))).buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("phone.close")
            #else
            SheetCloseDiscView(identifier: "phone.close", action: close).frame(width: 44, height: 44)
            #endif
        } else {
            Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
        }
    }
}

extension PhoneScreenHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, back: (() -> Void)? = nil, close: (() -> Void)? = nil) {
        self.init(title: title, subtitle: subtitle, back: back, close: close) { EmptyView() }
    }
}

struct PhoneMarkView: View {
    let mark: PhoneMark
    let size: CGFloat

    var body: some View {
        Image(systemName: mark.symbol)
            .font(.system(size: size * 0.43, weight: .semibold))
            .foregroundStyle(Color(uiColor: PhoneCardColors.ink(on: mark.uiColor, minimum: 3)))
            .frame(width: size, height: size)
            .background(mark.color, in: .circle)
            .accessibilityHidden(true)
    }
}

extension PhoneMark {
    var color: Color {
        switch self {
        case .phone, .success: .hqGreen
        case .warning, .voicemail, .missed: Color(uiColor: PhoneCardColors.attention)
        case .failed: .hqRed
        case .proposal: .hqTint
        case .ended: .hqLabel2
        }
    }
}

struct PhoneActionStyle: ButtonStyle {
    var fill: Color = .phoneCardFill
    var ink: Color = .hqTintText
    var radius: CGFloat = 14
    var minHeight: CGFloat = 44
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Font.hq(.subheadline).weight(.semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(ink)
            .padding(.horizontal, 8).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .background(fill, in: .rect(cornerRadius: HQShape.radius(radius, .card)))
            .opacity(configuration.isPressed || !enabled ? 0.6 : 1)
            .contentShape(.rect)
    }
}

extension View {
    func phonePage() -> some View {
        font(Font.hq(.body)).foregroundStyle(Color.hqLabel).tint(Color.hqTintText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.hqGroupedPage.ignoresSafeArea())
    }

    func phoneCard(radius: CGFloat) -> some View {
        background(Color.phoneCardFill, in: .rect(cornerRadius: HQShape.radius(radius, .card)))
    }
}

struct PhoneStoredResultView: View {
    let result: PhoneResultCard
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let who = [result.name, phoneShown(result.number)].compactMap { $0 }.joined(separator: " · ")
        VStack(spacing: 10) {
            PhoneScreenHeader(title: "Call summary", subtitle: who, close: { dismiss() })
            ScrollView {
                VStack(spacing: 10) {
                    VStack(spacing: 8) {
                        PhoneMarkView(mark: result.mark, size: 54)
                        Text(result.title).font(Font.hq(.title2).weight(.bold))
                        Text(who).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                    }
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(18).frame(maxWidth: .infinity)
                    .phoneCard(radius: 22)

                    if !result.goal.isEmpty {
                        sectionCard("GOAL") {
                            Text(result.goal).textSelection(.enabled)
                        }
                    }
                    if let summary = result.summary, !summary.isEmpty {
                        sectionCard("WHAT HAPPENED") {
                            Text(summary).textSelection(.enabled)
                        }
                    }
                    if !result.questions.isEmpty {
                        sectionCard("YOU WERE ASKED") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(result.questions.enumerated()), id: \.offset) { _, line in
                                    Text(line).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    sectionCard("TRANSCRIPT") {
                        if result.transcriptLines.isEmpty {
                            Text("Nothing was said.").foregroundStyle(Color.hqLabel2)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(result.transcriptLines.enumerated()), id: \.offset) { _, line in
                                    Text(line).textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
        }
        .phonePage()
    }

    private func sectionCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Font.hq(.caption).weight(.bold)).foregroundStyle(Color.hqLabel2)
                .accessibilityAddTraits(.isHeader)
            content().font(Font.hq(.subheadline)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).phoneCard(radius: 18)
    }
}


extension Color {
    static var phoneCardFill: Color { Color(uiColor: HQPalette.solidSheetCard) }
}
