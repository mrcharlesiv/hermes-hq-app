import UIKit

// [travel] Chat rows for `show_flights` and `show_hotels`, mirroring App/Shopping/ShoppingRows.swift.

nonisolated struct FlightsCardRow: Sendable, Hashable {
    var flights: TravelCards.Flights
    var rowId: String
    var messageId: String
    /// Flight id → asks already sent in this chat.
    var asked: [String: Set<TravelCards.Ask>]
    var expanded: Bool
    /// True while a booking ask has been sent for any flight in this card (auto-hides other Book buttons).
    var bookingInFlight: Bool { asked.values.contains { $0.contains(.book) } }

    func asks(_ flight: TravelCards.Flight) -> Set<TravelCards.Ask> { asked[flight.id] ?? [] }
}

nonisolated struct HotelsCardRow: Sendable, Hashable {
    var hotels: TravelCards.Hotels
    var rowId: String
    var messageId: String
    /// Hotel id → asks already sent in this chat.
    var asked: [String: Set<TravelCards.Ask>]
    var expanded: Bool
    var bookingInFlight: Bool { asked.values.contains { $0.contains(.book) } }

    func asks(_ hotel: TravelCards.Hotel) -> Set<TravelCards.Ask> { asked[hotel.id] ?? [] }
}

nonisolated enum TravelRowLayout: @unchecked Sendable {
    case flights(FlightsCardGeometry)
    case hotels(HotelsCardGeometry)
}

nonisolated extension PromptRows {
    /// A travel tool part's row; nil when the call isn't one or can't be read.
    static func travelRow(_ call: ToolCall, message: ChatMessage, input: ChatRowBuilder.Input) -> ChatRow? {
        switch call.name {
        case TravelCards.flightsTool:
            guard let flights = TravelCards.flights(call) else { return nil }
            let id = "\(message.id)|flights\(call.id)"
            var asked: [String: Set<TravelCards.Ask>] = [:]
            for f in flights.flights { if let a = input.travel.asked[f.id] { asked[f.id] = a } }
            let card = FlightsCardRow(flights: flights, rowId: id, messageId: message.id,
                                      asked: asked, expanded: input.expanded.contains(id))
            return row(id: id, messageId: message.id, kind: .flights(card), scope: input.scope)
        case TravelCards.hotelsTool:
            guard let hotels = TravelCards.hotels(call) else { return nil }
            let id = "\(message.id)|hotels\(call.id)"
            var asked: [String: Set<TravelCards.Ask>] = [:]
            for h in hotels.hotels { if let a = input.travel.asked[h.id] { asked[h.id] = a } }
            let card = HotelsCardRow(hotels: hotels, rowId: id, messageId: message.id,
                                     asked: asked, expanded: input.expanded.contains(id))
            return row(id: id, messageId: message.id, kind: .hotels(card), scope: input.scope)
        default:
            return nil
        }
    }
}
