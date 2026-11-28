using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Hermes.Core.Questions;

// Pure rules for stream "questions" (HermesKit/Chat/PromptLogic.swift): clarify normalisation, the dock's staging,
// approval expiry, and the password sheets' words.

public static class ClarifyText
{
    public const string RecommendedLabel = "(Recommended)";
    public const int MaxChoiceChars = 8000;

    /// A choice minus a trailing "(Recommended)" (what is sent and what the settled card shows).
    public static string BareChoice(string choice) =>
        choice.EndsWith(RecommendedLabel, StringComparison.Ordinal) ? choice[..^RecommendedLabel.Length].Trim() : choice;

    public static bool IsRecommended(string choice) => BareChoice(choice) != choice;

    /// `normalizeQuestions` (clarify.ts:52-102): non-blank qid and question (trimmed); choices that are non-blank
    /// strings whose bare text is ≤ 8,000 characters (none left → an open question); multi-select only with choices.
    public static IReadOnlyList<ClarifyQuestion> Normalize(JsonNode? questions)
    {
        var output = new List<ClarifyQuestion>();
        if (questions is not JsonArray list) return output;
        foreach (var row in list)
        {
            if (row is not JsonObject) continue;
            var qid = row.Str("qid")?.Trim() ?? "";
            var question = row.Str("question")?.Trim() ?? "";
            if (qid.Length == 0 || question.Length == 0) continue;
            var choices = (row.Arr("choices") ?? [])
                .Select(c => c is JsonValue v && v.TryGetValue(out string? s) ? s : null)
                .Where(c => c != null && c.Trim().Length > 0 && BareChoice(c).Length <= MaxChoiceChars)
                .Select(c => c!).ToList();
            output.Add(new ClarifyQuestion(qid, question, choices.Count == 0 ? null : choices,
                row.Bool("multi_select") == true && choices.Count > 0));
        }
        return output;
    }

    /// A replay's `answers` map: qid → answer (null = skipped). Non-string answers are JSON-encoded.
    public static IReadOnlyDictionary<string, string?> LockedAnswers(JsonNode? value)
    {
        var output = new Dictionary<string, string?>();
        if (value is not JsonObject o) return output;
        foreach (var (qid, answer) in o)
        {
            output[qid] = answer switch
            {
                null => null,
                JsonValue v when v.TryGetValue(out string? s) => s,
                _ => answer.ToJsonString(),
            };
        }
        return output;
    }
}

/// The dock's staging (web `stagedAnswer`, `toggleStage`, `openOther`, `replayStage`, `sentRows`).
public static class ClarifyStaging
{
    private static readonly JsonSerializerOptions Compact = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    /// What one question answers, exactly as the web card sends it (null: unanswered). Multi-select: a JSON array
    /// string of bare picks plus the typed text.
    public static string? StagedAnswer(ClarifyQuestion question, ClarifyStage? stage = null)
    {
        stage ??= ClarifyStage.Empty;
        var hasChoices = question.Choices is { Count: > 0 };
        var draft = stage.Other || !hasChoices ? stage.Draft.Trim() : "";
        if (question.MultiSelect)
        {
            var combined = stage.Choices.Select(ClarifyText.BareChoice).ToList();
            if (draft.Length > 0) combined.Add(draft);
            return combined.Count == 0 ? null : JsonArray(combined);
        }
        if (stage.Choices.Count > 0) return ClarifyText.BareChoice(stage.Choices[0]);
        return draft.Length == 0 ? null : draft;
    }

    /// A tap on a choice: single-select replaces (and closes "Something else"), multi-select toggles.
    public static ClarifyStage Toggle(ClarifyQuestion question, ClarifyStage stage, string choice)
    {
        if (!question.MultiSelect) return new ClarifyStage([choice], stage.Draft, false);
        var next = stage.Choices.ToList();
        if (!next.Remove(choice)) next.Add(choice);
        return stage with { Choices = next };
    }

    /// "Something else": single-select drops the picked choice; multi-select keeps it beside the text.
    public static ClarifyStage OpenOther(ClarifyQuestion question, ClarifyStage stage) =>
        question.MultiSelect ? new ClarifyStage(stage.Choices, stage.Draft, true) : new ClarifyStage([], stage.Draft, true);

    /// A reconnect's already-locked answer shows as picked (null: nothing locked for it).
    public static ClarifyStage? Replay(ClarifyQuestion question, bool locked, string? answer)
    {
        if (!locked || answer == null) return null;
        var answers = new List<string> { answer };
        if (question.MultiSelect && J.Parse(answer) is JsonArray parsed && parsed.All(n => n is JsonValue v && v.TryGetValue(out string? _)))
            answers = parsed.Select(n => n!.GetValue<string>()).ToList();
        var offered = question.Choices ?? [];
        var choices = offered.Where(c => answers.Contains(ClarifyText.BareChoice(c))).ToList();
        var rest = answers.Where(a => !choices.Any(c => ClarifyText.BareChoice(c) == a)).ToList();
        if (choices.Count > 0 && rest.Count == 0) return new ClarifyStage(choices, "", false);
        return new ClarifyStage(choices, string.Join(", ", rest), offered.Count > 0);
    }

    /// The note after Send ("" when skipped, null = no answer); multi-select answers joined with ", ".
    public static IReadOnlyList<SentClarifyRow> SentRows(IReadOnlyList<ClarifyQuestion> questions,
        IReadOnlyDictionary<string, ClarifyStage> stages, bool skipped = false) =>
        questions.Select(q =>
        {
            if (skipped) return new SentClarifyRow(q.Question, "");
            var answer = StagedAnswer(q, stages.GetValueOrDefault(q.Qid));
            if (answer != null && q.MultiSelect && J.Parse(answer) is JsonArray list)
                return new SentClarifyRow(q.Question, string.Join(", ", list.Select(n => J.AsString(n) ?? "")));
            return new SentClarifyRow(q.Question, answer);
        }).ToList();

    /// The draft the dock opens with: replayed locks first, local picks win (web `QuestionPages` initial state).
    public static ClarifyDraft InitialDraft(ClarifyPrompt prompt, ClarifyDraft? saved)
    {
        var stages = new Dictionary<string, ClarifyStage>();
        foreach (var q in prompt.Questions)
        {
            var locked = prompt.LockedAnswers.TryGetValue(q.Qid, out var answer);
            if (Replay(q, locked, answer) is { } stage) stages[q.Qid] = stage;
        }
        foreach (var (qid, stage) in saved?.Stages ?? new Dictionary<string, ClarifyStage>()) stages[qid] = stage;
        var page = Math.Min(Math.Max(0, saved?.Page ?? 0), Math.Max(0, prompt.Questions.Count - 1));
        return new ClarifyDraft(page, stages, saved?.Minimized ?? false);
    }

    /// `JSON.stringify` of a string array (no spaces, `/` unescaped).
    public static string JsonArray(IEnumerable<string> values) => JsonSerializer.Serialize(values.ToArray(), Compact);
}

/// Approval expiry (W:src/approval-expiry.ts).
public static class ApprovalExpiry
{
    public static readonly TimeSpan DefaultTimeout = TimeSpan.FromSeconds(300);
    /// Upper clamp matching Swift's 100-year cap (`PromptLogic.swift`): keeps `TimeSpan.FromSeconds` and
    /// `DateTimeOffset + TimeSpan` safe against extreme remote doubles (e.g. `1e20`, `double.MaxValue`).
    public static readonly TimeSpan MaxTimeout = TimeSpan.FromDays(365 * 100);
    public const string Expired = "Expired";

    /// "Expires within 0:42", "Expires within 4 min", "Expires within 2 h", or "Expired".
    public static string Label(DateTimeOffset seenAt, TimeSpan timeout, DateTimeOffset now)
    {
        var clamped = timeout > MaxTimeout ? MaxTimeout : timeout;
        var left = (long)Math.Ceiling((seenAt + clamped - now).TotalSeconds);
        if (left <= 0) return Expired;
        if (left > 99 * 60) return $"Expires within {(long)Math.Ceiling(left / 3600.0)} h";
        if (left > 90) return $"Expires within {(long)Math.Ceiling(left / 60.0)} min";
        return $"Expires within {left / 60}:{left % 60:00}";
    }

    /// The countdown a card shows: Stale (the estimate ran out on a timeout read before it was due) reads
    /// "Expires within 0:00" until a fresh read agrees.
    public static (string Label, bool Stale) Countdown(DateTimeOffset seenAt, TimeSpan? timeout, DateTimeOffset? readAt,
        DateTimeOffset now)
    {
        if (timeout is not { } t || readAt is not { } read) return ("", false);
        var clamped = t > MaxTimeout ? MaxTimeout : t;
        var due = seenAt + clamped;
        var stale = now >= due && read < due;
        var text = Label(seenAt, clamped, now);
        return (stale && text == Expired ? "Expires within 0:00" : text, stale);
    }

    /// `approvals.timeout` from a `/api/config` answer: absent or non-positive → 300; extreme values clamped to `MaxTimeout`.
    public static TimeSpan Timeout(JsonNode? config) =>
        config.Obj("approvals").Num("timeout") is { } v && double.IsFinite(v) && v > 0
            ? TimeSpan.FromSeconds(Math.Min(v, MaxTimeout.TotalSeconds))
            : DefaultTimeout;
}

/// The words of one value prompt (App/Questions/PromptSheets.swift `PromptSheetCopy`, Mac wording).
public sealed record PromptSheetCopy(string Title, string Text, string? Command, string? CommandMissing, string? Key,
    IReadOnlyList<PromptField> Fields, string Primary, string Decline, string Chip)
{
    public const string HostPhrase = "the computer running Hermes";

    public static PromptSheetCopy Make(ValuePrompt prompt, string? botName = null)
    {
        var p = prompt.Params;
        var named = botName?.Trim() is { Length: > 0 } n ? n : null;
        string bot = named ?? "the bot", botStart = named ?? "The bot", botTitle = named ?? "Your Bot";
        string? NonEmpty(string key) => p.Str(key)?.Trim() is { Length: > 0 } s ? s : null;
        switch (prompt.Kind)
        {
            case PromptKind.Sudo:
            {
                var command = NonEmpty("command");
                return new PromptSheetCopy("Administrator Password",
                    $"Your password is sent to {bot} to run this, and kept for this session.", command,
                    command == null ? $"{botStart} didn’t say which command. Choose Don’t Send if you can’t check it in the conversation." : null,
                    null, [new PromptField(PromptFieldKind.Secure, "sudo password")], "Send", "Don’t Send", "Password requested");
            }
            case PromptKind.Secret:
            {
                var env = NonEmpty("env_var");
                return new PromptSheetCopy($"{botTitle} Needs a Key", NonEmpty("prompt") ?? $"{botStart} needs a key to continue.",
                    null, null, env, [new PromptField(PromptFieldKind.Secure, env ?? "secret value")], "Send", "Don’t Send",
                    env != null ? $"{env} requested" : "Secret requested");
            }
            case PromptKind.VaultUnlock:
            {
                var name = NonEmpty("display_name") ?? NonEmpty("backend");
                var shown = name ?? "your password manager";
                return new PromptSheetCopy($"Unlock {name ?? "Password Manager"}",
                    $"{botStart} wants to sign into a site with a login saved in {shown}. Enter your master password to unlock it for this session — it goes straight to {shown} on {HostPhrase} and is never stored or shown to {bot}.",
                    null, null, null, [new PromptField(PromptFieldKind.Secure, "Master password")], "Unlock", "Keep Locked",
                    name != null ? $"Unlock {name}" : "Unlock password manager");
            }
            case PromptKind.VaultSaveLogin:
            {
                var site = (NonEmpty("site") ?? NonEmpty("origin")) is { } s0
                    ? (s0.StartsWith("www.", StringComparison.OrdinalIgnoreCase) ? s0[4..] : s0) : null;
                var origin = NonEmpty("origin") ?? site ?? "this site";
                return new PromptSheetCopy($"Save Your {site ?? "Site"} Login?",
                    $"{botStart} reached a sign-in page at {origin} and has no login for it. Enter it once here; it is encrypted on {HostPhrase} and filled into the page without {bot} ever seeing the password.",
                    null, null, null,
                    [new PromptField(PromptFieldKind.Username, "you@example.com", "Email or username"),
                     new PromptField(PromptFieldKind.Password, "Password", "Password")],
                    "Save and Sign In", "Don’t Save", site != null ? $"Save login for {site}?" : "Save login?");
            }
            case PromptKind.VaultCode:
            {
                var site = NonEmpty("site");
                return new PromptSheetCopy($"Verification Code for {site ?? "This Site"}",
                    $"{site ?? "The site"} is asking for a one-time code (text message, email or authenticator app). Enter it here and it’s typed into the page; {bot} never sees it.",
                    null, null, null, [new PromptField(PromptFieldKind.Code, "123 456", "Code")], "Enter Code", "Skip",
                    site != null ? $"Code for {site} requested" : "Code requested");
            }
            default:
                return new PromptSheetCopy("", "", null, null, null, [], "", "", "");
        }
    }

    /// What the primary sends for the typed fields, or null while it isn't valid (Q9: disabled while empty). A login is
    /// `{"identifier","password"}` as a JSON string (identifier trimmed); a code drops spaces and dashes.
    public static string? Answer(PromptKind kind, IReadOnlyList<string> values)
    {
        switch (kind)
        {
            case PromptKind.VaultSaveLogin:
            {
                var identifier = values.ElementAtOrDefault(0)?.Trim() ?? "";
                var password = values.ElementAtOrDefault(1) ?? "";
                if (identifier.Length == 0 || password.Length == 0) return null;
                return new JsonObject { ["identifier"] = identifier, ["password"] = password }.ToJsonString();
            }
            case PromptKind.VaultCode:
            {
                var code = new string((values.ElementAtOrDefault(0) ?? "").Where(c => c != ' ' && c != '-' && !char.IsWhiteSpace(c)).ToArray());
                return code.Length == 0 ? null : code;
            }
            default:
            {
                var value = values.ElementAtOrDefault(0) ?? "";
                return value.Length == 0 ? null : value;
            }
        }
    }
}

public enum PromptFieldKind { Secure, Username, Password, Code }

/// One field of a sheet: its kind, placeholder and (for a login) its label.
public sealed record PromptField(PromptFieldKind Kind, string Placeholder, string? Label = null);
