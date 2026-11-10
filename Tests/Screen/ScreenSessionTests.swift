// The Screen's state machine (docs/spec/3x-screen.md §4, §5.5, §5.8, §5.11, §5.12) against a gateway model with
// Hermes's lease rules and sockets the tests end by hand.

import Foundation
import Testing
@testable import HermesHQNative

@MainActor @Suite(.serialized) struct ScreenSessionTests {
    private func keys(_ call: FakeGatewayClient.Call?) -> [String] { (call?.params.object?.keys.sorted()) ?? ["<no call>"] }

    // MARK: Opening (L516, S0–S4)

    @Test func opensToALivePictureAndOnlyWatches() async {
        let rig = SessionRig()
        #expect(rig.session.phase == .connecting)
        #expect(await rig.openLive())
        #expect(rig.display.methods == ["display.status", "display.observe"])
        #expect(keys(rig.display.calls("display.status").first) == ["profile"])
        #expect(keys(rig.display.calls("display.observe").first) == ["profile"])          // no viewer id yet
        #expect(rig.session.caption == "Hermes is in control")
        #expect(!rig.session.holding && rig.session.viewer != nil)
        #expect(rig.session.label == "This Mac · 64×48")
        #expect(rig.frames >= 1 && rig.notices.contains(.live))
        // Watching sends nothing but the handshake and update requests, whatever the view asks for.
        rig.session.sendPointer(mask: 1, x: 3, y: 3)
        rig.session.sendKeys(ScreenKeys.text("a"))
        rig.session.type("hello")
        rig.session.paste("clip")
        try? await Task.sleep(for: .milliseconds(150))
        #expect(rig.socket?.inputs.isEmpty == true)
        let kinds = Set(rig.socket?.sent.compactMap(\.first) ?? [])
        let allowed: Set<UInt8> = [82, 1, 0, 2, 3]                                       // 82 = "R" of the version line
        #expect(kinds.isSubset(of: allowed))
        rig.session.leave()
    }

    @Test func theStatusNeverArrivingSaysSoAndRetryWorks() async {
        let rig = SessionRig()
        rig.display.set { $0.hang = ["display.status"] }
        rig.session.open()
        #expect(rig.session.phase == .connecting)
        #expect(await screenWait(3) { rig.session.phase == .noAnswer(nil) })
        #expect(rig.display.calls("display.observe").isEmpty)
        rig.display.set { $0.hang = [] }
        rig.session.open()                                                              // "Retry"
        #expect(rig.session.phase == .connecting)
        #expect(await rig.live())
        #expect(rig.display.calls("display.status").count == 2)
        rig.session.leave()
    }

    /// The request's own 20 s limit can beat the 20 s wait by a hair: the words are the same either way.
    @Test func aStatusRequestThatTimesOutReadsAsNeverArrived() async {
        let rig = SessionRig()
        rig.display.set { $0.fail["display.status"] = RPCError.timedOut("display.status", after: .seconds(20)) }
        rig.session.open()
        #expect(await screenWait(2) { rig.session.phase == .noAnswer(nil) })
        rig.session.leave()
    }

    @Test func aFailedStatusShowsTheGatewaysWordsAtOnce() async {
        let rig = SessionRig()
        rig.display.set { $0.fail["display.status"] = RPCError(code: 5300, message: "Bot Desktop state is unreadable.", data: nil) }
        rig.session.open()
        #expect(await screenWait(2) { rig.session.phase == .noAnswer("Bot Desktop state is unreadable.") })
        // The app coming to the front asks again by itself.
        rig.display.set { $0.fail = [:] }
        rig.session.resumeSignal()
        #expect(await rig.live())
        rig.session.leave()
    }

    @Test func aSlowStatusIsNotAFailure() async {
        let rig = SessionRig()
        rig.display.set { $0.delay["display.status"] = .milliseconds(150) }
        rig.session.open()
        #expect(await rig.live())
        #expect(!rig.phases.contains { if case .noAnswer = $0 { true } else { false } })
        rig.session.leave()
    }

    @Test func anOlderAnswerNeverReplacesANewerOne() async {
        let rig = SessionRig()
        rig.display.set { $0.running = false; $0.delay["display.status"] = .milliseconds(250) }
        rig.session.open()
        try? await Task.sleep(for: .milliseconds(50))
        rig.display.set { $0.delay = [:]; $0.installed = false }
        rig.session.open()
        #expect(await screenWait(2) { rig.session.phase == .missing })
        try? await Task.sleep(for: .milliseconds(400))                                  // the first, slower answer lands now
        #expect(rig.session.phase == .missing)
        rig.session.leave()
    }

    @Test func eachStateOfABotWithoutALiveScreen() async {
        let rig = SessionRig()
        rig.display.set { $0.fail["display.status"] = RPCError(code: -32601, message: "Method not found", data: nil) }
        rig.session.open()
        #expect(await screenWait(2) { rig.session.phase == .fallback(.unavailable) })
        #expect(rig.service.kind(for: "default") == .screenshots)
        rig.display.set { $0.fail = [:]; $0.supported = false }
        rig.session.open()
        #expect(await screenWait(2) { rig.session.phase == .fallback(.unsupported) })
        rig.display.set { $0.supported = true; $0.installed = false; $0.installCommand = "sudo apt install tigervnc" }
        rig.session.open()
        #expect(await screenWait(2) { rig.session.phase == .missing })
        #expect(rig.session.status?.installCommand == "sudo apt install tigervnc")
        #expect(rig.service.kind(for: "default") == .live)
        rig.display.set { $0.installed = true; $0.running = false; $0.blocker = "Allow Screen Recording for Dispatch Screen on the Mac" }
        rig.session.open()
        #expect(await screenWait(2) { rig.session.phase == .fallback(.blocked) })
        #expect(rig.session.status?.blocker == "Allow Screen Recording for Hermes HQ Screen on the Mac")
        rig.display.set { $0.blocker = nil }
        rig.session.open()
        #expect(await screenWait(2) { rig.session.phase == .off })
        #expect(rig.display.calls("display.observe").isEmpty)
        rig.session.leave()
    }

    @Test func startScreenStartsItAndAFailureIsShown() async {
        let rig = SessionRig()
        rig.display.set { $0.running = false; $0.fail["display.start"] = RPCError(code: 5300, message: "Xvnc could not start", data: nil) }
        rig.session.open()
        #expect(await screenWait(2) { rig.session.phase == .off })
        rig.session.start()
        #expect(rig.session.busy == .start)
        #expect(await screenWait(2) { rig.session.errorLine == "Xvnc could not start" && rig.session.busy == nil })
        rig.display.set { $0.fail = [:] }
        rig.session.start()
        #expect(await rig.live())
        #expect(rig.session.errorLine == nil)
        #expect(keys(rig.display.calls("display.start").last) == ["profile"])
        rig.session.leave()
    }

    @Test func aStatusEventOpensTheScreenThatWasOff() async {
        let rig = SessionRig()
        rig.display.set { $0.running = false }
        rig.session.open()
        #expect(await screenWait(2) { rig.session.phase == .off })
        rig.display.set { $0.running = true }
        rig.display.emitStatus()
        #expect(await rig.live())
        // And one that says it stopped closes the stream without a hand-back.
        rig.display.set { $0.running = false }
        rig.display.emitStatus()
        #expect(await screenWait(2) { rig.session.phase == .off })
        #expect(rig.socket?.closes == [false])
        rig.session.leave()
    }

    // MARK: Control (L509)

    @Test func takeOverThenHandBack() async {
        let rig = SessionRig()
        #expect(await rig.openLive())
        let viewer = rig.session.viewer
        #expect(await rig.takeOver())
        let acquire = rig.display.calls("display.lease.acquire").first
        #expect(keys(acquire) == ["profile", "viewer_id"] && acquire?.params["viewer_id"]?.string == viewer?.id)
        #expect(rig.session.caption == "You are in control" && rig.notices.contains(.controlStarted))
        #expect(rig.display.lease.holder == "human" && rig.display.lease.hash == viewer?.hash)
        // DECISION D14: the first input after control starts releases any button a dropped link left down.
        rig.session.sendPointer(mask: 0, x: 10, y: 12)
        rig.session.sendPointer(mask: 1, x: 10, y: 12)
        rig.session.sendPointer(mask: 0, x: 10, y: 12)
        rig.session.sendKeys(ScreenKeys.text("a"))
        #expect(await screenWait { SessionRig.inputs(rig.socket).count == 6 })
        #expect(SessionRig.inputs(rig.socket) == ["pointer 0 32,24", "pointer 0 10,12", "pointer 1 10,12", "pointer 0 10,12", "key 61 down", "key 61 up"])
        rig.session.handBack()
        #expect(await screenWait { !rig.session.holding && rig.session.busy == nil })
        let release = rig.display.calls("display.lease.release").first
        #expect(keys(release) == ["profile", "viewer_id"] && release?.params["viewer_id"]?.string == viewer?.id)
        #expect(rig.session.caption == "Hermes is in control" && rig.notices.contains(.controlEnded))
        rig.session.sendPointer(mask: 1, x: 1, y: 1)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(SessionRig.inputs(rig.socket).count == 6)
        #expect(rig.socket?.closes.isEmpty == true)                                      // the stream stays up to watch
        rig.session.leave()
    }

    @Test func aHeldButtonIsReleasedBeforeControlIsGivenAway() async {
        let rig = SessionRig()
        #expect(await rig.openLive())
        #expect(await rig.takeOver())
        rig.session.sendPointer(mask: 1, x: 20, y: 20)                                   // a drag in progress
        rig.session.handBack()
        #expect(await screenWait { !rig.session.holding })
        #expect(SessionRig.inputs(rig.socket).suffix(2) == ["pointer 1 20,20", "pointer 0 20,20"])
        // The same before a pause.
        #expect(await rig.takeOver())
        rig.session.sendPointer(mask: 1, x: 30, y: 30)
        rig.session.setOnView(false, immediately: true)
        #expect(await screenWait { rig.socket?.closes == [false] })
        #expect(SessionRig.inputs(rig.socket).last == "pointer 0 30,30", "\(SessionRig.inputs(rig.socket))")
        rig.session.leave()
    }

    @Test func aRefusedTakeOverReadsInFullUntilDismissedOrUntilOneWorks() async {
        let rig = SessionRig()
        #expect(await rig.openLive())
        rig.display.set { $0.fail["display.lease.acquire"] = RPCError(code: 5300, message: "Lease store is busy", data: nil) }
        rig.session.takeOver()
        #expect(await screenWait { rig.session.errorLine == "Lease store is busy" })
        #expect(!rig.session.holding && rig.session.busy == nil)
        rig.session.dismissError()
        #expect(rig.session.errorLine == nil)
        rig.session.takeOver()
        #expect(await screenWait { rig.session.errorLine != nil })
        rig.display.set { $0.fail = [:] }
        #expect(await rig.takeOver())
        #expect(rig.session.errorLine == nil)
        rig.session.leave()
    }

    @Test func anotherViewerHoldsAndForceReturnsItToTheBot() async {
        let rig = SessionRig()
        #expect(await rig.openLive())
        rig.display.otherTakes()
        #expect(await screenWait { rig.session.otherHolds })
        #expect(rig.session.caption == "Another viewer is in control" && rig.session.tone == .other)
        rig.session.forceHandBack()
        #expect(await screenWait { !rig.session.otherHolds && rig.session.busy == nil })
        let release = rig.display.calls("display.lease.release").first
        #expect(keys(release) == ["force", "profile"] && release?.params["force"]?.bool == true)
        #expect(rig.display.lease.holder == "agent")
        rig.session.leave()
    }

    @Test func aStaleLeaseEventIsIgnored() async {
        let rig = SessionRig()
        #expect(await rig.openLive())
        #expect(await rig.takeOver())
        let epoch = rig.session.lease?.epoch ?? 0
        rig.display.client.emit(GatewayEvent(type: "display.lease", sessionId: "", seq: nil,
                                             payload: ["profile_key": .string(FakeDisplay.homeKey), "lease": ["holder": "agent", "viewer_hash": .null, "epoch": .number(Double(epoch - 1))]]))
        rig.display.client.emit(GatewayEvent(type: "display.lease", sessionId: "", seq: nil,
                                             payload: ["profile_key": "/fixture/home/profiles/someone-else", "lease": ["holder": "agent", "viewer_hash": .null, "epoch": .number(Double(epoch + 5))]]))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(rig.session.holding)
        rig.session.leave()
    }

    @Test func typedTextGoesOutInSlicesAndStopsWhenControlEnds() async {
        let rig = SessionRig()
        rig.display.set { $0.display = ":7" }                                            // a Linux screen: paste is typed
        #expect(await rig.openLive())
        #expect(await rig.takeOver())
        #expect(rig.session.paste(String(repeating: "x", count: 5_000)))
        #expect(rig.session.typingBacklog > 0)                                           // not all at once
        #expect(await screenWait { SessionRig.inputs(rig.socket).filter { $0.hasPrefix("key") }.count == 10_000 })
        #expect(rig.session.typingBacklog == 0)
        // A long paste, then the bot takes control back: the rest is never sent.
        #expect(rig.session.paste(String(repeating: "y", count: 200_000)))
        rig.display.agentTakes()
        #expect(await screenWait { !rig.session.holding })
        #expect(rig.session.typingBacklog == 0)
        try? await Task.sleep(for: .milliseconds(200))
        let typed = SessionRig.inputs(rig.socket).filter { $0.hasPrefix("key 79") }.count
        #expect(typed < 400_000 && typed % 2 == 0)                                       // whole key presses only
        rig.session.leave()
    }

    @Test func pasteOnAMacSetsTheClipboardThenCommandV() async {
        let rig = SessionRig()
        #expect(await rig.openLive())
        #expect(await rig.takeOver())
        #expect(rig.session.paste("héllo"))
        #expect(await screenWait { SessionRig.inputs(rig.socket).count == 6 })
        #expect(SessionRig.inputs(rig.socket).suffix(5) == ["cut 5", "key ffeb down", "key 76 down", "key 76 up", "key ffeb up"])
        #expect(!rig.session.paste(nil) && !rig.session.paste(""))
        rig.session.leave()
    }

    // MARK: Eviction and stream endings (L512, L515)

    @Test func evictionWatchesAgainAndAFourthInARowAsksForATap() async {
        let rig = SessionRig()
        #expect(await rig.openLive())
        #expect(await rig.takeOver())
        rig.display.otherTakes()                                                        // closes our socket with 4000
        #expect(await screenWait { rig.notices.contains(.controlTaken) })
        #expect(await screenWait { rig.display.sockets.count == 2 && rig.session.phase == .live })
        #expect(!rig.session.holding && rig.session.otherHolds)
        #expect(rig.display.calls("display.lease.acquire").count == 1)                   // no reclaim: the lease is theirs
        rig.session.sendPointer(mask: 1, x: 1, y: 1)
        try? await Task.sleep(for: .milliseconds(80))
        #expect(rig.display.sockets[1].inputs.isEmpty)
        // A gateway that evicts every fresh attach: three are followed, the fourth stops.
        for round in 2...3 {
            rig.socket?.end(code: 4000, reason: "control-taken")
            #expect(await screenWait { rig.display.sockets.count == round + 1 && rig.session.phase == .live })
        }
        rig.socket?.end(code: 4000)
        #expect(await screenWait { rig.session.phase == .ended(title: "Another viewer took control. Watching only.", detail: nil) })
        #expect(rig.display.sockets.count == 4)
        rig.session.reconnect()
        #expect(await rig.live())
        rig.session.leave()
    }

    @Test func evictionsFarApartAreEachFollowed() async {
        let rig = SessionRig()
        #expect(await rig.openLive())
        for round in 1...5 {
            rig.clock.advance(11)
            rig.socket?.end(code: 4000)
            #expect(await screenWait { rig.display.sockets.count == round + 1 && rig.session.phase == .live })
        }
        rig.session.leave()
    }

    @Test func aDroppedStreamReattachesOnceThenAsks() async {
        let rig = SessionRig()
        #expect(await rig.openLive())
        rig.socket?.end()                                                               // the link dropped: no close frame
        #expect(await screenWait { rig.display.sockets.count == 2 && rig.session.phase == .live })
        #expect(!rig.phases.contains { if case .ended = $0 { true } else { false } })
        rig.socket?.end()                                                               // again inside the window
        #expect(await screenWait { rig.session.phase == .ended(title: "Screen Stopped", detail: nil) })
        try? await Task.sleep(for: .milliseconds(200))
        #expect(rig.display.sockets.count == 2)                                          // no loop
        rig.session.reconnect()
        #expect(await rig.live())
        // A drop long after the last one gets its own quiet retry.
        rig.clock.advance(60)
        rig.socket?.end(code: 1011)
        #expect(await screenWait { rig.display.sockets.count == 4 && rig.session.phase == .live })
        rig.session.leave()
    }

    @Test func aRetryThatCannotAttachAsksForATap() async {
        let rig = SessionRig()
        #expect(await rig.openLive())
        rig.display.set { $0.dialFails = true }
        rig.socket?.end()
        #expect(await screenWait { rig.session.phase == .ended(title: "Screen Stopped", detail: nil) })
        rig.display.set { $0.dialFails = false }
        rig.session.reconnect()
        #expect(await rig.live())
        rig.session.leave()
    }

    @Test func aFirstAttachThatFailsSaysWhy() async {
        let rig = SessionRig()
        rig.display.set { $0.fail["display.observe"] = RPCError(code: 5300, message: "Too many viewers", data: nil) }
        rig.session.open()
        #expect(await screenWait { rig.session.phase == .ended(title: "Screen Stopped", detail: "Too many viewers.") })
        rig.session.leave()
    }

    @Test func aSpentTicketObservesAgainOnce() async {
        let rig = SessionRig()
        #expect(await rig.openLive())
        rig.socket?.end(code: 4401)
        #expect(await screenWait { rig.display.sockets.count == 2 && rig.session.phase == .live })
        #expect(rig.display.calls("display.observe").count == 2)
        rig.session.leave()
    }

    /// Spec §2.4: 4401 → observe again once, then "Screen Stopped". Never a third try by itself.
    @Test func aSecondRefusedTicketEndsTheStreamInWords() async {
        let rig = SessionRig()
        #expect(await rig.openLive())
        rig.display.set { $0.pictures = false }                 // the next socket is refused before any picture
        rig.socket?.end(code: 4401)
        #expect(await screenWait { rig.display.sockets.count == 2 })
        rig.socket?.end(code: 4401)
        #expect(await screenWait { rig.session.phase == .ended(title: "Screen Stopped", detail: nil) })
        rig.session.setOnView(true)                             // the viewer finishing its appearance is not a resume
        try? await Task.sleep(for: .milliseconds(400))          // well past the automatic retry's 40 ms
        #expect(rig.display.calls("display.observe").count == 2)
        #expect(rig.display.sockets.count == 2)
        // "Reconnect" starts over, with its own second try.
        rig.session.reconnect()
        #expect(await screenWait { rig.display.sockets.count == 3 })
        rig.display.set { $0.pictures = true }
        rig.socket?.end(code: 4401)
        #expect(await screenWait { rig.display.sockets.count == 4 && rig.session.phase == .live })
        #expect(rig.display.calls("display.observe").count == 4)
        // A ticket that worked resets the count: the next spent ticket is retried again.
        rig.socket?.end(code: 4401)
        #expect(await screenWait { rig.display.sockets.count == 5 && rig.session.phase == .live })
        rig.session.leave()
    }

    @Test func notRunningReadsTheStatusAndShowsOff() async {
        let rig = SessionRig()
        #expect(await rig.openLive())
        rig.display.set { $0.running = false }
        rig.socket?.end(code: 4001)
        #expect(await screenWait { rig.session.phase == .off })
        #expect(rig.display.sockets.count == 1)
        rig.session.leave()
    }

    @Test func badDataFromTheGatewayEndsTheStreamInWords() async {
        let rig = SessionRig()
        #expect(await rig.openLive())
        rig.socket?.push(Data([99, 0, 0, 0]))                                           // an unknown server message
        #expect(await screenWait { rig.display.sockets.count == 2 && rig.session.phase == .live })
        rig.socket?.pushText()
        #expect(await screenWait { rig.session.phase == .ended(title: "Screen Stopped", detail: nil) })
        rig.session.leave()
    }

    // MARK: Out of view (L515)

    @Test func outOfViewClosesWithoutHandingBackAndBackOnViewHoldsAgain() async {
        let rig = SessionRig()
        #expect(await rig.openLive())
        #expect(await rig.takeOver())
        let viewer = rig.session.viewer
        rig.session.setOnView(false, immediately: true)
        #expect(await screenWait { rig.socket?.closes == [false] })
        #expect(rig.display.lease.holder == "human")                                     // a person's control survives it
        #expect(rig.display.calls("display.lease.release").isEmpty)
        #expect(rig.session.phase == .attaching && !rig.session.onView)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(rig.display.sockets.count == 1)                                          // nothing re-attaches while away
        rig.session.setOnView(true)
        #expect(await screenWait { rig.display.sockets.count == 2 && rig.session.phase == .live })
        // The same /api/ws connection honours the id again: still in control, no second acquire.
        #expect(rig.display.calls("display.observe").last?.params["viewer_id"]?.string == viewer?.id)
        #expect(rig.session.viewer == viewer && rig.session.holding)
        #expect(rig.display.calls("display.lease.acquire").count == 1)
        rig.session.leave()
    }

    @Test func aShortLookAwayDoesNotCloseTheStream() async {
        let rig = SessionRig()
        #expect(await rig.openLive())
        rig.session.setOnView(false)                                                    // Control Centre, a call banner
        try? await Task.sleep(for: .milliseconds(40))
        rig.session.setOnView(true)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(rig.socket?.closes.isEmpty == true && rig.display.sockets.count == 1)
        rig.session.setOnView(false)                                                    // and a long one does
        #expect(await screenWait { rig.socket?.closes == [false] })
        rig.session.leave()
    }

    @Test func resumeSignalsOnlyTouchAStreamThatIsNotLive() async {
        let rig = SessionRig()
        #expect(await rig.openLive())
        rig.session.resumeSignal()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(rig.display.sockets.count == 1)
        rig.display.set { $0.dialFails = true }
        rig.socket?.end()
        #expect(await screenWait { rig.session.phase == .ended(title: "Screen Stopped", detail: nil) })
        rig.display.set { $0.dialFails = false }
        rig.session.resumeSignal()                                                      // the network came back
        #expect(await rig.live())
        rig.session.leave()
    }

    // MARK: Holds (L512)

    @Test func controlSurvivesANewGatewayConnection() async {
        let rig = SessionRig()
        #expect(await rig.openLive())
        #expect(await rig.takeOver())
        let old = rig.session.viewer
        let before = rig.display.methods.count
        rig.display.reconnectGateway()
        #expect(await screenWait { rig.session.viewer != old && rig.session.holding && rig.session.phase == .live })
        #expect(Array(rig.display.methods[before...].prefix(3)) == ["display.observe", "display.status", "display.lease.acquire"])
        let observe = rig.display.calls("display.observe").last
        #expect(observe?.params["viewer_id"]?.string == old?.id)
        #expect(rig.display.calls("display.lease.acquire").last?.params["viewer_id"]?.string == rig.session.viewer?.id)
        #expect(rig.display.lease.hash == rig.session.viewer?.hash && rig.display.lease.holder == "human")
        #expect(rig.holds.saved(rig.account, "default")?.id == rig.session.viewer?.id)
        // And the new stream takes input.
        rig.session.sendPointer(mask: 0, x: 5, y: 5)
        #expect(await screenWait { SessionRig.inputs(rig.socket).last == "pointer 0 5,5" })
        rig.session.leave()
    }

    @Test func noReclaimWhenSomeoneElseTookControlMeanwhile() async {
        let rig = SessionRig()
        #expect(await rig.openLive())
        #expect(await rig.takeOver())
        // Between the observe and the recheck another person takes it.
        rig.display.set {
            $0.before["display.status"] = { s in
                s.holder = "human"
                s.hash = ScreenWire.viewerHash("a-stranger")
                s.epoch += 1
            }
        }
        rig.display.reconnectGateway()
        #expect(await screenWait { rig.session.phase == .live && rig.display.sockets.count == 2 })
        #expect(rig.display.calls("display.lease.acquire").count == 1)                   // only the first Take over
        #expect(!rig.session.holding && rig.session.otherHolds)
        rig.session.leave()
    }

    @Test func aFailedRecheckAcquiresNothing() async {
        let rig = SessionRig()
        #expect(await rig.openLive())
        #expect(await rig.takeOver())
        rig.display.set { $0.fail["display.status"] = RPCError(code: 5300, message: "busy", data: nil) }
        rig.display.reconnectGateway()
        #expect(await screenWait { rig.display.sockets.count == 2 && rig.session.phase == .live })
        #expect(rig.display.calls("display.lease.acquire").count == 1)
        #expect(!rig.session.holding)
        rig.session.leave()
    }

    @Test func closingWhileInControlHandsBackThroughTheClose() async {
        let rig = SessionRig()
        #expect(await rig.openLive())
        #expect(await rig.takeOver())
        #expect(rig.holds.saved(rig.account, "default") != nil)
        rig.session.sendPointer(mask: 1, x: 8, y: 8)
        rig.session.leave()
        #expect(await screenWait { rig.socket?.closes.first == true })                   // close frame 1000
        #expect(SessionRig.inputs(rig.socket).last == "pointer 0 8,8")                   // the button went up first
        #expect(rig.display.calls("display.lease.release").isEmpty)
        // Not forgotten on faith (review finding 2): the hold stays saved until the gateway says the bot has control.
        #expect(rig.holds.saved(rig.account, "default") != nil && rig.holds.own(rig.account, "default") == nil)
        rig.session.leave()                                                             // idempotent
        #expect(rig.socket?.closes.count == 1)
        rig.display.agentTakes()                                                        // what the close frame makes Hermes send
        #expect(await screenWait { rig.holds.saved(rig.account, "default") == nil })
    }

    /// Sign-out and gateway switch: the hand-back is finished, and answered, before the caller ends the client.
    @Test func leavingBeforeSignOutWaitsForTheGatewaysWord() async {
        let rig = SessionRig()
        #expect(await rig.openLive())
        #expect(await rig.takeOver())
        let id = rig.session.viewer?.id
        rig.session.sendPointer(mask: 1, x: 8, y: 8)
        await rig.service.handBackBeforeLeaving()
        // All of it is true the moment the call returns: no waiting here.
        #expect(rig.session.left)
        #expect(rig.socket?.closes == [true])                                            // close frame 1000, sent by the sender itself
        #expect(SessionRig.inputs(rig.socket).last == "pointer 0 8,8")
        let release = rig.display.calls("display.lease.release").last
        #expect(release?.params["viewer_id"]?.string == id && release?.params["force"]?.bool == true)
        #expect(rig.display.lease.holder == "agent")
        #expect(rig.holds.saved(rig.account, "default") == nil && rig.holds.own(rig.account, "default") == nil)
        rig.service.shutdown()                                                          // what tearDown does next: nothing left to do
        #expect(rig.socket?.closes.count == 1 && rig.display.calls("display.lease.release").count == 1)
    }

    @Test func aHandBackTheGatewayNeverAnsweredKeepsTheHold() async {
        let rig = SessionRig()
        #expect(await rig.openLive())
        #expect(await rig.takeOver())
        rig.display.set { $0.fail["display.lease.release"] = RPCError(code: -32000, message: "not connected", data: nil) }
        await rig.service.handBackBeforeLeaving()
        #expect(rig.session.left && rig.socket?.closes == [true])
        #expect(rig.holds.saved(rig.account, "default") != nil)                           // the next launch offers Resume / Hand back
        #expect(rig.holds.own(rig.account, "default") == nil)                             // and nothing takes it back silently
    }

    @Test func aGatewayThatHangsDoesNotHoldSignOutUp() async {
        let rig = SessionRig()
        #expect(await rig.openLive())
        #expect(await rig.takeOver())
        rig.display.set { $0.hang.insert("display.lease.release") }
        let began = ContinuousClock.now
        await rig.service.handBackBeforeLeaving(limit: .milliseconds(600))
        #expect(ContinuousClock.now - began < .seconds(3))
        #expect(rig.holds.saved(rig.account, "default") != nil)
    }

    @Test func leavingBeforeSignOutWithNoScreenOpenDoesNotWait() async {
        let rig = SessionRig()
        rig.session.leave()
        let began = ContinuousClock.now
        await rig.service.handBackBeforeLeaving()
        #expect(ContinuousClock.now - began < .milliseconds(200))
        #expect(rig.display.methods.isEmpty)
    }

    @Test func aHoldSavedByAnEarlierRunIsReleasedAndAnsweredBeforeSignOut() async {
        let rig = SessionRig()
        #expect(await rig.openLive())
        #expect(await rig.takeOver())
        rig.session.setOnView(false, immediately: true)                                  // holding, the stream down
        #expect(await screenWait { rig.socket?.closes == [false] })
        await rig.service.handBackBeforeLeaving()
        #expect(rig.display.lease.holder == "agent" && rig.holds.saved(rig.account, "default") == nil)
    }

    @Test func closingWithTheStreamDownReleasesById() async {
        let rig = SessionRig()
        #expect(await rig.openLive())
        #expect(await rig.takeOver())
        let viewer = rig.session.viewer
        rig.session.setOnView(false, immediately: true)                                 // the stream is down, the lease is still ours
        rig.session.leave()
        #expect(await screenWait { rig.display.calls("display.lease.release").count == 1 })
        let release = rig.display.calls("display.lease.release").first
        #expect(keys(release) == ["force", "profile", "viewer_id"])
        #expect(release?.params["viewer_id"]?.string == viewer?.id && release?.params["force"]?.bool == true)
        #expect(await screenWait { rig.holds.saved(rig.account, "default") == nil })
        #expect(rig.display.lease.holder == "agent")
    }

    @Test func closingWhileWatchingReleasesNothing() async {
        let rig = SessionRig()
        #expect(await rig.openLive())
        rig.session.leave()
        #expect(await screenWait { rig.socket?.closes == [false] })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(rig.display.calls("display.lease.release").isEmpty)
    }

    @Test func offlineNothingIsForgotten() async {
        let rig = SessionRig()
        #expect(await rig.openLive())
        #expect(await rig.takeOver())
        rig.session.setOnView(false, immediately: true)
        rig.display.set { $0.fail["display.lease.release"] = RPCError(code: -32000, message: "not connected", data: nil) }
        rig.session.leave()
        #expect(await screenWait { rig.display.calls("display.lease.release").count == 1 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(rig.holds.saved(rig.account, "default") != nil)                           // the next launch offers it again
    }

    @Test func aHoldFromAnEarlierRunIsOfferedNotTaken() async {
        // An earlier run of the app took control and was killed.
        let first = SessionRig()
        #expect(await first.openLive())
        #expect(await first.takeOver())
        let old = first.session.viewer
        // The relaunch: a new service and connection, the same UserDefaults, the gateway's lease untouched.
        let rig = SessionRig(defaults: first.defaults)
        rig.display.set { [hash = old?.hash] in
            $0.holder = "human"
            $0.hash = hash
            $0.epoch = 9
        }
        #expect(await rig.openLive())
        #expect(rig.session.held?.id == old?.id && !rig.session.holding && !rig.session.otherHolds)
        #expect(rig.session.caption == "You were in control")
        #expect(rig.display.calls("display.lease.acquire").isEmpty)                      // nothing is reclaimed silently
        // "Hand back" releases the saved id with force.
        rig.session.handBack()
        #expect(await screenWait { rig.session.held == nil && rig.session.busy == nil })
        let release = rig.display.calls("display.lease.release").first
        #expect(keys(release) == ["force", "profile", "viewer_id"] && release?.params["viewer_id"]?.string == old?.id)
        #expect(rig.display.lease.holder == "agent" && rig.holds.saved(rig.account, "default") == nil)
        rig.session.leave()
        first.session.leave()
    }

    @Test func resumeControlTakesItWithTheNewId() async {
        let first = SessionRig()
        #expect(await first.openLive())
        #expect(await first.takeOver())
        let old = first.session.viewer
        let rig = SessionRig(defaults: first.defaults)
        rig.display.set { [hash = old?.hash] in
            $0.holder = "human"
            $0.hash = hash
            $0.epoch = 9
        }
        #expect(await rig.openLive())
        #expect(rig.session.held != nil)
        #expect(await rig.takeOver())                                                   // "Resume control"
        #expect(rig.session.caption == "You are in control" && rig.session.held == nil)
        #expect(rig.holds.saved(rig.account, "default")?.id == rig.session.viewer?.id)
        // Closing a Screen that only offered an old hold still hands that hold back.
        let third = SessionRig(defaults: first.defaults)
        third.display.set { [hash = rig.session.viewer?.hash] in
            $0.holder = "human"
            $0.hash = hash
            $0.epoch = 12
        }
        #expect(await third.openLive())
        let saved = third.session.held
        #expect(saved != nil)
        third.session.leave()
        #expect(await screenWait { third.display.calls("display.lease.release").count == 1 })
        #expect(third.display.calls("display.lease.release").first?.params["viewer_id"]?.string == saved?.id)
        rig.session.leave()
        first.session.leave()
    }

    @Test func closedWhileAReclaimWasInFlightTheNewIdIsReleased() async {
        let rig = SessionRig()
        #expect(await rig.openLive())
        #expect(await rig.takeOver())
        rig.display.set { $0.delay["display.lease.acquire"] = .milliseconds(250) }
        rig.display.reconnectGateway()
        #expect(await screenWait { rig.display.calls("display.lease.acquire").count == 2 })
        rig.session.leave()                                                             // Close before the acquire answers
        #expect(await screenWait(3) { rig.display.calls("display.lease.release").contains { $0.params["force"]?.bool == true } })
        #expect(await screenWait(3) { rig.display.lease.holder == "agent" })
    }

    // MARK: Mac health (L514)

    @Test func aMacScreenPollsItsHealthAndALinuxOneNeverDoes() async {
        let rig = SessionRig()
        #expect(await rig.openLive())
        #expect(await screenWait { rig.session.mac?.inputReady == true })
        #expect(rig.session.canTake)
        #expect(await screenWait(3) { rig.display.client.restLog.count >= 3 })           // at once, then on the interval
        #expect(rig.display.client.restLog.allSatisfy { $0.path == "/api/plugins/hermes-hq-screen/health" })
        // Out of view: no more reads. Back: one at once.
        rig.session.setOnView(false, immediately: true)
        try? await Task.sleep(for: .milliseconds(100))
        let paused = rig.display.client.restLog.count
        try? await Task.sleep(for: .milliseconds(600))
        #expect(rig.display.client.restLog.count == paused)
        rig.session.setOnView(true)
        #expect(await screenWait { rig.display.client.restLog.count > paused })
        rig.session.leave()

        let linux = SessionRig()
        linux.display.set { $0.display = ":7" }
        #expect(await linux.openLive())
        try? await Task.sleep(for: .milliseconds(400))
        #expect(linux.display.client.restLog.isEmpty)
        #expect(linux.session.canTake && linux.session.mac == nil)
        linux.session.leave()
    }

    @Test func onAMacTakeOverWaitsForInputToBeReady() async {
        let rig = SessionRig()
        let answer = Locked(#"{"installed":true,"control":false,"helper":{"ok":true,"tcc":{"screen":true,"events":false}}}"#)
        rig.display.client.onRest { _, _ in Data(answer.value.utf8) }
        #expect(await rig.openLive())
        #expect(await screenWait { rig.session.mac != nil })
        #expect(!rig.session.canTake && rig.session.mac?.control == false)
        rig.session.takeOver()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(rig.display.calls("display.lease.acquire").isEmpty)
        // The helper changes and says so with a status event: read at once, not at the next poll.
        answer.set(#"{"installed":true,"control":true,"helper":{"ok":true,"locked":true,"tcc":{"screen":true,"events":true}}}"#)
        rig.display.emitStatus()
        #expect(await screenWait(1) { rig.session.mac?.locked == true && rig.session.canTake })
        // No plugin at all on a Mac: readiness is unknown, so no Take over.
        rig.display.client.onRest { _, _ in throw HTTPError(status: 404, body: nil) }
        #expect(await screenWait(3) { rig.session.mac == nil })
        #expect(!rig.session.canTake)
        rig.session.leave()
    }
}

@MainActor @Suite(.serialized) struct ScreenServiceTests {
    @Test func theMenuLabelFollowsWhatIsKnownAndIsRememberedForTheGateway() async {
        let rig = SessionRig()
        #expect(rig.service.kind(for: "default") == .unknown && rig.service.kind(for: "writer") == .unknown)
        #expect(rig.display.methods.isEmpty)                                            // asking for a label reads nothing
        #expect(await rig.openLive())
        #expect(rig.service.kind(for: "default") == .live)
        #expect(rig.service.kind(for: "writer") == .live)                               // never opened: the gateway's kind
        rig.session.leave()
        #expect(rig.service.kind(for: "default") == .live)
        #expect(rig.holds.rememberedKind(rig.account) == .live)
        // The gateway loses its screen: the next open learns it and the label follows, for a relaunch too.
        rig.display.set { $0.supported = false }
        rig.reopen()
        rig.session.open()
        #expect(await screenWait { rig.session.phase == .fallback(.unsupported) })
        #expect(rig.service.kind(for: "default") == .screenshots && rig.service.kind(for: "writer") == .screenshots)
        let relaunched = ScreenHolds(defaults: rig.defaults)
        #expect(relaunched.rememberedKind(rig.account) == .screenshots)
        rig.session.leave()
    }

    /// As Hermes sends them: `profile_key` is the profile's home path, a status also says the name, a lease event
    /// says the path only (review finding 1: the cache was filed under the path and the menu never saw it).
    @Test func eventsFeedTheLabelsOfBotsThatWereNeverOpened() async {
        let rig = SessionRig()
        let key: JSONValue = "/srv/hermes/homes/w-1"                                 // nothing in the path names the bot
        rig.display.client.emit(GatewayEvent(type: "display.status", sessionId: "", seq: nil,
                                             payload: ["profile": "writer", "profile_key": key, "supported": true, "installed": true, "running": true,
                                                       "lease": ["holder": "human", "viewer_hash": "abc", "epoch": 3]]))
        #expect(await screenWait { rig.service.tone(for: "writer") == .other })
        rig.display.client.emit(GatewayEvent(type: "display.lease", sessionId: "", seq: nil,
                                             payload: ["profile_key": key, "lease": ["holder": "agent", "viewer_hash": .null, "epoch": 4]]))
        #expect(await screenWait { rig.service.tone(for: "writer") == .live })
        rig.display.client.emit(GatewayEvent(type: "display.lease", sessionId: "", seq: nil,
                                             payload: ["profile_key": key, "lease": ["holder": "human", "viewer_hash": "abc", "epoch": 2]]))
        try? await Task.sleep(for: .milliseconds(80))
        #expect(rig.service.tone(for: "writer") == .live)                               // an older lease changes nothing
        #expect(rig.service.kind(for: "writer") == .live)
        #expect(rig.service.tone(for: "/srv/hermes/homes/w-1") == .unknown)             // nothing is filed under a path
    }

    @Test func aLeaseEventForAHomeNobodyNamedChangesNothing() async {
        let rig = SessionRig()
        rig.display.client.emit(GatewayEvent(type: "display.lease", sessionId: "", seq: nil,
                                             payload: ["profile_key": "/srv/hermes/homes/x-9", "lease": ["holder": "human", "viewer_hash": "abc", "epoch": 9]]))
        try? await Task.sleep(for: .milliseconds(80))
        #expect(rig.service.tone(for: "/srv/hermes/homes/x-9") == .unknown)
        #expect(rig.service.profileName(for: ["profile_key": "/srv/hermes/homes/x-9"]) == nil)
        // Hermes' own layout names the bot; "custom" is not a name; an old gateway's bare name still works.
        #expect(rig.service.profileName(for: ["profile_key": "/Users/x/.hermes/profiles/ivy"]) == "ivy")
        #expect(rig.service.profileName(for: ["profile": "custom", "profile_key": "/opt/elsewhere"]) == nil)
        #expect(rig.service.profileName(for: ["profile_key": "writer"]) == "writer")
    }

    /// Found by UI test02 once the stand-in sent home paths: a Screen still waiting for its first status must take
    /// the gateway's status event (it names the bot), though the event's key is a path it has never seen.
    @Test func aScreenWithNoStatusYetTakesTheGatewaysStatusEvent() async {
        let rig = SessionRig()
        rig.display.set { $0.hang.insert("display.status") }
        rig.session.open()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(rig.session.status == nil)
        rig.display.emitStatus()                                    // profile "default", profile_key "/fixture/home"
        #expect(await rig.live(), "the late status opened the Screen without a tap")
        // And another bot's status event is not taken for this one.
        let before = rig.session.status
        rig.display.client.emit(GatewayEvent(type: "display.status", sessionId: "", seq: nil,
                                             payload: ["profile": "ivy", "profile_key": "/fixture/home/profiles/ivy", "supported": false]))
        try? await Task.sleep(for: .milliseconds(80))
        #expect(rig.session.status == before)
        rig.session.leave()
    }

    /// A screen the service already knows is running opens straight to observe: its answer carries the status.
    @Test func aKnownRunningScreenOpensWithoutAStatusRead() async {
        let rig = SessionRig()
        #expect(await rig.openLive())
        rig.session.leave()
        let before = rig.display.methods.count
        rig.reopen()
        rig.session.open()
        #expect(rig.session.phase == .attaching, "the known status shows at once")
        #expect(await rig.live())
        #expect(Array(rig.display.methods.dropFirst(before)) == ["display.observe"])
        rig.session.leave()
    }

    /// The known status was stale (the screen was turned off since): the status is read as on any open, and no
    /// "stream ended" page shows on the way.
    @Test func aStaleKnownStatusFallsBackToTheStatusRead() async {
        let rig = SessionRig()
        #expect(await rig.openLive())
        rig.session.leave()
        rig.display.set { $0.running = false }
        let before = rig.display.methods.count
        rig.reopen()
        rig.session.open()
        #expect(await screenWait { rig.session.phase == .off })
        #expect(Array(rig.display.methods.dropFirst(before)) == ["display.observe", "display.status"])
        #expect(!rig.phases.contains { if case .ended = $0 { true } else { false } })
        rig.session.leave()
    }

    /// An open Screen teaches the pairing: the bot's lease events move its label after the Screen is closed.
    @Test func anOpenedScreenPairsItsHomeWithItsBot() async {
        let rig = SessionRig()
        #expect(await rig.openLive())
        rig.session.leave()
        #expect(rig.service.tone(for: "default") == .live)
        rig.display.otherTakes()
        #expect(await screenWait { rig.service.tone(for: "default") == .other })
        rig.display.agentTakes()
        #expect(await screenWait { rig.service.tone(for: "default") == .live })
    }

    /// Review finding 3: a Mac that answers but has no picture ends in words that say why, not "Screen Stopped".
    @Test func aMacWithNoPictureSaysWhy() async {
        let rig = SessionRig()
        rig.display.set { $0.pictures = false }
        rig.display.client.onRest { _, _ in Data(SessionRig.healthy.replacingOccurrences(of: "\"helper\":{", with: "\"helper\":{\"paused\":true,").utf8) }
        rig.session.open()
        #expect(await screenWait { rig.socket != nil })
        rig.socket?.push(RFBBuild.preamble(width: 64, height: 48))
        // The handshake is done once the stream has asked for its first picture. (The picture's size is no sign of it:
        // the status carries one too, and on a loaded machine moving the clock before the stream had read the
        // handshake stamped its "last byte" late, so the 20 s never ran out. Seen in the whole-suite run only.)
        #expect(await screenWait(20) { rig.socket?.requests.isEmpty == false })
        try? await Task.sleep(for: .milliseconds(300))
        rig.clock.advance(12)
        try? await Task.sleep(for: .milliseconds(600))
        #expect(rig.session.phase == .attaching, "12 s: still waiting, the socket open")
        rig.clock.advance(9)
        // The title comes with the stream's end; the reason follows the helper's health (read again at that moment).
        #expect(await screenWait(20) { rig.session.phase == .ended(title: "The Mac hasn’t sent a picture yet",
                                                                   detail: "Resume sharing from Hermes HQ Screen’s menu on the Mac.") },
                "\(rig.session.phase) phases \(rig.phases) sockets \(rig.display.sockets.count) clock \(rig.clock.now)")
        try? await Task.sleep(for: .milliseconds(200))
        #expect(rig.display.sockets.count == 1 && rig.display.calls("display.observe").count == 1, "no retry by itself")
        // Reconnect, and this time the picture comes.
        rig.display.set { $0.pictures = true }
        rig.session.reconnect()
        #expect(await rig.live())
        rig.session.leave()
    }

    @Test func theReasonForNoPictureFollowsTheHelpersHealth() {
        #expect(ScreenSession.noPictureReason(["helper": ["paused": true]]) == "Resume sharing from Hermes HQ Screen’s menu on the Mac.")
        #expect(ScreenSession.noPictureReason(["helper": ["capture_error": "The display is off"]]) == "The display is off.")
        #expect(ScreenSession.noPictureReason(["helper": ["tcc": ["screen": false]]]) == "Allow Screen Recording for Hermes HQ Screen on the Mac.")
        #expect(ScreenSession.noPictureReason(["helper": ["locked": true]])?.hasPrefix("The Mac is locked") == true)
        #expect(ScreenSession.noPictureReason(nil) == "Its display may be asleep. Wake the Mac, then tap Reconnect.")
    }

    @Test func signOutLeavesEveryOpenScreenByTheRules() async {
        let rig = SessionRig()
        #expect(await rig.openLive())
        #expect(await rig.takeOver())
        #expect(rig.service.hasOpenSession)
        rig.service.shutdown()
        #expect(rig.session.left)
        #expect(await screenWait { rig.socket?.closes.first == true })                   // handed back through the close
        rig.display.emitStatus()
        rig.display.reconnectGateway()
        try? await Task.sleep(for: .milliseconds(150))
        #expect(rig.display.sockets.count == 1 && rig.display.calls("display.observe").count == 1)
    }

    @Test func checkSetupReadsHealthAndStatusTogether() async throws {
        let rig = SessionRig()
        rig.display.client.onRest { _, _ in
            Data(#"{"installed":true,"ok":true,"platform":"darwin","drift":[],"enabled":true,"control":false,"helper":{"ok":true,"tcc":{"screen":true,"events":true}}}"#.utf8)
        }
        #expect(try await rig.service.checkSetup(profile: "default") == "Viewing is ready. Finish setup with Hermes to enable pointer, clicks, and typing.")
        #expect(rig.display.methods == ["display.status"] && rig.display.client.restLog.count == 1)
        // No plugin route at all is an answer, not a failure.
        rig.display.client.onRest { _, _ in throw HTTPError(status: 404, body: nil) }
        #expect(try await rig.service.checkSetup(profile: "default") == "The Mac screen plugin is not loaded in this gateway yet.")
        // A gateway that cannot be reached is a failure.
        rig.display.client.onRest { _, _ in throw URLError(.timedOut) }
        await #expect(throws: URLError.self) { try await rig.service.checkSetup(profile: "default") }
        // An older Hermes without display.* still gets a plain line.
        rig.display.client.onRest { _, _ in Data(#"{"installed":true,"ok":true,"platform":"darwin","drift":[],"enabled":true}"#.utf8) }
        rig.display.set { $0.fail["display.status"] = RPCError(code: -32601, message: "Method not found", data: nil) }
        #expect(try await rig.service.checkSetup(profile: "default") == "This bot does not have access to the Mac’s screen.")
    }
}
