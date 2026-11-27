using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace Hermes.Core.Gateways;

/// The chat left on show and where it was opened from (HermesKit/Store/LaunchChatMemory.swift `RememberedChat`). On
/// Windows the sidebar's bots are the Mac's Bots origin and everything else opened a listed chat (Sessions).
public sealed record RememberedChat(string Origin, string Profile, string? StoredId, bool BotChat, string? Title = null)
{
    public const string Bots = "bots", Sessions = "sessions";
}

/// Why a launch did or did not put the last chat back. The reasons go into the log.
public sealed record LaunchChatDecision(RememberedChat? Reopen, string? Skip)
{
    public const string Nothing = "no chat was on show";
    public const string Crashed = "the last run ended with that chat on screen";
    public const string ResumeOff = "Reopen last chat on launch is off";
    public const string BotGone = "its bot is gone";
    public const string SessionGone = "its chat is no longer listed";

    /// `bot(profile)`: the bot exists; `listed(profile, id)`: the gateway still lists that chat for that bot.
    public static LaunchChatDecision Decide(RememberedChat? chat, bool crashed, bool resume, Func<string, bool> bot,
        Func<string, string, bool> listed)
    {
        if (chat == null) return new(null, Nothing);
        if (crashed) return new(null, Crashed);
        if (!resume) return new(null, ResumeOff);
        if (chat.BotChat) return bot(chat.Profile) ? new(chat, null) : new(null, BotGone);
        if (chat.StoredId is not { Length: > 0 } id || !listed(chat.Profile, id)) return new(null, SessionGone);
        return new(chat, null);
    }
}

/// The remembered chat (per account), the reopen preference (per account) and the "chat on screen" marker, in one
/// small JSON file (the Mac keeps them in UserDefaults under `launchChat.`). A marker still set at launch means the run
/// before ended (a crash, or killed) with that chat on screen: it isn't reopened, so a chat that crashes the app on its
/// data can't do it again at every launch.
public sealed class LaunchChatMemory
{
    private sealed class State
    {
        [JsonPropertyName("chats")] public Dictionary<string, RememberedChat> Chats { get; set; } = [];
        [JsonPropertyName("resume")] public Dictionary<string, bool> Resume { get; set; } = [];
        [JsonPropertyName("onScreen")] public string? OnScreen { get; set; }
    }

    private readonly string? _path;
    private readonly object _gate = new();
    private State _state;
    private bool _launched;
    private readonly HashSet<string> _crashed = [];

    /// `path` null: memory only (tests).
    public LaunchChatMemory(string? path)
    {
        _path = path;
        _state = Load();
    }

    private State Load()
    {
        if (_path == null) return new State();
        try { return JsonSerializer.Deserialize<State>(File.ReadAllText(_path)) ?? new State(); }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { return new State(); }
    }

    private void Save()
    {
        if (_path == null) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            File.WriteAllText(_path, JsonSerializer.Serialize(_state));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    /// First thing at launch, before this run can set the marker.
    public void Launch()
    {
        lock (_gate)
        {
            if (_launched) return;
            _launched = true;
            if (_state.OnScreen is not { } account) return;
            _state.OnScreen = null;
            _state.Chats.Remove(account);
            _crashed.Add(account);
            Save();
        }
    }

    public bool CrashedFor(string account) { lock (_gate) return _crashed.Contains(account); }

    public RememberedChat? Recall(string account) { lock (_gate) return _state.Chats.GetValueOrDefault(account); }

    /// The screen on show for `account`: the chat (or null). While the app is in front a chat on show also sets the
    /// marker, which leaving the app clears.
    public void Remember(RememberedChat? chat, string account, bool foreground)
    {
        lock (_gate)
        {
            var changed = false;
            if (chat != null)
            {
                if (_state.Chats.GetValueOrDefault(account) != chat) { _state.Chats[account] = chat; changed = true; }
            }
            else changed |= _state.Chats.Remove(account);
            var marker = chat != null && foreground ? account : null;
            if (_state.OnScreen != marker) { _state.OnScreen = marker; changed = true; }
            if (changed) Save();
        }
    }

    /// The app closed cleanly: no screen of this run counts as crashed.
    public void Closed()
    {
        lock (_gate)
        {
            if (_state.OnScreen == null) return;
            _state.OnScreen = null;
            Save();
        }
    }

    /// `display.resume_last_session` as last read from `account`'s gateway; on until read off.
    public bool Resume(string account) { lock (_gate) return _state.Resume.GetValueOrDefault(account, true); }

    public void SetResume(bool on, string account)
    {
        lock (_gate)
        {
            if (_state.Resume.TryGetValue(account, out var was) && was == on) return;
            _state.Resume[account] = on;
            Save();
        }
    }

    /// From a `GET /api/config` answer: only `false` turns it off (the web's `!== false`).
    public static bool ResumeFrom(JsonNode? config) =>
        !(config.Obj("display")?.Get("resume_last_session") is JsonValue v && v.TryGetValue(out bool b) && !b);

    /// Sign Out and Remove Gateway: the account's remembered chat and preference go.
    public void Forget(string account)
    {
        lock (_gate)
        {
            _state.Chats.Remove(account);
            _state.Resume.Remove(account);
            if (_state.OnScreen == account) _state.OnScreen = null;
            Save();
        }
    }
}
