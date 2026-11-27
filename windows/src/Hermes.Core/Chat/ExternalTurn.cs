// [WIN-EXTERNAL-TURN] A turn another Hermes process runs in this chat (93f984bb1 HermesKit/Chat/ExternalTurn.swift,
// docs/spec/03-chat-history.md §4.8).
//
// A message from another bot (`message_agent`), a Telegram or Discord message, or a job's hand-off runs in the messaging
// gateway (`hermes gateway run`), not in `hermes serve`, which the app talks to: `session.resume` says `running: false`,
// no turn frames come, and the chat looked idle while the bot worked for minutes. Two signals say otherwise:
//   - the gateway's durable ledger holds the work until it ends; the Hermes HQ add-on (0.9.6+, `GET sessions/working`)
//     reads it for the app. Authoritative when present.
//   - without that add-on, the stored rows: the gateway writes each step as it goes, so a newest turn that ends on a
//     tool step (no words after it), or a stored prompt nobody answered yet, written recently, is still running.
// The watch that asks them is ChatSession+External.cs.

using System.Collections.Concurrent;
using System.Text.Json.Nodes;
using Hermes.Core.Model;

namespace Hermes.Core.Chat;

public static class ExternalTurn
{
    /// Where the "still running" came from.
    public enum Source { Ledger, History }

    /// The add-on's answer for this chat: working (or not), missing (404: no add-on, or one older than 0.9.6), failed.
    public enum LedgerKind { Working, Idle, Missing, Failed }

    public const string LedgerPath = "/api/plugins/hermes-hq-push/sessions/working";
    /// The header's words while another process's turn runs (the same word as ours).
    public const string StatusWords = "Working…";
    /// A tool step with nothing after it counts as running this long after the newest stored row (a terminal command or
    /// a slow search writes nothing until it returns).
    public static readonly TimeSpan ToolWindow = TimeSpan.FromSeconds(600);
    /// A stored prompt with no answer counts as running this long (the gateway writes its first step within seconds).
    public static readonly TimeSpan PromptWindow = TimeSpan.FromSeconds(120);
    /// How often the transcript and the ledger are read while the other process works (ChatSession.ExternalPollInterval).
    public static readonly TimeSpan DefaultPollInterval = TimeSpan.FromSeconds(3);
    /// A 404 is believed this long before the add-on is asked again (it may be updated meanwhile).
    public static readonly TimeSpan MissingRecheck = TimeSpan.FromSeconds(600);

    /// Accounts whose add-on lacks the route, with when that was learned (`ledgerMissingSince`).
    internal static readonly ConcurrentDictionary<string, DateTimeOffset> LedgerMissingSince = new();

    /// Forgets every account's 404 (tests; an add-on update).
    public static void ForgetMissingLedgers() => LedgerMissingSince.Clear();

    /// The newest stored turn is still being written: its newest message (our own prompts aside) is a stored prompt
    /// with no answer, or the bot's steps with no words after the last one; and the newest stored row is recent.
    public static bool HistoryUnfinished(IReadOnlyList<ChatMessage> messages, DateTimeOffset? newestStoredAt, DateTimeOffset now)
    {
        if (newestStoredAt is not { } newest) return false;
        // Our own bubbles aside (a send waiting behind that turn); our own live reply still counts, so a turn of ours
        // that just ended in words never reads as unfinished.
        ChatMessage? last = null;
        for (var i = messages.Count - 1; i >= 0; i--)
        {
            var m = messages[i];
            if (m.Id.StartsWith("local-", StringComparison.Ordinal) && m.Role == Role.User) continue;
            last = m;
            break;
        }
        if (last == null) return false;
        var age = now - newest;
        switch (last.Role)
        {
            case Role.User:
                return age < PromptWindow;
            case Role.Assistant:
                if (last.Error != null || last.Interrupted) return false;
                // The last part a reader sees: words or a thought with something in them, or a step (a generated
                // picture stands in for its step). Photos and files carry no words: they are passed over, as the Mac's
                // parts (which hold none) do.
                ChatPart? visible = null;
                for (var i = last.Parts.Count - 1; i >= 0 && visible == null; i--)
                {
                    visible = last.Parts[i] switch
                    {
                        TextPart t when t.Text.Trim().Length > 0 => t,
                        ReasoningPart r when r.Text.Trim().Length > 0 => r,
                        ToolPart or GeneratedImagePart => last.Parts[i],
                        _ => null,
                    };
                }
                return visible switch
                {
                    ToolPart or GeneratedImagePart or ReasoningPart => age < ToolWindow,
                    _ => false,
                };
            default:
                // A notice ([SILENT], a model switch, a failed turn) ends what came before it.
                return false;
        }
    }

    /// `{"sessions": [{"profile", "id", "status", "kind"}]}` → whether any row names one of `ids` (for `profile`).
    public static bool LedgerNames(JsonNode? json, IReadOnlyCollection<string> ids, string profile)
    {
        var want = profile.Length == 0 ? "default" : profile;
        if (json?["sessions"] is not JsonArray rows) return false;
        foreach (var row in rows)
        {
            if (row.Text("id") is not { } id || !ids.Contains(id)) continue;
            var p = row.Text("profile") ?? "";
            if (p.Length == 0 || p == want) return true;
        }
        return false;
    }
}
