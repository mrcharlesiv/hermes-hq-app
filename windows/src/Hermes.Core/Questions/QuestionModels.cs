using System.Text.Json.Nodes;

namespace Hermes.Core.Questions;

// What a chat shows for its open server requests (HermesKit/Contracts+questions.swift, spec 1x §3.6).

/// A chat waits for the user (spec 1x §3.6): ranks above "Working…" on the Bots row and in the chat's header.
public enum NeedsInput { Approval, Reply, Waiting }

public static class NeedsInputText
{
    public static string StatusText(this NeedsInput n) => n switch
    {
        NeedsInput.Approval => "Waiting for your approval",
        NeedsInput.Reply => "Waiting for your reply",
        _ => "Waiting for you",
    };
}

public enum PromptKind { Approval, Clarify, Sudo, Secret, VaultUnlock, VaultSaveLogin, VaultCode }

public static class PromptKinds
{
    public static PromptKind? FromMethod(string method) => method switch
    {
        "approval" => PromptKind.Approval,
        "clarify" => PromptKind.Clarify,
        "sudo" => PromptKind.Sudo,
        "secret" => PromptKind.Secret,
        "vault.unlock_prompt" => PromptKind.VaultUnlock,
        "vault.save_login" => PromptKind.VaultSaveLogin,
        "vault.code" => PromptKind.VaultCode,
        _ => null,
    };

    public static string Wire(this PromptKind k) => k switch
    {
        PromptKind.Approval => "approval",
        PromptKind.Clarify => "clarify",
        PromptKind.Sudo => "sudo",
        PromptKind.Secret => "secret",
        PromptKind.VaultUnlock => "vault.unlock_prompt",
        PromptKind.VaultSaveLogin => "vault.save_login",
        _ => "vault.code",
    };

    /// Value prompts answer `{value}` and show as a sheet (§4.5).
    public static bool IsValuePrompt(this PromptKind k) => k is not (PromptKind.Approval or PromptKind.Clarify);
}

public enum ApprovalChoice { Once, Session, Always, Deny }

/// Approval card kind (Hermes 0.23.4+): shell command vs sandbox folder (`access`) or website (`network`).
public enum ApprovalKind { Command, Access, Network }

/// Folder access permission level for `ApprovalKind.Access`.
public enum ApprovalAccessLevel { Read, ReadWrite }

public static class ApprovalChoices
{
    public static string Wire(this ApprovalChoice c) => c switch
    {
        ApprovalChoice.Once => "once",
        ApprovalChoice.Session => "session",
        ApprovalChoice.Always => "always",
        _ => "deny",
    };
}

/// One approval as the card shows it (the oldest of the stack is drawn).
public sealed record ApprovalPrompt(string Id, string Command, string Description, bool AllowSession, bool AllowAlways,
    string ClockKey, DateTimeOffset FirstSeen, ApprovalChoice? Answering, bool Leaving)
{
    public ApprovalKind Kind { get; init; } = ApprovalKind.Command;
    public string? Path { get; init; }
    public ApprovalAccessLevel? AccessLevel { get; init; }
    public string? Host { get; init; }
    public string? Label { get; init; }
    public string? Risk { get; init; }
    public bool IsSandbox => Kind is ApprovalKind.Access or ApprovalKind.Network;

    /// A plugin rule's synthetic label (`<tool> (…`) or no command at all: the card shows the description (§4.2).
    /// Sandbox access/network cards show their own structured target fields, not the raw command description (matching Swift).
    public bool ShowsDescription
    {
        get
        {
            if (Kind != ApprovalKind.Command) return false;
            var c = Command.Trim();
            return c.Length == 0 || System.Text.RegularExpressions.Regex.IsMatch(c, @"^<[^>]+> \(");
        }
    }
}

public sealed record ClarifyQuestion(string Qid, string Question, IReadOnlyList<string>? Choices, bool MultiSelect);

/// The open clarify request of a session (one at a time). LockedAnswers: what a reconnect's replay says the gateway
/// already holds, qid → answer (null = skipped).
public sealed record ClarifyPrompt(string Id, IReadOnlyList<ClarifyQuestion> Questions,
    IReadOnlyDictionary<string, string?> LockedAnswers, bool Sending);

/// One question's picks and typed text (web `Stage`).
public sealed record ClarifyStage(IReadOnlyList<string> Choices, string Draft = "", bool Other = false)
{
    public static readonly ClarifyStage Empty = new([], "", false);
}

/// The dock's page and picks for one request, kept in memory by request id until Send / Skip (Q15).
public sealed record ClarifyDraft(int Page, IReadOnlyDictionary<string, ClarifyStage> Stages, bool Minimized = false)
{
    public static readonly ClarifyDraft Empty = new(0, new Dictionary<string, ClarifyStage>());
}

/// One row of the sent-answers note: the question and the answer ("" = Skipped, null = No answer).
public sealed record SentClarifyRow(string Question, string? Answer);

public sealed record SentClarify(string RequestId, IReadOnlyList<SentClarifyRow> Rows);

/// A sudo / secret / vault prompt (§4.5). Params are the request's own (env_var, prompt, backend, site…).
public sealed record ValuePrompt(string Id, PromptKind Kind, JsonObject Params, bool Sending);

/// Everything one chat shows for its open requests.
public sealed record ChatPrompts
{
    public static readonly ChatPrompts None = new();

    /// Oldest first; the card draws the first.
    public IReadOnlyList<ApprovalPrompt> Approvals { get; init; } = [];
    /// How many approvals this stack has held since it was last empty ("1 / 2").
    public int ApprovalStackTotal { get; init; }
    public ClarifyPrompt? Clarify { get; init; }
    /// What the dock last sent for this session, until the clarify tool's settled card arrives.
    public SentClarify? SentClarify { get; init; }
    /// A clarify tool runs but its question never reached the app (§3.5).
    public bool ClarifyUndelivered { get; init; }
    public IReadOnlyList<ValuePrompt> Values { get; init; } = [];

    public bool IsEmpty => Approvals.Count == 0 && Clarify == null && SentClarify == null && !ClarifyUndelivered && Values.Count == 0;

    /// The header and Bots-row words (§3.6, Q11): any approval or value prompt → approval; a clarify → reply.
    public NeedsInput? NeedsInput =>
        Approvals.Any(a => !a.Leaving) || Values.Count > 0 ? Questions.NeedsInput.Approval
        : Clarify != null ? Questions.NeedsInput.Reply : null;
}

/// Why an answer didn't go out, in the user's words (§4.7). The entry stays open. Offline: no socket, offer Reconnect.
public sealed class PromptAnswerException(string message, bool offline) : Exception(message)
{
    public bool Offline { get; } = offline;
}

/// A request the app holds, as an alert reads it: its id, kind, runtime session, params, and its chat's bot and stored id
/// when known.
public sealed record HeldRequest(string Id, PromptKind Kind, string SessionId, System.Text.Json.Nodes.JsonObject Params, string? Profile,
    string? StoredId);

/// What Approve Once / Deny on a local alert came to (ServerRequests.swift AlertAnswer): sent, or the request is gone
/// (answered elsewhere, expired, or it never reached this computer).
public enum AlertAnswer { Sent, Gone }
