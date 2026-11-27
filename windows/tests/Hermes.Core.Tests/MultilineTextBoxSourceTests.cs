using System.Text.RegularExpressions;
using Xunit;

namespace Hermes.Core.Tests;

/// A WinUI TextBox with AcceptsReturn still false keeps only the first line of any Text it is given, and turning
/// AcceptsReturn on afterwards doesn't bring the rest back. C# object initializers set properties in the order written,
/// so `new TextBox { Text = x, AcceptsReturn = true }` drops every line after the first: CI run 45011042251 showed a
/// Kanban task's Edit holding only "## Launch thread". This holds every multi-line box in the app to AcceptsReturn first.
public class MultilineTextBoxSourceTests
{
    private static readonly Regex Initializer = new(@"new (?:TextBox|RichEditBox)\s*\{(.*?)\}\s*;", RegexOptions.Singleline);
    private static readonly Regex TextSet = new(@"(?<![A-Za-z_.])Text\s*=(?!=)");
    private static readonly Regex AcceptsReturnTrue = new(@"AcceptsReturn\s*=\s*true");

    /// "file:line" for each initializer that sets Text before AcceptsReturn = true.
    internal static List<string> TextBeforeAcceptsReturn(string file, string source)
    {
        var found = new List<string>();
        foreach (Match m in Initializer.Matches(source))
        {
            var body = m.Groups[1].Value;
            var accepts = AcceptsReturnTrue.Match(body);
            var text = TextSet.Match(body);
            if (accepts.Success && text.Success && text.Index < accepts.Index)
                found.Add($"{file}:{source[..m.Index].Count(c => c == '\n') + 1}");
        }
        return found;
    }

    [Fact]
    public void TheRuleCatchesTextBeforeAcceptsReturn()
    {
        Assert.Single(TextBeforeAcceptsReturn("a.cs", "var b = new TextBox { Text = x, AcceptsReturn = true };"));
        Assert.Single(TextBeforeAcceptsReturn("a.cs", "var b = new TextBox\n{\n    Header = \"H\", Text = x,\n    AcceptsReturn = true,\n};"));
        Assert.Empty(TextBeforeAcceptsReturn("a.cs", "var b = new TextBox { AcceptsReturn = true, Text = x };"));
        Assert.Empty(TextBeforeAcceptsReturn("a.cs", "var b = new TextBox { Text = x, AcceptsReturn = false };"));
        Assert.Empty(TextBeforeAcceptsReturn("a.cs", "var b = new TextBox { PlaceholderText = \"p\", AcceptsReturn = true };"));
    }

    [Fact]
    public void EveryMultilineBoxTurnsOnReturnsBeforeItsText()
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        var src = Path.Combine(dir, "src");
        var found = Directory.EnumerateFiles(src, "*.cs", SearchOption.AllDirectories)
            .SelectMany(p => TextBeforeAcceptsReturn(Path.GetRelativePath(src, p), File.ReadAllText(p)))
            .ToList();
        Assert.True(found.Count == 0, "Text set before AcceptsReturn = true (only the first line survives):\n" + string.Join("\n", found));
    }
}
