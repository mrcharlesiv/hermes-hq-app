using Hermes.Core.Auth;
using Hermes.Core.Gateways;
using Hermes.Core.Net;
using Hermes.Core.Offline;
using Hermes.Core.Onboarding;
using HermesHQ.Services;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using VirtualKey = Windows.System.VirtualKey;
using Launcher = Windows.System.Launcher;
using static HermesHQ.Features.Onboarding.GuideKit;

namespace HermesHQ.Features.Onboarding;

/// The sign-in form (App/SignIn/SignInView.swift with its SignInModel): the Hermes address first; a quiet probe 600 ms
/// after typing stops shows the ways in it offers — Sign in with Nous (the accent button) and/or a username and
/// password — then the optional Name. One attempt per click; after it, one capped read of the gateway's version
/// decides between the app and "Update Hermes" (docs/spec/3x-onboarding.md §5.14).
public sealed class SignInForm : UserControl
{
    private readonly DispatcherQueue _ui = DispatcherQueue.GetForCurrentThread();
    private readonly CancellationToken _windowStop = App.Window?.Lifetime.StopToken ?? default;
    private readonly TextBlock _heading, _subtitle, _footnote;
    private readonly TextBox _address, _username, _name;
    private readonly PasswordBox _password;
    private readonly ProgressRing _checkingRing;
    private readonly Button _paste, _continue, _nous, _signIn;
    private readonly HyperlinkButton _cancelNous, _help;
    private readonly StackPanel _note, _notice, _error, _options, _nousWay, _passwordWay, _orLine, _nameField, _nameUnderAddress;
    private readonly TextBlock _noteText, _noticeText, _errorText;
    private CancellationTokenSource? _debounce, _nousCancel;
    private string _asked = "";
    private bool _checking;

    /// nil until the address has been asked about (only the field and Continue show).
    public SignInWays? Ways { get; private set; }
    public bool IsBusy { get; private set; }
    /// The form's heading where the flow hosts it ("Sign in to Hermes.", "Add another Hermes."); null: the app's name.
    public string? Heading { get => _heading.Text; set { _heading.Text = value ?? "Hermes HQ"; UpdateSubtitle(); } }
    /// "Need help connecting?": shown only where there is a guide to open.
    public Action? OnHelp
    {
        get => _onHelp;
        set { _onHelp = value; _help.Visibility = value == null ? Visibility.Collapsed : Visibility.Visible; }
    }
    private Action? _onHelp;
    /// A sign-in (and the version check after it) started or ended: the flow holds navigation meanwhile.
    public event Action<bool>? BusyChanged;
    /// A sign-in succeeded: the session is saved and current; the outcome says whether Hermes needs an update first.
    public event Action<GatewaySession, SignInOutcome>? SignedIn;

    public SignInForm(string address = "", string username = "", string? notice = null)
    {
        _heading = new TextBlock { Text = "Hermes HQ", TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, Style = Style("TitleLargeTextBlockStyle") };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetHeadingLevel(_heading, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level1);
        _subtitle = new TextBlock { TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, MaxWidth = 360, Foreground = Brush("TextFillColorSecondaryBrush") };
        var header = new StackPanel { Spacing = 10, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 12) };
        header.Children.Add(AppIcon());
        header.Children.Add(_heading);
        header.Children.Add(_subtitle);

        // The address, with the check's spinner, or Paste while it is empty.
        _address = new TextBox { PlaceholderText = SignInCopy.AddressPlaceholder, IsSpellCheckEnabled = false, Text = address };
        _address.InputScope = new InputScope { Names = { new InputScopeName(InputScopeNameValue.Url) } };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_address, SignInCopy.AddressLabel);
        _checkingRing = new ProgressRing { Width = 18, Height = 18, IsActive = false, Visibility = Visibility.Collapsed };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_checkingRing, "Checking the address");
        _paste = new Button { Content = SignInCopy.Paste, Padding = new Thickness(10, 4, 10, 4) };
        _paste.Click += async (_, _) => await PasteAsync();
        var addressRow = new Grid { ColumnSpacing = 8 };
        addressRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        addressRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        addressRow.Children.Add(_address);
        var trailing = new Grid { VerticalAlignment = VerticalAlignment.Center, Children = { _checkingRing, _paste } };
        Grid.SetColumn(trailing, 1);
        addressRow.Children.Add(trailing);
        var addressField = Field(SignInCopy.AddressLabel, addressRow);
        _address.TextChanged += (_, _) => AddressChanged();
        _address.LostFocus += (_, _) => Ask();
        _address.KeyDown += Address_KeyDown;

        (_note, _noteText) = Line("", "SystemFillColorCautionBrush", "TextFillColorPrimaryBrush");
        (_notice, _noticeText) = Line("", "TextFillColorSecondaryBrush", "TextFillColorSecondaryBrush");
        (_error, _errorText) = Line("", "SystemFillColorCriticalBrush", "SystemFillColorCriticalBrush");
        _errorText.IsTextSelectionEnabled = true; // some errors name a setting to type on the computer running Hermes

        _continue = new Button { Content = SignInCopy.Continue, Style = Style("AccentButtonStyle"), HorizontalAlignment = HorizontalAlignment.Stretch, MinHeight = 34, IsEnabled = address.Trim().Length > 0 };
        _continue.Click += (_, _) => Ask();

        // The ways in.
        _name = new TextBox { PlaceholderText = OnboardingCopy.NamePlaceholder, MaxLength = OnboardingCopy.NameLimit };
        _name.KeyDown += (_, e) => { if (e.Key == VirtualKey.Enter) { e.Handled = true; SubmitFromName(); } };
        _nameField = Field(OnboardingCopy.NameLabel, _name);
        _nameUnderAddress = new StackPanel();
        _nous = new Button { Style = Style("AccentButtonStyle"), HorizontalAlignment = HorizontalAlignment.Stretch, MinHeight = 34 };
        _nous.Click += (_, _) => SignInWithNous();
        _cancelNous = new HyperlinkButton { Content = OfflineCopy.Cancel, HorizontalAlignment = HorizontalAlignment.Center, Visibility = Visibility.Collapsed };
        _cancelNous.Click += (_, _) => _nousCancel?.Cancel();
        _nousWay = new StackPanel { Spacing = 6, Children = { _nous, _cancelNous } };
        _orLine = OrLine();
        _username = new TextBox { IsSpellCheckEnabled = false, Text = username };
        _username.KeyDown += (_, e) => { if (e.Key == VirtualKey.Enter) { e.Handled = true; _password!.Focus(FocusState.Keyboard); } };
        _password = new PasswordBox();
        _password.PasswordChanged += (_, _) => _password.BorderBrush = null;
        _password.KeyDown += (_, e) => { if (e.Key == VirtualKey.Enter) { e.Handled = true; SignInWithPassword(); } };
        _signIn = new Button { HorizontalAlignment = HorizontalAlignment.Stretch, MinHeight = 34 };
        _signIn.Click += (_, _) => SignInWithPassword();
        _passwordWay = new StackPanel { Spacing = 12 };
        _passwordWay.Children.Add(Field(SignInCopy.Username, _username));
        _passwordWay.Children.Add(Field(SignInCopy.Password, _password));
        _options = new StackPanel { Spacing = 14, Visibility = Visibility.Collapsed, Children = { _nameUnderAddress, _nousWay, _orLine, _passwordWay } };

        _footnote = new TextBlock { FontSize = 12, TextWrapping = TextWrapping.Wrap, Foreground = Brush("TextFillColorSecondaryBrush"), Visibility = Visibility.Collapsed };
        _help = new HyperlinkButton { Content = OnboardingCopy.NeedHelp, HorizontalAlignment = HorizontalAlignment.Center, Visibility = Visibility.Collapsed };
        _help.Click += (_, _) => OnHelp?.Invoke();

        var column = new StackPanel { Spacing = 14, MaxWidth = ContentWidth, Padding = new Thickness(24, 12, 24, 32) };
        column.Children.Add(header);
        foreach (var e in new UIElement[] { addressField, _note, _continue, _options, _notice, _error, _footnote, _help }) column.Children.Add(e);
        Content = new ScrollViewer
        {
            Content = new Grid { Children = { column }, VerticalAlignment = VerticalAlignment.Center },
            HorizontalScrollMode = ScrollMode.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
        if (notice != null) Show(_notice, _noticeText, notice);
        ApplyWays();
        Loaded += (_, _) =>
        {
            if (_windowStop.IsCancellationRequested) return;
            if (Ways == null) _address.Focus(FocusState.Programmatic);
            if (_address.Text.Trim().Length > 0) Ask();
        };
    }

    private static StackPanel Field(string label, UIElement control)
    {
        var p = new StackPanel { Spacing = 6 };
        p.Children.Add(new TextBlock { Text = label, FontSize = 12, FontWeight = FontWeights.Medium, Foreground = Brush("TextFillColorSecondaryBrush") });
        p.Children.Add(control);
        return p;
    }

    private static (StackPanel, TextBlock) Line(string glyph, string iconBrush, string textBrush)
    {
        var text = new TextBlock { TextWrapping = TextWrapping.Wrap, Foreground = Brush(textBrush) };
        var g = new Grid { ColumnSpacing = 8 };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.Children.Add(new FontIcon { Glyph = glyph, FontSize = 14, Foreground = Brush(iconBrush), VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 2, 0, 0) });
        Grid.SetColumn(text, 1);
        g.Children.Add(text);
        return (new StackPanel { Visibility = Visibility.Collapsed, Children = { g } }, text);
    }

    private static StackPanel OrLine()
    {
        var g = new Grid { ColumnSpacing = 10 };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var left = new Border { Height = 1, Background = Brush("DividerStrokeColorDefaultBrush"), VerticalAlignment = VerticalAlignment.Center };
        var words = new TextBlock { Text = SignInCopy.OrWithPassword, FontSize = 12, Foreground = Brush("TextFillColorSecondaryBrush") };
        var right = new Border { Height = 1, Background = Brush("DividerStrokeColorDefaultBrush"), VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(words, 1);
        Grid.SetColumn(right, 2);
        g.Children.Add(left); g.Children.Add(words); g.Children.Add(right);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAccessibilityView(g, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        return new StackPanel { Children = { g } };
    }

    private static void Show(StackPanel line, TextBlock text, string? words)
    {
        text.Text = words ?? "";
        line.Visibility = string.IsNullOrEmpty(words) ? Visibility.Collapsed : Visibility.Visible;
    }

    // ---------------------------------------------------------------- the address

    /// An address handed to the form (a connect link, "On this PC"): filled in and asked about. A typed password
    /// belongs to the address it was typed for: another address never inherits it.
    public void Fill(string address)
    {
        if (IsBusy || _windowStop.IsCancellationRequested) return;
        if (address.Trim() != _address.Text.Trim()) _password.Password = "";
        _address.Text = address;
        Ask();
    }

    /// The form left the screen for the guide: what was typed stays, except the password.
    public void LeftForGuide() => _password.Password = "";

    private async Task PasteAsync()
    {
        try
        {
            var data = Windows.ApplicationModel.DataTransfer.Clipboard.GetContent();
            if (!data.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.Text)) return;
            Fill(SignInAddress.Pasted(await data.GetTextAsync()));
        }
        catch (Exception e) { AppLog.Error("paste", e); }
    }

    private void AddressChanged()
    {
        if (_windowStop.IsCancellationRequested) return;
        _address.BorderBrush = null;
        _debounce?.Cancel();
        var text = _address.Text.Trim();
        _paste.Visibility = text.Length == 0 && !_checking ? Visibility.Visible : Visibility.Collapsed;
        _continue.IsEnabled = text.Length > 0 && !_checking && !IsBusy;
        if (text.Length == 0)
        {
            _asked = ""; Ways = null; SetChecking(false); Show(_note, _noteText, null);
            ApplyWays();
            return;
        }
        // A pasted setup link (hermes://connect?url=…) becomes the address in it.
        if (SignInAddress.FromConnectLink(text) is { } inner) { _address.Text = inner; return; }
        var cts = _debounce = new CancellationTokenSource();
        _ = Task.Delay(600, cts.Token).ContinueWith(t =>
        {
            if (!t.IsCanceled && !_windowStop.IsCancellationRequested) _ui.TryEnqueue(Ask);
        }, TaskScheduler.Default);
    }

    private void Address_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter) return;
        e.Handled = true;
        if (Ways == SignInWays.Nous && WaysAreCurrent) { SignInWithNous(); return; }
        Ask();
        if (Ways?.ShowsPassword() == true && WaysAreCurrent) (_username.Text.Length == 0 ? (Control)_username : _password).Focus(FocusState.Keyboard);
    }

    private bool WaysAreCurrent => Ways != null && !_checking && _asked == _address.Text.Trim();

    private void SetChecking(bool on)
    {
        _checking = on;
        _checkingRing.IsActive = on;
        _checkingRing.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
        _paste.Visibility = !on && _address.Text.Trim().Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        _continue.Content = on ? SignInCopy.Checking : SignInCopy.Continue;
        _continue.IsEnabled = !on && !IsBusy && _address.Text.Trim().Length > 0;
    }

    /// Asks about the address now (after the pause, on Enter, or when the field is left). An answer is applied only
    /// while the field still holds the text it was asked about.
    public async void Ask()
    {
        if (_windowStop.IsCancellationRequested) return; // includes a delivery already in the dispatcher queue
        _debounce?.Cancel();
        var text = _address.Text.Trim();
        if (text.Length == 0 || text == _asked) return;
        _asked = text;
        if (!SignInAddress.LooksLikeAddress(text))
        {
            Ways = SignInWays.Both; SetChecking(false); Show(_note, _noteText, null);
            ApplyWays();
            return;
        }
        SetChecking(true);
        SignIn.Probe probe;
        try { probe = await AppState.SignIn.ProbeAsync(GatewayAddress.FromTyped(text), _windowStop); }
        catch (OperationCanceledException) when (_windowStop.IsCancellationRequested) { return; }
        catch (GatewayException) { probe = SignIn.Probe.Unknown; }
        if (_windowStop.IsCancellationRequested || _asked != text) return; // a newer ask owns the spinner
        if (_address.Text.Trim() != text) { _asked = ""; return; }
        SetChecking(false);
        Ways = SignInWaysExtensions.From(probe);
        Show(_note, _noteText, SignInCopy.ProbeNote(probe));
        AppLog.Note("signin", $"address probe settled: known={probe.Known} answered={probe.Answered}");
        ApplyWays();
    }

    private void UpdateSubtitle() =>
        _subtitle.Text = Ways == null && _heading.Text != "Hermes HQ" ? OnboardingCopy.FormLead : SignInCopy.Subtitle(Ways);

    private void ApplyWays()
    {
        UpdateSubtitle();
        _continue.Visibility = Ways == null ? Visibility.Visible : Visibility.Collapsed;
        _options.Visibility = Ways == null ? Visibility.Collapsed : Visibility.Visible;
        _footnote.Visibility = Ways == null ? Visibility.Collapsed : Visibility.Visible;
        if (Ways is not { } ways) return;
        _footnote.Text = SignInCopy.Footnote(ways);
        _nousWay.Visibility = ways.ShowsNous() ? Visibility.Visible : Visibility.Collapsed;
        _orLine.Visibility = ways == SignInWays.Both ? Visibility.Visible : Visibility.Collapsed;
        _passwordWay.Visibility = ways.ShowsPassword() ? Visibility.Visible : Visibility.Collapsed;
        // The optional Name: under the address for Nous only, else under Password (before Sign In).
        _nameUnderAddress.Children.Clear();
        _passwordWay.Children.Remove(_nameField);
        _passwordWay.Children.Remove(_signIn);
        if (ways == SignInWays.Nous) _nameUnderAddress.Children.Add(_nameField);
        else { _passwordWay.Children.Add(_nameField); _passwordWay.Children.Add(_signIn); }
        _signIn.Style = ways == SignInWays.Password ? Style("AccentButtonStyle") : Style("DefaultButtonStyle");
        ApplyBusy(null);
    }

    // ---------------------------------------------------------------- signing in

    private enum Way { Nous, Password }

    private void ApplyBusy(Way? busy)
    {
        IsBusy = busy != null;
        _address.IsEnabled = _username.IsEnabled = _password.IsEnabled = _name.IsEnabled = !IsBusy;
        _nous.IsEnabled = _signIn.IsEnabled = _help.IsEnabled = !IsBusy;
        _continue.IsEnabled = !IsBusy && !_checking && _address.Text.Trim().Length > 0;
        _nous.Content = Busy(busy == Way.Nous, SignInCopy.SignInWithNous);
        _signIn.Content = Busy(busy == Way.Password, SignInCopy.SignInButton);
        _cancelNous.Visibility = busy == Way.Nous ? Visibility.Visible : Visibility.Collapsed;
    }

    private static object Busy(bool on, string idle)
    {
        if (!on) return idle;
        var p = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        p.Children.Add(new ProgressRing { Width = 16, Height = 16, IsActive = true });
        p.Children.Add(new TextBlock { Text = SignInCopy.SigningIn });
        return p;
    }

    private void SubmitFromName()
    {
        if (Ways is not { } ways) return;
        if (ways == SignInWays.Nous) SignInWithNous(); else SignInWithPassword();
    }

    private void ClearProblems()
    {
        Show(_error, _errorText, null);
        Show(_notice, _noticeText, null);
        _address.BorderBrush = null;
        _password.BorderBrush = null;
    }

    public void SignInWithNous()
    {
        if (IsBusy || _windowStop.IsCancellationRequested) return;
        ClearProblems();
        var text = _address.Text.Trim();
        if (text.Length == 0)
        {
            Fail(SignInCopy.EnterAddressThen(SignInCopy.SignInWithNous), markAddress: true, markPassword: false);
            return;
        }
        _nousCancel = CancellationTokenSource.CreateLinkedTokenSource(_windowStop);
        var ct = _nousCancel.Token;
        Run(Way.Nous, async () =>
        {
            var gw = GatewayAddress.FromTyped(text);
            var s = await AppState.SignIn.NousAsync(gw, async url =>
            {
                ct.ThrowIfCancellationRequested();
                if (!await Launcher.LaunchUriAsync(url))
                    throw new GatewayException("nous-failed", "Couldn't open your web browser.");
            }, ct, _name.Text);
            if (!_windowStop.IsCancellationRequested) App.Window?.BringToFront();
            return s;
        });
    }

    public void SignInWithPassword()
    {
        if (IsBusy || _windowStop.IsCancellationRequested) return;
        ClearProblems();
        var text = _address.Text.Trim();
        var user = _username.Text.Trim();
        var secret = _password.Password;
        if (text.Length == 0 || user.Length == 0 || secret.Length == 0)
        {
            Fail(SignInCopy.Messages["missing-fields"], markAddress: text.Length == 0, markPassword: false);
            return;
        }
        // Exactly one attempt per click: the gateway allows 10 a minute.
        Run(Way.Password, () => AppState.SignIn.PasswordAsync(GatewayAddress.FromTyped(text), user, secret, _windowStop, _name.Text));
    }

    private async void Run(Way way, Func<Task<GatewaySession>> attempt)
    {
        var started = DateTimeOffset.UtcNow;
        GatewaySession? unadopted = null;
        ApplyBusy(way);
        BusyChanged?.Invoke(true);
        try
        {
            var session = unadopted = await attempt();
            if (_windowStop.IsCancellationRequested) return;
            // The form stays busy while the gateway's version is read (one capped read).
            var answer = await GatewayCompatibility.CappedAsync(ct => SignIn.CompatibilityAsync(session, ct), stop: _windowStop);
            if (_windowStop.IsCancellationRequested) return;
            _password.Password = "";
            AppLog.Note("signin", $"sign-in ({way}) ok in {(DateTimeOffset.UtcNow - started).TotalMilliseconds:0} ms"
                + (answer.Outdated != null ? ", gateway needs an update" : ""));
            ApplyBusy(null);
            BusyChanged?.Invoke(false);
            if (!_windowStop.IsCancellationRequested && SignedIn is { } take)
            {
                unadopted = null; // ownership passes to the subscriber, including its late-return disposal
                take(session, answer.Outdated is { } o ? new SignInOutcome(o) : SignInOutcome.Enter);
            }
        }
        catch (Exception e) when (!_windowStop.IsCancellationRequested || e is OperationCanceledException or ObjectDisposedException or GatewayException)
        {
            if (_windowStop.IsCancellationRequested) return; // a cancelled sign-in has no form to repaint
            ApplyBusy(null);
            BusyChanged?.Invoke(false);
            var code = SignInCopy.Code(e);
            if (code == "nous-cancelled") { AppLog.Note("signin", $"sign-in ({way}) cancelled"); return; }
            AppLog.Note("signin", $"sign-in ({way}) failed: {code}");
            if (e is not GatewayException and not OperationCanceledException) AppLog.Error("signin", e);
            Fail(SignInCopy.Messages[code], SignInCopy.MarksAddress(code), SignInCopy.MarksPassword(code));
        }
        finally { unadopted?.Dispose(); _nousCancel?.Dispose(); _nousCancel = null; }
    }

    private void Fail(string message, bool markAddress, bool markPassword)
    {
        Show(_error, _errorText, message);
        var red = Brush("SystemFillColorCriticalBrush");
        if (markAddress) { _address.BorderBrush = red; _address.Focus(FocusState.Programmatic); }
        if (markPassword) { _password.BorderBrush = red; _password.Focus(FocusState.Programmatic); }
    }
}
