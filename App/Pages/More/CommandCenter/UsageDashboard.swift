// [mac-tools] Usage on the Mac, as a dashboard across the window (owner 2026-11-09, the Tools sketch: "a dashboard
// across the window, not Settings cards in a strip"). The period is a switch at the top right; four tiles give the
// totals with what they come to a day; the daily chart runs the window's width, splits a day's tokens into what was
// read and what was written, switches to sessions, and names the day under the pointer; the models and the skills
// stand side by side, each row with a bar for its share. Narrower than `UsageDashboard.wideAt`, or with nothing used
// yet, the page is the list it was. iPhone and iPad keep the list.

import Charts
import SwiftUI
import UIKit

struct UsageDashboard: View {
    @Bindable var model: UsagePageModel
    var usage: UsageReport
    @State private var metric = Metric.tokens
    @State private var hovered: UsageReport.Day?

    enum Metric: String, CaseIterable, Identifiable {
        case tokens = "Tokens", sessions = "Sessions"
        var id: String { rawValue }
    }

    /// The page is drawn at 77 % on the Mac: about 740 pt of window.
    static let wideAt: CGFloat = 960

    private static let dayFormat = Date.FormatStyle.dateTime.month(.abbreviated).day()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headline
                tiles
                if !usage.daily.isEmpty { chartCard }
                HStack(alignment: .top, spacing: 16) {
                    if !usage.models.isEmpty { modelsCard }
                    if !usage.skills.isEmpty { skillsCard }
                }
            }
            .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 28)
        }
        .background(Color.hqGroupedPage)
        .refreshable { await model.read() }
        .accessibilityIdentifier("more-usage.dashboard")
    }

    // MARK: The headline

    private var headline: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Last \(model.shownDays) Days").font(Font.hq(.title2).weight(.bold)).foregroundStyle(Color.hqLabel)
                    .accessibilityAddTraits(.isHeader)
                Text("Every bot on this gateway, together.").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                if model.refreshFailed {
                    HStack(spacing: 10) {
                        Text(model.refreshFailedText).font(Font.hq(.footnote)).foregroundStyle(Color.hqOrange)
                        Button("Try Again") { model.retry() }.hqMacBordered().fixedSize()
                    }
                    .accessibilityIdentifier("more-usage.refresh-failed")
                }
            }
            Spacer(minLength: 12)
            if model.busy { ProgressView().controlSize(.small) }
            HQSegmentedPicker("Period", options: [7, 30, 90].map { (title: "\($0) Days", value: $0) }, selection: $model.days, ticks: false)   // `days` ticks as it changes
                .labelsHidden()
            .frame(width: 330)
            .accessibilityIdentifier("more-usage.period")
        }
        .padding(.vertical, 4)
    }

    // MARK: The tiles

    private var tiles: some View {
        let days = max(1, usage.daily.isEmpty ? usage.periodDays : usage.daily.count)
        let input = usage.daily.reduce(0) { $0 + $1.input }, output = usage.daily.reduce(0) { $0 + $1.output }
        let peak = usage.daily.max { $0.tokens < $1.tokens }.flatMap { $0.tokens > 0 ? $0 : nil }
        return HStack(spacing: 16) {
            MacDashTile(title: "Tokens", value: UsageFormat.compact(usage.tokens),
                        note: input + output > 0 ? "\(UsageFormat.compact(input)) read · \(UsageFormat.compact(output)) written" : nil)
                .accessibilityIdentifier("more-usage.tile.tokens")
            MacDashTile(title: "Sessions", value: usage.sessions.map { UsageFormat.compact($0) } ?? "—",
                        note: usage.sessions.map { "about \(max(1, Int((Double($0) / Double(days)).rounded()))) a day" })
                .accessibilityIdentifier("more-usage.tile.sessions")
            MacDashTile(title: "Estimated Cost", value: UsageFormat.cost(usage.cost),
                        note: usage.cost.map { "about \(UsageFormat.cost($0 / Double(days))) a day" })
                .accessibilityIdentifier("more-usage.tile.cost")
            MacDashTile(title: "Busiest Day", value: peak.map { $0.date.formatted(Self.dayFormat) } ?? "—",
                        note: peak.map { "\(UsageFormat.compact($0.tokens)) tokens · \(UsageFormat.sessions($0.sessions))" })
                .accessibilityIdentifier("more-usage.tile.peak")
        }
    }

    // MARK: The chart

    private var chartCard: some View {
        MacDashCard(title: metric == .tokens ? "Daily Tokens" : "Daily Sessions") {
            Group {
                if let day = hovered {
                    Text("\(day.date.formatted(Self.dayFormat)) · \(UsageFormat.compact(day.tokens)) tokens · \(UsageFormat.sessions(day.sessions))")
                        .foregroundStyle(Color.hqLabel).monospacedDigit()
                } else if metric == .tokens {
                    HStack(spacing: 14) {
                        key("Read", Color.hqTint)
                        key("Written", Color.hqTint.opacity(0.45))
                    }
                }
            }
            .font(Font.hq(.footnote))
            HQSegmentedPicker("Show", options: Metric.allCases.map { (title: $0.rawValue, value: $0) }, selection: $metric)
                .labelsHidden()
            .frame(width: 220)
            .accessibilityIdentifier("more-usage.metric")
        } content: {
            UsageDashChart(report: usage, metric: metric, hovered: $hovered)
                .frame(height: 320)
        }
    }

    private func key(_ word: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(word).foregroundStyle(Color.hqLabel2)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Models and skills

    private var modelsCard: some View {
        let rows = Array(usage.models.prefix(12))
        let top = max(1, rows.map(\.tokens).max() ?? 1)
        let all = max(1, usage.models.reduce(0) { $0 + $1.tokens })
        return MacDashCard(title: "By Model") {
            Text("\(usage.models.count) \(usage.models.count == 1 ? "model" : "models")").font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
        } content: {
            VStack(spacing: 14) {
                ForEach(rows) { row in
                    let percent = Int((Double(row.tokens) / Double(all) * 100).rounded())
                    share(name: row.id, value: UsageFormat.compact(row.tokens), part: Double(row.tokens) / Double(top),
                          note: ([row.sessions.map { UsageFormat.sessions($0) }, row.cost.map { UsageFormat.cost($0) }].compactMap { $0 }
                                 + ["\(percent)% of tokens"]).joined(separator: " · "))
                        .accessibilityLabel("\(row.id), \(UsageFormat.compact(row.tokens)) tokens, \(UsageFormat.sessions(row.sessions))")
                }
            }
        }
    }

    private var skillsCard: some View {
        let rows = Array(usage.skills.prefix(12))
        let top = max(1, rows.map(\.count).max() ?? 1)
        return MacDashCard(title: "Top Skills") {
            Text("by how often bots used them").font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
        } content: {
            VStack(spacing: 14) {
                ForEach(rows) { row in
                    share(name: row.id, value: UsageFormat.actions(row.count), part: Double(row.count) / Double(top), note: nil)
                }
            }
        }
    }

    /// One row of a share list: its name and number, a bar as long as its share of the largest, a line under it.
    private func share(name: String, value: String, part: Double, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(name).font(Font.hq(.body)).foregroundStyle(Color.hqLabel).lineLimit(1)
                Spacer(minLength: 8)
                Text(value).font(Font.hq(.body)).foregroundStyle(Color.hqLabel).monospacedDigit()
            }
            Capsule().fill(Color(uiColor: HQPalette.separator)).frame(height: 6)
                .overlay(alignment: .leading) {
                    GeometryReader { box in
                        Capsule().fill(Color.hqTint).frame(width: max(6, box.size.width * min(1, max(0, part))))
                    }
                }
                .accessibilityHidden(true)
            if let note { Text(note).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2).lineLimit(1) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The dashboard's chart: a bar a day, a day's tokens split into read and written, the day under the pointer told
/// to the card's heading.
struct UsageDashChart: View {
    var report: UsageReport
    var metric: UsageDashboard.Metric
    @Binding var hovered: UsageReport.Day?

    var body: some View {
        Chart {
            ForEach(report.daily) { day in
                let dim = hovered == nil || hovered?.id == day.id ? 1.0 : 0.35
                if metric == .tokens {
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value("Tokens", day.input))
                        .foregroundStyle(Color.hqTint).opacity(dim)
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value("Tokens", day.output))
                        .foregroundStyle(Color.hqTint.opacity(0.45)).opacity(dim)
                } else {
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value("Sessions", day.sessions))
                        .foregroundStyle(Color.hqTint).opacity(dim)
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let count = value.as(Int.self) { Text(UsageFormat.compact(count)) }
                }
                .font(Font.hq(.caption))   // Mac polish 2026-11-06 #103: the app's caption, not the chart's smaller one
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 8)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .font(Font.hq(.caption))
            }
        }
        .chartOverlay { proxy in
            GeometryReader { box in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            guard let frame = proxy.plotFrame.map({ box[$0] }),
                                  let date: Date = proxy.value(atX: point.x - frame.minX) else { hovered = nil; return }
                            hovered = report.daily.first { Calendar.current.isDate($0.date, inSameDayAs: date) }
                        case .ended:
                            hovered = nil
                        }
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(report.chartSummary())
        .accessibilityChartDescriptor(UsageChartDescriptor(report: report))
        .accessibilityIdentifier("more-usage.chart")
    }
}
