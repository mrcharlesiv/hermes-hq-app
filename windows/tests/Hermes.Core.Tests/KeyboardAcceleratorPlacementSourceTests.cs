using Xunit;

namespace Hermes.Core.Tests;

/// WinUI 3's default KeyboardAcceleratorPlacementMode.Auto creates an automatic ToolTip popup on any element
/// carrying KeyboardAccelerators (such as MainWindow.RootGrid, ShellPage, or a Page) whenever the pointer rests
/// over it or keyboard focus lands inside it. Setting KeyboardAcceleratorPlacementMode.Hidden keeps shortcuts
/// active without spawning phantom ToolTip popups over pages or duplicating explicit ToolTip text.
public class KeyboardAcceleratorPlacementSourceTests
{
    internal static bool HasUnmaskedAccelerators(string file, string source)
    {
        if (file.EndsWith(".xaml", StringComparison.OrdinalIgnoreCase))
            return source.Contains("<KeyboardAccelerator", StringComparison.Ordinal)
                && !source.Contains("KeyboardAcceleratorPlacementMode=\"Hidden\"", StringComparison.Ordinal);

        return source.Contains("KeyboardAccelerators.Add(", StringComparison.Ordinal)
            && !source.Contains("KeyboardAcceleratorPlacementMode.Hidden", StringComparison.Ordinal);
    }

    [Fact]
    public void TheRuleCatchesUnmaskedKeyboardAccelerators()
    {
        Assert.True(HasUnmaskedAccelerators("a.cs", "root.KeyboardAccelerators.Add(a);"));
        Assert.False(HasUnmaskedAccelerators("a.cs", "root.KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;\nroot.KeyboardAccelerators.Add(a);"));
        Assert.True(HasUnmaskedAccelerators("a.xaml", "<ToggleButton><ToggleButton.KeyboardAccelerators><KeyboardAccelerator Key=\"I\" /></ToggleButton.KeyboardAccelerators></ToggleButton>"));
        Assert.False(HasUnmaskedAccelerators("a.xaml", "<ToggleButton KeyboardAcceleratorPlacementMode=\"Hidden\"><ToggleButton.KeyboardAccelerators><KeyboardAccelerator Key=\"I\" /></ToggleButton.KeyboardAccelerators></ToggleButton>"));
    }

    [Fact]
    public void EveryKeyboardAcceleratorOwnerHidesWinUisAutomaticToolTip()
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln")))
            dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        var app = Path.Combine(dir, "src", "HermesHQ.Windows");
        var found = Directory.EnumerateFiles(app, "*.*", SearchOption.AllDirectories)
            .Where(p => p.EndsWith(".cs", StringComparison.Ordinal) || p.EndsWith(".xaml", StringComparison.Ordinal))
            .Where(p => !p.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}", StringComparison.Ordinal))
            .Select(p => (Rel: Path.GetRelativePath(app, p), Src: File.ReadAllText(p)))
            .Where(x => HasUnmaskedAccelerators(x.Rel, x.Src))
            .Select(x => x.Rel)
            .ToList();
        Assert.True(found.Count == 0,
            "Files adding KeyboardAccelerators without KeyboardAcceleratorPlacementMode.Hidden:\n" + string.Join("\n", found));
    }
}
