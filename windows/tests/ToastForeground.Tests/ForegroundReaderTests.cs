using Hermes.Core.Notifications;
using HermesHQ.Services;

namespace ToastForeground.Tests;

public sealed partial class ForegroundTests
{
    [Fact]
    public void UndefinedExpectedChatStopsBeforeEvenTheWindowGetter()
    {
        Scene.Now = new Scene();
        Assert.Equal(QuietForeground.ExpectedChatUnknown, ReplyQuietReadback.Reader().ReadFixtureForeground((QuietChat)int.MaxValue));
        Assert.Empty(Scene.Now.Reads);
    }

    [Fact]
    public async Task InvalidPublicGuardNeverAsksTheReaderWhichChatItIs()
    {
        var w = new Walk(); await w.Run(); w.Scene.Reads.Clear();
        var stop = Assert.Throws<QuietWalkStopped>(() => w.Probe!.RequireChat((QuietChat)int.MaxValue));
        Assert.Equal("toast-quiet-stop/v1 phase=invalid gap=invalid-phase", stop.StopLine);
        Assert.Empty(w.Scene.Reads); Assert.Equal(2, w.Lines.Count);
        Assert.DoesNotContain(w.Lines, line => line.StartsWith("fixture-foreground", StringComparison.Ordinal));
    }
}
