// [WIN-SCREEN-SERVICE] The Mac screen plugin's health (docs/spec/3x-screen.md §2.4, §5.10, §5.13), the C# twin of the
// Mac's HermesKit/Screen/MacScreenHealth.swift at 93f984bb1: the route under its current name and the one from before
// the rename (an older install still answers there), and the one line "Check setup" shows. The old route's name is in
// code only, never on screen. (MacScreen, the value the session reads, is in MacScreen.cs.)
//
// Nothing here reads this computer: the "Mac" is the computer running Hermes, and its health is a REST route on that
// gateway, so a Windows app reads it exactly as the Mac app does. A gateway on Windows or Linux answers with a
// platform other than "darwin" (or 404 when the plugin is absent), which reads as "Live Mac screen sharing needs a Mac
// gateway." / "not loaded"; no Windows-side health reading is needed.

using System.Text.Json;
using System.Text.Json.Nodes;
using Hermes.Core.Gateways;
using Hermes.Core.Net;

namespace Hermes.Core.Screen;

/// The gateway's REST side as the health reader asks it (the Swift `GatewayClient.rest`). Returns the body; a refused
/// call throws GatewayException("http", …) with its status, as GatewaySession.HttpError does.
public interface IScreenRest
{
    Task<string> RestAsync(string method, string path, CancellationToken ct = default);
}

/// Reads the health route, remembering which name answered. One per account.
public sealed class MacScreenHealthReader(IScreenRest rest) : IScreenHealthReader
{
    public enum Route { Current, Legacy }

    public const string CurrentPath = "/api/plugins/hermes-hq-screen/health";
    public const string LegacyPath = "/api/plugins/dispatch-screen/health";
    /// Each route's limit (`ScreenTimeout.run(.seconds(8))`).
    public static readonly TimeSpan Limit = TimeSpan.FromSeconds(8);

    public static string PathOf(Route route) => route == Route.Current ? CurrentPath : LegacyPath;

    private readonly object _gate = new();
    private Route? _remembered;
    private Task<JsonNode?>? _inFlight;

    public Route? Remembered { get { lock (_gate) return _remembered; } }

    /// The health answer, null when neither route exists (404). Never more than one request at a time: a second
    /// caller joins the first. Throws on any other failure (the caller keeps its last value).
    public Task<JsonNode?> ReadAsync()
    {
        lock (_gate)
        {
            if (_inFlight is { IsCompleted: false } running) return running;
            var task = Task.Run(FetchAsync);
            _inFlight = task;
            return task;
        }
    }

    private async Task<JsonNode?> FetchAsync()
    {
        Route[] order = Remembered == Route.Legacy ? [Route.Legacy, Route.Current] : [Route.Current, Route.Legacy];
        foreach (var route in order)
        {
            try
            {
                var text = await ScreenTimeout.Run(Limit, ct => rest.RestAsync("GET", PathOf(route), ct)).ConfigureAwait(false);
                lock (_gate) _remembered = route;
                return Parse(text);
            }
            catch (GatewayException e) when (e is { Code: "http", Status: 404 })
            {
            }
        }
        lock (_gate) _remembered = null;
        return null;
    }

    /// `(try? JSONValue.parse(data)) ?? .null`: an answer that is not JSON reads as JSON null (here: null, which every
    /// reader of the health treats as the Swift's .null: not installed).
    private static JsonNode? Parse(string text)
    {
        try { return JsonNode.Parse(text); }
        catch (JsonException) { return null; }
    }
}

public static class ScreenTimeout
{
    public sealed class Expired() : Exception("The screen request took too long.");

    /// `work`, or `Expired` when it takes longer than `limit` (the work is cancelled through its token). A cancelled
    /// `ct` is a cancellation, not an expiry.
    public static async Task<T> Run<T>(TimeSpan limit, Func<CancellationToken, Task<T>> work, CancellationToken ct = default)
    {
        using var job = CancellationTokenSource.CreateLinkedTokenSource(ct);
        job.CancelAfter(limit);
        try
        {
            return await work(job.Token).ConfigureAwait(false);
        }
        catch (Exception) when (job.IsCancellationRequested && !ct.IsCancellationRequested)
        {
            throw new Expired();
        }
    }
}

/// "Check setup": the first line that applies (the web's macScreenReadiness, in its order).
public static class MacScreenReadiness
{
    public const string Ready = $"Viewing and control are ready. Open Screen, then {DeviceWord.Tap} Take Control to use the pointer and keyboard.";

    private static JsonNode? At(JsonNode? node, string key) => node is JsonObject o && o.TryGetPropertyValue(key, out var v) ? v : null;

    private static string? Text(JsonNode? value) => ScreenJson.AsString(value) is { } raw && ScreenWire.Plain(raw) is { Length: > 0 } text ? text : null;

    public static string Message(JsonNode? health, ScreenStatus? status)
    {
        if (ScreenJson.Bool(health, "installed") != true) return "The Mac screen plugin is not loaded in this gateway yet.";
        if (ScreenJson.Str(health, "platform") != "darwin") return "Live Mac screen sharing needs a Mac gateway.";
        if (ScreenJson.Bool(health, "ok") != true || At(health, "drift") is not JsonArray { Count: 0 })
            return "The screen plugin could not verify compatibility with this Hermes version.";
        if (ScreenJson.Bool(health, "enabled") != true) return "Screen sharing is not enabled on the Mac yet.";
        if ((Text(At(health, "blocker")) ?? (status?.Blocker is { Length: > 0 } b ? b : null)) is { } blocker) return blocker;
        if (status?.Supported != true) return "This bot does not have access to the Mac’s screen.";
        if (status.Installed != true || status.Missing.Count > 0 || !status.IsMac)
            return "This gateway has not finished loading the Mac screen setup.";
        var helper = At(health, "helper");
        if (helper is not JsonObject { Count: > 0 }) return "The Mac screen helper has not answered yet. Open Screen to start it.";
        if (ScreenJson.Bool(helper, "ok") != true) return "The Mac screen helper has not reported a healthy status yet.";
        var tcc = At(helper, "tcc");
        if (ScreenJson.Bool(tcc, "screen") != true) return "Allow Screen Recording for Hermes HQ Screen on the Mac.";
        if (ScreenJson.Bool(health, "control") != true) return "Viewing is ready. Finish setup with Hermes to enable pointer, clicks, and typing.";
        if (ScreenJson.Bool(tcc, "events") != true) return "Allow Accessibility for Hermes HQ Screen on the Mac to use control.";
        if (ScreenJson.Bool(helper, "paused") == true) return "Resume sharing from Hermes HQ Screen’s menu on the Mac.";
        if (Text(At(helper, "capture_error")) is { } capture) return capture;
        if (status.Running != true) return "The Mac screen helper is ready. Open Screen to start sharing.";
        return Ready;
    }
}
