using System.Text.RegularExpressions;
using Hermes.Core.Capabilities;
using Hermes.Core.Settings;

namespace Hermes.Core.Tests;

/// [WIN-SKILLS-ROW-ONELINE] Skills' Installed and Available rows on the Mac (93f984bb1, App/Capabilities/
/// CapabilitiesViewController.swift `SkillRow` / `OfficialSkillRow`, `DeviceWord.isMac`): one subtitle line, category
/// and use then what it does, `.lineLimit(typeSize.isAccessibilitySize ? nil : 1)` at Standard and Compact alike, cut
/// at its tail, the whole description its tooltip (`.help(skill.description)`). Synthetic values only.
public class SkillRowOneLineTests
{
    [Theory]
    [InlineData(1.0, 1)]
    [InlineData(1.35, 1)]
    [InlineData(1.49, 1)]
    [InlineData(1.5, 0)]    // the accessibility sizes: no limit, the line wraps
    [InlineData(2.25, 0)]
    public void OneLineAtEveryOrdinarySizeAndNoLimitAtTheAccessibilitySizes(double textScale, int lines) =>
        Assert.Equal(lines, CapabilitiesWords.SkillLineLines(textScale));

    [Fact]
    public void TheLineDoesNotFollowDensity()
    {
        // Compact's one line comes from the row's own rule, not DescriptionLines (which is 2 at Standard).
        Assert.Equal(2, DensitySizes.DescriptionLines(compact: false));
        Assert.Equal(1, CapabilitiesWords.SkillLineLines(1.0));
    }

    [Fact]
    public void TheTooltipIsTheWholeDescriptionAndNoneWhenThereIsNone()
    {
        Assert.Equal("Searches the web and reads pages.", CapabilitiesWords.SkillTip("Searches the web and reads pages."));
        Assert.Null(CapabilitiesWords.SkillTip(""));
    }

    [Fact]
    public void InstalledAndAvailableRowsTakeTheOneLineAndTheTip()
    {
        var list = Source("Features", "Capabilities", "ListScreen.cs");
        Assert.Contains("Kit.Row(DisplayName.Title(skill.Name), CapabilitiesWords.SkillLine(skill), tip: CapabilitiesWords.SkillTip(skill.Description),", list);
        Assert.Contains("Kit.Row(DisplayName.Title(o.Name), CapabilitiesWords.OfficialLine(o), tip: CapabilitiesWords.SkillTip(o.Description),", list);
        Assert.Equal(2, Regex.Matches(list, Regex.Escape("subtitleLines: CapabilitiesWords.SkillLineLines(TextScale())")).Count);
        // Kit.Row cuts a limited subtitle at its tail; 0 lets it wrap.
        var kit = Source("Features", "Capabilities", "Kit.cs");
        Assert.Contains("sub.MaxLines = subtitleLines;", kit);
        Assert.Contains("sub.TextTrimming = TextTrimming.CharacterEllipsis;", kit);
    }

    private static string Source(params string[] parts)
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        return File.ReadAllText(Path.Combine([dir, "src", "HermesHQ.Windows", .. parts])).Replace("\r\n", "\n");
    }
}
