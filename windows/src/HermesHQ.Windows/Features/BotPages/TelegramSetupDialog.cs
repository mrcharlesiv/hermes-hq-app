using Hermes.Core.BotPages;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;

namespace HermesHQ.Features.BotPages;

/// "Set Up with Telegram" (App/Pages/More/Messaging/TelegramSetupView.swift): Open Telegram, or the QR code for Telegram
/// on another device; waiting, connected, expired. Closing it before Finish gives the pairing back.
internal static class TelegramSetupDialog
{
    public static async Task ShowAsync(MessagingModel model)
    {
        if (!model.CanWrite) return;
        var host = model.Host;
        var setup = model.TelegramSetup();
        var profile = model.Profile;
        var body = new StackPanel { Spacing = 16, Width = 420, Padding = new Thickness(0, 8, 0, 8) };
        var dialog = new ContentDialog
        {
            Title = MessagingWords.SetUpTelegram, Content = new ScrollViewer { Content = body, MaxHeight = 620 },
            CloseButtonText = "Close",
        };
        var typedIds = new TextBox { PlaceholderText = MessagingWords.UserIdLabel, IsSpellCheckEnabled = false, InputScope = null };
        AutomationProperties.SetAutomationId(typedIds, "telegram.user-id");
        var openFailed = false;
        var tick = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        TextBlock? expires = null;
        tick.Tick += (_, _) =>
        {
            if (expires != null) expires.Text = setup.Remaining(DateTimeOffset.UtcNow) is { } left ? MessagingWords.ExpiresIn(left) : "";
        };

        void Draw()
        {
            body.Children.Clear();
            expires = null;
            switch (setup.Current)
            {
                case TelegramSetup.Phase.Idle or TelegramSetup.Phase.Starting: Busy(MessagingWords.Starting); break;
                case TelegramSetup.Phase.Applying: Busy(MessagingWords.Saving); break;
                case TelegramSetup.Phase.Waiting w: Waiting(w.Start); break;
                case TelegramSetup.Phase.Ready r: Ready(r.BotUsername, r.OwnerUserId); break;
                case TelegramSetup.Phase.Applied a: Connected(a.Result.BotUsername); break;
                case TelegramSetup.Phase.Expired:
                    Message("", MessagingWords.LinkExpired, TelegramSetup.ExpiredText, MessagingWords.StartAgain, "telegram.expired");
                    break;
                case TelegramSetup.Phase.Failed f:
                    Message("", MessagingWords.StartFailTitle, f.Reason, MessagingWords.TryAgain, "telegram.failed");
                    break;
            }
        }

        void Centered(UIElement e) { if (e is FrameworkElement f) f.HorizontalAlignment = HorizontalAlignment.Center; body.Children.Add(e); }

        TextBlock CenterText(string text, double size = 14, Brush? color = null, bool bold = false)
        {
            var t = Kit.Text(text, size, color, bold);
            t.TextAlignment = TextAlignment.Center;
            t.HorizontalAlignment = HorizontalAlignment.Stretch;
            return t;
        }

        void Busy(string text)
        {
            var s = new StackPanel { Spacing = 12, MinHeight = 200, VerticalAlignment = VerticalAlignment.Center };
            s.Children.Add(new ProgressRing { IsActive = true });
            s.Children.Add(CenterText(text, 14, Kit.Secondary));
            AutomationProperties.SetAutomationId(s, "telegram.busy");
            body.Children.Add(s);
        }

        void Waiting(TelegramSetupStart start)
        {
            body.Children.Add(CenterText(MessagingWords.WaitingIntro(start.OpenUrl != null)));
            if (start.OpenUrl is { } url)
            {
                var open = new Button { Content = MessagingWords.OpenTelegram, Style = Kit.Res<Style>("AccentButtonStyle"), HorizontalAlignment = HorizontalAlignment.Stretch };
                AutomationProperties.SetAutomationId(open, "telegram.open");
                open.Click += async (_, _) =>
                {
                    var opened = await Windows.System.Launcher.LaunchUriAsync(url);
                    if (!opened && !openFailed) { openFailed = true; Draw(); }
                };
                body.Children.Add(open);
            }
            if (openFailed) body.Children.Add(CenterText(MessagingWords.OpenFailed, 12, Kit.Red));
            if (QrCode.Encode(start.QrPayload) is { } qr)
            {
                var image = QrImage(qr, 200);
                AutomationProperties.SetName(image, MessagingWords.QrName);
                AutomationProperties.SetAutomationId(image, "telegram.qr");
                Centered(image);
                body.Children.Add(CenterText(MessagingWords.QrNote, 12, Kit.Secondary));
            }
            var wait = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center };
            wait.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
            wait.Children.Add(Kit.Text(MessagingWords.WaitingForTelegram, 14, Kit.Secondary));
            AutomationProperties.SetAutomationId(wait, "telegram.waiting");
            body.Children.Add(wait);
            expires = CenterText(setup.Remaining(DateTimeOffset.UtcNow) is { } left ? MessagingWords.ExpiresIn(left) : "", 12, Kit.Secondary);
            body.Children.Add(expires);
            if (setup.Notice is { } notice) body.Children.Add(CenterText(notice, 12, Kit.Orange));
        }

        void Connected(string? bot)
        {
            var s = new StackPanel { Spacing = 10, Margin = new Thickness(0, 24, 0, 0) };
            s.Children.Add(new FontIcon { Glyph = "", FontSize = 40, Foreground = Kit.Green });
            var t = CenterText(MessagingWords.Connected(bot), 18, bold: true);
            AutomationProperties.SetAutomationId(t, "telegram.connected");
            s.Children.Add(t);
            body.Children.Add(s);
        }

        Button? finishButton = null;
        typedIds.TextChanged += (_, _) => { if (finishButton != null) finishButton.IsEnabled = TelegramSetup.UserIds(typedIds.Text) != null; };

        void Ready(string? bot, string? owner)
        {
            Connected(bot);
            if (owner != null) body.Children.Add(CenterText(MessagingWords.OnlyYou(owner), 13, Kit.Secondary));
            else
            {
                var s = new StackPanel { Spacing = 6 };
                s.Children.Add(Kit.Text(MessagingWords.UserIdLabel, 12, Kit.Secondary));
                HermesHQ.Services.UiTree.DetachFromParent(typedIds);
                s.Children.Add(typedIds);
                s.Children.Add(Kit.Text(MessagingWords.UserIdHelp, 12, Kit.Secondary));
                body.Children.Add(s);
            }
            if (setup.Notice is { } notice)
            {
                var n = CenterText(notice, 12, Kit.Red);
                AutomationProperties.SetAutomationId(n, "telegram.notice");
                body.Children.Add(n);
            }
            var allowed = owner != null ? [owner] : TelegramSetup.UserIds(typedIds.Text);
            var finish = new Button { Content = MessagingWords.Finish, Style = Kit.Res<Style>("AccentButtonStyle"), HorizontalAlignment = HorizontalAlignment.Stretch,
                IsEnabled = allowed != null };
            AutomationProperties.SetAutomationId(finish, "telegram.finish");
            finish.Click += (_, _) => { if ((owner != null ? [owner] : TelegramSetup.UserIds(typedIds.Text)) is { } ids) setup.Finish(ids); };
            finishButton = owner == null ? finish : null;
            body.Children.Add(finish);
        }

        void Message(string glyph, string title, string text, string button, string id)
        {
            var s = new StackPanel { Spacing = 14, Margin = new Thickness(0, 24, 0, 0) };
            s.Children.Add(new FontIcon { Glyph = glyph, FontSize = 36, Foreground = Kit.Tertiary });
            s.Children.Add(CenterText(title, 18, bold: true));
            s.Children.Add(CenterText(text, 14, Kit.Secondary));
            var b = new Button { Content = button, Style = Kit.Res<Style>("AccentButtonStyle"), HorizontalAlignment = HorizontalAlignment.Stretch };
            AutomationProperties.SetAutomationId(b, "telegram.restart");
            b.Click += (_, _) => setup.Start();
            s.Children.Add(b);
            AutomationProperties.SetAutomationId(s, id);
            body.Children.Add(s);
        }

        setup.Changed += () => host.Ui(Draw);
        setup.AppliedEvent += applied => host.Ui(() =>
        {
            dialog.Hide();
            model.TelegramApplied(applied, profile);
        });
        Draw();
        tick.Start();
        setup.Start();
        await Kit.Show(host.XamlRoot, dialog);
        tick.Stop();
        // Closed (Close or Esc): before Finish the pairing is given back.
        setup.Close();
    }

    /// The code drawn black on white, a quiet zone of 4 modules, sharp at `side` pixels.
    private static FrameworkElement QrImage(QrCode qr, double side)
    {
        var quiet = 4;
        var n = qr.Size + quiet * 2;
        var cell = side / n;
        var canvas = new Canvas { Width = side, Height = side, Background = new SolidColorBrush(Colors.White) };
        var black = new SolidColorBrush(Colors.Black);
        for (var y = 0; y < qr.Size; y++)
            for (var x = 0; x < qr.Size; x++)
            {
                if (!qr[x, y]) continue;
                var r = new Rectangle { Width = cell + 0.25, Height = cell + 0.25, Fill = black };
                Canvas.SetLeft(r, (x + quiet) * cell);
                Canvas.SetTop(r, (y + quiet) * cell);
                canvas.Children.Add(r);
            }
        return new Border { Child = canvas, Padding = new Thickness(12), CornerRadius = new CornerRadius(16), Background = new SolidColorBrush(Colors.White) };
    }
}
