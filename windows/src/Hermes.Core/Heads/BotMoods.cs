using System.Diagnostics;
using Hermes.Core.Rpc;

namespace Hermes.Core.Heads;

// [moods] What a bot is up to right now, as its face acts it out (HermesKit/Activity/BotMood.swift &
// App/Heads/BotMoods.swift): 12 moods worked out from gateway turn events with dwell holding (2.2 s),
// once-only endings (`Done` 2.4 s, `Failed` 1.9 s), `Asking` precedence, and stale expiry (20 min).

public enum BotMood
{
    /// Between steps, or before the first: chin up, eyes up and to the side, turning it over.
    Thinking,
    /// A file, a page, an image: head down, narrowed eyes reading line by line.
    Reading,
    /// The web, files, past chats: looking this way and that, eyes first, leaning in to peer.
    Searching,
    /// A command or code: bobbing away at the work, a look at what came out.
    Running,
    /// A file, a patch, memory, a schedule: eyes and head following each line as it's typed.
    Writing,
    /// Its browser or its screen: a pointer the eyes and head follow, a peck where it clicks.
    Browsing,
    /// Another bot, an email, a hand-off: turned to the side, winding up and sending.
    Messaging,
    /// An image, a video, a voice: eyes up at it, wiggling, bouncing, admiring it.
    Making,
    /// Its answer is coming in: it nods and sways along as it talks.
    Replying,
    /// It waits for your answer or approval: head on one side, looking at you, little hops.
    Asking,
    /// The turn just finished (once): a jump, two blinks at you and a burst of light.
    Done,
    /// The turn failed (once): eyes screwed shut, a shake of the head, then a droop.
    Failed,
}

public static class BotMoodExtensions
{
    /// Shown once and then gone (the others last while the bot is at it).
    public static bool IsOnce(this BotMood mood) => mood is BotMood.Done or BotMood.Failed;

    /// How long a once-only mood plays (seconds).
    public static double Length(this BotMood mood) => mood switch
    {
        BotMood.Failed => 1.9,
        BotMood.Done => 2.4,
        _ => 0.0,
    };

    /// Wire name matching Swift `BotMood.rawValue`.
    public static string WireName(this BotMood mood) => mood.ToString().ToLowerInvariant();
}

/// Per-profile bot mood state machine driven by gateway turn events (`App/Heads/BotMoods.swift`).
public sealed class BotMoods
{
    public static BotMoods Shared { get; } = new();

    /// A step's mood stays at least this long so a sub-second step still reads on screen.
    public const double Dwell = 2.2;

    /// How long a working mood lasts with no word from its turn (missed ending safeguard).
    public const double StaleSeconds = 20 * 60;

    private sealed class State
    {
        public BotMood Mood;
        public double Since;
        public double Heard;
        public BotMood? Next;
    }

    private static readonly Dictionary<string, BotMood> KnownTools = new(StringComparer.Ordinal)
    {
        ["terminal"] = BotMood.Running,
        ["execute_code"] = BotMood.Running,
        ["process_manage"] = BotMood.Running,
        ["close_terminal"] = BotMood.Running,
        ["read_terminal"] = BotMood.Reading,
        ["read_file"] = BotMood.Reading,
        ["web_extract"] = BotMood.Reading,
        ["skill_view"] = BotMood.Reading,
        ["vision_analyze"] = BotMood.Reading,
        ["video_analyze"] = BotMood.Reading,
        ["web_search"] = BotMood.Searching,
        ["search_files"] = BotMood.Searching,
        ["session_search"] = BotMood.Searching,
        ["x_search"] = BotMood.Searching,
        ["skills_list"] = BotMood.Searching,
        ["write_file"] = BotMood.Writing,
        ["patch"] = BotMood.Writing,
        ["memory"] = BotMood.Writing,
        ["todo"] = BotMood.Writing,
        ["todo_list"] = BotMood.Writing,
        ["cronjob_manage"] = BotMood.Writing,
        ["skill_manage"] = BotMood.Writing,
        ["message_agent"] = BotMood.Messaging,
        ["send_message"] = BotMood.Messaging,
        ["delegate_task"] = BotMood.Messaging,
        ["image_generate"] = BotMood.Making,
        ["video_generate"] = BotMood.Making,
        ["text_to_speech"] = BotMood.Making,
        ["clarify"] = BotMood.Asking,
    };

    private static readonly string[] SearchWords = ["search", "find", "query", "lookup", "list"];
    private static readonly string[] MessageWords = ["send", "reply", "post", "message", "email", "mail", "notify", "invite", "share", "forward", "comment"];
    private static readonly string[] MakeWords = ["image", "video", "audio", "speech", "generate", "render", "draw"];
    private static readonly string[] WriteWords = ["create", "update", "write", "edit", "add", "insert", "patch", "upload", "delete", "remove", "set", "save", "move"];
    private static readonly string[] ReadWords = ["get", "read", "fetch", "view", "open", "download", "retrieve", "describe", "show"];
    private static readonly string[] BrowseWords = ["browse", "navigate", "click", "scroll", "screenshot", "screen"];

    private readonly object _lock = new();
    private readonly Dictionary<string, State> _states = new(StringComparer.Ordinal);
    private readonly HashSet<string> _asking = new(StringComparer.Ordinal);
    private readonly Dictionary<string, Timer> _timers = new(StringComparer.Ordinal);

    /// Monotonic clock in seconds (replaceable in tests).
    public Func<double> Clock { get; set; } = DefaultClock;

    /// Whether background timers fire `Tick` automatically (set false in deterministic unit tests).
    public bool UsesTimers { get; set; } = true;

    /// Raised with the profile name whenever that profile's effective mood changes.
    public event Action<string>? Changed;

    private static double DefaultClock() => Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;

    /// The step a tool represents (`null` for empty/whitespace tool names).
    public static BotMood? FromTool(string? raw)
    {
        var name = raw?.Trim();
        if (string.IsNullOrEmpty(name)) return null;
        if (name.StartsWith("functions.", StringComparison.Ordinal))
            name = name["functions.".Length..];
        if (KnownTools.TryGetValue(name, out var known))
            return known;
        if (name.StartsWith("browser_", StringComparison.Ordinal) || name.StartsWith("computer_use", StringComparison.Ordinal))
            return BotMood.Browsing;
        return Guess(name.ToLowerInvariant());
    }

    private static BotMood Guess(string lower)
    {
        var words = new HashSet<string>(StringComparer.Ordinal);
        var start = -1;
        for (var i = 0; i <= lower.Length; i++)
        {
            var isLetter = i < lower.Length && char.IsLetter(lower[i]);
            if (isLetter && start < 0) start = i;
            else if (!isLetter && start >= 0)
            {
                words.Add(lower[start..i]);
                start = -1;
            }
        }
        bool Any(string[] list)
        {
            foreach (var w in list)
                if (words.Contains(w)) return true;
            return false;
        }
        if (Any(SearchWords)) return BotMood.Searching;
        if (Any(MessageWords)) return BotMood.Messaging;
        if (Any(MakeWords)) return BotMood.Making;
        if (Any(WriteWords)) return BotMood.Writing;
        if (Any(ReadWords)) return BotMood.Reading;
        if (Any(BrowseWords)) return BotMood.Browsing;
        return BotMood.Running;
    }

    /// What `profile`'s face acts out now: waiting for you first (`Asking`), then its turn's step, else `null`.
    public BotMood? MoodFor(string profile)
    {
        if (string.IsNullOrEmpty(profile)) return null;
        lock (_lock)
        {
            if (_asking.Contains(profile)) return BotMood.Asking;
            return _states.TryGetValue(profile, out var s) ? s.Mood : null;
        }
    }

    /// When `profile`'s mood began (seconds on `Clock`), or `null` while asking or idle.
    public double? Since(string profile)
    {
        if (string.IsNullOrEmpty(profile)) return null;
        lock (_lock)
        {
            if (_asking.Contains(profile)) return null;
            return _states.TryGetValue(profile, out var s) ? s.Since : null;
        }
    }

    /// Processes a gateway RPC event belonging to `profile`.
    public void Handle(RpcEvent e, string? profile, bool replayed = false) =>
        HandleEvent(e.Type, profile, e.Payload.Str("name"), e.Payload.Str("status"), replayed);

    /// Processes a gateway event type and payload fields directly.
    public void HandleEvent(string type, string? profile, string? toolName = null, string? status = null, bool replayed = false)
    {
        if (string.IsNullOrEmpty(profile)) return;
        if (replayed)
        {
            if (type is "message.complete" or "error") Clear(profile);
            return;
        }
        switch (type)
        {
            case "message.start":
            case "thinking.delta":
            case "reasoning.delta":
            case "reasoning.available":
            case "tool.complete":
                Set(profile, BotMood.Thinking);
                break;
            case "tool.start":
            case "tool.generating":
                if (FromTool(toolName) is { } mood) Set(profile, mood);
                break;
            case "message.delta":
                Set(profile, BotMood.Replying);
                break;
            case "message.complete":
                var st = status ?? "";
                if (st == "interrupted") Clear(profile);
                else Once(profile, st.Contains("error", StringComparison.OrdinalIgnoreCase) ? BotMood.Failed : BotMood.Done);
                break;
            case "error":
                Once(profile, BotMood.Failed);
                break;
            case "session.interrupt":
                Clear(profile);
                break;
        }
    }

    /// `profile`'s chat waits for an answer or approval (or no longer does).
    public void SetAsking(string profile, bool on)
    {
        if (string.IsNullOrEmpty(profile)) return;
        bool changed;
        lock (_lock)
        {
            var before = _asking.Contains(profile) ? BotMood.Asking : (_states.TryGetValue(profile, out var s) ? s.Mood : (BotMood?)null);
            if (on) _asking.Add(profile);
            else _asking.Remove(profile);
            var after = _asking.Contains(profile) ? BotMood.Asking : (_states.TryGetValue(profile, out var s2) ? s2.Mood : (BotMood?)null);
            changed = before != after;
        }
        if (changed) Notify(profile);
    }

    /// A turn of `profile`'s started: `Thinking`, unless its events already said more.
    public void Started(string profile)
    {
        if (string.IsNullOrEmpty(profile)) return;
        lock (_lock)
        {
            if (_states.ContainsKey(profile)) return;
        }
        Set(profile, BotMood.Thinking);
    }

    /// None of `profile`'s turns runs any more: a working mood goes (a `Done` or `Failed` plays out).
    public void Settle(string profile)
    {
        if (string.IsNullOrEmpty(profile)) return;
        lock (_lock)
        {
            if (!_states.TryGetValue(profile, out var state) || state.Mood.IsOnce()) return;
        }
        Clear(profile);
    }

    /// Sign-out or gateway switch: every mood goes.
    public void Reset()
    {
        List<string> profiles;
        List<Timer> oldTimers;
        lock (_lock)
        {
            profiles = [.. _states.Keys.Union(_asking, StringComparer.Ordinal)];
            _states.Clear();
            _asking.Clear();
            oldTimers = [.. _timers.Values];
            _timers.Clear();
        }
        foreach (var timer in oldTimers) timer.Dispose();
        foreach (var p in profiles) Notify(p);
    }

    /// Directly shows `mood` for `profile` now (demo/preview/tests).
    public void Show(BotMood mood, string profile)
    {
        if (string.IsNullOrEmpty(profile)) return;
        var now = Clock();
        lock (_lock)
        {
            _states[profile] = new State { Mood = mood, Since = now, Heard = now };
            PlanLocked(profile);
        }
        Notify(profile);
    }

    /// Time has passed for `profile`: a held mood takes over, or a once-only / stale mood ends.
    public void Tick(string profile)
    {
        if (string.IsNullOrEmpty(profile)) return;
        var notify = false;
        Timer? oldTimer = null;
        lock (_lock)
        {
            if (_timers.Remove(profile, out var t)) oldTimer = t;
            if (!_states.TryGetValue(profile, out var state)) goto Done;
            var now = Clock();
            if (now < Due(state) - 0.02)
            {
                PlanLocked(profile);
                goto Done;
            }
            if (state.Next is { } next)
            {
                _states[profile] = new State { Mood = next, Since = now, Heard = state.Heard };
                PlanLocked(profile);
                notify = true;
            }
            else
            {
                _states.Remove(profile);
                notify = true;
            }
        }
    Done:
        oldTimer?.Dispose();
        if (notify) Notify(profile);
    }

    private void Set(string profile, BotMood mood)
    {
        var now = Clock();
        var notify = false;
        lock (_lock)
        {
            if (!_states.TryGetValue(profile, out var state))
            {
                _states[profile] = new State { Mood = mood, Since = now, Heard = now };
                PlanLocked(profile);
                notify = true;
            }
            else
            {
                state.Heard = now;
                if (state.Mood == mood)
                {
                    state.Next = null;
                    PlanLocked(profile);
                }
                else if (!state.Mood.IsOnce() && (state.Mood != BotMood.Thinking || mood == BotMood.Thinking) && now - state.Since < Dwell)
                {
                    state.Next = mood;
                    PlanLocked(profile);
                }
                else
                {
                    _states[profile] = new State { Mood = mood, Since = now, Heard = now };
                    PlanLocked(profile);
                    notify = true;
                }
            }
        }
        if (notify) Notify(profile);
    }

    private void Once(string profile, BotMood mood)
    {
        var now = Clock();
        lock (_lock)
        {
            _states[profile] = new State { Mood = mood, Since = now, Heard = now };
            PlanLocked(profile);
        }
        Notify(profile);
    }

    private void Clear(string profile)
    {
        Timer? oldTimer = null;
        bool removed;
        lock (_lock)
        {
            removed = _states.Remove(profile);
            if (_timers.Remove(profile, out var t)) oldTimer = t;
        }
        oldTimer?.Dispose();
        if (removed) Notify(profile);
    }

    private static double Due(State state)
    {
        if (state.Mood.IsOnce()) return state.Since + state.Mood.Length();
        if (state.Next != null) return state.Since + Dwell;
        return state.Heard + StaleSeconds;
    }

    private void PlanLocked(string profile)
    {
        if (_timers.Remove(profile, out var old)) old.Dispose();
        if (!UsesTimers || !_states.TryGetValue(profile, out var state)) return;
        var waitMs = Math.Max(10, (int)Math.Ceiling((Due(state) - Clock()) * 1000.0));
        _timers[profile] = new Timer(_ => Tick(profile), null, waitMs, Timeout.Infinite);
    }

    private void Notify(string profile) => Changed?.Invoke(profile);
}
