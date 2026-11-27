using System.Text.Json.Nodes;
using System.Xml.Linq;
using Hermes.Core.Notifications;

namespace Hermes.Core.Shell;

/// Notification wording, delivery and read-back checks. The only live activation in this walk opens a fixture chat.
/// Sensitive labels and routing are checked separately as data (RecordedToastActions).
public static class ToastsWalkProof
{
    /// The words the walk makes the stand-in send (synthetic), and the Mac's alert for each from Sam's own chat: a bot's
    /// chat is titled by the bot, with no subtitle.
    public const string ReplyText = "The draft is ready for review.";
    public const string FailureCode = "timeout";
    public const string FailureMessage = "Provider request timed out.";
    /// Plain display data. Never submitted to a gateway, shell or prompt.
    public const string ApprovalCommand = "Sample preview";
    public const string Sender = "Sam";

    /// [WIN-10 review] A second reply while the window is minimized (the Mac's "away" case: a banner), and the reply left
    /// in Notification Center when the app quits. The probe needs the entire stamped reply in the matching app group.
    public const string ReplyAwayText = "The summary is ready too.";
    public const string ColdText = "Cold launch check: the notes are ready.";

    public static readonly NotificationCopy Reply = new(Sender, "", ReplyText);
    public static readonly NotificationCopy ReplyAway = new(Sender, "", ReplyAwayText);
    public static readonly NotificationCopy Cold = new(Sender, "", ColdText);
    /// errorReason's known code "timeout" → "the reply timed out"; turnError → "Couldn’t finish: <reason>".
    public static readonly NotificationCopy Failure = new(Sender, "", "Couldn’t finish: the reply timed out");
    public static readonly NotificationCopy Approval = new(Sender, "", "Wants to run: " + ApprovalCommand);

    /// The `error` event the walk has the stand-in send for chat A.
    public static JsonObject FailurePayload() =>
        new() { ["message"] = FailureMessage, ["error_surface"] = new JsonObject { ["code"] = FailureCode } };

    /// The newest toast of `kind` for chat A was decided with `expected`'s words, in A's group, with Approve Once and Deny
    /// when `buttons` (an approval whose whole command shows) and none otherwise.
    public static string? Raised(ToastRecord? record, string kind, NotificationCopy expected, string storedA, bool buttons)
    {
        if (record == null) return $"no {kind} toast was raised for chat A";
        var t = record.Toast;
        if (t.Kind != kind) return $"the toast is {t.Kind}, not {kind}";
        if (t.Group != LocalToast.Key(storedA)) return $"the {kind} toast isn't in chat A's group ({t.Group})";
        if (t.Title != expected.Title) return $"the {kind} toast's title reads «{t.Title}», not «{expected.Title}»";
        if (t.Subtitle != expected.Subtitle) return $"the {kind} toast's subtitle reads «{t.Subtitle}», not «{expected.Subtitle}»";
        if (t.Body != expected.Body) return $"the {kind} toast's body reads «{t.Body}», not «{expected.Body}»";
        var titles = string.Join(", ", t.Buttons.Select(b => b.Title));
        if (buttons && titles != "Approve Once, Deny") return $"the {kind} toast's buttons are [{titles}], not Approve Once and Deny";
        if (!buttons && t.Buttons.Count > 0) return $"the {kind} toast has buttons [{titles}]";
        return null;
    }

    /// Whether Windows took every toast the walk raised: null when each was shown (or listed), else the open gap with the
    /// exact reason the first one wasn't. A gap fails nothing by itself but is reported as a gap, never as a pass.
    public static string? Gap(IReadOnlyList<ToastRecord> records, ProcessElevation? process)
    {
        var label = ProcessElevation.GapLabel(process);
        if (records.Count == 0) return $"{label}: no toast was decided";
        return records.FirstOrDefault(r => r.Delivery == ToastDelivery.NotShown) is { } r
            ? $"{label}: Windows didn't show {r.Toast.Kind}: {r.Why}"
            : null;
    }

    /// A toast's payload as Windows hands it back (AppNotificationManager.GetAllAsync): its text lines hold the title,
    /// the subtitle (when there is one) and the body.
    public static string? PayloadShows(string? payloadXml, NotificationCopy copy)
    {
        if (payloadXml == null) return "Windows has no toast to read back";
        List<string> texts;
        try { texts = [.. XDocument.Parse(payloadXml).Descendants("text").Select(e => e.Value)]; }
        catch (System.Xml.XmlException) { return "the toast's payload isn't XML"; }
        if (!texts.Contains(copy.Title)) return $"Windows's toast doesn't show the title «{copy.Title}»";
        if (copy.Subtitle.Length > 0 && !texts.Contains(copy.Subtitle)) return $"Windows's toast doesn't show the subtitle «{copy.Subtitle}»";
        if (!texts.Contains(copy.Body)) return $"Windows's toast doesn't show the body «{copy.Body}»";
        return null;
    }

    /// A toast's (or button's) arguments as a click hands them back: the builder drops empty values
    /// (NotificationsFeature.Show) and the SDK returns the `key=value;…` string it was given.
    public static IReadOnlyList<KeyValuePair<string, string>> AsActivated(IEnumerable<KeyValuePair<string, string>> arguments) =>
        NotificationArguments.Decode(NotificationArguments.Encode(arguments.Where(a => a.Value.Length > 0)));

    /// The reply toast's click opened chat A.
    public static string? ChatOpened(string? storedOnScreen, string storedA) =>
        storedOnScreen == storedA ? null : $"the reply toast's click left {storedOnScreen ?? "no chat"} on screen, not chat A";

    /// [WIN-10 review] The reply raised while the window is minimized must be a banner (Delivery Shown): list-only would
    /// be a bug in the decision, and a toast Windows didn't take is the open gap (labelled by its cause), never a pass.
    public static string? AwayDelivered(ToastRecord? record, ProcessElevation? process) => record switch
    {
        null => "bug: no reply toast was raised while the window was minimized",
        { Delivery: ToastDelivery.Shown } => null,
        { Delivery: ToastDelivery.ListOnly } => "bug: the reply raised while the window was minimized was list-only, not a banner",
        _ => $"{ProcessElevation.GapLabel(process)}: Windows didn't show the away reply: {record.Why}",
    };

    /// The helper is not the witness: exactly one fresh SDK callback and the expected loaded chat are both required.
    public static bool WarmOpened(long before, long now, bool loaded, string? stored) =>
        loaded && now > before && now - before == 1 && stored == DesktopProof.Chat;

    /// Shown means the SDK took the notification, not that Windows painted a banner. No desktop-wide capture.
    public static string BannerObservation(IEnumerable<ToastRecord> records, string setting) =>
        $"open gap: banner pixels not verified; app decisions: {string.Join(", ", records.Select(r => $"{r.Toast.Kind} {r.Delivery}"))}; app notification setting: {setting}";
}
