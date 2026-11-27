namespace Hermes.Core.Attachments;

/// Settings › Chat Behavior › Largest Attachment (HermesKit/Attachments/AttachmentLimit.swift; spec 3x-settings §4):
/// the largest file this PC attaches or loads inline, in MB, 1…100, 100 by default (Hermes takes up to 100 MB on
/// /api/files/upload-stream, which this app streams from disk). Set on this PC only, for every bot.
public static class AttachmentLimit
{
    public const int Min = 1, Max = 100, DefaultMB = 100;
    public const string Key = "hqn.attachmentLimitMb";

    /// Where the number is kept (the app supplies one backed by its settings file; tests and the default keep it in
    /// memory). Null means the default.
    public interface IStore
    {
        int? Read();
        void Write(int? value);
    }

    private sealed class MemoryStore : IStore
    {
        private int? _v;
        public int? Read() => _v;
        public void Write(int? value) => _v = value;
    }

    public static IStore Store { get; set; } = new MemoryStore();

    /// Raised after the limit changes.
    public static event Action? Changed;

    /// 1…100; anything unreadable is the default.
    public static int Megabytes
    {
        get => Clamp(Store.Read());
        set
        {
            var v = Math.Clamp(value, Min, Max);
            var before = Megabytes;
            Store.Write(v == DefaultMB ? null : v);
            if (v != before) Changed?.Invoke();
        }
    }

    public static long Bytes => Megabytes * 1024L * 1024L;
    public static bool IsDefault => Megabytes == DefaultMB;

    public static int Clamp(int? stored) => stored is { } v ? Math.Clamp(v, Min, Max) : DefaultMB;

    /// Why an item was refused. At the default the limit is the app's own; below it, the person's setting, with the
    /// way to change it (the Mac's words, "this Mac" → "this PC").
    public static string Refusal(string name, int? megabytes = null, string app = "Hermes HQ")
    {
        var mb = megabytes ?? Megabytes;
        return mb >= DefaultMB
            ? $"“{name}” is larger than {DefaultMB} MB, the most {app} can send."
            : $"“{name}” is larger than {mb} MB, the largest attachment this PC is set to send. You can change it in Settings › Chat Behavior › Largest Attachment.";
    }

    /// The Settings row's help, beside a field that shows "MB" (the Mac's macFooter).
    public const string Footer = "Files larger than this aren’t attached or previewed. Default: 100 MB. Set on this PC for every bot.";
}
