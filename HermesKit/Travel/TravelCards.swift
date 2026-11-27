// [travel] Flight and hotel travel cards: two tools of the Hermes HQ add-on (`show_flights` and `show_hotels`),
// drawn natively in chat like `show_products` (ShoppingCards). Pure, nonisolated, transcript-driven state so cards
// stay identical after relaunch and across devices.

import CryptoKit
import Foundation

nonisolated enum TravelCards {
    static let flightsTool = "show_flights"
    static let hotelsTool = "show_hotels"
    static let tools: Set<String> = [flightsTool, hotelsTool]
    static let maxArgsBytes = 256_000

    static let maxFlights = 12, maxHotels = 12, maxImages = 12, maxSegments = 6
    static let maxAmenities = 10, maxWhy = 3, maxCaution = 2, maxFollowUps = 3, maxRelaxed = 4

    // MARK: Flight Models

    struct Segment: Hashable, Sendable {
        var airline: String
        var flightNumber: String
        var origin: String
        var destination: String
        var departTime: String
        var arriveTime: String
        var duration: String
        var layover: String
    }

    struct Flight: Hashable, Sendable {
        var id: String
        var airline: String
        var flightNumber: String
        var origin: String
        var destination: String
        var departTime: String
        var arriveTime: String
        var duration: String
        var stops: Int
        var stopSummary: String
        var cabin: String
        var fareTier: String
        var price: Double
        var was: Double?
        var currency: String
        var url: URL
        var badge: String
        var carryOn: String
        var checkedBag: String
        var changeRule: String
        var refundRule: String
        var segments: [Segment]
        var why: [String]
        var caution: [String]

        var routeLabel: String { "\(origin) → \(destination)" }
        var stopsLabel: String {
            if !stopSummary.isEmpty { return stopSummary }
            switch stops {
            case 0: return "Nonstop"
            case 1: return "1 stop"
            default: return "\(stops) stops"
            }
        }
    }

    struct Flights: Hashable, Sendable {
        var note: String
        /// Live step indicator such as "Searching flights" or "Checking the fare".
        var step: String
        /// Filters relaxed when no exact flights matched (e.g., ["Nonstop only", "Morning departure"]).
        var relaxedFilters: [String]
        var flights: [Flight]
        var followUps: [String]
    }

    // MARK: Hotel Models

    struct Hotel: Hashable, Sendable {
        var id: String
        var name: String
        var neighborhood: String
        var address: String
        var latitude: Double?
        var longitude: Double?
        var stars: Int?
        var rating: Double?
        var reviews: Int?
        var pricePerNight: Double?
        var totalPrice: Double?
        var currency: String
        var was: Double?
        var url: URL
        var images: [URL]
        var badge: String
        var cancellation: String
        var breakfast: String
        var distance: String
        var amenities: [String]
        var why: [String]
        var caution: [String]

        var image: URL? { images.first }
        var hasCoordinates: Bool { latitude != nil && longitude != nil }
    }

    struct Hotels: Hashable, Sendable {
        var note: String
        var step: String
        var location: String
        var checkIn: String
        var checkOut: String
        var guests: String
        var hotels: [Hotel]
        var followUps: [String]
    }

    // MARK: Add-on handshake

    static let cardsPath = "/travel/cards"

    static func cardsUntold(_ status: [String: Any]?) -> Bool {
        (status?["travelCards"] as? NSNumber)?.boolValue == true && (status?["travelCardsShown"] as? NSNumber)?.boolValue != true
    }

    static func wholeArgsText(name: String, args: [String: JSONValue]) -> String? {
        guard tools.contains(name), !args.isEmpty else { return nil }
        let text = ChatJSON.stringify(.object(args))
        return text.utf8.count <= maxArgsBytes ? text : nil
    }

    // MARK: Parsing

    private static func args(_ call: ToolCall, _ name: String) -> [String: JSONValue]? {
        guard call.name == name, call.state != .failed, let text = call.argsText else { return nil }
        return ChatJSON.parse(string: text)?.object
    }

    static func flights(_ call: ToolCall) -> Flights? {
        guard let args = args(call, flightsTool) else { return nil }
        return flights(args)
    }

    static func flights(_ args: [String: JSONValue]) -> Flights? {
        let list = (args["flights"]?.array ?? []).compactMap { $0.object.flatMap(flight) }
        guard !list.isEmpty else { return nil }
        let relaxed = strings(args["relaxed_filters"] ?? args["relaxedFilters"], max: maxRelaxed, length: 60)
        let follow = strings(args["follow_ups"] ?? args["followUps"], max: maxFollowUps, length: 60)
        return Flights(
            note: text(args["note"], 200),
            step: text(args["step"] ?? args["status"], 60),
            relaxedFilters: relaxed,
            flights: Array(list.prefix(maxFlights)),
            followUps: follow
        )
    }

    static func flight(_ o: [String: JSONValue]) -> Flight? {
        let airline = trimmed(o["airline"])
        let origin = trimmed(o["origin"] ?? o["from"]).uppercased()
        let dest = trimmed(o["destination"] ?? o["to"]).uppercased()
        guard !airline.isEmpty, !origin.isEmpty, !dest.isEmpty,
              let price = fare(o["price"]),
              let url = https(trimmed(o["url"])) else { return nil }
        // The id is over the link as the bot wrote it, as the add-on hashes it: `URL` may rewrite an unusual one
        // (percent-encoding), and the two ids would part.
        let link = trimmed(o["url"])
        let flightNum = text(o["flight_number"] ?? o["flightNumber"], 24)
        let depart = text(o["depart_time"] ?? o["departTime"] ?? o["depart"], 40)
        let arrive = text(o["arrive_time"] ?? o["arriveTime"] ?? o["arrive"], 40)
        let stops = whole(amount(o["stops"]), in: 0...9) ?? 0
        let segments: [Segment] = (o["segments"]?.array ?? []).compactMap { v in
            guard let s = v.object else { return nil }
            let segOrigin = trimmed(s["origin"] ?? s["from"]).uppercased()
            let segDest = trimmed(s["destination"] ?? s["to"]).uppercased()
            guard !segOrigin.isEmpty, !segDest.isEmpty else { return nil }
            return Segment(
                airline: text(s["airline"], 60),
                flightNumber: text(s["flight_number"] ?? s["flightNumber"], 24),
                origin: cut(segOrigin, 8),
                destination: cut(segDest, 8),
                departTime: text(s["depart_time"] ?? s["departTime"] ?? s["depart"], 40),
                arriveTime: text(s["arrive_time"] ?? s["arriveTime"] ?? s["arrive"], 40),
                duration: text(s["duration"], 30),
                layover: text(s["layover"], 60)
            )
        }
        return Flight(
            id: flightId(airline: airline, origin: origin, destination: dest, depart: depart, url: link),
            airline: cut(airline, 60),
            flightNumber: flightNum,
            origin: cut(origin, 8),
            destination: cut(dest, 8),
            departTime: depart,
            arriveTime: arrive,
            duration: text(o["duration"], 30),
            stops: stops,
            stopSummary: text(o["stop_summary"] ?? o["stopSummary"], 60),
            cabin: text(o["cabin"], 40),
            fareTier: text(o["fare_tier"] ?? o["fareTier"], 40),
            price: price,
            was: above(amount(o["was"]), price),
            currency: currency(o["currency"]),
            url: url,
            badge: text(o["badge"], 28),
            carryOn: text(o["carry_on"] ?? o["carryOn"], 80),
            checkedBag: text(o["checked_bag"] ?? o["checkedBag"], 80),
            changeRule: text(o["change_rule"] ?? o["changeRule"], 120),
            refundRule: text(o["refund_rule"] ?? o["refundRule"], 120),
            segments: Array(segments.prefix(maxSegments)),
            why: strings(o["why"], max: maxWhy, length: 120),
            caution: strings(o["caution"], max: maxCaution, length: 120)
        )
    }

    static func hotels(_ call: ToolCall) -> Hotels? {
        guard let args = args(call, hotelsTool) else { return nil }
        return hotels(args)
    }

    static func hotels(_ args: [String: JSONValue]) -> Hotels? {
        let list = (args["hotels"]?.array ?? []).compactMap { $0.object.flatMap(hotel) }
        guard !list.isEmpty else { return nil }
        let follow = strings(args["follow_ups"] ?? args["followUps"], max: maxFollowUps, length: 60)
        return Hotels(
            note: text(args["note"], 200),
            step: text(args["step"] ?? args["status"], 60),
            location: text(args["location"], 80),
            checkIn: text(args["check_in"] ?? args["checkIn"], 40),
            checkOut: text(args["check_out"] ?? args["checkOut"], 40),
            guests: text(args["guests"], 40),
            hotels: Array(list.prefix(maxHotels)),
            followUps: follow
        )
    }

    static func hotel(_ o: [String: JSONValue]) -> Hotel? {
        let name = trimmed(o["name"] ?? o["title"])
        guard !name.isEmpty, let url = https(trimmed(o["url"])) else { return nil }
        var images: [URL] = []
        for value in [o["image"]] + (o["images"]?.array ?? []).map(Optional.some) {
            if let u = https(trimmed(value)), !images.contains(u) { images.append(u) }
        }
        let lat = coordinate(o["latitude"] ?? o["lat"], limit: 90)
        let lng = coordinate(o["longitude"] ?? o["lng"] ?? o["lon"], limit: 180)
        let stars = whole(amount(o["stars"]), in: 1...5)   // 7 stars, or 0, is a mistake: no stars shown
        let rating = amount(o["rating"]).map { min(5, max(0, $0 > 5 ? $0 / 2.0 : $0)) }
        let reviews = amount(o["reviews"]).flatMap { $0 >= 0 && $0 < 1e9 ? Int($0) : nil }
        let nightly = fare(o["price_per_night"] ?? o["pricePerNight"] ?? o["price"])
        let total = fare(o["total_price"] ?? o["totalPrice"] ?? o["total"])
        return Hotel(
            id: hotelId(name: name, address: trimmed(o["address"]), url: trimmed(o["url"])),
            name: cut(name, 140),
            neighborhood: text(o["neighborhood"] ?? o["area"], 80),
            address: text(o["address"], 200),
            latitude: (lat != nil && lng != nil) ? lat : nil,
            longitude: (lat != nil && lng != nil) ? lng : nil,
            stars: stars,
            rating: rating,
            reviews: reviews,
            pricePerNight: nightly,
            totalPrice: total,
            currency: currency(o["currency"]),
            was: above(amount(o["was"]), nightly),
            url: url,
            images: Array(images.prefix(maxImages)),
            badge: text(o["badge"], 28),
            cancellation: text(o["cancellation"], 100),
            breakfast: text(o["breakfast"], 60),
            distance: text(o["distance"], 60),
            amenities: strings(o["amenities"], max: maxAmenities, length: 40),
            why: strings(o["why"], max: maxWhy, length: 120),
            caution: strings(o["caution"], max: maxCaution, length: 120)
        )
    }

    // MARK: Actions & Transcript Answers

    enum Ask: String, Hashable, Sendable {
        case book
        case watchPrice = "watch price"
    }

    struct Answers: Equatable, Sendable {
        /// Flight or hotel id → asks already sent in this chat.
        var asked: [String: Set<Ask>] = [:]
    }

    static let lead = "[Hermes HQ travel "
    private static let mark = TRx(#"^\s*\[Hermes HQ travel ([fh]-[0-9a-f]{8}): (book|watch price)\]"#)

    static func message(_ ask: Ask, flight: Flight) -> String {
        let header = "[Hermes HQ travel \(flight.id): \(ask.rawValue)]"
        let desc = "\(flight.airline) \(flight.routeLabel) (\(flight.departTime)–\(flight.arriveTime)) for \(ShoppingCards.price(flight.price, currency: flight.currency))"
        switch ask {
        case .book:
            return "\(header)\nBook this flight for me: \(desc).\n\(flight.url.absoluteString)\nVerify the current fare, bag rules, and seat availability, then stop before final payment and confirm the total with me."
        case .watchPrice:
            return "\(header)\nWatch the fare on this flight and tell me if it drops below \(ShoppingCards.price(flight.price, currency: flight.currency)): \(desc).\n\(flight.url.absoluteString)"
        }
    }

    static func message(_ ask: Ask, hotel: Hotel) -> String {
        let header = "[Hermes HQ travel \(hotel.id): \(ask.rawValue)]"
        let rate = hotel.pricePerNight.map { " at \(ShoppingCards.price($0, currency: hotel.currency))/night" } ?? ""
        switch ask {
        case .book:
            return "\(header)\nBook this hotel for me: \(hotel.name)\(rate).\n\(hotel.url.absoluteString)\nVerify room availability, taxes, and cancellation terms, then stop before final payment and confirm the total with me."
        case .watchPrice:
            // The name after a colon, like the other three: the chat bubble says which hotel (`bubbleWords`).
            return "\(header)\nWatch the nightly rate for this hotel and tell me if it drops: \(hotel.name)\(rate).\n\(hotel.url.absoluteString)"
        }
    }

    static func answer(in text: String) -> (id: String, ask: Ask)? {
        guard text.drop(while: \.isWhitespace).hasPrefix(lead),
              let groups = mark.groups(text),
              let id = groups[1], let raw = groups[2],
              let ask = Ask(rawValue: raw) else { return nil }
        return (id, ask)
    }

    static func answers(_ messages: [ChatMessage], queued: [String] = []) -> Answers {
        var out = Answers()
        func scan(_ text: String) {
            if let found = answer(in: text) {
                out.asked[found.id, default: []].insert(found.ask)
            }
        }
        for message in messages where message.role == .user {
            for case .text(let text) in message.parts { scan(text) }
        }
        for text in queued { scan(text) }
        return out
    }

    /// Clean short bubble label for travel card actions.
    static func bubbleWords(_ text: String) -> String? {
        guard let found = answer(in: text) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let second = lines.count > 1 ? String(lines[1]) : ""
        let prefix = found.ask == .book ? "Book" : "Watch price"
        if let colon = second.firstIndex(of: ":") {
            let tail = second[second.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " ."))
            if !tail.isEmpty { return "\(prefix): \(cut(tail, 72))" }
        }
        return prefix
    }

    // MARK: IDs & Helpers

    static func flightId(airline: String, origin: String, destination: String, depart: String, url: String) -> String {
        "f-" + hex8([airline, origin, destination, depart, url].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n"))
    }

    static func hotelId(name: String, address: String, url: String) -> String {
        "h-" + hex8([name, address, url].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n"))
    }

    private static func hex8(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// A field's words. A bot often writes a number where words are meant (`guests: 2`, `flight_number: 412`):
    /// that reads as its digits, not as nothing.
    private static func trimmed(_ value: JSONValue?) -> String {
        if case .number(let n)? = value, n.isFinite, abs(n) < 1e15 {
            return n == n.rounded() ? String(Int64(n)) : String(n)
        }
        return (value?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cut(_ text: String, _ max: Int) -> String {
        text.count <= max ? text : String(text.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func text(_ value: JSONValue?, _ max: Int) -> String {
        cut(trimmed(value).split(whereSeparator: \.isNewline).joined(separator: " "), max)
    }

    /// A list of short lines. One line written as plain words (`"why": "Nonstop"`) is a list of one.
    private static func strings(_ value: JSONValue?, max: Int, length: Int) -> [String] {
        let items = value?.array ?? (value?.string != nil ? [value!] : [])
        return items.map { text($0, length) }.filter { !$0.isEmpty }.prefix(max).map { $0 }
    }

    private static func https(_ text: String) -> URL? {
        guard !text.isEmpty, text.count <= 2048,
              let url = URL(string: text),
              url.scheme?.lowercased() == "https",
              let host = url.host, host.contains(".") else { return nil }
        return url
    }

    private static func amount(_ value: JSONValue?) -> Double? {
        switch value {
        case .number(let n): return n.isFinite && abs(n) < 1e12 ? n : nil
        case .string(let s):
            // "1,299.00" as a bot may copy it off the page (ShoppingCards reads its amounts the same way).
            let cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "")
            if let n = Double(cleaned), n.isFinite, abs(n) < 1e12 { return n }
            return nil
        default: return nil
        }
    }

    /// A fare or a room rate: more than nothing and less than a number no trip costs (a wild value is a mistake,
    /// and the card would rather drop the option than show it).
    private static func fare(_ value: JSONValue?) -> Double? {
        guard let n = amount(value), n > 0, n < 10_000_000 else { return nil }
        return n
    }

    /// A count, rounded, when it lies in `range` (`Int(_:)` traps on a number too big for it, so the range is
    /// checked on the Double first).
    private static func whole(_ value: Double?, in range: ClosedRange<Int>) -> Int? {
        guard let value, value.isFinite else { return nil }
        let rounded = value.rounded()
        guard rounded >= Double(range.lowerBound), rounded <= Double(range.upperBound) else { return nil }
        return Int(rounded)
    }

    private static func coordinate(_ value: JSONValue?, limit: Double) -> Double? {
        guard let n = amount(value), abs(n) <= limit else { return nil }
        return n
    }

    private static func above(_ was: Double?, _ price: Double?) -> Double? {
        guard let was, let price, was > price else { return nil }
        return was
    }

    private static func currency(_ value: JSONValue?) -> String {
        let code = trimmed(value).uppercased()
        return code.count == 3 && code.allSatisfy(\.isASCII) ? code : "USD"
    }
}
