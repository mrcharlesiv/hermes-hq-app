using System.Globalization;

namespace Hermes.Core.Transcripts;

// Port of HermesKit/Chat/Transcript/Deliveries.swift (docs/spec/3x-transcript.md §2.1): a scheduled job's output mirrored
// into its chat arrives wrapped ("[Cron delivery: <job>]", "Cronjob Response: <job>", '[Cronjob "<job>" output …]').
// The wrapper goes, the job's bot speaks, the job is named on the byline. The pass over a whole message list
// (`resolve`, which sets a sender and job on the message) waits for the C# model to carry those fields.

/// A roster seat a cron job can belong to (Swift `DeliveryMessages.Seat`).
public sealed record DeliverySeat(string Profile, string Name, string? Head = null);

public sealed record CronDelivery(string Job, string Body);

public static class CronDeliveries
{
    private static readonly TranscriptRx Cron = new("""^(?:\[Cron delivery: ([^\]\n]{1,160})\]|Cronjob Response: ([^\n]{1,160})|\[Cronjob "([^"\n]{1,160})" output\b[^\]\n]*\])[ \t]*(?:\n|$)""");
    private static readonly TranscriptRx JobId = new(@"^\(job_id: [^)\n]*\)[ \t]*\n");
    private static readonly TranscriptRx Rule = new(@"^-{3,}[ \t]*\n");
    private static readonly TranscriptRx Footer = new(@"\n+(?:To stop or manage this job, send me a new message[^\n]*|Note: The agent cannot see this message[^\n]*)\s*$");
    private static readonly TranscriptRx ImportantNote = new(@"^\[IMPORTANT:\s*([\s\S]*?)\]?\s*$");

    private static bool SameWords(string a, string b) =>
        CultureInfo.InvariantCulture.CompareInfo.Compare(a, b, CompareOptions.IgnoreCase | CompareOptions.IgnoreNonSpace) == 0;

    private static bool IsDash(char c) => c is ' ' or ':' or '-' or '–' or '—';

    /// A cron card's name line: "<bot> · <job>", the bot named once. A job titled after its bot ("Ivy morning brief")
    /// drops that leading name ("Ivy · Morning brief"); a job that is only the bot's name leaves the name alone.
    public static string Header(string sender, string job)
    {
        var name = TxText.TrimSpaces(sender);
        var rest = TxText.TrimSpaces(job);
        if (name.Length > 0 && rest.Length > name.Length && SameWords(rest[..name.Length], name))
        {
            var after = rest[name.Length..];
            if (after.Length > 0 && IsDash(after[0]))
            {
                rest = after.TrimStart(' ', ':', '-', '–', '—');
                if (rest.Length > 0) rest = TxText.Cap(rest);
            }
        }
        else if (SameWords(rest, name))
        {
            rest = "";
        }
        return rest.Length == 0 ? name : $"{name} · {rest}";
    }

    /// A job's name as a chat line says it: the bot's own name off the front and a slug as words
    /// ("northwind-inbox-watch" from Northwind → "Inbox watch"). A job that is only the bot's name stays whole.
    public static string JobName(string job, string bot)
    {
        var name = TxText.TrimSpaces(bot);
        var whole = TxText.TrimSpaces(job);
        var rest = whole;
        const string seps = " :-–—_";
        if (name.Length > 0 && rest.Length > name.Length && SameWords(rest[..name.Length], name) && seps.Contains(rest[name.Length]))
            rest = rest[name.Length..].TrimStart(seps.ToCharArray());
        if (rest.Length == 0) rest = whole;
        var words = HumanJobTitle(rest);
        return TxText.Cap(words);
    }

    // RosterPreview.humanJobTitle (HermesKit/Model/RosterPreview.swift).
    private static readonly TranscriptRx SlugName = new("^[a-z0-9]+(?:[-_][a-z0-9]+)+$");
    private static readonly HashSet<string> Acronyms = ["ai", "api", "ap", "ci", "cpu", "crm", "csv", "dm", "dns", "gpu", "http", "id", "ios",
        "json", "kpi", "llm", "mcp", "os", "pdf", "pr", "qa", "rss", "seo", "sms", "sql", "ssh", "tts", "ui", "url", "ux"];
    private static readonly Dictionary<string, string> IosWords = new() { ["ios"] = "iOS", ["macos"] = "macOS", ["iphone"] = "iPhone", ["ipad"] = "iPad" };

    /// "morning-inbox-triage" → "Morning inbox triage"; a name that is already words stays.
    public static string HumanJobTitle(string name)
    {
        var text = name.Trim();
        if (!SlugName.Test(text)) return name;
        var words = text.Split(['-', '_'], StringSplitOptions.RemoveEmptyEntries);
        return string.Join(" ", words.Select((word, index) =>
            IosWords.TryGetValue(word, out var known) ? known
            : Acronyms.Contains(word) ? word.ToUpperInvariant()
            : index == 0 ? TxText.Cap(word) : word));
    }

    /// The report without a first line that only restates the job ("Northwind inbox watch: 1 new inbound email" for
    /// northwind-inbox-watch → "1 new inbound email"): letters and digits compared, case and punctuation ignored.
    public static string WithoutJobLead(string body, string job)
    {
        static string Squash(string s) => new([.. s.ToLowerInvariant().Where(char.IsLetterOrDigit)]);
        var key = Squash(job);
        var colon = body.IndexOf(':');
        if (key.Length == 0 || colon < 0 || body[..colon].Contains('\n') || Squash(body[..colon]) != key) return body;
        var rest = body[(colon + 1)..].Trim();
        return rest.Length == 0 ? body : rest;
    }

    /// Cheap test before the regular expression.
    public static bool MayBeCron(string text)
    {
        var head = text.TrimStart(' ', '\n', '\t', '\r');
        return head.StartsWith("[Cron delivery: ", StringComparison.Ordinal) || head.StartsWith("Cronjob Response: ", StringComparison.Ordinal)
            || head.StartsWith("[Cronjob \"", StringComparison.Ordinal);
    }

    /// A cron delivery's job name and its text without the wrapper, or null when the message isn't one.
    public static CronDelivery? Parse(string text)
    {
        if (!MayBeCron(text)) return null;
        var start = text.TrimStart();
        if (Cron.Groups(start) is not { } groups || groups[0] is not { } whole) return null;
        var body = start[whole.Length..];
        // The wrapper's own lines: "(job_id: …)" and the rule under it. (A body that is only a footer has nothing left
        // before it, so the footer is tried with a leading newline added.)
        body = JobId.Replace(body, "");
        body = Rule.Replace(body, "");
        body = Footer.Replace("\n" + body, "");
        var job = (groups[1] ?? groups[2] ?? groups[3] ?? "").Trim();
        if (job.Length == 0) return null;
        return new CronDelivery(job, body.Trim());
    }

    private static readonly TranscriptRx CronHead = new("""^\s*(?:\[Cron delivery: ([^\]\n]{1,160})(\])?|Cronjob Response: ([^\n]{1,160})|\[Cronjob "([^"\n]{1,160})"(?: output\b[^\]\n]*(\]))?)""");
    private static readonly TranscriptRx PreviewLead = new(@"^\s*(?:\(job_id: [^)\n]*\)\s*)?(?:-{3,}\s*)?");

    /// A list preview's cron run: the job's name and the report's words, null words when there are none. The gateway
    /// cuts previews at 80 characters (often inside the wrapper) and may put the report on the wrapper's line.
    public static (string Job, string? Body)? Preview(string text)
    {
        if (Parse(text) is { } parsed) return (parsed.Job, parsed.Body.Length == 0 ? null : parsed.Body);
        if (!MayBeCron(text) || CronHead.Groups(text) is not { } groups || groups[0] is not { } whole) return null;
        var job = (groups[1] ?? groups[3] ?? groups[4] ?? "").Trim();
        if (job.Length == 0) return null;
        if (groups[2] is null && groups[3] is null && groups[5] is null) return (job, null);
        var body = PreviewLead.Replace(text[whole.Length..], "").Trim();
        return (job, body.Length == 0 ? null : body);
    }

    /// The roster bot a cron job's name starts with ("Scout morning brief" → Scout), longest name first.
    public static DeliverySeat? Bot(string job, IEnumerable<DeliverySeat> roster)
    {
        var text = job.Trim().ToLowerInvariant();
        DeliverySeat? best = null;
        var bestLength = 0;
        const string separators = " \t:·–—-";
        foreach (var seat in roster)
        {
            foreach (var label in new[] { seat.Name, seat.Profile, seat.Profile == "default" ? "Hermes" : "" })
            {
                var value = label.Trim().ToLowerInvariant();
                if (value.Length == 0 || !text.StartsWith(value, StringComparison.Ordinal)) continue;
                if (text.Length > value.Length && !separators.Contains(text[value.Length])) continue;
                if (value.Length > bestLength) { best = seat; bestLength = value.Length; }
            }
        }
        return best;
    }

    /// The seat whose bot speaks a delivery: the job's own bot, else the chat's.
    public static DeliverySeat Speaker(string job, IEnumerable<DeliverySeat> roster, DeliverySeat own) => Bot(job, roster) ?? own;

    /// The text inside an "[IMPORTANT: …]" process note, or null.
    public static string? ProcessNote(string text)
    {
        var trimmed = text.Trim();
        if (!trimmed.StartsWith("[IMPORTANT:", StringComparison.Ordinal) || ImportantNote.Groups(trimmed) is not { } g || g[1] is not { } inside) return null;
        var words = inside.Trim();
        return words.Length == 0 ? null : words;
    }
}
