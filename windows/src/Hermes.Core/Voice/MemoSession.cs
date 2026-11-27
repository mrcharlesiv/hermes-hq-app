namespace Hermes.Core.Voice;

/// The recorder the gesture drives. Both calls return at once; the recorder answers later through
/// `MemoSession.Input`: `Begin` with `Started` or `BeginFailed`, `End` with `Ended` (review carries the saved length).
/// A stop of its own (a call, a lost headset, the limit) goes through `MemoSession.RecorderStopped`.
/// A start that lands after the gesture went idle (reset, failed or stopped meanwhile) is ended by the session with
/// `Cancel`, once per `Begin`.
public interface IMemoRecorder
{
    void Begin();
    void End(MemoEndAction action);
}

/// Runs the gesture: feeds each input through `MemoGesture.Reduce` and runs its effects in order (MemoController's
/// `input` and `run` at 93f984bb1, without audio, files or chat). Begin and End go to the recorder; every other effect
/// goes to `effect` for the page (send or discard the reviewed take, keep it as a draft, tips, cues, focus).
/// A long take's Delete asks through `confirmDelete`; with nobody to ask (null) the take is kept, as the Mac's does
/// when its window is gone. Single-threaded: call it from the UI thread.
public sealed class MemoSession(IMemoRecorder recorder, Func<bool> sendOnRelease, Action<MemoEffect> effect,
    Action<double, bool, Action<bool>>? confirmDelete = null)
{
    public MemoGestureState State { get; private set; } = MemoGestureState.Idle;

    /// Raised after every input that changed the state (redraw the recorder's row and circle).
    public event Action<MemoGestureState>? Changed;

    // A Begin went to the recorder and no End has followed it yet: the take may still be holding the microphone.
    private bool open;

    public void Input(MemoInput input)
    {
        var before = State;
        var (next, effects) = MemoGesture.Reduce(State, input, sendOnRelease());
        State = next;
        if (next != before) Changed?.Invoke(next);
        foreach (var e in effects) Run(e);
        // Nothing wanted it any more (reset, failed or stopped before the start landed): stop recording, as
        // MemoController.begin() at 93f984bb1 does. A take already ended is not ended again.
        if (input is MemoInput.Started && State.Phase == MemoPhase.Idle && open)
            Run(new MemoEffect.End(MemoEndAction.Cancel));
    }

    /// The recorder stopped on its own. The limit waits for the release rule (`Limit`); anything else returns the
    /// gesture to idle and says whether the recorder keeps the take as a draft or drops it. Never a send.
    public MemoFinish RecorderStopped(MemoStopReason reason, double seconds)
    {
        var finish = MemoPolicy.Finish(reason, seconds);
        Input(finish == MemoFinish.Await ? new MemoInput.Limit(seconds) : new MemoInput.NativeStopped());
        return finish;
    }

    private void Run(MemoEffect e)
    {
        switch (e)
        {
            case MemoEffect.Begin:
                open = true;
                recorder.Begin();
                break;
            case MemoEffect.End end:
                open = false;
                recorder.End(end.Action);
                break;
            case MemoEffect.ConfirmDelete ask:
                effect(e);
                if (confirmDelete is null) Input(new MemoInput.DeleteKept());
                else confirmDelete(ask.Seconds, ask.Recording, yes => Input(yes ? new MemoInput.DeleteConfirmed() : new MemoInput.DeleteKept()));
                break;
            default:
                effect(e);
                break;
        }
    }
}
