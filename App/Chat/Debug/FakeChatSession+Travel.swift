#if DEBUG
import Foundation

// [travel] Demo chat (`-HQDemoTravel`): flights card with relaxed filter + segments/policies, hotels card with
// coordinates & photo gallery, Mermaid architecture diagram, an email draft with Cc/Bcc, and hotels written as a
// table with one wide right-aligned column — stand-ins only.

extension FakeChatSession {
    static var travelMessages: [ChatMessage] {
        func tool(_ id: String, _ name: String, _ title: String, _ args: [String: JSONValue]) -> ChatPart {
            .tool(ToolCall(id: id, name: name, title: title, argsText: ChatJSON.stringify(.object(args)),
                           summary: nil, state: .done, durationSeconds: 0.2))
        }

        let flightsArgs: [String: JSONValue] = [
            "step": .string("Fares checked"),
            "note": .string("Morning departures from SFO to JFK. Relaxed nonstop filter to include one lower fare."),
            "relaxed_filters": .array([.string("Nonstop only")]),
            "follow_ups": .array([.string("Show business class"), .string("Return Sunday evening")]),
            "flights": .array([
                .object([
                    "airline": .string("Example Air"),
                    "flight_number": .string("EA 412"),
                    "origin": .string("SFO"),
                    "destination": .string("JFK"),
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
                    "carry_on": .string("1 carry-on + personal item included"),
                    "checked_bag": .string("$35 first checked bag"),
                    "change_rule": .string("Free changes, pay fare difference"),
                    "refund_rule": .string("Flight credit before departure"),
                    "why": .array([.string("Nonstop morning flight with full carry-on included")]),
                    "caution": .array([.string("Extra legroom seats cost $65")]),
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
                    "fare_tier": .string("Value"),
                    "price": .number(279),
                    "currency": .string("USD"),
                    "url": .string("https://example.com/flights/cj88"),
                    "badge": .string("Lowest"),
                    "carry_on": .string("1 carry-on included"),
                    "checked_bag": .string("$40 first checked bag"),
                    "change_rule": .string("$75 change fee"),
                    "refund_rule": .string("Non-refundable after 24h"),
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
            ]),
        ]

        let hotelsArgs: [String: JSONValue] = [
            "location": .string("Manhattan, NY"),
            "check_in": .string("Dec 12"),
            "check_out": .string("Dec 15"),
            "guests": .string("2 guests"),
            "note": .string("Quiet boutique stays with easy subway access."),
            "follow_ups": .array([.string("Under $250/night"), .string("Near Central Park")]),
            "hotels": .array([
                .object([
                    "name": .string("The Harbor House"),
                    "neighborhood": .string("SoHo"),
                    "address": .string("120 Crosby St, New York, NY 10012"),
                    "latitude": .number(40.7243),
                    "longitude": .number(-73.9975),
                    "stars": .number(4),
                    "rating": .number(4.7),
                    "reviews": .number(842),
                    "price_per_night": .number(289),
                    "total_price": .number(960),
                    "was": .number(340),
                    "currency": .string("USD"),
                    "url": .string("https://example.com/hotels/harbor-house"),
                    "images": .array([
                        .string("https://picsum.photos/seed/harbor1/800/600"),
                        .string("https://picsum.photos/seed/harbor2/800/600"),
                        .string("https://picsum.photos/seed/harbor3/800/600"),
                    ]),
                    "badge": .string("Top pick"),
                    "cancellation": .string("Free cancellation until Dec 10"),
                    "breakfast": .string("Breakfast included"),
                    "distance": .string("2 min to subway"),
                    "amenities": .array([.string("Fast Wi-Fi"), .string("Gym"), .string("Quiet courtyard"), .string("24h desk")]),
                    "why": .array([.string("High guest scores for quiet rooms and easy transit")]),
                ]),
                .object([
                    "name": .string("Mercer Park Hotel and Conference Center by the River"),
                    "neighborhood": .string("Midtown"),
                    "address": .string("45 W 44th St, New York, NY 10036"),
                    "latitude": .number(40.7556),
                    "longitude": .number(-73.9818),
                    "stars": .number(4),
                    "rating": .number(4.5),
                    "reviews": .number(512),
                    "price_per_night": .number(249),
                    "total_price": .number(830),
                    "currency": .string("USD"),
                    "url": .string("https://example.com/hotels/mercer-park"),
                    "images": .array([
                        .string("https://picsum.photos/seed/mercer1/800/600"),
                    ]),
                    "cancellation": .string("Free cancellation until Dec 11"),
                    "amenities": .array([.string("Wi-Fi"), .string("Coffee bar"), .string("Workspace")]),
                ]),
            ]),
        ]

        let mermaidText = """
        Here is your trip plan flow:

        ```mermaid
        flowchart LR
            A[SFO Morning] --> B{Flight Choice}
            B -->|Nonstop| C[JFK 16:45]
            B -->|1 Stop| D[DEN Layover]
            D --> C
            C --> E([The Harbor House])
        ```
        """

        let draftArgs: [String: JSONValue] = [
            "app": .string("Email — from alex@example.com"),
            "to": .string("dana@example.com"),
            "cc": .array([.string("travel@example.com"), .string("ops@example.com")]),
            "bcc": .string("records@example.com"),
            "subject": .string("NYC Trip Itinerary (Dec 12–15)"),
            "body": .string("Hi Dana,\n\nSharing the flight and hotel options for December 12–15. Let me know if The Harbor House works for the team.\n\nBest,\nAlex"),
        ]

        // A reply that wrote its hotels as a table: the rate column is as wide as its one long cell and asks to be
        // right-aligned, so its short rates must still sit where they can be seen (`TextLayout.tableGrid`).
        let tableText = """
        Rooms for **two adults, December 12–13**:

        | Hotel | Rate for one night | Good for |
        |---|---:|---|
        | **[The Harbor House](https://example.com/hotels/harbor-house)** | **$240 flexible or 60,000 points**; other cash rates from **$190** | **Closest to the gate.** A short indoor walk from the terminal. |
        | **[Mercer Park Inn](https://example.com/hotels/mercer-park)** | **$118** | **Lowest price.** Breakfast and a pool. |
        | **[Canal Street Suites](https://example.com/hotels/canal-street)** | **$155** | **Most room.** A suite, with a shuttle to the airport. |

        I'd pick **The Harbor House**. Nothing is booked yet.
        """

        let now = Date()
        return [
            ChatMessage(id: "tr-u1", role: .user, parts: [.text("Find flights from SFO to JFK and a boutique hotel for Dec 12–15.")],
                        timestamp: now.addingTimeInterval(-300), rowId: 9401),
            ChatMessage(id: "tr-a1", role: .assistant, parts: [
                tool("tr-c1", TravelCards.flightsTool, "Flights", flightsArgs),
                tool("tr-c2", TravelCards.hotelsTool, "Hotels", hotelsArgs),
            ], timestamp: now.addingTimeInterval(-240), rowId: 9402),
            ChatMessage(id: "tr-a2", role: .assistant, parts: [.text(mermaidText)],
                        timestamp: now.addingTimeInterval(-180), rowId: 9403),
            ChatMessage(id: "tr-a3", role: .assistant, parts: [
                tool("tr-c3", DraftCards.tool, "Draft email", draftArgs),
            ], timestamp: now.addingTimeInterval(-120), rowId: 9404),
            ChatMessage(id: "tr-u2", role: .user, parts: [.text("Which hotels are near the airport?")],
                        timestamp: now.addingTimeInterval(-90), rowId: 9405),
            ChatMessage(id: "tr-a4", role: .assistant, parts: [.text(tableText)],
                        timestamp: now.addingTimeInterval(-60), rowId: 9406),
        ]
    }
}
#endif
