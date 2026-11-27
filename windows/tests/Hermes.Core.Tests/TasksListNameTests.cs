using Hermes.Core.Tasks;

namespace Hermes.Core.Tests;

/// [WIN-TASK-LIST-EDIT] A list's name as typed: the Mac's `prefix(60)` counts characters as you see them (Swift
/// Characters), so a long Unicode name is never cut inside an emoji, a flag or an accent.
public class TasksListNameTests
{
    [Fact]
    public void ANameIsTrimmedAndCutAtSixtyCharactersAsYouSeeThem()
    {
        Assert.Null(TodoListCopy.CleanName(null));
        Assert.Null(TodoListCopy.CleanName(" \n\t "));
        Assert.Equal("Errands", TodoListCopy.CleanName("  Errands \n"));
        Assert.Equal(new string('x', 60), TodoListCopy.CleanName(new string('x', 70)));
        // 59 letters then a toned thumbs-up (one character, four UTF-16 units): kept whole, nothing after it.
        var thumbs = "\U0001F44D\U0001F3FD";
        Assert.Equal(new string('a', 59) + thumbs, TodoListCopy.CleanName(new string('a', 59) + thumbs + "zz"));
        // Sixty flags (each two code points) stay sixty flags; the sixty-first goes.
        var flag = "\U0001F1EF\U0001F1F5";
        Assert.Equal(string.Concat(Enumerable.Repeat(flag, 60)), TodoListCopy.CleanName(string.Concat(Enumerable.Repeat(flag, 61))));
        // An accent written as e + combining acute is one character.
        var e = "e\u0301";
        Assert.Equal(string.Concat(Enumerable.Repeat(e, 60)), TodoListCopy.CleanName(string.Concat(Enumerable.Repeat(e, 64))));
        Assert.Equal("Ménage à trois 🏠", TodoListCopy.CleanName(" Ménage à trois 🏠 "));
    }
}
