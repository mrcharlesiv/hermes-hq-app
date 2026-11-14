// More › Usage (docs/spec/3x-morepages.md §15, D-M12): the gateway's usage over 7, 30 or 90 days, every bot together.
// A period menu, three tiles, "Daily Tokens" as a Swift Charts bar chart (one VoiceOver element with a summary and an
// audio graph), By Model and Top Skills.
// [status-page] It was Command Center's Usage tab; a page of its own beside Status & Maintenance (owner 2026-11-03: one
// home per page). Not the chat's Usage & Limits (that chat's plan allowances) or its Full Usage Report (that chat's
// /usage): this is the whole gateway's history, which neither shows.

import Accessibility
import Charts
import SwiftUI
import UIKit

extension MorePages {
    static func installUsage() {
        factories["usage"] = { context in UsagePage.make(context: context) }
    }
}

@MainActor
enum UsagePage {
    static func make(context: MorePages.Context) -> UIViewController {
        let model = UsagePageModel(api: CommandCenterAPI(client: context.client))
        let page = MorePageController(title: CommandCenterNames.usage, identifier: "more-usage.page", UsagePageView(model: model))
        page.retained = [model]
        page.keyRefresh = { [weak model] in Task { await model?.read() } }   // [Mac UI check 2026-11-13] ⌘R, as a pull (the Mac has no pull)
        page.onAppear = { [weak model] in model?.appear() }
        return page
    }
}

@MainActor @Observable
final class UsagePageModel {
    enum Load: Equatable {
        case loading
        case ready
        case failed(String)
    }

    @ObservationIgnored let api: CommandCenterAPI

    var days = 30 {
        didSet { if days != oldValue { PagesHaptics.selection(); Task { await read() } } }   // a pick (spec 1x §2.6)
    }
    /// The period the numbers on screen are for (a failed read for another period leaves them).
    private(set) var shownDays = 30
    private(set) var usage: UsageReport?
    private(set) var load: Load = .loading
    private(set) var busy = false
    private(set) var refreshFailed = false
    @ObservationIgnored private var readSerial = 0
    @ObservationIgnored private var appeared = false

    init(api: CommandCenterAPI) {
        self.api = api
    }

    func appear() {
        guard !appeared else { return }
        appeared = true
        Task { await read() }
    }

    /// The newest period asked wins, whatever order the answers land in.
    func read() async {
        readSerial += 1
        let serial = readSerial, asked = days
        busy = true
        defer { if serial == readSerial { busy = false } }
        do {
            let report = try await api.usage(days: asked)
            guard serial == readSerial else { return }
            usage = report
            shownDays = asked
            load = .ready
            refreshFailed = false
        } catch {
            guard serial == readSerial else { return }
            if usage == nil { load = .failed(PagesREST.reason(error)) } else { refreshFailed = true }
        }
    }

    /// Audit 863 (08d-5): the line over numbers a refresh couldn't replace, naming their period when another was picked.
    var refreshFailedText: String {
        shownDays == days ? "Couldn’t refresh. Showing the last numbers."
            : "Couldn’t load \(days) days. Showing the last \(shownDays) days."
    }

    func retry() {
        if usage == nil { load = .loading }
        Task { await read() }
    }
}

// MARK: - The page

struct UsagePageView: View {
    @Bindable var model: UsagePageModel
    /// [mac-tools] The page's width: wide enough on the Mac, it is the dashboard (UsageDashboard.swift).
    @State private var width: CGFloat = 0

    var body: some View {
        Group {
            switch model.load {
            case .loading:
                MoreSkeleton(label: "Loading \(CommandCenterNames.usage)…") { model.retry() }
            case .failed(let reason):
                MoreErrorState(title: "Couldn’t Load \(CommandCenterNames.usage)", reason: reason) { model.retry() }
            case .ready where DeviceWord.isMac && width >= UsageDashboard.wideAt && model.usage?.isEmpty == false:
                if let usage = model.usage { UsageDashboard(model: model, usage: usage) }
            case .ready:
                List { UsageSections(model: model) }
                    .hqMacForm()   // [mac] Stress test 2026-10-28 #8: the rows at a readable width
                    .hqGroupedPage()
                    .listStyle(.insetGrouped)
                    .contentMargins(.top, MacInset.top(otherwise: 0), for: .scrollContent)   // [mac] Stress test 2026-10-28 #53
                    .refreshable { await model.read() }
                    .accessibilityIdentifier("more-usage.list")
            }
        }
        .background(Color.hqGroupedPage)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

struct UsageSections: View {
    @Bindable var model: UsagePageModel
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Section {
            Picker(selection: $model.days) {
                ForEach([7, 30, 90], id: \.self) { Text("\($0) Days").tag($0) }
            } label: {
                HStack(spacing: 8) {
                    Text("Period").foregroundStyle(Color.hqLabel)
                    if model.busy { ProgressView().controlSize(.small) }
                }
            }
            .hqMenuPicker()
            .accessibilityIdentifier("more-usage.period")
        }
        if model.refreshFailed {
            Section {
                HStack(spacing: 12) {
                    Text(model.refreshFailedText).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Try Again") { model.retry() }.hqBorderedButtonStyle()
                }
                .padding(.vertical, 3)
                .accessibilityIdentifier("more-usage.refresh-failed")
            }
        }
        if let usage = model.usage {
            if usage.isEmpty {
                Section {
                    ContentUnavailableView {
                        UnavailableTitle("No Usage Yet", systemImage: "chart.bar")   // [mac] Stress test 2026-10-28 #52
                    } description: {
                        Text("Usage shows up after your bots have worked.").hqMacFont(MacType.emptyBodyFont)
                    }
                        .padding(.vertical, 24)
                        .listRowBackground(Color.clear)
                        .hqDesktopBareRow()   // Mac polish 2026-11-06 #104: on the page, not in an empty outlined box
                        .accessibilityIdentifier("more-usage.empty")
                }
            } else {
                Section { tiles(usage) }
                if !usage.daily.isEmpty {
                    Section {
                        UsageChart(report: usage)
                            .frame(height: 190)
                            .padding(.vertical, 8)
                    } header: { HQSectionLabel {
                        Text("Daily Tokens")
                    } }
                }
                if !usage.models.isEmpty {
                    Section {
                        ForEach(usage.models.prefix(12)) { row in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(row.id).foregroundStyle(Color.hqLabel).lineLimit(2)
                                    Text([row.sessions.map { UsageFormat.sessions($0) }, row.cost.map { UsageFormat.cost($0) }]
                                        .compactMap { $0 }.joined(separator: " · "))
                                        .font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                                }
                                Spacer(minLength: 8)
                                Text(UsageFormat.compact(row.tokens)).foregroundStyle(Color.hqLabel2).monospacedDigit()
                            }
                            .padding(.vertical, 6)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(row.id), \(UsageFormat.compact(row.tokens)) tokens, \(UsageFormat.sessions(row.sessions))")
                        }
                    } header: { HQSectionLabel {
                        Text("By Model")
                    } }
                }
                if !usage.skills.isEmpty {
                    Section {
                        ForEach(usage.skills.prefix(12)) { row in
                            LabeledContent(row.id, value: UsageFormat.actions(row.count))
                        }
                    } header: { HQSectionLabel {
                        Text("Top Skills")
                    } }
                }
            }
        }
    }

    @ViewBuilder private func tiles(_ usage: UsageReport) -> some View {
        let items = [("Tokens", UsageFormat.compact(usage.tokens), "tokens"), ("Sessions", usage.sessions.map { UsageFormat.compact($0) } ?? "—", "sessions"),
                     ("Est. Cost", UsageFormat.cost(usage.cost), "cost")]
        // One card, three numbers side by side (stacked at accessibility sizes, where three no longer fit a row).
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 8))
        layout {
            ForEach(items, id: \.0) { title, value, key in
                VStack(alignment: .leading, spacing: 3) {
                    Text(value).font(Font.hq(.title2).weight(.semibold)).foregroundStyle(Color.hqLabel)
                        .lineLimit(1).minimumScaleFactor(0.7).monospacedDigit()
                    Text(title).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title == "Est. Cost" ? "Estimated cost" : title)
                .accessibilityValue(value)
                .accessibilityIdentifier("more-usage.tile.\(key)")
            }
        }
        .padding(.vertical, 8)
    }
}

/// "Daily Tokens": one bar a day.
struct UsageChart: View {
    var report: UsageReport
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        Chart(report.daily) { day in
            BarMark(x: .value("Day", day.date, unit: .day), y: .value("Tokens", day.tokens))
                .foregroundStyle(Color.hqTint)
                .cornerRadius(2)
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let tokens = value.as(Int.self) { Text(UsageFormat.compact(tokens)) }
                }
                #if targetEnvironment(macCatalyst)
                // [mac] Mac polish 2026-11-06 #103: the app's caption, 10 pt on the Mac's screen; the chart's own came
                // out at 8.5 to 9 pt at the Mac's 77 %, the smallest text in the app.
                .font(Font.hq(.caption))
                #endif
            }
        }
        .chartXAxis {
            // Large dates would run into each other.
            AxisMarks(values: .automatic(desiredCount: textSize.isAccessibilitySize ? 2 : 4)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                #if targetEnvironment(macCatalyst)
                .font(Font.hq(.caption))   // [mac] Mac polish 2026-11-06 #103, as the token labels
                #endif
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(report.chartSummary())
        .accessibilityChartDescriptor(UsageChartDescriptor(report: report))
        .accessibilityIdentifier("more-usage.chart")
    }
}

/// VoiceOver's audio graph of the daily tokens.
struct UsageChartDescriptor: AXChartDescriptorRepresentable {
    var report: UsageReport

    func makeChartDescriptor() -> AXChartDescriptor {
        let format = Date.FormatStyle.dateTime.month(.abbreviated).day()
        let labels = report.daily.map { $0.date.formatted(format) }
        let top = Double(report.daily.map(\.tokens).max() ?? 0)
        let x = AXCategoricalDataAxisDescriptor(title: "Day", categoryOrder: labels)
        let y = AXNumericDataAxisDescriptor(title: "Tokens", range: 0...max(top, 1), gridlinePositions: []) { UsageFormat.compact(Int($0)) }
        let series = AXDataSeriesDescriptor(name: "Daily tokens", isContinuous: false,
                                            dataPoints: zip(labels, report.daily).map { AXDataPoint(x: $0, y: Double($1.tokens)) })
        return AXChartDescriptor(title: "Daily Tokens", summary: report.chartSummary(), xAxis: x, yAxis: y, additionalAxes: [], series: [series])
    }

    func updateChartDescriptor(_ descriptor: AXChartDescriptor) {}
}
