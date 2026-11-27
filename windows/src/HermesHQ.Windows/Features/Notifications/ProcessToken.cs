using System.ComponentModel;
using System.Runtime.InteropServices;
using Hermes.Core.Notifications;

namespace HermesHQ.Features.Notifications;

/// [WIN-10 review] Reads this process's TokenElevationType and TokenIntegrityLevel (the facts Windows App SDK's
/// AppNotificationManager.IsSupported() turns on), for the notify log line and the toasts walk's gap label.
internal static class ProcessToken
{
    private const uint TokenQuery = 0x0008;
    private const int TokenElevationTypeClass = 18, TokenIntegrityLevelClass = 25;

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool GetTokenInformation(IntPtr token, int infoClass, IntPtr info, int length, out int returned);

    [DllImport("advapi32.dll")]
    private static extern IntPtr GetSidSubAuthority(IntPtr sid, uint index);

    [DllImport("advapi32.dll")]
    private static extern IntPtr GetSidSubAuthorityCount(IntPtr sid);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    /// The token's facts, or null with `error` naming the call that failed and its Win32 error.
    public static ProcessElevation? Read(out string? error)
    {
        error = null;
        if (!OpenProcessToken(GetCurrentProcess(), TokenQuery, out var token))
        {
            error = $"OpenProcessToken: {new Win32Exception(Marshal.GetLastWin32Error()).Message}";
            return null;
        }
        try
        {
            var type = Marshal.AllocHGlobal(sizeof(int));
            try
            {
                if (!GetTokenInformation(token, TokenElevationTypeClass, type, sizeof(int), out _))
                {
                    error = $"TokenElevationType: {new Win32Exception(Marshal.GetLastWin32Error()).Message}";
                    return null;
                }
                GetTokenInformation(token, TokenIntegrityLevelClass, IntPtr.Zero, 0, out var needed);
                if (needed <= 0)
                {
                    error = $"TokenIntegrityLevel size: {new Win32Exception(Marshal.GetLastWin32Error()).Message}";
                    return null;
                }
                var label = Marshal.AllocHGlobal(needed);
                try
                {
                    if (!GetTokenInformation(token, TokenIntegrityLevelClass, label, needed, out _))
                    {
                        error = $"TokenIntegrityLevel: {new Win32Exception(Marshal.GetLastWin32Error()).Message}";
                        return null;
                    }
                    // TOKEN_MANDATORY_LABEL { SID_AND_ATTRIBUTES Label }: its first field is the SID pointer.
                    var sid = Marshal.ReadIntPtr(label);
                    var count = Marshal.ReadByte(GetSidSubAuthorityCount(sid));
                    var rid = unchecked((uint)Marshal.ReadInt32(GetSidSubAuthority(sid, (uint)(count - 1))));
                    return new ProcessElevation(Marshal.ReadInt32(type), rid);
                }
                finally { Marshal.FreeHGlobal(label); }
            }
            finally { Marshal.FreeHGlobal(type); }
        }
        finally { CloseHandle(token); }
    }
}
