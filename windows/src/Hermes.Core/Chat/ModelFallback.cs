using System.Globalization;
using System.Text.RegularExpressions;
using Hermes.Core.Composer;
using Hermes.Core.Gateways;

namespace Hermes.Core.Chat;

/// Why the primary model failed (`ModelFallback.Category`, HermesKit/Contracts+sessions.swift).
public enum ModelFallbackCategory
{
    Auth,
    Billing,
    NotFound,
    RateLimit,
    Busy,
    Timeout,
    Other,
}

/// The gateway answered with another model (port of HermesKit/Contracts+sessions.swift `ModelFallback`).
public sealed record ModelFallback(
    string Primary,
    string Fallback,
    string? Reason = null,
    string? PrimaryProvider = null,
    string? FallbackProvider = null,
    string RawText = "",
    int? RetryAfterSeconds = null,
    bool IsProviderShape = false)
{
    private static readonly Regex ModelLead = new(@"Model fallback:\s*(\S+)\s+via\s+(\S+)\s+", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    private static readonly Regex UsingTail = new(@"^(\S+)(?:\s+via\s+(\S+?))?(?:\.(?:\s|$)|\s*$)", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    private static readonly Regex RetryIn = new(@"Primary retry eligible in\s*~?(\d+)\s*s\b", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    private static readonly Regex ProviderRx = new(
        @"Provider fallback:\s*(\S+)\s+(?:unavailable|could not respond|failed)(?:\s+\(([\s\S]*)\))?;\s*using\s+(\S+?)(?:\s+for this response|\.(?:\s|$)|\s|$)",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);
    private static readonly Regex HttpCodeRx = new(@"\bHTTP\s+(\d{3})\b", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    private static readonly Regex EnvVarRx = new(@"\b[A-Z][A-Z0-9_]{4,}\b", RegexOptions.Compiled);

    private static readonly string[] AuthKeywords = ["auth", "401", "403", "login", "oauth", "api key", "credential", "unauthorized", "setup-token"];
    private static readonly string[] BillingKeywords = ["billing", "quota", "credit", "insufficient", "402", "payment"];
    private static readonly string[] NotFoundKeywords = ["not found", "404", "unknown model", "does not exist", "invalid model", "unsupported"];
    private static readonly string[] RateLimitKeywords = ["rate", "429", "too many requests", "limit"];
    private static readonly string[] BusyKeywords = ["overload", "busy", "529", "503", "capacity"];
    private static readonly string[] TimeoutKeywords = ["timeout", "timed out", "server error", "500", "502", "504", "connection"];

    /// Parses the gateway's status line (both "Model fallback:" and "Provider fallback:" shapes); null for anything else.
    /// Splits on `; using ` first so reasons containing nested or truncated parentheses still parse cleanly.
    public static ModelFallback? Parse(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;

        var modelAt = text.IndexOf("Model fallback:", StringComparison.OrdinalIgnoreCase);
        if (modelAt >= 0)
        {
            var usingAt = text.IndexOf("; using ", modelAt + "Model fallback:".Length, StringComparison.OrdinalIgnoreCase);
            if (usingAt >= 0)
            {
                var left = text[modelAt..usingAt];
                var right = text[(usingAt + "; using ".Length)..].Trim();
                var lead = ModelLead.Match(left);
                var tail = UsingTail.Match(right);
                if (lead.Success && tail.Success && lead.Groups[1].Value.Length > 0 && tail.Groups[1].Value.Length > 0)
                {
                    var primary = lead.Groups[1].Value;
                    var primaryProvider = lead.Groups[2].Value.Length > 0 ? lead.Groups[2].Value : null;
                    var fallback = tail.Groups[1].Value.Trim('.', ',', ';');
                    var fallbackProviderRaw = tail.Groups[2].Success ? tail.Groups[2].Value.Trim('.', ',', ';') : "";
                    var fallbackProvider = fallbackProviderRaw.Length > 0 ? fallbackProviderRaw : null;
                    var afterLead = left[(lead.Index + lead.Length)..].Trim();
                    var reason = ExtractReason(afterLead);
                    int? retry = RetryIn.Match(right) is { Success: true } rm
                        && int.TryParse(rm.Groups[1].Value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var s)
                        ? (int?)s : null;
                    return new ModelFallback(
                        Primary: primary,
                        Fallback: fallback,
                        Reason: reason,
                        PrimaryProvider: primaryProvider,
                        FallbackProvider: fallbackProvider,
                        RawText: text.Trim(),
                        RetryAfterSeconds: retry,
                        IsProviderShape: false);
                }
            }
        }

        var pm = ProviderRx.Match(text);
        if (pm.Success && pm.Groups[1].Value.Length > 0 && pm.Groups[3].Value.Length > 0)
        {
            var reason = pm.Groups[2].Success ? pm.Groups[2].Value.Trim() : "";
            int? retry = RetryIn.Match(text) is { Success: true } rm
                && int.TryParse(rm.Groups[1].Value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var s)
                ? (int?)s : null;
            return new ModelFallback(
                Primary: pm.Groups[1].Value,
                Fallback: pm.Groups[3].Value.Trim('.', ',', ';'),
                Reason: reason.Length > 0 ? reason : null,
                PrimaryProvider: null,
                FallbackProvider: null,
                RawText: text.Trim(),
                RetryAfterSeconds: retry,
                IsProviderShape: true);
        }

        return null;
    }

    private static string? ExtractReason(string statusAndReason)
    {
        var open = statusAndReason.IndexOf('(');
        if (open < 0) return null;
        var inner = statusAndReason[(open + 1)..].Trim();
        if (inner.EndsWith(')')) inner = inner[..^1].Trim();
        return inner.Length == 0 ? null : inner;
    }

    /// "Primary model restored:" ends a fallback.
    public static bool Restores(string? text) =>
        !string.IsNullOrEmpty(text) && text.Contains("Primary model restored:", StringComparison.Ordinal);

    /// The model id named after "Primary model restored:"; empty string when none is named; null for any other line.
    public static string? RestoredModel(string? text)
    {
        if (string.IsNullOrEmpty(text)) return null;
        const string lead = "Primary model restored:";
        var at = text.IndexOf(lead, StringComparison.Ordinal);
        if (at < 0) return null;
        var rest = text[(at + lead.Length)..];
        var first = rest.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? "";
        return first.Trim('.', ',', ';');
    }

    /// Classifies why the primary model failed so the timeline can separate actionable issues from transient blips.
    public ModelFallbackCategory Category
    {
        get
        {
            var lower = (Reason ?? "").ToLowerInvariant();
            if (AuthKeywords.Any(k => lower.Contains(k, StringComparison.Ordinal))) return ModelFallbackCategory.Auth;
            if (BillingKeywords.Any(k => lower.Contains(k, StringComparison.Ordinal))) return ModelFallbackCategory.Billing;
            if (NotFoundKeywords.Any(k => lower.Contains(k, StringComparison.Ordinal))) return ModelFallbackCategory.NotFound;
            if (RateLimitKeywords.Any(k => lower.Contains(k, StringComparison.Ordinal))) return ModelFallbackCategory.RateLimit;
            if (BusyKeywords.Any(k => lower.Contains(k, StringComparison.Ordinal))) return ModelFallbackCategory.Busy;
            if (TimeoutKeywords.Any(k => lower.Contains(k, StringComparison.Ordinal))) return ModelFallbackCategory.Timeout;
            return ModelFallbackCategory.Other;
        }
    }

    /// Persistent or user-fixable issues warrant a compact inline card; transient blips stay a quiet one-line pill.
    public bool IsActionable => Category switch
    {
        ModelFallbackCategory.Auth or ModelFallbackCategory.Billing or ModelFallbackCategory.NotFound => true,
        ModelFallbackCategory.RateLimit or ModelFallbackCategory.Busy or ModelFallbackCategory.Timeout => false,
        _ => ExtractedCommands.Count > 0,
    };

    /// An HTTP status code mentioned in the reason (e.g. "HTTP 401"), if any.
    public string? HttpStatus =>
        Reason is { Length: > 0 } r && HttpCodeRx.Match(r) is { Success: true } m && m.Groups[1].Value.Length > 0
            ? $"HTTP {m.Groups[1].Value}"
            : null;

    /// Complete CLI commands enclosed in backticks inside `Reason` (skipping truncated `...` snippets).
    public IReadOnlyList<string> ExtractedCommands
    {
        get
        {
            if (string.IsNullOrEmpty(Reason)) return [];
            var out_ = new List<string>();
            var index = 0;
            while (index < Reason.Length)
            {
                var open = Reason.IndexOf('`', index);
                if (open < 0) break;
                var start = open + 1;
                var close = Reason.IndexOf('`', start);
                if (close < 0) break;
                var candidate = Reason[start..close].Trim();
                if (candidate.Length > 0
                    && !candidate.EndsWith("...", StringComparison.Ordinal)
                    && !candidate.EndsWith('…')
                    && !(candidate.Contains('_') && !candidate.Contains(' ') && EnvVarRx.IsMatch(candidate))
                    && !out_.Contains(candidate, StringComparer.Ordinal))
                    out_.Add(candidate);
                index = close + 1;
            }
            return out_;
        }
    }

    /// Environment variable names mentioned in the reason (e.g. `CLAUDE_CODE_OAUTH_TOKEN`).
    public IReadOnlyList<string> MentionedEnvVars
    {
        get
        {
            if (string.IsNullOrEmpty(Reason)) return [];
            var out_ = new List<string>();
            foreach (Match m in EnvVarRx.Matches(Reason))
            {
                var token = m.Value;
                if (token.Contains('_') && !out_.Contains(token, StringComparer.Ordinal))
                    out_.Add(token);
            }
            return out_;
        }
    }
}

/// Provider waits and fallback notices (port of HermesKit/Activity/ToolCards.swift `ProviderWait`).
public static class ProviderWait
{
    private static readonly Regex WaitPattern = new(
        @"^(?:⏳|⚠|↻|⚙)\s*(?:(?:still\s+)?waiting on|loading|processing prompt|no (?:output|response)|model returned|rate limited|provider (?:overloaded|temporarily unavailable))",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);

    private static readonly Regex FallbackPattern = new(
        @"model fallback|provider fallback|switched to fallback|switching to fallback|primary model restored",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);

    /// The id prefix of a fallback notice row (`local-fallback-switch-N`).
    public const string NoticeIdPrefix = "local-fallback-switch-";

    /// Events that end a shown wait.
    public static readonly IReadOnlySet<string> ClearingEvents = new HashSet<string>(StringComparer.Ordinal)
    {
        "error", "message.complete", "message.delta", "message.interim", "message.start",
        "reasoning.available", "reasoning.delta", "tool.complete", "tool.generating", "tool.start",
    };

    public static string Text(string? raw)
    {
        var value = (raw ?? "").Trim();
        return value.Length > 0 && WaitPattern.IsMatch(value) ? value : "";
    }

    /// A `status.update` that announces a model / provider fallback or restoration: its text, else null.
    public static string? FallbackNotice(string? kind, string? text)
    {
        var t = (text ?? "").Trim();
        if (t.Length == 0) return null;
        if (string.Equals(kind, "fallback", StringComparison.OrdinalIgnoreCase)) return t;
        return FallbackPattern.IsMatch(t) ? t : null;
    }

    /// The notice in plain words: "Opus 5.5 hit a usage limit, so GPT-6.1-sol is answering for now."
    public static string PlainNotice(
        string text,
        Func<string, string>? displayName = null,
        Func<string, string>? providerName = null)
    {
        var display = displayName ?? ModelNames.DisplayModelName;
        var provider = providerName ?? ModelNames.ProviderDisplayName;
        var providerShape = text.Contains("Provider fallback:", StringComparison.Ordinal);

        string Name(string id, string placeholder, string fallbackWords)
        {
            var bare = id;
            if (bare.EndsWith(']'))
            {
                var open = bare.LastIndexOf('[');
                if (open >= 0) bare = bare[..open];
            }
            if (placeholder.Length > 0 && bare.Equals(placeholder, StringComparison.OrdinalIgnoreCase))
                return fallbackWords;
            string shown;
            var slash = bare.LastIndexOf('/');
            if (slash >= 0)
            {
                bare = bare[(slash + 1)..];
                shown = display(bare);
            }
            else
            {
                shown = providerShape ? provider(bare) : display(bare);
            }
            var trimmed = shown.Trim();
            return trimmed.Length == 0 ? bare : trimmed;
        }

        if (ModelFallback.Parse(text) is { } f)
        {
            var reason = (f.Reason ?? "").ToLowerInvariant();
            string what;
            if (reason.Contains("rate") || reason.Contains("limit") || reason.Contains("quota") || reason.Contains("billing") || reason.Contains("429"))
                what = "hit a usage limit";
            else if (reason.Contains("overload") || reason.Contains("busy") || reason.Contains("529") || reason.Contains("503"))
                what = "is busy";
            else if (reason.Contains("auth"))
                what = "couldn't sign in";
            else if (reason.Contains("timeout") || reason.Contains("server error"))
                what = "isn't responding";
            else
                what = "isn't available";

            var primary = Name(f.Primary, "primary", "Your usual model");
            var fallback = Name(f.Fallback, "fallback", "another model");
            return $"{primary} {what}, so {fallback} is answering for now.";
        }

        if (ModelFallback.Restores(text) && ModelFallback.RestoredModel(text) is { } restored)
            return restored.Length == 0 ? "Back to your usual model." : $"Back to {Name(restored, "", "")}.";

        var t = text;
        foreach (var mark in new[] { "⚠️", "⚠", "↻", "⚙" })
            if (t.StartsWith(mark, StringComparison.Ordinal)) t = t[mark.Length..];
        return t.Trim();
    }
}

/// Structured tiered presentation model for model & provider fallbacks (port of App/Chat/ModelFallbackViews.swift).
public sealed record ModelFallbackRow(
    ModelFallbackRow.PresentationKind Presentation,
    string Title,
    string? Subtitle,
    string Spoken,
    ModelFallbackRow.DetailModel? Detail)
{
    public enum PresentationKind { Card, Pill, Restored }

    public sealed record DetailModel(
        string PrimaryName,
        string PrimaryId,
        string? PrimaryProvider,
        string FallbackName,
        string FallbackId,
        string? FallbackProvider,
        ModelFallbackCategory Category,
        string Kicker,
        string RouteStatus,
        string Explanation,
        string? PrimaryCommand,
        string? PrimaryEnvVar,
        string? SecondaryHint,
        string RawText,
        bool IsActionable)
    {
        private static readonly char[] ForbiddenShellChars = [';', '|', '&', '`', '$', '>', '<', '(', ')', '{', '}', '\\', '\n', '\r', '\0'];

        /// Validates that a parsed CLI fix command is a safe, single-command invocation suitable for running directly in
        /// the in-app Terminal (no newlines, control characters, or shell chaining/redirection metacharacters).
        public static string? SafeTerminalCommand(string? raw)
        {
            var trimmed = raw?.Trim();
            if (string.IsNullOrEmpty(trimmed) || trimmed.Length > 200) return null;
            if (trimmed.IndexOfAny(ForbiddenShellChars) >= 0) return null;
            foreach (var c in trimmed)
                if (c < 0x20 || c == 0x7f) return null;
            return trimmed;
        }

        /// Sanitizes a single-line initial command for Terminal launch (`TerminalViewController.sanitizeInitialCommand`,
        /// `7b264e66d`): rejects empty strings, `\n`, `\r`, `\0`, and Unicode line separators.
        public static string? SanitizeInitialCommand(string? command)
        {
            var trimmed = command?.Trim();
            if (string.IsNullOrEmpty(trimmed)) return null;
            foreach (var c in trimmed)
                if (c is '\n' or '\r' or '\0' or '\u0085' or '\u2028' or '\u2029') return null;
            return trimmed;
        }

        /// Non-null when `PrimaryCommand` can be launched directly in a fresh Terminal tab.
        public string? RunnableCommand => SafeTerminalCommand(PrimaryCommand);
    }

    public static ModelFallbackRow? Parse(
        string? text,
        Func<string, string>? displayName = null,
        Func<string, string>? providerName = null)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        var display = displayName ?? ModelNames.DisplayModelName;
        var provider = providerName ?? ModelNames.ProviderDisplayName;

        if (ModelFallback.Parse(text) is { } fallback)
            return FromFallback(fallback, display, provider);

        if (ModelFallback.RestoredModel(text) is { } restored)
        {
            var title = restored.Length == 0
                ? "Back to your usual model"
                : $"Back to {ReadableName(restored, providerShape: false, placeholder: "", fallbackWords: "", display, provider)}";
            return new ModelFallbackRow(PresentationKind.Restored, title, null, title, null);
        }

        return null;
    }

    public static ModelFallbackRow FromFallback(
        ModelFallback fallback,
        Func<string, string>? displayName = null,
        Func<string, string>? providerName = null)
    {
        var display = displayName ?? ModelNames.DisplayModelName;
        var provider = providerName ?? ModelNames.ProviderDisplayName;

        var primary = ReadableName(fallback.Primary, fallback.IsProviderShape, "primary", "Your usual model", display, provider);
        var active = ReadableName(fallback.Fallback, fallback.IsProviderShape, "fallback", "another model", display, provider);
        var category = fallback.Category;
        var commands = fallback.ExtractedCommands;
        var lowerReason = (fallback.Reason ?? "").ToLowerInvariant();
        var primaryProviderLower = (fallback.PrimaryProvider ?? "").ToLowerInvariant();
        var isClaudeProvider = primaryProviderLower.StartsWith("claude-subscription", StringComparison.Ordinal)
            || primaryProviderLower == "claude-code";
        var isInvalidClaudeBearer = category == ModelFallbackCategory.Auth && isClaudeProvider
            && lowerReason.Contains("invalid bearer token", StringComparison.Ordinal);

        var primaryCommand = commands.Count > 0 ? commands[0] : (isInvalidClaudeBearer ? "claude auth login" : null);
        var primaryEnvVar = fallback.MentionedEnvVars.Count > 0
            ? fallback.MentionedEnvVars[0]
            : (isInvalidClaudeBearer ? "CLAUDE_CODE_OAUTH_TOKEN" : null);
        var secondaryHint = isInvalidClaudeBearer
            ? "If `CLAUDE_CODE_OAUTH_TOKEN` is set to a bad or expired value (such as a one-time login code), remove it so Hermes uses your `claude auth login` session."
            : BuildSecondaryHint(commands, fallback.MentionedEnvVars, fallback.Reason);

        var kickerBase = category switch
        {
            ModelFallbackCategory.Auth => "Sign-in required",
            ModelFallbackCategory.Billing => "Billing or quota limit",
            ModelFallbackCategory.NotFound => "Model unavailable",
            ModelFallbackCategory.RateLimit => "Rate limited",
            ModelFallbackCategory.Busy => "Provider busy",
            ModelFallbackCategory.Timeout => "Timed out",
            _ => "Model fallback",
        };
        var kicker = fallback.HttpStatus is { } http ? $"{kickerBase} · {http}" : kickerBase;
        var routeStatus = fallback.RetryAfterSeconds is > 0
            ? $"Retry in ~{fallback.RetryAfterSeconds}s"
            : "Active for turn";

        var explanation = BuildExplanation(primary, active, fallback, category);
        var detail = new DetailModel(
            PrimaryName: primary,
            PrimaryId: fallback.Primary,
            PrimaryProvider: fallback.PrimaryProvider,
            FallbackName: active,
            FallbackId: fallback.Fallback,
            FallbackProvider: fallback.FallbackProvider,
            Category: category,
            Kicker: kicker,
            RouteStatus: routeStatus,
            Explanation: explanation,
            PrimaryCommand: primaryCommand,
            PrimaryEnvVar: primaryEnvVar,
            SecondaryHint: secondaryHint,
            RawText: string.IsNullOrEmpty(fallback.RawText) ? $"{fallback.Primary} → {fallback.Fallback}" : fallback.RawText,
            IsActionable: fallback.IsActionable);

        if (fallback.IsActionable)
        {
            var title = $"Switched to {active}";
            var subtitle = category switch
            {
                ModelFallbackCategory.Auth => $"{primary} needs sign-in · {DeviceWord.TapCap} to fix",
                ModelFallbackCategory.Billing => $"{primary} hit a billing limit · {DeviceWord.TapCap} for details",
                ModelFallbackCategory.NotFound => $"{primary} isn’t available · {DeviceWord.TapCap} to fix",
                _ => $"{primary} couldn’t respond · {DeviceWord.TapCap} to fix",
            };
            return new ModelFallbackRow(PresentationKind.Card, title, subtitle, $"{title}. {subtitle}", detail);
        }

        var shortCause = category switch
        {
            ModelFallbackCategory.RateLimit => "rate limited",
            ModelFallbackCategory.Busy => "busy",
            ModelFallbackCategory.Timeout => "timed out",
            _ => "unavailable",
        };
        var pillTitle = $"{primary} {shortCause} · Using {active}";
        return new ModelFallbackRow(PresentationKind.Pill, pillTitle, null, $"{pillTitle}. Opens details", detail);
    }

    private static string BuildExplanation(string primary, string active, ModelFallback fallback, ModelFallbackCategory category)
    {
        var lower = (fallback.Reason ?? "").ToLowerInvariant();
        var providerLower = (fallback.PrimaryProvider ?? "").ToLowerInvariant();
        var isClaude = providerLower.StartsWith("claude-subscription", StringComparison.Ordinal) || providerLower == "claude-code";
        return category switch
        {
            ModelFallbackCategory.Auth when lower.Contains("invalid bearer token", StringComparison.Ordinal) && isClaude =>
                $"Claude Code’s saved token was rejected by Anthropic, so {active} answered this message instead.",
            ModelFallbackCategory.Auth when lower.Contains("claude code", StringComparison.Ordinal) && lower.Contains("login", StringComparison.Ordinal) =>
                $"Claude Code doesn’t have an active login in Hermes’s environment, so {active} answered this message instead.",
            ModelFallbackCategory.Auth =>
                $"{primary} couldn’t authenticate with its provider, so {active} answered this message instead.",
            ModelFallbackCategory.Billing =>
                $"{primary} hit a billing or quota limit, so {active} answered this message instead.",
            ModelFallbackCategory.NotFound =>
                $"{primary} wasn’t found on its configured provider, so {active} answered this message instead.",
            ModelFallbackCategory.RateLimit when fallback.RetryAfterSeconds is > 0 =>
                $"{primary} hit a rate limit, so {active} answered for now. Hermes can retry {primary} in about {fallback.RetryAfterSeconds} seconds.",
            ModelFallbackCategory.RateLimit =>
                $"{primary} hit a rate limit, so {active} answered this message for now.",
            ModelFallbackCategory.Busy when fallback.RetryAfterSeconds is > 0 =>
                $"{primary} is temporarily busy, so {active} answered for now. Hermes can retry {primary} in about {fallback.RetryAfterSeconds} seconds.",
            ModelFallbackCategory.Busy =>
                $"{primary} is temporarily overloaded, so {active} answered this message for now.",
            ModelFallbackCategory.Timeout =>
                $"{primary} didn’t respond in time, so {active} answered this message instead.",
            _ =>
                $"{primary} couldn’t respond, so {active} answered this message instead.",
        };
    }

    private static string? BuildSecondaryHint(IReadOnlyList<string> commands, IReadOnlyList<string> envVars, string? reason)
    {
        var second = commands.Count > 1 ? commands[1] : null;
        var env = envVars.Count > 0 ? envVars[0] : null;
        if (second != null && env != null)
            return $"Or instead, run `{second}` and set `{env}` in Hermes’s environment.";
        if (env != null)
        {
            if (env == "CLAUDE_CODE_OAUTH_TOKEN")
                return "Alternative (don’t do both): paste a long-lived `sk-ant-…` token from `claude setup-token` into `CLAUDE_CODE_OAUTH_TOKEN`. Leave it unset if you use `claude auth login`.";
            if (reason != null && reason.Contains("setup-to", StringComparison.Ordinal))
                return $"Or instead, set `{env}` (from `claude setup-token`) in Hermes’s environment.";
            return $"Or instead, set `{env}` in Hermes’s environment.";
        }
        if (second != null)
            return $"Or run `{second}` on {HostWord.Phrase}.";
        return null;
    }

    private static string ReadableName(
        string id,
        bool providerShape,
        string placeholder,
        string fallbackWords,
        Func<string, string> displayName,
        Func<string, string> providerName)
    {
        var bare = id;
        if (bare.EndsWith(']'))
        {
            var open = bare.LastIndexOf('[');
            if (open >= 0) bare = bare[..open];
        }
        if (placeholder.Length > 0 && bare.Equals(placeholder, StringComparison.OrdinalIgnoreCase))
            return fallbackWords;
        string shown;
        var slash = bare.LastIndexOf('/');
        if (slash >= 0)
        {
            bare = bare[(slash + 1)..];
            shown = displayName(bare);
        }
        else
        {
            shown = providerShape ? providerName(bare) : displayName(bare);
        }
        var trimmed = shown.Trim();
        return trimmed.Length == 0 ? bare : trimmed;
    }
}
