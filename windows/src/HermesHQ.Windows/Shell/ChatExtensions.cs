using Hermes.Core.Chat;
using Hermes.Core.Model;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace HermesHQ.Shell;

/// What an open chat offers features to hang their UI on (the Mac's chat: title header with ⋯ and the inspector
/// button, the shelf above the message box, ☰ and + on its left, the model chip, mic and voice on its right; a
/// question or approval dock takes the message box's place).
public sealed class ChatContext
{
    public required ChatSession Session { get; init; }
    public required Page Page { get; init; }
    /// Above the message box: subagents, goal, queue, browser cards (stacked, top to bottom).
    public required StackPanel Shelf { get; init; }
    /// Left of the text field (☰ commands, + attachments).
    public required StackPanel ComposerLeading { get; init; }
    /// After the optional model chip, before Send.
    public required StackPanel ComposerTrailing { get; init; }
    /// The direct page fits the chip. The composer feature owns its model and the picker both entry points open.
    internal Action<string?> SetModelChip { get; set; } = _ => { };
    internal Action? OpenModelPicker { get; set; }
    /// Shows over the message box while set (approvals, questions, passwords); null gives the box back.
    public required ContentControl Dock { get; init; }
    /// The ⋯ menu in the chat's header.
    public required MenuFlyout MoreMenu { get; init; }
    /// [WIN-62] The header's buttons just before the ⋯ (the Mac's Read Replies Aloud speaker), from the left.
    public required StackPanel HeaderTrailing { get; init; }
    /// The panel on the right (Info, Steps, Files, Helpers); ShowInspector opens it.
    public required ContentControl Inspector { get; init; }
    public required Action<bool> ShowInspector { get; init; }
    public Func<bool> IsInspectorShown { get; init; } = () => false;
    public bool IsBotChat { get; init; }
    /// The composer's text, for features that insert into it (slash drawer, prompts, Link…).
    public required TextBox Composer { get; init; }
    /// The transcript's newest end: rows here scroll with the messages, after the last one (the approval card, the
    /// question note).
    public required StackPanel TranscriptFooter { get; init; }
    /// Floats over the transcript's bottom edge, just above the message box (the Mac's jump button: Approval needed).
    public required Grid TranscriptOverlay { get; init; }
    /// The transcript list itself (its scroll position; bring a footer row into view).
    public required ListView Transcript { get; init; }
    /// Words the header shows in place of "Replying…" (the Mac's "Waiting for your approval", in orange); null gives
    /// the header back.
    public required Action<string?> SetStatus { get; init; }
    /// [WIN-CHAT-INTRO] Over the transcript while it has no rows (the empty chat's intro, Features/ChatIntro); a panel
    /// with no background, so the transcript under it still takes clicks and scrolls.
    public required Grid TranscriptEmpty { get; init; }
    /// [WIN-CHAT-INTRO] Where the chat's first read stands (the Mac's `openPhase`), the rows on screen, and whether
    /// messages exist that aren't rows yet (older pages): what decides the empty chat's placeholder.
    public ChatOpenPhase OpenPhase { get; private set; } = ChatOpenPhase.Opening;
    public Func<int> RowCount { get; init; } = () => 0;
    public Func<bool> HasHiddenRows { get; init; } = () => false;
    /// Raised on the UI thread when the rows or the phase change.
    public event Action? TranscriptChanged;
    internal void SetPhase(ChatOpenPhase phase) { OpenPhase = phase; TranscriptChanged?.Invoke(); }
    internal void RaiseTranscriptChanged() => TranscriptChanged?.Invoke();
    /// [questions] The turn waits on the user (an open approval or question): the thinking row isn't drawn then, the
    /// header says "Waiting for your reply" (ChatRow.swift `waitsOnUser`). Set by the questions feature.
    public bool WaitsOnUser { get; private set; }
    public event Action? WaitsOnUserChanged;
    internal void SetWaitsOnUser(bool waits)
    {
        if (WaitsOnUser == waits) return;
        WaitsOnUser = waits;
        WaitsOnUserChanged?.Invoke();
    }
    /// Something besides the typed text makes the message box sendable (attachments in the tray).
    public List<Func<bool>> HasDraftContent { get; } = [];
    /// Send stays disabled while any of these is true (an attachment still being prepared).
    public List<Func<bool>> HoldsSend { get; } = [];
    /// Offered the composer's text when Send is pressed; the first to return true takes the send (and the box clears).
    public List<Func<string, bool>> SendHandlers { get; } = [];
    /// Asks the page to re-check Send (call after HasDraftContent or HoldsSend changes).
    public Action RefreshComposer { get; internal set; } = () => { };
    /// [WIN-MEMO-SEND-WIRE] The composer's Send as Enter or the Send button does it (the Mac's `composer.submit()`).
    public Action Submit { get; internal set; } = () => { };
    /// [composer] Takes the message box's send (Enter, the Send button), the text as typed: true when it handled it (the
    /// box is then cleared). Null: the page sends it itself.
    public Func<string, bool>? SendHandler { get; set; }
    /// [composer] Key presses in the message box, before the page's own (Enter sends, Shift+Enter, Esc stops): a hook
    /// that returns true has handled the key.
    public List<Func<KeyRoutedEventArgs, bool>> ComposerKeys { get; } = [];
    /// Raised when the chat closes; features drop their subscriptions here.
    public event Action? Closed;
    private bool _closed;
    internal void Close()
    {
        if (_closed) return;
        _closed = true;
        var callbacks = Closed;
        Closed = null; // consume this opening's registrations before callbacks can remove peers or reenter
        Exception? first = null;
        foreach (var close in Delegate.EnumerateInvocationList(callbacks))
        {
            try { close(); }
            catch (Exception e) { first ??= e; }
        }
        // The coordinator records a partial close as 'threw', never the exception's text.
        if (first != null) System.Runtime.ExceptionServices.ExceptionDispatchInfo.Throw(first);
    }
}

public static class ChatExtensions
{
    /// Every feature that adds to a chat registers once at startup (see FeatureRegistry).
    public static readonly List<Action<ChatContext>> OnOpen = [];

    /// Renderers for message parts the base bubble doesn't know (attachments, cards, diffs…).
    public static readonly Dictionary<Type, Func<ChatPart, ChatMessage, UIElement>> PartRenderers = [];

    /// Cards for tool calls that draw their own (clarify, image_generate, delegate_task…), by tool name. Null from the
    /// renderer, or no renderer, draws the call as an ordinary step line.
    public static readonly Dictionary<string, Func<ToolCall, ChatMessage, UIElement?>> ToolRenderers = [];

    /// A bubble asked to show one of its steps (a click on a step line's row): the transcript feature opens it in the
    /// inspector's Steps tab. Raised on the UI thread.
    public static event Action<ChatSession, ChatMessage, ToolCall?>? StepRequested;
    public static void RequestStep(ChatSession session, ChatMessage message, ToolCall? call) =>
        StepRequested?.Invoke(session, message, call);
}
