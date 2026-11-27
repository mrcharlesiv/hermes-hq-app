using System.Text.Json.Nodes;
using Hermes.Core.Insights;

namespace Hermes.Core.Shell;

/// [WIN-STAR-FIRST] The checks behind the star-map-first-open walk (Services/ProofWalks.StarMapFirstOpen.cs) on the More
/// pages' stand-in (windows/ci/fixtures/morepages-gateway.py, its learning.py module). Each control is set on the
/// stand-in BEFORE a fresh Star Map page opens, and that page's first read is judged with no retry:
///   Seeded       the seeded graph (60 skills in 12 categories, 40 memories): the Map drawn with stars and links, the
///                count line "60 skills across 12 categories".
///   Error        the read answers 500 with the gateway's reason: "Couldn’t Load Star Map", that reason, Try Again.
///   Empty        nothing learned (nodes 0): "Nothing Learned Yet", no count line, no Try Again.
///   Unsupported  the route is not there (404 "Not Found", what the stand-in's --old-gateway answers): "Not Available on
///                This Hermes", no Try Again, no Bot picker over it (StarMapModel.isUnavailable).
///   Bare         the read answers 200 with `{}` (the performance stand-in's answer, run 45034520666 line 86): the same
///                "Not Available on This Hermes" (PagesREST.unreadable / MoreWire.isEmptyAnswer on the Mac).
/// Each check answers null for what the Mac shows and names what is wrong otherwise. Nothing here reads a PNG.
public static class StarMapFirstOpenWalkProof
{
    public enum Control { Seeded, Error, Empty, Unsupported, Bare }

    public static readonly Control[] Order = [Control.Seeded, Control.Error, Control.Empty, Control.Unsupported, Control.Bare];

    public const string Walk = "star-map-first-open";
    public const string FailDetail = "Failed to build learning graph";
    public const int SeedSkills = 60, SeedMemory = 40, SeedCategories = 12;
    /// Skills and memories are both stars on the Map.
    public const int SeedStars = SeedSkills + SeedMemory;
    public const string ErrorTitle = "Couldn’t Load Star Map";
    public const string EmptyTitle = "Nothing Learned Yet";

    // The automation ids the page gives each state (Features/Insights/StarMapPage.cs).
    public const string MapId = "starmap.canvas", ListId = "starmap.list", ErrorId = "starmap.error", EmptyId = "starmap.empty",
        UnavailableId = "starmap.unavailable", FilterMissId = "starmap.filter-miss", LoadingId = "more.page.loading";
    /// What the walk looks for, in this order; the first one showing is the page's state.
    public static readonly string[] StateIds = [ErrorId, EmptyId, UnavailableId, FilterMissId, LoadingId, MapId, ListId];

    public static string SeedSubtitle => StarMapRules.Subtitle(SeedSkills, SeedCategories);

    public static string Name(Control c) => c.ToString().ToLowerInvariant();

    /// `POST /__fixture/graph` for a control: every knob set, so nothing a previous control left lingers.
    public static JsonObject Knobs(Control c)
    {
        var o = new JsonObject
        {
            ["nodes"] = c == Control.Empty ? 0 : SeedSkills, ["edges"] = null, ["memory"] = SeedMemory, ["delay"] = 0,
            ["fail"] = null, ["bare"] = c == Control.Bare,
        };
        if (c == Control.Error) o["fail"] = new JsonObject { ["status"] = 500, ["count"] = 1, ["detail"] = FailDetail };
        if (c == Control.Unsupported) o["fail"] = new JsonObject { ["status"] = 404, ["count"] = 1, ["detail"] = "Not Found" };
        return o;
    }

    /// Graph reads the stand-in has answered (`GET /__fixture/state` → learning.served.graph); -1 when it doesn't say.
    public static int Served(JsonNode? state) =>
        state?["learning"]?["served"]?["graph"] is JsonValue v && v.TryGetValue(out int n) ? n : -1;

    /// What the walk saw on the fresh page once its first read had settled.
    public sealed record Seen(
        string Phase, string? StateId, IReadOnlyList<string> StateTexts, bool RetryShown, bool PickerShown,
        string? Subtitle, int Skills, int Cards, int Stars, int Edges, int DrawnStars, int DrawnEdges,
        int PageReads, int Retries, string Profile);

    /// Null when the first opening under `c` shows what the Mac shows from exactly one read (the page's and the
    /// stand-in's counts agree); the first thing wrong otherwise.
    public static string? Check(Control c, Seen s, int servedBefore, int servedAfter)
    {
        if (servedBefore < 0 || servedAfter < 0) return "the stand-in doesn't report its graph reads";
        if (s.Retries != 0) return $"the page was retried {s.Retries} times; the first opening must stand alone";
        if (s.PageReads != 1) return $"the page read the graph {s.PageReads} times on its first opening";
        if (servedAfter - servedBefore != 1) return $"the stand-in answered {servedAfter - servedBefore} graph reads for one opening";
        if (s.Profile != "default") return $"the first opening read bot {s.Profile}, not the default bot";
        bool Says(string text) => s.StateTexts.Any(t => t == text);
        string Texts() => string.Join(" | ", s.StateTexts);
        switch (c)
        {
            case Control.Seeded:
                if (s.Phase != "loaded") return $"the seeded graph left the page {s.Phase}";
                if (s.StateId is not (MapId or ListId)) return $"the seeded graph shows {s.StateId ?? "nothing"}, not the Map or the List";
                if (s.Subtitle != SeedSubtitle) return $"the count line reads \"{s.Subtitle}\", not \"{SeedSubtitle}\"";
                if (s.Skills != SeedSkills) return $"{s.Skills} skills on show, not {SeedSkills}";
                if (s.Cards != SeedMemory) return $"{s.Cards} memory cards, not {SeedMemory}";
                if (s.Stars != SeedStars) return $"the layout has {s.Stars} stars, not {SeedStars}";
                if (s.Edges <= 0) return "the layout has no links";
                if (s.StateId == MapId && s.DrawnStars <= 0) return "the Map drew no stars";
                if (s.StateId == MapId && s.DrawnEdges <= 0) return "the Map drew no links";
                return null;
            case Control.Error:
                if (s.Phase != "failed") return $"a 500 left the page {s.Phase}";
                if (s.StateId != ErrorId) return $"a 500 shows {s.StateId ?? "nothing"}, not the error state";
                if (!Says(ErrorTitle)) return $"the error state reads \"{Texts()}\", without \"{ErrorTitle}\"";
                if (!Says(FailDetail)) return $"the error state reads \"{Texts()}\", without the gateway's reason";
                if (!s.RetryShown) return "the error state has no Try Again";
                if (s.Subtitle != null) return "a count line shows over the error";
                return null;
            case Control.Empty:
                if (s.Phase != "loaded") return $"an empty graph left the page {s.Phase}";
                if (s.StateId != EmptyId) return $"an empty graph shows {s.StateId ?? "nothing"}, not Nothing Learned Yet";
                if (!Says(EmptyTitle)) return $"the empty state reads \"{Texts()}\"";
                if (s.RetryShown) return "the empty state offers Try Again";
                if (s.Subtitle != null) return "a count line shows over the empty state";
                return null;
            default:
                if (s.Phase != "failed") return $"{Name(c)} left the page {s.Phase}";
                if (s.StateId != UnavailableId) return $"{Name(c)} shows {s.StateId ?? "nothing"}, not Not Available on This Hermes";
                if (!Says(InsightsWire.NotAvailableTitle)) return $"the unavailable state reads \"{Texts()}\"";
                if (!Says(InsightsWire.NotAvailableBody("Star Map"))) return $"the unavailable state's line reads \"{Texts()}\"";
                if (s.RetryShown) return "the unavailable state offers Try Again";
                if (s.PickerShown) return "the Bot picker shows over Not Available on This Hermes";
                if (s.Subtitle != null) return "a count line shows over the unavailable state";
                return null;
        }
    }

    /// The states must stay apart: the error, the empty map and the missing route each have their own id and title.
    public static string? Distinct(IReadOnlyDictionary<Control, Seen> seen)
    {
        foreach (var c in Order) if (!seen.ContainsKey(c)) return $"no {Name(c)} opening was seen";
        var error = seen[Control.Error]; var empty = seen[Control.Empty]; var missing = seen[Control.Unsupported];
        if (new[] { error.StateId, empty.StateId, missing.StateId, seen[Control.Seeded].StateId }.Distinct().Count() != 4)
            return "the seeded, error, empty and unavailable openings don't each show their own state";
        if (missing.StateTexts.Contains(EmptyTitle) || empty.StateTexts.Contains(InsightsWire.NotAvailableTitle))
            return "the empty and unavailable states share words";
        if (seen[Control.Bare].StateId != missing.StateId) return "`{}` and a missing route don't read the same";
        return null;
    }
}
