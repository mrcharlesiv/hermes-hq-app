using System.Text.RegularExpressions;
using Xunit;

namespace Hermes.Core.Tests;

/// WinUI throws when a TextBlock's FontFamily is set to null ("'Unknown' is not a valid value for property
/// 'FontFamily'"): CI run 45020434210 lost the whole app when the composer's slash drawer drew a plain row with
/// `FontFamily = row.RefFace ? CodeFont : null`. Leave FontFamily unset instead of setting it to null.
public class NullFontFamilySourceTests
{
    private static readonly Regex NullFont = new(@"FontFamily\s*=\s*(?:null!?\s*[,;}]|[^;,{}]*\?[^;,{}]*:\s*null!?\s*[,;}])");

    [Fact]
    public void TheRuleCatchesANullFontFamily()
    {
        Assert.Matches(NullFont, "new TextBlock { FontFamily = mono ? Res<FontFamily>(\"CodeFont\") : null, FontSize = 12 }");
        Assert.Matches(NullFont, "t.FontFamily = null;");
        Assert.DoesNotMatch(NullFont, "if (mono) t.FontFamily = Res<FontFamily>(\"CodeFont\");");
    }

    [Fact]
    public void NoFontFamilyIsSetToNull()
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        var src = Path.Combine(dir, "src");
        var found = Directory.EnumerateFiles(src, "*.cs", SearchOption.AllDirectories)
            .SelectMany(p => File.ReadAllLines(p).Select((l, i) => (p, l, i)))
            .Where(x => NullFont.IsMatch(x.l))
            .Select(x => $"{Path.GetRelativePath(src, x.p)}:{x.i + 1}")
            .ToList();
        Assert.True(found.Count == 0, "FontFamily set to null (WinUI throws):\n" + string.Join("\n", found));
    }
}
