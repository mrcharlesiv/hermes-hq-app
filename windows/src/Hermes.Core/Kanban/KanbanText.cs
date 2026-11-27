namespace Hermes.Core.Kanban;

/// The agent-written words on a task's page (App/Pages/Kanban/KanbanTaskSheet.swift `FoldedMarkdown`): its Result,
/// Description, Latest Update (also in the working card), and each comment. All of them read as Markdown through the
/// chat's renderer (App/Pages/PagesMarkdown.swift), folded with Show More / Show Less. Last Error stays monospaced text.
public enum KanbanTextPart { Result, Description, LatestUpdate, WorkingUpdate, Comment }

/// What the Description section shows: the formatted words, the editor holding the raw text, or Add a Description.
public enum KanbanDescriptionMode { Markdown, Editing, Add }

public sealed record KanbanDescriptionView(KanbanDescriptionMode Mode, string Text);

public static class KanbanText
{
    /// How many lines a part shows before Show More: `FoldedMarkdown(text:)` folds to twelve, the working card's Latest
    /// Update (`FoldedMarkdown(text: summary, lines: 6)`) to six.
    public static int FoldLines(KanbanTextPart part) => part == KanbanTextPart.WorkingUpdate ? 6 : 12;

    /// The Description section (`descriptionSection`): while editing, the editor holds exactly what is being typed; else
    /// the body as Markdown; with no body, Add a Description.
    public static KanbanDescriptionView Description(string? body, string? editing) =>
        editing != null ? new(KanbanDescriptionMode.Editing, editing)
        : body is { Length: > 0 } ? new(KanbanDescriptionMode.Markdown, Markdown(body))
        : new(KanbanDescriptionMode.Add, "");

    /// The text handed to the chat's Markdown renderer. The Mac's renderer draws a line break inside a paragraph as a
    /// line break (MarkdownRenderer.swift: `SoftBreak` → U+2028), so a task written as plain lines reads as those lines;
    /// CommonMark would join them with a space. Each such line therefore ends in a hard break (two spaces). Code (fenced,
    /// or indented after a blank line) and lines already ending in a hard break are left exactly as written.
    public static string Markdown(string text)
    {
        var lines = text.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n');
        char fence = '\0';
        var fenceLength = 0;
        var indentedCode = false;
        for (var i = 0; i < lines.Length; i++)
        {
            var line = lines[i];
            var blank = line.Trim().Length == 0;
            if (fence != '\0')
            {
                if (Fence(line) is { } close && close.Mark == fence && close.Length >= fenceLength && close.After.Trim().Length == 0)
                    fence = '\0';
                continue;
            }
            if (Fence(line) is { } open && (open.Mark == '~' || !open.After.Contains('`')))
            {
                fence = open.Mark;
                fenceLength = open.Length;
                indentedCode = false;
                continue;
            }
            if (blank) continue;
            var previousBlank = i == 0 || lines[i - 1].Trim().Length == 0;
            if (Indented(line) && (indentedCode || previousBlank)) { indentedCode = true; continue; }
            indentedCode = false;
            if (i + 1 >= lines.Length || lines[i + 1].Trim().Length == 0) continue;
            if (line.EndsWith("  ", StringComparison.Ordinal) || line.EndsWith('\\')) continue;
            lines[i] = line + "  ";
        }
        return string.Join("\n", lines);
    }

    private static bool Indented(string line) =>
        line.StartsWith('\t') || line.StartsWith("    ", StringComparison.Ordinal);

    /// A code fence (``` or ~~~, three or more, up to three spaces in): its mark, length and what follows.
    private static (char Mark, int Length, string After)? Fence(string line)
    {
        var start = 0;
        while (start < line.Length && start < 4 && line[start] == ' ') start++;
        if (start > 3 || start >= line.Length || line[start] is not ('`' or '~')) return null;
        var mark = line[start];
        var end = start;
        while (end < line.Length && line[end] == mark) end++;
        return end - start >= 3 ? (mark, end - start, line[end..]) : null;
    }
}
