// [onboarding] Every word, command and link of the welcome and the connection guide (docs/spec/3x-onboarding.md §5),
// copied from the web app (`W:src/connection-onboarding.ts`, `W:src/connection-guide.ts`, build 240). One place, pure,
// so the unit tests can pin it character for character (Tests/Onboarding/OnboardingCopyTests.swift).
//
// Rich lines use a small markup that `GuideText` (OnboardingKit.swift) draws: `**bold**`, `[[key cap]]`, `` `code` ``
// and `<<link text|address>>`. `GuideText.plain` gives the words alone, which is what the web shows.

import Foundation

nonisolated enum OnboardingCopy {
    /// "iPhone" on a phone, "iPad" on an iPad (`DEVICE`, `W:src/connection-startup.ts:28-33`): the train's one word.
    static var device: String { DeviceWord.name }

    // MARK: Links (`SETUP_LINKS`)

    enum Links {
        static let hermes = "https://hermes-agent.nousresearch.com/docs/"
        static let dashboard = "https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard"
        static let tailscaleServe = "https://tailscale.com/docs/features/tailscale-serve"
        static let tailscaleApp = "https://apps.apple.com/app/tailscale/id1470499037"
        static let tailscaleAdmin = "https://login.tailscale.com/admin/dns"
    }

    /// A link that could not open, on every guide screen but the chooser (`W:src/connection-guide.ts:213`).
    static func couldNotOpen(_ address: String) -> String { "Couldn’t open it. Open this address in Safari: \(address)" }
    /// The chooser's "Install Hermes first" link (`W:src/connection-onboarding.ts`).
    static func couldNotOpenGuide(_ address: String) -> String { "Couldn’t open the guide. Open this address in Safari: \(address)" }

    // MARK: Commands and messages

    static let connectCommand = "curl -fsSL https://raw.githubusercontent.com/mrcharlesiv/hermes-hq/main/connect.sh | sh"
    static let connectPage = "github.com/mrcharlesiv/hermes-hq"

    /// The message for the person's own Hermes (`HERMES_CONNECT_PROMPT`). Text for an agent: straight apostrophes, and
    /// "the iPhone app" on every device, as the web's.
    static let hermesConnectPrompt = """
        Please connect this computer to Hermes HQ, the iPhone app for Hermes, so I can reach you from anywhere and sign in with my Nous account.

        Run this in your terminal, on this computer itself (if your terminal runs in a container, sandbox or another machine, stop and tell me):
        \(connectCommand) -s -- --agent

        It's safe to run again and again. Each time it either finishes or prints a NEXT STEP. If the next step is for you, do it. If it's for me (a link to open, a code, or a command that needs my password), send it to me word for word and wait until I say I've done it. Then run the command again, until it says DONE.

        It uses Tailscale on this computer (free) to give it an address my phone can reach; my phone doesn't need Tailscale. Never send me files from this computer, and put any file path you mention in backticks.

        When it says DONE, send me the address it prints and tell me to paste it into Hermes HQ and tap Sign in with Nous. If it says it can't run on this computer, tell me why.
        """

    /// `SETUP_COMMANDS`: placeholders only; the app never writes a real secret anywhere.
    enum Setup {
        static let serve = "tailscale serve --bg 9119"
        static let secret = "openssl rand -base64 32"
        static let envLines = [
            "HERMES_DASHBOARD_BASIC_AUTH_USERNAME=your-username",
            "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=your-long-password",
            "HERMES_DASHBOARD_BASIC_AUTH_SECRET=the-secret-you-generated",
            "HERMES_DASHBOARD_PUBLIC_URL=https://your-computer.your-tailnet.ts.net",
        ]
        static let env = envLines.joined(separator: "\n")
        static let start = "hermes dashboard --no-open"
    }

    /// What Copy All Steps copies (`SETUP_STEPS_TEXT`; note the trailing newline).
    static let setupStepsText = """
        Hermes HQ setup (type these on the computer where Hermes is installed)

        Before you start: Tailscale is installed and signed in on this computer and on your \(device), with the same account. In the Tailscale admin console (\(Links.tailscaleAdmin)), MagicDNS and HTTPS Certificates are on.

        1. Share Hermes on your Tailscale network:
        \(Setup.serve)
        It prints your address, like https://your-computer.your-tailnet.ts.net
        (If this computer already shares something with Tailscale Serve, that command replaces it. Use: tailscale serve --bg --https=8443 9119, and add :8443 to the address.)

        2. Turn on sign-in. Make a secret:
        \(Setup.secret)
        Then add these four lines to the file ~/.hermes/.env, with your own username, password, that secret and the address from step 1:
        \(Setup.env)

        3. Start Hermes and leave it running:
        \(Setup.start)
        (Restart it whenever you change those lines.)

        4. In Hermes HQ, enter the address from step 1 and the username and password from step 2.

        More on sign-in, including a hashed password: \(Links.dashboard)

        """

    /// The Windows path's message for Hermes (`HERMES_SETUP_PROMPT`).
    static let hermesSetupPrompt = """
        Please set up this computer so I can use Hermes from Hermes HQ, the iPhone app for Hermes. Use your terminal tools and do each step yourself; stop and ask me only for what you can't do. If your terminal runs somewhere other than this computer (a container, sandbox or remote machine), stop and tell me.

        1. Check that Tailscale is installed, running and signed in (tailscale status). If it isn't, tell me how to install it and sign in, and wait for me. Remind me to install Tailscale on my phone with the same account, and to turn on MagicDNS and HTTPS certificates in the Tailscale admin console (\(Links.tailscaleAdmin)).

        2. Run tailscale serve status. If nothing is being served, run: \(Setup.serve)
        If something is already served, don't replace it; run tailscale serve --bg --https=8443 9119 instead and use :8443 in the address. The address is https:// plus this computer's MagicDNS name (Self.DNSName in tailscale status --json, without the trailing dot), e.g. https://your-computer.your-tailnet.ts.net

        3. Ask me for the username and password I want to type into Hermes HQ, or offer to generate a strong password. These are sign-in details for this computer's Hermes, not an AI provider login. Generate a secret with: \(Setup.secret)

        4. Back up ~/.hermes/.env, then set these four lines in it (replace any existing values for the same keys, don't duplicate them):
        \(Setup.env)
        using my username and password, the secret from step 3 and the address from step 2 (with :8443 if you used it).

        5. Start the dashboard so it keeps running after this chat ends: \(Setup.start) (in the background, e.g. with nohup, or as a login service). If a dashboard is already running, restart it so it reads the new settings.

        6. Check it: curl -sI on the address should answer, not "400 Invalid Host header". If it fails, fix it and check again.

        When you're done, tell me in plain words the address and username to type into Hermes HQ, and anything I still have to do myself. Don't repeat the password back in the chat.
        """

    // MARK: Welcome (`W:src/connection-onboarding.ts:47-57`)

    enum Welcome {
        static let headingLine1 = "Your Hermes,"
        static let headingLine2 = "wherever you are."
        static let lead = "Chat with your agents, see what they’re working on, and get a ping when they’re done, right from your \(device)."
        static let points: [(symbol: String, title: String, text: String)] = [
            ("desktopcomputer", "Hermes stays on your computer.", "Your agents, chats and files stay there."),
            (device == "iPad" ? "ipad" : device == "Mac" ? "laptopcomputer" : "iphone", "Hermes HQ connects your \(device) to it.", "Set it up once; it takes a few minutes."),
            ("lock", "Only you can get in.", "Hermes HQ never stores your password."),
        ]
        static let start = "Get Started"
        /// Title case like every other first-run button (UX study #79; the web says "I already have an address").
        static let haveAddress = "I Already Have an Address"
    }

    // MARK: Where does Hermes run? (`:58-71`)

    enum Where {
        static let eyebrow = "Set it up yourself"
        static let heading = "Where does Hermes run?"
        static let lead = "Pick the computer Hermes is installed on."
        typealias Choice = (id: String, symbol: String, title: String, text: String, step: OnboardingStep)
        static let choices = choices(onMac: DeviceWord.isMac)
        /// [mac] On the Mac, "On this Mac" comes first and goes straight to the form at `localAddress` (no Tailscale, no
        /// QR code); "On a Mac" becomes another Mac.
        static func choices(onMac: Bool) -> [Choice] {
            let here = onMac ? "Mac" : device
            let quick = "One command sets it up. Then you sign in with your Nous account."
            let rest: [Choice] = [
                ("linux", "server.rack", "On Linux or a server", "The same one command, run there or over SSH. Then you sign in with Nous.", .linux1),
                ("windows", "desktopcomputer", "On Windows", "Uses Tailscale, a free app, on that computer and this \(here), with a password.", .other1),
                ("address", "link", "Someone gave me an address", "Sign in with the address and details they sent you.", .connect),
            ]
            guard onMac else { return [("mac", "laptopcomputer", "On a Mac", quick, .mac1)] + rest }
            return [
                (localID, "laptopcomputer", "On this Mac", "Sign in to the Hermes running here. No Tailscale needed.", .connect),
                ("mac", "display", "On another Mac", quick, .mac1),
            ] + rest
        }
        /// [mac] The "On this Mac" choice's id.
        static let localID = "here"
        /// [mac] A Hermes on this same Mac: `hermes serve` listens on 127.0.0.1:9119 (the setup's own default). Not
        /// "localhost": Hermes turns away a Host it isn't bound to.
        static let localAddress = "http://127.0.0.1:9119"
        /// The web says "your phone" here on every device; [mac] the Mac says where Hermes can run instead.
        static let footnote = footnote(onMac: DeviceWord.isMac)
        static func footnote(onMac: Bool) -> String {
            let runs = onMac ? "It runs on a computer, like this Mac." : "It runs on a computer, not on your phone."
            return "No Hermes yet? \(runs) <<Install Hermes first|\(Links.hermes)>>, then come back."
        }
    }

    // MARK: Let Hermes set it up (`W:src/connection-guide.ts:146-155`)

    enum LetHermes {
        static let heading = "Let Hermes set it up."
        static let lead = "Send this message to your Hermes, wherever you chat with it: Telegram, Discord, the Hermes app or its terminal. Hermes sets up its own computer for you."
        static let copy = "Copy Message"
        static let share = "Send…"
        static let showMessage = "Show the message"
        static let steps = [
            "Hermes runs the setup on its computer.",
            "It may send you a link or two to sign in to, both free: **Nous**, so only you can get in, and **Tailscale**, which gives that computer an address your \(device) can reach from anywhere.",
            "When it’s done, Hermes sends you the address. Paste it on the next screen and \(DeviceWord.tap) **Sign in with Nous**.",
        ]
        static let footnote = "Tailscale runs only on that computer: nothing to install on this \(device). Works when Hermes runs on a Mac or Linux, servers included."
        static let haveAddress = "I Have the Address"
        static let myself = "Set It Up Myself"
    }

    // MARK: Mac and Linux, three steps each (`quickSetup`, `:103-142`)

    enum QuickKind: String, Sendable, CaseIterable { case mac, linux }

    struct Quick: Sendable {
        var eyebrow1 = "Step 1 of 3", eyebrow2 = "Step 2 of 3", eyebrow3 = "Step 3 of 3"
        var heading1: String, lead1: String, share: String, footnote1: String
        var heading2: String, steps2: [String], note2: String, troubleTitle: String, trouble: [(problem: String, fix: String)]
        var heading3: String, lead3: String, steps3: [String], note3: String
        var copy = "Copy", next = "Next", typeAddress = "Type the Address Instead"
    }

    /// - Parameter onMac: [mac] HQ itself runs on a Mac, so "On a Mac" is another Mac (a Hermes on this one skips the
    ///   guide) and step 3 copies the address the setup prints instead of scanning its QR code with a camera.
    static func quick(_ kind: QuickKind, onMac: Bool = DeviceWord.isMac) -> Quick {
        let mac = kind == .mac
        let here = onMac ? "Mac" : device
        let it = mac ? (onMac ? "the other Mac" : "your Mac") : "that computer"
        let enter = mac ? "Return" : "Enter"
        var trouble: [(problem: String, fix: String)] = [
            ("“Hermes isn’t installed”", "Install Hermes on \(mac ? (onMac ? "that Mac" : "this Mac") : "that computer") first (<<Hermes setup guide|\(Links.hermes)>>), then run the command again."),
            ("“Hermes didn’t start in the background”", "\(mac ? "Open a new Terminal window with [[⌘ N]], type" : "In a second terminal, type") `hermes serve` and press [[\(enter)]]. Leave it running, then run the command again in the first one."),
        ]
        if mac {
            trouble.append(("“Needs Node.js 20 or newer”", "Update Hermes: type `hermes update` and press [[Return]], then run the command again."))
        } else {
            trouble.append(("“Tailscale is installed but not signed in”", "Type `sudo tailscale up`, open the link it shows and sign in, then run the command again."))
            trouble.append(("“systemd user services … can’t reach”", "Log in to that computer directly or over SSH as yourself, not with su or sudo, then run the command again."))
        }
        trouble += [
            ("“Turn on MagicDNS and HTTPS Certificates”", "Open the link it shows, switch both on, then run the command again."),
            ("“Restart Hermes now”", "Stop Hermes where you started it ([[Control C]] in its window) and start it again the same way. The setup carries on by itself."),
            ("Anything else", "Run the command again; that’s always safe. Still stuck? Paste what the terminal says into a chat with Hermes and ask it for help."),
        ]
        let terminal = mac ? "Terminal" : "the terminal"
        var copy = Quick(
            heading1: "Get the setup command onto \(it).",
            lead1: (mac ? "You’ll paste one line into Terminal on \(onMac ? "the Mac running Hermes" : "your Mac")." : "You’ll paste one line into a terminal on the computer running Hermes, or into an SSH session to it.") + " It sets up everything else for you.",
            share: mac && !onMac ? "Send to Your Mac…" : "Send…",
            footnote1: "Or \(mac ? (onMac ? "on the other Mac" : "on your Mac") : "on the computer you’ll type it on"), open **\(connectPage)** in a web browser and copy the command from there.",
            heading2: mac ? "Run it in Terminal on \(it)." : "Run it in a terminal there.",
            steps2: mac ? [
                "Open **Terminal**: press [[⌘ Space]], type **Terminal**, then press [[Return]].",
                "Paste the command with [[⌘ V]], then press [[Return]].",
                "Do what it asks. It signs \(onMac ? "that" : "this") Mac in to **Nous**, so only you can get in, and to **Tailscale**, which gives \(onMac ? "it" : "your Mac") an address this \(here) can reach from anywhere (both free). It may open your browser for you to sign in, or ask you to click **Allow**.",
            ] : [
                "Open a terminal on the computer running Hermes, or connect to it with **SSH**.",
                "Paste the command and press [[Enter]].",
                "Do what it asks. It signs that computer in to **Nous**, so only you can get in, and to **Tailscale**, which gives it an address this \(here) can reach from anywhere (both free). It may show a link to open in any browser (this \(here)’s is fine), or ask for your password once.",
            ],
            note2: "It takes about five minutes. Tailscale runs only on \(mac ? (onMac ? "that Mac" : "your Mac") : "that computer"): \(onMac ? "this Mac" : "your \(device)") doesn’t need it. If you stop partway, run the command again: it picks up where it left off.",
            troubleTitle: "If \(terminal) shows a problem",
            trouble: trouble,
            heading3: "Scan the QR code with this \(device).",
            lead3: "When the setup is done, \(terminal) shows a QR code. It holds \(mac ? "your Mac’s" : "that computer’s") address, so you don’t have to type it.",
            steps3: [
                "Open the **Camera** app and point it at the QR code on the screen.",
                "\(DeviceWord.Tap) **Open in Hermes HQ**.",
                "\(DeviceWord.Tap) **Sign in with Nous**, with the same Nous account you used \(mac ? "on your Mac" : "there").",
            ],
            note3: "\(mac ? (onMac ? "Keep the other Mac on and awake" : "Keep your Mac on and awake") : "Keep that computer on"): Hermes HQ can reach Hermes only while it is.")
        guard onMac else { return copy }
        // [mac] A Mac has no Camera app to scan with: the address the setup prints under its QR code is the way on,
        // and the button to the form leads.
        copy.heading3 = "Copy the address it prints."
        copy.lead3 = "When the setup is done, \(terminal) shows a QR code for phones. Under it, the line that starts **Can’t scan it?** ends with \(mac ? "that Mac’s" : "that computer’s") address."
        copy.steps3 = [
            "Select the address at the end of that line (it starts with **https://**) and copy it with [[⌘ C]].",
            "Click **Next: Sign In** and paste it with [[⌘ V]].",
            "Click **Sign in with Nous**, with the same Nous account you used \(mac ? "on that Mac" : "there").",
        ]
        copy.typeAddress = "Next: Sign In"
        return copy
    }

    /// The Mac and Linux screens when this device already runs Tailscale (`Tailnet`): the same steps, without the
    /// "your iPhone doesn't need it" lines, and with the same Tailscale account asked for.
    static func quick(_ kind: QuickKind, tailnetOnly: Bool, onMac: Bool = DeviceWord.isMac) -> Quick {
        var copy = quick(kind, onMac: onMac)
        guard tailnetOnly else { return copy }
        let mac = kind == .mac, here = onMac ? "Mac" : device
        copy.steps2[2] = copy.steps2[2].replacingOccurrences(
            of: ", which gives \(mac && !onMac ? "your Mac" : "it") an address this \(here) can reach from anywhere",
            with: ", with the same Tailscale account as this \(here)")
        copy.note2 = "It takes about five minutes. Sign in to Tailscale there with the same account as this \(here). If you stop partway, run the command again: it picks up where it left off."
        copy.note3 += " Leave Tailscale connected on this \(here) too: the address works only on your Tailscale network."
        return copy
    }

    // MARK: Already on Tailscale (native only: not in the web's build 240)

    /// For someone whose device already runs Tailscale and who wants Hermes kept off the internet: the same setup
    /// with `--private`, which shares the address with Tailscale Serve (only their own Tailscale network) instead of
    /// Funnel. Nous sign-in still works: it all happens in this device's browser, which is on that network.
    enum Tailnet {
        static let toggleTitle = "This \(device) already uses Tailscale"
        static let toggleText = "Keep Hermes off the internet: only devices on your Tailscale network can reach it."
        static let command = connectCommand + " -s -- --private"
        static let prompt = hermesConnectPrompt
            .replacingOccurrences(of: "so I can reach you from anywhere", with: "so I can reach you from my phone over Tailscale")
            .replacingOccurrences(of: "\(connectCommand) -s -- --agent", with: "\(connectCommand) -s -- --agent --private")
            .replacingOccurrences(of: "It uses Tailscale on this computer (free) to give it an address my phone can reach; my phone doesn't need Tailscale.",
                                  with: "It uses Tailscale on this computer (free) and keeps the address off the internet: only devices on my Tailscale network can reach it. My phone already runs Tailscale, so sign this computer in to the same Tailscale account.")
        static let letHermesSteps = [
            LetHermes.steps[0],
            "It may send you a link or two to sign in to, both free: **Nous**, so only you can get in, and **Tailscale**, on that computer with the same account as this \(device).",
            LetHermes.steps[2],
        ]
        static let letHermesFootnote = "Leave Tailscale connected on this \(device): the address works only on your Tailscale network. Works when Hermes runs on a Mac or Linux, servers included."
    }

    // MARK: Hermes Cloud (native only: not in the web's build 240)

    /// For a Hermes that Nous hosts (Nous Portal's Hermes Cloud), one already made or a new one: nothing to set up, and
    /// the setup message would only make a cloud Hermes say it can't run there. The row opens Hermes Cloud
    /// (App/Gateways/CloudGatewayFlow.swift), which lists the account's agents or, with none, makes the first.
    enum Cloud {
        static let id = "cloud"
        static let symbol = "cloud"
        static let title = "On Hermes Cloud"
        static let text = "Nous runs it for you. Sign in with Nous, then pick your agent or make a new one. Nothing to set up."
        /// The same row on "Let Hermes set it up.", above the message a cloud Hermes can't act on.
        static let letHermesTitle = "Use Hermes Cloud Instead"
        static let letHermesText = "Nous runs Hermes for you: no computer, no message to send. Sign in with Nous, then pick your agent or make a new one."
    }

    // MARK: Windows, two steps (`:158-170`)

    enum Windows {
        static let eyebrow1 = "Step 1 of 2"
        static let heading1 = "Install Tailscale on both."
        static let lead1 = "Tailscale is a free app that privately links this \(device) and the computer running Hermes, wherever you are."
        static let steps1 = [
            "**On this \(device):** install Tailscale and sign in.",
            "**On the computer running Hermes:** install Tailscale from **tailscale.com/download** and sign in with the same account.",
        ]
        static let getTailscale = "Get Tailscale"
        static let next = "Next"
        static let eyebrow2 = "Step 2 of 2"
        static let heading2 = "Let Hermes do the setup."
        static let lead2 = "Copy this message and send it to Hermes on that computer, wherever you chat with it: in its terminal, Telegram, Discord or the Hermes app."
        static let copy = "Copy Message for Hermes"
        static let showMessage = "Show the message"
        static let after = "Hermes does the setup, has you choose a password, then tells you the **address** and **username** to sign in with."
        static let myself = "I’d Rather Do It Myself"   // UX study #79: title case, as the buttons beside it
        static let signIn = "Next: Sign In"
    }

    // MARK: Set it up yourself (`:171-179`)

    enum Manual {
        static let eyebrow = "Without Hermes’s help"
        static let heading = "Set it up yourself."
        static let lead = "Type these on the computer running Hermes, not on this \(device). Tailscale should already be on both, signed in to the same account, with MagicDNS and HTTPS Certificates turned on in its <<admin console|\(Links.tailscaleAdmin)>>."
        static let copyAll = "Copy All Steps"
        static let title1 = "Share Hermes on your Tailscale network"
        static let text1 = "It prints your address, like https://your-computer.your-tailnet.ts.net. If this computer already shares something with Tailscale Serve, this replaces it: use --https=8443 instead and add :8443 to the address."
        static let link1 = "Tailscale Serve guide"
        static let title2 = "Turn on sign-in"
        static let secretLead = "Make a secret:"
        static let envLead = "Add four lines to the file ~/.hermes/.env, with your own username, password, that secret and the address from step 1:"
        /// The web says "your phone" on every device; Mac polish #143: the iPad and the Mac name themselves.
        static let text2 = "You choose this username and password here; they aren’t your AI provider’s login. Without the last line, Hermes turns \(device == "iPhone" ? "your phone" : "your \(device)") away."
        static let link2 = "Sign-in guide"
        static let title3 = "Start Hermes"
        static let text3 = "Run this and leave it running. Restart it whenever you change those lines."
        static let signIn = "Next: Sign In"
    }

    // MARK: Copy and share feedback (`COPIES`, `:182-208`)

    enum FeedbackKind: String, Sendable, CaseIterable {
        case agent, connect, connectLinux, prompt, steps

        /// What Copy (and Send) hand over.
        var text: String {
            switch self {
            case .agent: OnboardingCopy.hermesConnectPrompt
            case .connect, .connectLinux: OnboardingCopy.connectCommand
            case .prompt: OnboardingCopy.hermesSetupPrompt
            case .steps: OnboardingCopy.setupStepsText
            }
        }

        /// What Copy (and Send) hand over when this device already runs Tailscale (the setup's `--private`).
        func text(tailnetOnly: Bool) -> String {
            guard tailnetOnly else { return text }
            switch self {
            case .agent: return OnboardingCopy.Tailnet.prompt
            case .connect, .connectLinux: return OnboardingCopy.Tailnet.command
            case .prompt, .steps: return text
            }
        }

        var copied: String {
            switch self {
            case .agent: "Copied. Paste it into your chat with Hermes."
            case .connect where DeviceWord.isMac: "Copied. If both Macs use the same Apple Account, press ⌘V in Terminal on the other Mac to paste it."   // [mac]
            case .connect: "Copied. If this \(OnboardingCopy.device) and your Mac use the same Apple Account, press ⌘V in Terminal on your Mac to paste it."
            case .connectLinux: "Copied. Paste it into the terminal on that computer, or your SSH session to it."
            case .prompt: "Copied. Paste it into a chat with Hermes on that computer."
            case .steps: "Copied. Paste them on your computer, or into a note or message to yourself."
            }
        }

        var couldNotCopy: String {
            switch self {
            case .agent: "Couldn’t copy. \(DeviceWord.Tap) Send… or Show the message instead."
            case .connect: "Couldn’t copy. \(DeviceWord.Tap) \(OnboardingCopy.quick(.mac).share) instead."   // [mac] "Send…" there
            case .connectLinux: "Couldn’t copy. \(DeviceWord.Tap) Send… instead."
            case .prompt: "Couldn’t copy. \(DeviceWord.Tap) Show the message to select it."
            case .steps: "Couldn’t copy. The steps are listed below."
            }
        }
    }

    static let couldNotShare = "Couldn’t open sharing. \(DeviceWord.Tap) Copy instead."

    // MARK: The form's extras (`W:src/connection-onboarding.ts:104-106`, `W:src/main.ts:187`)

    static let needHelp = "Need help connecting?"
    /// The form inside the flow (`W:src/connection-onboarding.ts:97-98`, `W:src/main.ts:206`).
    static let formHeading = "Sign in to Hermes."
    /// UX study #24: the form's own word for the install ("the address of your Hermes", "Name for this Hermes"), not
    /// the web's "Add a gateway.".
    static let addHeading = "Add another Hermes."
    static let formLead = "Enter the address of your Hermes, then sign in."
    /// Says what it names (UX study 2026-10-19 #78: "Name" beside Username read as your own name).
    static let nameLabel = "Name for this Hermes"
    static let namePlaceholder = "Optional, like Home Mac"
    static let nameLimit = 60
}

/// The web's `Step` (`W:src/connection-onboarding.ts:6`).
nonisolated enum OnboardingStep: String, CaseIterable, Sendable {
    case welcome, hermes, `where`, mac1, mac2, mac3, linux1, linux2, linux3, other1, other2, manual, connect

    /// The screens of the connection guide (everything but the welcome and the form).
    static let guide: [OnboardingStep] = [.hermes, .where, .mac1, .mac2, .mac3, .linux1, .linux2, .linux3, .other1, .other2, .manual]
}
