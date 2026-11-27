using Hermes.Core;
using Hermes.Core.Shell;
using Hermes.Core.Transcripts;
using HermesHQ.Pages;
using HermesHQ.Shell;
using HermesHQ.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Services;

/// [WIN-36] The CI's walk for the transcript's extras (windows/ci/windows.yml asks for it on the composer stand-in), on
/// the stand-in's “Release review” chat (composer-gateway.py `EXTRAS`), backed by the app's state and the stand-in's
/// own record (`Hermes.Core.Shell.WalkProof`):
///   transcript-extras  The chat's link chip shows the title of the page the stand-in served on loopback (the walk points
///                      the link reader at the stand-in first: LinkPreviewFetcher.LoopbackStandIn); the model-change note,
///                      the job's byline, “2 files changed” and the table's “3 rows · 7 columns” footer are on screen.
///                      A click on Expand opens the Table sheet (Table; Copy as Text, Done) and Esc closes it. A send
///                      fails with a usage limit: its card reads Usage limit reached with Choose a Model and Copy Details,
///                      and a click on Choose a Model opens the composer's Models sheet. A send the stand-in refuses shows
///                      “Couldn’t Send” with its reason. The stand-in took exactly those two sends.
/// Keys and clicks go in by SendInput; where they don't arrive, the walk does what they do and says so in the app log.
internal static partial class ProofWalks
{
    private static void RegisterTranscriptWalks()
    {
        Automation.NamedWalks["transcript-extras"] = TranscriptExtrasAsync;
    }

    private static async Task TranscriptExtrasAsync(Func<string, Task> shot)
    {
        var client = AppState.Client ?? throw new InvalidOperationException("not signed in");
        var url = client.Session.Address.ToString();
        LinkPreviews.ReplaceShared(new LinkPreviews(LinkPreviewFetcher.LoopbackStandIn(new Uri(url))));
        try { await ExtrasWalkAsync(shot, url); }
        finally { LinkPreviews.ReplaceShared(null); }
    }

    private static async Task ExtrasWalkAsync(Func<string, Task> shot, string url)
    {
        Navigator.Go(new ChatDestination(WalkProof.ExtrasBot, WalkProof.ExtrasStoredId, WalkProof.ExtrasTitle));
        var chat = await Until(() => ChatPage.Current is { IsLoaded: true } p && p.StoredId == WalkProof.ExtrasStoredId && p.MessageCount >= 6 ? p : null,
            "Release review's messages");
        var list = await Until(() => Shown(chat).OfType<ListView>().FirstOrDefault(), "the transcript");
        List<MessageItem> Items() => (list.ItemsSource as IEnumerable<object>)?.OfType<MessageItem>().ToList() ?? [];
        var botName = Items().First().Display.Context.BotName;

        // Every message brought on screen in turn (the transcript only draws what it shows), its words collected.
        var seen = new HashSet<string>();
        async Task ShowAsync(MessageItem item)
        {
            list.ScrollIntoView(item, ScrollIntoViewAlignment.Leading);
            await Task.Delay(400);
            foreach (var t in Shown(list).OfType<TextBlock>()) if (t.Text is { Length: > 0 } words) seen.Add(words);
        }
        foreach (var item in Items()) await ShowAsync(item);
        if (WalkProof.ExtrasShown(seen, botName) is { } missing) throw new InvalidOperationException(missing);

        // The link chip: the title the stand-in served.
        var linkItem = Items().FirstOrDefault(i => i.Message.Text.Contains(WalkProof.ExtrasLink, StringComparison.Ordinal))
            ?? throw new InvalidOperationException("no reply holds the link");
        await ShowAsync(linkItem);
        var expected = LinkChips.Face(WalkProof.ExtrasLink, new Uri(WalkProof.ExtrasLink), new LinkPreview(WalkProof.ExtrasLinkTitle, null)).AccessibleName;
        var chip = await Until(() => Shown(list).FirstOrDefault(e => Id(e) == LinkChips.AutomationId && AutomationProperties.GetName(e) == expected),
            "the link chip's fetched title", 20);
        if (WalkProof.ChipShowsFetched(AutomationProperties.GetName(chip), await StandIn(url, "/__extras/state")) is { } chipWrong)
            throw new InvalidOperationException(chipWrong);
        await shot("transcript-extras-chip");

        // The table's Expand: the Table sheet; Esc closes it.
        var tableItem = Items().FirstOrDefault(i => i.Message.Text.Contains("| Build | Platform |", StringComparison.Ordinal))
            ?? throw new InvalidOperationException("no reply holds the table");
        await ShowAsync(tableItem);
        var expand = (Button)await Until(() => Shown(list).FirstOrDefault(e => Id(e) == TableText.ExpandId), "the table's Expand");
        if (AutomationProperties.GetName(expand) != TableText.ExpandName) throw new InvalidOperationException($"Expand is named {AutomationProperties.GetName(expand)}");
        try { Mouse.Click(expand); }
        catch (InvalidOperationException e) { AppLog.Note("automation", $"walk transcript-extras: Expand wasn't clicked ({e.Message}); invoking it"); }
        var shownBy = DateTime.UtcNow.AddSeconds(10);
        while (TableSheet() == null && DateTime.UtcNow < shownBy) await Task.Delay(100);
        if (TableSheet() == null)
        {
            AppLog.Note("automation", "walk transcript-extras: the click didn't open the Table sheet; invoking Expand");
            Invoke(expand);
        }
        else AppLog.Note("automation", "walk transcript-extras: the Table sheet open by pointer");
        var sheet = await Until(TableSheet, "the Table sheet");
        if (WalkProof.TableSheetReads(sheet.Title as string, [sheet.PrimaryButtonText, sheet.CloseButtonText]) is { } sheetWrong)
            throw new InvalidOperationException(sheetWrong);
        await Task.Delay(500);   // the sheet's entrance settles before the picture
        await shot("transcript-extras-table");
        if (!await KeysAsync(() => Keys.Press(Keys.Escape), () => TableSheet() == null, "Esc on the Table sheet"))
        {
            AppLog.Note("automation", "walk transcript-extras: Esc unproven by keyboard; closing the sheet as Esc does");
            sheet.Hide();
        }
        await Until(() => TableSheet() == null ? chat : null, "the Table sheet to close");

        // A send that fails with a usage limit: its card offers Choose a Model, which opens the composer's Models sheet.
        await Until(() => !chat.IsBusy ? chat : null, "the chat to be idle");
        var mark = WalkProof.ExtrasSendCount(await StandIn(url, "/__extras/state"));
        chat.AutomationSend(WalkProof.ExtrasLimitWords);
        var card = await Until(() => Shown(list).LastOrDefault(e => Id(e) == "chat.error-card"), "the usage limit's card", 20);
        var cardTitle = Shown(card).OfType<TextBlock>().FirstOrDefault(t => Id(t) == "chat.error.title")?.Text;
        var cardButtons = Shown(card).OfType<Button>().Select(b => b.Content as string ?? "").ToList();
        if (WalkProof.LimitCardReads(cardTitle, cardButtons) is { } cardWrong) throw new InvalidOperationException(cardWrong);
        var choose = (Button)Shown(card).First(e => Id(e) == "chat.error.choose-model");
        try { Mouse.Click(choose); }
        catch (InvalidOperationException e) { AppLog.Note("automation", $"walk transcript-extras: Choose a Model wasn't clicked ({e.Message}); invoking it"); }
        shownBy = DateTime.UtcNow.AddSeconds(10);
        while (ModelsSheet() == null && DateTime.UtcNow < shownBy) await Task.Delay(100);
        if (ModelsSheet() == null)
        {
            AppLog.Note("automation", "walk transcript-extras: the click didn't open the Models sheet; invoking Choose a Model");
            Invoke(choose);
        }
        else AppLog.Note("automation", "walk transcript-extras: Choose a Model clicked by pointer");
        var models = await Until(ModelsSheet, "the Models sheet");
        if (WalkProof.ModelsSheetOpened([.. OpenDialogs().Select(d => d.Title as string ?? "")]) is { } modelsWrong)
            throw new InvalidOperationException(modelsWrong);
        await ModelsSheetRowsAsync(models, chat, "Choose a Model");   // [WIN-45] ProofWalks.ModelsSheet.cs
        await Task.Delay(500);
        await shot("transcript-extras-models");
        models.Hide();
        await Until(() => ModelsSheet() == null ? chat : null, "the Models sheet to close");
        await ModelsSheetFromPillAsync(chat, shot);

        // A send the stand-in refuses: “Couldn’t Send” with its reason.
        await Until(() => !chat.IsBusy ? chat : null, "the chat to be idle again");
        chat.AutomationSend(WalkProof.ExtrasRefused);
        var failure = await Until(() => Find(Hermes.Core.Chat.ComposerNotices.SendFailureId), "the Couldn’t Send card", 20);
        var failureTitle = Shown(failure).OfType<TextBlock>().FirstOrDefault(t => Id(t) == Hermes.Core.Chat.ComposerNotices.Part(Hermes.Core.Chat.ComposerNotices.SendFailureId, Hermes.Core.Chat.ComposerNotices.TitlePart))?.Text;
        var failureBody = Shown(failure).OfType<TextBlock>().FirstOrDefault(t => Id(t) == Hermes.Core.Chat.ComposerNotices.Part(Hermes.Core.Chat.ComposerNotices.SendFailureId, Hermes.Core.Chat.ComposerNotices.BodyPart))?.Text;
        if (WalkProof.CouldntSendReads(failureTitle, failureBody) is { } failureWrong) throw new InvalidOperationException(failureWrong);
        await Task.Delay(1000);   // anything else the sends might do has reached the stand-in
        if (WalkProof.ExtrasSent(await StandIn(url, "/__extras/state"), mark, [WalkProof.ExtrasLimitWords, WalkProof.ExtrasRefused]) is { } sentWrong)
            throw new InvalidOperationException(sentWrong);
        list.ScrollIntoView(Items()[^1], ScrollIntoViewAlignment.Leading);
        await Task.Delay(400);
        await shot("transcript-extras");
    }

    private static IEnumerable<ContentDialog> OpenDialogs() => InPopups().OfType<ContentDialog>();

    private static ContentDialog? TableSheet() => OpenDialogs().FirstOrDefault(d => Id(d) == TableText.SheetId);

    private static ContentDialog? ModelsSheet() => OpenDialogs().FirstOrDefault(d => d.Title as string == "Models");
}
