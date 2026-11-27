import UIKit

// [travel] Prompt cell hosting for FlightsCardView and HotelsCardView, mirroring ChatPromptCell+Shopping.swift.

@MainActor struct TravelCellViews {
    var flights: FlightsCardView?
    var hotels: HotelsCardView?
    var flightsRow: FlightsCardRow?
    var hotelsRow: HotelsCardRow?
}

extension ChatPromptCell {
    func configureTravel(_ spec: PromptRow, _ l: PromptRowLayout) {
        switch (spec.kind, l.travel) {
        case (.flights(let row), .flights(let g)?):
            let view = travelViews.flights ?? makeFlightsView()
            travelViews.flightsRow = row
            view.isHidden = false
            view.frame = contentView.bounds
            view.configure(row, g)
            travelViews.hotels?.isHidden = true
            travelViews.hotelsRow = nil
        case (.hotels(let row), .hotels(let g)?):
            let view = travelViews.hotels ?? makeHotelsView()
            travelViews.hotelsRow = row
            view.isHidden = false
            view.frame = contentView.bounds
            view.configure(row, g)
            travelViews.flights?.isHidden = true
            travelViews.flightsRow = nil
        default:
            travelViews.flights?.isHidden = true
            travelViews.hotels?.isHidden = true
            travelViews.flightsRow = nil
            travelViews.hotelsRow = nil
        }
    }

    func travelAccessibility() -> [Any]? {
        if travelViews.flightsRow != nil, let view = travelViews.flights { return [view] }
        if travelViews.hotelsRow != nil, let view = travelViews.hotels { return [view] }
        return nil
    }

    func resetTravel() {
        travelViews.flights?.reset()
        travelViews.hotels?.reset()
        travelViews.flightsRow = nil
        travelViews.hotelsRow = nil
    }

    private func makeFlightsView() -> FlightsCardView {
        let view = FlightsCardView()
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.onOpenFlight = { [weak self] index in
            guard let self, let row = self.travelViews.flightsRow else { return }
            self.handler?.travelOpenFlight(row, index: index)
        }
        view.onBookFlight = { [weak self] index in
            guard let self, let row = self.travelViews.flightsRow else { return }
            self.handler?.travelAskFlight(row, index: index, ask: .book)
        }
        view.onFollowUp = { [weak self] text in
            guard let self, let row = self.travelViews.flightsRow else { return }
            self.handler?.travelFollowUp(rowId: row.rowId, text: text)
        }
        view.onToggle = { [weak self] in
            guard let self, let row = self.travelViews.flightsRow else { return }
            self.handler?.draftCardToggle(rowId: row.rowId)
        }
        contentView.addSubview(view)
        travelViews.flights = view
        return view
    }

    private func makeHotelsView() -> HotelsCardView {
        let view = HotelsCardView()
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.onOpenHotel = { [weak self] index in
            guard let self, let row = self.travelViews.hotelsRow else { return }
            self.handler?.travelOpenHotel(row, index: index)
        }
        view.onFollowUp = { [weak self] text in
            guard let self, let row = self.travelViews.hotelsRow else { return }
            self.handler?.travelFollowUp(rowId: row.rowId, text: text)
        }
        contentView.addSubview(view)
        travelViews.hotels = view
        return view
    }
}
