using Hermes.Core.Shell;
using HermesHQ.Features.Insights;
using HermesHQ.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Proof = Hermes.Core.Shell.StarMapFirstOpenWalkProof;

namespace HermesHQ.Services;

/// [WIN-STAR-FIRST] The CI's walk for Star Map's first opening (windows/ci/windows.yml asks for it on its own More pages
/// stand-in, morepages-gateway.py, with no places before it), backed by `Hermes.Core.Shell.StarMapFirstOpenWalkProof`:
///   star-map-first-open  For each control (seeded, error, empty, unsupported, bare) the stand-in is set first, then a
///                        fresh Star Map opens and its first read is judged with no retry: the page's own read count, the
///                        stand-in's served count (exactly one each), the state on show by its automation id, its words
///                        read from the screen, Try Again, the Bot picker and the count line. Seeded: the Map drawn with
///                        stars and links, "60 skills across 12 categories" ("star-map-first-seeded"). Error: Couldn’t
///                        Load Star Map with the gateway's reason and Try Again ("star-map-first-error"). Empty: Nothing
///                        Learned Yet ("star-map-first-empty"). Unsupported (404 Not Found) and bare (200 `{}`): Not
///                        Available on This Hermes, no Try Again, no Bot picker ("star-map-first-unsupported",
///                        "star-map-first-bare"). Then the four states are checked apart and the stand-in is seeded again.
/// It clicks nothing on the page: any read past the first fails it.
internal static partial class ProofWalks
{
    private static void RegisterStarMapFirstOpenWalks()
    {
        Automation.NamedWalks["star-map-first-open"] = StarMapFirstOpenAsync;
    }

    private static async Task StarMapFirstOpenAsync(Func<string, Task> shot)
    {
        var client = AppState.Client ?? throw new InvalidOperationException("not signed in");
        var url = client.Session.Address.ToString();
        var seen = new Dictionary<Proof.Control, Proof.Seen>();
        try
        {
            foreach (var control in Proof.Order)
            {
                var name = Proof.Name(control);
                // A fresh page: leave any Star Map on show first (pages aren't cached, so the next opening builds anew).
                if (StarMapPage.Current != null)
                {
                    Navigator.Open("usage");
                    await Until(() => StarMapPage.Current == null ? new object() : null, "Star Map to close");
                }
                await StandInPost(url, "/__fixture/graph", Proof.Knobs(control));
                var before = Proof.Served(await StandIn(url, "/__fixture/state"));

                Navigator.Open("star-map");
                var page = await Until(() => StarMapPage.Current is { IsLoaded: true, PhaseWord: not "loading" } p ? p : null,
                    $"the {name} opening's first read", 20);
                // The state the read settled on, laid out on screen (the Map's canvas is in the tree once it is loaded).
                var settled = await Until(() => Proof.StateIds.Select(id => Find(id)).FirstOrDefault(e => e != null && Id(e) != Proof.LoadingId),
                    $"the {name} opening's state on screen");
                if (Id(settled) == Proof.MapId && page.ShownStars > 0)
                    await Until(() => page.DrawnStars > 0 && page.MapSettled ? page : null, "the Map's stars", 15);
                // Long enough for a second read (a hidden retry) to reach the stand-in before it is counted.
                await Task.Delay(1500);
                var after = Proof.Served(await StandIn(url, "/__fixture/state"));
                if (!ReferenceEquals(StarMapPage.Current, page)) throw new InvalidOperationException($"the {name} opening's page was replaced");

                var state = Proof.StateIds.Select(id => Find(id)).FirstOrDefault(e => e != null);
                var texts = state == null ? new List<string>() : Shown(state).OfType<TextBlock>().Select(t => t.Text).Where(t => t.Length > 0).ToList();
                var subtitle = Find("starmap.subtitle") is TextBlock { Text.Length: > 0 } sub ? sub.Text : null;
                var s = new Proof.Seen(page.PhaseWord, state == null ? null : Id(state), texts,
                    RetryShown: state != null && FindIn(state, "more.page.retry") != null, PickerShown: Find("more.bot-picker") != null,
                    subtitle, page.ShownSkills, page.ShownCards, page.ShownStars, page.ShownEdges, page.DrawnStars, page.DrawnEdges,
                    page.GraphReads, page.Retries, page.Profile);
                AppLog.Note("automation", $"walk {Proof.Walk}: {name}: {s.Phase}, {s.StateId ?? "no state"}, \"{string.Join(" | ", texts.Take(3))}\", "
                    + $"{s.Skills} skills, {s.Cards} cards, {s.DrawnStars} stars and {s.DrawnEdges} links drawn, {s.PageReads} read(s), "
                    + $"stand-in served {after - before}");
                if (Proof.Check(control, s, before, after) is { } wrong) throw new InvalidOperationException($"{name}: {wrong}");
                seen[control] = s;
                switch (control)
                {
                    case Proof.Control.Seeded:
                        await shot("star-map-first-seeded");
                        await shot("star-map-first-open");
                        break;
                    case Proof.Control.Error: await shot("star-map-first-error"); break;
                    case Proof.Control.Empty: await shot("star-map-first-empty"); break;
                    case Proof.Control.Unsupported: await shot("star-map-first-unsupported"); break;
                    case Proof.Control.Bare: await shot("star-map-first-bare"); break;
                }
            }
            if (Proof.Distinct(seen) is { } mixed) throw new InvalidOperationException(mixed);
            AppLog.Note("automation", $"walk {Proof.Walk}: seeded, error, empty and unavailable each showed their own state on a first opening");
        }
        finally
        {
            try { await StandInPost(url, "/__fixture/graph", Proof.Knobs(Proof.Control.Seeded)); }
            catch (Exception e) { AppLog.Note("automation", $"walk {Proof.Walk}: couldn't seed the stand-in again: {e.Message}"); }
        }
    }
}
