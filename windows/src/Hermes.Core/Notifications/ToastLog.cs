namespace Hermes.Core.Notifications;

/// What became of a toast the app decided on: Windows showed it with a banner, put it in Notification Center only (the
/// Mac's `[.list, .sound]` while the app is in front), or didn't take it at all.
public enum ToastDelivery { Shown, ListOnly, NotShown }

/// One toast the app decided on and what became of it; `Why` is the exact reason when Windows didn't take it.
public sealed record ToastRecord(LocalToast Toast, ToastDelivery Delivery, string Why, DateTimeOffset At);

/// [WIN-56] The app's own toast log: every toast the notifications feature decided on (the words, the arguments, the
/// buttons) with whether Windows took it, kept in memory for this run only (never written to disk or AppLog, since the
/// words are message text). The toasts walk reads it to tell a toast Windows showed from the unpackaged fallback, where
/// the decision is made but nothing appears; the Mac has no such fallback (UNUserNotificationCenter always exists).
public sealed class ToastLog
{
    public const int Capacity = 64;
    public static ToastLog Shared { get; } = new();

    private readonly object _gate = new();
    private readonly List<ToastRecord> _records = [];

    public void Note(LocalToast toast, ToastDelivery delivery, string why)
    {
        lock (_gate)
        {
            _records.Add(new ToastRecord(toast, delivery, why, DateTimeOffset.UtcNow));
            if (_records.Count > Capacity) _records.RemoveRange(0, _records.Count - Capacity);
        }
    }

    public IReadOnlyList<ToastRecord> All() { lock (_gate) return [.. _records]; }

    public void Clear() { lock (_gate) _records.Clear(); }

    /// The newest toast of `kind` in the chat stored as `stored` (its group), or null.
    public ToastRecord? Newest(string kind, string stored)
    {
        var group = LocalToast.Key(stored);
        lock (_gate) return _records.LastOrDefault(r => r.Toast.Kind == kind && r.Toast.Group == group);
    }

    /// How a toast Windows took is delivered: list only when the decision asked for no banner.
    public static ToastDelivery Posted(LocalToast toast) => toast.SuppressDisplay ? ToastDelivery.ListOnly : ToastDelivery.Shown;

    /// Why Windows can't take a toast now, or null when it can: the registration failed (or was never possible, as for
    /// an unpackaged app Windows won't register), or the person turned this app's notifications off (`setting`, the
    /// SDK's AppNotificationSetting by name).
    public static string? Blocked(bool registered, string? registrationError, string setting) =>
        !registered ? $"toasts unavailable: {registrationError ?? "not registered"}"
        : setting != "Enabled" ? $"not allowed ({setting})"
        : null;

    /// An exception as the gap names it: its type, its HRESULT and its message on one line (no message text of a chat
    /// is ever in it; these come from the Windows App SDK).
    public static string Error(Exception x) =>
        $"{x.GetType().Name} 0x{unchecked((uint)x.HResult):X8}: {NotificationText.OneLine(x.Message)}";

    /// [WIN-10 review] A chat named in a log line by a short key (the first 8 hex digits of its stored id's SHA-256),
    /// never by the id itself.
    public static string ChatKey(string stored) =>
        Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(stored)))[..8].ToLowerInvariant();

    /// [WIN-10 review] The app log's line once a toast click that launched the app has its chat on screen; the CI's
    /// cold-launch step waits for it with the key the toasts walk logged.
    public static string ColdLaunchOpened(string stored) => $"toast cold launch opened chat key {ChatKey(stored)}";
}
