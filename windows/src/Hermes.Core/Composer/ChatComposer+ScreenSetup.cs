// [WIN-SCREEN-SETUP-SEND] "Set up with Hermes" on the composer's side (docs/spec/3x-screen.md §5.13; the Mac's
// HermesKit/Chat/LiveChatSession+ScreenSetup.swift at 93f984bb1, `hasQueuedScreenSetup` and `sendScreenSetup`): the
// request goes through the chat's normal send, queued behind a running reply or sent at once when the chat is idle,
// the box's draft untouched. On Windows the queue is the composer's (ComposerQueue), so these live here.

using Hermes.Core.Model;
using Hermes.Core.Screen;

namespace Hermes.Core.Composer;

public sealed partial class ChatComposer
{
    /// True while this chat still has the setup request waiting in its queue (a second tap must not attach again).
    public bool HasQueuedScreenSetup => Queue.Items.Any(m => m.Text.StartsWith(ScreenSetupPrompt.Text, StringComparison.Ordinal));

    /// Queues the request (or sends it at once when the chat is idle) under its short title. Throws NotQueued when it
    /// is in neither the transcript nor the queue afterwards.
    public void SendScreenSetup(string refText, ScreenSetupBundle bundle)
    {
        var text = ScreenSetupPrompt.Message(refText, bundle.Sha256, bundle.HelperApp);
        var before = Session.Messages.Count;
        // [WIN-SENT-TITLES] The stored row holds the whole request; the bubble keeps its title when the chat reads it again.
        Session.SentTitles.Note(text, ScreenSetupPrompt.QueueTitle);
        Queue.Send(text, display: ScreenSetupPrompt.QueueTitle);
        var queued = Queue.Items.Any(m => m.Text == text);
        var now = Session.Messages;
        var sent = now.Count > before && now.Skip(before).Any(m => m.Role == Role.User);
        if (!queued && !sent) throw new ScreenSetupError(ScreenSetupFailure.NotQueued);
    }
}
