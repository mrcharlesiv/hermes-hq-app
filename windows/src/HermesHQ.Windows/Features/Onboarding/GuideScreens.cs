using Hermes.Core.Onboarding;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using static HermesHQ.Features.Onboarding.GuideKit;
using Copy = Hermes.Core.Onboarding.OnboardingCopy;

namespace HermesHQ.Features.Onboarding;

/// What a guide screen can do: move the flow, fill the form with an address, copy and open links.
public sealed class GuideContext
{
    public required Action<OnboardingStep> Go { get; init; }
    public required Action<string> Fill { get; init; }
    public GuideActions Actions { get; init; } = GuideActions.Live;
    public SetupReach Reach { get; init; } = new();
    /// The first-run window centres each screen's block top to bottom (the Mac's Q19); the sheet doesn't.
    public bool Centred { get; init; }
}

/// The welcome and the connection guide's screens (App/Onboarding/*View.swift), one builder each.
public static class GuideScreens
{
    public static FrameworkElement Build(OnboardingStep step, GuideContext c) => step switch
    {
        OnboardingStep.Welcome => new WelcomeScreen(c),
        OnboardingStep.Start => Start(c),
        OnboardingStep.GetHermes => GetHermes(c),
        OnboardingStep.Hermes => LetHermes(c),
        OnboardingStep.Where => Where(c),
        OnboardingStep.Mac1 => QuickCommand(Copy.QuickKind.Mac, c),
        OnboardingStep.Linux1 => QuickCommand(Copy.QuickKind.Linux, c),
        OnboardingStep.Mac2 => QuickRun(Copy.QuickKind.Mac, c),
        OnboardingStep.Linux2 => QuickRun(Copy.QuickKind.Linux, c),
        OnboardingStep.Mac3 => QuickAddress(Copy.QuickKind.Mac, c),
        OnboardingStep.Linux3 => QuickAddress(Copy.QuickKind.Linux, c),
        OnboardingStep.Other1 => WindowsTailscale(c),
        OnboardingStep.Other2 => WindowsMessage(c),
        OnboardingStep.Manual => Manual(c),
        _ => throw new ArgumentOutOfRangeException(nameof(step)),
    };

    /// "Where is your Hermes?" (App/Onboarding/StartView.swift): on this PC (the form at its own address), on another
    /// computer, or no Hermes yet. Hermes Cloud and Cloudflare Access have their own rows on the Mac (not built here).
    private static FrameworkElement Start(GuideContext c)
    {
        var rows = new StackPanel { Spacing = 10 };
        foreach (var choice in Copy.Start.Choices)
        {
            rows.Children.Add(ChoiceRow(choice.Glyph, choice.Title, choice.Text, () =>
            {
                if (choice.Id == Copy.Start.LocalId) c.Fill(Copy.Start.LocalAddress); else c.Go(choice.Step);
            }));
        }
        rows.Children.Add(ChoiceRow(Copy.Start.NoneGlyph, Copy.Start.NoneTitle, Copy.Start.NoneText, () => c.Go(OnboardingStep.GetHermes)));
        return Page(Copy.Start.Heading, [Paragraph(Copy.Start.Lead), rows], centred: c.Centred);
    }

    /// "Get Hermes first." (StartView.swift `GetHermesView`).
    private static FrameworkElement GetHermes(GuideContext c)
    {
        var error = ErrorLine();
        var rows = new StackPanel { Spacing = 10 };
        rows.Children.Add(ChoiceRow(Copy.GetHermes.InstallGlyph, Copy.GetHermes.InstallTitle, Copy.GetHermes.InstallText,
            () => OpenLink(c.Actions, Copy.Links.Hermes, error, Copy.CouldNotOpenGuide)));
        return Page(Copy.GetHermes.Heading, [Paragraph(Copy.GetHermes.Lead), rows, Paragraph(Copy.GetHermes.After, small: true)],
            // Installed, the way on is here: back to the question, where a Hermes on this PC has its own row.
            [Action(Copy.GetHermes.Installed, () => c.Go(OnboardingStep.Start), prominent: false)], error, c.Centred);
    }

    /// "Let Hermes set it up." (App/Onboarding/LetHermesView.swift).
    private static FrameworkElement LetHermes(GuideContext c)
    {
        var message = Block(Copy.Text(Copy.FeedbackKind.Agent, c.Reach.TailnetOnly));
        var steps = new ContentControl { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        var foot = new ContentControl { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        void Refresh()
        {
            ((TextBlock)message.Child).Text = Copy.Text(Copy.FeedbackKind.Agent, c.Reach.TailnetOnly);
            steps.Content = Steps(c.Reach.TailnetOnly ? Copy.Tailnet.LetHermesSteps : Copy.LetHermes.Steps);
            foot.Content = Paragraph((c.Reach.TailnetOnly ? Copy.Tailnet.LetHermesFootnote : Copy.LetHermes.Footnote)
                + " " + Copy.LetHermes.Windows, small: true);
        }
        Refresh();
        var card = CommandCard(Copy.FeedbackKind.Agent, Copy.LetHermes.Copy, c.Actions, () => c.Reach.TailnetOnly,
            body: Disclosure(Copy.LetHermes.ShowMessage, message));
        return Page(Copy.LetHermes.Heading, [Paragraph(Copy.LetHermes.Lead), card, steps, foot, TailnetToggle(c.Reach, Refresh)],
        [
            Action(Copy.LetHermes.HaveAddress, () => c.Go(OnboardingStep.Connect)),
            Action(Copy.LetHermes.Myself, () => c.Go(OnboardingStep.Where), prominent: false),
        ], centred: c.Centred);
    }

    /// "Which computer runs Hermes?" (App/Onboarding/WhereView.swift).
    private static FrameworkElement Where(GuideContext c)
    {
        var rows = new StackPanel { Spacing = 10 };
        foreach (var choice in Copy.Where.Choices) rows.Children.Add(ChoiceRow(choice.Glyph, choice.Title, choice.Text, () => c.Go(choice.Step)));
        return Page(Copy.Where.Heading, [Paragraph(Copy.Where.Lead), rows], centred: c.Centred);
    }

    /// Step 1: get the setup command onto the computer (QuickSetupViews.swift `QuickSetupCommandView`).
    private static FrameworkElement QuickCommand(Copy.QuickKind kind, GuideContext c)
    {
        var feedback = kind == Copy.QuickKind.Mac ? Copy.FeedbackKind.Connect : Copy.FeedbackKind.ConnectLinux;
        var copy = Copy.QuickFor(kind, c.Reach.TailnetOnly);
        var command = Block(Copy.Text(feedback, c.Reach.TailnetOnly));
        var card = CommandCard(feedback, copy.Copy, c.Actions, () => c.Reach.TailnetOnly, body: command);
        var toggle = TailnetToggle(c.Reach, () => ((TextBlock)command.Child).Text = Copy.Text(feedback, c.Reach.TailnetOnly));
        return Page(copy.Heading1, [Paragraph(copy.Lead1), card, Paragraph(copy.Footnote1, small: true), toggle],
            [Action(copy.Next, () => c.Go(kind == Copy.QuickKind.Mac ? OnboardingStep.Mac2 : OnboardingStep.Linux2))], centred: c.Centred);
    }

    /// Step 2: run it, key by key, with the problems the terminal may show (`QuickSetupRunView`).
    private static FrameworkElement QuickRun(Copy.QuickKind kind, GuideContext c)
    {
        var copy = Copy.QuickFor(kind, c.Reach.TailnetOnly);
        var error = ErrorLine();
        void Open(string address) => OpenLink(c.Actions, address, error);
        var trouble = new StackPanel { Spacing = 14 };
        foreach (var t in copy.Troubles)
        {
            var item = new StackPanel { Spacing = 3 };
            item.Children.Add(new TextBlock { Text = t.Problem, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
            item.Children.Add(Paragraph(t.Fix, Open, small: true));
            trouble.Children.Add(item);
        }
        return Page(copy.Heading2, [Steps(copy.Steps2), Note(copy.Note2), Disclosure(copy.TroubleTitle, trouble)],
            [Action(copy.Next, () => c.Go(kind == Copy.QuickKind.Mac ? OnboardingStep.Mac3 : OnboardingStep.Linux3))], error, c.Centred);
    }

    /// Step 3: on a PC, copy the address the setup prints under its QR code (`QuickSetupScanView`, the Mac's words).
    private static FrameworkElement QuickAddress(Copy.QuickKind kind, GuideContext c)
    {
        var copy = Copy.QuickFor(kind, c.Reach.TailnetOnly);
        return Page(copy.Heading3, [Paragraph(copy.Lead3), Steps(copy.Steps3), Note(copy.Note3)],
            [Action(copy.TypeAddress, () => c.Go(OnboardingStep.Connect))], centred: c.Centred);
    }

    /// The Windows path, step 1: Tailscale on both (App/Onboarding/WindowsViews.swift).
    private static FrameworkElement WindowsTailscale(GuideContext c)
    {
        var error = ErrorLine();
        var first = new StackPanel { Spacing = 10 };
        first.Children.Add(Paragraph(Copy.Windows.Steps1[0], primary: true));
        first.Children.Add(Link(Copy.Windows.GetTailscale, () => OpenLink(c.Actions, Copy.Links.TailscaleApp, error)));
        var steps = new StackPanel { Spacing = 18 };
        steps.Children.Add(StepRow(1, first));
        steps.Children.Add(StepRow(2, Paragraph(Copy.Windows.Steps1[1], primary: true)));
        return Page(Copy.Windows.Heading1, [Paragraph(Copy.Windows.Lead1), steps],
            [Action(Copy.Windows.Next, () => c.Go(OnboardingStep.Other2))], error, c.Centred);
    }

    /// The Windows path, step 2: a message for Hermes to do the setup with a password.
    private static FrameworkElement WindowsMessage(GuideContext c)
    {
        var card = CommandCard(Copy.FeedbackKind.Prompt, Copy.Windows.Copy, c.Actions, () => false,
            body: Disclosure(Copy.Windows.ShowMessage, Block(Copy.HermesSetupPrompt)));
        var myself = new HyperlinkButton { Content = Copy.Windows.Myself, HorizontalAlignment = HorizontalAlignment.Center };
        myself.Click += (_, _) => c.Go(OnboardingStep.Manual);
        return Page(Copy.Windows.Heading2, [Paragraph(Copy.Windows.Lead2), card, Paragraph(Copy.Windows.After), myself],
            [Action(Copy.Windows.SignIn, () => c.Go(OnboardingStep.Connect))], centred: c.Centred);
    }

    /// "Set it up yourself." (App/Onboarding/ManualSetupView.swift): the commands, with placeholders only.
    private static FrameworkElement Manual(GuideContext c)
    {
        var error = ErrorLine();
        void Open(string address) => OpenLink(c.Actions, address, error);
        var status = StatusLine();
        var copyAll = Link(Copy.Manual.CopyAll, () =>
        {
            Say(status, "");
            Say(status, c.Actions.Copy(Copy.SetupStepsText) ? Copy.Copied(Copy.FeedbackKind.Steps) : Copy.CouldNotCopy(Copy.FeedbackKind.Steps));
        });
        var top = new StackPanel { Spacing = 4, Children = { copyAll, status } };
        StackPanel Section(int number, string title, params UIElement[] content)
        {
            var body = new StackPanel { Spacing = 10 };
            var head = new TextBlock { Text = title, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(head, $"{number}. {title}");
            body.Children.Add(head);
            foreach (var x in content) body.Children.Add(x);
            return new StackPanel { Children = { StepRow(number, body) } };
        }
        return Page(Copy.Manual.Heading,
        [
            Paragraph(Copy.Manual.Lead, Open),
            top,
            Section(1, Copy.Manual.Title1, Block(Copy.Setup.Serve), Paragraph(Copy.Manual.Text1, small: true),
                Link(Copy.Manual.Link1, () => Open(Copy.Links.TailscaleServe)), Paragraph(Copy.Manual.OwnAddress, small: true)),
            Section(2, Copy.Manual.Title2, Paragraph(Copy.Manual.SecretLead, small: true), Block(Copy.Setup.Secret),
                Paragraph(Copy.Manual.EnvLead, small: true), Block(Copy.Setup.Env), Paragraph(Copy.Manual.Text2, small: true),
                Link(Copy.Manual.Link2, () => Open(Copy.Links.Dashboard))),
            Section(3, Copy.Manual.Title3, Paragraph(Copy.Manual.Text3, small: true), Block(Copy.Setup.Start)),
        ],
        [Action(Copy.Manual.SignIn, () => c.Go(OnboardingStep.Connect))], error, c.Centred);
    }
}
