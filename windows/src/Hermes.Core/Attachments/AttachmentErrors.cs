namespace Hermes.Core.Attachments;

/// Why a pick couldn't become an attachment (alert "Couldn't Attach", spec §4.6; AttachmentPrepareError).
public sealed class AttachmentPrepareException(AttachmentPrepareException.Reason why, string? name = null)
    : Exception(Words(why, name))
{
    public enum Reason { TooLarge, UnreadablePhoto, UnreadableFile, CameraNotSaved, LimitReached, Cancelled }
    public Reason Why { get; } = why;

    private static string Words(Reason why, string? name) => why switch
    {
        Reason.TooLarge => AttachmentLimit.Refusal(name ?? "attachment"),
        Reason.UnreadablePhoto => "Couldn’t read the selected photo or video.",
        Reason.UnreadableFile => "Couldn’t read the selected file.",
        Reason.CameraNotSaved => "Couldn’t save the camera photo.",
        Reason.LimitReached => $"You can attach up to {AttachmentCenter.MaxPerMessage} items to one message.",
        _ => "",
    };
}

/// Why a stage failed, in the words the tray and the refusal card show (AttachmentUploadError, spec §3.3, §6.3).
public sealed class AttachmentUploadException(AttachmentUploadException.Kinds kind, string reason) : Exception(reason)
{
    public enum Kinds
    {
        /// No connection: the upload waits and starts by itself when it is back.
        Waiting,
        /// Network, timeout, 5xx: one automatic retry after 2 s, then failed (retryable).
        Retryable,
        /// The gateway refused it for good (name, size, no upload folder).
        Final,
        /// The session ended (a 401 after the refresh).
        SessionEnded,
    }

    public Kinds Kind { get; } = kind;
    public string Reason => Message;

    public const string NoFolderReason = "Your gateway has no folder for uploads.";
    public const string SessionEndedReason = "Your session ended. Sign in again to send this.";

    public static AttachmentUploadException Connection(string name) =>
        new(Kinds.Retryable, $"Couldn’t upload “{name}”. Check your connection and try again.");
    public static AttachmentUploadException Status(string name, int status) =>
        new(Kinds.Retryable, $"Couldn’t upload “{name}” (gateway error {status}).");
    public static AttachmentUploadException NoFolder() => new(Kinds.Final, NoFolderReason);
    public static AttachmentUploadException TooBig(string name) => new(Kinds.Final, $"“{name}” is too big for your gateway.");
    public static AttachmentUploadException BadName() =>
        new(Kinds.Final, "This file’s name has characters your gateway can’t take.");
    public static AttachmentUploadException NotStored(string name) => new(Kinds.Final, $"Your gateway didn’t store “{name}”.");
    public static AttachmentUploadException Stopped() => new(Kinds.Final, "Stopped before sending");
    public static AttachmentUploadException Ended() => new(Kinds.SessionEnded, SessionEndedReason);
    public static AttachmentUploadException WaitingForConnection() => new(Kinds.Waiting, "Waiting for connection");

    /// A 400 from the upload: the gateway's own reason (`detail`), which is rarely the name.
    public static AttachmentUploadException Refused(string name, string? body)
    {
        var detail = body != null ? J.Parse(body).Text("detail") : null;
        return detail == null
            ? new(Kinds.Final, $"Your gateway refused “{name}” (HTTP 400).")
            : new(Kinds.Final, $"Your gateway refused “{name}”: {detail}");
    }
}

/// Why a picture or file couldn't be loaded from the gateway (MediaLoadError).
public sealed class MediaLoadException(MediaLoadException.Kinds kind) : Exception(kind.ToString())
{
    public enum Kinds { NotFound, Forbidden, TooLarge, Unreachable, NotImage, Unavailable }
    public Kinds Kind { get; } = kind;

    /// The "Couldn't Open File" alert's words.
    public string FileMessage => Kind switch
    {
        Kinds.NotFound => "This file isn’t on your gateway anymore.",
        Kinds.Forbidden => "Your gateway keeps this file private.",
        Kinds.TooLarge => "This file is larger than 512 MB, the most Hermes HQ can open.",
        _ => "Couldn’t reach your gateway. Try again.",
    };
}
