using Hermes.Core;
using Hermes.Core.Chat;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Dispatching;

namespace HermesHQ.Features.Bots;

/// [WIN-EXTERNAL-SURFACES, WIN-OWN-TURN-ROWS] An open chat's turn on its bot row and its Sessions row, as the Mac's
/// AppModel (93f984bb1 App/AppModel.swift `onRunningChange`, `onExternalWorkChange`, `onStoredIdResolved`,
/// `onRuntimeBound`, `runningChats`, `offScreenTurnEnded`): a send of ours marks both rows at once
/// (ChatSession.RunningChanged), another Hermes process's turn too (ExternalWorkChanged), the mark moves with the stored
/// id the resume names, and a chat closed mid-turn keeps it until the turn's end arrives on the client's socket; that
/// end's reply then shows on both rows with the bot's unread dot ([WIN-OFFSCREEN-TURN-END], TurnRows.ApplyTo). The
/// rules are Hermes.Core's TurnRows; this applies each change to the lists on the UI thread. The gateway's live registry
/// (session.active_list) still marks the turns this PC didn't start. [WIN-OFFSCREEN-END-REST] A turn's end also gives
/// its bot row the Mac's standing problem (orange words) or clears it, and the step it was on goes; when the app signs
/// out or moves to another gateway (AppState.ClientChanged) the marks reset at that moment (the Mac's account teardown).
/// [WIN-LIVE-STEPS] The socket's tool frames name each chat's running step on its rows ("Reading package.json…" under
/// the bot and on the Sessions row, per chat), handed over once per quarter second (the Mac's `scheduleStepsPush`).
public static class ChatRowsWorking
{
    private static readonly TurnRows Rows = new();
    private static DispatcherQueue? _ui;
    /// One hand-over to the lists per quarter second: a burst of quick steps rebuilds them once.
    private static DispatcherQueueTimer? _stepsPush;

    static ChatRowsWorking()
    {
        Rows.Changed += change =>
        {
            if (AppShutdown.Stopping) return;
            _ui?.TryEnqueue(() =>
            {
                if (AppShutdown.Stopping || ListsHub.Current is not { } hub) return;
                if (change.OnlySteps) ScheduleStepsPush();
                else Rows.ApplyTo(change, hub.Bots, hub.Sessions);
            });
        };
        // The account's teardown: a sign-out, an ended session (null) or another gateway's client.
        AppState.ClientChanged += client => Rows.UseSocket(client?.Rpc);
    }

    internal static void StopForQuit()
    {
        Rows.UseSocket(null);
        var timer = _stepsPush;
        _stepsPush = null;
        _ui = null;
        timer?.Stop();
    }

    public static void Watch(ChatContext ctx)
    {
        if (AppShutdown.Stopping) return;
        _ui ??= ctx.Page.DispatcherQueue;
        Listen(ListsHub.Current?.Client);
        var screen = Rows.Follow(ctx.Session);
        ctx.Closed += screen.Dispose;
    }

    /// `scheduleStepsPush`: the steps go to the lists on the next quarter second.
    private static void ScheduleStepsPush()
    {
        if (_ui == null || AppShutdown.Stopping) return;
        if (_stepsPush == null)
        {
            _stepsPush = _ui.CreateTimer();
            _stepsPush.Interval = TimeSpan.FromMilliseconds(250);
            _stepsPush.IsRepeating = false;
            _stepsPush.Tick += (_, _) =>
            {
                if (!AppShutdown.Stopping && ListsHub.Current is { } hub) Rows.PushSteps(hub.Bots, hub.Sessions);
            };
        }
        if (!_stepsPush.IsRunning) _stepsPush.Start();
    }

    /// One client's socket at a time (TurnRows.UseSocket): a sign-in to another gateway moves the listener there.
    private static void Listen(HermesClient? client)
    {
        if (client != null) Rows.UseSocket(client.Rpc);
    }
}
