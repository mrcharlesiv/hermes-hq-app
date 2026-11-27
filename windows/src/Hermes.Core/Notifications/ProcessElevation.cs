namespace Hermes.Core.Notifications;

/// [WIN-10 review] The app process's token as Windows App SDK judges it for toasts: `ElevationType` is TOKEN_ELEVATION_TYPE
/// (1 Default, 2 Full, 3 Limited) and `IntegrityRid` the last sub-authority of its TokenIntegrityLevel SID. The SDK's
/// AppNotificationManager.IsSupported() is false for an elevated process, packaged or not (WindowsAppSDK PR #2505;
/// dev/Common/Security.IntegrityLevel.h IsElevated: integrity at or above High), so a toast Windows won't take from such a
/// process is the "elevated process" gap, and "MSIX needed" is kept for a process that isn't elevated. The Mac has no such
/// case (UNUserNotificationCenter works for any process); the Windows app reads the token in NotificationsFeature.
public sealed record ProcessElevation(int ElevationType, uint IntegrityRid)
{
    /// SECURITY_MANDATORY_HIGH_RID.
    public const uint HighRid = 0x3000;

    public bool Elevated => IntegrityRid >= HighRid;

    public string Describe() => $"{TypeName(ElevationType)} ({ElevationType}), integrity {LevelName(IntegrityRid)} (0x{IntegrityRid:X4})";

    /// How the toasts walk labels a toast Windows didn't take: the real cause when the token says so.
    public static string GapLabel(ProcessElevation? process) => process switch
    {
        null => "open gap (elevation unknown)",
        { Elevated: true } => "open gap (elevated process)",
        _ => "open gap (MSIX needed)",
    };

    /// The registration error when IsSupported() is false, with the token's facts.
    public static string Unsupported(ProcessElevation? process) =>
        $"AppNotificationManager.IsSupported() is false ({process?.Describe() ?? "token unreadable"})";

    /// The app log line at registration; windows/ci/windows.yml copies the cold relaunch's into toast-cold.log.
    public static string LogLine(ProcessElevation? process) => process is null
        ? "process token: unreadable"
        : $"process token: {process.Describe()}; elevated: {(process.Elevated ? "yes" : "no")}";

    private static string TypeName(int type) => type switch
    {
        1 => "TokenElevationTypeDefault",
        2 => "TokenElevationTypeFull",
        3 => "TokenElevationTypeLimited",
        _ => $"TokenElevationType {type}",
    };

    private static string LevelName(uint rid) => rid switch
    {
        0x0000 => "Untrusted",
        0x1000 => "Low",
        0x2000 => "Medium",
        0x2100 => "MediumPlus",
        0x3000 => "High",
        0x4000 => "System",
        0x5000 => "ProtectedProcess",
        _ => $"0x{rid:X4}",
    };
}
