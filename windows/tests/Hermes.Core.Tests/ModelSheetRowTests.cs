using System.Text.RegularExpressions;
using Hermes.Core.Composer;
using Hermes.Core.Shell;

namespace Hermes.Core.Tests;

/// [WIN-45] The Models sheet's rows (ModelsDialog; App/Chat/Menus/ModelSheetViewController.swift's ModelRowCell): each
/// row reads its model's name. CI run 44997803358 drew every row blank because the app's text helper set a local null
/// Foreground, which hides a TextBlock's words instead of letting it inherit the theme's.
public class ModelSheetRowTests
{
    private static readonly ModelChoice Sonnet = new("claude-sonnet-5", "Sonnet 5", "anthropic", "Anthropic");
    private static readonly ModelChoice Opus = new("claude-opus-4-5-20251101", "Opus 4.5", "anthropic", "Anthropic");

    [Fact]
    public void RowReadsTheModelsName()
    {
        var row = ModelSheetModel.Row(Opus, Sonnet, starred: false);
        Assert.Equal("Opus 4.5", row.Title);
        Assert.False(row.Current);
        Assert.Equal("Opus 4.5", row.AccessibleName);
        Assert.Equal("Favorite Opus 4.5", row.StarName);
        Assert.Equal("claude-opus-4-5-20251101", row.Tip);
    }

    [Fact]
    public void CurrentRowIsMarkedAndStillNamed()
    {
        var row = ModelSheetModel.Row(Sonnet, Sonnet, starred: true);
        Assert.Equal("Sonnet 5", row.Title);
        Assert.True(row.Current);
        Assert.True(row.Starred);
        Assert.Equal("Sonnet 5, Current", row.AccessibleName);
    }

    [Fact]
    public void NamelessModelStillShowsWords()
    {
        var row = ModelSheetModel.Row(new ModelChoice("x-ai/grok-4", "  ", "openrouter", "OpenRouter"), Sonnet, false);
        Assert.Equal("x-ai/grok-4", row.Title);
    }

    [Fact]
    public void EverySectionRowOfTheCatalogHasWords()
    {
        var models = new[]
        {
            Sonnet, Opus, new ModelChoice("gpt-5.5", "GPT-5.5", "openai-codex", "ChatGPT or Codex Subscription"),
            new ModelChoice("x-ai/grok-4", "Grok 4", "openrouter", "OpenRouter"),
        };
        var rows = ModelSheetModel.Sections(models, "", (Sonnet.Id, Sonnet.Provider))
            .SelectMany(s => s.Models).Select(m => ModelSheetModel.Row(m, Sonnet, false)).ToList();
        Assert.Equal(["Sonnet 5", "Opus 4.5", "GPT-5.5", "Grok 4"], rows.Select(r => r.Title));
        Assert.Single(rows, r => r.Current);
    }

    [Fact]
    public void WalkProofReadsTheRowsShown()
    {
        string[] expected = ["Sonnet 5", "Opus 4.5"];
        Assert.Null(ModelsSheetWalkProof.RowsRead(expected, [("Sonnet 5", true), ("Opus 4.5", true)]));
        Assert.Contains("blank", ModelsSheetWalkProof.RowsRead(expected, [("", true), ("", true)]));
        Assert.Contains("no brush", ModelsSheetWalkProof.RowsRead(expected, [("Sonnet 5", false), ("Opus 4.5", true)]));
        Assert.Contains("Opus 4.5", ModelsSheetWalkProof.RowsRead(expected, [("Sonnet 5", true)]));
        Assert.NotNull(ModelsSheetWalkProof.RowsRead([], []));
        Assert.Null(ModelsSheetWalkProof.CurrentMatchesPill("Sonnet 5", ["Sonnet 5, Current", "Opus 4.5"]));
        Assert.NotNull(ModelsSheetWalkProof.CurrentMatchesPill("Opus 4.5", ["Sonnet 5, Current", "Opus 4.5"]));
        Assert.NotNull(ModelsSheetWalkProof.CurrentMatchesPill("Sonnet 5", ["Sonnet 5", "Opus 4.5"]));
        Assert.Equal("Sonnet 5", ModelsSheetWalkProof.Shown(ModelSheetModel.Row(Sonnet, Sonnet, false).AccessibleName));
    }

    /// A local `Foreground = null` on a WinUI TextBlock leaves it without a brush: its words don't draw. The app clears
    /// a local brush with ClearValue, or doesn't set one.
    [Fact]
    public void AppNeverSetsANullForeground()
    {
        var src = Path.Combine(RepoRoot(), "windows", "src", "HermesHQ.Windows");
        var nullBrush = new Regex(@"Foreground\s*=\s*(null\b|[^;\n]*\?[^;\n]*:\s*null\b)");
        var hits = Directory.EnumerateFiles(src, "*.cs", SearchOption.AllDirectories)
            .SelectMany(f => File.ReadAllLines(f).Select((line, i) => (f, i, line)))
            .Where(x => nullBrush.IsMatch(x.line))
            .Select(x => $"{Path.GetRelativePath(src, x.f)}:{x.i + 1}: {x.line.Trim()}")
            .ToList();
        Assert.True(hits.Count == 0, "a null Foreground hides text:\n" + string.Join("\n", hits));
    }

    private static string RepoRoot()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir != null; dir = dir.Parent)
            if (File.Exists(Path.Combine(dir.FullName, "windows", "HermesHQ.sln")))
                return dir.FullName;
        throw new InvalidOperationException("repo root not found");
    }
}
