// [WIN-SCREEN-SESSION] The one value ScreenSession needs from the Mac's HermesKit/Screen/MacScreenHealth.swift at
// 93f984bb1: what a live Mac screen's plugin health says about control (docs/spec/3x-screen.md §5.10). The reader (the
// current and legacy health routes, the 8 s limit, one request at a time) and "Check setup"'s line are the next slice
// (ScreenService/MacScreenHealth); the session reads health through IScreenHealthReader.

using System.Text.Json.Nodes;

namespace Hermes.Core.Screen;

/// What a live Mac screen needs to know about control.
public sealed record MacScreen(bool Control = false, bool InputReady = false, bool Locked = false, bool SecureInput = false)
{
    /// null unless the plugin is installed (`installed === true`).
    public static MacScreen? Parse(JsonNode? health)
    {
        if (health == null || ScreenJson.Bool(health, "installed") != true) return null;
        var helper = health["helper"];
        var control = ScreenJson.Bool(health, "control") == true;
        return new MacScreen(control, control && ScreenJson.Bool(helper?["tcc"], "events") == true,
            ScreenJson.Bool(helper, "locked") == true, ScreenJson.Bool(helper, "secure_input") == true);
    }
}

/// The plugin's health route (the Swift `MacScreenHealthReader.read`): the answer as sent, null when the route does
/// not exist (404). Throws on any other failure; the session then keeps its last value.
public interface IScreenHealthReader
{
    Task<JsonNode?> ReadAsync();
}
