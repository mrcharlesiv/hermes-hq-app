// Comprehensive unit & stress tests for Travel Cards (Flights & Hotels).

import Testing
import UIKit
@testable import HermesHQNative

@MainActor @Suite(.serialized) struct TravelCardsTests {

    private func sampleFlightsCall() -> ToolCall {
        let args: [String: JSONValue] = [
            "step": .string("Checking the fare"),
            "note": .string("Best morning departures to New York."),
            "relaxed_filters": .array([.string("Nonstop only")]),
            "follow_ups": .array([.string("Show business class"), .string("Return Sunday")]),
            "flights": .array([
                .object([
                    "airline": .string("Example Air"),
                    "flight_number": .string("EA 412"),
                    "origin": .string("sfo"),
                    "destination": .string("jfk"),
                    "depart_time": .string("08:15"),
                    "arrive_time": .string("16:45"),
                    "duration": .string("5h 30m"),
                    "stops": .number(0),
                    "cabin": .string("Economy"),
                    "fare_tier": .string("Main Cabin"),
                    "price": .number(348),
                    "was": .number(412),
                    "currency": .string("USD"),
                    "url": .string("https://example.com/flights/ea412"),
                    "badge": .string("Best"),
                    "carry_on": .string("1 carry-on included"),
                    "checked_bag": .string("$35 first bag"),
                    "change_rule": .string("Free changes, pay fare difference"),
                    "refund_rule": .string("Credit for cancellations before departure"),
                    "why": .array([.string("Nonstop with full carry-on included")]),
                    "caution": .array([.string("Seat selection extra at front")]),
                ]),
                .object([
                    "airline": .string("CloudJet"),
                    "flight_number": .string("CJ 88"),
                    "origin": .string("SFO"),
                    "destination": .string("JFK"),
                    "depart_time": .string("10:05"),
                    "arrive_time": .string("20:10"),
                    "duration": .string("7h 05m"),
                    "stops": .number(1),
                    "stop_summary": .string("1 stop · DEN"),
                    "cabin": .string("Economy"),
                    "price": .number(279),
                    "currency": .string("USD"),
                    "url": .string("https://example.com/flights/cj88"),
                    "segments": .array([
                        .object(["airline": .string("CloudJet"), "flight_number": .string("CJ 88"),
                                 "origin": .string("SFO"), "destination": .string("DEN"),
                                 "depart_time": .string("10:05"), "arrive_time": .string("13:30"),
                                 "duration": .string("2h 25m"), "layover": .string("1h 15m layover in Denver")]),
                        .object(["airline": .string("CloudJet"), "flight_number": .string("CJ 91"),
                                 "origin": .string("DEN"), "destination": .string("JFK"),
                                 "depart_time": .string("14:45"), "arrive_time": .string("20:10"),
                                 "duration": .string("3h 25m")]),
                    ]),
                ]),
                // Invalid flight (insecure http URL) should be dropped safely.
                .object([
                    "airline": .string("Bad Air"),
                    "origin": .string("SFO"),
                    "destination": .string("JFK"),
                    "price": .number(99),
                    "url": .string("http://insecure.example.com/bad"),
                ]),
            ]),
        ]
        return ToolCall(id: "t-f1", name: TravelCards.flightsTool, title: "Flights",
                        argsText: ChatJSON.stringify(.object(args)), summary: nil, state: .done, durationSeconds: nil)
    }

    private func sampleHotelsCall() -> ToolCall {
        let args: [String: JSONValue] = [
            "location": .string("Manhattan, NY"),
            "check_in": .string("Dec 12"),
            "check_out": .string("Dec 15"),
            "guests": .string("2 guests"),
            "note": .string("Top rated stays near Midtown."),
            "hotels": .array([
                .object([
                    "name": .string("The Harbor House"),
                    "neighborhood": .string("SoHo"),
                    "address": .string("120 Crosby St, New York, NY 10012"),
                    "latitude": .number(40.7243),
                    "longitude": .number(-73.9975),
                    "stars": .number(4),
                    "rating": .number(9.2),   // 10-pt scale normalizes to 4.6
                    "reviews": .number(842),
                    "price_per_night": .number(289),
                    "total_price": .number(960),
                    "was": .number(340),
                    "currency": .string("USD"),
                    "url": .string("https://example.com/hotels/harbor-house"),
                    "image": .string("https://example.com/img/h1.jpg"),
                    "images": .array([
                        .string("https://example.com/img/h1.jpg"),   // duplicate deduplicated
                        .string("https://example.com/img/h2.jpg"),
                        .string("https://example.com/img/h3.jpg"),
                    ]),
                    "badge": .string("Free cancel"),
                    "cancellation": .string("Free cancellation until Dec 10"),
                    "amenities": .array([.string("Wi-Fi"), .string("Gym"), .string("Rooftop bar")]),
                ]),
                .object([
                    "name": .string("Out-of-bounds Coord Inn"),
                    "address": .string("555 Example Ave"),
                    "latitude": .number(999),
                    "longitude": .number(-200),
                    "price": .number(199),
                    "url": .string("https://example.com/hotels/oob"),
                ]),
            ]),
        ]
        return ToolCall(id: "t-h1", name: TravelCards.hotelsTool, title: "Hotels",
                        argsText: ChatJSON.stringify(.object(args)), summary: nil, state: .done, durationSeconds: nil)
    }

    @Test func flightsParseValidateAndTrackBookingState() {
        let call = sampleFlightsCall()
        let parsed = TravelCards.flights(call)
        #expect(parsed != nil)
        #expect(parsed?.flights.count == 2, "http URL flight dropped")
        #expect(parsed?.step == "Checking the fare")
        #expect(parsed?.relaxedFilters == ["Nonstop only"])
        #expect(parsed?.flights[0].routeLabel == "SFO → JFK")
        #expect(parsed?.flights[0].stopsLabel == "Nonstop")
        #expect(parsed?.flights[1].segments.count == 2)

        // Book message round-trip & bubble wording.
        let flight = parsed!.flights[0]
        let bookMsg = TravelCards.message(.book, flight: flight)
        let ans = TravelCards.answer(in: bookMsg)
        #expect(ans?.id == flight.id && ans?.ask == .book)
        #expect(TravelCards.bubbleWords(bookMsg)?.hasPrefix("Book:") == true)

        let msgs = [
            ChatMessage(id: "m1", role: .assistant, parts: [.tool(call)], timestamp: Date()),
            ChatMessage(id: "m2", role: .user, parts: [.text(bookMsg)], timestamp: Date()),
        ]
        let answers = TravelCards.answers(msgs)
        #expect(answers.asked[flight.id] == [.book])
        // Synthetic travel message is not counted as a normal human turn.
        #expect(!DraftCards.isNormalHumanTurn(msgs[1]))

        // Card row locks booking once one flight is requested.
        let row = FlightsCardRow(flights: parsed!, rowId: "r-f", messageId: "m1", asked: answers.asked, expanded: false)
        #expect(row.bookingInFlight)
    }

    @Test func hotelsParseNormalizeCoordsDedupeImagesAndPageGallery() {
        let call = sampleHotelsCall()
        let parsed = TravelCards.hotels(call)
        #expect(parsed != nil)
        #expect(parsed?.hotels.count == 2)

        let h0 = parsed!.hotels[0]
        #expect(h0.hasCoordinates && h0.latitude == 40.7243 && h0.longitude == -73.9975)
        #expect(h0.rating == 4.6)
        #expect(h0.images.count == 3, "duplicate main image removed")
        #expect(h0.amenities == ["Wi-Fi", "Gym", "Rooftop bar"])

        let h1 = parsed!.hotels[1]
        #expect(!h1.hasCoordinates, "invalid lat/lng stripped cleanly")

        // Full-screen gallery paging bounds.
        let gallery = HotelPhotoGalleryController(hotelName: h0.name, urls: h0.images, index: 0)
        gallery.loadViewIfNeeded()
        #expect(gallery.index == 0)
        gallery.select(index: 2)
        #expect(gallery.index == 2)
        gallery.select(index: 99) // out of bounds ignored
        #expect(gallery.index == 2)
    }

    @Test func travelLayoutsHandleStandardAndAccessibilitySizesAndCaps() {
        let flights = TravelCards.flights(sampleFlightsCall())!
        let hotels = TravelCards.hotels(sampleHotelsCall())!
        for cat in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
            let fRow = FlightsCardRow(flights: flights, rowId: "rf", messageId: "m1", asked: [:], expanded: false)
            let fLayout = FlightsCardLayout.make(fRow, gap: 8, width: 390, category: cat)
            #expect(fLayout.height > 150)

            let hRow = HotelsCardRow(hotels: hotels, rowId: "rh", messageId: "m2", asked: [:], expanded: false)
            let hLayout = HotelsCardLayout.make(hRow, gap: 8, width: 390, category: cat)
            #expect(hLayout.height > 200)
        }
        // Handshake helper
        #expect(TravelCards.cardsUntold(["travelCards": true, "travelCardsShown": false]))
        #expect(!TravelCards.cardsUntold(["travelCards": true, "travelCardsShown": true]))
        #expect(!TravelCards.cardsUntold(["travelCards": false]))
    }
}
