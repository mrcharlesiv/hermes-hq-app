// [botslist] [WIN-BOT-WAKING] "Waking up…" once a bot's chat has been opening for a second (parity §3 L184): display
// only, never saved. Port of HermesKit/Store/BotStore+RowStatus.swift `noteBotOpening`/`isWaking` and the waking half of
// BotStore.swift `stop()` at 93f984bb1 (`wakingBots`, `wakingTasks`, `wakingGrace`). The Mac's `Task.sleep(for: grace)`
// is a timer from `WakingClock`, so tests move a manual clock instead of sleeping.
namespace Hermes.Core.Bots;

public sealed partial class BotStore
{
    private readonly HashSet<string> _wakingBots = [];
    private readonly Dictionary<string, ITimer> _wakingTimers = [];

    /// How long an open lasts before its row says "Waking up…" (the Mac's `wakingGrace`, 1 s).
    public TimeSpan WakingGrace { get; set; } = TimeSpan.FromSeconds(1);
    /// The clock the grace runs on (tests pass a manual one).
    public TimeProvider WakingClock { get; set; } = TimeProvider.System;

    /// A bot's chat began opening (true) or its open ended — bound, failed, or the chat was left (false). The row says
    /// "Waking up…" only once the open has lasted `WakingGrace` (1 s), and stops saying it the moment the open ends.
    public void NoteBotOpening(string profile, bool opening)
    {
        if (opening)
        {
            lock (_gate)
            {
                if (_wakingTimers.ContainsKey(profile) || _wakingBots.Contains(profile)) return;
                ITimer? timer = null;
                timer = WakingClock.CreateTimer(_ => GraceEnded(profile, timer), null, WakingGrace, Timeout.InfiniteTimeSpan);
                _wakingTimers[profile] = timer;
            }
            return;
        }
        bool changed;
        lock (_gate)
        {
            if (_wakingTimers.Remove(profile, out var timer)) timer.Dispose();
            changed = _wakingBots.Remove(profile);
        }
        if (changed) Rebuild();
    }

    /// The transcript's header can say "Waking up…" too.
    public bool IsWaking(string profile) { lock (_gate) return _wakingBots.Contains(profile); }

    /// The account's store stops (sign-out, another gateway): no open is waiting any more (the Mac's `stop()`).
    public void StopWaking()
    {
        bool changed;
        lock (_gate)
        {
            foreach (var timer in _wakingTimers.Values) timer.Dispose();
            _wakingTimers.Clear();
            changed = _wakingBots.Count > 0;
            _wakingBots.Clear();
        }
        if (changed) Rebuild();
    }

    /// The grace ran out with the open still going (a timer the open's end already dropped does nothing).
    private void GraceEnded(string profile, ITimer? timer)
    {
        lock (_gate)
        {
            if (timer == null || !_wakingTimers.TryGetValue(profile, out var current) || current != timer) return;
            _wakingTimers.Remove(profile);
            timer.Dispose();
            if (!_wakingBots.Add(profile)) return;
        }
        Rebuild();
    }

    /// The rows' input (`input.waking = wakingBots`); called under `_gate`.
    private HashSet<string> WakingInput() => [.. _wakingBots];
}
