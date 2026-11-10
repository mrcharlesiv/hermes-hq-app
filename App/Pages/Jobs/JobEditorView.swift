// [jobs] The New Job / Edit Job form (docs/spec/3x-jobs.md §4.4, §6.5-§6.10; redesign 2026-10-31): the bot's faces
// and the template cards (create only), the Prompt with the Name under it, the Schedule (frequency chips, Weekly's
// days, the time, the summary and the first run), Send Results To (places, then the bots' chats), Model, and Run Once
// Now (create only). A chosen template replaces the prompt to the model with its own fields. Nothing takes focus when
// the sheet opens; the keyboard goes away on scroll.
//
// [glass] Owner 2026-10-31 ("the entire pop-up should be liquid glass, and then as much that is inside of it as possible
// should be liquid glass too"): the sheet is glass at every height (`hqGlassPage(everyHeight:)`). The picks (bots,
// templates, frequency chips) are glass themselves and run edge to edge on the sheet's glass, not cut off inside a
// card; what people read and type (the prompt, the time, the places) sits on solid cards, as on every glass sheet.

import SwiftUI
import UIKit

struct JobEditorView: View {
    @Bindable var model: JobEditorModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .caption) private var botCell: CGFloat = 76
    @Environment(\.hqGlassSheet) private var onGlass
    @State private var pageWidth: CGFloat = 0
    var pickModel: () -> Void
    var pickBlueprint: () -> Void
    /// A bot's head (the Bot row).
    var head: (String) -> JSONValue? = { _ in nil }

    enum Field: Hashable { case name, prompt, custom, slot(String) }
    @FocusState private var focus: Field?

    /// The device's clock style, for the summary sentence ("9:00 AM" or "09:00").
    private static var uses24Hour: Bool {
        !(DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "").contains("a")
    }

    var body: some View {
        let _ = Theme.touch()   // follows a live toggle of the look
        ScrollViewReader { proxy in
            Form {
                if let failure = model.failure { failureSection(failure) }
                if model.showsBotRow { botSection }
                if offersBlueprints { templateSection }
                if let blueprint = model.blueprint {
                    ForEach(blueprint.fields) { field in slotSection(field) }
                } else {
                    promptSection
                    frequencySection.id("job.editor.when")
                    scheduleSection
                    deliverySections.id("job.editor.deliver")
                    if model.showsModelRow { modelSection }
                }
                if !model.isEdit { runNowSection.id("job.editor.end") }
            }
            .hqGroupedPage()   // [desktoplook] the page follows the skin
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
            .scrollDismissesKeyboard(.interactively)
            .disabled(model.saving)
            .refreshable {
                await model.reloadTargets()
                if model.modelsState == .failed { await model.reloadModels() }
            }
            .onChange(of: model.failureTick) {
                HQMotion.withAnimation(.snappy) { proxy.scrollTo("job.editor.failure", anchor: .top) }
            }
            #if DEBUG
            .task {
                // Screenshots: -HQPagesJobScroll when|deliver|end (PagesDebug).
                guard let place = UserDefaults.standard.string(forKey: "HQPagesJobScroll") else { return }
                try? await Task.sleep(for: .seconds(1.5))
                proxy.scrollTo("job.editor.\(place)", anchor: place == "end" ? .bottom : .top)
            }
            #endif
        }
    }

    private var offersBlueprints: Bool { !model.isEdit && !model.blueprints.isEmpty }

    /// The first section's header carries `job.editor.top` (UI tests scroll back to it).
    private enum Top { case bot, templates, prompt }
    private var top: Top { model.showsBotRow ? .bot : offersBlueprints ? .templates : .prompt }

    /// The cards' distance from the sheet's edges, set on every section, so a strip running edge to edge starts in line
    /// with the cards: iOS's own 16 pt (20 on the widest phones); the Desktop Look's 20.
    private var gutter: CGFloat { Theme.isDesktop || pageWidth >= 414 ? 20 : 16 }
    /// A field's placeholder: `HQPalette.cardNote`, label 2 on the solid card (the system's placeholder read 1.7:1).
    private static var placeholderInk: Color { Color(uiColor: HQPalette.cardNote) }

    // MARK: Top

    private func failureSection(_ failure: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Label("Couldn’t save the job", systemImage: "exclamationmark.triangle.fill")
                    .font(Font.hq(.subheadline).weight(.semibold))
                Text(failure)
                    .font(Font.hq(.subheadline))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Color.hqRed)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("job.editor.failure")
            .listRowBackground(Color(uiColor: HQPalette.sheetCard).overlay(Color.hqRed.opacity(0.12)))
        }
        .jobCard(gutter)
        .id("job.editor.failure")
    }

    /// The bot that runs the job (create, two or more bots): the faces in a row, as New Task's "Who Does It".
    private var botSection: some View {
        Section {
            ScrollViewReader { strip in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: Theme.isDesktop ? 4 : 8) {
                        ForEach(model.bots, id: \.id) { bot in
                            let chosen = model.form.profile == bot.id
                            Button {
                                guard !chosen else { return }
                                PagesHaptics.selection()
                                model.chooseProfile(bot.id)
                            } label: {
                                let shape = RoundedRectangle(cornerRadius: Theme.isDesktop ? DesktopRows.radius : 20, style: .continuous)
                                VStack(spacing: 6) {
                                    HeadImage(raw: head(bot.id), profile: bot.id, size: 44)
                                        .frame(width: 44, height: 44)
                                        .padding(3)
                                    // The largest sizes: one line that shrinks, never a name broken mid-word.
                                    Text(bot.name)
                                        .font(Font.hq(.caption).weight(chosen ? .semibold : .regular))
                                        // On the glass the names are in full ink, the chosen one too (the grey read 3:1 over
                                        // the blur, the tint on the chosen tile's tinted glass 2.2:1 in the dark).
                                        .foregroundStyle(Theme.isDesktop ? (chosen ? Color.hqTintText : Color.hqLabel2) : Color.hqLabel)
                                        .lineLimit(typeSize.isAccessibilitySize ? 1 : 2)
                                        .minimumScaleFactor(typeSize.isAccessibilitySize ? 0.6 : 1)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(width: min(HQFont.scaled(botCell), 150))   // [ui-sizing] UI Scale too, not only the text size
                                .padding(.vertical, Theme.isDesktop ? 4 : 8)
                                .padding(.horizontal, Theme.isDesktop ? 0 : 2)
                                .background(shape.fill(chosen && Theme.isDesktop ? Color.hqTint.opacity(0.14) : .clear))
                                .hqPickGlass(chosen, in: shape)
                                .contentShape(shape)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(bot.name)
                            .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
                            .accessibilityIdentifier("job.editor.bot.\(bot.id)")
                            .id(bot.id)
                        }
                    }
                    .hqPickGlassRow()
                    .jobStripRoom()
                }
                .contentMargins(.horizontal, gutter, for: .scrollContent)
                .jobStripRoomOutside()
                .onAppear { strip.scrollTo(model.form.profile, anchor: .center) }
            }
            .jobStripRow()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Bot")
            .accessibilityIdentifier("job.editor.bot")
        } header: { JobHeader {
            Text("Bot").jobEditorTop(top == .bot)
        }.padding(.horizontal, gutter) }
        .jobStrip()
    }

    /// "Start From" (create): Write Your Own, then every template as a card; See All opens the searchable list.
    private var templateSection: some View {
        Section {
            ScrollViewReader { strip in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        JobTemplateCard(title: "Write Your Own", symbol: "square.and.pencil", selected: model.blueprint == nil,
                                        identifier: "job.editor.card.custom") { choose(nil) }
                            .id("custom")
                        ForEach(model.blueprints) { blueprint in
                            JobTemplateCard(title: blueprint.title, symbol: JobTemplateSymbol.name(blueprint),
                                            selected: model.form.blueprintKey == blueprint.key,
                                            identifier: "job.editor.card.\(blueprint.key)") { choose(blueprint.key) }
                                .id(blueprint.key)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)   // every card as tall as the tallest
                    .hqPickGlassRow()
                    .jobStripRoom()
                }
                .contentMargins(.horizontal, gutter, for: .scrollContent)
                .jobStripRoomOutside()
                // The template already chosen (See All, a job page's template) shows when the sheet opens, as the bot does.
                .onAppear { strip.scrollTo(model.form.blueprintKey ?? "custom", anchor: .center) }
                .onChange(of: model.form.blueprintKey) { _, key in
                    HQMotion.withAnimation(.snappy) { strip.scrollTo(key ?? "custom", anchor: .center) }
                }
            }
            .jobStripRow()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Start from")
            .accessibilityIdentifier("job.editor.start")
        } header: { JobHeader {
            // The largest sizes: See All under the title (beside it, it was cut to "See…").
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Start From").jobEditorTop(top == .templates)
                    Spacer(minLength: 8)
                    seeAll
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("Start From").jobEditorTop(top == .templates)
                    seeAll
                }
            }
        }.padding(.horizontal, gutter) } footer: { HQSectionFooter {
            if let description = model.blueprint?.description, !description.isEmpty {
                Text(description).accessibilityIdentifier("job.editor.start.description")
            }
        }.jobGlassInk().padding(.horizontal, gutter) }
        .jobStrip()
    }

    /// "See All": in the Desktop Look the plain tinted word; on the glass a glass capsule like the picks, its word in
    /// full ink (the tint read 3:1 over the blur, 4.2:1 in the dark).
    @ViewBuilder private var seeAll: some View {
        let button = Button("See All", action: pickBlueprint).textCase(nil).accessibilityIdentifier("job.editor.start.all")
        if Theme.isDesktop {
            button.font(Font.hq(.subheadline)).foregroundStyle(Color.hqTintText).buttonStyle(.borderless)
        } else {
            // Its 30 pt overhang the header's line by 5 pt above and below without making the header taller, so the
            // cards sit as far under "Start From" as every other header's content.
            button.buttonStyle(JobCapsuleButtonStyle()).padding(.vertical, -5)
        }
    }

    private func choose(_ key: String?) {
        guard key != model.form.blueprintKey else { return }
        PagesHaptics.selection()
        focus = nil
        HQMotion.withAnimation(.snappy) { model.chooseBlueprint(key) }
    }

    // MARK: Prompt, name

    private var botName: String { model.botNames[model.form.profile].flatMap { $0.isEmpty ? nil : $0 } ?? "the bot" }

    /// The prompt first (it is the job), then the name, which Hermes makes from the prompt when it is left blank.
    private var promptSection: some View {
        Section {
            if model.scriptOnly {
                Text("This job runs a script on \(HostWord.phrase). It has no AI prompt.")
                    .foregroundStyle(Color.hqLabel2)
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("job.editor.script-note")
            } else {
                TextField("Prompt", text: $model.form.prompt,
                          prompt: Text("What should \(botName) do? For example: summarize my unread Slack threads and email me the top 5.")
                            .foregroundStyle(Self.placeholderInk), axis: .vertical)
                    .lineLimit(4...12)
                    .textInputAutocapitalization(.sentences)
                    .focused($focus, equals: .prompt)
                    .padding(.vertical, 6)
                    .accessibilityLabel("Prompt")
                    .accessibilityIdentifier("job.editor.prompt")
            }
            HStack(spacing: 12) {
                Text("Name").foregroundStyle(Color.hqLabel).accessibilityHidden(true)
                TextField("Name", text: $model.form.name, prompt: Text(model.suggestedName ?? "Optional").foregroundStyle(Self.placeholderInk))
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.words)
                    .focused($focus, equals: .name)
                    .submitLabel(.done)
                    .onSubmit { focus = nil }
                    .accessibilityLabel("Name")
                    .accessibilityIdentifier("job.editor.name")
            }
        } header: { JobHeader {
            Text(model.scriptOnly ? "Script" : "Prompt").jobEditorTop(top == .prompt)
        } } footer: { HQSectionFooter {
            if model.form.name.pgTrim.isEmpty, model.suggestedName != nil {
                Text("Leave the name blank and it’s named after the prompt.").accessibilityIdentifier("job.editor.name.hint")
            }
        }.jobGlassInk() }
        .jobCard(gutter)
    }

    // MARK: Schedule

    /// The time wheel's date: hour and minute on a fixed day in UTC, shown in UTC, so the phone's time zone and
    /// daylight saving never move the stored hour.
    private static func wheelDate(hour: Int, minute: Int) -> Date {
        Date(timeIntervalSinceReferenceDate: TimeInterval(hour * 3600 + minute * 60))
    }

    private static func wheelTime(_ date: Date) -> (hour: Int, minute: Int) {
        let seconds = ((Int(date.timeIntervalSinceReferenceDate.rounded()) % 86400) + 86400) % 86400
        return (seconds / 3600, (seconds % 3600) / 60)
    }

    private var timeBinding: Binding<Date> {
        Binding(get: {
            let fields = model.fields
            return Self.wheelDate(hour: fields.hour, minute: fields.minute)
        }, set: { date in
            var fields = model.fields
            (fields.hour, fields.minute) = Self.wheelTime(date)
            model.setFields(fields)
        })
    }

    private func fieldBinding(_ key: WritableKeyPath<JobTimeFields, Int>) -> Binding<Int> {
        Binding(get: { model.fields[keyPath: key] }, set: { next in
            var fields = model.fields
            fields[keyPath: key] = next
            PagesHaptics.selection()
            model.setFields(fields)
        })
    }

    /// The chip's word: the picker's, shorter where a chip would be long.
    private static func chipTitle(_ frequency: JobFrequency) -> String {
        frequency == .every15 ? "Every 15 Min" : frequency.title
    }

    /// Whether the phone keeps the gateway's clock (then "times follow the computer's clock" says nothing).
    private var sameClockAsHost: Bool { model.hostClock() == .shared }

    private var frequencyStrip: some View {
        ScrollViewReader { strip in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(JobFrequency.allCases) { frequency in
                        JobChip(title: Self.chipTitle(frequency), selected: model.form.frequency == frequency,
                                identifier: "job.editor.frequency.\(frequency.rawValue)") {
                            guard model.form.frequency != frequency else { return }
                            PagesHaptics.selection()
                            focus = frequency == .custom ? .custom : nil
                            HQMotion.withAnimation(.snappy) { model.setFrequency(frequency) }
                        }
                        .id(frequency)
                    }
                }
                .hqPickGlassRow()
                .jobStripRoom()
            }
            .contentMargins(.horizontal, gutter, for: .scrollContent)
            .jobStripRoomOutside()
            .onAppear { strip.scrollTo(model.form.frequency, anchor: .center) }
        }
        .jobStripRow()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Frequency")
        .accessibilityIdentifier("job.editor.frequency")
    }

    /// The frequency chips on the glass, edge to edge, under the Schedule header; the card with the time follows.
    private var frequencySection: some View {
        Section {
            frequencyStrip
        } header: { JobHeader {
            Text("Schedule")
        }
        // The chips and the time card read as one Schedule: no gap between the two sections, so the header takes the
        // list's gap above it itself (the Desktop Look's is 18), and comes 8 pt closer to the chips, which the list's
        // row height centres lower than a card's top.
        .padding(.horizontal, gutter).padding(.top, Theme.isDesktop ? 18 : 6).padding(.bottom, -8) }
        .jobStrip()
        .listSectionSpacing(0)
    }

    private var scheduleSection: some View {
        let frequency = model.form.frequency
        let fields = model.fields
        return Section {
            switch frequency {
            case .weekly:
                JobWeekdayPicker(days: fields.weekdays) { day in
                    if model.toggleWeekday(day) { PagesHaptics.selection() } else { Haptics.play(.warning) }
                }
                .accessibilityIdentifier("job.editor.day")
            case .monthly:
                Picker("Day of the Month", selection: fieldBinding(\.day)) {
                    ForEach(1...31, id: \.self) { Text("\($0)").tag($0) }
                }
                .hqMenuPicker()
                .accessibilityIdentifier("job.editor.monthday")
            case .hourly:
                Picker("Minutes Past the Hour", selection: fieldBinding(\.minute)) {
                    ForEach(JobSchedule.minuteChoices(current: fields.minute), id: \.self) { Text(String(format: ":%02d", $0)).tag($0) }
                }
                .hqMenuPicker()
                .accessibilityIdentifier("job.editor.minute")
            default:
                EmptyView()
            }
            if frequency.isTimed && frequency != .hourly {
                HQDatePicker("Time", selection: timeBinding)
                    .environment(\.timeZone, .gmt)
                    .accessibilityIdentifier("job.editor.time")
            }
            if frequency == .custom {
                TextField("Custom Schedule", text: Binding(get: { model.form.schedule }, set: { model.setCustomSchedule($0) }),
                          prompt: Text(JobSchedule.customPlaceholder).foregroundStyle(Self.placeholderInk))
                    .font(Font.hqSystem(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.asciiCapable)
                    .environment(\.layoutDirection, .leftToRight)
                    .focused($focus, equals: .custom)
                    .submitLabel(.done)
                    .onSubmit { focus = nil }
                    .padding(.vertical, 4)
                    .accessibilityLabel("Custom Schedule")
                    .accessibilityIdentifier("job.editor.custom")
            }
        } footer: { HQSectionFooter {
            VStack(alignment: .leading, spacing: 4) {
                if frequency == .custom {
                    if model.scheduleRejected, let failure = model.failure {
                        Text(failure).foregroundStyle(Color.hqRed).accessibilityIdentifier("job.editor.custom.rejected")
                    } else if let preview = JobSchedule.customPreview(model.form.schedule), !preview.isEmpty {
                        Text(preview).foregroundStyle(Color.hqLabel).accessibilityIdentifier("job.editor.summary")
                    }
                    if let next = model.nextRunWords() { Text(next).accessibilityIdentifier("job.editor.next-run") }
                    Text(JobSchedule.customHint)
                } else {
                    Text(JobSchedule.summary(frequency, expr: model.form.schedule, uses24Hour: Self.uses24Hour))
                        .foregroundStyle(Color.hqLabel)
                        .accessibilityIdentifier("job.editor.summary")
                    if let next = model.nextRunWords() { Text(next).accessibilityIdentifier("job.editor.next-run") }
                    if let skip = JobSchedule.skipNote(frequency, fields) {
                        Text(skip).accessibilityIdentifier("job.editor.skip-note")
                    }
                    if frequency.isTimed && !sameClockAsHost { Text(JobSchedule.clockNote) }
                }
            }
        }.jobGlassInk() }
        .jobCard(gutter)
    }

    // MARK: Delivery, model, run once

    /// A row's mark: Run History's clock, a platform's own mark, a bot's face.
    private func deliveryIcon(_ id: String) -> AnyView {
        if id == JobDelivery.fallback {
            return AnyView(JobSymbolTile(symbol: "clock.arrow.circlepath", size: 28))
        }
        if id.hasPrefix("bot-chat:") {
            let profile = String(id.dropFirst("bot-chat:".count))
            return AnyView(HeadImage(raw: head(profile), profile: profile, size: 28).frame(width: 28, height: 28))
        }
        if id == "origin" { return AnyView(JobSymbolTile(symbol: "arrow.uturn.backward", size: 28)) }
        let platform = id.split(separator: ":").first.map(String.init) ?? id
        return AnyView(PlatformMark(source: platform, size: 28))
    }

    private func deliveryTitle(_ row: DeliveryRow) -> String {
        if row.id.hasPrefix("bot-chat:"), let name = model.botNames[String(row.id.dropFirst("bot-chat:".count))], !name.isEmpty {
            return name
        }
        return row.title
    }

    private func deliveryRow(_ row: DeliveryRow) -> some View {
        JobCheckRow(title: deliveryTitle(row), note: row.note, checked: row.checked, enabled: row.selectable,
                    icon: deliveryIcon(row.id), identifier: "job.editor.deliver.\(row.id)") {
            if model.toggleDelivery(row.id) { PagesHaptics.selection() }
        }
    }

    @ViewBuilder
    private var deliverySections: some View {
        let groups = model.deliveryGroups
        Section {
            ForEach(groups.places) { deliveryRow($0) }
            if model.targetsState == .loading { loadingRow }
        } header: { JobHeader {
            Text("Send Results To")
        } } footer: { HQSectionFooter {
            VStack(alignment: .leading, spacing: 4) {
                if model.targetsState == .failed {
                    placesFailed.accessibilityIdentifier("job.editor.deliver.failed")
                }
                if let note = JobDelivery.needsHomeNote(groups.needsHome) {
                    Text(note).accessibilityIdentifier("job.editor.deliver.needs-home")
                }
                Text("Every result is also kept in the job’s Run History.")
            }
        }.jobGlassInk() }
        .jobCard(gutter)
        if !groups.bots.isEmpty {
            Section {
                ForEach(groups.bots) { deliveryRow($0) }
            } header: { JobHeader {
                Text("Bot Chats")
            } } footer: { HQSectionFooter {
                Text("The bot gets each result in its chat and can act on it.")
            }.jobGlassInk() }
            .jobCard(gutter)
        }
    }

    /// The places to deliver to didn't load. [mac] There is no pull to refresh with a mouse: a Try Again button instead.
    @ViewBuilder private var placesFailed: some View {
        if DeviceWord.isMac {
            HStack(spacing: 6) {
                Text("Couldn’t load the other places.")
                Button("Try Again") { Task { await model.reloadTargets() } }.buttonStyle(.borderless)
            }
        } else {
            Text("Couldn’t load the other places. Pull down to try again.")
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Loading other places…").foregroundStyle(Color.hqLabel2)
        }
        .accessibilityElement(children: .combine)
    }

    private var modelSection: some View {
        Section {
            Button(action: pickModel) {
                HStack(spacing: 8) {
                    Text("Model").foregroundStyle(Color.hqLabel)
                    Spacer(minLength: 8)
                    Text(model.modelWords).foregroundStyle(Color.hqLabel2).multilineTextAlignment(.trailing)
                    SettingsChevron()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Model")
            .accessibilityValue(model.modelWords)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("job.editor.model")
        } footer: { HQSectionFooter {
            // [model-scope] Owner 2026-11-03: a job's model is its own; Default is its bot's.
            Text(JobWords.modelScope(bot: model.botNames[model.form.profile])).accessibilityIdentifier("job.editor.model-scope")
        }.jobGlassInk() }
        .jobCard(gutter)
    }

    /// Create only: the first run starts as soon as the job exists, so its result can be checked right away.
    private var runNowSection: some View {
        Section {
            Toggle("Run Once Now", isOn: Binding(get: { model.form.runNow }, set: { on in
                PagesHaptics.selection()
                model.form.runNow = on
            }))
                .accessibilityIdentifier("job.editor.run-now")
        } footer: { HQSectionFooter {
            Text("Runs it as soon as it’s created, so you can check the result.")
        }.jobGlassInk() }
        .jobCard(gutter)
    }

    // MARK: Blueprint fields

    private func optionalHeader(_ title: String, optional: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            if optional {
                Spacer(minLength: 8)
                // On the glass in full ink, regular against the semibold title (label 3 read under 2:1 over the blur).
                Text("Optional").textCase(nil).fontWeight(.regular)
                    .foregroundStyle(onGlass ? Color(uiColor: HQPalette.glassInk2) : Color.hqLabel3)
            }
        }
    }

    private func slotBinding(_ field: BlueprintField) -> Binding<String> {
        Binding(get: { model.form.slots[field.name] ?? "" }, set: { model.setSlot(field.name, $0) })
    }

    @ViewBuilder
    private func slotSection(_ field: BlueprintField) -> some View {
        let control = JobBlueprints.control(field)
        let value = model.form.slots[field.name] ?? ""
        Section {
            switch control {
            case .time:
                HQDatePicker(field.title, selection: Binding(get: {
                    let time = JobBlueprints.time(value) ?? (hour: 9, minute: 0)
                    return Self.wheelDate(hour: time.hour, minute: time.minute)
                }, set: { date in
                    let time = Self.wheelTime(date)
                    model.setSlot(field.name, JobBlueprints.timeValue(hour: time.hour, minute: time.minute))
                }), displayedComponents: .hourAndMinute)
                .environment(\.timeZone, .gmt)
                .accessibilityIdentifier("job.editor.slot.\(field.name)")
            case .choice:
                Picker(field.title, selection: Binding(get: { value }, set: { next in
                    PagesHaptics.selection()
                    model.setSlot(field.name, next)
                })) {
                    if !field.options.contains(value) {
                        Text(value.isEmpty ? (field.optional ? "None" : "Choose") : JobBlueprints.optionLabel(field, value)).tag(value)
                    } else if field.optional {
                        Text("None").tag("")
                    }
                    ForEach(field.options, id: \.self) { Text(JobBlueprints.optionLabel(field, $0)).tag($0) }
                }
                .hqMenuPicker()
                .accessibilityIdentifier("job.editor.slot.\(field.name)")
            case .deliver:
                ForEach(model.slotDeliveryRows(value).filter { $0.selectable || $0.checked }) { row in
                    JobCheckRow(title: deliveryTitle(row), note: row.note, checked: row.checked, enabled: row.selectable,
                                icon: deliveryIcon(row.id), identifier: "job.editor.slot.\(field.name).\(row.id)") {
                        guard !row.checked else { return }
                        PagesHaptics.selection()
                        model.setSlot(field.name, row.id)
                    }
                }
                if model.targetsState == .loading { loadingRow }
            case .text:
                TextField(field.title, text: slotBinding(field),
                          prompt: Text(JobBlueprints.placeholder(field)).foregroundStyle(Self.placeholderInk), axis: .vertical)
                    .lineLimit(1...6)
                    .focused($focus, equals: .slot(field.name))
                    .padding(.vertical, 2)
                    .accessibilityLabel(field.title)
                    .accessibilityIdentifier("job.editor.slot.\(field.name)")
            }
        } header: { JobHeader {
            if control == .text || control == .deliver {
                optionalHeader(field.title, optional: field.optional).textCase(nil)
            }
        } } footer: { HQSectionFooter {
            if model.failedField == field.name, let failure = model.failure {
                Text(failure).foregroundStyle(Color.hqRed).accessibilityIdentifier("job.editor.slot.\(field.name).error")
            } else if control == .deliver, model.targetsState == .failed {
                placesFailed
            } else if control == .deliver {
                VStack(alignment: .leading, spacing: 4) {
                    if let note = JobDelivery.needsHomeNote(JobDelivery.groups(model.slotDeliveryRows(value)).needsHome) { Text(note) }
                    Text("Every result is also kept in the job’s Run History.")
                }
            } else if let help = JobBlueprints.fieldHelp(field) {
                Text(help)
            }
        }.jobGlassInk() }
        .jobCard(gutter)
    }
}

// MARK: - Pieces

/// A section header on the sheet's glass: the primary label, semibold (the system grey read 3.2:1 over the blur). The
/// Desktop Look keeps its own label.
private struct JobHeader<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if Theme.isDesktop {
            HQSectionLabel { content }
        } else {
            HQSectionLabel { content }.foregroundStyle(Color(uiColor: HQPalette.glassInk2)).fontWeight(.semibold)
        }
    }
}

private extension View {
    /// `job.editor.top` on the form's first header.
    @ViewBuilder func jobEditorTop(_ first: Bool) -> some View {
        if first { accessibilityIdentifier("job.editor.top") } else { self }
    }

    /// A section of rows people read: a solid card on the glass (`hqSheetRows`), `gutter` in from the sheet's edges.
    func jobCard(_ gutter: CGFloat) -> some View {
        listSectionMargins(.horizontal, gutter).hqSheetRows()
    }

    /// A strip's section: edge to edge, so its picks scroll out at the sheet's edges instead of being cut off inside a
    /// card. Its header and footer bring their own `gutter`, and the strip its content margins.
    func jobStrip() -> some View {
        listSectionMargins(.horizontal, 0)
    }

    /// A strip's row: no card behind it (the picks stand on the glass; bare in the Desktop Look, where the clear
    /// background alone still drew the outline round the edge-to-edge strip), no insets.
    func jobStripRow() -> some View {
        listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden).hqDesktopBareRow()
    }

    /// Room inside a strip's scroll view above and below its picks, so the scroll view's clip never cuts a pick's glass
    /// or its press (it grows under the finger); `jobStripRoomOutside` takes it back from the row, so the strip sits
    /// where its picks are. Not `scrollClipDisabled`: unclipped, a pick past the screen's edge counted as on screen,
    /// and UI tests failed to tap it.
    func jobStripRoom() -> some View { padding(.vertical, 6) }
    func jobStripRoomOutside() -> some View { padding(.vertical, -6) }

    /// Words standing on the sheet's glass (a footer): `HQPalette.glassInk2`, the primary label there (the footer's grey
    /// read about 3:1 over the blur), the secondary label off the glass. Words that bring their own colour keep it.
    func jobGlassInk() -> some View {
        foregroundStyle(Color(uiColor: HQPalette.glassInk2))
    }
}

/// A choice chip (the Schedule's frequency): a glass capsule on the sheet's glass, the chosen one the tint's glass; in
/// the Desktop Look the desktop's square-cornered outline, the chosen one on the pressed-row fill (as
/// `DesktopSegmentStrip`).
struct JobChip: View {
    var title: String
    var selected: Bool
    var identifier: String
    var action: () -> Void
    @ScaledMetric(relativeTo: .subheadline) private var height: CGFloat = 36

    var body: some View {
        let desk = Theme.isDesktop
        let shape = RoundedRectangle(cornerRadius: desk ? DesktopRows.radius : min(height, 52) / 2, style: .continuous)
        Button(action: action) {
            Text(title)
                .font(Font.hq(.subheadline).weight(selected ? .semibold : .medium))
                .foregroundStyle(selected && !desk ? Color.hqOnTint : Color.hqLabel)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, desk ? 14 : 16)
                .frame(minHeight: desk ? 34 : min(height, 52))
                .background(shape.fill(desk && selected ? Color(uiColor: HQPalette.cellPressed) : .clear))
                .overlay(shape.strokeBorder(desk ? (selected ? Color.hqLabel3 : Color.hqStroke) : Color.clear, lineWidth: 1))
                .hqPickGlass(selected, in: shape, prominent: true)
                .contentShape(shape)
                // Touched over 44 pt at least.
                .padding(.vertical, desk ? 5 : 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(identifier)
    }
}

/// A template in "Start From": its symbol on a tinted square beside its title, on a glass card on the sheet's glass;
/// the chosen one tinted and ringed. The Desktop Look's flat card, outlined.
struct JobTemplateCard: View {
    var title: String
    var symbol: String
    var selected: Bool
    var identifier: String
    var action: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .subheadline) private var tileSize: CGFloat = 30

    var body: some View {
        let desk = Theme.isDesktop
        let shape = RoundedRectangle(cornerRadius: desk ? DesktopRows.radius : 20, style: .continuous)
        let tile = min(tileSize, 44)
        // The largest sizes stack the icon over the title on a wider card, so the title keeps whole words.
        let stacked = typeSize.isAccessibilitySize
        Button(action: action) {
            let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
            layout {
                Image(systemName: symbol)
                    .font(Font.hqSystem(size: tile * 0.52, weight: .semibold))
                    // The tint's text ink: the plain tint on its 14 % square read 2.4:1 over the dark glass.
                    .foregroundStyle(selected ? Color.hqOnTint : Color.hqTintText)
                    .frame(width: tile, height: tile)
                    .background(RoundedRectangle(cornerRadius: desk ? DesktopRows.radius : tile * 0.27, style: .continuous)
                        .fill(selected ? Color.hqTint : Color.hqTint.opacity(0.14)))
                Text(title)
                    .font(Font.hq(.subheadline).weight(.medium))
                    .foregroundStyle(Color.hqLabel)
                    .lineLimit(stacked ? 3 : 2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, desk ? 10 : 12)
            .padding(.vertical, desk ? 9 : 12)
            .frame(width: stacked ? 280 : 176, alignment: .leading)
            .frame(maxHeight: .infinity)
            .background(shape.fill(desk && selected ? Color.hqTint.opacity(0.12) : .clear))
            .overlay(shape.strokeBorder(desk ? (selected ? Color.hqTint : Color.hqStroke) : Color.clear, lineWidth: selected ? 1.5 : 1))
            .hqPickGlass(selected, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(identifier)
    }
}

/// A small glass capsule standing in a header (See All): full ink, 30 pt tall; the interactive glass answers a press.
private struct JobCapsuleButtonStyle: ButtonStyle {
    @ScaledMetric(relativeTo: .subheadline) private var height: CGFloat = 30

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Font.hq(.subheadline).weight(.semibold))
            .foregroundStyle(Color.hqLabel)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minHeight: min(height, 44))
            .hqPickGlass(false, in: Capsule())
            .contentShape(Capsule())
    }
}

/// Weekly's days, one button each in the week's order for the phone's region; any number of them can be on, never none.
struct JobWeekdayPicker: View {
    /// Cron days, 0 = Sunday.
    var days: [Int]
    var toggle: (Int) -> Void
    @ScaledMetric(relativeTo: .subheadline) private var size: CGFloat = 38

    private var order: [Int] {
        let first = Calendar.current.firstWeekday - 1
        return (0..<7).map { (first + $0) % 7 }
    }

    var body: some View {
        let desk = Theme.isDesktop
        let letters = Calendar.current.veryShortStandaloneWeekdaySymbols
        let side = min(size, 46)
        let shape = RoundedRectangle(cornerRadius: desk ? DesktopRows.radius : side / 2, style: .continuous)
        HStack(spacing: 0) {
            ForEach(order, id: \.self) { day in
                let on = days.contains(day)
                Button { toggle(day) } label: {
                    Text(letters[day])
                        .font(Font.hq(.subheadline).weight(.semibold))
                        .foregroundStyle(on && !desk ? Color.hqOnTint : (on ? Color.hqLabel : Color.hqLabel2))
                        .frame(width: side, height: side)
                        .background(shape.fill(on ? (desk ? Color(uiColor: HQPalette.cellPressed) : Color.hqTint) : (desk ? Color.clear : Color.hqFill3)))
                        .overlay(shape.strokeBorder(desk ? (on ? Color.hqLabel3 : Color.hqStroke) : Color.clear, lineWidth: 1))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(JobWords.days[day])
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("job.editor.weekday.\(day)")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}

/// A symbol on a soft grey tile, the size and corners of `PlatformMark` (Run History's row, a template's list row).
struct JobSymbolTile: View {
    var symbol: String
    var size: CGFloat = 28
    var tint: Color = .hqLabel2

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(tint.opacity(0.16))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol).resizable().scaledToFit().fontWeight(.semibold)
                    .frame(width: size * 0.56, height: size * 0.56)
                    .foregroundStyle(tint)
            }
            .accessibilityHidden(true)
    }
}

/// A template's symbol: Hermes's own templates by key (cron/blueprint_catalog.py), anything else by its category.
enum JobTemplateSymbol {
    private static let byKey: [String: String] = [
        "morning-brief": "sun.horizon", "important-mail": "envelope.badge", "weekly-review": "calendar",
        "workday-start": "briefcase", "custom-reminder": "bell", "evening-winddown": "moon.stars",
        "news-digest": "newspaper", "bill-renewal-watch": "creditcard", "price-watch": "tag",
        "competitor-watch": "binoculars", "habit-checkin": "checkmark.circle", "hydration-move": "drop",
        "meal-plan": "fork.knife", "learn-daily": "graduationcap", "gratitude-journal": "heart.text.square",
        "on-this-day": "clock.arrow.circlepath",
    ]

    static func name(_ blueprint: Blueprint) -> String {
        if let known = byKey[blueprint.key] { return known }
        switch blueprint.category.lowercased() {
        case "daily": return "sun.max"
        case "weekly": return "calendar"
        case "email": return "envelope"
        default: return "sparkles"
        }
    }
}
