using System.Text.RegularExpressions;
using Xunit;

namespace Hermes.Core.Tests;

/// Archive Chat (Ctrl+Alt+A) closes the pane that held the keyboard, then shows the Undo pill. WinUI's focus fallback
/// could hand the keyboard to the pill's Undo, whose focus hold kept the pill up for good (CI run 45029354385, "the Undo
/// pill is held (VoiceOver)"). After the pill is shown the shell must put a fallen keyboard back in the sidebar.
public class ArchiveKeyboardSourceTests
{
    [Fact]
    public void ArchiveChatPutsAFallenKeyboardBackInTheSidebarAfterThePill()
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        var shell = File.ReadAllText(Path.Combine(dir, "src", "HermesHQ.Windows", "Pages", "ShellPage.xaml.cs"));
        var archive = Regex.Match(shell, @"internal async Task ArchiveChatAsync\(\)\s*\{(?<body>.*?)\n    \}", RegexOptions.Singleline);
        Assert.True(archive.Success, "ArchiveChatAsync not found");
        var body = archive.Groups["body"].Value;
        var pill = body.IndexOf("UndoPill.Show(", StringComparison.Ordinal);
        var keep = body.IndexOf("await KeepKeyboardInSidebarAsync();", StringComparison.Ordinal);
        Assert.True(pill >= 0 && keep > pill, "ArchiveChatAsync must await KeepKeyboardInSidebarAsync() after UndoPill.Show");
        Assert.Contains("Sidebar.Focus(FocusState.Keyboard)", shell[shell.IndexOf("private async Task KeepKeyboardInSidebarAsync", StringComparison.Ordinal)..]);
    }
}
