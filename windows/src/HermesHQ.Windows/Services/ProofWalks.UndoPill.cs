using Hermes.Core;
using Hermes.Core.Bots;
using Hermes.Core.Shell;
using HermesHQ.Features.Bots;
using Microsoft.UI.Xaml;

namespace HermesHQ.Services;

/// [WIN-44] The Undo pill's time, asserted by the chat-keys walk after its "chat-keys" shot: the archive's
/// "Archived “Trip planning”" pill runs its clock with nothing holding it — the Mac's 4 s, 8 at accessibility text sizes
/// (UndoPillClock) — and is gone within 10 s. The pill used to stay for minutes, into the later walks' shots.
/// Nothing holds it: the keyboard is in the sidebar after Archive Chat; a cursor left resting over it by an earlier click
/// is moved off it first (and logged), since the pointer resting there would rightly hold it.
internal static partial class ProofWalks
{
    private static async Task UndoPillLeavesAsync()
    {
        var started = DateTime.UtcNow;
        if (UndoPill.Current is { } pill && UndoPill.CurrentLife is { } life)
        {
            if (life.Clock.Holds.Contains(UndoPillHold.Pointer))
            {
                Mouse.MoveOffPill();
                AppLog.Note("automation", "walk undo pill: the cursor rested over the pill; moved off it");
                await Task.Delay(300);
            }
            var large = UndoPillClock.AccessibilityTextScale(new Windows.UI.ViewManagement.UISettings().TextScaleFactor);
            if (WalkProof.UndoPillRuns(life.Clock, large) is { } wrong) throw new InvalidOperationException(wrong);
        }
        var until = started.AddSeconds(WalkProof.UndoPillGoneWithin);
        while (true)
        {
            var shown = UndoPill.Current != null || Find("undo-pill") != null;
            var waited = (DateTime.UtcNow - started).TotalSeconds;
            if (!shown) { AppLog.Note("automation", $"walk undo pill: gone {waited:0.0} s after the shot"); return; }
            if (DateTime.UtcNow > until)
                throw new InvalidOperationException(WalkProof.UndoPillGone(true, waited) ?? "the Undo pill stayed");
            await Task.Delay(100);
        }
    }

}
