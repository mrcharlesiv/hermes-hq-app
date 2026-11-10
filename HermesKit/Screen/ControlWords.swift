// The words for taking over a bot's browser or screen and giving it back. Watch Browser and Screen are reached from
// the same Computer group, so they say the same thing (UX study 2026-10-19 #81; the owner's own phrase is "watch and
// take control", docs/spec/3x-screen.md).

import Foundation

nonisolated enum ControlWords {
    static let take = "Take Control"
    static let give = "Give Back"
    /// Screen only: a hold this phone lost track of (docs/spec/3x-screen.md §5.8).
    static let resume = "Resume Control"
    /// Screen only: another viewer's control ends and the bot has it again (was "Hand back (force)").
    static let endOther = "End Their Control"

    /// The Take button's words: Resume Control while an earlier hold of this phone's is still on the screen.
    static func take(held: Bool) -> String { held ? resume : take }

    /// Both bars' keyboard button (its VoiceOver label) and an empty clipboard's note.
    static let showKeyboard = "Show Keyboard"
    static let hideKeyboard = "Hide Keyboard"
    static let nothingToPaste = "There’s no text to paste."

    /// The gesture hints, both with the one verb, "Drag".
    #if targetEnvironment(macCatalyst)
    /// [mac] A click is a tap there ("Click to click" said nothing), and a hold is the mouse button held down. A Mac's
    /// scroll goes to the page (`BrowserStageView.wheeled`); a pinch brings no touches, so it doesn't zoom.
    static let browserGestures = "Drag anywhere to move the pointer. A click clicks there, and scrolling scrolls the page."
    static let screenGestures = "Drag anywhere to move · A click clicks at the cursor · Hold the button then move to drag · Hold it to right-click"
    #else
    static let browserGestures = "Drag anywhere to move the pointer. Tap to click. Two fingers scroll; pinch to zoom."
    /// Audit 09-22: the two-finger scroll and the pinch too, as the Browser's hint says (the web's line left them out).
    static let screenGestures = "Drag anywhere to move · Tap to click at the cursor · Hold then move to drag · Hold to right-click · Two fingers scroll · Pinch to zoom"
    #endif

    /// Screen's notes under the picture.
    static let heldNote = "You were in control of this screen. \(resume), or give it back to the bot."
    static let otherNote = "Another viewer has control. \(endOther) gives it back to the bot."
    /// Watch Browser while another viewer holds the browser: why there is no Take Control, and when it comes back.
    static let browserOther = "Another viewer has control. You can take control once they give it back."
}
