using System.Collections.Concurrent;
using System.Text.Json.Nodes;
using Hermes.Core.Notifications;
using Hermes.Core.Questions;
using Hermes.Core.Rpc;
using Hermes.Core.Settings;

namespace Hermes.Core.Tests;

// Mac 1240: NotificationHub.observeRequest/pendingAnswer/withdrawLocal and ServerRequests.answerApprovalFromAlert.
// Only values go in and out. Nothing here presents a prompt or connects the question center to a running app.
public class NotificationAnswerRecorderTests
{
    private const string Runtime = "fixture-runtime", Stored = "fixture-chat", Id = "fixture-request";
    private static readonly TimeSpan Deadline = TimeSpan.FromSeconds(10);

    private sealed class Recorder : IDisposable
    {
        public readonly FakeQuestionTransport Transport;
        public readonly QuestionCenter Center;
        public readonly ChatQuestions Link;
        public readonly LocalAnswerQueue Queue = new();
        public readonly LocalAlerts Alerts = new(() => NotificationPrefs.Default, () => true, _ => false, () => true, () => true);
        public readonly ConcurrentDictionary<string, LocalToast> Notices = new();
        public readonly ConcurrentQueue<string> Skipped = new();
        public readonly TaskCompletionSource<string> Withdrawn = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public readonly List<Task<AlertAnswer>> Outcomes = [];

        public Recorder()
        {
            var transport = new FakeQuestionTransport();
            Transport = transport;
            Center = new QuestionCenter(transport);
            Link = Center.Link("ivy");
            Link.Observing = false;
            Link.Bind(Runtime, Stored);
            Center.Arrived += (id, kind, runtime, profile) =>
            {
                var entry = NotificationDirectory.Entry(profile!, Stored, "Fixture chat", null);
                var result = Alerts.ObserveRequest(id, kind, runtime, Center.Held(id)?.Params, entry);
                if (result.Toast is { } notice) Notices[notice.Tag] = notice;
                else Skipped.Enqueue(result.Skipped);
            };
            Center.Removed += ids =>
            {
                foreach (var id in ids)
                    if (Notices.TryRemove(LocalAlerts.RequestTag(id), out var removed)) Withdrawn.TrySetResult(removed.Tag);
            };
        }

        public void Receive(string id) => Center.Delivered(new ServerRequest(id, "approval",
            new JsonObject { ["session_id"] = Runtime, ["command"] = "Example preview" }, Runtime, false, 1));

        // The port's own encoding and routing, with a recorder in place of both the OS and the account.
        public void RecordButton(ToastButton button)
        {
            var response = NotificationResponse.From(NotificationArguments.Decode(NotificationArguments.Encode(button.Arguments)));
            Assert.Equal(new NotificationTarget(Stored, "ivy"), response.Target);
            Assert.Equal(Id, response.Request);
            Assert.NotNull(response.Approve);
            Queue.Answered(response.Request!, response.Approve.Value);
        }

        // Zero is intentional: each test independently establishes whether its request is present before checking it.
        public void Ready() => Queue.Ready((id, yes) => Outcomes.Add(Center.AnswerApprovalFromAlertAsync(id,
            yes ? ApprovalChoice.Once : ApprovalChoice.Deny, TimeSpan.Zero)));

        public void Dispose() { Link.Dispose(); Center.Dispose(); }
    }

    [Theory]
    [InlineData(0, "Approve Once", "once")]
    [InlineData(1, "Deny", "deny")]
    public async Task OffscreenChoiceWaitsForReadyRecordsOneExactFrameAndWithdraws(int index, string label, string wire)
    {
        using var r = new Recorder();
        r.Receive(Id);
        var notice = Assert.Single(r.Notices.Values);
        Assert.Equal(LocalAlerts.RequestTag(Id), notice.Tag);
        Assert.Equal(("approval.request", "Wants to run: Example preview"), (notice.Kind, notice.Body));
        Assert.Equal(["Approve Once", "Deny"], notice.Buttons.Select(b => b.Title));
        Assert.Equal(Id, Assert.Single(r.Link.Prompts.Approvals).Id);
        Assert.Equal(label, notice.Buttons[index].Title);
        r.RecordButton(notice.Buttons[index]);
        Assert.Empty(r.Outcomes);
        Assert.Empty(r.Transport.Frames);
        Assert.True(r.Notices.ContainsKey(notice.Tag));

        r.Ready();
        var first = Assert.Single(r.Outcomes);
        Assert.Equal(AlertAnswer.Sent, await first.WaitAsync(Deadline));
        Assert.Equal($$$"""{"jsonrpc":"2.0","id":"fixture-request","result":{"choice":"{{{wire}}}"}}""",
            Assert.Single(r.Transport.Frames).ToJsonString());
        Assert.Equal(notice.Tag, await r.Withdrawn.Task.WaitAsync(Deadline));
        Assert.Empty(r.Notices);
        Assert.Empty(r.Link.Prompts.Approvals);
        Assert.Null(r.Center.Held(Id));

        r.Ready(); // Registering twice must not replay the previously pending answer.
        Assert.Same(first, Assert.Single(r.Outcomes));
        r.RecordButton(notice.Buttons[1 - index]);
        r.Queue.Answered("fixture-unknown", false);
        Assert.Equal(new[] { AlertAnswer.Sent, AlertAnswer.Gone, AlertAnswer.Gone }, await Task.WhenAll(r.Outcomes).WaitAsync(Deadline));
        Assert.Single(r.Transport.Frames);
        Assert.DoesNotContain(r.Transport.Calls, c => c.Method == "approval.respond");
    }

    [Fact]
    public async Task WithdrawalBeforeReadyAndAnOnscreenRequestRecordNoAnswer()
    {
        using var r = new Recorder();
        r.Receive(Id);
        var notice = Assert.Single(r.Notices.Values);
        r.RecordButton(notice.Buttons[0]);
        r.Center.Receive(new RpcEvent("request.cancel", Runtime, new JsonObject { ["id"] = Id, ["reason"] = "timeout" }, 2));
        Assert.Equal(notice.Tag, await r.Withdrawn.Task.WaitAsync(Deadline));
        Assert.Null(r.Center.Held(Id));
        Assert.Empty(r.Notices);
        r.Ready();
        Assert.Equal(AlertAnswer.Gone, await Assert.Single(r.Outcomes).WaitAsync(Deadline));

        r.Alerts.Focus(Runtime, Stored);
        r.Receive("fixture-onscreen");
        Assert.Equal("chat on screen", Assert.Single(r.Skipped));
        Assert.Equal("fixture-onscreen", Assert.Single(r.Link.Prompts.Approvals).Id);
        Assert.Empty(r.Notices);
        Assert.Empty(r.Transport.Frames);
        Assert.DoesNotContain(r.Transport.Calls, c => c.Method == "approval.respond");
    }
}
