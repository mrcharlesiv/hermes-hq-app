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

    @Test func hotelsCardPolishesSubtitleCollapseWrappingAndEdgeBleed() {
        let baseHotel: [String: JSONValue] = [
            "name": .string("Embassy Suites by Hilton Chicago O'Hare Rosemont"),
            "price_per_night": .number(137),
            "currency": .string("USD"),
            "url": .string("https://example.com/hotels/embassy"),
        ]
        let secondHotel: [String: JSONValue] = [
            "name": .string("Loews Chicago O'Hare Hotel"),
            "price_per_night": .number(159),
            "currency": .string("USD"),
            "url": .string("https://example.com/hotels/loews"),
        ]
        let noSubCall = ToolCall(
            id: "t-h-nosub",
            name: TravelCards.hotelsTool,
            title: "Hotels",
            argsText: ChatJSON.stringify(.object([
                "location": .string("Chicago · O'Hare and downtown"),
                "check_in": .string("Sat, Dec 26, 2026"),
                "check_out": .string("Sun, Dec 27, 2026"),
                "note": .string("Three more airport-area options and two downtown stays. All rates are nightly before tax."),
                "hotels": .array([.object(baseHotel), .object(secondHotel)]),
            ])),
            summary: nil, state: .done, durationSeconds: nil
        )
        let withSubCall = ToolCall(
            id: "t-h-sub",
            name: TravelCards.hotelsTool,
            title: "Hotels",
            argsText: ChatJSON.stringify(.object([
                "location": .string("Chicago"),
                "hotels": .array([
                    .object(baseHotel.merging(["rating": .number(4.4), "neighborhood": .string("Rosemont")]) { _, new in new }),
                    .object(secondHotel),
                ]),
            ])),
            summary: nil, state: .done, durationSeconds: nil
        )

        let noSub = TravelCards.hotels(noSubCall)!
        let withSub = TravelCards.hotels(withSubCall)!
        let noSubRow = HotelsCardRow(hotels: noSub, rowId: "r-nosub", messageId: "m1", asked: [:], expanded: false)
        let withSubRow = HotelsCardRow(hotels: withSub, rowId: "r-sub", messageId: "m2", asked: [:], expanded: false)

        let width: CGFloat = 390
        let cardW = PromptLayout.cardWidth(for: width)
        let type = TravelCardType(category: .large)
        let pNoSub = HotelsCardLayout.pieces(noSubRow, width: cardW, category: .large)
        let pWithSub = HotelsCardLayout.pieces(withSubRow, width: cardW, category: .large)

        // 1. Empty subtitle collapses unused tile height instead of leaving blank padding.
        #expect(!pNoSub.hasSubtitle)
        #expect(pWithSub.hasSubtitle)
        #expect(pNoSub.carousel < pWithSub.carousel)

        // 2. Long hotel names get 2 lines so the property name isn't clipped after the chain name.
        #expect(pNoSub.nameLines == 2)
        let shortRow = HotelsCardRow(hotels: TravelCards.hotels(sampleHotelsCall())!, rowId: "r-short", messageId: "m3", asked: [:], expanded: false)
        let pShort = HotelsCardLayout.pieces(shortRow, width: cardW, category: .large)
        #expect(pShort.nameLines == 1)

        // 3. Long meta header and multi-sentence note wrap to 2 lines instead of truncating on line 1.
        #expect(pNoSub.meta > TravelCardType.line(type.smallStrong))
        #expect(pNoSub.note > TravelCardType.line(type.body))
        let metaProbe = UILabel()
        metaProbe.font = type.smallStrong
        metaProbe.numberOfLines = HotelsCardLayout.metaLines(type)
        metaProbe.text = HotelsCardLayout.metaWords(noSub)
        #expect(metaProbe.sizeThatFits(CGSize(width: cardW, height: .greatestFiniteMagnitude)).height <= pNoSub.meta)
        let noteProbe = UILabel()
        noteProbe.font = type.body
        noteProbe.numberOfLines = type.noteLines
        noteProbe.text = noSub.note
        #expect(noteProbe.sizeThatFits(CGSize(width: cardW, height: .greatestFiniteMagnitude)).height <= pNoSub.note)

        // 4. Phone-width carousel bleeds edge-to-edge; wide desktop pane stays on the inset rail.
        #expect(HotelsCardLayout.bleedsCarousel(rowWidth: 390, cardWidth: cardW))
        let wideCardW = PromptLayout.cardWidth(for: 1000)
        #expect(!HotelsCardLayout.bleedsCarousel(rowWidth: 1000, cardWidth: wideCardW))

        let view = HotelsCardView(frame: CGRect(x: 0, y: 0, width: width, height: 400))
        let geo = HotelsCardGeometry(width: cardW, rowWidth: width, height: ceil(pNoSub.height), gapAbove: 8, category: .large)
        view.configure(noSubRow, geo)
        let scroll = view.subviews.compactMap { $0 as? UIScrollView }.first
        #expect(scroll != nil)
        #expect(scroll?.frame.minX == 0)
        #expect(scroll?.frame.width == width)
    }

    @Test func widePaneHotelsCarouselFitsWholeTilesWrapsChipsAndPersistsOffset() throws {
        let hotels: [JSONValue] = (1...5).map { idx in
            .object([
                "name": .string("Harborview Suites North Terminal #\(idx)"),
                "price_per_night": .number(Double(120 + idx * 15)),
                "currency": .string("USD"),
                "url": .string("https://example.com/hotels/stay-\(idx)"),
            ])
        }
        let call = ToolCall(
            id: "t-h-wide",
            name: TravelCards.hotelsTool,
            title: "Hotels",
            argsText: ChatJSON.stringify(.object([
                "location": .string("North Harbor · Terminal & Waterfront District"),
                "check_in": .string("Sat, Nov 14, 2026"),
                "check_out": .string("Sun, Nov 15, 2026"),
                "guests": .string("2 adults + 1 guest"),
                "note": .string("Three terminal-area stays and two waterfront suites. Cash rates shown before tax."),
                "follow_ups": .array([
                    .string("Filter by free breakfast"),
                    .string("Show suites with two bedrooms"),
                    .string("Compare total with parking"),
                ]),
                "hotels": .array(hotels),
            ])),
            summary: nil, state: .done, durationSeconds: nil
        )
        let parsed = try #require(TravelCards.hotels(call))
        let rowA = HotelsCardRow(hotels: parsed, rowId: "r-wide-hotels-a", messageId: "m-wide-a", asked: [:], expanded: false)
        let rowB = HotelsCardRow(hotels: parsed, rowId: "r-wide-hotels-b", messageId: "m-wide-b", asked: [:], expanded: false)

        let rowWidth: CGFloat = 1000
        let macCardW: CGFloat = 660
        let type = TravelCardType(category: .large)

        // 1. Mac 660 pt rail (wholeTiles: true): exact whole-tile viewport, never chops the next card mid-tile at rest.
        let macMetrics = HotelsCardLayout.carouselMetrics(count: parsed.hotels.count, rowWidth: rowWidth, cardWidth: macCardW, type: type, wholeTiles: true)
        #expect(!macMetrics.bleeds && macMetrics.wholeTiles)
        #expect(macMetrics.stripX == HotelsCardLayout.side)
        #expect(macMetrics.stripWidth <= macCardW)
        #expect(macMetrics.visibleColumns == 3)
        let exactViewport = CGFloat(macMetrics.visibleColumns) * macMetrics.tileWidth + CGFloat(macMetrics.visibleColumns - 1) * macMetrics.spacing
        #expect(abs(macMetrics.stripWidth - exactViewport) < 0.01)
        #expect(macMetrics.isScrollable)
        #expect(abs(macMetrics.maxOffset - CGFloat(5 - macMetrics.visibleColumns) * macMetrics.stride) < 0.01)

        // Stepping forward & backward and snapping always land on whole-tile boundaries.
        let next = macMetrics.steppedOffset(from: 0, forward: true)
        #expect(next > 0 && next <= macMetrics.maxOffset)
        #expect(abs(next.truncatingRemainder(dividingBy: macMetrics.stride)) < 0.01)
        #expect(macMetrics.steppedOffset(from: next, forward: false) == 0)
        #expect(abs(macMetrics.snappedOffset(for: macMetrics.stride * 0.7) - macMetrics.stride) < 0.01)

        // 2. Wide iPad touch pane (wholeTiles: false): stays inset on the rail and keeps a peeking tile as a scroll cue.
        let ipadMetrics = HotelsCardLayout.carouselMetrics(count: parsed.hotels.count, rowWidth: rowWidth, cardWidth: 560, type: type, wholeTiles: false)
        #expect(!ipadMetrics.bleeds && !ipadMetrics.wholeTiles)
        #expect(ipadMetrics.stripX == HotelsCardLayout.side && ipadMetrics.stripWidth == 560)
        #expect(ipadMetrics.isScrollable)

        // 3. Narrow bleed mode stepping returns cleanly to 0 when stepping back.
        let phoneMetrics = HotelsCardLayout.carouselMetrics(count: parsed.hotels.count, rowWidth: 390, cardWidth: 358, type: type, wholeTiles: true)
        #expect(phoneMetrics.bleeds && !phoneMetrics.wholeTiles)
        let phoneNext = phoneMetrics.steppedOffset(from: 0, forward: true)
        #expect(phoneNext > 0)
        #expect(phoneMetrics.steppedOffset(from: phoneNext, forward: false) == 0)

        // Single hotel on wide pane does not stretch into a narrow panoramic banner.
        let singleMetrics = HotelsCardLayout.carouselMetrics(count: 1, rowWidth: rowWidth, cardWidth: macCardW, type: type, wholeTiles: true)
        #expect(singleMetrics.tileWidth <= 360 && !singleMetrics.isScrollable)

        // Long metadata wraps cleanly at Mac 660 pt rail in both standard and accessibility text sizes.
        for cat in [UIContentSizeCategory.large, .accessibilityLarge] {
            let t = TravelCardType(category: cat)
            let p = HotelsCardLayout.pieces(rowA, width: macCardW, rowWidth: rowWidth, category: cat, wholeTiles: true)
            let metaProbe = UILabel()
            metaProbe.font = t.smallStrong
            metaProbe.numberOfLines = HotelsCardLayout.metaLines(t)
            metaProbe.text = HotelsCardLayout.metaWords(parsed)
            #expect(metaProbe.sizeThatFits(CGSize(width: macCardW, height: .greatestFiniteMagnitude)).height <= p.meta)
        }

        // Follow-up chips wrap onto multiple rows on narrow width without overflowing.
        let narrowChips = TravelCardType.chipLayout(parsed.followUps, width: 320, type: type)
        #expect(narrowChips.height > type.chipHeight)
        #expect(narrowChips.frames.allSatisfy { $0.frame.maxX <= 320.5 })

        // Carousel clips to its viewport and preserves row A's offset even after cell reuse for row B.
        let cardW = PromptLayout.cardWidth(for: rowWidth)
        let activeMetrics = HotelsCardLayout.carouselMetrics(count: parsed.hotels.count, rowWidth: rowWidth, cardWidth: cardW, type: type)
        let pieces = HotelsCardLayout.pieces(rowA, width: cardW, rowWidth: rowWidth, category: .large)
        let view = HotelsCardView(frame: CGRect(x: 0, y: 0, width: rowWidth, height: 500))
        let geo = HotelsCardGeometry(width: cardW, rowWidth: rowWidth, height: ceil(pieces.height), gapAbove: 8, category: .large)
        view.configure(rowA, geo)
        let scroll = try #require(view.subviews.compactMap { $0 as? UIScrollView }.first)
        #expect(scroll.clipsToBounds)
        #expect(scroll.frame.minX == HotelsCardLayout.side)
        #expect(abs(scroll.frame.width - activeMetrics.stripWidth) < 0.01)

        scroll.contentOffset.x = activeMetrics.stride
        view.scrollViewDidScroll(scroll)
        // Reuse cell for row B (starts at 0), then return to row A — row A's saved offset must survive.
        view.configure(rowB, geo)
        #expect(abs(scroll.contentOffset.x) < 0.5)
        view.configure(rowA, geo)
        #expect(abs(scroll.contentOffset.x - activeMetrics.stride) < 0.5)
    }
}
