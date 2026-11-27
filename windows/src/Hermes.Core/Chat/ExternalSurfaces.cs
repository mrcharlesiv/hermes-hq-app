// [WIN-EXTERNAL-SURFACES] Another Hermes process's turn beyond the chat header, as the Mac at 93f984bb1:
// App/AppModel.swift `onRunningChange`/`onExternalWorkChange` (setWorking(running || chat.externalWorking); working ||
// chat.reportsRunning) feed the bot row and the Sessions row; App/Chat/ChatViewController.swift hands ChatRowBuilder
// isRunning (session.isRunning || externalWorking) && !ownerWaiting and input.externalWorking = externalWorking &&
// !ownerWaiting; App/Chat/ChatRow.swift `oneLineRow` and App/Chat/ProgressNotes.swift `working(at:)` give the live step
// line to the last row only (`externalTail`). The pure rules live here; the app wires them.
namespace Hermes.Core.Chat;

public static class ExternalSurfaces
{
    /// The bot row and the Sessions row show Working… while a turn of ours or another process's runs (`setWorking`).
    public static bool RowsWorking(bool running, bool external) => running || external;

    /// The transcript's turn: another process's turn draws as one of ours, but not while a send waits for the chat's
    /// owner (`ownerWaitKind`, Windows' WaitingForOwner): that send hasn't reached the model.
    public static TranscriptTurn Transcript(bool running, bool external, bool ownerWaiting) =>
        new((running || external) && !ownerWaiting, external && !ownerWaiting);
}

/// What the transcript's rows read of the running turn (ChatRowBuilder.Input's isRunning and externalWorking).
public readonly record struct TranscriptTurn(bool Running, bool External)
{
    /// The other process's turn is the chat's last row: it carries the live step line (`externalTail`).
    public bool ExternalTail(int index, int count) => External && count > 0 && index == count - 1;

    /// A row's live step line and progress notes (StepRules.isWorking, `working(at:)`): it streams, or the chat runs and
    /// it is the newest reply after the last prompt, or it is the other process's tail.
    public bool Working(bool streaming, int index, int count, int lastUser, int lastAssistant) =>
        streaming || (Running && index > lastUser && index == lastAssistant) || ExternalTail(index, count);
}

/// The chats this device knows are working (the Mac's TurnWorking for the rows): by bot, and by stored id for the
/// Sessions rows. A chat with no stored id yet counts for its bot only.
public sealed class ChatsWorking
{
    private const string NoId = "\0new";
    private readonly object _gate = new();
    private readonly Dictionary<string, HashSet<string>> _byProfile = [];

    /// True when it changed.
    public bool Set(string profile, string? storedId, bool working)
    {
        var key = string.IsNullOrEmpty(storedId) ? NoId : storedId;
        lock (_gate)
        {
            if (working)
            {
                if (!_byProfile.TryGetValue(profile, out var set)) _byProfile[profile] = set = [];
                return set.Add(key);
            }
            if (!_byProfile.TryGetValue(profile, out var had) || !had.Remove(key)) return false;
            if (had.Count == 0) _byProfile.Remove(profile);
            return true;
        }
    }

    /// [WIN-OWN-TURN-ROWS] A working chat of `profile` got its stored id (or the resume named another): the turn counts
    /// under it from now on, so its end (said under the new id) clears it (TurnWorking.resolved). False when nothing of
    /// the bot was working under `from`.
    public bool Move(string profile, string? from, string to)
    {
        var key = string.IsNullOrEmpty(from) ? NoId : from;
        lock (_gate)
        {
            if (key == to || !_byProfile.TryGetValue(profile, out var set) || !set.Remove(key)) return false;
            set.Add(to);
            return true;
        }
    }

    /// [WIN-OWN-TURN-ROWS] Nothing works any more (the account went): the bots that had working chats.
    public List<string> Clear()
    {
        lock (_gate)
        {
            var had = _byProfile.Keys.ToList();
            _byProfile.Clear();
            return had;
        }
    }

    public bool Busy(string profile) { lock (_gate) return _byProfile.ContainsKey(profile); }

    /// The bot's working chats (`turnWorking.busy(profile)`).
    public IReadOnlySet<string> Chats(string profile)
    {
        lock (_gate) return _byProfile.TryGetValue(profile, out var set) ? [.. set] : new HashSet<string>();
    }

    /// Every working chat's stored id (`runningSessions`).
    public IReadOnlySet<string> StoredIds
    {
        get { lock (_gate) return _byProfile.Values.SelectMany(s => s).Where(id => id != NoId).ToHashSet(); }
    }
}
