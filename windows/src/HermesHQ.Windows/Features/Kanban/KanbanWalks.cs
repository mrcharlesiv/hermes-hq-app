using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Windows.System;

namespace HermesHQ.Features.Kanban;

/// The CI's pictures of the board picker (Services/Automation.cs named walks; windows/ci/windows.yml starts
/// ci/fixtures/pages-fixture-gateway.py with --many-boards 8, 9 and 13 for them). Everything is driven the way UI
/// Automation sees it, by the ids KanbanPage sets: `kanban.board` is invoked; with 8 boards a menu of
/// `kanban.boards.menu.<slug>` opens and no `kanban.boards` page appears; with 9 the `kanban.boards` list shows
/// (`kanban.boards.row.<slug>`, `kanban.boards.back`) without `kanban.boards.search`; with 13 the search is there and
/// filters. A state that isn't so throws, which fails the walk (KanbanViewController.swift configureBoardButton,
/// showBoardList, KanbanBoardListController).
internal static class KanbanWalks
{
    private const string Row = "kanban.boards.row.";

    public static void Register()
    {
        Automation.NamedWalks["kanban-boards-menu"] = MenuAsync;
        Automation.NamedWalks["kanban-boards-list"] = ListAsync;
        Automation.NamedWalks["kanban-boards-search"] = SearchAsync;
        Automation.NamedWalks["kanban-task-markdown"] = TaskMarkdownAsync;
    }

    // ------------------------------------------------------------------ the walks

    /// Eight boards: the board button's pop-up menu, every board in it, a tick on the open one; no Boards page.
    private static async Task MenuAsync(Func<string, Task> shot)
    {
        var button = await OpenBoardAsync();
        Invoke(button);
        var items = await Until(() =>
        {
            var found = InPopups().OfType<ToggleMenuFlyoutItem>().Where(i => Id(i).StartsWith("kanban.boards.menu.", StringComparison.Ordinal)).ToList();
            return found.Count > 0 ? found : null;
        }, "the boards menu", allowFlyoutNudge: button);
        if (items.Count != 8) throw new InvalidOperationException($"the boards menu lists {items.Count} boards, not 8");
        // The Mac ticks the open board with a ✓ (UIMenu .singleSelection, state .on); a radio item would draw a bullet.
        if (InPopups().OfType<RadioMenuFlyoutItem>().FirstOrDefault(i => Id(i).StartsWith("kanban.boards.menu.", StringComparison.Ordinal)) is { } radio)
            throw new InvalidOperationException($"{Id(radio)} is a radio item, not a ✓");
        if (Find("kanban.boards") != null) throw new InvalidOperationException("8 boards pushed the Boards list");
        var ticked = items.Where(i => i.IsChecked).Select(i => Id(i)).ToList();
        if (ticked is not ["kanban.boards.menu.release-2-4"]) throw new InvalidOperationException($"ticked: {string.Join(", ", ticked)}");
        await shot("kanban-boards-menu");
        button.Flyout?.Hide();
        await Until(() => InPopups().OfType<ToggleMenuFlyoutItem>().Any() ? null : button, "the menu to close");
    }

    /// Nine boards: the pushed Boards list, no search; a pick switches the board and comes back; Back leaves it as is.
    private static async Task ListAsync(Func<string, Task> shot)
    {
        var button = await OpenBoardAsync();
        var rows = await OpenListAsync(button, 9);
        if (Find("kanban.boards.search") != null) throw new InvalidOperationException("9 boards show a search field");
        await shot("kanban-boards-list");

        // A pick: the list goes, the board button names the new board.
        Invoke(rows.Single(r => Id(r) == Row + "bakery-orders"));
        await Until(() => Find("kanban.boards") == null && Title(button) == "Bakery Orders" ? button : null, "Bakery Orders to open");
        await shot("kanban-boards-picked");

        // Back leaves the board as it was; then the open board again from the list, which does nothing but go back.
        rows = await OpenListAsync(button, 9, current: "bakery-orders");
        Invoke(Need("kanban.boards.back"));
        await Until(() => Find("kanban.boards") == null ? button : null, "Back to close the list");
        if (Title(button) != "Bakery Orders") throw new InvalidOperationException("Back changed the board");

        // Esc and Alt+Left close the list the same way as Back (the Mac pops its pushed list, showBoardList; KanbanPage.cs
        // wires both keys to CloseBoardList): the page's own accelerators run inside the app, no key sent through the OS; the board stays as it was.
        foreach (var (key, mods, label) in new[] { (VirtualKey.Escape, VirtualKeyModifiers.None, "Escape"), (VirtualKey.Left, VirtualKeyModifiers.Menu, "Alt+Left") })
        {
            await OpenListAsync(button, 9, current: "bakery-orders");
            var page = Shown(Root).OfType<KanbanPage>().FirstOrDefault() ?? throw new InvalidOperationException("no Kanban page");
            AppLog.Note("automation", $"walk keys: {label} on Boards");
            if (!page.PressForWalk(key, mods)) throw new InvalidOperationException($"the Kanban page has no {label} accelerator");
            await Until(() => Find("kanban.boards") == null ? button : null, $"{label} to close the list");
            if (Title(button) != "Bakery Orders") throw new InvalidOperationException($"{label} changed the board");
        }
        rows = await OpenListAsync(button, 9, current: "bakery-orders");
        Invoke(rows.Single(r => Id(r) == Row + "release-2-4"));
        await Until(() => Find("kanban.boards") == null && Title(button) == "Release 2.4" ? button : null, "Release 2.4 to open again");
    }

    /// Thirteen boards: the list with its search; "plan" leaves Launch Plan and Trip Planning.
    private static async Task SearchAsync(Func<string, Task> shot)
    {
        var button = await OpenBoardAsync();
        await OpenListAsync(button, 13);
        var search = (TextBox)Need("kanban.boards.search");
        search.Text = "plan";
        var rows = await Until(() =>
        {
            var shown = Rows();
            return shown.Count == 2 ? shown : null;
        }, "the search to leave two boards");
        var slugs = rows.Select(r => Id(r)[Row.Length..]).ToList();
        if (slugs is not ["launch-plan", "trip-planning"]) throw new InvalidOperationException($"the search left {string.Join(", ", slugs)}");
        await shot("kanban-boards-search");
        Invoke(Need("kanban.boards.back"));
        await Until(() => Find("kanban.boards") == null ? button : null, "Back to close the list");
    }

    /// [WIN-08] A task's text as Markdown (KanbanTaskSheet.swift FoldedMarkdown → PagesMarkdown), on the pages stand-in's
    /// Release 2.4 board. "Draft the launch thread": its description draws a heading, a bulleted and a numbered list, a
    /// monospaced `sh` code card, a web link and two plain lines that stay two lines; Edit shows the raw Markdown.
    /// "Approve the 2.4 release notes": a bold "yes" (not "**yes**") and its two comments through the same renderer.
    /// "Summarize the open-planning paper": its Result through it too. Anything else throws.
    private static async Task TaskMarkdownAsync(Func<string, Task> shot)
    {
        await OpenBoardAsync();

        // The launch thread's description.
        var description = await OpenTaskTextAsync("Draft the launch thread", "kanban.task.text.description");
        var paras = Paragraphs(description);
        var heading = paras.FirstOrDefault(p => Text(p).Trim() == "Launch thread")
            ?? throw new InvalidOperationException("no \"Launch thread\" heading paragraph");
        if (heading.FontWeight.Weight < FontWeights.SemiBold.Weight || heading.FontSize < 16)
            throw new InvalidOperationException($"the heading isn't a heading: weight {heading.FontWeight.Weight}, size {heading.FontSize}");
        if (paras.Any(p => Text(p).Contains("## ", StringComparison.Ordinal))) throw new InvalidOperationException("\"## \" drawn as words");
        if (!paras.Any(p => Text(p).StartsWith("•  the export menu", StringComparison.Ordinal))
            || !paras.Any(p => Text(p).StartsWith("•  the new shortcuts", StringComparison.Ordinal)))
            throw new InvalidOperationException("the bulleted list items aren't there: " + Dump(paras));
        if (!paras.Any(p => Text(p).StartsWith("1. style guide", StringComparison.Ordinal)))
            throw new InvalidOperationException("the numbered list item isn't there: " + Dump(paras));
        if (!Inlines(paras).OfType<Bold>().Any(b => SpanText(b) == "short")) throw new InvalidOperationException("\"short\" isn't bold");
        if (!Inlines(paras).OfType<Italic>().Any(i => SpanText(i) == "friendly")) throw new InvalidOperationException("\"friendly\" isn't italic");
        var link = Inlines(paras).OfType<Hyperlink>().FirstOrDefault(h => SpanText(h) == "style guide")
            ?? throw new InvalidOperationException("no \"style guide\" link");
        if (link.NavigateUri?.AbsoluteUri != "https://example.com/style")
            throw new InvalidOperationException($"the link goes to {link.NavigateUri?.AbsoluteUri ?? "nothing"}");
        var code = Shown(description).OfType<TextBlock>().FirstOrDefault(t => t.Text == "make thread-preview")
            ?? throw new InvalidOperationException("no code card with make thread-preview");
        if (!(code.FontFamily?.Source ?? "").Equals(((FontFamily)Application.Current.Resources["CodeFont"]).Source, StringComparison.Ordinal))
            throw new InvalidOperationException($"the code card's font is {code.FontFamily?.Source}");
        if (!paras.Any(p => Text(p).Contains("Plain line one\nPlain line two", StringComparison.Ordinal)))
            throw new InvalidOperationException("the plain lines aren't two lines: " + Dump(paras));
        if (paras.Any(p => Text(p).Contains("Plain line one Plain line two", StringComparison.Ordinal)))
            throw new InvalidOperationException("the plain lines were joined with a space");
        AppLog.Note("automation", $"kanban-task-markdown: description {paras.Count} paragraphs, link {link.NavigateUri}, code font {code.FontFamily?.Source}");
        await shot("kanban-task-markdown");

        // Edit shows the raw text.
        Invoke(Need("kanban.task.edit"));
        var box = await Until(() => Find("kanban.task.body") as TextBox, "the description editor");
        if (!box.Text.StartsWith("## Launch thread", StringComparison.Ordinal) || !box.Text.Contains("**short**", StringComparison.Ordinal)
            || !box.Text.Contains("```sh", StringComparison.Ordinal))
            throw new InvalidOperationException("the editor doesn't hold the raw Markdown");
        await shot("kanban-task-markdown-edit");
        Invoke(Need("kanban.task.cancel"));
        await Until(() => Find("kanban.task.body") == null ? Find("kanban.task.text.description") : null, "Cancel to close the editor");

        // A bold "yes" and the two comments.
        var notes = await OpenTaskTextAsync("Approve the 2.4 release notes", "kanban.task.text.description");
        var noteParas = Paragraphs(notes);
        if (!Inlines(noteParas).OfType<Bold>().Any(b => SpanText(b) == "yes")) throw new InvalidOperationException("\"yes\" isn't bold: " + Dump(noteParas));
        if (noteParas.Any(p => Text(p).Contains("**", StringComparison.Ordinal))) throw new InvalidOperationException("\"**\" drawn as words");
        var comments = await Until(() =>
        {
            var found = Shown(Root).Where(e => Id(e) == "kanban.task.text.comment").ToList();
            return found.Count > 0 ? found : null;
        }, "the comments");
        if (comments.Count != 2) throw new InvalidOperationException($"{comments.Count} comments drawn, not 2");
        if (comments.Any(c => !Paragraphs(c).Any(p => Text(p).Contains("Want the export section first", StringComparison.Ordinal))))
            throw new InvalidOperationException("a comment isn't drawn by the Markdown renderer");
        await shot("kanban-task-markdown-comments");

        // The Result.
        var result = await OpenTaskTextAsync("Summarize the open-planning paper", "kanban.task.text.result");
        if (!Paragraphs(result).Any(p => Text(p).Contains("One page, three takeaways", StringComparison.Ordinal)))
            throw new InvalidOperationException("the Result isn't drawn by the Markdown renderer");
        await shot("kanban-task-markdown-result");
    }

    /// Opens a stand-in task by its title (the stand-in's id: t_ + the first 8 hex of the title's SHA-256) the way a click
    /// on its card does (KanbanPage's card Tapped → OpenTask; a Border has no Invoke pattern), and waits for its panel
    /// to show `textId` under that title.
    private static async Task<FrameworkElement> OpenTaskTextAsync(string title, string textId)
    {
        var id = "t_" + Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(title)))[..8].ToLowerInvariant();
        var page = await Until(() => Shown(Root).OfType<KanbanPage>().FirstOrDefault(), "the Kanban page");
        AppLog.Note("automation", $"kanban-task-markdown: {(Find("kanban-task-" + id) != null ? "card shown" : "card off screen")} for {id}");
        page.OpenTask(id);
        return await Until(() =>
            Find("kanban.task.title") is TextBlock { Text: var t } && t == title && Find(textId) is { } text && Paragraphs(text).Count > 0 ? text : null,
            $"{title}: {textId}");
    }

    private static List<Paragraph> Paragraphs(DependencyObject node) =>
        [.. Shown(node).OfType<RichTextBlock>().SelectMany(r => r.Blocks.OfType<Paragraph>())];

    private static IEnumerable<Inline> Inlines(IEnumerable<Paragraph> paras) => paras.SelectMany(p => Flatten(p.Inlines));

    private static IEnumerable<Inline> Flatten(InlineCollection inlines)
    {
        foreach (var i in inlines)
        {
            yield return i;
            if (i is Span s) foreach (var c in Flatten(s.Inlines)) yield return c;
        }
    }

    /// A paragraph's words as drawn: runs as they are, a line break as "\n".
    private static string Text(Paragraph p) => Words(p.Inlines);

    private static string SpanText(Span s) => Words(s.Inlines);

    private static string Words(InlineCollection inlines) => string.Concat(inlines.Select(i => i switch
    {
        Run r => r.Text,
        LineBreak => "\n",
        Span s => Words(s.Inlines),
        _ => "",
    }));

    private static string Dump(IEnumerable<Paragraph> paras) => string.Join(" | ", paras.Select(p => Text(p).Replace("\n", "\\n")));

    // ------------------------------------------------------------------ helpers

    /// Kanban open with its boards read (the board button enabled and named).
    private static async Task<DropDownButton> OpenBoardAsync()
    {
        Navigator.Open("kanban");
        return await Until(() => Find("kanban.board") is DropDownButton { IsEnabled: true } b && Title(b) is { Length: > 0 } ? b : null,
            "the board button");
    }

    private static async Task<List<FrameworkElement>> OpenListAsync(DropDownButton button, int count, string current = "release-2-4")
    {
        Invoke(button);
        var rows = await Until(() =>
        {
            if (Find("kanban.boards") == null) return null;
            var shown = Rows();
            return shown.Count > 0 ? shown : null;
        }, "the Boards list");
        if (rows.Count != count) throw new InvalidOperationException($"the Boards list shows {rows.Count} boards, not {count}");
        var ticked = rows.Where(r => AutomationProperties.GetItemStatus(r) == "Selected").Select(r => Id(r)[Row.Length..]).ToList();
        if (ticked.Count != 1 || ticked[0] != current) throw new InvalidOperationException($"ticked: {string.Join(", ", ticked)}");
        return rows;
    }

    private static string? Title(ContentControl b) => b.Content as string;

    private static string Id(DependencyObject e) => AutomationProperties.GetAutomationId(e) ?? "";

    private static FrameworkElement Root => (FrameworkElement)App.Window!.Content;

    /// The shown elements under `node` (collapsed branches left out).
    private static IEnumerable<FrameworkElement> Shown(DependencyObject node)
    {
        if (node is UIElement { Visibility: Visibility.Collapsed }) yield break;
        if (node is FrameworkElement fe) yield return fe;
        var count = VisualTreeHelper.GetChildrenCount(node);
        for (var i = 0; i < count; i++)
            foreach (var child in Shown(VisualTreeHelper.GetChild(node, i))) yield return child;
    }

    private static IEnumerable<FrameworkElement> InPopups() =>
        Root.XamlRoot is { } xr ? VisualTreeHelper.GetOpenPopupsForXamlRoot(xr).Where(p => p.Child != null).SelectMany(p => Shown(p.Child)) : [];

    private static FrameworkElement? Find(string id) => Shown(Root).FirstOrDefault(e => Id(e) == id);

    private static FrameworkElement Need(string id) => Find(id) ?? throw new InvalidOperationException($"{id} isn't showing");

    private static List<FrameworkElement> Rows() =>
        [.. Shown(Root).Where(e => Id(e).StartsWith(Row, StringComparison.Ordinal))];

    /// A click as UI Automation makes it (the button's Invoke pattern).
    private static void Invoke(FrameworkElement element)
    {
        if (FrameworkElementAutomationPeer.CreatePeerForElement(element) is IInvokeProvider invoke) invoke.Invoke();
        else throw new InvalidOperationException($"{Id(element)} can't be invoked");
    }

    /// Waits at least 10 s (15 by default) for `get` to give something. `allowFlyoutNudge`: a button whose Invoke left
    /// its flyout shut after 3 s gets it shown directly, and the log says so.
    private static async Task<T> Until<T>(Func<T?> get, string what, int seconds = 15, Button? allowFlyoutNudge = null) where T : class
    {
        var start = DateTime.UtcNow;
        var nudged = false;
        while (true)
        {
            if (get() is { } found) return found;
            if (DateTime.UtcNow - start > TimeSpan.FromSeconds(seconds)) throw new TimeoutException($"waited too long for {what}");
            if (!nudged && allowFlyoutNudge?.Flyout is { } flyout && DateTime.UtcNow - start > TimeSpan.FromSeconds(3))
            {
                nudged = true;
                AppLog.Note("automation", "kanban: Invoke left the boards menu shut; showing it directly");
                flyout.ShowAt(allowFlyoutNudge);
            }
            await Task.Delay(100);
        }
    }
}
