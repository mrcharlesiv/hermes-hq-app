import SwiftUI
import UIKit

/// Pure two-step accidental hang-up guard: the first tap arms it, a later tap on End call confirms. A tap that lands
/// within `settle` of the arming tap is the same accidental double tap, so neither button answers it. The question
/// goes away by itself after `disarmDelay` (`assistedDisarmDelay` with VoiceOver or Switch Control).
nonisolated struct PhoneHangUpGuard: Equatable, Sendable {
    static let disarmDelay: Duration = .seconds(4)
    static let assistedDisarmDelay: Duration = .seconds(20)
    /// How long after the arming tap the two answers stay deaf.
    static let settle: TimeInterval = 0.45
    private(set) var armed = false
    private var armedAt: TimeInterval = 0

    static func disarmDelay(assisted: Bool) -> Duration { assisted ? assistedDisarmDelay : disarmDelay }

    mutating func arm(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !armed else { return }   // a repeated arming tap never moves the clock
        armed = true
        armedAt = now
    }

    /// The timer ran out, the screen went away: always disarms.
    mutating func cancel() { armed = false }

    /// Keep call. False while the arming tap is still settling (the question stays up).
    mutating func keep(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard armed, settled(now) else { return false }
        armed = false
        return true
    }

    /// End call. True only if armed and settled, then disarms.
    mutating func confirm(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard armed, settled(now) else { return false }
        armed = false
        return true
    }

    /// A clock that went backwards counts as not settled.
    private func settled(_ now: TimeInterval) -> Bool { now - armedAt >= Self.settle }
}

struct PhoneCallScreen: View {
    let controller: PhoneCallController
    let id: String
    let close: () -> Void
    let open: (PhoneCallView.Page) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var confirmDelete = false
    @State private var hangUpGuard = PhoneHangUpGuard()
    @State private var hangUpDisarmTask: Task<Void, Never>?
    @State private var sharing: String?
    @State private var message = ""
    @State private var answer = ""
    @State private var retryAction: Retry?
    @State private var questionHeight: CGFloat = 180
    @FocusState private var editing: Field?
    @AccessibilityFocusState private var firstChoice: Bool

    private enum Field: Hashable { case message, answer }
    private enum Retry { case answer(PhoneTranscript.Question, String), tell(String), hangUp }

    var body: some View {
        Group {
            if let call = controller.call(id) {
                VStack(spacing: 8) {
                    let activeTitle = call.name ?? phoneShown(call.to)
                    let activeSubtitle = call.name == nil ? nil : phoneShown(call.to)
                    PhoneScreenHeader(title: call.active ? activeTitle : "Call summary",
                                      subtitle: call.active ? activeSubtitle : dateLabel(call.placedAt), close: close) {
                        Menu {
                            Button("Copy number", systemImage: "doc.on.doc") {
                                UIPasteboard.general.string = call.to
                                Haptics.play(.success)
                                HQAnnounce.say("Number copied")
                            }
                            if !call.active {
                                if call.outcome == .voicemail && call.voicemailChoice == .hangUp {
                                    Button("Transcript", systemImage: "text.bubble") { perform(.transcript, call: call) }
                                    Button("Share", systemImage: "square.and.arrow.up") { perform(.share, call: call) }
                                }
                                Button("Delete this call", systemImage: "trash", role: .destructive) { confirmDelete = true }
                            }
                        } label: {
                            Image(systemName: "ellipsis").font(Font(HQFont.scaled(17, weight: .semibold, like: .headline, cap: 17)))
                                .frame(width: 44, height: 44)
                                .background(Color.phoneCardFill, in: .circle)
                        }
                        .accessibilityLabel("Call options")
                        .accessibilityIdentifier("phone.call.options")
                    }
                    if !call.active {
                        PhoneCallSummary(call: call, sendsResults: controller.setup?.sendsResults != false,
                                         action: { perform($0, call: call) })
                    } else if call.state == .calling || (call.state == .ending && call.answeredAt == nil && call.liveAt == nil) {
                        ringing(call)
                    } else {
                        live(call)
                    }
                }
                .animation(HQMotion.swiftUI(.easeInOut(duration: HQMotion.move)), value: call.active)
                .onChange(of: questionKey(call)) { _, _ in answer = "" }
                .confirmationDialog("Delete this call?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete this call", role: .destructive) { controller.deleteCall(id); close() }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("The call and its transcript will be removed from this device.")
                }
                .sheet(isPresented: Binding(get: { sharing != nil }, set: { if !$0 { sharing = nil } })) {
                    if let sharing { PhoneShareSheet(text: sharing) }
                }
                .onAppear { controller.sheetAppeared(call.sessionID) }
                .onDisappear { controller.sheetDisappeared(call.sessionID) }
            } else {
                VStack(spacing: 16) {
                    PhoneScreenHeader(title: "Call summary", close: close)
                    Text("This call is no longer in your history.").foregroundStyle(Color.hqLabel2)
                    Spacer()
                }
            }
        }
        .phonePage()
    }

    private func ringing(_ call: PhoneCallRecord) -> some View {
        VStack(spacing: 10) {
            GeometryReader { viewport in
                ScrollView {
                    VStack(spacing: 8) {
                        goal(call)
                        VStack(spacing: 14) {
                            PhoneRingingMark()
                            Text(call.statusText).font(Font.hq(.title).weight(.bold))
                                .accessibilityIdentifier("phone.call.status")
                            if call.state == .ending {
                                Text("If voicemail answers, " + (call.voicemailChoice == .hangUp ? "hang up" : "leave a message"))
                                    .font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                                    .multilineTextAlignment(.center)
                            } else {
                                TimelineView(.periodic(from: call.placedAt, by: 1)) { time in
                                    Text(PhoneCallPresentation.timer(from: call.placedAt, to: time.date)
                                         + " · If voicemail answers, " + (call.voicemailChoice == .hangUp ? "hang up" : "leave a message"))
                                        .font(Font.hq(.subheadline)).monospacedDigit().foregroundStyle(Color.hqLabel2)
                                }
                                .multilineTextAlignment(.center)
                            }
                        }
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(minHeight: viewport.size.height)
                    .padding(.horizontal, 16)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            issue(call)
            Button("Cancel call", role: .destructive) { run(.hangUp) }
                .buttonStyle(PhoneActionStyle(fill: .hqRed, ink: Color(uiColor: PhoneCardColors.onRed), radius: 16, minHeight: 50))
                .disabled(call.state == .ending)
                .padding(.bottom, 6)
                .padding(.horizontal, 16)
        }
    }

    private func live(_ call: PhoneCallRecord) -> some View {
        GeometryReader { viewport in
            VStack(spacing: 8) {
                if typeSize.isAccessibilitySize {
                    ScrollViewReader { scroll in
                        ScrollView {
                            VStack(spacing: 8) {
                                status(call)
                                if call.question == nil && editing == nil { goal(call) }
                                PhoneConversation(lines: call.shownLines, catchingUp: call.question == nil,
                                                  botName: call.botName, calleeName: call.name,
                                                  callingOwner: call.callingOwner == true)
                                    .frame(height: 300)
                                    .opacity(call.question == nil ? 1 : 0.55)
                                if let question = call.question {
                                    questionCard(question, call: call).id(Field.answer)
                                }
                            }
                        }
                        .scrollDismissesKeyboard(.never)
                        .task(id: questionKey(call)) {
                            guard call.question != nil else { return }
                            await Task.yield()
                            guard !Task.isCancelled else { return }
                            withAnimation(HQMotion.swiftUI(.easeInOut(duration: HQMotion.move))) {
                                scroll.scrollTo(Field.answer, anchor: .top)
                            }
                        }
                    }
                } else {
                    status(call)
                    if call.question == nil && editing == nil { goal(call) }
                    PhoneConversation(lines: call.shownLines, catchingUp: call.question == nil,
                                      botName: call.botName, calleeName: call.name,
                                      callingOwner: call.callingOwner == true)
                        .opacity(call.question == nil ? 1 : 0.55)
                        .frame(minHeight: 40)
                    if let question = call.question {
                        ScrollView {
                            questionCard(question, call: call)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { questionHeight = $0 }
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .scrollDismissesKeyboard(.never)
                        .frame(height: min(questionHeight, max(74, viewport.size.height * (editing == nil ? 0.65 : 0.45))))
                        .transition(.opacity)
                    }
                }
                issue(call)
                dock(call)
            }
            .animation(HQMotion.swiftUI(.easeInOut(duration: HQMotion.move)), value: questionKey(call))
            .task(id: questionKey(call)) {
                guard let question = call.question else { return }
                Haptics.play(.light)
                HQAnnounce.say(question.text, coalesce: true)
                await Task.yield()
                if !Task.isCancelled { firstChoice = !question.choices.isEmpty }
            }
        }
    }

    private func questionKey(_ call: PhoneCallRecord) -> String? {
        call.question.map { PhoneTranscript.normalized($0.text) }
    }

    private func status(_ call: PhoneCallRecord) -> some View {
        let waiting = call.question != nil && call.state != .ending
        return HStack(spacing: 12) {
            PhoneMarkView(mark: waiting ? .warning : .phone, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(waiting ? "Waiting on you" : call.statusText)
                    .font(Font.hq(.headline)).accessibilityIdentifier("phone.call.status")
                Text(waiting ? "They are holding" : call.recorded ? "Recorded" : "Not recorded")
                    .font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                    .accessibilityIdentifier("phone.call.recorded")
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            let start = call.answeredAt ?? call.liveAt ?? call.placedAt
            if call.state == .ending {
                Text(PhoneCallPresentation.timer(from: start, to: call.endedAt ?? Date()))
                    .font(Font.hq(.title3).weight(.semibold)).monospacedDigit()
                    .accessibilityIdentifier("phone.call.timer")
            } else {
                TimelineView(.periodic(from: start, by: 1)) { time in
                    Text(PhoneCallPresentation.timer(from: start, to: time.date))
                        .font(Font.hq(.title3).weight(.semibold)).monospacedDigit()
                        .accessibilityIdentifier("phone.call.timer")
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .phoneCard(radius: 18)
        .padding(.horizontal, 16)
    }

    private func goal(_ call: PhoneCallRecord) -> some View {
        (Text("Goal").fontWeight(.semibold) + Text(" · " + call.purpose).foregroundStyle(Color.hqLabel2))
            .font(Font.hq(.footnote))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.hqFill3, in: .rect(cornerRadius: HQShape.radius(12, .card)))
            .accessibilityIdentifier("phone.call.goal")
            .padding(.horizontal, call.state == .calling ? 0 : 16)
    }

    private func questionCard(_ question: PhoneTranscript.Question, call: PhoneCallRecord) -> some View {
        let sending = call.sendingAnswer != nil
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: typeSize.isAccessibilitySize ? 1 : 2)
        let asker = call.botName.flatMap { $0.isEmpty ? nil : $0 } ?? "The assistant"
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(asker.uppercased()) ASKS YOU").font(Font.hq(.caption).weight(.bold)).foregroundStyle(Color.hqOrange)
            Text(question.text).font(Font.hq(.title3).weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("phone.question")
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(question.choices, id: \.self) { choice in
                    if choice == question.choices.first {
                        choiceButton(choice, question: question).accessibilityFocused($firstChoice)
                    } else {
                        choiceButton(choice, question: question)
                    }
                }
            }
            .disabled(sending)
            HStack(spacing: 8) {
                TextField("Type a different answer", text: $answer,
                          prompt: Text("Type a different answer…").foregroundStyle(Color.hqLabel2))
                    .font(Font.hq(.subheadline))
                    .focused($editing, equals: .answer)
                    .submitLabel(.send)
                    .onSubmit { run(.answer(question, answer)) }
                    .frame(minHeight: 44).contentShape(.rect)
                    .accessibilityIdentifier("phone.answer")
                if !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Send answer", systemImage: "arrow.up.circle.fill") { run(.answer(question, answer)) }
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                }
            }
            .padding(.horizontal, 12).frame(minHeight: 44)
            .background(Color.hqGroupedPage, in: .rect(cornerRadius: 12))
            .disabled(sending)
            .overlay {
                if sending {
                    HStack(spacing: 8) { ProgressView(); Text("Sending…") }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.hqGroupedPage, in: .rect(cornerRadius: 12))
                }
            }
        }
        .padding(14).phoneCard(radius: 22)
        .overlay { RoundedRectangle(cornerRadius: HQShape.radius(22, .card)).strokeBorder(Color(uiColor: PhoneCardColors.attention), lineWidth: 2).allowsHitTesting(false) }
        .shadow(color: Color(uiColor: PhoneCardColors.attention).opacity(0.22), radius: 12, y: 5)
        .padding(.horizontal, typeSize.isAccessibilitySize ? 12 : 0)
    }

    private func choiceButton(_ choice: String, question: PhoneTranscript.Question) -> some View {
        Button(choice) { run(.answer(question, choice)) }
            .buttonStyle(PhoneActionStyle(fill: .hqTint, ink: Color(uiColor: PhoneCardColors.onAccent)))
    }

    private func dock(_ call: PhoneCallRecord) -> some View {
        let targetName = call.botName.flatMap { $0.isEmpty ? nil : $0 } ?? "the assistant"
        return Group {
            if hangUpGuard.armed {
                hangUpQuestion(call)
            } else {
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        TextField("Tell the assistant", text: $message,
                                  prompt: Text("Tell \(targetName)…").foregroundStyle(Color.hqLabel2))
                            .font(Font.hq(.subheadline))
                            .focused($editing, equals: .message)
                            .submitLabel(.send)
                            .onSubmit { run(.tell(message)) }
                            .frame(minHeight: 44).contentShape(.rect)
                            .accessibilityIdentifier("phone.tell")
                        if !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button("Send", systemImage: "arrow.up.circle.fill") { run(.tell(message)) }
                                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                                .accessibilityIdentifier("phone.tell.send")
                        }
                    }
                    .padding(.horizontal, 15).frame(minHeight: 44)
                    .background(Color.phoneCardFill, in: .capsule)
                    .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                    .disabled(call.state == .ending || call.sendingMessage)
                    Button("Hang up", systemImage: "phone.down.fill", role: .destructive) { armHangUp() }
                        .labelStyle(.iconOnly)
                        .font(Font(HQFont.scaled(22, weight: .semibold, like: .title3, cap: 22)))
                        .foregroundStyle(Color(uiColor: PhoneCardColors.onRed))
                        .frame(width: 54, height: 54)
                        .background(Color.hqRed, in: .circle)
                        .shadow(color: Color.hqRed.opacity(0.35), radius: 8, y: 4)
                        .buttonStyle(.plain)
                        .disabled(call.state == .ending)
                }
                .transition(.opacity)
            }
        }
        .animation(HQMotion.swiftUI(.easeInOut(duration: HQMotion.quick)), value: hangUpGuard.armed)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .onDisappear { disarmHangUp() }
    }

    /// "End this call?" with its two answers. Keep call takes the red button's place, so a tap that keeps landing in
    /// that spot never ends the call. At the largest text sizes the words sit above the answers.
    private func hangUpQuestion(_ call: PhoneCallRecord) -> some View {
        let big = typeSize.isAccessibilitySize
        let layout = big ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
        let end = Button("End call", role: .destructive) {
            guard hangUpGuard.confirm() else { return }
            hangUpDisarmTask?.cancel()
            hangUpDisarmTask = nil
            run(.hangUp)
        }
        .font(Font.hq(.subheadline).weight(.semibold))
        .lineLimit(1).minimumScaleFactor(0.7)
        .foregroundStyle(Color(uiColor: PhoneCardColors.onRed))
        .padding(.horizontal, 16).frame(maxWidth: big ? .infinity : nil, minHeight: 44)
        .background(Color.hqRed, in: .capsule)
        .contentShape(.capsule)
        .buttonStyle(.plain)
        .disabled(call.state == .ending)
        .accessibilityIdentifier("phone.hangup.confirm")
        let keep = Button("Keep call") {
            guard hangUpGuard.keep() else { return }
            disarmHangUp()
            Haptics.play(.selection)
        }
        .font(Font.hq(.subheadline).weight(.medium))
        .lineLimit(1).minimumScaleFactor(0.7)
        .foregroundStyle(Color.hqLabel)
        .padding(.horizontal, 14).frame(maxWidth: big ? .infinity : nil, minHeight: 44)
        .background(Color.hqFill3, in: .capsule)
        .contentShape(.capsule)
        .buttonStyle(.plain)
        .accessibilityIdentifier("phone.hangup.cancel")
        return layout {
            Text("End this call?")
                .font(Font.hq(.subheadline).weight(.semibold))
                .foregroundStyle(Color.hqLabel)
                .lineLimit(big ? 2 : 1).minimumScaleFactor(0.8)
                .accessibilityIdentifier("phone.hangup.prompt")
            if !big { Spacer(minLength: 4) }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { end; keep }
                VStack(spacing: 8) { end; keep }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, big ? 12 : 6)
        .background(Color.phoneCardFill, in: .rect(cornerRadius: big ? 22 : 29))
        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
        .transition(.opacity)
    }

    private func armHangUp() {
        editing = nil
        hangUpGuard.arm()
        Haptics.play(.light)
        HQAnnounce.say("Confirm end call")
        hangUpDisarmTask?.cancel()
        hangUpDisarmTask = Task {
            // With VoiceOver or Switch Control, reaching End call takes longer than four seconds.
            let settings = HQAccessibility.current
            let assisted = settings.voiceOver || settings.switchControl
            try? await Task.sleep(for: PhoneHangUpGuard.disarmDelay(assisted: assisted))
            guard !Task.isCancelled else { return }
            hangUpGuard.cancel()
        }
    }

    private func disarmHangUp() {
        hangUpDisarmTask?.cancel()
        hangUpDisarmTask = nil
        hangUpGuard.cancel()
    }

    @ViewBuilder private func issue(_ call: PhoneCallRecord) -> some View {
        if let words = call.issue ?? call.watchIssue {
            HStack {
                Text(words).font(Font.hq(.footnote)).accessibilityIdentifier("phone.call.issue")
                Spacer(minLength: 4)
                Button("Retry") {
                    if call.issue != nil, let retryAction { run(retryAction) }
                    else { Task { await controller.refresh(id) } }
                }
                .font(Font.hq(.footnote).weight(.semibold))
                .frame(minWidth: 44, minHeight: 44)
            }
            .padding(.horizontal, 12)
            .phoneCard(radius: 14)
            .padding(.horizontal, 16)
        }
    }

    private func run(_ action: Retry) {
        retryAction = action
        Task {
            switch action {
            case .answer(let question, let words):
                await controller.answer(id, question: question, with: words)
                if controller.call(id)?.answered.contains(question.id) == true {
                    Haptics.play(.light)
                    answer = ""
                    editing = nil
                }
            case .tell(let words):
                if await controller.tell(id, words), message == words {
                    message = ""
                    editing = nil
                }
            case .hangUp:
                await controller.hangup(id)
                if controller.call(id)?.active == false { editing = nil }
            }
        }
    }

    private func perform(_ action: PhoneCallPresentation.Action, call: PhoneCallRecord) {
        switch action {
        case .again, .leave: open(.again(id, leave: action == .leave))
        case .transcript: open(.transcript(id))
        case .share: sharing = PhoneCallPresentation.share(call, redacting: controller.setup?.apiKey)
        }
    }

    private func dateLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today " + date.formatted(date: .omitted, time: .shortened) }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct PhoneRingingMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle().fill(Color.hqGreen.opacity(0.12)).frame(width: 150, height: 150)
            Circle().fill(Color.hqGreen.opacity(0.19)).frame(width: 132, height: 132)
                .scaleEffect(pulse && !reduceMotion ? 1.1 : 0.95)
            PhoneMarkView(mark: .phone, size: 74)
        }
        .accessibilityHidden(true)
        .task(id: reduceMotion) {
            guard !reduceMotion else { pulse = false; return }
            withAnimation(HQMotion.swiftUI(.easeInOut(duration: 1.3).repeatForever(autoreverses: true))) { pulse = true }
        }
    }
}

struct PhoneConversation: View {
    let lines: [PhoneTranscript.Line]
    var catchingUp: Bool
    var readOnly = false
    var botName: String? = nil
    var calleeName: String? = nil
    var callingOwner: Bool = false
    @State private var following = true
    @State private var position = ScrollPosition(edge: .bottom)
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(lines) { line in
                        bubble(line, width: viewport.size.width - 32)
                    }
                    if catchingUp {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini).accessibilityHidden(true)
                            Text(lines.isEmpty ? "Connected, waiting for the first words…" : "catching up, a few seconds behind")
                                .accessibilityIdentifier("phone.lag-note")
                        }
                        .font(Font.hq(.caption)).foregroundStyle(Color.hqLabel2)
                        .padding(.top, lines.isEmpty ? 28 : 0)
                    } else if readOnly && lines.isEmpty {
                        Text("Nothing was said.").foregroundStyle(Color.hqLabel2)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
            .defaultScrollAnchor(readOnly ? .top : .bottom, for: .initialOffset)
            .defaultScrollAnchor(readOnly ? .top : .bottom, for: .alignment)
            .scrollPosition($position)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                PhoneCallPresentation.followsNewest(distanceFromBottom: geometry.contentSize.height - geometry.visibleRect.maxY)
            } action: { _, atNewest in
                if position.isPositionedByUser { following = atNewest }
            }
            .onScrollPhaseChange { _, phase, context in
                if phase == .idle {
                    following = PhoneCallPresentation.followsNewest(distanceFromBottom:
                        context.geometry.contentSize.height - context.geometry.visibleRect.maxY)
                }
            }
            .onChange(of: lines) { _, _ in
                if following && !readOnly { position.scrollTo(edge: .bottom) }
            }
            .onChange(of: viewport.size.height) { _, _ in
                if following && !readOnly { position.scrollTo(edge: .bottom) }
            }
            .overlay(alignment: .bottom) {
                if !following && !readOnly {
                    Button("Jump to newest", systemImage: "arrow.down") {
                        following = true
                        withAnimation(HQMotion.swiftUI(.easeInOut(duration: HQMotion.move))) { position.scrollTo(edge: .bottom) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(4)
                }
            }
        }
    }

    private func bubble(_ line: PhoneTranscript.Line, width: CGFloat) -> some View {
        let owner = line.speaker == .you
        let assistant = line.speaker == .assistant
        let speaker = PhoneCallPresentation.speaker(line, botName: botName, calleeName: calleeName, callingOwner: callingOwner)
        let alignment: HorizontalAlignment = owner ? .center : assistant ? .trailing : .leading
        return VStack(alignment: alignment, spacing: 3) {
            if !owner {
                Text(speaker).font(Font.hq(.caption2)).foregroundStyle(Color.hqLabel2).padding(.horizontal, 6)
            }
            Text(owner ? "\(speaker): \(line.text)" : line.text)
                .font(Font.hq(owner ? .footnote : .subheadline))
                .foregroundStyle(assistant ? Color(uiColor: PhoneCardColors.onAccent) : Color.hqLabel)
                .padding(.horizontal, 13).padding(.vertical, 9)
                .background(owner ? Color.hqFill3 : assistant ? Color.hqTint : Color.phoneCardFill,
                            in: .rect(cornerRadius: HQShape.radius(owner ? 12 : 18, .card)))
        }
        .frame(maxWidth: max(0, width) * (typeSize.isAccessibilitySize ? 0.98 : 0.78),
               alignment: Alignment(horizontal: alignment, vertical: .center))
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
        .accessibilityElement(children: .contain)
    }
}

private struct PhoneCallSummary: View {
    let call: PhoneCallRecord
    let sendsResults: Bool
    let action: (PhoneCallPresentation.Action) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                hero
                if !call.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    card("GOAL") {
                        Text(call.purpose)
                            .accessibilityIdentifier("phone.call.goal")
                    }
                }
                if call.settled {
                    let finished = call.outcome == .finished
                    card(finished ? "WHAT HAPPENED" : "WHY") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(finished ? PhoneCallPresentation.whatHappened(call) : PhoneCallPresentation.reason(call))
                                .accessibilityIdentifier(finished ? "phone.call.summary" : "phone.call.voicemail-note")
                            if finished && call.summary == nil && call.summaryFinished == false {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.mini).accessibilityHidden(true)
                                    Text("Generating summary…")
                                }
                                .font(Font.hq(.caption)).foregroundStyle(Color.hqLabel2)
                            }
                        }
                    }
                }
                if call.summary == nil, !call.shownLines.isEmpty {
                    let preview = Array(call.shownLines.suffix(4))
                    Button { action(.transcript) } label: {
                        card(call.shownLines.count > preview.count ? "RECENT CONVERSATION" : "CONVERSATION") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(preview) { line in
                                    let who = PhoneCallPresentation.speaker(line, botName: call.botName, calleeName: call.name,
                                                                            callingOwner: call.callingOwner == true)
                                    Text("\(Text(who + ": ").fontWeight(.semibold))\(line.text)")
                                        .foregroundStyle(Color.hqLabel)
                                        .lineLimit(3)
                                }
                                if call.shownLines.count > preview.count {
                                    Text("View all \(call.shownLines.count) messages")
                                        .font(Font.hq(.footnote).weight(.semibold))
                                        .foregroundStyle(Color.hqTintText)
                                        .padding(.top, 2)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("phone.call.transcript-preview")
                }
                if !call.asked.isEmpty {
                    card("YOU WERE ASKED") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(call.asked.enumerated()), id: \.offset) { _, pair in
                                Text(pair.question) + Text(" → " + (pair.answer ?? "Unanswered")).foregroundStyle(Color.hqLabel2)
                            }
                        }
                    }
                }
                let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
                layout {
                    ForEach(PhoneCallPresentation.actions(call), id: \.self) { item in
                        Button(item.rawValue) { action(item) }.buttonStyle(PhoneActionStyle())
                    }
                }
                card(nil) {
                    VStack(spacing: 8) {
                        ForEach(PhoneCallPresentation.facts(call, sendsResults: sendsResults)) { fact in
                            let layout = typeSize.isAccessibilitySize
                                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 3)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
                            layout {
                                Text(fact.id).frame(maxWidth: .infinity, alignment: .leading)
                                Text(fact.value).foregroundStyle(Color.hqLabel2)
                                    .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                if let note = call.endNote {
                    Text(note).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                        .accessibilityIdentifier("phone.call.end-note")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 16)
        }
        .accessibilityIdentifier("phone.summary")
    }

    private var hero: some View {
        VStack(spacing: 8) {
            ZStack {
                PhoneMarkView(mark: .outcome(call.outcome), size: 54).opacity(call.settled ? 1 : 0)
                if !call.settled { ProgressView().accessibilityLabel("Checking how the call ended") }
            }
            Text(PhoneCallPresentation.title(call.outcome, duration: call.duration))
                .font(Font.hq(.title2).weight(.bold)).accessibilityIdentifier("phone.call.status")
            Text([call.name, phoneShown(call.to), PhoneCallPresentation.pickup(call)].compactMap { $0 }.joined(separator: " · "))
                .font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
        }
        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        .padding(18).frame(maxWidth: .infinity, minHeight: 145)
        .phoneCard(radius: 22)
    }

    private func card<Content: View>(_ title: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).font(Font.hq(.caption).weight(.bold)).foregroundStyle(Color.hqLabel2)
                    .accessibilityAddTraits(.isHeader)
            }
            content().font(Font.hq(.subheadline)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).phoneCard(radius: 18)
    }
}

private struct PhoneShareSheet: UIViewControllerRepresentable {
    let text: String
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}
