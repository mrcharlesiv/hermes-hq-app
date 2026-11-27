namespace Hermes.Core.Bots;

/// [WIN-ARCHIVE-UNDO] The Undo pill's button, kept apart from the view so its rule is unit-tested (App/Kit/UndoPill.swift
/// `undo()`: `let action = onUndo; onUndo = nil; dismiss(animated:); action?()`). The first press takes the pill away
/// and runs its undo; every later press — a double click, a click queued behind the first, a press after the pill's
/// time ran out — does nothing, so one pill can never send its undo twice. The Windows pill ran `undo` on every Click
/// (only its dismissal was guarded).
public sealed class UndoPillPress(Action dismiss, Action undo)
{
    private int _state;   // 0 on show, 1 taken by a press, 2 gone (time ran out, or another pill took the place)

    /// The pill's undo has run.
    public bool Taken => Volatile.Read(ref _state) == 1;

    /// The pill can still be pressed.
    public bool Open => Volatile.Read(ref _state) == 0;

    /// A press: true when it is the one that undid.
    public bool Press()
    {
        if (Interlocked.CompareExchange(ref _state, 1, 0) != 0) return false;
        dismiss();
        undo();
        return true;
    }

    /// The pill went without a press (its clock ran out, it was replaced or unloaded): later presses do nothing.
    public void Gone() => Interlocked.CompareExchange(ref _state, 2, 0);
}
