using Hermes.Core.Shell;
using HermesHQ.Features.Composer;
using HermesHQ.Pages;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Services;

/// [WIN-45] The Models sheet's rows (ModelsDialog; the Mac's ModelSheetViewController ModelRowCell), checked inside the
/// transcript-extras walk (ProofWalks.Transcript.cs): every model row shows its name in a drawn brush, the row marked
/// current is the model the composer's pill reads. CI run 44997803358 drew the rows blank. Checked twice: on the sheet
/// Choose a Model opened, and again on the sheet the composer's model pill opens (shot models-sheet-rows).
internal static partial class ProofWalks
{
    /// The open Models sheet's rows read their names; `how` says how the sheet was opened, for the error.
    private static async Task ModelsSheetRowsAsync(ContentDialog sheet, ChatPage chat, string how)
    {
        // The catalog loads after the sheet opens: wait for its rows.
        await Until(() => RowNames(sheet).Count > 0 ? sheet : null, $"the Models sheet's rows ({how})", 20);
        var rows = ModelRows(sheet);
        var names = rows.Select(r => r.Name).ToList();
        var shown = rows.Select(r => (r.Words.Text ?? "", Inked(r.Words))).ToList();
        if (ModelsSheetWalkProof.RowsRead([.. names.Select(ModelsSheetWalkProof.Shown)], shown) is { } rowsWrong)
            throw new InvalidOperationException($"{how}: {rowsWrong}");
        var pill = Shown(chat).OfType<Button>().FirstOrDefault(b => AutomationProperties.GetName(b) == "Model");
        var pillText = pill == null ? null : Shown(pill).OfType<TextBlock>().FirstOrDefault()?.Text;
        // Favorites repeat a model above its provider; the current mark is read from the provider sections' rows.
        if (ModelsSheetWalkProof.CurrentMatchesPill(pillText, [.. names.Distinct()]) is { } currentWrong)
            throw new InvalidOperationException($"{how}: {currentWrong}");
        ThinkingStepsFoot(sheet, how);
        AppLog.Note("automation", $"walk transcript-extras: the Models sheet ({how}) shows {rows.Count} named rows");
    }

    /// The composer's model pill opens the same sheet; its rows read their names too.
    private static async Task ModelsSheetFromPillAsync(ChatPage chat, Func<string, Task> shot)
    {
        var pill = (Button)await Until(() => Shown(chat).OfType<Button>().FirstOrDefault(b => AutomationProperties.GetName(b) == "Model"),
            "the composer's model pill");
        try { Mouse.Click(pill); }
        catch (InvalidOperationException e) { AppLog.Note("automation", $"walk transcript-extras: the model pill wasn't clicked ({e.Message}); invoking it"); }
        var shownBy = DateTime.UtcNow.AddSeconds(10);
        while (ModelsSheet() == null && DateTime.UtcNow < shownBy) await Task.Delay(100);
        if (ModelsSheet() == null)
        {
            AppLog.Note("automation", "walk transcript-extras: the click didn't open the Models sheet; invoking the model pill");
            Invoke(pill);
        }
        var sheet = await Until(ModelsSheet, "the Models sheet from the model pill");
        await ModelsSheetRowsAsync(sheet, chat, "the model pill");
        await Task.Delay(500);   // the sheet's entrance settles before the picture
        await shot("models-sheet-rows");
        sheet.Hide();
        await Until(() => ModelsSheet() == null ? chat : null, "the Models sheet to close");
    }

    private static List<(string Name, TextBlock Words)> ModelRows(ContentDialog sheet) =>
    [
        .. Shown(sheet).OfType<Button>()
            .Select(b => (Name: AutomationProperties.GetName(b) ?? "", Words: Shown(b).OfType<TextBlock>().FirstOrDefault(t => Id(t) == ModelsDialog.RowNameId)))
            .Where(r => r.Words != null)
            .Select(r => (r.Name, r.Words!)),
    ];

    private static List<string> RowNames(ContentDialog sheet) => [.. ModelRows(sheet).Select(r => r.Name)];

    /// A TextBlock's words draw when it has a brush that isn't clear (a null Foreground draws nothing).
    private static bool Inked(TextBlock t) => t.Foreground is SolidColorBrush { Color.A: > 0 };
}
