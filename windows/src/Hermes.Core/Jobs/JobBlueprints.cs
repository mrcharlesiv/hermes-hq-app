using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Hermes.Core.Jobs;

/// One field of a job template (HermesKit/Pages/JobBlueprints.swift, docs/spec/3x-jobs.md §6.6).
public sealed record BlueprintField(string Name, string Type = "text", string Label = "", string? DefaultValue = null,
    IReadOnlyList<string>? Options = null, bool Optional = false, bool Strict = true, string Help = "")
{
    public IReadOnlyList<string> Choices => Options ?? [];

    public static BlueprintField? Parse(JsonNode? json)
    {
        if (json is not JsonObject || JobJson.PgString(json.Get("name"))?.Trim() is not { Length: > 0 } name) return null;
        return new BlueprintField(name,
            JobJson.StrictString(json.Get("type"))?.Trim().ToLowerInvariant() ?? "text",
            JobJson.PgString(json.Get("label"))?.Trim() ?? "",
            JobJson.PgString(json.Get("default")),
            [.. (json.Arr("options") ?? []).Select(JobJson.PgString).OfType<string>()],
            JobJson.StrictBool(json.Get("optional")) ?? false,
            JobJson.StrictBool(json.Get("strict")) ?? true,
            JobJson.PgString(json.Get("help")) ?? "");
    }

    /// The row's label: the field's own, else its name in words.
    public string Title => Label.Length == 0 ? JobWords.TitleCase(Name) : Label;

    public bool Equals(BlueprintField? o) => o is not null && Name == o.Name && Type == o.Type && Label == o.Label
        && DefaultValue == o.DefaultValue && Choices.SequenceEqual(o.Choices) && Optional == o.Optional && Strict == o.Strict && Help == o.Help;

    public override int GetHashCode() => HashCode.Combine(Name, Type, Label);
}

public sealed record Blueprint(string Key, string Title, string Description = "", string Category = "", IReadOnlyList<BlueprintField>? FieldList = null)
{
    public IReadOnlyList<BlueprintField> Fields => FieldList ?? [];

    /// Lenient: a missing `fields` is an empty list, a wrong-typed entry is dropped, never fatal.
    public static Blueprint? Parse(JsonNode? json)
    {
        if (json is not JsonObject || JobJson.PgString(json.Get("key"))?.Trim() is not { Length: > 0 } key) return null;
        var named = JobJson.PgString(json.Get("title"))?.Trim() ?? "";
        var seen = new HashSet<string>();
        return new Blueprint(key, named.Length == 0 ? JobWords.TitleCase(key) : named,
            JobJson.PgString(json.Get("description"))?.Trim() ?? "",
            JobJson.PgString(json.Get("category")) ?? "",
            [.. (json.Arr("fields") ?? []).Select(BlueprintField.Parse).OfType<BlueprintField>().Where(f => seen.Add(f.Name))]);
    }

    public static List<Blueprint> List(JsonNode? json)
    {
        var seen = new HashSet<string>();
        var rows = json.Arr("blueprints") ?? json as JsonArray ?? [];
        return [.. rows.Select(Parse).OfType<Blueprint>().Where(b => seen.Add(b.Key))];
    }

    public bool Equals(Blueprint? o) => o is not null && Key == o.Key && Title == o.Title && Description == o.Description
        && Category == o.Category && Fields.SequenceEqual(o.Fields);

    public override int GetHashCode() => HashCode.Combine(Key, Title);
}

public enum BlueprintControl { Time, Choice, Deliver, Text }

public static partial class JobBlueprints
{
    public const string DeliverField = "deliver";

    public static BlueprintControl Control(BlueprintField field)
    {
        if (field.Name == DeliverField) return BlueprintControl.Deliver;
        return field.Type switch
        {
            "time" => BlueprintControl.Time,
            // A choice field the catalog gave no choices is asked as text (never an empty menu).
            "enum" or "weekdays" => field.Choices.Count == 0 ? BlueprintControl.Text : BlueprintControl.Choice,
            _ => BlueprintControl.Text,
        };
    }

    [GeneratedRegex(@"^(?:an?|two or three|one or two|some)\s.*(?:\sor\s|,)", RegexOptions.IgnoreCase)]
    private static partial Regex ExampleDefault();

    /// A text default that describes what to type ("a product URL or exact flight/hotel/listing description").
    public static bool IsExampleDefault(BlueprintField field) => field.Type == "text" && ExampleDefault().IsMatch((field.DefaultValue ?? "").Trim());

    /// The form's first values: each field's default, except the deliver slot's '' or 'origin' → 'local', and an example
    /// default → ''.
    public static Dictionary<string, string> InitialValues(Blueprint blueprint)
    {
        var out_ = new Dictionary<string, string>();
        foreach (var field in blueprint.Fields)
        {
            var seeded = field.DefaultValue ?? "";
            if (field.Name == DeliverField && (seeded.Length == 0 || seeded == "origin")) out_[field.Name] = "local";
            else if (IsExampleDefault(field)) out_[field.Name] = "";
            else out_[field.Name] = seeded;
        }
        return out_;
    }

    private static readonly Dictionary<string, string> WeekdayWords = new() { ["everyday"] = "Every day", ["weekdays"] = "Weekdays", ["weekends"] = "Weekends" };

    private static string Capitalised(string text) => text.Length == 0 ? text : char.ToUpperInvariant(text[0]) + text[1..];

    /// A choice in words: "everyday" → "Every day", "sunday" → "Sunday", a start hour "7" → "7 AM", minutes between
    /// checks "30" → "Every 30 minutes"; anything else keeps its words with a capital.
    public static string OptionLabel(BlueprintField field, string option)
    {
        var value = option.Trim();
        if (WeekdayWords.TryGetValue(value, out var words)) return words;
        if (JobWords.Days.FirstOrDefault(d => d.Equals(value, StringComparison.OrdinalIgnoreCase)) is { } day) return day;
        if (JobWords.Int(value) is { } n)
        {
            if (field.Name.EndsWith("_hour") && n <= 23) return $"{(n % 12 == 0 ? 12 : n % 12)} {(n < 12 ? "AM" : "PM")}";
            if (Regex.IsMatch(field.Name, "^interval_(?:min|minutes)$")) return n == 60 ? "Every hour" : $"Every {n} minutes";
            if (Regex.IsMatch(field.Name, "^interval_(?:h|hours)$")) return n == 1 ? "Every hour" : n == 24 ? "Once a day" : $"Every {n} hours";
            return value;
        }
        return Capitalised(value);
    }

    /// The hint under a field.
    public static string? FieldHelp(BlueprintField field)
    {
        if (field.Name == DeliverField) return null;
        if (field.Type == "time") return JobSchedule.ClockNote;
        if (Control(field) == BlueprintControl.Text) return null;
        var text = Regex.Replace(field.Help, @"\s*\(24h\)", "", RegexOptions.IgnoreCase).Trim();
        return text.Length == 0 ? null : Capitalised(text);
    }

    /// A text field's placeholder: its help, else its label.
    public static string Placeholder(BlueprintField field)
    {
        var help = field.Help.Trim();
        return help.Length == 0 ? field.Title : Capitalised(help);
    }

    /// "422: missing required value: time (What time?)" → "missing required value: time (What time?)".
    public static string CleanFieldError(string message) => new Regex(@"^\d+:\s*").Replace(message, "", 1);

    /// The field a gateway refusal names.
    public static string? FieldNamed(string error, Blueprint blueprint)
    {
        var names = blueprint.Fields.Select(f => f.Name).ToList();
        var m = Regex.Match(error, @"missing required value:\s*([\w-]+)");
        if (m.Success && names.Contains(m.Groups[1].Value)) return m.Groups[1].Value;
        m = Regex.Match(error, @"^([\w-]+)=");
        if (m.Success && names.Contains(m.Groups[1].Value)) return m.Groups[1].Value;
        if (Regex.IsMatch(error, "invalid time|a time is required", RegexOptions.IgnoreCase)) return blueprint.Fields.FirstOrDefault(f => f.Type == "time")?.Name;
        if (Regex.IsMatch(error, "unknown recurrence", RegexOptions.IgnoreCase) && names.Contains("recurrence")) return "recurrence";
        if (Regex.IsMatch(error, "unknown day", RegexOptions.IgnoreCase) && names.Contains("day")) return "day";
        return null;
    }

    /// "08:15" → (8, 15); null for anything that is not a 24 h time.
    public static (int Hour, int Minute)? Time(string value)
    {
        var m = Regex.Match(value.Trim(), @"^(\d{1,2}):(\d{2})");
        if (!m.Success) return null;
        int h = int.Parse(m.Groups[1].Value), mi = int.Parse(m.Groups[2].Value);
        return h is >= 0 and <= 23 && mi is >= 0 and <= 59 ? (h, mi) : null;
    }

    public static string TimeValue(int hour, int minute) => $"{hour:00}:{minute:00}";

    /// A non-optional field is still blank (Create waits).
    public static bool IsIncomplete(Blueprint blueprint, IReadOnlyDictionary<string, string> values) =>
        blueprint.Fields.Any(f => !f.Optional && (values.TryGetValue(f.Name, out var v) ? v : "").Trim().Length == 0);

    /// Title and description contain the words (the Blueprints section follows the Jobs search).
    public static bool Matches(Blueprint blueprint, string words) => words.Length == 0
        || blueprint.Title.Contains(words, StringComparison.OrdinalIgnoreCase) || blueprint.Description.Contains(words, StringComparison.OrdinalIgnoreCase);
}
