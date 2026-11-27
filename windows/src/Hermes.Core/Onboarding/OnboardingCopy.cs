using Hermes.Core.Gateways;

namespace Hermes.Core.Onboarding;

/// The web's `Step` (App/Onboarding/OnboardingCopy.swift `OnboardingStep`).
public enum OnboardingStep { Welcome, Start, GetHermes, Hermes, Where, Mac1, Mac2, Mac3, Linux1, Linux2, Linux3, Other1, Other2, Manual, Connect }

/// Every word, command and link of the welcome and the connection guide (App/Onboarding/OnboardingCopy.swift), with the
/// Mac app's desktop choices ("On this Mac" → "On this PC"; no camera, so step 3 copies the address the setup prints).
///
/// Rich lines use the Swift's small markup, drawn by the app's GuideText: `**bold**`, `[[key cap]]`, `` `code` `` and
/// `<<link text|address>>`. `GuideText.Plain` gives the words alone.
public static class OnboardingCopy
{
    public const string Device = DeviceWord.Name;

    public static class Links
    {
        public const string Hermes = "https://hermes-agent.nousresearch.com/docs/";
        public const string Dashboard = "https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard";
        public const string TailscaleServe = "https://tailscale.com/docs/features/tailscale-serve";
        /// The Mac's App Store page has no meaning here: Tailscale's own download page for Windows.
        public const string TailscaleApp = "https://tailscale.com/download/windows";
        public const string TailscaleAdmin = "https://login.tailscale.com/admin/dns";
    }

    /// A link that could not open, on every guide screen but the chooser.
    public static string CouldNotOpen(string address) => $"Couldn’t open it. Open this address in your web browser: {address}";
    public static string CouldNotOpenGuide(string address) => $"Couldn’t open the guide. Open this address in your web browser: {address}";

    // ---------------------------------------------------------------- commands and messages

    public const string ConnectCommand = "curl -fsSL https://raw.githubusercontent.com/mrcharlesiv/hermes-hq/main/connect.sh | sh";
    public const string ConnectPage = "github.com/mrcharlesiv/hermes-hq";

    /// The message for the person's own Hermes (`HERMES_CONNECT_PROMPT`): "the iPhone app" on every device, as the web's.
    public const string HermesConnectPrompt =
        "Please connect this computer to Hermes HQ, the iPhone app for Hermes, so I can reach you from anywhere and sign in with my Nous account.\n\n"
        + "Run this in your terminal, on this computer itself (if your terminal runs in a container, sandbox or another machine, stop and tell me):\n"
        + ConnectCommand + " -s -- --agent\n\n"
        + "It's safe to run again and again. Each time it either finishes or prints a NEXT STEP. If the next step is for you, do it. If it's for me (a link to open, a code, or a command that needs my password), send it to me word for word and wait until I say I've done it. Then run the command again, until it says DONE.\n\n"
        + "It uses Tailscale on this computer (free) to give it an address my phone can reach; my phone doesn't need Tailscale. Never send me files from this computer, and put any file path you mention in backticks.\n\n"
        + "When it says DONE, send me the address it prints and tell me to paste it into Hermes HQ and tap Sign in with Nous. If it says it can't run on this computer, tell me why.";

    public static class Setup
    {
        public const string Serve = "tailscale serve --bg 9119";
        public const string Secret = "openssl rand -base64 32";
        public static readonly string[] EnvLines =
        [
            "HERMES_DASHBOARD_BASIC_AUTH_USERNAME=your-username",
            "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=your-long-password",
            "HERMES_DASHBOARD_BASIC_AUTH_SECRET=the-secret-you-generated",
            "HERMES_DASHBOARD_PUBLIC_URL=https://your-computer.your-tailnet.ts.net",
        ];
        public static readonly string Env = string.Join("\n", EnvLines);
        public const string Start = "hermes dashboard --no-open";
    }

    /// What Copy All Steps copies (`SETUP_STEPS_TEXT`; note the trailing newline).
    public static readonly string SetupStepsText =
        "Hermes HQ setup (type these on the computer where Hermes is installed)\n\n"
        + $"Before you start: Tailscale is installed and signed in on this computer and on your {Device}, with the same account. In the Tailscale admin console ({Links.TailscaleAdmin}), MagicDNS and HTTPS Certificates are on.\n\n"
        + "1. Share Hermes on your Tailscale network:\n"
        + Setup.Serve + "\n"
        + "It prints your address, like https://your-computer.your-tailnet.ts.net\n"
        + "(If this computer already shares something with Tailscale Serve, that command replaces it. Use: tailscale serve --bg --https=8443 9119, and add :8443 to the address.)\n\n"
        + "2. Turn on sign-in. Make a secret:\n"
        + Setup.Secret + "\n"
        + "Then add these four lines to the file ~/.hermes/.env, with your own username, password, that secret and the address from step 1:\n"
        + Setup.Env + "\n\n"
        + "3. Start Hermes and leave it running:\n"
        + Setup.Start + "\n"
        + "(Restart it whenever you change those lines.)\n\n"
        + "4. In Hermes HQ, enter the address from step 1 and the username and password from step 2.\n\n"
        + $"More on sign-in, including a hashed password: {Links.Dashboard}\n";

    /// The Windows path's message for Hermes (`HERMES_SETUP_PROMPT`).
    public static readonly string HermesSetupPrompt =
        "Please set up this computer so I can use Hermes from Hermes HQ, the iPhone app for Hermes. Use your terminal tools and do each step yourself; stop and ask me only for what you can't do. If your terminal runs somewhere other than this computer (a container, sandbox or remote machine), stop and tell me.\n\n"
        + $"1. Check that Tailscale is installed, running and signed in (tailscale status). If it isn't, tell me how to install it and sign in, and wait for me. Remind me to install Tailscale on my phone with the same account, and to turn on MagicDNS and HTTPS certificates in the Tailscale admin console ({Links.TailscaleAdmin}).\n\n"
        + $"2. Run tailscale serve status. If nothing is being served, run: {Setup.Serve}\n"
        + "If something is already served, don't replace it; run tailscale serve --bg --https=8443 9119 instead and use :8443 in the address. The address is https:// plus this computer's MagicDNS name (Self.DNSName in tailscale status --json, without the trailing dot), e.g. https://your-computer.your-tailnet.ts.net\n\n"
        + $"3. Ask me for the username and password I want to type into Hermes HQ, or offer to generate a strong password. These are sign-in details for this computer's Hermes, not an AI provider login. Generate a secret with: {Setup.Secret}\n\n"
        + "4. Back up ~/.hermes/.env, then set these four lines in it (replace any existing values for the same keys, don't duplicate them):\n"
        + Setup.Env + "\n"
        + "using my username and password, the secret from step 3 and the address from step 2 (with :8443 if you used it).\n\n"
        + $"5. Start the dashboard so it keeps running after this chat ends: {Setup.Start} (in the background, e.g. with nohup, or as a login service). If a dashboard is already running, restart it so it reads the new settings.\n\n"
        + "6. Check it: curl -sI on the address should answer, not \"400 Invalid Host header\". If it fails, fix it and check again.\n\n"
        + "When you're done, tell me in plain words the address and username to type into Hermes HQ, and anything I still have to do myself. Don't repeat the password back in the chat.";

    // ---------------------------------------------------------------- welcome

    public sealed record Point(string Glyph, string Title, string Text);

    public static class Welcome
    {
        public const string HeadingLine1 = "Your Hermes,";
        public const string HeadingLine2 = "wherever you are.";
        public const string Lead = "Chat with your agents, see what they’re working on, and get a ping when they’re done, right from your " + Device + ".";
        /// Segoe Fluent glyphs for desktopcomputer, laptopcomputer, lock.
        public static readonly Point[] Points =
        [
            new("", "Hermes stays on your computer.", "Your agents, chats and files stay there."),
            new("", $"Hermes HQ connects your {Device} to it.", "Set it up once; it takes a few minutes."),
            new("", "Only you can get in.", "Hermes HQ never stores your password."),
        ];
        public const string Start = "Get Started";
        public const string HaveAddress = "I Already Have an Address";
    }

    public sealed record Choice(string Id, string Glyph, string Title, string Text, OnboardingStep Step);

    /// "Where is your Hermes?": on this PC, on another computer, or no Hermes yet (the Mac's choices).
    public static class Start
    {
        public const string Heading = "Where is your Hermes?";
        public const string Lead = "Hermes HQ connects to the Hermes you already use. Pick where yours runs.";
        public const string ComputerId = "computer", LocalId = "here", NoneId = "none";
        /// `hermes serve` listens on 127.0.0.1:9119. Not "localhost": Hermes turns away a Host it isn't bound to.
        public const string LocalAddress = "http://127.0.0.1:9119";
        public static readonly Choice[] Choices =
        [
            new(LocalId, "", $"On this {Device}", "Sign in to the Hermes running here.", OnboardingStep.Connect),
            new(ComputerId, "", "On another computer", "A Mac, Linux, Windows or a server.", OnboardingStep.Hermes),
        ];
        public const string NoneGlyph = "";
        public const string NoneTitle = "I don’t have Hermes yet";
        public const string NoneText = "See the two ways to get one.";
    }

    public static class GetHermes
    {
        public const string Heading = "Get Hermes first.";
        public const string Lead = "Hermes is the AI agent that Hermes HQ talks to. There are two ways to get one.";
        public const string InstallGlyph = "";
        public const string InstallTitle = "Install it on a computer";
        public const string InstallText = "Opens the Hermes guide. Follow it on a Mac, Linux, Windows or a server.";
        public const string Installed = "I’ve Installed Hermes";
        public const string After = "After you install it, come back here and " + DeviceWord.Tap + " **" + Installed + "**.";
    }

    public static class Where
    {
        public const string Eyebrow = "Set it up yourself";
        public const string Heading = "Which computer runs Hermes?";
        public const string Lead = "Pick the computer Hermes is installed on.";
        public static readonly Choice[] Choices =
        [
            new("mac", "", "On a Mac", "One command sets it up. Then you sign in with your Nous account.", OnboardingStep.Mac1),
            new("linux", "", "On Linux or a server", "The same one command, run there or over SSH. Then you sign in with Nous.", OnboardingStep.Linux1),
            new("windows", "", "On Windows", $"Uses Tailscale, a free app, on that computer and this {Device}, with a password.", OnboardingStep.Other1),
        ];
    }

    public static class LetHermes
    {
        public const string Heading = "Let Hermes set it up.";
        public const string Lead = "Send this message to your Hermes, wherever you chat with it: Telegram, Discord, the Hermes app or its terminal. Hermes sets up its own computer for you.";
        public const string Copy = "Copy Message";
        public const string ShowMessage = "Show the message";
        public static readonly string[] Steps =
        [
            "Hermes runs the setup on its computer.",
            $"It may send you a link or two to sign in to, both free: **Nous**, so only you can get in, and **Tailscale**, which gives that computer an address your {Device} can reach from anywhere.",
            $"When it’s done, Hermes sends you the address. Paste it on the next screen and {DeviceWord.Tap} **Sign in with Nous**.",
        ];
        public const string Footnote = "Tailscale runs only on that computer: nothing to install on this " + Device + ". Works when Hermes runs on a Mac or Linux, servers included.";
        public const string Windows = "Hermes on Windows? " + DeviceWord.TapCap + " **Set It Up Myself**.";
        public const string HaveAddress = "I Have the Address";
        public const string Myself = "Set It Up Myself";
    }

    // ---------------------------------------------------------------- Mac and Linux, three steps each

    public enum QuickKind { Mac, Linux }

    public sealed record Trouble(string Problem, string Fix);

    public sealed record Quick
    {
        public string Eyebrow1 { get; init; } = "Step 1 of 3";
        public string Eyebrow2 { get; init; } = "Step 2 of 3";
        public string Eyebrow3 { get; init; } = "Step 3 of 3";
        public required string Heading1 { get; init; }
        public required string Lead1 { get; init; }
        public required string Footnote1 { get; init; }
        public required string Heading2 { get; init; }
        public required string[] Steps2 { get; init; }
        public required string Note2 { get; init; }
        public required string TroubleTitle { get; init; }
        public required Trouble[] Troubles { get; init; }
        public required string Heading3 { get; init; }
        public required string Lead3 { get; init; }
        public required string[] Steps3 { get; init; }
        public required string Note3 { get; init; }
        public string Copy { get; init; } = "Copy";
        public string Next { get; init; } = "Next";
        public string TypeAddress { get; init; } = "Next: Sign In";
    }

    /// The Mac's words for another computer, seen from this PC (`quick(kind, onMac:)` with "this PC" for "this Mac"):
    /// step 3 copies the address printed under the setup's QR code, since a PC has no camera app to scan it with.
    public static Quick QuickFor(QuickKind kind, bool tailnetOnly = false)
    {
        var mac = kind == QuickKind.Mac;
        const string here = Device;
        var it = mac ? "your Mac" : "that computer";
        var enter = mac ? "Return" : "Enter";
        var trouble = new List<Trouble>
        {
            new("“Hermes isn’t installed”", $"Install Hermes on {(mac ? "this Mac" : "that computer")} first (<<Hermes setup guide|{Links.Hermes}>>), then run the command again."),
            new("“Hermes didn’t start in the background”", $"{(mac ? "Open a new Terminal window with [[⌘ N]], type" : "In a second terminal, type")} `hermes serve` and press [[{enter}]]. Leave it running, then run the command again in the first one."),
        };
        if (mac) trouble.Add(new("“Needs Node.js 20 or newer”", "Update Hermes: type `hermes update` and press [[Return]], then run the command again."));
        else
        {
            trouble.Add(new("“Tailscale is installed but not signed in”", "Type `sudo tailscale up`, open the link it shows and sign in, then run the command again."));
            trouble.Add(new("“systemd user services … can’t reach”", "Log in to that computer directly or over SSH as yourself, not with su or sudo, then run the command again."));
        }
        trouble.Add(new("“Turn on MagicDNS and HTTPS Certificates”", "Open the link it shows, switch both on, then run the command again."));
        trouble.Add(new("“Restart Hermes now”", "Stop Hermes where you started it ([[Control C]] in its window) and start it again the same way. The setup carries on by itself."));
        trouble.Add(new("Anything else", "Run the command again; that’s always safe. Still stuck? Paste what the terminal says into a chat with Hermes and ask it for help."));
        var terminal = mac ? "Terminal" : "the terminal";
        var steps2 = mac
            ? new[]
            {
                "Open **Terminal**: press [[⌘ Space]], type **Terminal**, then press [[Return]].",
                "Paste the command with [[⌘ V]], then press [[Return]].",
                $"Do what it asks. It signs this Mac in to **Nous**, so only you can get in, and to **Tailscale**, which gives your Mac an address this {here} can reach from anywhere (both free). It may open your browser for you to sign in, or ask you to click **Allow**.",
            }
            : new[]
            {
                "Open a terminal on the computer running Hermes, or connect to it with **SSH**.",
                "Paste the command and press [[Enter]].",
                $"Do what it asks. It signs that computer in to **Nous**, so only you can get in, and to **Tailscale**, which gives it an address this {here} can reach from anywhere (both free). It may show a link to open in any browser (this {here}’s is fine), or ask for your password once.",
            };
        var copy = new Quick
        {
            Heading1 = $"Get the setup command onto {it}.",
            Lead1 = (mac ? "You’ll paste one line into Terminal on your Mac." : "You’ll paste one line into a terminal on the computer running Hermes, or into an SSH session to it.")
                + " It sets up everything else for you.",
            Footnote1 = $"Or {(mac ? "on your Mac" : "on the computer you’ll type it on")}, open **{ConnectPage}** in a web browser and copy the command from there.",
            Heading2 = mac ? $"Run it in Terminal on {it}." : "Run it in a terminal there.",
            Steps2 = steps2,
            Note2 = $"It takes about five minutes. Tailscale runs only on {(mac ? "your Mac" : "that computer")}: your {Device} doesn’t need it. If you stop partway, run the command again: it picks up where it left off.",
            TroubleTitle = $"If {terminal} shows a problem",
            Troubles = [.. trouble],
            Heading3 = "Copy the address it prints.",
            Lead3 = $"When the setup is done, {terminal} shows a QR code for phones. Under it, the line that starts **Can’t scan it?** ends with {(mac ? "your Mac’s" : "that computer’s")} address.",
            Steps3 =
            [
                "Select the address at the end of that line (it starts with **https://**) and copy it.",
                "Click **Next: Sign In** and paste it with [[Ctrl V]], or type it.",
                $"Click **Sign in with Nous**, with the same Nous account you used {(mac ? "on your Mac" : "there")}.",
            ],
            Note3 = $"{(mac ? "Keep your Mac on and awake" : "Keep that computer on")}: Hermes HQ can reach Hermes only while it is.",
        };
        if (!tailnetOnly) return copy;
        var s2 = (string[])copy.Steps2.Clone();
        s2[2] = s2[2].Replace($", which gives {(mac ? "your Mac" : "it")} an address this {here} can reach from anywhere",
            $", with the same Tailscale account as this {here}");
        return copy with
        {
            Steps2 = s2,
            Note2 = $"It takes about five minutes. Sign in to Tailscale there with the same account as this {here}. If you stop partway, run the command again: it picks up where it left off.",
            Note3 = copy.Note3 + $" Leave Tailscale connected on this {here} too: the address works only on your Tailscale network.",
        };
    }

    /// For someone whose PC already runs Tailscale and who wants Hermes kept off the internet (the setup's --private).
    public static class Tailnet
    {
        public const string ToggleTitle = "This " + Device + " already uses Tailscale";
        public const string ToggleText = "Keep Hermes off the internet: only devices on your Tailscale network can reach it.";
        public const string Command = ConnectCommand + " -s -- --private";
        public static readonly string Prompt = HermesConnectPrompt
            .Replace("so I can reach you from anywhere", "so I can reach you from my phone over Tailscale")
            .Replace(ConnectCommand + " -s -- --agent", ConnectCommand + " -s -- --agent --private")
            .Replace("It uses Tailscale on this computer (free) to give it an address my phone can reach; my phone doesn't need Tailscale.",
                "It uses Tailscale on this computer (free) and keeps the address off the internet: only devices on my Tailscale network can reach it. My phone already runs Tailscale, so sign this computer in to the same Tailscale account.");
        public static readonly string[] LetHermesSteps =
        [
            LetHermes.Steps[0],
            $"It may send you a link or two to sign in to, both free: **Nous**, so only you can get in, and **Tailscale**, on that computer with the same account as this {Device}.",
            LetHermes.Steps[2],
        ];
        public const string LetHermesFootnote = "Leave Tailscale connected on this " + Device + ": the address works only on your Tailscale network. Works when Hermes runs on a Mac or Linux, servers included.";
    }

    // ---------------------------------------------------------------- Windows, two steps

    public static class Windows
    {
        public const string Eyebrow1 = "Step 1 of 2";
        public const string Heading1 = "Install Tailscale on both.";
        public const string Lead1 = "Tailscale is a free app that privately links this " + Device + " and the computer running Hermes, wherever you are.";
        public static readonly string[] Steps1 =
        [
            $"**On this {Device}:** install Tailscale and sign in.",
            "**On the computer running Hermes:** install Tailscale from **tailscale.com/download** and sign in with the same account.",
        ];
        public const string GetTailscale = "Get Tailscale";
        public const string Next = "Next";
        public const string Eyebrow2 = "Step 2 of 2";
        public const string Heading2 = "Let Hermes do the setup.";
        public const string Lead2 = "Copy this message and send it to Hermes on that computer, wherever you chat with it: in its terminal, Telegram, Discord or the Hermes app.";
        public const string Copy = "Copy Message for Hermes";
        public const string ShowMessage = "Show the message";
        public const string After = "Hermes does the setup, has you choose a password, then tells you the **address** and **username** to sign in with.";
        public const string Myself = "I’d Rather Do It Myself";
        public const string SignIn = "Next: Sign In";
    }

    public static class Manual
    {
        public const string Eyebrow = "Without Hermes’s help";
        public const string Heading = "Set it up yourself.";
        public const string Lead = "Type these on the computer running Hermes, not on this " + Device + ". Tailscale should already be on both, signed in to the same account, with MagicDNS and HTTPS Certificates turned on in its <<admin console|" + Links.TailscaleAdmin + ">>.";
        public const string CopyAll = "Copy All Steps";
        public const string Title1 = "Share Hermes on your Tailscale network";
        public const string Text1 = "It prints your address, like https://your-computer.your-tailnet.ts.net. If this computer already shares something with Tailscale Serve, this replaces it: use --https=8443 instead and add :8443 to the address.";
        public const string Link1 = "Tailscale Serve guide";
        public const string OwnAddress = "Not using Tailscale? Any address this " + Device + " can reach works: your own VPN such as WireGuard, your local network, or your own https:// address. Skip this step and use that address in step 2.";
        public const string Title2 = "Turn on sign-in";
        public const string SecretLead = "Make a secret:";
        public const string EnvLead = "Add four lines to the file ~/.hermes/.env, with your own username, password, that secret and the address from step 1:";
        public const string Text2 = "You choose this username and password here; they aren’t your AI provider’s login. Without the last line, Hermes turns your " + Device + " away.";
        public const string Link2 = "Sign-in guide";
        public const string Title3 = "Start Hermes";
        public const string Text3 = "Run this and leave it running. Restart it whenever you change those lines.";
        public const string SignIn = "Next: Sign In";
    }

    // ---------------------------------------------------------------- Copy feedback

    public enum FeedbackKind { Agent, Connect, ConnectLinux, Prompt, Steps }

    public static string Text(FeedbackKind kind, bool tailnetOnly = false) => kind switch
    {
        FeedbackKind.Agent => tailnetOnly ? Tailnet.Prompt : HermesConnectPrompt,
        FeedbackKind.Connect or FeedbackKind.ConnectLinux => tailnetOnly ? Tailnet.Command : ConnectCommand,
        FeedbackKind.Prompt => HermesSetupPrompt,
        _ => SetupStepsText,
    };

    public static string Copied(FeedbackKind kind) => kind switch
    {
        FeedbackKind.Agent => "Copied. Paste it into your chat with Hermes.",
        // The Mac's "same Apple Account, press ⌘V" has no meaning between a PC and a Mac.
        FeedbackKind.Connect => "Copied. Paste it into Terminal on your Mac.",
        FeedbackKind.ConnectLinux => "Copied. Paste it into the terminal on that computer, or your SSH session to it.",
        FeedbackKind.Prompt => "Copied. Paste it into a chat with Hermes on that computer.",
        _ => "Copied. Paste them on your computer, or into a note or message to yourself.",
    };

    public static string CouldNotCopy(FeedbackKind kind) => kind switch
    {
        FeedbackKind.Agent or FeedbackKind.Prompt => $"Couldn’t copy. {DeviceWord.TapCap} Show the message to select it.",
        FeedbackKind.Connect or FeedbackKind.ConnectLinux => "Couldn’t copy. Select the command above to copy it.",
        _ => "Couldn’t copy. The steps are listed below.",
    };

    // ---------------------------------------------------------------- the form's extras

    public const string NeedHelp = "Need help connecting?";
    public const string FormHeading = "Sign in to Hermes.";
    public const string AddHeading = "Add another Hermes.";
    public const string FormLead = "Paste or type the address of your Hermes, then sign in.";
    public const string NameLabel = "Name for this Hermes";
    public const string NamePlaceholder = "Optional, like Home Mac";
    public const int NameLimit = 60;
}

/// Which screen a signed-out launch starts on (App/Onboarding/OnboardingGate.swift): the welcome for a first run, the
/// form for a returning one.
public static class OnboardingGate
{
    public enum Entry { Welcome, Form }

    public static Entry EntryFor(string? linkAddress, string? prefillAddress, string? notice, bool signedInBefore)
    {
        static bool Has(string? t) => !string.IsNullOrWhiteSpace(t);
        return Has(linkAddress) || Has(prefillAddress) || Has(notice) || signedInBefore ? Entry.Form : Entry.Welcome;
    }
}

/// The flow's stack rule (App/Onboarding/OnboardingFlow.swift `go`): the step on show is a no-op, a step already on the
/// stack pops to it, anything else pushes; nothing moves while a sign-in runs. Pure, so tests read the stack.
public sealed class OnboardingStack
{
    private readonly List<OnboardingStep> _steps;

    /// `root`: the signed-out window (welcome at the bottom); otherwise the Add Gateway dialog (the form at the bottom).
    public OnboardingStack(bool root, OnboardingGate.Entry entry)
    {
        _steps = !root ? [OnboardingStep.Connect]
            : entry == OnboardingGate.Entry.Welcome ? [OnboardingStep.Welcome] : [OnboardingStep.Welcome, OnboardingStep.Connect];
    }

    public IReadOnlyList<OnboardingStep> Steps => _steps;
    public OnboardingStep Current => _steps[^1];
    public bool Busy { get; set; }
    /// "Let Hermes set it up." has been shown: the form's help link goes back there, not to the question before it.
    public bool SawMessage { get; private set; }
    public bool CanGoBack => !Busy && _steps.Count > 1;

    /// Where "Need help connecting?" goes.
    public OnboardingStep HelpStep => SawMessage ? OnboardingStep.Hermes : OnboardingStep.Start;

    /// Returns whether the stack changed; `popped` tells the caller the form was left (it forgets the password).
    public bool Go(OnboardingStep step, out bool leftForm)
    {
        leftForm = false;
        if (Busy || step == Current) return false;
        leftForm = Current == OnboardingStep.Connect;
        if (step == OnboardingStep.Hermes) SawMessage = true;
        var at = _steps.IndexOf(step);
        if (at >= 0) _steps.RemoveRange(at + 1, _steps.Count - at - 1);
        else _steps.Add(step);
        return true;
    }

    public bool Back()
    {
        if (!CanGoBack) return false;
        _steps.RemoveAt(_steps.Count - 1);
        return true;
    }

    /// The eyebrow over a guide screen (the Swift's bar title): "Step 1 of 3", "Set it up yourself", …
    public static string Eyebrow(OnboardingStep step) => step switch
    {
        OnboardingStep.Where => OnboardingCopy.Where.Eyebrow,
        OnboardingStep.Mac1 or OnboardingStep.Linux1 => "Step 1 of 3",
        OnboardingStep.Mac2 or OnboardingStep.Linux2 => "Step 2 of 3",
        OnboardingStep.Mac3 or OnboardingStep.Linux3 => "Step 3 of 3",
        OnboardingStep.Other1 => OnboardingCopy.Windows.Eyebrow1,
        OnboardingStep.Other2 => OnboardingCopy.Windows.Eyebrow2,
        OnboardingStep.Manual => OnboardingCopy.Manual.Eyebrow,
        _ => "",
    };
}
