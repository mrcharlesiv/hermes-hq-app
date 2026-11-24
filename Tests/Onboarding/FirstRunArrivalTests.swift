// [first-run] The redrawn first run's pure parts (App/Onboarding/Arrival/): the land and its dots, the clock's
// longitude, the head's LEDs and which dot lights each, where the stage puts every dot at rest, the switch's rules, the
// new words, and the arrival skipped when the Update screen is due. build/first-run/BRIEF.md, "Tests and proof".

import Foundation
import simd
import Testing
@testable import HermesHQNative

@Suite struct FirstRunLandTests {
    private var land: ArrivalWorld.Land { get throws { try #require(ArrivalWorld.Land.bundled, "first-run-land.bin is in the app") } }

    @Test func theLandIsOneBitPerDegree() throws {
        let data = try #require(Bundle.main.url(forResource: "first-run-land", withExtension: "bin").flatMap { try? Data(contentsOf: $0) })
        #expect(data.count == 8100)
        #expect(ArrivalWorld.Land(Data(count: 8099)) == nil, "the wrong size is refused")
    }

    @Test func knownLandAndSea() throws {
        let land = try land
        for (lat, lon) in [(48.86, 2.35), (39.7, -105.0), (-1.29, 36.8), (-25.0, 134.0), (35.7, 139.7)] {
            #expect(land.isLand(lat: lat, lon: lon), "land at \(lat), \(lon)")
        }
        for (lat, lon) in [(30.0, -40.0), (0.0, -150.0), (-40.0, 80.0), (55.0, -30.0)] {
            #expect(!land.isLand(lat: lat, lon: lon), "sea at \(lat), \(lon)")
        }
        #expect(land.isLand(lat: 48.86, lon: 2.35 + 360) == land.isLand(lat: 48.86, lon: 2.35), "longitude wraps")
    }

    @Test func theSpiralMakesTheMocksDots() throws {
        var random = ArrivalWorld.Random()
        let dots = ArrivalWorld.dots(land: try land, random: &random)
        #expect(dots.count == 1416, "the mock's P on this land")
        for dot in dots {
            #expect(abs(simd_length(dot.u) - 1) < 1e-9)
            #expect(asin(dot.u.y) / ArrivalWorld.d2r >= -58, "nothing south of 58°S")
            #expect((0..<390).contains(dot.hx) && (0..<844).contains(dot.hy) && (0..<1).contains(dot.hs))
        }
        let stars = ArrivalWorld.stars(random: &random)
        #expect(stars.count == 90)
    }

    @Test func theRandomStreamIsTheMocks() {
        var random = ArrivalWorld.Random()
        #expect(abs(random.next() - 184877.0 / 2147483647) < 1e-15, "11 × 16807 mod 2³¹−1")
    }
}

@Suite struct FirstRunPlaceTests {
    @Test func longitudeComesFromTheClockAlone() {
        #expect(ArrivalWorld.longitude(secondsFromGMT: 0) == 0)
        #expect(ArrivalWorld.longitude(secondsFromGMT: 3600) == 15)
        #expect(ArrivalWorld.longitude(secondsFromGMT: -8 * 3600) == -120)
        #expect(ArrivalWorld.longitude(secondsFromGMT: 5 * 3600 + 1800) == 82.5)
        #expect(ArrivalWorld.longitude(secondsFromGMT: 14 * 3600) == 180, "clamped")
        #expect(ArrivalWorld.longitude(secondsFromGMT: -13 * 3600) == -180, "clamped")
    }

    @Test func theHemisphereIsGuessedFromTheZonesName() {
        let north = ArrivalWorld.Place(secondsFromGMT: 3600, identifier: "Europe/Paris")
        #expect(north.tilt == 0.44)
        #expect(abs(asin(north.you.y) / ArrivalWorld.d2r - 39) < 1e-9)
        let south = ArrivalWorld.Place(secondsFromGMT: 36000, identifier: "Australia/Sydney")
        #expect(south.tilt == -0.4)
        #expect(abs(asin(south.you.y) / ArrivalWorld.d2r + 28) < 1e-9)
        #expect(abs(south.lon - 150) < 1e-9)
    }

    @Test func theNoteGoes122DegreesEast() {
        let place = ArrivalWorld.Place(secondsFromGMT: 0, identifier: "Europe/London")
        let lon = atan2(place.far.x, place.far.z) / ArrivalWorld.d2r
        #expect(abs(lon - 122) < 1e-9)
    }

    @Test func theGlobeFacesThemAtRest() {
        let place = ArrivalWorld.Place(secondsFromGMT: -5 * 3600, identifier: "America/New_York")
        var globe = ArrivalWorld.Globe()
        globe.rot = place.restRotation
        globe.tilt = place.tilt
        let mark = globe.project(place.you)
        #expect(abs(mark.x - globe.cx) < 1e-6, "turned to their longitude: the mark is on the middle line")
        #expect(mark.z > 0, "on the near side")
    }
}

@Suite struct FirstRunLEDTests {
    @Test func theRoundHeadHas308LEDsAndTwoEyes() {
        let cells = ArrivalWorld.cells
        #expect(cells.count == 308, "20 across, within 9.9 of the middle")
        #expect(cells.filter(\.eye).count == 16, "two eyes, two LEDs wide and four tall")
        #expect(cells.filter { $0.eye && $0.r == 7 }.count == 4, "the dark row in each eye")
        #expect(cells.allSatisfy { (0...1).contains($0.light) })
    }

    @Test func everyLEDIsLitByExactlyOneDot() throws {
        let land = try #require(ArrivalWorld.Land.bundled)
        var random = ArrivalWorld.Random()
        let dots = ArrivalWorld.dots(land: land, random: &random)
        var globe = ArrivalWorld.Globe()
        globe.rot = 0.3
        let mono = SIMD3<Double>(245, 245, 247)
        let rest = dots.map { ArrivalWorld.globe($0, globe, mono: mono) }
        let cells = ArrivalWorld.cells
        let centres = cells.map { SIMD2(195 + $0.dx * 7.4, 188 + $0.dy * 7.4) }
        let order = Array(cells.indices.reversed())
        let assigned = ArrivalWorld.assign(cellCentres: centres, dots: rest.map { SIMD2($0.x, $0.y) }, alphas: rest.map(\.a), order: order)
        #expect(assigned.cell.count == dots.count)
        var lit = [Int](repeating: 0, count: cells.count)
        for (i, prim) in assigned.prim.enumerated() where prim { lit[assigned.cell[i]] += 1 }
        #expect(lit.allSatisfy { $0 == 1 }, "each LED filled once")
        #expect(assigned.prim.filter { $0 }.count == cells.count)
        #expect(assigned.cell.allSatisfy { cells.indices.contains($0) }, "the rest fold into some LED")
    }

    @Test func visibleDotsAreTakenFirst() {
        let centres = [SIMD2(0.0, 0.0)]
        let dots = [SIMD2(0.0, 0.0), SIMD2(5.0, 0.0)]
        let assigned = ArrivalWorld.assign(cellCentres: centres, dots: dots, alphas: [0.01, 0.5], order: [0])
        #expect(assigned.prim == [false, true], "the nearest dot bright enough to see, not the nearest")
    }
}

@MainActor @Suite struct FirstRunStageTests {
    private let mono = SIMD3<Double>(245, 245, 247)
    private let accent = SIMD3<Double>(176, 48, 85)

    @Test func starsRestAtTheirHome() throws {
        let land = try #require(ArrivalWorld.Land.bundled)
        var random = ArrivalWorld.Random()
        let dot = try #require(ArrivalWorld.dots(land: land, random: &random).first)
        let t = ArrivalWorld.star(dot, now: 0, mono: mono)
        #expect(t.x == dot.hx && t.y == dot.hy)
        #expect(abs(t.r - (0.5 + dot.hs * 0.9)) < 1e-12)
    }

    @Test func theGlobeRestsInsideItsCircle() throws {
        let land = try #require(ArrivalWorld.Land.bundled)
        var random = ArrivalWorld.Random()
        let dots = ArrivalWorld.dots(land: land, random: &random)
        let globe = ArrivalWorld.Globe(cx: 195, cy: 136, r: 38, rot: 1, tilt: 0.44)
        for dot in dots {
            let t = ArrivalWorld.globe(dot, globe, mono: mono)
            #expect(hypot(t.x - 195, t.y - 136) <= 38 + 1e-9)
            #expect((0...1).contains(t.a))
        }
    }

    @Test func sleepingLEDsAreDimAndLitOnesAreTheHeadsColour() {
        let cell = ArrivalWorld.cells.first { !$0.eye && abs($0.dx) < 1 && abs($0.dy) < 1 }!
        var leds = ArrivalWorld.Leds()
        let asleep = ArrivalWorld.led(cell: cell, prim: true, leds, now: 0, still: true, mono: mono, accent: accent, hot: mono)
        #expect(asleep.c == mono && abs(asleep.a - 0.27) < 1e-12, "not lit yet: the ink, faint")
        #expect(asleep.x == 195 + cell.dx * 7.4 && asleep.y == 188 + cell.dy * 7.4)
        leds.ign = -1e7
        leds.fuse = 1
        let fused = ArrivalWorld.led(cell: cell, prim: true, leds, now: 0, still: true, mono: mono, accent: accent, hot: mono)
        #expect(fused.c == accent && fused.a == 1, "run together: the face's colour")
        let dark = ArrivalWorld.led(cell: cell, prim: false, leds, now: 0, still: true, mono: mono, accent: accent, hot: mono)
        #expect(dark.a == 0, "a dot that lights no LED stays dark")
    }

    @Test func theBurstLeavesFromTheFace() throws {
        let land = try #require(ArrivalWorld.Land.bundled)
        var random = ArrivalWorld.Random()
        let dot = try #require(ArrivalWorld.dots(land: land, random: &random).first)
        let t = ArrivalWorld.burst(dot, prim: true, bx: 1, by: 0, face: (195, 296, 106), accent: accent, spark: mono)
        #expect(t.y == 296 && t.x > 195 + 106 && t.a == 0)
    }

    @Test func theStagesRestTargetsFollowItsMode() throws {
        let stage = ArrivalStage(place: ArrivalWorld.Place(secondsFromGMT: 0, identifier: "Europe/London"))
        #expect(stage.count == 1416)
        #expect(stage.mode == .stars)
        stage.setMode(.globe)
        stage.gp = ArrivalWorld.Globe(cx: 195, cy: 172, r: 60, rot: 0, tilt: 0.44)
        let globe = stage.restingTargets()
        #expect(globe.allSatisfy { hypot($0.x - 195, $0.y - 172) <= 60 + 1e-9 }, "Send the note: the globe at (195, 172), 60")
        stage.seed(dotsAt: globe)
        stage.toLED(cx: 195, cy: 188, pitch: 7.4, dur: 900, stagger: 300, swirl: 0.25)
        #expect(stage.mode == .led)
        let leds = stage.restingTargets()
        let cells = ArrivalWorld.cells
        #expect(stage.prim.filter { $0 }.count == cells.count, "found: every LED has its dot")
        for (i, t) in leds.enumerated() {
            let cell = cells[stage.cell[i]]
            #expect(abs(t.x - (195 + cell.dx * 7.4)) < 1e-9 && abs(t.y - (188 + cell.dy * 7.4)) < 1e-9)
        }
    }
}

@Suite struct FirstRunSwitchTests {
    @Test func onUnlessTurnedOffAndNeverOnTheMac() {
        #expect(FirstRunArrival.allowed(stored: nil, isMac: false) == true, "on by default (public beta 1247)")
        #expect(FirstRunArrival.allowed(stored: false, isMac: false) == false, "-HQFirstRunArrival NO")
        #expect(FirstRunArrival.allowed(stored: true, isMac: false) == true)
        #expect(FirstRunArrival.allowed(stored: nil, isMac: true) == false)
        #expect(FirstRunArrival.allowed(stored: true, isMac: true) == false)
        #expect(FirstRunArrival.allowed(stored: false, isMac: true) == false)
    }

    @Test func debugHooksKeepTodaysFirstRunUnlessNamed() {
        #expect(FirstRunArrival.allowed(stored: nil, debugHooks: true, isMac: false) == false)
        #expect(FirstRunArrival.allowed(stored: true, debugHooks: true, isMac: false) == true, "the arrival's own walk")
        #expect(FirstRunArrival.allowed(stored: false, debugHooks: true, isMac: false) == false)
    }

    @Test func onlyTheSignedOutRootDrawsIt() {
        #expect(FirstRunArrival.applies(on: true, root: true))
        #expect(!FirstRunArrival.applies(on: true, root: false), "never the Add Gateway sheet")
        #expect(!FirstRunArrival.applies(on: false, root: true))
    }

    @Test func nothingStoredMeansUnset() {
        let defaults = try! #require(UserDefaults(suiteName: "first-run-switch-\(UUID().uuidString)"))
        #expect(defaults.object(forKey: FirstRunArrival.key) == nil, "unset, so the default (on) applies")
        #expect(FirstRunArrival.key == "HQFirstRunArrival")
    }

    @MainActor @Test func theUpdateScreenWins() {
        let info = OutdatedGateway(version: "0.20.0", releaseDate: "2026.9.10")
        #expect(FirstRunArrival.next(after: .update(info), drawn: true) == .update, "the arrival is skipped")
        #expect(FirstRunArrival.next(after: .update(info), drawn: false) == .update)
        #expect(FirstRunArrival.next(after: .enter, drawn: true) == .arrival)
        #expect(FirstRunArrival.next(after: .enter, drawn: false) == .app, "switch off: straight in, as main")
    }

    @Test func theArrivingBotIsTheDefault() throws {
        let rows: [JSONValue] = [
            .object(["name": .string("ivy"), "is_default": .bool(false)]),
            .object(["name": .string("default"), "is_default": .bool(true)]),
            .object(["name": .string("wren")]),
        ]
        let profiles = rows.compactMap(RosterProfile.init(json:))
        #expect(FirstRunArrival.arriving(profiles)?.name == "default")
        #expect(FirstRunArrival.others(profiles).map(\.name) == ["ivy", "wren"])
        let marked = [RosterProfile(json: .object(["name": .string("otto"), "is_default": .bool(true)]))!,
                      RosterProfile(json: .object(["name": .string("juno"), "is_default": .bool(false)]))!]
        #expect(FirstRunArrival.arriving(marked)?.name == "otto")
        #expect(FirstRunArrival.arriving([]) == nil)
        #expect(FirstRunArrival.others([]).isEmpty, "no list, no count")
    }
}

@Suite struct FirstRunCopyTests {
    private typealias A = OnboardingCopy.Arrival

    @Test func theMocksWords() {
        #expect(A.helloLead == "Ask from anywhere. Get a ping the moment it’s done.")
        #expect(A.trust == "It stays on your computer. Only you get in.")
        #expect(A.whereEyebrow == "Step 1 of 3" && A.noteEyebrow == "Step 2 of 3" && A.foundEyebrow == "Step 3 of 3")
        #expect(A.noteHeading == "Send your Hermes this note.")
        #expect(A.sentHeading == "Sent. Hermes is on it.")
        #expect(A.foundHeading == "Found your Hermes.")
        #expect(A.hereHeading == "Hermes is here.")
        #expect(A.next.count == 3)
        #expect(A.next[2].title == "\(DeviceWord.Tap) the link", "tap through DeviceWord")
    }

    @Test func buttonsAreTitleCaseAndSentencesEndWell() {
        for title in [A.send, A.copy, A.usePassword, A.sayHello, A.haveAddress, A.myself] {
            let words = title.split(separator: " ").filter { !["a", "an", "the", "it", "to", "with", "of", "in"].contains($0) }
            #expect(words.allSatisfy { $0.first?.isUppercase == true }, "Title Case: \(title)")
        }
        for sentence in [A.helloLead, A.trust, A.whereLead, A.noteLead, A.sentLead, A.foundLead, A.hereLead] {
            #expect(sentence.first?.isUppercase == true && sentence.hasSuffix("."), Comment(rawValue: sentence))
        }
    }

    @Test func theNotesStartIsTheRealNote() {
        let excerpt = A.excerpt(OnboardingCopy.hermesConnectPrompt)
        #expect(excerpt.hasPrefix("“Please connect this computer to Hermes HQ"))
        #expect(excerpt.hasSuffix("…”"))
        #expect(!excerpt.contains("sign in"), "cut before “and sign in”")
        let tailnet = A.excerpt(OnboardingCopy.Tailnet.prompt)
        #expect(tailnet.contains("over Tailscale"), "the Tailscale kind shows its own start")
        #expect(A.excerpt("One line only") == "“One line only…”")
    }

    @Test func othersAreCountedNeverGuessed() {
        #expect(A.others(1) == "and 1 more agent came with it")
        #expect(A.others(3) == "and 3 more agents came with it")
    }

    @Test func todaysWordsAreUntouched() {
        #expect(OnboardingCopy.Welcome.start == "Get Started")
        #expect(OnboardingCopy.Welcome.haveAddress == "I Already Have an Address")
        #expect(OnboardingCopy.Start.heading == "Where is your Hermes?")
        #expect(OnboardingCopy.LetHermes.haveAddress == A.haveAddress)
    }
}

/// The first run's last beat, in the arriving bot's chat (ArrivalFirstWords).
@Suite struct FirstRunFirstWordsTests {
    private typealias W = ArrivalFirstWords
    private typealias A = OnboardingCopy.Arrival

    @Test func theRestWaitsForTheGreetingsTurnToEnd() {
        #expect(W.afterGreeting(ran: true, running: true, waited: 3, canAsk: true) == nil, "still writing")
        #expect(W.afterGreeting(ran: false, running: false, waited: 3, canAsk: true) == nil, "not begun yet")
        #expect(W.afterGreeting(ran: true, running: false, waited: 3, canAsk: true) == .ping)
        #expect(W.afterGreeting(ran: true, running: false, waited: 3, canAsk: false) == .starters, "iOS was asked before: no card")
    }

    @Test func aGreetingThatNeverComesHoldsNothingUpForLong() {
        #expect(W.afterGreeting(ran: false, running: false, waited: W.greetingWait, canAsk: false) == .starters)
        #expect(W.afterGreeting(ran: true, running: true, waited: W.greetingWait + 1, canAsk: true) == .ping)
        #expect(W.greetingWait <= 30)
    }

    @Test func theAskIsForAnAgentAndSaysWhatToWrite() {
        let ask = A.greetingPrompt
        #expect(ask.contains("Hermes HQ") && ask.contains(OnboardingCopy.device))
        #expect(ask.contains("one or two short sentences"))
        #expect(ask.contains("Don't use any tools"))
        #expect(!ask.contains("’"), "straight apostrophes, as the setup message's")
        #expect(!ask.contains("\n"))
    }

    @Test func theCardAndTheStarters() {
        #expect(A.pingTitle == "Get a Ping When It’s Done")
        #expect(A.pingBody.hasPrefix("Hermes HQ can tell you the moment Hermes finishes or needs you."))
        #expect(A.pingBody.hasSuffix(" asks next."))
        #expect(A.pingOn == "Turn On")
        #expect(A.starters == ["What can you do for me?", "What are you working on?", "Show me around"])
    }
}
