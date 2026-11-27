// [travel] Flight detail sheet: route & schedule, expandable fare/bag/change/refund policies, multi-leg segments,
// Why It Fits, Cautions, Book Flight (auto-hidden once booking is requested), Watch Price, and Open Site.

import SwiftUI
import UIKit

enum FlightDetailSheet {
    @discardableResult
    static func present(_ flight: TravelCards.Flight,
                        asks: Set<TravelCards.Ask>,
                        bookingLocked: Bool,
                        from vc: UIViewController,
                        onAsk: @escaping (TravelCards.Ask) -> Void) -> UIViewController {
        let host = UIHostingController(rootView: HQScaledRoot(FlightDetailView(
            flight: flight,
            asks: asks,
            bookingLocked: bookingLocked,
            onAsk: { ask in
                vc.dismiss(animated: true) { onAsk(ask) }
            },
            onOpenSite: {
                LinkOpener.open(flight.url, from: vc)
            }
        )))
        let sheet = ChatSheet.wrap(host, title: flight.routeLabel, detents: [.medium(), .large()])
        #if targetEnvironment(macCatalyst)
        SheetStyle.macPage(sheet, width: 620, from: vc)
        #else
        SheetStyle.widen(sheet, to: 620, from: vc)
        #endif
        vc.present(sheet, animated: true)
        return sheet
    }
}

private struct FlightDetailView: View {
    let flight: TravelCards.Flight
    let asks: Set<TravelCards.Ask>
    let bookingLocked: Bool
    let onAsk: (TravelCards.Ask) -> Void
    let onOpenSite: () -> Void
    @State private var rulesExpanded = true

    private var hasRules: Bool {
        !flight.carryOn.isEmpty || !flight.checkedBag.isEmpty || !flight.changeRule.isEmpty || !flight.refundRule.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                headerCard
                if !flight.segments.isEmpty { segmentsCard }
                if hasRules { rulesCard }
                if !flight.why.isEmpty || !flight.caution.isEmpty { notesCard }
                actionsSection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(uiColor: HQPalette.sheetPage))
        .accessibilityIdentifier("travel.flight.sheet")
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(flight.airline + (flight.flightNumber.isEmpty ? "" : " · \(flight.flightNumber)"))
                        .font(Font.hq(.subheadline).weight(.semibold))
                        .foregroundStyle(Color.hqLabel2)
                    Text("\(flight.departTime) – \(flight.arriveTime)")
                        .font(Font.hq(.title3).weight(.semibold))
                        .foregroundStyle(Color.hqLabel)
                    Text([flight.duration, flight.stopsLabel, flight.cabin, flight.fareTier].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqLabel2)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(ShoppingCards.price(flight.price, currency: flight.currency))
                        .font(Font.hq(.title3).weight(.bold))
                        .foregroundStyle(Color.hqLabel)
                    if let was = flight.was {
                        Text(ShoppingCards.price(was, currency: flight.currency))
                            .font(Font.hq(.caption))
                            .strikethrough()
                            .foregroundStyle(Color.hqLabel2)
                    }
                    if !flight.badge.isEmpty {
                        Text(flight.badge)
                            .font(Font.hq(.caption2).weight(.semibold))
                            .foregroundStyle(Color.hqTint)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.hqTint.opacity(0.14), in: .capsule)
                    }
                }
            }
        }
        .padding(14)
        .background(Color(uiColor: HQPalette.sheetCard), in: .rect(cornerRadius: HQShape.radius(16, .card)))
    }

    private var segmentsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ITINERARY")
                .font(Font.hq(.caption).weight(.semibold))
                .foregroundStyle(Color.hqLabel2)
            ForEach(Array(flight.segments.enumerated()), id: \.offset) { idx, seg in
                if idx > 0 { Divider() }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(seg.origin) → \(seg.destination)")
                            .font(Font.hq(.subheadline).weight(.semibold))
                            .foregroundStyle(Color.hqLabel)
                        Spacer()
                        Text(seg.duration)
                            .font(Font.hq(.footnote))
                            .foregroundStyle(Color.hqLabel2)
                    }
                    Text("\(seg.departTime) – \(seg.arriveTime)" + (seg.flightNumber.isEmpty ? "" : " · \(seg.airline) \(seg.flightNumber)"))
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqLabel2)
                    if !seg.layover.isEmpty {
                        Text(seg.layover)
                            .font(Font.hq(.caption).weight(.medium))
                            .foregroundStyle(Color.hqOrange)
                    }
                }
            }
        }
        .padding(14)
        .background(Color(uiColor: HQPalette.sheetCard), in: .rect(cornerRadius: HQShape.radius(16, .card)))
    }

    private var rulesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                if HQMotion.reduced { rulesExpanded.toggle() }
                else { withAnimation(HQMotion.swiftUI(.easeInOut(duration: HQMotion.quick))) { rulesExpanded.toggle() } }
            } label: {
                HStack {
                    Text("BAGS, CHANGES & REFUNDS")
                        .font(Font.hq(.caption).weight(.semibold))
                        .foregroundStyle(Color.hqLabel2)
                    Spacer()
                    Image(systemName: rulesExpanded ? "chevron.up" : "chevron.down")
                        .font(Font.hq(.caption).weight(.semibold))
                        .foregroundStyle(Color.hqLabel2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("travel.flight.rulesToggle")

            if rulesExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    if !flight.carryOn.isEmpty { ruleRow(icon: "bag", title: "Carry-on", value: flight.carryOn) }
                    if !flight.checkedBag.isEmpty { ruleRow(icon: "suitcase", title: "Checked bag", value: flight.checkedBag) }
                    if !flight.changeRule.isEmpty { ruleRow(icon: "arrow.triangle.2.circlepath", title: "Changes", value: flight.changeRule) }
                    if !flight.refundRule.isEmpty { ruleRow(icon: "arrow.uturn.backward.circle", title: "Refunds", value: flight.refundRule) }
                }
            }
        }
        .padding(14)
        .background(Color(uiColor: HQPalette.sheetCard), in: .rect(cornerRadius: HQShape.radius(16, .card)))
    }

    private func ruleRow(icon: String, title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(Font.hq(.footnote))
                .foregroundStyle(Color.hqTint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Font.hq(.caption).weight(.semibold)).foregroundStyle(Color.hqLabel2)
                Text(value).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !flight.why.isEmpty {
                Text("WHY IT FITS").font(Font.hq(.caption).weight(.semibold)).foregroundStyle(Color.hqLabel2)
                ForEach(flight.why, id: \.self) { line in
                    Label(line, systemImage: "checkmark.circle.fill")
                        .font(Font.hq(.subheadline))
                        .foregroundStyle(Color.hqLabel)
                }
            }
            if !flight.caution.isEmpty {
                Text("THINGS TO NOTE").font(Font.hq(.caption).weight(.semibold)).foregroundStyle(Color.hqOrange)
                ForEach(flight.caution, id: \.self) { line in
                    Label(line, systemImage: "exclamationmark.triangle.fill")
                        .font(Font.hq(.subheadline))
                        .foregroundStyle(Color.hqLabel)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(uiColor: HQPalette.sheetCard), in: .rect(cornerRadius: HQShape.radius(16, .card)))
    }

    private var actionsSection: some View {
        VStack(spacing: 10) {
            if asks.contains(.book) {
                Label("Booking requested", systemImage: "checkmark.circle.fill")
                    .font(Font.hq(.subheadline).weight(.semibold))
                    .foregroundStyle(Color.hqLabel2)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color(uiColor: HQPalette.sheetCard), in: .capsule)
                    .accessibilityIdentifier("travel.flight.booked")
            } else if !bookingLocked {
                Button {
                    onAsk(.book)
                } label: {
                    Text("Book Flight · \(ShoppingCards.price(flight.price, currency: flight.currency))")
                        .font(Font.hq(.body).weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .hqProminentButtonStyle()
                .accessibilityIdentifier("travel.flight.book")
            }
            HStack(spacing: 10) {
                if asks.contains(.watchPrice) {
                    Label("Watching fare", systemImage: "bell.fill")
                        .font(Font.hq(.footnote).weight(.semibold))
                        .foregroundStyle(Color.hqLabel2)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(Color(uiColor: HQPalette.sheetCard), in: .capsule)
                } else {
                    Button {
                        onAsk(.watchPrice)
                    } label: {
                        Label("Watch Fare", systemImage: "bell")
                            .font(Font.hq(.subheadline).weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .hqBorderedButtonStyle()
                    .accessibilityIdentifier("travel.flight.watch")
                }
                Button {
                    onOpenSite()
                } label: {
                    Label("Open Site", systemImage: "safari")
                        .font(Font.hq(.subheadline).weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .hqBorderedButtonStyle()
                .accessibilityIdentifier("travel.flight.site")
            }
        }
    }
}
