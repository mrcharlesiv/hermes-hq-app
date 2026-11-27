import UIKit

// [travel] Chat screen handlers for `show_flights` and `show_hotels`, mirroring ChatViewController+Shopping.swift.

extension ChatViewController {
    var travelQueuedTexts: [String] {
        (session as? LiveChatSession)?.queuedMessages.map(\.text).filter {
            $0.hasPrefix(TravelCards.lead)
        } ?? []
    }

    func travelMessagesToRebuild() -> [String] {
        let messages = session.messages
        let now = TravelCards.answers(messages, queued: travelQueuedTexts)
        guard now != travelAnswersShown else { return [] }
        travelAnswersShown = now
        return messages.filter { m in
            m.role == .assistant && m.parts.contains { part in
                guard case .tool(let call) = part else { return false }
                return TravelCards.tools.contains(call.name)
            }
        }.map(\.id)
    }

    // MARK: ChatPromptCellHandling

    func travelOpenFlight(_ card: FlightsCardRow, index: Int) {
        guard card.flights.flights.indices.contains(index) else { return }
        let flight = card.flights.flights[index]
        AppLog.trace("travel", "flight \(AppLog.tag(flight.id)) opened \(logTag)")
        FlightDetailSheet.present(flight, asks: card.asks(flight), bookingLocked: card.bookingInFlight, from: self) { [weak self] ask in
            self?.travelAskFlight(card, index: index, ask: ask)
        }
    }

    func travelAskFlight(_ card: FlightsCardRow, index: Int, ask: TravelCards.Ask) {
        guard card.flights.flights.indices.contains(index) else { return }
        let flight = card.flights.flights[index]
        guard !card.asks(flight).contains(ask) else { return }
        if ask == .book && card.bookingInFlight { return }
        AppLog.trace("travel", "flight \(AppLog.tag(flight.id)) \(ask.rawValue) \(logTag)")
        Haptics.play(.selection)
        let text = TravelCards.message(ask, flight: flight)
        sendFromCard(text, display: text)
        rebuildMessage(card.messageId)
    }

    func travelOpenHotel(_ card: HotelsCardRow, index: Int) {
        guard card.hotels.hotels.indices.contains(index) else { return }
        let hotel = card.hotels.hotels[index]
        AppLog.trace("travel", "hotel \(AppLog.tag(hotel.id)) opened \(logTag)")
        HotelDetailSheet.present(hotel, asks: card.asks(hotel), bookingLocked: card.bookingInFlight, from: self) { [weak self] ask in
            self?.travelAskHotel(card, index: index, ask: ask)
        }
    }

    func travelAskHotel(_ card: HotelsCardRow, index: Int, ask: TravelCards.Ask) {
        guard card.hotels.hotels.indices.contains(index) else { return }
        let hotel = card.hotels.hotels[index]
        guard !card.asks(hotel).contains(ask) else { return }
        if ask == .book && card.bookingInFlight { return }
        AppLog.trace("travel", "hotel \(AppLog.tag(hotel.id)) \(ask.rawValue) \(logTag)")
        Haptics.play(.selection)
        let text = TravelCards.message(ask, hotel: hotel)
        sendFromCard(text, display: text)
        rebuildMessage(card.messageId)
    }

    func travelFollowUp(rowId: String, text: String) {
        sendFromCard(text, display: text)
    }
}
