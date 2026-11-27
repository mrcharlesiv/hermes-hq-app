// [WIN-SCREEN-SERVICE] The Mac screen plugin's health (docs/spec/3x-screen.md §5.9, §5.10, §5.13): what it means for
// control, the route under its new and old names, and every line "Check setup" can show. The Mac's
// Tests/Screen/MacScreenTests.swift at 93f984bb1 (MacScreenTests + MacScreenReadinessTests), case for case.

using System.Text.Json.Nodes;
using Hermes.Core.Gateways;
using Hermes.Core.Net;
using Hermes.Core.Screen;

namespace Hermes.Core.Tests.Screen;

internal static class MacFixture
{
    public static JsonNode Health(Action<JsonObject>? change = null)
    {
        var value = new JsonObject
        {
            ["installed"] = true, ["ok"] = true, ["platform"] = "darwin", ["drift"] = new JsonArray(), ["enabled"] = true, ["control"] = true,
            ["helper"] = new JsonObject
            {
                ["ok"] = true, ["tcc"] = new JsonObject { ["screen"] = true, ["events"] = true }, ["locked"] = false, ["secure_input"] = false, ["paused"] = false,
            },
        };
        change?.Invoke(value);
        return JsonNode.Parse(value.ToJsonString())!;                // as it arrives off the wire
    }

    public static ScreenStatus Status(Func<ScreenStatus, ScreenStatus>? change = null)
    {
        var status = new ScreenStatus
        {
            ProfileKey = "default", Supported = true, Installed = true, Running = true, Missing = [], Display = "This Mac",
            Geometry = "1920x1080x24", InstallCommand = null, Blocker = null, Placement = null, Lease = new ScreenLease(),
        };
        return change == null ? status : change(status);
    }

    public static JsonNode Json(string text) => JsonNode.Parse(text)!;
}

/// A gateway's REST side for the health reader: an answer per path, and every path asked.
internal sealed class FakeRest : IScreenRest
{
    private readonly object _gate = new();
    private readonly List<string> _log = [];
    private Func<string, string> _answer = _ => "{}";

    public TimeSpan Delay { get; init; }
    public int Hits { get { lock (_gate) return _log.Count; } }
    public List<string> RestLog { get { lock (_gate) return [.. _log]; } }
    public void OnRest(Func<string, string> answer) { lock (_gate) _answer = answer; }

    public async Task<string> RestAsync(string method, string path, CancellationToken ct = default)
    {
        Func<string, string> answer;
        lock (_gate)
        {
            _log.Add(path);
            answer = _answer;
        }
        if (Delay > TimeSpan.Zero) await Task.Delay(Delay, ct);
        else await Task.Yield();
        return answer(path);
    }

    public static GatewayException Http(int status, string? body = null) => new("http", $"The gateway answered {status}.", status, body);
}

public sealed class MacScreenTests
{
    [Fact]
    public void ControlNeedsBothTheSettingAndAccessibility()
    {
        Assert.Equal(new MacScreen(Control: true, InputReady: true, Locked: false, SecureInput: false), MacScreen.Parse(MacFixture.Health()));
        Assert.Equal(new MacScreen(Control: false, InputReady: false), MacScreen.Parse(MacFixture.Health(h => h["control"] = false)));
        Assert.Equal(new MacScreen(Control: true, InputReady: false), MacScreen.Parse(MacFixture.Health(h =>
            h["helper"] = new JsonObject { ["ok"] = true, ["tcc"] = new JsonObject { ["screen"] = true, ["events"] = false } })));
        Assert.Equal(new MacScreen(Control: true, InputReady: true, Locked: true, SecureInput: true), MacScreen.Parse(MacFixture.Health(h =>
            h["helper"] = new JsonObject
            {
                ["ok"] = true, ["tcc"] = new JsonObject { ["screen"] = true, ["events"] = true }, ["locked"] = true, ["secure_input"] = true,
            })));
        Assert.Equal(new MacScreen(Control: true, InputReady: false), MacScreen.Parse(MacFixture.Health(h => h["helper"] = null)));
    }

    [Fact]
    public void OnlyAnInstalledPluginCounts()
    {
        Assert.Null(MacScreen.Parse(null));
        Assert.Null(MacScreen.Parse(MacFixture.Json("null")));
        Assert.Null(MacScreen.Parse(MacFixture.Json("""{"installed":false,"control":true}""")));
        Assert.Null(MacScreen.Parse(MacFixture.Json("""{"installed":"yes"}""")));
        Assert.Null(MacScreen.Parse(MacFixture.Json("[]")));
        Assert.Equal(new MacScreen(), MacScreen.Parse(MacFixture.Json("""{"installed":true}""")));
    }

    [Fact]
    public async Task TheOldRouteIsTriedOnA404AndAskedFirstAfterwards()
    {
        var client = new FakeRest();
        client.OnRest(path => path.Contains("hermes-hq-screen") ? throw FakeRest.Http(404) : """{"installed":true,"control":true}""");
        var reader = new MacScreenHealthReader(client);
        Assert.True((await reader.ReadAsync())?["installed"]?.GetValue<bool>() == true);
        Assert.Equal(["/api/plugins/hermes-hq-screen/health", "/api/plugins/dispatch-screen/health"], client.RestLog);
        _ = await reader.ReadAsync();
        Assert.Equal(["/api/plugins/dispatch-screen/health"], client.RestLog.TakeLast(1));
        Assert.Equal(3, client.RestLog.Count);
        Assert.Equal(MacScreenHealthReader.Route.Legacy, reader.Remembered);
    }

    [Fact]
    public async Task BothMissingIsNoPluginAndForgetsTheRememberedRoute()
    {
        var client = new FakeRest();
        var legacyGone = false;
        client.OnRest(path => path.Contains("hermes-hq-screen") || Volatile.Read(ref legacyGone) ? throw FakeRest.Http(404) : """{"installed":true}""");
        var reader = new MacScreenHealthReader(client);
        _ = await reader.ReadAsync();
        Volatile.Write(ref legacyGone, true);
        Assert.Null(await reader.ReadAsync());
        Assert.Null(reader.Remembered);
        // The plugin was updated: the new route answers and is asked first from then on.
        client.OnRest(_ => """{"installed":true}""");
        _ = await reader.ReadAsync();
        _ = await reader.ReadAsync();
        Assert.Equal(["/api/plugins/hermes-hq-screen/health", "/api/plugins/hermes-hq-screen/health"], client.RestLog.TakeLast(2));
    }

    [Fact]
    public async Task AnyOtherFailureIsThrownNotMistakenForMissing()
    {
        var client = new FakeRest();
        client.OnRest(_ => throw FakeRest.Http(500, "boom"));
        var reader = new MacScreenHealthReader(client);
        var failure = await Assert.ThrowsAsync<GatewayException>(reader.ReadAsync);
        Assert.Equal(500, failure.Status);
        Assert.Single(client.RestLog);                                          // no second route after a real failure
        // URLError(.notConnectedToInternet): a transport failure.
        client.OnRest(_ => throw new IOException("The Internet connection appears to be offline."));
        await Assert.ThrowsAsync<IOException>(reader.ReadAsync);
    }

    [Fact]
    public async Task OneRequestAtATime()
    {
        var client = new FakeRest { Delay = TimeSpan.FromMilliseconds(150) };
        client.OnRest(_ => """{"installed":true}""");
        var reader = new MacScreenHealthReader(client);
        var first = reader.ReadAsync();
        var second = reader.ReadAsync();
        var third = reader.ReadAsync();
        await Task.WhenAll(first, second, third);
        Assert.Equal(1, client.Hits);
        _ = await reader.ReadAsync();
        Assert.Equal(2, client.Hits);
    }

    [Fact]
    public async Task ARouteThatNeverAnswersTimesOut()
    {
        var started = DateTime.UtcNow;
        await Assert.ThrowsAsync<ScreenTimeout.Expired>(() => ScreenTimeout.Run(TimeSpan.FromMilliseconds(150), async ct =>
        {
            await Task.Delay(TimeSpan.FromSeconds(30), ct);
            return 0;
        }));
        Assert.True(DateTime.UtcNow - started < TimeSpan.FromSeconds(5));
        Assert.Equal(7, await ScreenTimeout.Run(TimeSpan.FromSeconds(5), _ => Task.FromResult(7)));
        Assert.Equal(TimeSpan.FromSeconds(8), MacScreenHealthReader.Limit);             // the route's own limit
    }
}

public sealed class MacScreenReadinessTests
{
    private static string Message(JsonNode? health, ScreenStatus? status) => MacScreenReadiness.Message(health, status);

    private static void Says(string expected, JsonNode? health) => Says(expected, health, MacFixture.Status());

    private static void Says(string expected, JsonNode? health, ScreenStatus? status) => Assert.Equal(expected, Message(health, status));

    private static void Helper(JsonObject health, JsonObject changes)
    {
        var value = health["helper"] as JsonObject ?? [];
        foreach (var (key, change) in changes.ToList())
        {
            changes.Remove(key);
            value[key] = change;
        }
        health["helper"] = (JsonObject)value.DeepClone();
    }

    [Fact]
    public void EveryLineInItsOrder()
    {
        // 1
        Says("The Mac screen plugin is not loaded in this gateway yet.", null);
        Says("The Mac screen plugin is not loaded in this gateway yet.", MacFixture.Health(h => h["installed"] = false));
        // 2
        Says("Live Mac screen sharing needs a Mac gateway.", MacFixture.Health(h => h["platform"] = "linux"));
        // 3
        const string drifted = "The screen plugin could not verify compatibility with this Hermes version.";
        Says(drifted, MacFixture.Health(h => h["ok"] = false));
        Says(drifted, MacFixture.Health(h => h["drift"] = new JsonArray("runtime changed")));
        Says(drifted, MacFixture.Health(h => h.Remove("drift")));
        // 4
        Says("Screen sharing is not enabled on the Mac yet.", MacFixture.Health(h => h["enabled"] = false));
        // 5
        Says("Allow Screen Recording", MacFixture.Health(h => h["blocker"] = "  Allow Screen Recording  "));
        Says("The Mac is asleep", MacFixture.Health(), MacFixture.Status(s => s with { Blocker = "The Mac is asleep" }));
        // 6
        Says("This bot does not have access to the Mac’s screen.", MacFixture.Health(), MacFixture.Status(s => s with { Supported = false }));
        Says("This bot does not have access to the Mac’s screen.", MacFixture.Health(), null);
        // 7
        const string loading = "This gateway has not finished loading the Mac screen setup.";
        Says(loading, MacFixture.Health(), MacFixture.Status(s => s with { Installed = false }));
        Says(loading, MacFixture.Health(), MacFixture.Status(s => s with { Missing = ["helper"] }));
        Says(loading, MacFixture.Health(), MacFixture.Status(s => s with { Display = ":99" }));
        // 8
        Says("The Mac screen helper has not answered yet. Open Screen to start it.", MacFixture.Health(h => h["helper"] = null));
        Says("The Mac screen helper has not answered yet. Open Screen to start it.", MacFixture.Health(h => h["helper"] = new JsonObject()));
        // 9
        Says("The Mac screen helper has not reported a healthy status yet.", MacFixture.Health(h => Helper(h, new JsonObject { ["ok"] = false })));
        // 10
        Says("Allow Screen Recording for Hermes HQ Screen on the Mac.", MacFixture.Health(h =>
            h["helper"] = new JsonObject { ["ok"] = true, ["tcc"] = new JsonObject { ["screen"] = false } }));
        Says("Allow Screen Recording for Hermes HQ Screen on the Mac.", MacFixture.Health(h =>
            h["helper"] = new JsonObject { ["ok"] = true, ["tcc"] = new JsonObject() }));
        // 11
        Says("Viewing is ready. Finish setup with Hermes to enable pointer, clicks, and typing.", MacFixture.Health(h => h["control"] = false));
        // 12
        Says("Allow Accessibility for Hermes HQ Screen on the Mac to use control.", MacFixture.Health(h =>
            h["helper"] = new JsonObject { ["ok"] = true, ["tcc"] = new JsonObject { ["screen"] = true, ["events"] = false } }));
        // 13
        Says("Resume sharing from Hermes HQ Screen’s menu on the Mac.", MacFixture.Health(h => Helper(h, new JsonObject { ["paused"] = true })));
        // 14
        Says("Display disconnected", MacFixture.Health(h => Helper(h, new JsonObject { ["capture_error"] = "Display disconnected" })));
        // 15
        Says("The Mac screen helper is ready. Open Screen to start sharing.", MacFixture.Health(), MacFixture.Status(s => s with { Running = false }));
        // 16. The Mac's "tap" is this app's DeviceWord.Tap ("click").
        Says("Viewing and control are ready. Open Screen, then click Take Control to use the pointer and keyboard.", MacFixture.Health());
        Assert.Equal(MacScreenReadiness.Ready, Message(MacFixture.Health(), MacFixture.Status()));
        Assert.Equal($"Viewing and control are ready. Open Screen, then {DeviceWord.Tap} Take Control to use the pointer and keyboard.", MacScreenReadiness.Ready);
    }

    [Fact]
    public void EarlierLinesWin()
    {
        // Not installed beats everything; a blocker beats the bot's own state; Screen Recording beats control.
        Says("The Mac screen plugin is not loaded in this gateway yet.", MacFixture.Health(h => { h["installed"] = false; h["blocker"] = "x"; }));
        Says("Allow Screen Recording", MacFixture.Health(h => h["blocker"] = "Allow Screen Recording"), MacFixture.Status(s => s with { Supported = false }));
        Says("Allow Screen Recording for Hermes HQ Screen on the Mac.", MacFixture.Health(h =>
        {
            h["control"] = false;
            h["helper"] = new JsonObject { ["ok"] = true, ["tcc"] = new JsonObject { ["screen"] = false } };
        }));
    }

    [Fact]
    public void TheGatewaysWordsNeverCarryTheOldName()
    {
        var said = Message(MacFixture.Health(h => h["blocker"] = "Open Dispatch Screen and allow Screen Recording"), MacFixture.Status());
        Assert.DoesNotContain("dispatch", said.ToLowerInvariant());
        Assert.Contains("Hermes HQ Screen", said);
        var capture = Message(MacFixture.Health(h => h["helper"] = new JsonObject
        {
            ["ok"] = true, ["tcc"] = new JsonObject { ["screen"] = true, ["events"] = true }, ["capture_error"] = "dispatch-screen lost the display",
        }), MacFixture.Status());
        Assert.DoesNotContain("dispatch", capture.ToLowerInvariant());
    }
}
