using Hermes.Core.BotPages;
using Hermes.Core.Heads;
using HermesHQ.Controls;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Features.BotPages;

/// New Bot (App/Bots/NewBotViewController.swift): Name, Display Name, Description; Create makes the profile
/// (`profiles.create` with the SOUL it is born with), checks it can run, then opens its chat. Opened by
/// Navigator.Open("profiles", "new") (the Bots list's New Bot, More search's New Bot action).
internal static class NewBotDialog
{
    private static bool _open;

    public static async Task ShowAsync(PageHost host)
    {
        if (_open || host.Gateway is not { } gw || host.Client is not { } client) return;
        _open = true;
        try { await Run(host, gw, client); }
        finally { _open = false; }
    }

    private static async Task Run(PageHost host, IPagesGateway gw, Hermes.Core.HermesClient client)
    {
        var bots = client.Bots ?? [];
        var name = new TextBox { PlaceholderText = NewBotWords.NamePlaceholder, IsSpellCheckEnabled = false, IsTextPredictionEnabled = false };
        var title = new TextBox { PlaceholderText = NewBotWords.TitlePlaceholder };
        var description = new TextBox { PlaceholderText = NewBotWords.DescriptionPlaceholder, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap,
            MinHeight = 72, MaxHeight = 180 };
        AutomationProperties.SetAutomationId(name, "new-bot.name");
        AutomationProperties.SetAutomationId(title, "new-bot.title");
        AutomationProperties.SetAutomationId(description, "new-bot.description");
        var inline = Kit.Text("", 12, Kit.Red);
        inline.Visibility = Visibility.Collapsed;
        var head = new ContentControl { IsTabStop = false, Width = 72, Height = 72, HorizontalAlignment = HorizontalAlignment.Center };

        var form = new StackPanel { Spacing = 4, Width = 420 };
        var intro = Kit.Text(NewBotWords.Intro, 13, Kit.Secondary);
        intro.TextAlignment = TextAlignment.Center;
        form.Children.Add(intro);
        form.Children.Add(head);
        var note = Kit.Text(NewBotWords.ShapeNote, 12, Kit.Secondary);
        note.TextAlignment = TextAlignment.Center;
        form.Children.Add(note);
        form.Children.Add(Kit.SectionLabel(NewBotWords.NameHeader));
        form.Children.Add(name);
        form.Children.Add(inline);
        form.Children.Add(Kit.Footer(NewBotWords.NameFooter));
        form.Children.Add(Kit.SectionLabel(NewBotWords.TitleHeader));
        form.Children.Add(title);
        form.Children.Add(Kit.Footer(NewBotWords.TitleFooter));
        form.Children.Add(Kit.SectionLabel(NewBotWords.DescriptionHeader));
        form.Children.Add(description);

        var dialog = new ContentDialog
        {
            Title = NewBotWords.Title, Content = new ScrollViewer { Content = form, MaxHeight = 560 },
            PrimaryButtonText = NewBotWords.Create, CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary,
        };
        string? inlineError = null;
        var creating = false;

        void Refresh()
        {
            var (slug, _) = BotIdentity.ProfileIdentity(name.Text, title.Text);
            var valid = BotIdentity.IsValidProfileId(slug);
            var taken = valid && bots.Any(b => b.Name == slug);
            inline.Text = taken ? NewBotWords.Taken(slug) : inlineError ?? "";
            inline.Visibility = inline.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
            dialog.IsPrimaryButtonEnabled = valid && !taken && !creating;
            dialog.PrimaryButtonText = creating ? NewBotWords.Creating : NewBotWords.Create;
            // The bot gets a shape from its name.
            head.Content = new BotHead
            {
                Bot = new Hermes.Core.Model.Bot(slug.Length == 0 ? "new-bot" : slug, BotIdentity.DisplayName(slug, title.Text), null, null,
                    false, false, false, null, false, null, null),
                DisplayName = BotIdentity.DisplayName(slug.Length == 0 ? "new-bot" : slug, title.Text), Width = 72, Height = 72,
            };
        }
        name.TextChanged += (_, _) => { inlineError = null; Refresh(); };
        title.TextChanged += (_, _) => Refresh();
        name.Loaded += (_, _) => name.Focus(FocusState.Programmatic);
        Refresh();

        NewBotResult? made = null;
        dialog.PrimaryButtonClick += async (d, e) =>
        {
            var deferral = e.GetDeferral();
            e.Cancel = true;
            creating = true;
            inlineError = null;
            name.IsEnabled = title.IsEnabled = description.IsEnabled = false;
            Refresh();
            try
            {
                var teammates = bots.Select(b => (b.Name, b.Description)).ToList();
                made = await new NewBotApi(gw).CreateAsync(name.Text, title.Text, description.Text, teammates);
                e.Cancel = false;
            }
            catch (NewBotInlineException x) { inlineError = x.Message; }
            catch (Exception x)
            {
                var (failTitle, reason) = x is BotWriteException w ? (w.Title, w.Message)
                    : (NewBotWords.FailTitle(BotIdentity.DisplayName(BotIdentity.ProfileIdentity(name.Text, title.Text).Slug, title.Text)), PagesRest.Reason(x));
                creating = false;
                deferral.Complete();
                d.Hide();
                await Kit.Failure(host.XamlRoot, failTitle, reason);
                return;
            }
            finally
            {
                creating = false;
                name.IsEnabled = title.IsEnabled = description.IsEnabled = true;
                Refresh();
            }
            deferral.Complete();
        };
        // Nothing closes the sheet while Create is on its way.
        dialog.Closing += (_, e) => { if (creating && e.Result != ContentDialogResult.Primary) e.Cancel = true; };
        await Kit.Show(host.XamlRoot, dialog);
        if (made is not { } result) return;
        AppLog.Note("bots", "new bot created");
        // The chat opens from the roster, read again with the new bot in it.
        try
        {
            var fresh = await client.BotsAsync();
            if (fresh.FirstOrDefault(b => b.Name == result.Slug) is { } bot) host.Ui(() => Navigator.Go(new BotChatDestination(bot)));
        }
        catch (Exception x) { AppLog.Error("bots", x); }
        if (host.Top is ProfilesList list) await list.Read();
    }
}
