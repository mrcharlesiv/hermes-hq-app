// [first-run] The stage's beats, one per screen, ported line by line from the mock's S[0]…S[4]
// (build/first-run/spec/prototype.src.html, "the six beats"). Each screen asks for its beat as it comes on; a beat that
// was running stops where it is (`ArrivalStage.begin`). The words' own timing lives with the screens; what the words
// wait for (the eyes opening, say) comes through `ArrivalHereBeats`.

import SwiftUI
import UIKit

/// What the Hermes-is-here screen shows as the moment goes on (the mock's `.late` → `.on`).
@MainActor @Observable final class ArrivalHereBeats {
    var heading = false
    var lead = false
    var others = false
    var button = false
    /// The real face (`HeadView`) has taken over from the drawn one.
    var realFace = false
    /// Where the face sits and how big it is, in mock points (the screen places the real face there).
    var faceY = 296.0
    var faceR = 106.08
}

extension ArrivalStage {
    // MARK: S[0] Hello

    func hello() {
        begin { s in
            let fresh = s.mode == .stars
            s.prep()
            s.dragsGlobe = true
            if fresh { s.markA = 0; s.resetSpin() }
            if s.mode != .globe {
                s.gp.cx = 195; s.gp.cy = 258; s.gp.r = 116
                if fresh { s.setMode(.globe, dur: 1700, stagger: 900, swirl: 0.5) } else { s.setMode(.globe, dur: 1100, stagger: 450, swirl: 0.3) }
            } else {
                s.twGo([(\.gp.cx, 195), (\.gp.cy, 258), (\.gp.r, 116)], 700, .inOut)
            }
            if fresh {
                try await s.sleep(250)
                s.cue(.gather)
                try await s.sleep(2150)
                s.cue(.here)
                Haptics.play(.light)                                  // the dots have found them
                try await s.tw([(\.markA, 1)], 500)
            } else {
                s.twGo([(\.markA, 1)], 500)
            }
        }
    }

    // MARK: S[1] Where

    func whereIs() {
        begin { s in
            s.prep()
            s.toGlobe(cx: 195, cy: 136, r: 38)
        }
    }

    // MARK: S[2] The note

    func note() {
        begin { s in
            s.prep()
            s.toGlobe(cx: 195, cy: 172, r: 60)
        }
    }

    /// The note has gone (shared or copied): it leaves from where they are, over the horizon; then a fainter one keeps
    /// going while they wait. Runs inside the note's beat (no new beat: the screen hasn't changed).
    func noteSent(cardFlight: Double = 380) {
        Haptics.play(.light)                                         // the note leaves
        spawn { [weak self] in
            guard let self else { return }
            try await self.sleep(cardFlight)
            self.spawn { [weak self] in
                guard let self else { return }
                try await self.tw([(\.gp.r, 66)], 150)
                try await self.tw([(\.gp.r, 60)], 380, .back)
            }
            let m = self.project(self.place.you)
            self.ring(m.x, m.y, 5, 46, 800, 0.7, self.tintColour)
            self.cue(.send)
            let you = self.place.you, far = self.place.far
            self.spawn { [weak self] in try await self?.arc(you, far, 1000) }
            if self.still { return }
            try await self.sleep(2100)
            while true {
                self.spawn { [weak self] in try await self?.arc(you, far, 1500, alpha: 0.4) }
                try await self.sleep(2300)
            }
        }
    }

    // MARK: S[3] Found

    /// The answer comes back the way the note went, and the whole world folds down into a face that isn't lit yet.
    func found() {
        begin { s in
            s.prep()
            if s.mode == .led {
                s.lp.ign = nil; s.lp.fuse = 0; s.lp.fade = 1
                s.twGo([(\.lp.cx, 195), (\.lp.cy, 188), (\.lp.pitch, 7.4)], 700, .inOut)
                return
            }
            if s.mode == .globe {
                s.twGo([(\.gp.cx, 195), (\.gp.cy, 188), (\.gp.r, 70)], 650, .inOut)
                s.cue(.back)
                try await s.arc(s.place.far, s.place.you, 800)
                let m = s.project(s.place.you)
                s.ring(m.x, m.y, 5, 70, 800, 0.8, s.tintColour)
                s.ring(195, 188, 70, 150, 900, 0.4)
                try await s.sleep(140)
            }
            s.toLED(cx: 195, cy: 188, pitch: 7.4, dur: 900, stagger: 300, swirl: 0.25)
            s.cue(.settle)
            Haptics.play(.light)                                      // the dots click into place
        }
    }

    /// Signing in: a line sweeps across the sleeping face.
    func scanning(_ on: Bool) {
        if on { scan(true) } else { lp.scan = nil }
    }

    // MARK: S[4] Hermes is here

    /// It lights from the middle out in the head's own colour, the LEDs run together into the face, and it wakes.
    /// `more`: other bots came with it (the face sits a little higher to make room for them).
    func here(_ beats: ArrivalHereBeats, more: Bool) {
        begin { s in
            let was = s.mode
            s.prep(keepFace: true)
            let cy = more ? 282.0 : 296.0, pitch = 10.2, radius = pitch * 10.4
            beats.faceY = cy
            beats.faceR = radius
            s.faceA = 0; s.faceLid = 1; s.faceGX = 0; s.faceGY = 0; s.faceSc = 1; s.faceHop = 0; s.glow = 0
            if was != .led {
                s.toLED(cx: 195, cy: 188, pitch: 7.4, dur: 600, stagger: 150, swirl: 0.2)
                try await s.sleep(800)
            } else {
                s.lp.ign = nil; s.lp.fuse = 0; s.lp.fade = 1; s.lp.scan = nil
            }
            try await s.tw([(\.lp.cx, 195), (\.lp.cy, cy), (\.lp.pitch, pitch)], 950, .inOut)
            try await s.sleep(180)                                    // a held breath
            // It lights: colour, for the first time, from the middle out. The stars get out of the way.
            s.faceX = 195; s.faceY = cy; s.faceR = radius
            s.lp.ign = s.still ? -1e7 : ArrivalStage.ms()
            s.cue(.ignite)
            Haptics.play(.medium)                                     // the deepest the app's haptics go
            s.twGo([(\.glow, 1)], 800)
            if !s.still {
                s.flash = 1
                s.twGo([(\.flash, 0)], 900)
                s.spawn { [weak s] in
                    guard let s else { return }
                    try await s.tw([(\.camZ, 0.045)], 140)
                    try await s.tw([(\.camZ, 0)], 900, .out)
                }
            }
            try await s.sleep(170)
            s.ring(195, cy, radius, radius * 1.9, 1100, 0.6, s.accent, shock: true)
            try await s.sleep(190)
            s.ring(195, cy, radius, radius * 2.6, 1500, 0.35, s.accent, shock: true)
            try await s.sleep(640)
            // The LEDs run together into the face the app shows everywhere, and let go.
            s.twGo([(\.lp.fuse, 1)], 380, .in)
            try await s.sleep(210)
            try await s.tw([(\.faceA, 1)], 260)
            s.letGo()
            s.spawn { [weak s] in
                guard let s else { return }
                try await s.tw([(\.faceSc, 1.06)], 150)
                try await s.tw([(\.faceSc, 1)], 460, .back)
            }
            try await s.sleep(430)
            s.cue(.wake)
            try await s.tw([(\.faceLid, 0)], 200)                    // and it wakes
            Haptics.play(.success)
            HQMotion.withAnimation(.easeOut(duration: 0.6), fades: true) { beats.heading = true }
            HQAnnounce.say(OnboardingCopy.Arrival.hereHeading, priority: .high, coalesce: true)
            try await s.sleep(260)
            try await s.tw([(\.faceGX, -0.05)], 200, .inOut)
            try await s.sleep(240)
            try await s.tw([(\.faceGX, 0)], 260, .inOut)
            // The drawn face hands over to the real one (the same face, now the app's own, alive from here).
            HQMotion.withAnimation(.easeInOut(duration: 0.25), fades: true) {
                beats.realFace = true
                beats.lead = true
            }
            if more {
                try await s.sleep(350)
                HQMotion.withAnimation(.easeOut(duration: 0.6), fades: true) { beats.others = true }
            }
            try await s.sleep(500)
            HQMotion.withAnimation(.easeOut(duration: 0.6), fades: true) { beats.button = true }
            s.tapsFace = true
        }
    }

    /// The face hops when it's tapped (the mock's `boop`), whichever face is showing.
    func boop() {
        cue(.boop)
        Haptics.play(.soft)
        boopRing()
        guard !still else { return }
        spawn { [weak self] in
            guard let self else { return }
            try await self.tw([(\.faceSc, 0.93)], 80)
            try await self.tw([(\.faceSc, 1.07), (\.faceHop, -12)], 150)
            try await self.tw([(\.faceSc, 1), (\.faceHop, 0)], 420, .back)
        }
    }

    /// Hands the face over to `view` (the real head): the drawn one fades out under it.
    func handOver(to view: UIView?) {
        realFace = view
        guard view != nil else { return }
        // The drawn one stays whole until the real one is fully in over it (0.25 s): two faces cross-fading dip to grey.
        if still { faceA = 0; return }
        spawn { [weak self] in
            guard let self else { return }
            try await self.sleep(280)
            try await self.tw([(\.faceA, 0)], 120)
        }
    }
}
