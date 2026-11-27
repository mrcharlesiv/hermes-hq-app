using System.Text.Json.Serialization;

namespace Hermes.Core.Voice;

// Small value types shared by the memo recorder, the gesture reducer and the controller (spec 1x-voice §2.1;
// HermesKit/Voice/MemoTypes.swift at 93f984bb1). `MemoEndAction`, `MemoTip` and `MemoHaptic` already live in
// MemoGesture.cs and `MemoStopReason` in MemoPolicy.cs (unchanged); their Mac raw values are here as `MemoRaw`.
// `MemoFile` is the shared type from HermesKit/Contracts+voice.swift, here because every memo file type uses it.

/// A finished recording on this device. `Path` is absolute, under the app data's memos/<account key>/…, or (once the
/// gateway accepted it) the gateway's own path, which the playback cache maps back to a local file.
/// JSON keys as the Mac's Codable: path, seconds, peaks, mime, words (left out when null).
public sealed record MemoFile(
    [property: JsonPropertyName("path")] string Path,
    // Two decimals.
    [property: JsonPropertyName("seconds")] double Seconds,
    // 48 values in 0…1, three decimals (`MemoPolicy.peaks`).
    [property: JsonPropertyName("peaks")] IReadOnlyList<double> Peaks,
    // "audio/x-m4a" (recorder) or "audio/wav" (the fixture recorder).
    [property: JsonPropertyName("mime")] string Mime,
    // [live words] What this device heard as the memo was recorded: sent as its transcript, so the gateway never
    // transcribes it. Null: nothing heard it.
    [property: JsonPropertyName("words"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Words = null)
{
    // Swift's synthesized Equatable compares the arrays by value; a record compares the list reference.
    public bool Equals(MemoFile? other) =>
        other is not null && Path == other.Path && Seconds.Equals(other.Seconds) && Mime == other.Mime && Words == other.Words
        && Peaks.SequenceEqual(other.Peaks);

    public override int GetHashCode() => HashCode.Combine(Path, Seconds, Mime, Words, Peaks.Count);
}

/// The Mac's raw values (the web's and the reducer's codes).
public static class MemoRaw
{
    public static string Of(MemoEndAction action) => action switch
    {
        MemoEndAction.Cancel => "cancel",
        MemoEndAction.Review => "review",
        MemoEndAction.Send => "send",
        _ => "draft",
    };

    public static string Of(MemoStopReason reason) => reason switch
    {
        MemoStopReason.Interrupted => "interrupted",
        MemoStopReason.RouteLost => "route-lost",
        MemoStopReason.Reset => "reset",
        MemoStopReason.Background => "background",
        MemoStopReason.Error => "error",
        MemoStopReason.Limit => "limit",
        _ => "cancel",
    };

    public static string Of(MemoTip tip) => tip switch
    {
        MemoTip.NowHold => "now-hold",
        MemoTip.HoldToRecord => "hold-to-record",
        _ => "talk",
    };
}

/// Why `begin` didn't start a recording (spec §3.3 step 1).
public abstract record MemoBeginError
{
    private MemoBeginError() { }

    public sealed record Busy : MemoBeginError;
    public sealed record Background : MemoBeginError;
    /// The touch raised the permission prompt: it records nothing; `Answer` is whether it was granted.
    public sealed record PermissionPending(bool Answer) : MemoBeginError;
    public sealed record PermissionDenied : MemoBeginError;
    public sealed record TooSmall : MemoBeginError;
    public sealed record StartFailed(string Words) : MemoBeginError;
    public sealed record Canceled : MemoBeginError;

    /// The reducer's `begin-failed` code.
    public string Code => this switch
    {
        Busy => "busy",
        Background => "background",
        PermissionPending => "permission-pending",
        PermissionDenied => "permission-denied",
        TooSmall => "too-small",
        StartFailed => "start-failed",
        _ => "canceled",
    };

    public bool? Granted => this is PermissionPending p ? p.Answer : null;

    public string? Message => this switch
    {
        StartFailed s => $"Couldn’t start the voice memo: {s.Words}.",
        TooSmall => "The attachment size limit is too small for a voice memo.",
        _ => null,
    };

    /// The gesture's input for this failure.
    public MemoInput.BeginFailed Input => new(Code, Granted, Message);
}

/// What the recorder did with a take it stopped by itself.
public abstract record MemoStopDisposition
{
    private MemoStopDisposition() { }

    /// The length limit: the reducer's `limit` rule decides (send, review or cancel).
    public sealed record Await : MemoStopDisposition;
    /// Saved as a draft chip in its chat.
    public sealed record Draft(MemoFile Memo) : MemoStopDisposition;
    /// Under a second: nothing kept.
    public sealed record Discard : MemoStopDisposition;
    /// It couldn't be saved; the words say why.
    public sealed record Failed(string Words) : MemoStopDisposition;
}

/// The recorder's side of a take, delivered on the UI thread.
public abstract record MemoCaptureEvent
{
    private MemoCaptureEvent() { }

    /// 15 Hz: the current level (0…1) and the seconds recorded.
    public sealed record Level(double Value, double Seconds) : MemoCaptureEvent;
    public sealed record Stopped(MemoStopReason Reason, string Id, double Seconds, MemoStopDisposition Disposition) : MemoCaptureEvent;
}
