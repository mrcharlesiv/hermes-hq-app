using System.Runtime.InteropServices;
using System.Text.Json.Nodes;
using Hermes.Core.Net;
using Hermes.Core.Notifications;
using HermesHQ.Features.Notifications;
using Microsoft.Windows.AppNotifications;

namespace HermesHQ.Services;

/// In-process only. No startup hook or standalone command. The reviewed named-walk dispatcher supplies its actual
/// selected extra, walk name and adopted fixture session. There is no log-only read API; see ci/toast-quiet.md.
internal static partial class ReplyQuietReadback
{
    private const string ChatA = "20260929_120000_aabbcc02", ChatB = "20260929_120000_aabbcc01";

    internal static void RequirePlan(JsonNode? config) =>
        ToastQuietProbe.RequirePlan(OperatingSystem.IsWindows(), Environment.GetEnvironmentVariable, config);

    internal static ToastQuietProbe Bind(JsonNode? config, JsonNode? selectedExtra, string? selectedWalk, GatewaySession? boundSession)
    {
        bool InCurrentWalk(bool requireTrackedA)
        {
            if (!Automation.Enabled || Automation.AppOnly || AppState.Client is not { } client) return false;
            var session = client.Session;
            return !session.IsNous && ToastQuietProbe.IsReplyWalk(config, selectedExtra, selectedWalk, session.Address.ToString(), session.Account.Username,
                boundSession, session, client.Questions.Waiting().Count) && (!requireTrackedA || NotificationsFeature.Tracks(ChatA));
        }
        return new(OperatingSystem.IsWindows(), Environment.GetEnvironmentVariable, InCurrentWalk, new WindowsReader(),
            line => AppLog.Note("automation", "walk toasts: " + line));
    }

    private sealed partial class WindowsReader : IQuietReader
    {
        public int? ReadQuns() => SHQueryUserNotificationState(out var state) == 0 ? state : null;

        public QuietProfileRead? ReadFocus()
        {
            // Legacy Focus Assist diagnostic only. This private WNF payload isn't a documented setter or a banner API.
            // Never treat a failed, absent, truncated or future-format publication as an explicit DWORD zero (off).
            ulong name = 0x0D83063EA3BF1C75; // WNF_SHEL_QUIETHOURS_ACTIVE_PROFILE_CHANGED
            uint bytes = sizeof(uint);
            int status = NtQueryWnfStateData(ref name, IntPtr.Zero, IntPtr.Zero, out var stamp, out var profile, ref bytes);
            return new QuietProfileRead(status, bytes, stamp, profile);
        }

        public string? ReadAppSetting() => NotificationsFeature.Registration.Registered
            ? AppNotificationManager.Default.Setting.ToString() : "Unregistered";

        [DllImport("user32.dll", ExactSpelling = true), DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        private static extern IntPtr GetForegroundWindow();
        [DllImport("shell32.dll", ExactSpelling = true), DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        private static extern int SHQueryUserNotificationState(out int state);
        [DllImport("ntdll.dll", ExactSpelling = true), DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        private static extern int NtQueryWnfStateData(ref ulong name, IntPtr typeId, IntPtr scope, out uint stamp, out uint profile, ref uint bytes);
    }
}
