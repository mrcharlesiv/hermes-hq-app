// [WIN-SCREEN-SERVICE] "Set up with Hermes" (docs/spec/3x-screen.md §5.13), the C# twin of the Mac's
// HermesKit/Screen/ScreenSetup.swift at 93f984bb1: the words, the installer the app carries, and the request the bot's
// own chat receives. The web's `bot-screen-setup.ts` and `bot-screen-setup-view.tsx`. The app never unpacks or runs
// the installer: it is opaque data handed to the owner's own gateway, exactly as the web app handed it over.
//
// The installer itself (App/Resources/Screen/HermesHQScreenSetup.zip on the Mac, 550,200 bytes) ships beside the
// Windows app as `Screen/HermesHQScreenSetup.zip` ([WIN-SCREEN-SETUP-SEND]: src/HermesHQ.Windows/Screen, a Content item).
// `ScreenSetupBundle.Load()` refuses anything that is not the reviewed bytes, so a missing or altered copy stops the
// request with the installer error rather than sending something unreviewed.

using System.Security.Cryptography;
using System.Text.Json.Nodes;
using Hermes.Core.Gateways;

namespace Hermes.Core.Screen;

public static class ScreenSetupPrompt
{
    /// The web's prompt with one sentence reworded (DECISION D26: the gateway stores this text as the message, so it
    /// can be read in the chat later, and the pre-rename product name must never show on screen).
    public static readonly IReadOnlyList<string> Paragraphs =
    [
        $"Set up live Mac screen sharing for me in Hermes HQ on {HostWord.Phrase} for this chat. Do the setup yourself and verify it; do not send me a list of terminal commands.",
        "The attached hermes-hq-screen-setup source bundle came with Hermes HQ. Verify its SHA-256 against the value below before extracting it to a fresh directory with /usr/bin/ditto -x -k so executable permissions are preserved. Read hermes-hq-screen-setup/SETUP.md and scripts/setup-screen-helper.py, then run the installer by its absolute path with python3 and --control --wait-permissions 60 --json. Run it on the Mac hosting this gateway using an available host execution route; if your terminal runs in Docker or over SSH, verify the host route first and report a missing route as a blocker. If the bundle includes a signed Hermes HQ Screen.app, prefer that app and pass its absolute extracted path with --app so no compiler or signing identity is required on this Mac. The working directory is not assumed to contain the Hermes HQ repository. Use the attached bundle; do not invent a download URL or require a preexisting checkout. If the source attachment is unavailable, explain that exact blocker.",
        "Set up both viewing and remote control. This click authorizes installing the helper and plugin and enabling screen sharing and remote input with --control. Preserve the existing profile access and signing-team restrictions. The Mac's whole console will be visible to gateway users who have access to Screen. Keep its visible Stop sharing control. Ask me only for actions macOS requires me to take locally, such as approving Screen Recording, Accessibility, or an administrator password. Explain both permissions up front in one short checklist: Screen Recording lets me see the Mac; Accessibility lets me move its pointer, click, and type. Do not bypass macOS permissions, weaken signing checks, use ad hoc signing for the installed helper. If this Mac still has the older screen plugin or helper app from before the rename, the installer carries their settings over and removes them so only one helper runs (macOS keeps the existing permissions); if it reports it could not remove the old plugin, run the removal command it reports yourself. If Xcode, a suitable signing identity, or permission is missing, report the precise remaining requirement without claiming success.",
        "While I approve permissions, keep checking with the installer rather than asking me to send a new message after each approval. If macOS requires Quit & Reopen, relaunch only this helper using its existing launcher and check again. After a bounded wait, report the exact outstanding permission with a single next action; never claim it is ready early.",
        "Use the installer's check mode (--check --json --control) and hermes hq-screen doctor to verify the helper signature, plugin compatibility and Screen Recording. If Hermes must restart to load the plugin, use its existing managed service or launcher, preserve its arguments and profile, and make the restart survive this chat's connection closing. Do not kill unmanaged processes or restart unrelated services. After any restart, reconnect and verify the actual gateway answering Hermes HQ: /api/plugins/hermes-hq-screen/health must report installed and enabled, no drift or blocker, and a live helper with ok and tcc.screen true; this bot's display.status must report supported, installed, no missing dependencies or blocker, and This Mac. Start the display normally if the helper is idle. Verify health.control is true and helper.tcc.events is true for Accessibility. Viewing alone does not complete this request. Local setup is verified only after these live checks succeed. A successful build or installer exit alone is insufficient; report a pending restart or permission honestly. Then tell me to open this bot's Screen. Confirm live sharing only after an actual screen frame appears; the health checks alone do not prove the stream works.",
    ];

    public static readonly string Text = string.Join("\n\n", Paragraphs);
    /// SHA-256 of `Text` (3,953 UTF-8 bytes; UX study #24: "the computer running Hermes", was "the gateway computer"); a unit test holds the text to it.
    public const string Sha256 = "fb7b7a4dc80eae6c0a0ca41068874f2e22e22d494d9345c3f59009aca11c6107";
    /// What the chat shows for the request.
    public const string QueueTitle = "Set up live screen sharing on my Mac and verify it.";

    /// The message sent: the prompt, then where the gateway put the installer, its hash and the signed helper's path.
    public static string Message(string refText, string sha256, string? helperAppPath)
    {
        var out_ = $"{Text}\n\nInstaller source: {refText}\nSHA-256: {sha256}";
        if (!string.IsNullOrEmpty(helperAppPath)) out_ += $"\nSigned helper inside the bundle: {helperAppPath}";
        return out_;
    }
}

/// Why a setup request did not start (the Swift `ScreenSetupError` cases).
public enum ScreenSetupFailure { NotConnected, ChatDidNotOpen, ChatChanged, NotReady, ChangedWhilePreparing, Installer, ChangedBeforeStart, NotQueued }

/// Why a setup request did not start. The words are the web's. Equal when the case and the gateway's words are.
public sealed class ScreenSetupError(ScreenSetupFailure failure, string? said = null) : Exception(Words(failure, said)), IEquatable<ScreenSetupError>
{
    public const string AlertTitle = "Couldn’t Start Screen Setup";

    public ScreenSetupFailure Failure { get; } = failure;
    /// `.installer(String?)`: the gateway's own words, when it gave any.
    public string? Said { get; } = said;

    private static string Words(ScreenSetupFailure failure, string? said) => failure switch
    {
        ScreenSetupFailure.NotConnected => "This bot’s gateway is no longer connected.",
        ScreenSetupFailure.ChatDidNotOpen => "Hermes could not open this bot’s chat. Try again.",
        ScreenSetupFailure.ChatChanged => "The selected chat changed before setup could start.",
        ScreenSetupFailure.NotReady => "This bot’s chat did not become ready for setup. Try again.",
        ScreenSetupFailure.ChangedWhilePreparing => "The chat connection changed while preparing setup. Try again.",
        ScreenSetupFailure.Installer => string.IsNullOrEmpty(said) ? "Hermes could not receive the Mac screen installer. Try again." : said,
        ScreenSetupFailure.ChangedBeforeStart => "The chat connection changed before setup could start. Try again.",
        _ => "Hermes could not queue the setup request in this chat. Try again.",
    };

    public bool Equals(ScreenSetupError? other) => other != null && other.Failure == Failure && other.Said == Said;
    public override bool Equals(object? obj) => Equals(obj as ScreenSetupError);
    public override int GetHashCode() => HashCode.Combine(Failure, Said);
}

/// The installer source the app ships: the exact bytes public build 240 shipped. (The Swift has both a static and an
/// instance `filename` / `helperAppPath`; here the constants keep those names and the instance says `File` / `HelperApp`.)
public sealed record ScreenSetupBundle(string File, string DataUrl, string Sha256, string HelperApp)
{
    public const string Filename = "hermes-hq-screen-setup.zip";
    public const string Resource = "HermesHQScreenSetup";
    public const int ByteCount = 550_200;
    public const string ExpectedSha256 = "71ff241d0a3e803b8a457a9df5f91c14df48c1f227893d785974837af0c8de09";
    public const string HelperAppPath = "hermes-hq-screen-setup/Hermes HQ Screen.app";

    public static string Hex(byte[] data) => Convert.ToHexStringLower(SHA256.HashData(data));

    /// The resource's bytes, refused unless they are the bytes that were reviewed (never a silent send without it).
    public static ScreenSetupBundle Verified(byte[]? data)
    {
        if (data == null || data.Length != ByteCount) throw new ScreenSetupError(ScreenSetupFailure.Installer);
        var hash = Hex(data);
        if (hash != ExpectedSha256) throw new ScreenSetupError(ScreenSetupFailure.Installer);
        return new ScreenSetupBundle(Filename, "data:application/zip;base64," + Convert.ToBase64String(data), hash, HelperAppPath);
    }

    /// Where the app keeps the installer: `Screen/HermesHQScreenSetup.zip` beside it (the Mac's `Bundle.main` resource).
    public static string DefaultPath => System.IO.Path.Combine(AppContext.BaseDirectory, "Screen", Resource + ".zip");

    /// Reads and checks the installer off the calling thread.
    public static Task<ScreenSetupBundle> Load(string? path = null) => Task.Run(() =>
    {
        byte[]? data;
        try { data = System.IO.File.ReadAllBytes(path ?? DefaultPath); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or NotSupportedException or ArgumentException) { data = null; }
        return Verified(data);
    });
}

/// What the gateway answered to `file.attach`.
public static class ScreenSetupAttach
{
    /// The `ref_text` to name in the prompt; throws the gateway's own words when it did not take the file.
    public static string RefText(JsonNode? answer)
    {
        var raw = ScreenJson.Str(answer, "ref_text");
        var trimmed = raw?.Trim() ?? "";
        if (ScreenJson.Bool(answer, "attached") != true || trimmed.Length == 0)
            throw new ScreenSetupError(ScreenSetupFailure.Installer, ScreenJson.Str(answer, "message"));
        return raw ?? trimmed;
    }
}

/// The setup card's words (§5.13), exact.
public static class ScreenSetupCopy
{
    public static string Heading(bool controlOnly) => controlOnly ? "Enable Screen Control" : "Set Up Viewing and Control";
    public const string How = "Hermes will install the helper, enable viewing and control, and check both permissions in one setup. Follow its progress in your bot’s chat.";
    public const string Shares = "This shares your Mac’s entire screen and enables pointer and keyboard control for people with Screen access on your gateway. Approve Screen Recording to view, and Accessibility to click and type, on the Mac when prompted.";

    /// [screen-points] Owner 2026-11-10 (design pick 14): `How` and `Shares` as three short points, each led by its
    /// first words: what happens, what the Mac asks, and (the warning) what is shared and with whom. `Symbol` is the
    /// Mac's SF Symbol name; the Windows view maps it to its own glyph.
    public sealed record Point(string Symbol, string Lead, string Rest, bool Warning = false);

    public static readonly IReadOnlyList<Point> Points =
    [
        new("arrow.down.circle", "Hermes installs a small helper", " on your Mac and reports its progress in your bot’s chat."),
        new("checkmark.circle", "Your Mac asks you to approve", " Screen Recording to view, and Accessibility to click and type."),
        new("exclamationmark.triangle.fill", "Your whole screen is shared,",
            " with pointer and keyboard control, with people who have Screen access on your gateway.", Warning: true),
    ];

    public const string Update = "Hermes will also check whether your gateway needs an update.";
    public const string Requested = "Setup was requested in your bot’s chat. Hermes will report any permissions or requirements that still need attention.";
    public const string Windows = "Live screen sharing isn’t available on Windows yet. Your bot’s latest screenshots will appear here.";
    public const string Opening = "Opening setup…";

    public static string Primary(bool requested, bool controlOnly, bool working)
    {
        if (working) return Opening;
        if (requested) return "Continue with Hermes";
        return controlOnly ? "Enable Control with Hermes" : "Set Up with Hermes";
    }

    public static string Check(bool working) => working ? "Checking…" : "Check Setup";
}
