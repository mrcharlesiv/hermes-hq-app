using Hermes.Core.Shell;

namespace Hermes.Core.Tests;

/// [WIN-58] The keyboard-only walk's order table and checks (Hermes.Core.Shell.KeyboardOnlyWalkProof): the stops the
/// Mac's key loop reaches, in the Mac's order, and how a focused stop is judged visible, on screen and drawn.
public class KeyboardOnlyWalkTests
{
    private static string[] Keys(KeyStop[] stops) => stops.Select(s => s.Key).ToArray();

    [Fact]
    public void ChatTabOrderIsTheMacs()
    {
        // Sidebar row, then the header left to right (⋯ before Inspector: rightBarButtonItems lists the trailing item
        // first), then the message box (bubbles take no keyboard focus).
        Assert.Equal(["sidebar.chat", "MoreButton", "InspectorToggle", "chat.composer"], Keys(KeyboardOnlyWalkProof.ChatForward));
        Assert.Equal(["InspectorToggle", "MoreButton", "sidebar*"], Keys(KeyboardOnlyWalkProof.ChatBackward));
        Assert.Equal(["tasks.search", "tasks.key.*"], Keys(KeyboardOnlyWalkProof.TasksForward));
        Assert.Equal("Ctrl+,", KeyboardOnlyWalkProof.SettingsKey);
    }

    [Fact]
    public void EveryStopCitesItsSwift()
    {
        foreach (var stop in KeyboardOnlyWalkProof.ChatForward.Concat(KeyboardOnlyWalkProof.ChatBackward).Concat(KeyboardOnlyWalkProof.TasksForward))
        {
            Assert.StartsWith("App/", stop.Swift);
            Assert.Contains(".swift `", stop.Swift);
            Assert.False(string.IsNullOrWhiteSpace(stop.What));
        }
        Assert.Contains("\"Chat Actions\"", KeyboardOnlyWalkProof.ChatForward[1].Swift);
        Assert.Contains("\"Inspector\"", KeyboardOnlyWalkProof.ChatForward[2].Swift);
        Assert.Contains("\"Search Tasks\"", KeyboardOnlyWalkProof.TasksForward[0].Swift);
    }

    [Fact]
    public void OrderPassesWithStopsBetween()
    {
        string[] went = ["sidebar.tools.search", "sidebar.chat", "FoldButton", "shell.account", "MoreButton", "InspectorToggle", "composer.attach", "chat.composer"];
        Assert.Null(KeyboardOnlyWalkProof.Order(went, KeyboardOnlyWalkProof.ChatForward));
        // The walk keys every stop under the sidebar pane "sidebar." + its own key.
        string[] back = ["composer.attach", "InspectorToggle", "MoreButton", "sidebar.shell.account"];
        Assert.Null(KeyboardOnlyWalkProof.Order(back, KeyboardOnlyWalkProof.ChatBackward));
        Assert.Null(KeyboardOnlyWalkProof.Order(["tasks.more", "tasks.new", "tasks.search", "tasks.section.Today", "tasks.key.t1"], KeyboardOnlyWalkProof.TasksForward));
    }

    [Fact]
    public void OrderFailsOutOfOrderOrMissing()
    {
        // Inspector before Chat Actions: not the Mac's order.
        var swapped = KeyboardOnlyWalkProof.Order(["sidebar.chat", "InspectorToggle", "MoreButton", "chat.composer"], KeyboardOnlyWalkProof.ChatForward);
        Assert.NotNull(swapped);
        Assert.Contains("Inspector (InspectorToggle) came before the stop it follows on the Mac", swapped);
        // A task row the keyboard never reaches (the rows were plain Borders, no tab stop).
        var noRow = KeyboardOnlyWalkProof.Order(["tasks.more", "tasks.new", "tasks.search", "tasks.section.Today"], KeyboardOnlyWalkProof.TasksForward);
        Assert.NotNull(noRow);
        Assert.Contains("a task's row (tasks.key.*) was never reached", noRow);
        Assert.Contains("tasks.search → tasks.section.Today", noRow);
        // Trapped in the chat: Shift+Tab never gets back to the sidebar.
        Assert.NotNull(KeyboardOnlyWalkProof.Order(["InspectorToggle", "MoreButton", "chat.composer", "InspectorToggle"], KeyboardOnlyWalkProof.ChatBackward));
    }

    [Fact]
    public void PrefixMatching()
    {
        Assert.True(KeyboardOnlyWalkProof.Matches("sidebar*", "sidebar.chat"));
        Assert.True(KeyboardOnlyWalkProof.Matches("tasks.key.*", "tasks.key.t9"));
        Assert.False(KeyboardOnlyWalkProof.Matches("tasks.key.*", "tasks.row.t9"));
        Assert.False(KeyboardOnlyWalkProof.Matches("chat.composer", "chat.composer2"));
    }

    [Fact]
    public void OnScreenWantsASizeInsideTheWindow()
    {
        Assert.Null(KeyboardOnlyWalkProof.OnScreen("chat.composer", 600, 32, 300, 700, 1280, 800));
        Assert.Null(KeyboardOnlyWalkProof.OnScreen("edge", 100, 20, -0.5, 0, 1280, 800));   // rounding slack
        Assert.Equal("x has the focus but no size (0×20)", KeyboardOnlyWalkProof.OnScreen("x", 0, 20, 10, 10, 1280, 800));
        Assert.Contains("off screen", KeyboardOnlyWalkProof.OnScreen("x", 100, 20, 10, 790, 1280, 800));
        Assert.Contains("off screen", KeyboardOnlyWalkProof.OnScreen("x", 100, 20, -50, 10, 1280, 800));
    }

    [Fact]
    public void FocusVisualIsTheSystemRingOrABoxBorder()
    {
        Assert.True(KeyboardOnlyWalkProof.DrawsFocus(true, false, 0));
        Assert.False(KeyboardOnlyWalkProof.DrawsFocus(false, false, 1));
        Assert.True(KeyboardOnlyWalkProof.DrawsFocus(false, true, 1));
        // The message box has no border of its own (ChatPage.xaml BorderThickness="0"): only the system ring shows it.
        Assert.False(KeyboardOnlyWalkProof.DrawsFocus(false, true, 0));
    }
}
