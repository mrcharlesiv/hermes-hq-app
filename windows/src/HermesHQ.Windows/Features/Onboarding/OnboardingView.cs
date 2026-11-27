using Hermes.Core.Gateways;
using Hermes.Core.Net;
using Hermes.Core.Offline;
using Hermes.Core.Onboarding;
using HermesHQ.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Animation;
using static HermesHQ.Features.Onboarding.GuideKit;

namespace HermesHQ.Features.Onboarding;

/// The welcome, the connection guide and the sign-in form as one stack (App/Onboarding/OnboardingFlow.swift): the
/// signed-out window (rooted at the welcome) and the Add Gateway sheet (rooted at the form, with Cancel). Moving to the
/// step on show does nothing, a step already on the stack goes back to it, anything else goes forward; nothing moves
/// while a sign-in runs. Once a locked screen (Update Hermes) is on top, nothing leaves it but its own buttons.
public sealed class OnboardingView : UserControl
{
    public sealed record Options
    {
        /// Null: the signed-out window. Otherwise the sheet's purpose ("Add Gateway", "Sign In").
        public string? SheetTitle { get; init; }
        public OnboardingGate.Entry Entry { get; init; } = OnboardingGate.Entry.Form;
        public string Address { get; init; } = "";
        public string Username { get; init; } = "";
        public string? Notice { get; init; }
        /// Other saved gateways the form offers ("Switch to <name>"), when a gateway ended this PC's session.
        public IReadOnlyList<(string Key, string Title)> OtherGateways { get; init; } = [];
    }

    private readonly Options _options;
    private readonly OnboardingStack _stack;
    private readonly SignInForm _form;
    private readonly GuideContext _context;
    private readonly Button _back, _cancel;
    private readonly DropDownButton _others;
    private readonly TextBlock _eyebrow;
    private readonly Grid _bar;
    private readonly ContentControl _host;
    private readonly WelcomeScaleHost? _rootRoom;
    private bool _locked;

    /// A sign-in succeeded (saved and current).
    public event Action<GatewaySession, SignInOutcome>? SignedIn;
    /// Cancel in the sheet.
    public event Action? Cancelled;
    /// "Switch to <name>" on the form.
    public event Action<string>? SwitchTo;

    public bool IsSheet => _options.SheetTitle != null;
    public bool IsBusy => _stack.Busy;
    public OnboardingStep Current => _stack.Current;

    public OnboardingView(Options options)
    {
        _options = options;
        _stack = new OnboardingStack(root: !IsSheet, options.Entry);
        _context = new GuideContext { Go = Go, Fill = a => ShowForm(a), Centred = !IsSheet };
        _form = new SignInForm(options.Address, options.Username, options.Notice)
        {
            // "Add another Hermes." when adding one, "Sign in to Hermes." everywhere else.
            Heading = options.SheetTitle == "Add Gateway" ? OnboardingCopy.AddHeading : OnboardingCopy.FormHeading,
        };
        _form.OnHelp = () => Go(_stack.HelpStep);
        _form.BusyChanged += busy => { _stack.Busy = busy; ApplyBar(); };
        _form.SignedIn += (s, outcome) => SignedIn?.Invoke(s, outcome);

        _back = new Button { Content = new FontIcon { Glyph = "", FontSize = 14 }, Style = Style("QuietButtonStyle") };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_back, "Back");
        ToolTipService.SetToolTip(_back, "Back");
        _back.Click += (_, _) => Back();
        _eyebrow = new TextBlock { VerticalAlignment = VerticalAlignment.Center, Style = Style("CaptionTextBlockStyle"), Foreground = Brush("TextFillColorSecondaryBrush") };
        _cancel = new Button { Content = OfflineCopy.Cancel, Visibility = IsSheet ? Visibility.Visible : Visibility.Collapsed };
        _cancel.Click += (_, _) => { if (!_stack.Busy && !_locked) Cancelled?.Invoke(); };
        _others = new DropDownButton { Content = GatewaySwitchWords.Gateways, Visibility = Visibility.Collapsed };
        if (options.OtherGateways.Count > 0)
        {
            var menu = new MenuFlyout { Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.BottomEdgeAlignedRight };
            foreach (var (key, title) in options.OtherGateways)
            {
                var item = new MenuFlyoutItem { Text = OfflineCopy.SwitchTo(title), Icon = new FontIcon { Glyph = "" } };
                item.Click += (_, _) => { if (!_stack.Busy) SwitchTo?.Invoke(key); };
                menu.Items.Add(item);
            }
            _others.Flyout = menu;
            _others.Visibility = Visibility.Visible;
        }
        var bar = _bar = new Grid { Padding = new Thickness(12, 8, 12, 4), ColumnSpacing = 8, MinHeight = 44 };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.Children.Add(_back);
        Grid.SetColumn(_eyebrow, 1); bar.Children.Add(_eyebrow);
        Grid.SetColumn(_others, 2); bar.Children.Add(_others);
        Grid.SetColumn(_cancel, 3); bar.Children.Add(_cancel);
        _host = new ContentControl
        {
            IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch,
            ContentTransitions = [new ContentThemeTransition()],
        };
        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.Children.Add(bar);
        Grid.SetRow(_host, 1);
        root.Children.Add(_host);
        // Sheets sit outside MainWindow's zoomed frame.
        Content = IsSheet ? root : (_rootRoom = new WelcomeScaleHost(root));
        Render();
    }

    public void Go(OnboardingStep step)
    {
        if (_locked || !_stack.Go(step, out var leftForm)) return;
        AppLog.Note("onboard", $"onboarding step reached: {step}");
        if (leftForm) _form.LeftForGuide();
        Render();
    }

    public void Back()
    {
        if (_locked || !_stack.Back()) return;
        Render();
    }

    /// The form, from wherever the flow is, with this address in the field (a connect link, "On this PC").
    public bool ShowForm(string address)
    {
        if (_stack.Busy || _locked) return false;
        Go(OnboardingStep.Connect);
        _form.Fill(address);
        return true;
    }

    /// Another screen takes over (Update Hermes): no Back, no Cancel.
    public void PushLocked(FrameworkElement screen)
    {
        _locked = true;
        _host.Content = screen;
        ApplyBar();
    }

    private void Render()
    {
        var step = _stack.Current;
        _host.Content = step == OnboardingStep.Connect ? _form : GuideScreens.Build(step, _context);
        ApplyBar();
    }

    private void ApplyBar()
    {
        // Style the actual, empty navigation bar, not the Windows caption. Never carry the welcome's paint to the form.
        var welcome = !IsSheet && !_locked ? _host.Content as WelcomeScreen : null;
        _rootRoom?.ShowWelcome(welcome != null);
        _eyebrow.Visibility = welcome == null ? Visibility.Visible : Visibility.Collapsed;
        if (welcome != null)
        {
            _bar.ClearValue(FrameworkElement.MinHeightProperty);
            _bar.Style = welcome.GuideBarStyle;
        }
        else if (_bar.ReadLocalValue(FrameworkElement.StyleProperty) is Style)
        {
            _bar.ClearValue(FrameworkElement.StyleProperty);
            _bar.MinHeight = 44;
        }
        _back.Visibility = !_locked && _stack.CanGoBack ? Visibility.Visible : Visibility.Collapsed;
        _back.IsEnabled = !_stack.Busy;
        _cancel.IsEnabled = !_stack.Busy;
        _cancel.Visibility = IsSheet && !_locked ? Visibility.Visible : Visibility.Collapsed;
        _others.Visibility = !_locked && _options.OtherGateways.Count > 0 && _stack.Current == OnboardingStep.Connect
            ? Visibility.Visible : Visibility.Collapsed;
        _eyebrow.Text = _locked ? "" : OnboardingStack.Eyebrow(_stack.Current);
    }
}
