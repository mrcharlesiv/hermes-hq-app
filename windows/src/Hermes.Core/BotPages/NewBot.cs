using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Net;

namespace Hermes.Core.BotPages;

/// A new bot's identity (HermesKit/Model/BotIdentity.swift, from `HB/labels.ts` and `HB/soul.ts`): the profile id from
/// the typed name, the display title, the description line and the SOUL it is born with. Pure.
public static partial class BotIdentity
{
    [GeneratedRegex("^[a-z0-9][a-z0-9_-]{0,63}$")]
    private static partial Regex ProfileIdPattern();

    /// `slugify(value, max)`: lower-case, runs of anything but `[a-z0-9_-]` → "-", no leading or trailing "-".
    public static string Slugify(string value, int max = 64)
    {
        var sb = new StringBuilder();
        var dash = false;
        foreach (var rune in value.ToLowerInvariant().EnumerateRunes())
        {
            var v = rune.Value;
            var ok = v is >= 'a' and <= 'z' or >= '0' and <= '9' or '_' or '-';
            if (ok) { sb.Append((char)v); dash = false; }
            else if (!dash) { sb.Append('-'); dash = true; }
        }
        var s = sb.ToString().Trim('-');
        return s.Length > max ? s[..max] : s;
    }

    private static bool IsLetterOrNumber(Rune r) => Rune.GetUnicodeCategory(r) is UnicodeCategory.UppercaseLetter
        or UnicodeCategory.LowercaseLetter or UnicodeCategory.TitlecaseLetter or UnicodeCategory.ModifierLetter
        or UnicodeCategory.OtherLetter or UnicodeCategory.DecimalDigitNumber or UnicodeCategory.LetterNumber
        or UnicodeCategory.OtherNumber;

    private static bool IsMark(Rune r) => Rune.GetUnicodeCategory(r) is UnicodeCategory.NonSpacingMark
        or UnicodeCategory.SpacingCombiningMark or UnicodeCategory.EnclosingMark;

    /// The profile id Hermes accepts (ASCII only): accented Latin folds to its base letters, every other letter or digit
    /// becomes `u<hex>` per NFC code point, cut at 64 on a token boundary.
    public static string SlugifyProfileName(string value)
    {
        var folded = new StringBuilder();
        foreach (var r in value.Normalize(NormalizationForm.FormC).EnumerateRunes())
        {
            if (!IsLetterOrNumber(r)) { folded.Append(r.ToString()); continue; }
            var b = new StringBuilder();
            foreach (var x in r.ToString().Normalize(NormalizationForm.FormKD).EnumerateRunes()) if (!IsMark(x)) b.Append(x.ToString());
            var baseText = b.ToString();
            var ascii = baseText.Length > 0 && baseText.All(c => c is >= 'a' and <= 'z' or >= 'A' and <= 'Z' or >= '0' and <= '9');
            folded.Append(ascii ? baseText : $"-u{r.Value:x}-");
        }
        var collapsed = new StringBuilder();
        foreach (var ch in folded.ToString()) if (!(ch == '-' && collapsed.Length > 0 && collapsed[^1] == '-')) collapsed.Append(ch);
        var slug = Slugify(collapsed.ToString(), int.MaxValue);
        if (slug.Length <= 64) return slug;
        var cut = slug[..64];
        var boundary = slug[64] == '-' ? 64 : cut.LastIndexOf('-');
        var result = boundary > 0 ? slug[..boundary] : cut;
        return result.TrimEnd('-');
    }

    /// The typed Name split into the backend id and the display title: a non-ASCII name survives as the title when
    /// Title was left empty.
    public static (string Slug, string Title) ProfileIdentity(string name, string title)
    {
        var entered = name.Trim();
        var typedTitle = title.Trim();
        var nonAscii = entered.Any(c => c < 0x20 || c > 0x7E);
        return (SlugifyProfileName(entered), typedTitle.Length > 0 ? typedTitle : nonAscii ? entered : "");
    }

    public static bool IsValidProfileId(string slug) => slug.Length > 0 && ProfileIdPattern().IsMatch(slug);

    /// `[title, description].filter(Boolean).join(" — ")`.
    public static string DescriptionText(string title, string description) =>
        string.Join(" — ", new[] { title, description.Trim() }.Where(s => s.Length > 0));

    /// The title, else the name Title Cased (`-`/`_` runs as spaces, each word's first character upper-cased).
    public static string DisplayName(string name, string title)
    {
        var trimmed = title.Trim();
        if (trimmed.Length > 0) return trimmed;
        if (name.Trim().ToLowerInvariant() == "default") return "Hermes";
        return TitleCase(name);
    }

    /// RosterRules.titleCase.
    public static string TitleCase(string raw)
    {
        var spaced = Regex.Replace(raw, "[-_]+", " ").Trim();
        var sb = new StringBuilder();
        var previousIsWord = false;
        foreach (var ch in spaced)
        {
            var isWord = char.IsLetterOrDigit(ch) || ch == '_';
            sb.Append(isWord && !previousIsWord ? char.ToUpperInvariant(ch) : ch);
            previousIsWord = isWord;
        }
        return sb.ToString();
    }

    /// `composeSoul` for a new bot. `serverInjectsProtocol`: current gateways say true; the teammate section is left out.
    public static string ComposeSoul(string slug, string title, string description, bool serverInjectsProtocol,
        IReadOnlyList<(string Name, string? Description)>? teammates = null)
    {
        var shown = DisplayName(slug, title);
        var desc = description.Trim();
        var lines = new List<string?>
        {
            $"# {shown}",
            "",
            title.Length == 0 ? null : $"**Role:** {title}",
            desc.Length == 0 ? null : $"**Mission:** {desc}",
            "",
            $"You are {shown}, a persistent named agent (profile `{slug}`) on this machine.",
            "You keep your own memory, skills, and conversation history across sessions.",
        };
        var identity = string.Join("\n", lines.OfType<string>());
        return serverInjectsProtocol ? identity : identity + "\n\n" + MessagingProtocolSection(slug, teammates ?? []);
    }

    /// `messagingProtocolSection` (`HB/soul.ts:19-66`), verbatim.
    public static string MessagingProtocolSection(string name, IReadOnlyList<(string Name, string? Description)> teammates)
    {
        var others = teammates.Where(t => t.Name != name).ToList();
        var handle = name.Trim().ToLowerInvariant() == "default" ? "hermes" : name;
        var robot = "\U0001F916";
        var lines = new List<string>
        {
            "## Messaging other agents",
            "",
            "You work alongside other named agents. Every agent (including you) has",
            "ONE canonical conversation titled \"Bot Chat\" — created with the agent,",
            "so it always exists. Agent-to-agent messages are delivered straight",
            "into it, like a DM. To message a teammate, run:",
            "",
            "```",
            "hermes -p <agent-name> chat --in ~ -c \"Bot Chat\" --create-if-missing -Q -q \"Message from " + robot + " " + handle
                + " (@" + handle + "): your message\"",
            "",
            "Run the send with background=true and notify_on_complete=true on the",
            "terminal tool, then finish your turn — the reply arrives later as a",
            "background process notification. Never block waiting for it.",
            "```",
            "",
            "(`--in ~ -c \"Bot Chat\" --create-if-missing` resumes their canonical",
            "conversation in the home workspace, creating it if the target has no",
            "\"Bot Chat\" yet. `-Q` keeps output clean. Always open with the",
            "\"Message from " + robot + " " + handle + " (@" + handle + "):\" prefix so they know",
            "who is talking (the @handle lets the app show your avatar to them).",
            "Their reply prints to stdout — relay the relevant part back to the",
            "user, and say which agent it came from.)",
            "",
            "If a message in YOUR chat starts with \"Message from " + robot + " <name>\", it is",
            "a teammate messaging you, not the user. Answer it directly — your reply",
            "reaches them via their own delivery — and use the same command if you",
            "need to start a conversation yourself.",
            "",
            "When the user writes @<agent-name> or says \"ask <name> to ...\" /",
            "\"tell <name> ...\", that is a handoff: message that agent, wait for the",
            "reply, and report back.",
            "",
            "The roster grows over time — run `hermes profile list` for the LIVE",
            "teammate list before a handoff. Teammates when you were created:",
        };
        if (others.Count == 0) lines.Add("- (none yet)");
        else lines.AddRange(others.Select(m => $"- `{m.Name}`" + (string.IsNullOrEmpty(m.Description) ? "" : $" — {m.Description}")));
        return string.Join("\n", lines);
    }
}

/// New Bot's words (App/Bots/NewBotViewController.swift).
public static class NewBotWords
{
    public const string Title = "New Bot";
    public const string Intro = "A named teammate with its own memory, skills, and chat. It can message your other bots.";
    public const string ShapeNote = "The bot gets a shape from its name. You can change it once the bot is created.";
    public const string NameHeader = "Name";
    public const string NamePlaceholder = "inbox-triage";
    public const string NameFooter = "Lowercase letters, numbers and dashes. Spaces become dashes.";
    public const string TitleHeader = "Display Name";
    public const string TitlePlaceholder = "Inbox Triage";
    public const string TitleFooter = "The name shown in lists. Leave it blank to use the Name.";
    public const string DescriptionHeader = "Description";
    public const string DescriptionPlaceholder = "What should this bot help with?";
    public const string Create = "Create";
    public const string Creating = "Creating…";
    public static string Taken(string slug) => $"A bot named “{slug}” already exists.";
    public static string FailTitle(string display) => $"Couldn’t Create {display}";
    public const string NoLetters = "Give the bot a name with letters or numbers.";
}

/// The result of New Bot (`NewBotResult`): `NeedsModel` when `setup.runtime_check` said `ok: false`.
public sealed record NewBotResult(string Slug, string DisplayName, bool NeedsModel);

/// A refusal shown under the Name field (RPC 4062), not in an alert (`NewBotError.inline`).
public sealed class NewBotInlineException(string message) : Exception(message);

/// New Bot's calls (BotStore+Editing.swift `createBot`, steps 1, 4): `profiles.create`, then `setup.runtime_check`. The
/// meta write, the Bot Chat and the intro are the Bots feature's (it opens the chat).
public sealed class NewBotApi(IPagesGateway gw)
{
    public static readonly TimeSpan CreateTimeout = TimeSpan.FromSeconds(90);

    /// The exact keys `profiles.create` takes.
    public static JsonObject CreateParams(string slug, string descriptionText, string soul) => new()
    {
        ["name"] = slug, ["description"] = descriptionText, ["clone_from"] = "default",
        ["no_skills"] = false, ["share_auth"] = true, ["soul"] = soul,
    };

    public async Task<NewBotResult> CreateAsync(string typedName, string typedTitle, string description,
        IReadOnlyList<(string Name, string? Description)> teammates, bool serverInjectsProtocol = true, CancellationToken ct = default)
    {
        var (slug, title) = BotIdentity.ProfileIdentity(typedName, typedTitle);
        var display = BotIdentity.DisplayName(slug, title);
        if (!BotIdentity.IsValidProfileId(slug)) throw new BotWriteException(NewBotWords.FailTitle(display), NewBotWords.NoLetters);
        var descriptionText = BotIdentity.DescriptionText(title, description);
        var soul = BotIdentity.ComposeSoul(slug, title, description, serverInjectsProtocol, teammates);
        try
        {
            await gw.CallAsync("profiles.create", CreateParams(slug, descriptionText, soul), CreateTimeout, ct);
        }
        catch (GatewayException e) when (e is { Code: "rpc", RpcCode: 4062 }) { throw new NewBotInlineException(e.Message); }
        catch (GatewayException e)
        {
            // The answer was lost, but the profile may have been made: carry on rather than leave a half-made bot.
            if (e.Code != "timeout" && e.Code != "offline" || !await ExistsAsync(slug, ct))
                throw new BotWriteException(NewBotWords.FailTitle(display), PagesRest.Reason(e));
        }
        JsonNode? ready = null;
        try
        {
            ready = await gw.CallAsync("setup.runtime_check", new JsonObject { ["profile"] = slug }, TimeSpan.FromSeconds(30), ct);
        }
        catch (GatewayException) { }
        return new NewBotResult(slug, display, ready.Bool("ok") == false);
    }

    /// The answer was lost, but the profile may have been made: a slim read says.
    private async Task<bool> ExistsAsync(string slug, CancellationToken ct)
    {
        try
        {
            var list = await gw.CallAsync("profiles.list", [], TimeSpan.FromSeconds(30), ct);
            return (list.Arr("profiles") ?? []).Any(p => p.Text("name") == slug);
        }
        catch (GatewayException) { return false; }
    }
}
