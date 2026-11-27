using System.Text.RegularExpressions;
using Xunit;

namespace Hermes.Core.Tests;

/// [WIN-ARCHIVE-UNDO] The WinUI side can't run here, so its source is held to the tested objects: the pill's Undo button
/// goes through `UndoPillPress` (one press undoes, the pill's going ends it), and both chat archive routes — a Sessions
/// row's Archive and Archive Chat (Ctrl+Alt+A) — hand the pill `ArchiveUndoRoute.For`, whose write is `ArchiveUndo`'s
/// behind the "Couldn’t Unarchive Chat" alert. Source proof only; it does not show the WinUI pill being clicked.
public class ArchiveUndoSourceTests
{
    private static string Source(params string[] parts)
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        return File.ReadAllText(Path.Combine([dir, "src", "HermesHQ.Windows", .. parts]));
    }

    private static string Body(string source, string signature)
    {
        var m = Regex.Match(source, Regex.Escape(signature) + @"[^\n]*\n    \{(?<body>.*?)\n    \}", RegexOptions.Singleline);
        Assert.True(m.Success, signature + " not found");
        return m.Groups["body"].Value;
    }

    [Fact]
    public void ThePillsUndoButtonPressesOnce()
    {
        var show = Body(Source("Features", "Bots", "Prompts.cs"), "public static Action Show(Panel host");
        Assert.Contains("new UndoPillPress(", show);
        Assert.Matches(@"undoButton\.Click \+= \(_, _\) => press\.Press\(\);", show);
        Assert.DoesNotMatch(@"Click \+= \(_, _\) => \{ Dismiss\(\); undo\(\); \}", show);
        var dismiss = Regex.Match(show, @"void Dismiss\(\)\s*\{(?<b>.*?)\n        \}", RegexOptions.Singleline).Groups["b"].Value;
        Assert.Contains("press?.Gone()", dismiss);   // a pill gone by its time, or replaced, takes no late click
    }

    [Fact]
    public void TheComposerWalkChecksTheRestoredChatAfterChatKeys()
    {
        const string name = "archive-undo";
        const string register = "RegisterArchiveUndoWalks();";
        var services = Source("Services", "ProofWalks.cs");
        Assert.Contains(register, services);
        var workflow = Source("..", "..", "ci", "windows.yml");
        var composer = Assert.Single(workflow.Split('\n'), line => line.Contains("tag = \"composer\";") && line.Contains("walks = @("));
        var walks = Regex.Match(composer, @"walks = @\((?<items>[^)]*)\)").Groups["items"].Value;
        Assert.Contains($"\"chat-keys\",\"{name}\"", walks);
        var walk = Source("Services", "ProofWalks.ArchiveUndo.cs");
        foreach (var word in new[] { name + "-pill", name + "-back" })
        {
            Assert.Contains($"\"{word}\"", composer);
            Assert.Contains($"await shot(\"{word}\");", walk);
        }
        Assert.Contains($"await shot(\"{name}\");", walk);
    }

    [Fact]
    public void BothArchiveRoutesUndoThroughTheTestedRestore()
    {
        var row = Body(Source("Features", "Sessions", "SessionActions.cs"), "private async Task ArchiveAsync(SessionSummary s)");
        Assert.Contains("ArchiveUndoRoute.For(root, Store, s)", row);
        Assert.DoesNotContain("_ = Store.SetArchivedAsync(s with", row);   // the dropped write that said nothing on failure

        var shell = Body(Source("Pages", "ShellPage.xaml.cs"), "internal async Task ArchiveChatAsync()");
        Assert.Contains("ArchiveUndoRoute.For(() => XamlRoot, store, s)", shell);
        Assert.DoesNotContain("store.SetArchivedAsync(s with { Archived = true }, false)", shell);

        var route = Source("Features", "Sessions", "ArchiveUndoRoute.cs");
        Assert.Contains("Prompts.RunAsync(root(), ArchiveUndo.FailureTitle, undo.RestoreAsync)", route);
    }
}
