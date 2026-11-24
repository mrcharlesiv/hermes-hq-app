// [first-run] The new words of the first run ("Hermes arrives"), from the approved mock
// (build/first-run/spec/prototype.src.html, S[0]…S[4]). Today's `OnboardingCopy` strings are left exactly as they are:
// with the switch off the app reads only those. Tests: Tests/Onboarding/FirstRunArrivalTests.swift.

import Foundation

extension OnboardingCopy {
    nonisolated enum Arrival {
        // MARK: Hello

        static let brand = "Hermes HQ"
        /// The heading is today's two lines (`Welcome.headingLine1`/`2`).
        static let helloLead = "Ask from anywhere. Get a ping the moment it’s done."
        static let trust = "It stays on your computer. Only you get in."

        // MARK: Where

        static let whereEyebrow = "Step 1 of 3"
        /// The heading is today's (`Start.heading`).
        static let whereLead = "Hermes HQ connects to the Hermes you already use."
        static let computerTitle = "On my computer"
        static let computerText = "A Mac, Linux, Windows or a server."
        /// The Hermes Cloud row is today's words (`Cloud.title`, `Cloud.text`).
        static let noneTitle = "I don’t have one yet"
        static let noneText = "See the two ways to get one."
        static let cloudflare = "Behind Cloudflare Access?"

        // MARK: The note

        static let noteEyebrow = "Step 2 of 3"
        static let noteHeading = "Send your Hermes this note."
        static let noteLead = "Send it wherever you already chat with it. Hermes sets up its own computer."
        static let noteTo = "To my Hermes"
        static let readAll = "Read it all"
        static let send = "Send to My Hermes"
        static let copy = "Copy It Instead"
        static let sentHeading = "Sent. Hermes is on it."
        static let sentLead = "You can leave. The link brings you right back."
        static var next: [(title: String, text: String)] {
            [("Hermes sets itself up", "About five minutes. Nothing for you to do."),
             ("It sends you a link", "In the same chat you sent the note to."),
             ("\(DeviceWord.Tap) the link", "It opens Hermes HQ, ready to sign in.")]
        }
        /// Today's two ways on from the note (`LetHermes.haveAddress`, `LetHermes.myself`).
        static let haveAddress = OnboardingCopy.LetHermes.haveAddress
        static let myself = OnboardingCopy.LetHermes.myself
        static let wholeNote = "The Note"
        static let done = "Done"

        /// The start of the note, as the card shows it: its first sentence up to " and sign in" (or the whole first
        /// line), in curly quotes, trailing off.
        static func excerpt(_ note: String) -> String {
            let line = note.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? note
            var cut = line.range(of: " and sign in").map { String(line[..<$0.lowerBound]) } ?? line
            while let last = cut.last, last == "." || last == "," || last == " " { cut.removeLast() }
            return "“" + cut + "…”"
        }

        // MARK: Found

        static let foundEyebrow = "Step 3 of 3"
        static let foundHeading = "Found your Hermes."
        static let foundLead = "Sign in, so only you can get in."
        static let reachable = "Reachable"
        /// Today's Nous button words (SignInView's).
        static let signInNous = "Sign in with Nous"
        static let usePassword = "Use a Password Instead"
        static let signingIn = "Signing in…"

        // MARK: Hermes is here

        static let hereHeading = "Hermes is here."
        static let hereLead = "The same one that runs on your computer. Now it goes where you go."
        /// Only when the list of bots is in, with the real count: never a guess.
        static func others(_ count: Int) -> String {
            count == 1 ? "and 1 more agent came with it" : "and \(count) more agents came with it"
        }
        static let sayHello = "Say Hello"

        // MARK: First words (in the arriving bot's own chat)

        /// For the person's own Hermes, sent with no bubble once the chat has opened: it writes the first message
        /// itself. Text for an agent: straight apostrophes, as the setup message's.
        static var greetingPrompt: String {
            "I've just connected you to Hermes HQ, the \(device) app for Hermes, for the first time, and I'm looking at this chat on my \(device) right now. "
                + "Say hello in one or two short sentences, in your own voice, and use my name if you know it. "
                + "Tell me I can ask you anything from here and that you'll let me know when it's done. "
                + "Don't use any tools, don't list what you can do, and don't mention this message."
        }
        static let pingTitle = "Get a Ping When It’s Done"
        static var pingBody: String { "Hermes HQ can tell you the moment Hermes finishes or needs you. \(DeviceWord.system) asks next." }
        static let pingOn = "Turn On"
        static let pingsOn = "Pings are on."
        /// Each goes out as a typed message would.
        static let starters = ["What can you do for me?", "What are you working on?", "Show me around"]

        // MARK: Shared

        static let back = "Back"
        static let globeLabel = "A globe that turns to where you are"
        static let faceHint = "Double-tap to say hi."
    }
}
