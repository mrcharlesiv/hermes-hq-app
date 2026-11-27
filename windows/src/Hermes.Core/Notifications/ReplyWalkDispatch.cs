using System.Text.Json.Nodes;

namespace Hermes.Core.Notifications;

/// One dispatch loop over the original parsed plan. The reserved name never reaches the ordinary lookup.
/// This class has no desktop, sign-in, notification or input capability of its own.
public sealed class ReplyWalkDispatch(JsonNode? plan,
    IReadOnlyDictionary<string, Func<Func<string, Task>, Task>> named,
    IReadOnlyDictionary<string, Func<Func<string, Task>, ToastQuietProbe, Task>> bound)
{
    private QuietWalkStopped? stopped;
    private bool entered;
    private readonly JsonNode? originalReply = plan.Arr("extras") is { Count: > 0 } xs && xs[^1].Str("tag") == "toasts" ? xs[^1] : null;

    private bool IsLast(JsonNode extra) => plan.Arr("extras") is { Count: > 0 } xs && ReferenceEquals(extra, xs[^1]);
    public bool Reserves(JsonNode extra) => (originalReply != null && (ReferenceEquals(extra, originalReply) || IsLast(extra)))
        || extra.Str("tag") == "toasts" || extra.Arr("walks")?.Any(n => J.AsString(n) == "toasts") == true;

    public void RequireUnique()
    {
        if (stopped != null) throw stopped;
        if (named.ContainsKey("toasts") || bound.Count != 1 || !bound.ContainsKey("toasts"))
            throw stopped = QuietWalkStopped.RouteNotUnique();
    }

    public void RequireSelection(JsonNode extra)
    {
        RequireUnique();
        if (!ReferenceEquals(extra, originalReply) || !IsLast(extra)) throw stopped = new QuietWalkStopped("dispatch", "not-reply-walk");
    }

    public async Task RunAsync<T>(JsonNode extra, string tag, string walkName, T session,
        Func<JsonNode?, JsonNode, string, T, ToastQuietProbe> bind, Func<string, Task> shot,
        Func<string, ToastQuietProbe, Task> boundShot) where T : class
    {
        if (stopped != null) throw stopped;
        if (tag == "toasts" || walkName == "toasts" || Reserves(extra))
        {
            try
            {
                RequireSelection(extra);
                if (tag != "toasts" || walkName != "toasts" || entered) throw QuietWalkStopped.RouteNotUnique();
                entered = true;
                var walk = bound["toasts"];
                var quiet = bind(plan, extra, walkName, session);
                quiet.Checkpoint(QuietPoint.Entry);
                await walk(name => boundShot(name, quiet), quiet);
                quiet.RecheckChat();
            }
            catch (QuietWalkStopped stop) { stopped = stop; throw; }
            catch (Exception e) when (e is not OutOfMemoryException) { throw stopped = QuietWalkStopped.Incomplete(); }
            return;
        }
        if (!named.TryGetValue(walkName, out var ordinary)) throw new InvalidOperationException($"no walk named {walkName}");
        await ordinary(shot);
    }

    // The existing separate contrast step has no push projection or baseline and asks for just one of these
    // two exact single-walk passes. An extrasOnly flag alone must never exempt a full plan from preflight.
    public static bool IsContrastPass(JsonNode? config) => config is JsonObject obj && !obj.ContainsKey("url")
        && obj["extrasOnly"] is JsonValue flag && flag.TryGetValue<bool>(out var only) && only
        && obj["extras"] is JsonArray { Count: 1 } extras && extras[0] is JsonObject extra
        && extra.Arr("places") is { Count: 0 } && extra.Arr("walks") is { Count: 1 } walks
        && extra.Str("tag") is { } tag && J.AsString(walks[0]) == tag
        && (tag, extra.Str("url")) is ("text-scale", "http://127.0.0.1:9863") or ("high-contrast", "http://127.0.0.1:9864");
}