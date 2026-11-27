namespace Hermes.Core.Voice;

// The one-gesture voice memo: a pure reducer, ported line for line from HermesKit/Voice/MemoGesture.swift at 93f984bb1
// (spec 1x-voice §3.2; owner decision 1: it sends on release). Presses and recorder answers in, a state and the effects
// to run out; `MemoSession` runs the effects.
//
//   press                      → begin at once; red only once the recorder says it is recording
//   permission prompt          → nothing records; after Allow, the "Now Hold to Record" tip
//   release before 1.0 s       → locked, hands-free, still recording (never sends, never discards)
//   release at 1.0 s or later  → sends (Send Memo on Release, the default), else stops into review
//                                (the second counts from when recording started, not from the press)
//   slide left past the line   → cancel;  slide up to −72 → locked
//   pointer cancelled          → kept as a draft chip, never sent
//
// Times are milliseconds (as the Mac's), so the 1.0 s rule compares whole numbers exactly. Distances are the Mac's
// points; on Windows they are device-independent pixels (the same 1/96-inch-ish unit a WinUI pointer reports).

/// What happens to a take when it ends (MemoTypes.swift `MemoEndAction`).
public enum MemoEndAction { Cancel, Review, Send, Draft }

/// The memo tips (spec §3.7). `Talk` is the Mac's "Talk with <name>" tip on the circle.
public enum MemoTip { NowHold, HoldToRecord, Talk }

public enum MemoHaptic { Recording, Lock, CancelArmed }

public enum MemoPhase { Idle, Pressing, Holding, Locked, Ending, Review }

public sealed record MemoGestureState
{
    public MemoPhase Phase { get; init; } = MemoPhase.Idle;
    public double DownAt { get; init; }
    public double? StartedAt { get; init; }
    public double Width { get; init; }
    public double DX { get; init; }
    public double DY { get; init; }
    /// The finger left before the recorder confirmed the recording.
    public bool Released { get; init; }
    /// The system took the press (a call, an alert, the chat left) before the recorder confirmed.
    public bool Canceled { get; init; }
    public bool CancelArmed { get; init; }
    public bool LockNear { get; init; }
    /// Locked by a short press (the "Hold to Record" tip teaches the gesture after the first one).
    public bool TapLocked { get; init; }
    public bool ConfirmingDelete { get; init; }
    /// The take's length: live while recording, final in review.
    public double Seconds { get; init; }
    public MemoEndAction? Ending { get; init; }

    public static readonly MemoGestureState Idle = new();

    public bool IsRecording => Phase is MemoPhase.Holding or MemoPhase.Locked;
}

public abstract record MemoInput
{
    private MemoInput() { }
    public sealed record Down(double At, double Width) : MemoInput;
    /// Narrator's Invoke or a keyboard press of the mic: the locked recorder, never a hold (VoiceOver's double-tap).
    public sealed record A11yOpen(double At) : MemoInput;
    public sealed record Move(double DX, double DY) : MemoInput;
    public sealed record Up(double At) : MemoInput;
    public sealed record PointerCancel : MemoInput;
    public sealed record Started(double At) : MemoInput;
    public sealed record BeginFailed(string Code, bool? Granted = null, string? Message = null) : MemoInput;
    public sealed record Tick(double Seconds) : MemoInput;
    public sealed record Stop : MemoInput;
    public sealed record Send : MemoInput;
    public sealed record Delete : MemoInput;
    public sealed record DeleteConfirmed : MemoInput;
    public sealed record DeleteKept : MemoInput;
    public sealed record Limit(double Seconds) : MemoInput;
    public sealed record NativeStopped : MemoInput;
    public sealed record Leave : MemoInput;
    public sealed record Ended(MemoEndAction Action, double? Seconds = null) : MemoInput;
    public sealed record Reset : MemoInput;
}

public abstract record MemoEffect
{
    private MemoEffect() { }
    public sealed record Begin : MemoEffect;
    public sealed record End(MemoEndAction Action) : MemoEffect;
    public sealed record SendReviewed : MemoEffect;
    public sealed record DiscardReviewed : MemoEffect;
    public sealed record DraftReviewed : MemoEffect;
    public sealed record ConfirmDelete(double Seconds, bool Recording) : MemoEffect;
    public sealed record Tip(MemoTip Value) : MemoEffect;
    public sealed record Failed(string Code, string? Message = null) : MemoEffect;
    public sealed record Haptic(MemoHaptic Value) : MemoEffect;
    public sealed record FocusStatus : MemoEffect;
}

public static class MemoGesture
{
    public const double HoldSendMs = 1000;
    public const double TapSlop = 12;
    public const double LockDY = -72;
    public const double LockNearDY = -40;
    public const double DeleteConfirmSeconds = 10;

    /// How far left cancels: min(120, 35 % of the composer's width).
    public static double CancelLine(double width) => -Math.Min(120, Math.Max(1, width) * 0.35);

    private static bool Moved(MemoGestureState s) => Math.Sqrt(s.DX * s.DX + s.DY * s.DY) >= TapSlop;

    public static (MemoGestureState State, IReadOnlyList<MemoEffect> Effects) Reduce(MemoGestureState state, MemoInput input,
        bool sendOnRelease)
    {
        (MemoGestureState, IReadOnlyList<MemoEffect>) Next(MemoGestureState s, params MemoEffect[] effects) => (s, effects);
        (MemoGestureState, IReadOnlyList<MemoEffect>) End(MemoEndAction action, MemoGestureState? patched = null) =>
            ((patched ?? state) with { Phase = MemoPhase.Ending, Ending = action, CancelArmed = false, ConfirmingDelete = false },
             [new MemoEffect.End(action)]);
        (MemoGestureState, IReadOnlyList<MemoEffect>) Lock(MemoGestureState? patched = null) =>
            ((patched ?? state) with { Phase = MemoPhase.Locked, CancelArmed = false, LockNear = false },
             [new MemoEffect.Haptic(MemoHaptic.Lock), new MemoEffect.FocusStatus()]);
        (MemoGestureState, IReadOnlyList<MemoEffect>) Idle(params MemoEffect[] effects) => (MemoGestureState.Idle, effects);
        var unchanged = (state, (IReadOnlyList<MemoEffect>)[]);

        switch (input)
        {
            case MemoInput.Reset:
                return Idle();

            case MemoInput.Down down:
                if (state.Phase != MemoPhase.Idle) return unchanged;
                return Next(MemoGestureState.Idle with { Phase = MemoPhase.Pressing, DownAt = down.At, Width = down.Width },
                    new MemoEffect.Begin());

            case MemoInput.A11yOpen open:
                if (state.Phase != MemoPhase.Idle) return unchanged;
                return Next(MemoGestureState.Idle with { Phase = MemoPhase.Pressing, DownAt = open.At, Released = true, TapLocked = false },
                    new MemoEffect.Begin());

            case MemoInput.Move move:
            {
                if (state.Phase is not (MemoPhase.Pressing or MemoPhase.Holding)) return unchanged;
                var armed = move.DX <= CancelLine(state.Width);
                var patched = state with { DX = move.DX, DY = move.DY, CancelArmed = armed, LockNear = move.DY <= LockNearDY };
                if (state.Phase == MemoPhase.Holding && move.DY <= LockDY && !armed) return Lock(patched);
                if (armed && !state.CancelArmed && state.Phase == MemoPhase.Holding)
                    return Next(patched, new MemoEffect.Haptic(MemoHaptic.CancelArmed));
                return Next(patched);
            }

            case MemoInput.Up up:
                if (state.Phase == MemoPhase.Pressing) return Next(state with { Released = true });
                if (state.Phase != MemoPhase.Holding) return unchanged;
                if (state.CancelArmed) return End(MemoEndAction.Cancel);
                // A short or unsure press never sends and never loses audio: it keeps recording hands-free.
                if (up.At - (state.StartedAt ?? state.DownAt) < HoldSendMs) return Lock(state with { TapLocked = !Moved(state) });
                return End(sendOnRelease ? MemoEndAction.Send : MemoEndAction.Review);

            case MemoInput.PointerCancel:
                if (state.Phase == MemoPhase.Pressing) return Next(state with { Canceled = true });
                if (state.Phase == MemoPhase.Holding) return End(MemoEndAction.Draft);
                return unchanged;

            case MemoInput.Started started:
                if (state.Phase != MemoPhase.Pressing) return unchanged;
                if (state.Canceled || (state.Released && state.CancelArmed))
                    return End(MemoEndAction.Cancel, state with { StartedAt = started.At });
                // Let go before the recorder confirmed: nothing was recorded while the finger was down, so however long
                // the press was there is no take to send; it records hands-free from now.
                if (state.Released) return Lock(state with { StartedAt = started.At, TapLocked = !Moved(state) });
                if (state.DY <= LockDY && !state.CancelArmed) return Lock(state with { StartedAt = started.At });
                return Next(state with { Phase = MemoPhase.Holding, StartedAt = started.At }, new MemoEffect.Haptic(MemoHaptic.Recording));

            case MemoInput.BeginFailed failed:
                if (state.Phase != MemoPhase.Pressing) return unchanged;
                if (failed.Code == "permission-pending")
                    return Idle(failed.Granted == true ? new MemoEffect.Tip(MemoTip.NowHold) : new MemoEffect.Failed("permission-denied"));
                if (failed.Code is "busy" or "canceled") return Idle();
                return Idle(new MemoEffect.Failed(failed.Code, failed.Message));

            case MemoInput.Tick tick:
                return state.IsRecording ? Next(state with { Seconds = tick.Seconds }) : unchanged;

            case MemoInput.Stop:
                return state.Phase == MemoPhase.Locked ? End(MemoEndAction.Review) : unchanged;

            case MemoInput.Send:
                if (state.Phase == MemoPhase.Locked) return End(MemoEndAction.Send);
                if (state.Phase == MemoPhase.Review) return Idle(new MemoEffect.SendReviewed());
                return unchanged;

            case MemoInput.Delete:
                if (state.Phase is not (MemoPhase.Locked or MemoPhase.Review)) return unchanged;
                if (state.Seconds >= DeleteConfirmSeconds)
                    return Next(state with { ConfirmingDelete = true },
                        new MemoEffect.ConfirmDelete(state.Seconds, state.Phase == MemoPhase.Locked));
                return state.Phase == MemoPhase.Locked ? End(MemoEndAction.Cancel) : Idle(new MemoEffect.DiscardReviewed());

            case MemoInput.DeleteConfirmed:
                if (!state.ConfirmingDelete) return unchanged;
                return state.Phase == MemoPhase.Locked ? End(MemoEndAction.Cancel) : Idle(new MemoEffect.DiscardReviewed());

            case MemoInput.DeleteKept:
                return Next(state with { ConfirmingDelete = false });

            case MemoInput.Limit limit:
                // At the limit the recording has already stopped: a held memo follows the release rule (a finger past
                // the cancel line, showing "Release to Cancel", cancels), a locked one goes to review.
                if (state.Phase == MemoPhase.Holding)
                    return End(state.CancelArmed ? MemoEndAction.Cancel : sendOnRelease ? MemoEndAction.Send : MemoEndAction.Review,
                        state with { Seconds = limit.Seconds });
                if (state.Phase == MemoPhase.Locked) return End(MemoEndAction.Review, state with { Seconds = limit.Seconds });
                return unchanged;

            case MemoInput.NativeStopped:
                // A call, a lost headset, the app hidden: the recorder kept the take as a draft (or dropped a
                // sub-second one).
                return state.IsRecording || state.Phase == MemoPhase.Pressing ? Idle() : unchanged;

            case MemoInput.Leave:
                // Its chat left the screen: a take left behind becomes a draft chip in the chat it started in (C3).
                if (state.Phase == MemoPhase.Pressing) return Next(state with { Canceled = true });
                if (state.IsRecording) return End(MemoEndAction.Draft);
                if (state.Phase == MemoPhase.Review) return Idle(new MemoEffect.DraftReviewed());
                return unchanged;

            case MemoInput.Ended ended:
                if (state.Phase != MemoPhase.Ending) return unchanged;
                if (ended.Action == MemoEndAction.Review)
                    return Next(state with { Phase = MemoPhase.Review, Ending = null, Seconds = ended.Seconds ?? state.Seconds });
                return Idle();

            default:
                return unchanged;
        }
    }
}
