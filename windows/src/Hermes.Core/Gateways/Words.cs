namespace Hermes.Core.Gateways;

/// The device's name in user-facing wording (Shared/DeviceWord.swift). The Windows app is the Mac app's twin, so it
/// takes the Mac's words with Windows names: "PC" for "Mac", "click" for "tap", the Credential Locker for the Keychain.
public static class DeviceWord
{
    public const string Name = "PC";
    public const string System = "Windows";
    /// Where a sign-in is kept: "macOS Keychain" on the Mac.
    public const string Keychain = "Windows Credential Locker";
    public const string Tap = "click", TapCap = "Click";
    public const string Subject = "your PC", SubjectCap = "Your PC";

    /// "Set on this PC only."
    public static string OnlyHere => $"Set on this {Name} only.";
}

/// The computer the bots run on, in user-facing wording: one phrase everywhere, never "gateway" (Shared/DeviceWord.swift).
public static class HostWord
{
    public const string Phrase = "the computer running Hermes";
    public const string Sentence = "The computer running Hermes";

    private static volatile string? _gatewayName;

    /// The gateway in use by its name ("Studio"), so "too old" messages say "Update Hermes on Studio"; set when the
    /// gateway changes (null: none, and the messages keep the phrase).
    public static string? GatewayName { get => _gatewayName; set => _gatewayName = value; }

    /// What "Update Hermes on …" names: the gateway in use, else the computer running Hermes.
    public static string UpdateTarget => GatewayName ?? Phrase;
}
