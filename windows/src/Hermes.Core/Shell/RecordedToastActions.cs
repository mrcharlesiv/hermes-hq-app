using System.Text.Json.Nodes;
using Hermes.Core.Notifications;
using Hermes.Core.Questions;
using Hermes.Core.Settings;

namespace Hermes.Core.Shell;

/// An independent in-memory receiver for the Mac's two local notification actions. A record is a description,
/// never a callback. This type has no client, answer queue, handler, process, UI or transport.
public sealed class RecordedToastActions
{
    private const string Request = "fixture-request";
    public sealed record Entry(string Label, string? Action, NotificationResponse Route);
    private readonly List<Entry> _entries = [];
    public IReadOnlyList<Entry> Entries => _entries.AsReadOnly();

    public static LocalToast Sample()
    {
        var alerts = new LocalAlerts(() => NotificationPrefs.Default, () => true, _ => false, () => true, () => true);
        var chat = new LocalAlertEntry(new NotificationWho(ToastsWalkProof.Sender, "", "", true), DesktopProof.Chat, DesktopProof.Profile);
        return alerts.ObserveRequest(Request, PromptKind.Approval, "fixture-runtime",
            new JsonObject { ["command"] = ToastsWalkProof.ApprovalCommand }, chat).Toast!;
    }

    public void Record(ToastButton button)
    {
        var args = button.Arguments; // Do not silently drop empty or extra fields.
        var actions = args.Where(a => a.Key == "action").Select(a => a.Value).ToArray();
        var keys = args.Select(a => a.Key).Order(StringComparer.Ordinal);
        if (!keys.SequenceEqual(["action", "kind", "profile", "request", "session", "stored"])
            || !args.Contains(new("kind", "approval.request")) || !args.Contains(new("session", DesktopProof.Chat))
            || !args.Contains(new("stored", DesktopProof.Chat)) || !args.Contains(new("profile", DesktopProof.Profile))
            || !args.Contains(new("request", Request)))
            throw new InvalidOperationException("unexpected recorded action route");
        var action = actions.Single();
        if ((button.Title, action) is not (("Approve Once", "approve") or ("Deny", "deny")))
            throw new InvalidOperationException("unexpected recorded action label");
        _entries.Add(new(button.Title, action, NotificationResponse.From(args)));
    }

    public static void Verify(LocalToast toast)
    {
        var record = new ToastRecord(toast, ToastDelivery.NotShown, "recording only", DateTimeOffset.UnixEpoch);
        if (ToastsWalkProof.Raised(record, "approval.request", ToastsWalkProof.Approval, DesktopProof.Chat, true) is { } wrong)
            throw new InvalidOperationException(wrong);
        var chat = new NotificationTarget(DesktopProof.Chat, DesktopProof.Profile);
        KeyValuePair<string, string>[] body = [new("session", DesktopProof.Chat), new("stored", DesktopProof.Chat),
            new("request", Request), new("kind", "approval.request"), new("profile", DesktopProof.Profile)];
        if (toast.Tag != LocalAlerts.RequestTag(Request) || toast.Arguments.Count != body.Length || !body.All(toast.Arguments.Contains)
            || NotificationResponse.From(toast.Arguments) != new NotificationResponse(chat, null, null))
            throw new InvalidOperationException("the sample body is not the plain open-chat route");
        var receiver = new RecordedToastActions();
        foreach (var data in toast.Buttons) receiver.Record(data);
        if (!receiver.Entries.SequenceEqual([new Entry("Approve Once", "approve", new(chat, Request, true)),
            new Entry("Deny", "deny", new(chat, Request, false))])) throw new InvalidOperationException("wrong recorded action labels or routing");
    }
}
