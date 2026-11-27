using Hermes.Core.Model;
using Hermes.Core.Transcripts;
using Microsoft.UI.Xaml;

namespace HermesHQ.ViewModels;

/// What a bubble needs from around it, worked out by ChatViewModel each pass (App/Chat/ChatRow.swift builds the same
/// from the whole chat): the day line over it, whether its time shows, its reply layout's inputs, and the prompt a
/// Retry sends again.
public sealed record MessageDisplay(string? DayLabel, MessageRuns.Run Run, ReplyContext Context, string? RetryPrompt)
{
    /// [groups] The reply's sender line (its face and name) shows: the first of a member's run in a room
    /// (Hermes.Core.Groups.GroupRoomChrome.ShowsSenderName). Off in a bot's chat.
    public bool ShowsSender { get; init; }
    // ActivityRows.applyBubbleJoins can restore a quiet prose clock when the immediately
    // preceding row is a tool bubble from another message. Those rows live in different views.
    public bool ClockFromToolAbove { get; init; }
    public bool ShowTime => Run.ShowTime;
}

/// One bubble on screen. Updated in place when its ChatMessage's Revision (or what's around it) changes, so streaming
/// redraws one bubble.
public sealed class MessageItem : Observable
{
    private ChatMessage _m;

    public MessageItem(ChatMessage m, ChatViewModel? owner = null, MessageDisplay? display = null)
    {
        _m = m;
        Owner = owner;
        Display = display ?? new MessageDisplay(null, default, new ReplyContext(), null);
    }

    /// The chat this bubble is in (its actions: Retry, React, Show Steps).
    public ChatViewModel? Owner { get; }
    public MessageDisplay Display { get; private set; }

    public string Id => _m.Id;
    public Role Role => _m.Role;
    public int Revision { get; private set; }
    public ChatMessage Message => _m;

    /// The parts in order: text runs, reasoning, and tool rows, as the bubble draws them.
    public IReadOnlyList<ChatPart> Parts => _m.Parts;
    public string Text => _m.Text;
    public bool IsStreaming => _m.IsStreaming;
    public string Footer
    {
        get
        {
            if (_m.Error is { } e) return e;
            if (_m.IsPending) return "Sending…";
            if (_m.Interrupted) return "Stopped";
            return _m.Timestamp is { } t ? DayLines.Clock(t) : "";
        }
    }
    public bool HasError => _m.Error != null;
    public Visibility StreamingVisibility => _m.IsStreaming && _m.Parts.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

    /// [questions] Draws the bubble again with the same message (a settled clarify card whose later answer arrived).
    public void Redraw()
    {
        Revision++;
        Raise(nameof(Revision));
    }

    public void Update(ChatMessage m, MessageDisplay? display = null)
    {
        var sameDisplay = display == null || display == Display;
        if (m.Revision == _m.Revision && ReferenceEquals(m.Parts, _m.Parts) && m.IsPending == _m.IsPending
            && m.Error == _m.Error && ReferenceEquals(m.Reactions, _m.Reactions) && sameDisplay) return;
        _m = m;
        if (display != null) Display = display;
        Revision++;
        Raise(nameof(Parts));
        Raise(nameof(Text));
        Raise(nameof(IsStreaming));
        Raise(nameof(Footer));
        Raise(nameof(HasError));
        Raise(nameof(StreamingVisibility));
        Raise(nameof(Revision));
    }
}
