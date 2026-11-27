using Hermes.Core.Kanban;

namespace Hermes.Core.Tests;

/// A task's text read as Markdown (App/Pages/Kanban/KanbanTaskSheet.swift FoldedMarkdown → App/Pages/PagesMarkdown.swift,
/// the chat's MarkdownRenderer): which words render, how far each folds, and the text the renderer is handed.
public class KanbanTextTests
{
    [Fact]
    public void PlainWordsAreHandedOverUnchanged()
    {
        Assert.Equal("Waits for the test suite.", KanbanText.Markdown("Waits for the test suite."));
        Assert.Equal("", KanbanText.Markdown(""));
        Assert.Equal("One paragraph.\n\nAnother one.", KanbanText.Markdown("One paragraph.\n\nAnother one."));
    }

    [Fact]
    public void ALineBreakInTheWordsStaysALineBreak()
    {
        // The Mac draws a soft break as a line break (MarkdownRenderer.swift: SoftBreak → U+2028); CommonMark would join
        // the lines with a space, so each one ends in a hard break.
        Assert.Equal("Step one  \nStep two  \nStep three", KanbanText.Markdown("Step one\nStep two\nStep three"));
        Assert.Equal("Step one  \nStep two", KanbanText.Markdown("Step one\r\nStep two"));
        // Already a hard break: left as written.
        Assert.Equal("Ends in two  \nEnds in a slash\\\nlast", KanbanText.Markdown("Ends in two  \nEnds in a slash\\\nlast"));
    }

    [Fact]
    public void CodeIsHandedOverExactly()
    {
        var fenced = "Run:\n```sh\nmake test\nmake lint\n```\nThen\n~~~\na\nb\n~~~";
        Assert.Equal("Run:  \n```sh\nmake test\nmake lint\n```\nThen  \n~~~\na\nb\n~~~", KanbanText.Markdown(fenced));
        // A fence of four closes only on four or more of its own mark.
        Assert.Equal("````\n```\nx\n````\nafter", KanbanText.Markdown("````\n```\nx\n````\nafter"));
        // An unclosed fence runs to the end.
        Assert.Equal("```\nx\ny", KanbanText.Markdown("```\nx\ny"));
        // Indented code after a blank line.
        Assert.Equal("Look:\n\n    one\n    two\n\nback  \nhere", KanbanText.Markdown("Look:\n\n    one\n    two\n\nback\nhere"));
    }

    [Fact]
    public void MarkdownSyntaxIsKept()
    {
        var text = "## Plan\n- **ship** it\n- check `--dry-run`\n1. [guide](https://example.com/a_b)\n> quoted";
        var prepared = KanbanText.Markdown(text);
        // Only trailing hard breaks are added: every line still starts as written.
        Assert.Equal(text.Split('\n'), prepared.Split('\n').Select(l => l.TrimEnd(' ')).ToArray());
        Assert.Equal("## Plan  \n- **ship** it  \n- check `--dry-run`  \n1. [guide](https://example.com/a_b)  \n> quoted", prepared);
    }

    [Fact]
    public void EveryAgentTextRendersAsMarkdownFoldedAsOnTheMac()
    {
        // FoldedMarkdown(text:) defaults to twelve lines; the working card's Latest Update folds to six.
        Assert.Equal(12, KanbanText.FoldLines(KanbanTextPart.Result));
        Assert.Equal(12, KanbanText.FoldLines(KanbanTextPart.Description));
        Assert.Equal(12, KanbanText.FoldLines(KanbanTextPart.LatestUpdate));
        Assert.Equal(12, KanbanText.FoldLines(KanbanTextPart.Comment));
        Assert.Equal(6, KanbanText.FoldLines(KanbanTextPart.WorkingUpdate));
    }

    [Fact]
    public void TheDescriptionReadsFormattedAndEditsRaw()
    {
        const string body = "# Brief\nShow **Markdown**,\nthen `JSON`.";
        var read = KanbanText.Description(body, editing: null);
        Assert.Equal(KanbanDescriptionMode.Markdown, read.Mode);
        Assert.Equal(KanbanText.Markdown(body), read.Text);

        // Edit: the editor holds exactly what was written (no added hard breaks), and what's typed stays as typed.
        var edit = KanbanText.Description(body, editing: body);
        Assert.Equal(KanbanDescriptionMode.Editing, edit.Mode);
        Assert.Equal(body, edit.Text);
        Assert.Equal("half typed\n", KanbanText.Description(body, editing: "half typed\n").Text);

        Assert.Equal(KanbanDescriptionMode.Add, KanbanText.Description(null, null).Mode);
        Assert.Equal(KanbanDescriptionMode.Add, KanbanText.Description("", null).Mode);
        // Add a Description opens an empty editor.
        Assert.Equal(new KanbanDescriptionView(KanbanDescriptionMode.Editing, ""), KanbanText.Description(null, ""));
    }
}
