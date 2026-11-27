// [WIN-ROWS-STEP-WALK] What the row-steps walk (HermesHQ.Windows/Services/ProofWalks.RowSteps.cs) asks the stand-in for
// and checks on the real rows, against windows/ci/fixtures/settings-gateway.py (its turns held on one step with
// /__settings/hold until /__settings/release; one bot's session.resume slowed with /__settings/fail mode slow). The
// words are the Mac's (93f984bb1):
//   HermesKit/Activity/LiveSteps.swift `line`, ToolNow.swift `phrase`  "Reading package.json…", "Running npm test…"
//   App/Bots/BotListModel.swift `secondLine` (.waking)                  "Waking up…" (BotStore+RowStatus noteBotOpening)
//   App/Bots/BotListModel.swift, SessionListPipeline.swift              a working row's "Working…"
// A Bot Chat never shows on Sessions (§9.2), so the bot row's step comes from ivy's own Bot Chat and the Sessions row's
// from one of ivy's side chats ("Trip ideas"): each chat's own step, never the other's. Each check answers null when
// right, else what is wrong.

using System.Text.Json.Nodes;
using Hermes.Core.Activity;

namespace Hermes.Core.Shell;

public static class RowStepsWalkProof
{
    public const string Walk = "row-steps";
    /// The stand-in's tag in windows.yml's screenshot extras.
    public const string Tag = "row-steps";

    public const string Bot = "ivy";
    public const string BotName = "Ivy";
    /// One of ivy's chats that isn't its Bot Chat: Sessions lists it (the stand-in's seed).
    public const string SideTitle = "Trip ideas";
    /// The bot whose chat opens slowly.
    public const string WakingBot = "research";
    public const string WakingName = "Research";

    public const string StatePath = "/__settings/state";
    public const string HoldPath = "/__settings/hold";
    public const string ReleasePath = "/__settings/release";
    public const string FailPath = "/__settings/fail";

    public const string BotsShot = "row-step-bots";
    public const string SessionsShot = "row-step-sessions";
    public const string WakingShot = "row-waking";
    /// The walk's own picture (windows.yml wants one per walk name): Research's chat open, its row settled.
    public const string FinalShot = Walk;
    public static readonly IReadOnlyList<string> Shots = [BotsShot, SessionsShot, WakingShot];

    // ------------------------------------------------------------------ the Mac's words

    public const string BotLine = "Reading package.json…";
    public const string SideLine = "Running npm test…";
    public const string Working = "Working…";
    public const string Waking = "Waking up…";

    // ------------------------------------------------------------------ what is sent (synthetic)

    public const string BotText = "Synthetic check of the package file";
    public const string SideText = "Synthetic test run for the trip list";
    /// How long Research's resume takes: past the Mac's 1 s grace with room for the picture.
    public const double SlowOpenSeconds = 6;

    public static JsonObject BotStep() => new() { ["name"] = "read_file", ["args"] = new JsonObject { ["path"] = "/Users/me/app/package.json" } };
    public static JsonObject SideStep() => new() { ["name"] = "terminal", ["args"] = new JsonObject { ["command"] = "cd /Users/me/app && npm test" } };

    /// The held turns' steps, one per turn in order: the Bot Chat's turn first, then the side chat's.
    public static string HoldBody() => new JsonObject { ["steps"] = new JsonArray(BotStep(), SideStep()) }.ToJsonString();
    public static string ReleaseBody() => "{}";

    public static string SlowOpenBody() => new JsonObject
    {
        ["method"] = "session.resume", ["mode"] = "slow", ["seconds"] = SlowOpenSeconds, ["profile"] = WakingBot, ["count"] = 1,
    }.ToJsonString();

    /// A `tool.start` payload's words as a row's live line (Hermes.Core's port of the Mac's LiveSteps and ToolNow).
    public static string StepLine(JsonObject step) =>
        LiveSteps.Line(LiveSteps.Phrase(step["name"]!.GetValue<string>(), step, []));

    /// The Mac's words written here agree with what ToolNow makes of the stand-in's calls.
    public static string? Lines()
    {
        if (StepLine(BotStep()) is var b && b != BotLine) return $"words: the Bot Chat's step reads \"{b}\", not \"{BotLine}\"";
        if (StepLine(SideStep()) is var s && s != SideLine) return $"words: the side chat's step reads \"{s}\", not \"{SideLine}\"";
        return null;
    }

    // ------------------------------------------------------------------ the stand-in's record

    /// GET /__settings/state's `held`: the turns holding on their step now.
    public static string? Held(JsonNode state, int count)
    {
        if (state["held"] is not JsonValue v || !v.TryGetValue<int>(out var held)) return "stand-in: no held count";
        return held == count ? null : $"stand-in: {held} turns held, not {count}";
    }

    /// The stand-in took each prompt once, in its own chat: the Bot Chat's words in the Bot Chat, the side chat's there.
    public static string? Prompts(JsonNode state, string botChatId, string sideChatId)
    {
        var prompts = state["prompts"]?.AsArray().OfType<JsonObject>().ToList() ?? [];
        string? Once(string text, string session, string where)
        {
            var sent = prompts.Where(p => p["text"]?.GetValue<string>() == text).ToList();
            if (sent.Count == 0) return $"stand-in: no prompt \"{text}\"";
            if (sent.Count > 1) return $"stand-in: \"{text}\" sent {sent.Count} times";
            var to = sent[0]["session"]?.GetValue<string>();
            return to == session ? null : $"stand-in: \"{text}\" went to {to}, not {where} ({session})";
        }
        return Once(BotText, botChatId, "the Bot Chat") ?? Once(SideText, sideChatId, SideTitle);
    }

    /// Research's slow resume was taken (the armed failure's count is spent).
    public static string? SlowOpenTaken(JsonNode state)
    {
        var armed = state["fail"]?.AsArray().OfType<JsonObject>()
            .LastOrDefault(f => f["method"]?.GetValue<string>() == "session.resume" && f["profile"]?.GetValue<string>() == WakingBot);
        if (armed == null) return "stand-in: no slow resume armed for " + WakingBot;
        var left = armed["count"]?.GetValue<int>() ?? -1;
        return left == 0 ? null : $"stand-in: the slow resume isn't taken ({left} left)";
    }

    // ------------------------------------------------------------------ the rows as drawn

    /// A bot's row (the sidebar): its accessible name is "<bot>. <line> …" (BotList.AccessibilityLabel) and its second
    /// line draws `line` exactly.
    public static string? BotRow(string? name, IReadOnlyList<string> texts, string bot, string line)
    {
        if (name == null) return $"{bot}: no row";
        if (!name.StartsWith(bot + ". ", StringComparison.Ordinal)) return $"{bot}: the row is \"{name}\"";
        if (!name.StartsWith($"{bot}. {line}", StringComparison.Ordinal)) return $"{bot}: the row reads \"{name}\", not \"{line}\"";
        if (!texts.Contains(line)) return $"{bot}: \"{line}\" isn't drawn on the row (it draws {Quoted(texts)})";
        return null;
    }

    /// The bot's row after: neither `line` nor Working… (read or drawn).
    public static string? BotRowSettled(string? name, IReadOnlyList<string> texts, string bot, string line)
    {
        if (name == null) return $"{bot}: no row";
        if (name.Contains(line, StringComparison.Ordinal) || texts.Contains(line)) return $"{bot}: the row still says \"{line}\"";
        if (name.StartsWith($"{bot}. {Working}", StringComparison.Ordinal) || texts.Contains(Working)) return $"{bot}: the row still says {Working}";
        return null;
    }

    /// A Sessions row: its accessible name is "<title>. <line without …>. …" (SessionRowWords.AccessibilityLabel) and its
    /// second line ends with `line` ("<owner> · <line>", or the line alone in Recent rows).
    public static string? SessionRow(string? name, IReadOnlyList<string> texts, string title, string line)
    {
        if (name == null) return $"{title}: no row";
        var spoken = line.Replace("…", "");
        if (!name.StartsWith($"{title}. {spoken}.", StringComparison.Ordinal) && name != $"{title}. {spoken}")
            return $"{title}: the row reads \"{name}\", not \"{spoken}\"";
        if (!texts.Any(t => t == line || t.EndsWith(" · " + line, StringComparison.Ordinal)))
            return $"{title}: \"{line}\" isn't drawn on the row (it draws {Quoted(texts)})";
        return null;
    }

    /// The Sessions row after: neither `line` nor Working… (read or drawn).
    public static string? SessionRowSettled(string? name, IReadOnlyList<string> texts, string title, string line)
    {
        if (name == null) return $"{title}: no row";
        var spoken = line.Replace("…", "");
        if (name.Contains(spoken, StringComparison.Ordinal) || texts.Any(t => t.EndsWith(line, StringComparison.Ordinal)))
            return $"{title}: the row still says \"{line}\"";
        var working = Working.Replace("…", "");
        if (name.StartsWith($"{title}. {working}.", StringComparison.Ordinal) || texts.Any(t => t.EndsWith(Working, StringComparison.Ordinal)))
            return $"{title}: the row still says {Working}";
        return null;
    }

    private static string Quoted(IReadOnlyList<string> texts) => texts.Count == 0 ? "nothing" : string.Join(", ", texts.Select(t => $"\"{t}\""));
}
