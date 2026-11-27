using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Hermes.Core.Bots;

/// A new bot's identity (spec 1x-settings §8.1–8.2): the profile id from the typed name, the display title, the
/// description line and the SOUL it is born with. Port of HermesKit/Model/BotIdentity.swift and the duplicate helpers
/// of BotStore+Extras.swift. Pure.
public static class BotIdentity
{
    private static readonly Regex ProfileIdPattern = new("^[a-z0-9][a-z0-9_-]{0,63}$");

    /// Lower-case, runs of anything but `[a-z0-9_-]` → "-", no leading or trailing "-".
    public static string Slugify(string value, int max = 64)
    {
        var sb = new StringBuilder();
        var dash = false;
        foreach (var ch in value.ToLowerInvariant())
        {
            var ok = ch is >= 'a' and <= 'z' or >= '0' and <= '9' or '_' or '-';
            if (ok) { sb.Append(ch); dash = false; }
            else if (!dash) { sb.Append('-'); dash = true; }
        }
        var s = sb.ToString().Trim('-');
        return s.Length > max ? s[..max] : s;
    }

    /// The profile id Hermes accepts (ASCII only): accented Latin folds to its base letters, every other letter or digit
    /// becomes `u<hex>` per code point, cut at 64 on a token boundary.
    public static string SlugifyProfileName(string value)
    {
        var folded = new StringBuilder();
        foreach (var rune in value.Normalize(NormalizationForm.FormC).EnumerateRunes())
        {
            var cat = Rune.GetUnicodeCategory(rune);
            var letterOrNumber = cat is UnicodeCategory.UppercaseLetter or UnicodeCategory.LowercaseLetter or UnicodeCategory.TitlecaseLetter
                or UnicodeCategory.ModifierLetter or UnicodeCategory.OtherLetter or UnicodeCategory.DecimalDigitNumber
                or UnicodeCategory.LetterNumber or UnicodeCategory.OtherNumber;
            if (!letterOrNumber) { folded.Append(rune.ToString()); continue; }
            var baseText = new string(rune.ToString().Normalize(NormalizationForm.FormKD)
                .Where(c => CharUnicodeInfo.GetUnicodeCategory(c) is not (UnicodeCategory.NonSpacingMark
                    or UnicodeCategory.SpacingCombiningMark or UnicodeCategory.EnclosingMark)).ToArray());
            var ascii = baseText.Length > 0 && baseText.All(c => c is >= 'a' and <= 'z' or >= 'A' and <= 'Z' or >= '0' and <= '9');
            folded.Append(ascii ? baseText : $"-u{rune.Value:x}-");
        }
        var collapsed = Regex.Replace(folded.ToString(), "-+", "-");
        var slug = Slugify(collapsed, int.MaxValue);
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

    public static bool IsValidProfileId(string slug) => slug.Length > 0 && ProfileIdPattern.IsMatch(slug);

    /// `[title, description].filter(Boolean).join(" — ")`.
    public static string DescriptionText(string title, string description) =>
        string.Join(" — ", new[] { title, description.Trim() }.Where(s => s.Length > 0));

    public static string DisplayName(string name, string title)
    {
        var t = title.Trim();
        if (t.Length > 0) return t;
        if (name.Trim().ToLowerInvariant() == "default") return "Hermes";
        return RosterRules.TitleCase(name);
    }

    /// `composeSoul` for a new bot (current gateways inject the messaging protocol, so it is left out then).
    public static string ComposeSoul(string slug, string title, string description, bool serverInjectsProtocol,
        IReadOnlyList<(string Name, string? Description)>? teammates = null)
    {
        var shown = DisplayName(slug, title);
        var desc = description.Trim();
        var lines = new List<string?>
        {
            $"# {shown}", "",
            title.Length == 0 ? null : $"**Role:** {title}",
            desc.Length == 0 ? null : $"**Mission:** {desc}",
            "",
            $"You are {shown}, a persistent named agent (profile `{slug}`) on this machine.",
            "You keep your own memory, skills, and conversation history across sessions.",
        };
        var identity = string.Join("\n", lines.Where(l => l != null));
        return serverInjectsProtocol ? identity : identity + "\n\n" + MessagingProtocolSection(slug, teammates ?? []);
    }

    /// `messagingProtocolSection` (`HB/soul.ts:19-66`), verbatim.
    public static string MessagingProtocolSection(string name, IReadOnlyList<(string Name, string? Description)> teammates)
    {
        var others = teammates.Where(m => m.Name != name).ToList();
        var handle = name.Trim().ToLowerInvariant() == "default" ? "hermes" : name;
        var lines = new List<string>
        {
            "## Messaging other agents", "",
            "You work alongside other named agents. Every agent (including you) has",
            "ONE canonical conversation titled \"Bot Chat\" — created with the agent,",
            "so it always exists. Agent-to-agent messages are delivered straight",
            "into it, like a DM. To message a teammate, run:", "",
            "```",
            "hermes -p <agent-name> chat --in ~ -c \"Bot Chat\" --create-if-missing -Q -q \"Message from \U0001F916 " + handle
                + " (@" + handle + "): your message\"",
            "",
            "Run the send with background=true and notify_on_complete=true on the",
            "terminal tool, then finish your turn — the reply arrives later as a",
            "background process notification. Never block waiting for it.",
            "```", "",
            "(`--in ~ -c \"Bot Chat\" --create-if-missing` resumes their canonical",
            "conversation in the home workspace, creating it if the target has no",
            "\"Bot Chat\" yet. `-Q` keeps output clean. Always open with the",
            "\"Message from \U0001F916 " + handle + " (@" + handle + "):\" prefix so they know",
            "who is talking (the @handle lets the app show your avatar to them).",
            "Their reply prints to stdout — relay the relevant part back to the",
            "user, and say which agent it came from.)", "",
            "If a message in YOUR chat starts with \"Message from \U0001F916 <name>\", it is",
            "a teammate messaging you, not the user. Answer it directly — your reply",
            "reaches them via their own delivery — and use the same command if you",
            "need to start a conversation yourself.", "",
            "When the user writes @<agent-name> or says \"ask <name> to ...\" /",
            "\"tell <name> ...\", that is a handoff: message that agent, wait for the",
            "reply, and report back.", "",
            "The roster grows over time — run `hermes profile list` for the LIVE",
            "teammate list before a handoff. Teammates when you were created:",
        };
        if (others.Count == 0) lines.Add("- (none yet)");
        else lines.AddRange(others.Select(m => $"- `{m.Name}`" + (string.IsNullOrEmpty(m.Description) ? "" : $" — {m.Description}")));
        return string.Join("\n", lines);
    }

    /// The duplicate's profile name: "<base>-2", "-3", … up to 99, the first not taken. Null when none is free.
    public static string? DuplicateName(string baseName, IReadOnlySet<string> taken)
    {
        for (var n = 2; n < 100; n++)
        {
            var suffix = $"-{n}";
            var head = baseName.Length > 64 - suffix.Length ? baseName[..(64 - suffix.Length)] : baseName;
            if (!taken.Contains(head + suffix)) return head + suffix;
        }
        return null;
    }

    /// The meta the duplicate starts with: the original's look and filing, not its chat or creation time; "(copy)" titled.
    public static JsonObject DuplicateMeta(JsonObject meta)
    {
        var look = (JsonObject)meta.DeepClone();
        look.Remove("chat");
        look.Remove("created");
        look.Remove("image");
        look.Remove("pet");
        var title = RosterText.Trimmed(meta["title"]);
        look["title"] = title is null ? "" : $"{title} (copy)";
        return look;
    }

    /// `sec-<ms base36>-<5 random>`.
    public static string NewSectionId(DateTimeOffset? now = null)
    {
        var ms = (now ?? DateTimeOffset.UtcNow).ToUnixTimeMilliseconds();
        const string alphabet = "0123456789abcdefghijklmnopqrstuvwxyz";
        var b36 = new StringBuilder();
        do { b36.Insert(0, alphabet[(int)(ms % 36)]); ms /= 36; } while (ms > 0);
        var random = new string(Enumerable.Range(0, 5).Select(_ => alphabet[Random.Shared.Next(36)]).ToArray());
        return $"sec-{b36}-{random}";
    }
}

/// Per-bot Mute on this PC (Shared/BotMutes.swift): device-local, by gateway account and profile.
public sealed record BotMute(bool Always, DateTimeOffset? Until)
{
    public static readonly BotMute Forever = new(true, null);
    public bool Live(DateTimeOffset now) => Always || (Until is { } u && u > now);
}

public enum MuteChoice { Off, Hour, Hours8, Week, Always }

public static class BotMutes
{
    public const string Scope = "Only on this PC. Approval requests still notify you.";

    public static string Title(MuteChoice c) => c switch
    {
        MuteChoice.Off => "Off",
        MuteChoice.Hour => "For 1 Hour",
        MuteChoice.Hours8 => "For 8 Hours",
        MuteChoice.Week => "For 1 Week",
        _ => "Always",
    };

    public static BotMute? Mute(MuteChoice c, DateTimeOffset now) => c switch
    {
        MuteChoice.Off => null,
        MuteChoice.Hour => new BotMute(false, now.AddHours(1)),
        MuteChoice.Hours8 => new BotMute(false, now.AddHours(8)),
        MuteChoice.Week => new BotMute(false, now.AddHours(168)),
        _ => BotMute.Forever,
    };

    /// "Off", "Always", "Until 6:30 PM" (under 20 h) or "Until Tue, Oct 6".
    public static string Value(BotMute? mute, DateTimeOffset now, TimeZoneInfo? zone = null)
    {
        if (mute == null || !mute.Live(now)) return "Off";
        if (mute.Always || mute.Until is not { } until) return "Always";
        var local = TimeZoneInfo.ConvertTime(until, zone ?? TimeZoneInfo.Local);
        var en = CultureInfo.GetCultureInfo("en-US");
        return "Until " + ((until - now).TotalHours < 20 ? local.ToString("h:mm tt", en) : local.ToString("ddd, MMM d", en));
    }

    /// "Muted", or for a timed mute "Muted until 6:30 PM".
    public static string MutedWords(BotMute? mute, DateTimeOffset now)
    {
        if (mute == null || mute.Always || !mute.Live(now)) return "Muted";
        var v = Value(mute, now);
        return "Muted " + char.ToLowerInvariant(v[0]) + v[1..];
    }
}
