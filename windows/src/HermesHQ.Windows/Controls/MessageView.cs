using System.ComponentModel;
using Hermes.Core.Attachments;
using Hermes.Core.Model;
using Hermes.Core.Settings;
using Hermes.Core.Transcripts;
using HermesHQ.Features.Settings;
using HermesHQ.Shell;
using HermesHQ.ViewModels;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;

namespace HermesHQ.Controls;

/// One message, drawn as the Mac's transcript (App/Chat/ChatRow.swift, Cells/ChatCells.swift): a centred day line
/// ("Today 11:13 AM") when the day changes; your coloured bubble on the right; a reply on the left, boxed unless
/// the look asks for plain replies, its time at the end of the run; steps folded into one quiet centred line ("Checked how
/// to use web search, explored big.txt, ran 1 command ⌄") that opens on its steps (Tool Call Style: Rows, One Line,
/// At the Bottom, Bubbles, In Header); thoughts, error cards, "Stopped", Tapbacks; and the right-click menu (Copy,
/// Share…, Select Text, React, Show / Hide Steps).
public sealed partial class MessageView : ContentControl
{
    public static readonly DependencyProperty ItemProperty = DependencyProperty.Register(
        nameof(Item), typeof(MessageItem), typeof(MessageView), new PropertyMetadata(null, (d, e) =>
        {
            var v = (MessageView)d;
            if (e.OldValue is MessageItem old) old.PropertyChanged -= v.OnItemChanged;
            if (e.NewValue is MessageItem now) now.PropertyChanged += v.OnItemChanged;
            v._drawnRevision = -1;
            v.Rebuild();
        }));

    public MessageItem? Item
    {
        get => (MessageItem?)GetValue(ItemProperty);
        set => SetValue(ItemProperty, value);
    }

    /// Lines opened by a click, by "<message id>|<row key>" (screen-only state, kept as rows are recycled).
    private static readonly HashSet<string> Expanded = [];
    private const double Side = ChatVisualTokens.Side, Column = ChatVisualTokens.BubbleMax;
    /// Calm card rail max width matching Swift `PromptLayout.maxCardWidth = 660` (`6402f83b5`).
    private const double MaxCardWidth = 660;
    /// Tight vertical gap between adjacent quiet folded rows (`6402f83b5` / `2fea38fca`).
    private const double TightFoldGap = 2;
    private const string QuietFoldTag = "chat.calm.quiet-fold";
    private static ChatVisualTokens.TypeRamp Type => ChatVisualTokens.Type(ThemeService.State.DesktopLook);
    private (bool Desktop, bool Plain, int Corner, bool SystemContrast, BubbleStyle Style, bool ChatBackdrop) _drawnLook;

    private int _drawnRevision = -1;
    private string? _drawnId;

    /// [chat find] Raised after a message is drawn or redrawn, so Find paints its matches on the new elements.
    public static event Action<MessageView>? Drawn;
    /// [chat find] The elements holding the message's searched words (your words, the reply's prose), in reading order.
    public IReadOnlyList<FrameworkElement> FindableText => _findable;
    private readonly List<FrameworkElement> _findable = [];

    public MessageView()
    {
        HorizontalContentAlignment = HorizontalAlignment.Stretch;
        HorizontalAlignment = HorizontalAlignment.Stretch;
        IsTabStop = false;
        ContextRequested += OnContextRequested;
        // Recycled rows may have been offscreen when the look changed.
        Loaded += (_, _) => {
            ChatBubbles.Changed -= OnBubbles; ChatBubbles.Changed += OnBubbles;
            ThemeService.Changed -= OnPalette; ThemeService.Changed += OnPalette;
            BackdropPrefs.Changed -= OnBubbles; BackdropPrefs.Changed += OnBubbles;
            Rebuild();
        };
        Unloaded += (_, _) => {
            ChatBubbles.Changed -= OnBubbles;
            ThemeService.Changed -= OnPalette;
            BackdropPrefs.Changed -= OnBubbles;
        };
    }

    // Skin colours repaint their shared brushes. Rebind only when Windows swaps the entire
    // brush dictionary, not on every Refresh (ChatBubbles already handles changes of shape).
    private void OnPalette() { if (_drawnLook.SystemContrast != ThemeService.SystemHighContrast) Rebuild(); }

    private void OnBubbles()
    {
        Redraw();
    }

    private void OnItemChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(MessageItem.Revision)) Rebuild();
    }

    private static bool HasChatBackground()
    {
        if (ThemeService.State.DesktopLook || ThemeService.SystemHighContrast) return false;
        var app = BackdropPainter.Prefs.Load(BackdropPlace.App);
        var chats = BackdropPainter.Prefs.Load(BackdropPlace.Chats);
        return chats.EffectiveSource(app) != null;
    }

    private void Rebuild()
    {
        if (Item is not { } item) { Content = null; return; }
        var state = ThemeService.State;
        var hasBackdrop = HasChatBackground();
        var look = (state.DesktopLook, state.AppliedPlainReplies, state.AppliedBubbleCorners, ThemeService.SystemHighContrast, state.AppliedBubbleStyle, hasBackdrop);
        if (_drawnId == item.Id && _drawnRevision == item.Revision && _drawnLook == look) return;
        _drawnLook = look;
        _drawnId = item.Id;
        _drawnRevision = item.Revision;
        _findable.Clear();
        // A part a feature draws (ChatExtensions.PartRenderers), alone in its message: the feature draws the row
        // (the composer's slash-command output rows).
        if (item.Parts is [var only] && only is not (TextPart or ReasoningPart or ToolPart)
            && ChatExtensions.PartRenderers.TryGetValue(only.GetType(), out var renderOnly))
        {
            Content = renderOnly(only, item.Message);
            return;
        }
        var root = new StackPanel { MaxWidth = ChatVisualTokens.Column, HorizontalAlignment = HorizontalAlignment.Stretch };
        if (item.Display.DayLabel is { } day) root.Children.Add(DayLine(day));
        var previousStreaming = MarkdownRenderer.StreamingContext;
        MarkdownRenderer.StreamingContext = item.Message.IsStreaming;
        try
        {
            switch (item.Role)
            {
                case Role.System:
                    root.Children.Add(item.HasError ? ErrorCardView(item, item.Message.Error!) : SystemLine(item));
                    break;
                case Role.User:
                    BuildUserRow(item, root, state, hasBackdrop);
                    break;
                default:
                    foreach (var e in BuildAssistantRows(item, state, hasBackdrop)) root.Children.Add(e);
                    break;
            }
        }
        finally
        {
            MarkdownRenderer.StreamingContext = previousStreaming;
        }
        ApplyCalmSpacing(root);
        if (item.Message.Reactions is { Count: > 0 } reactions) root.Children.Add(Reactions(item, reactions));
        Content = root;
        Drawn?.Invoke(this);
    }

    private void Redraw() { _drawnRevision = -1; Rebuild(); }

    // MARK: Calm chat, cards, voice records & bubble surfaces (outside ChatBubbleRows.Tests extracted spans)

    private void BuildUserRow(MessageItem item, StackPanel root, ThemeState state, bool hasBackdrop)
    {
        if (item.Message.Sender == null && item.Parts is [TextPart] && TimelineNotes.ScheduledWake(item.Text) is { } wake)
        {
            root.Children.Add(ScheduledWakeRow(item.Id, wake.Title, wake.Detail));
            return;
        }
        // Collapsed expandable "Voice Chat · M:SS" card for stored voice chat transcripts (never a plain user bubble).
        if (item.Message.Sender == null && !item.Parts.Any(p => p is AttachmentPart)
            && Hermes.Core.Voice.VoiceChatRecordCodec.IsVoiceChatRecord(item.Text)
            && Hermes.Core.Voice.VoiceChatRecordCodec.ParseCard(item.Text) is { } voiceCard)
        {
            root.Children.Add(VoiceChatRecordRow(item, voiceCard.Title, voiceCard.Body));
            return;
        }
        // Calm Chat Readability: suppress synthetic card-tap echoes immediately following their card.
        if (IsSuppressedAdjacentAnswerEcho(item)) return;
        // Voice memo turn: render combined memo + photo/file attachments on the same user turn (#521).
        if (Features.Voice.VoiceMemosFeature.TryCreateMemoBubble(item.Message, item.Owner?.Session) is { } memoBubble)
        {
            root.Children.Add(BuildMemoUserLane(item, memoBubble));
            return;
        }
        var lane = new ChatBubbleLane(UserBubble(item, _findable), mine: true, joined: item.Display.Run.JoinedAbove);
        ApplyBubbleSurface(lane, mine: true, plain: false, state, hasBackdrop);
        root.Children.Add(lane);
    }

    private static bool IsSuppressedAdjacentAnswerEcho(MessageItem item)
    {
        var m = item.Message;
        if (m.Sender != null || m.Error != null || m.IsPending) return false;
        if (m.Reactions is { Count: > 0 } || m.Parts.Any(p => p is AttachmentPart)) return false;
        var history = item.Owner?.Session.Messages;
        if (history is not { Count: > 1 }) return false;
        var index = -1;
        for (var i = 0; i < history.Count; i++)
            if (history[i].Id == m.Id) { index = i; break; }
        if (index <= 0) return false;
        var text = item.Text;
        if (Hermes.Core.Questions.ClarifyLate.Answer(text) is { } clarify
            && Hermes.Core.Questions.ClarifyLate.IsAdjacentAnswerEcho(history, index, clarify.Key))
            return true;
        if (Hermes.Core.Drafts.DraftCards.ParseAnswer(text) is { } draft
            && Hermes.Core.Drafts.DraftCards.IsAdjacentAnswerEcho(history, index, draft.Id))
            return true;
        if (Hermes.Core.Asks.AskCards.ParseAnswer(text) is { } ask
            && Hermes.Core.Asks.AskCards.IsAdjacentAnswerEcho(history, index, ask.Id))
            return true;
        return false;
    }

    private static ChatBubbleLane BuildMemoUserLane(MessageItem item, FrameworkElement memoBubble)
    {
        var extras = new List<FrameworkElement>();
        foreach (var part in item.Parts)
            if (part is not (TextPart or ReasoningPart or ToolPart)
                && ChatExtensions.PartRenderers.TryGetValue(part.GetType(), out var drawPart))
                extras.Add(new Border
                {
                    Child = drawPart(part, item.Message),
                    HorizontalAlignment = HorizontalAlignment.Right,
                    Margin = new Thickness(0, 0, 0, 4),
                });
        var m = item.Message;
        if (extras.Count == 0 && m.Error == null && !m.IsPending)
            return new ChatBubbleLane(memoBubble, mine: true, joined: item.Display.Run.JoinedAbove);

        var stack = new StackPanel { HorizontalAlignment = HorizontalAlignment.Right, Spacing = 4 };
        foreach (var extra in extras) stack.Children.Add(extra);
        memoBubble.HorizontalAlignment = HorizontalAlignment.Right;
        stack.Children.Add(memoBubble);
        if (m.Error != null)
            stack.Children.Add(HermesHQ.Features.Transcript.UndeliveredActions.CheckLine(item, Res<Brush>("SystemFillColorCriticalBrush")));
        else if (m.IsPending)
            stack.Children.Add(new TextBlock
            {
                Text = "Sending…", FontSize = Type.Caption2.Size, HorizontalAlignment = HorizontalAlignment.Right,
                Margin = new Thickness(0, 2, 2, 0), Foreground = Res<Brush>("HQLabel2Brush"),
            });
        return new ChatBubbleLane(stack, mine: true, joined: item.Display.Run.JoinedAbove);
    }

    private FrameworkElement VoiceChatRecordRow(MessageItem item, string title, string body)
    {
        var key = $"{item.Id}|voice-chat";
        var open = Expanded.Contains(key);
        var m = item.Message;
        var stamp = (m.LatestTimestamp ?? m.Timestamp) is { } at ? DayLines.Clock(at) : null;

        var head = new Grid { ColumnSpacing = 8 };
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        head.Children.Add(new FontIcon
        {
            Glyph = "\uE720", FontSize = 13, VerticalAlignment = VerticalAlignment.Center,
            Foreground = Res<Brush>("HQTintTextBrush"),
        });
        var titleBlock = new TextBlock
        {
            Text = title, FontSize = Type.Subhead.Size, FontWeight = FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis,
            Foreground = Res<Brush>("TextFillColorPrimaryBrush"),
        };
        Grid.SetColumn(titleBlock, 1);
        head.Children.Add(titleBlock);
        if (stamp != null)
        {
            var clock = new TextBlock
            {
                Text = stamp, FontSize = Type.Caption2.Size, VerticalAlignment = VerticalAlignment.Center,
                Foreground = Res<Brush>("HQLabel2Brush"),
            };
            Grid.SetColumn(clock, 2);
            head.Children.Add(clock);
        }
        var chevron = new FontIcon
        {
            Glyph = open ? "\uE70E" : "\uE70D", FontSize = 10, VerticalAlignment = VerticalAlignment.Center,
            Foreground = Res<Brush>("TextFillColorTertiaryBrush"),
        };
        Grid.SetColumn(chevron, 3);
        head.Children.Add(chevron);

        var toggle = new Button
        {
            Content = head, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0),
            Padding = new Thickness(12, 8, 12, 8), CornerRadius = new CornerRadius(10),
        };
        AutomationName(toggle, title);
        toggle.Click += (_, _) =>
        {
            if (!Expanded.Remove(key)) Expanded.Add(key);
            Redraw();
        };

        var inner = new StackPanel { Spacing = 0 };
        inner.Children.Add(toggle);
        if (open && !string.IsNullOrWhiteSpace(body))
        {
            var bodyBlock = new TextBlock
            {
                Text = body, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true,
                FontSize = Type.Footnote.Size, LineHeight = Type.Footnote.Size * 1.45,
                Foreground = Res<Brush>("TextFillColorSecondaryBrush"),
                Margin = new Thickness(12, 2, 12, 10),
            };
            _findable.Add(bodyBlock);
            inner.Children.Add(new Border
            {
                Height = 1, Margin = new Thickness(12, 0, 12, 6),
                Background = Res<Brush>("CardStrokeColorDefaultBrush"),
            });
            inner.Children.Add(bodyBlock);
        }

        var card = new Border
        {
            Child = inner, MaxWidth = MaxCardWidth, HorizontalAlignment = HorizontalAlignment.Left,
            Margin = new Thickness(Side, 6, Side, 6), CornerRadius = new CornerRadius(12),
            Background = Res<Brush>("HQPromptCardBrush"), BorderBrush = Res<Brush>("HQPromptEdgeBrush"),
            BorderThickness = new Thickness(1),
        };
        if (!open) card.Tag = QuietFoldTag;
        AutomationId(card, "chat.voice-chat-card");
        return card;
    }

    private static bool IsInteractiveCardTool(ToolCall call) =>
        Hermes.Core.Travel.TravelCards.IsTravelTool(call.Name)
        || Hermes.Core.Shopping.ShoppingCards.IsShoppingTool(call.Name)
        || Hermes.Core.Drafts.DraftCards.IsDraftTool(call.Name)
        || Hermes.Core.Asks.AskCards.IsAskTool(call.Name);

    private IEnumerable<FrameworkElement> BuildAssistantRows(MessageItem item, ThemeState state, bool hasBackdrop)
    {
        var m = item.Message;
        var hasCardTool = m.Tools.Any(IsInteractiveCardTool);
        if (!hasCardTool)
        {
            foreach (var row in ReplyRows(item))
            {
                if (row is ChatBubbleLane lane)
                    ApplyBubbleSurface(lane, mine: false, plain: state.AppliedPlainReplies, state, hasBackdrop);
                yield return row;
            }
            yield break;
        }

        Action<string> send = text => { if (item.Owner is { } o) _ = o.Session.SendAsync(text); };
        var history = item.Owner?.Session.Messages;
        var draftAnswers = history != null ? Hermes.Core.Drafts.DraftCards.Answers(history) : null;
        var supersededDrafts = history != null ? Hermes.Core.Drafts.DraftCards.SupersededRowIds(history) : null;
        var staleDrafts = history != null ? Hermes.Core.Drafts.DraftCards.StaleRowIds(history) : null;
        var askAnswers = history != null ? Hermes.Core.Asks.AskCards.Answers(history) : null;
        var shoppingAnswers = history != null ? Hermes.Core.Shopping.ShoppingCards.Answers(history) : null;
        List<Hermes.Core.Shopping.ProductOption>? catalogHistory = null;
        if (history != null && m.Tools.Any(c => c.Name == Hermes.Core.Shopping.ShoppingCards.OrderTool))
        {
            catalogHistory = [];
            foreach (var hm in history)
                foreach (var tc in hm.Tools)
                    if (tc.Name == Hermes.Core.Shopping.ShoppingCards.ProductsTool
                        && Hermes.Core.Shopping.ShoppingCards.ParseProducts(tc) is { } list)
                        catalogHistory.AddRange(list.Products);
        }

        var renderedCardIds = new HashSet<string>(StringComparer.Ordinal);
        var beforeProseCards = new List<FrameworkElement>();
        var afterProseCards = new List<FrameworkElement>();
        var firstTextIndex = -1;
        for (var i = 0; i < m.Parts.Count; i++)
            if (m.Parts[i] is TextPart tp && !string.IsNullOrWhiteSpace(tp.Text)) { firstTextIndex = i; break; }

        var hasRenderedDraft = false;
        var hasRenderedAsk = false;
        for (var i = 0; i < m.Parts.Count; i++)
        {
            if (m.Parts[i] is not ToolPart { Call: var call } || !IsInteractiveCardTool(call)) continue;
            UIElement? built = null;
            var quietFolded = false;

            if (Hermes.Core.Travel.TravelCards.IsTravelTool(call.Name))
            {
                built = HermesHQ.Features.Travel.TravelCardsView.TryBuild(call, send);
            }
            else if (Hermes.Core.Shopping.ShoppingCards.IsShoppingTool(call.Name))
            {
                if (call.Name == Hermes.Core.Shopping.ShoppingCards.OrderTool)
                {
                    var orderState = shoppingAnswers != null && shoppingAnswers.OrderStates.TryGetValue(call.Id, out var st)
                        ? st : Hermes.Core.Shopping.OrderState.Waiting;
                    built = catalogHistory != null || shoppingAnswers != null
                        ? HermesHQ.Features.Shopping.OrderCardView.TryBuild(call, send, orderState, catalogHistory)
                        : HermesHQ.Features.Shopping.OrderCardView.TryBuild(call, send);
                    quietFolded = orderState != Hermes.Core.Shopping.OrderState.Waiting;
                }
                else
                {
                    built = HermesHQ.Features.Shopping.ProductCardsView.TryBuild(call, send);
                }
            }
            else if (Hermes.Core.Drafts.DraftCards.IsDraftTool(call.Name))
            {
                var draftState = Hermes.Core.Drafts.DraftState.Waiting;
                if (Hermes.Core.Drafts.DraftCards.Parse(call) is { } parsedDraft && draftAnswers != null
                    && draftAnswers.TryGetValue(parsedDraft.Id, out var da))
                    draftState = da is Hermes.Core.Drafts.DraftAnswer.Send
                        ? Hermes.Core.Drafts.DraftState.Sent : Hermes.Core.Drafts.DraftState.Skipped;
                else if (supersededDrafts != null && supersededDrafts.Contains(Hermes.Core.Drafts.DraftCards.RowId(m.Id, call.Id)))
                    draftState = Hermes.Core.Drafts.DraftState.Superseded;
                else if (staleDrafts != null && staleDrafts.Contains(Hermes.Core.Drafts.DraftCards.RowId(m.Id, call.Id)))
                    draftState = Hermes.Core.Drafts.DraftState.Stale;
                built = history != null
                    ? HermesHQ.Features.Drafts.DraftCardView.TryBuild(call, send, draftState)
                    : HermesHQ.Features.Drafts.DraftCardView.TryBuild(call, send);
                if (built != null)
                {
                    hasRenderedDraft = true;
                    quietFolded = draftState != Hermes.Core.Drafts.DraftState.Waiting;
                }
            }
            else if (Hermes.Core.Asks.AskCards.IsAskTool(call.Name))
            {
                Hermes.Core.Asks.AskAnswer? initialAnswer = null;
                if (Hermes.Core.Asks.AskCards.Parse(call) is { } parsedAsk && askAnswers != null
                    && askAnswers.TryGetValue(parsedAsk.Id, out var aa))
                    initialAnswer = aa;
                built = history != null
                    ? HermesHQ.Features.Drafts.AskCardView.TryBuild(call, send, initialAnswer)
                    : HermesHQ.Features.Drafts.AskCardView.TryBuild(call, send);
                if (built != null)
                {
                    hasRenderedAsk = true;
                    quietFolded = initialAnswer != null;
                }
            }

            if (built == null) continue;
            renderedCardIds.Add(call.Id);
            var rail = CalmCardRail(built, quietFolded);
            if (firstTextIndex >= 0 && i < firstTextIndex) beforeProseCards.Add(rail);
            else afterProseCards.Add(rail);
        }

        if (renderedCardIds.Count == 0)
        {
            foreach (var row in ReplyRows(item))
            {
                if (row is ChatBubbleLane lane)
                    ApplyBubbleSurface(lane, mine: false, plain: state.AppliedPlainReplies, state, hasBackdrop);
                yield return row;
            }
            yield break;
        }

        var allProse = string.Join("\n", m.Parts.OfType<TextPart>().Select(p => p.Text).Where(s => !string.IsNullOrWhiteSpace(s)));
        var suppressBoilerplate = !m.IsStreaming && (
            (hasRenderedDraft && Hermes.Core.Drafts.DraftCards.IsReadyBoilerplate(allProse))
            || (hasRenderedAsk && Hermes.Core.Asks.AskCards.IsReadyBoilerplate(allProse)));

        var remainingParts = new List<ChatPart>(m.Parts.Count);
        foreach (var part in m.Parts)
        {
            if (part is ToolPart { Call: var tc } && renderedCardIds.Contains(tc.Id)) continue;
            if (suppressBoilerplate && part is TextPart) continue;
            remainingParts.Add(part);
        }
        var filteredItem = new MessageItem(m with { Parts = remainingParts }, item.Owner, item.Display);
        var produced = ReplyRows(filteredItem).ToList();
        var emittedBefore = false;
        var emittedAfter = false;
        for (var i = 0; i < produced.Count; i++)
        {
            var row = produced[i];
            if (row is ChatBubbleLane lane)
                ApplyBubbleSurface(lane, mine: false, plain: state.AppliedPlainReplies, state, hasBackdrop);

            // Keep any top folded step line first, then cards that appeared before prose, then prose,
            // then cards that appeared after prose, then trailing action/files rows.
            var isTrailingChrome = Equals(row.Tag, "chat.reply.actions")
                || Microsoft.UI.Xaml.Automation.AutomationProperties.GetAutomationId(row) == "chat.files-changed";
            if (!emittedBefore && !Equals(row.Tag, QuietFoldTag))
            {
                emittedBefore = true;
                foreach (var c in beforeProseCards) yield return c;
            }
            if (!emittedAfter && isTrailingChrome)
            {
                emittedAfter = true;
                foreach (var c in afterProseCards) yield return c;
            }
            yield return row;
        }
        if (!emittedBefore) foreach (var c in beforeProseCards) yield return c;
        if (!emittedAfter) foreach (var c in afterProseCards) yield return c;
    }

    private static FrameworkElement CalmCardRail(UIElement card, bool quietFolded = false)
    {
        FrameworkElement element;
        if (card is FrameworkElement fe)
        {
            fe.MaxWidth = double.IsNaN(fe.MaxWidth) || double.IsPositiveInfinity(fe.MaxWidth)
                ? MaxCardWidth
                : Math.Min(fe.MaxWidth, MaxCardWidth);
            if (fe.Margin == default) fe.Margin = new Thickness(Side, 6, Side, 6);
            element = fe;
        }
        else
        {
            element = new Border
            {
                Child = card, MaxWidth = MaxCardWidth, HorizontalAlignment = HorizontalAlignment.Left,
                Margin = new Thickness(Side, 6, Side, 6),
            };
        }
        if (quietFolded && element.Tag == null) element.Tag = QuietFoldTag;
        return element;
    }

    /// Tightens vertical spacing to 2px between adjacent quiet folded rows (`6402f83b5`, `2fea38fca`).
    private static void ApplyCalmSpacing(StackPanel root)
    {
        FrameworkElement? prevQuiet = null;
        foreach (var child in root.Children)
        {
            if (child is FrameworkElement fe && Equals(fe.Tag, QuietFoldTag))
            {
                if (prevQuiet != null)
                {
                    var pm = prevQuiet.Margin;
                    prevQuiet.Margin = new Thickness(pm.Left, pm.Top, pm.Right, 0);
                    var cm = fe.Margin;
                    fe.Margin = new Thickness(cm.Left, TightFoldGap, cm.Right, cm.Bottom);
                }
                prevQuiet = fe;
            }
            else
            {
                prevQuiet = null;
            }
        }
    }

    /// Applies `BubbleStyle.Card` and `BubbleStyle.Tinted` translucent surfaces cleanly over chat backgrounds (`ca97fb3b3`).
    /// Solid, Hermes Look, and Windows High Contrast stay completely untouched.
    private static void ApplyBubbleSurface(FrameworkElement lane, bool mine, bool plain, ThemeState state, bool hasBackdrop)
    {
        if (state.DesktopLook || ThemeService.SystemHighContrast) return;
        if (!mine && plain) return;
        var style = state.AppliedBubbleStyle;
        if (style == BubbleStyle.Solid) return;
        if (style is BubbleStyle.Tinted or BubbleStyle.Glass && !hasBackdrop) return;

        var (box, tail) = FindBubbleBox(lane, mine);
        if (box == null) return;

        var tokens = ThemeService.Tokens;
        var dark = ThemeService.Dark;
        Rgba fill, edge;
        bool hideTail;

        if (style == BubbleStyle.Card)
        {
            hideTail = true;
            if (mine)
            {
                fill = tokens.MeBubble.Alpha(hasBackdrop ? (dark ? 0.88 : 0.90) : 0.95);
                edge = tokens.MeBorder.A > 0.01 ? tokens.MeBorder : tokens.OnTint.Alpha(dark ? 0.16 : 0.14);
            }
            else
            {
                var cardBase = tokens.PromptCard.A > 0.01 ? tokens.PromptCard : tokens.Page;
                fill = cardBase.Alpha(hasBackdrop ? (dark ? 0.84 : 0.88) : (dark ? 0.92 : 0.96));
                edge = hasBackdrop ? tokens.Label.Alpha(dark ? 0.16 : 0.10) : tokens.PromptEdge;
            }
        }
        else
        {
            hideTail = false;
            var backdropTint = ResolveChatBackdropTint(tokens, dark);
            if (mine)
            {
                fill = BlendRgba(tokens.MeBubble, backdropTint, 0.14).Alpha(dark ? 0.86 : 0.88);
                edge = tokens.MeBorder.A > 0.01 ? tokens.MeBorder : tokens.OnTint.Alpha(dark ? 0.14 : 0.12);
            }
            else
            {
                fill = BlendRgba(tokens.ReplyFill, backdropTint, 0.22).Alpha(dark ? 0.80 : 0.84);
                edge = tokens.Label.Alpha(dark ? 0.14 : 0.10);
            }
        }

        var fillBrush = new SolidColorBrush(ThemeService.ToColor(fill));
        var edgeBrush = new SolidColorBrush(ThemeService.ToColor(edge));
        box.Background = fillBrush;
        box.BorderBrush = edgeBrush;
        if (box.BorderThickness.Left == 0) box.BorderThickness = new Thickness(ChatVisualTokens.Dip);

        if (hideTail)
        {
            box.CornerRadius = new CornerRadius(ChatBubbles.MessageCorner(state));
            if (tail != null) tail.Visibility = Visibility.Collapsed;
        }
        else if (tail != null)
        {
            tail.Fill = fillBrush;
            if (!mine)
            {
                tail.Stroke = edgeBrush;
                tail.StrokeThickness = box.BorderThickness.Left;
            }
        }
    }

    private static (Border? Box, Microsoft.UI.Xaml.Shapes.Path? Tail) FindBubbleBox(FrameworkElement element, bool mine)
    {
        if (element is Border b)
            return !mine || b.Name == UserBubbleName ? (b, null) : (null, null);
        if (element is Grid g)
        {
            Border? found = null;
            Microsoft.UI.Xaml.Shapes.Path? tail = null;
            foreach (var child in g.Children)
            {
                if (child is Border cb && (!mine || cb.Name == UserBubbleName)) found = cb;
                else if (child is Microsoft.UI.Xaml.Shapes.Path p) tail = p;
            }
            if (found != null) return (found, tail);
        }
        if (element is Panel panel)
        {
            foreach (var child in panel.Children)
            {
                if (child is FrameworkElement fe)
                {
                    var hit = FindBubbleBox(fe, mine);
                    if (hit.Box != null) return hit;
                }
            }
        }
        return (null, null);
    }

    private static Rgba ResolveChatBackdropTint(ThemeTokens tokens, bool dark)
    {
        var app = BackdropPainter.Prefs.Load(BackdropPlace.App);
        var chats = BackdropPainter.Prefs.Load(BackdropPlace.Chats);
        var source = chats.EffectiveSource(app);
        if (source == null) return tokens.Tint;
        if (source.IsSolid) return BackdropCatalog.ResolveSolidBase(source, dark, tokens.Tint);
        if (source is BackdropSource.Preset p && BackdropCatalog.Find(p.Id) is { } info)
            return p.Id == "glow" ? OkLabSolidAdapt.Adapt(tokens.Tint, dark, isTint: true) : Rgba.Hex(dark ? info.DarkHex : info.LightHex);
        return tokens.Tint;
    }

    private static Rgba BlendRgba(Rgba a, Rgba b, double amount)
    {
        var t = Math.Clamp(amount, 0, 1);
        return new(a.R + (b.R - a.R) * t, a.G + (b.G - a.G) * t, a.B + (b.B - a.B) * t, 1);
    }

    // MARK: Lines

    private static FrameworkElement DayLine(string label) => new TextBlock
    {
        Text = label, FontSize = Type.Caption1.Size, FontWeight = FontWeights.Normal,
        HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 14, 0, 8),
        Foreground = Res<Brush>("TextFillColorSecondaryBrush"),
    };

    /// A timeline note in words (TimelineNotes: "Model changed to …", a failed turn's note beside its card is hidden).
    private static FrameworkElement SystemLine(MessageItem item)
    {
        if (Hermes.Core.Chat.ModelFallback.Parse(item.Text) is { } fallback)
        {
            var card = ModelFallbackCard.Build(
                fallback,
                openModels: () => ChooseModelRequested?.Invoke(item.Owner?.Session),
                openProviders: () => SettingsWindows.Show("providers"));
            return CalmCardRail(card);
        }
        var note = TimelineNotes.Note(item.Text);
        if (note.Kind == TimelineNoteKind.Hidden) return new Border();
        return NoteLine(note.Kind == TimelineNoteKind.Words ? note.Text : item.Text);
    }

    private static FrameworkElement NoteLine(string text) => new TextBlock
    {
        Text = text, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true,
        HorizontalAlignment = HorizontalAlignment.Center, TextAlignment = TextAlignment.Center,
        Margin = new Thickness(40, 6, 40, 6), FontSize = Type.Footnote.Size,
        Foreground = Res<Brush>("TextFillColorSecondaryBrush"),
    };

    /// Automated session wake centered clock row (App/Chat/ChatRow.swift `e89ac4d51`), clicking expands its trigger prompt.
    private FrameworkElement ScheduledWakeRow(string messageId, string title, string detail)
    {
        var key = $"{messageId}|wake";
        var open = Expanded.Contains(key);
        var stack = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(32, 6, 32, 6), Spacing = 6 };
        var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, HorizontalAlignment = HorizontalAlignment.Center };
        head.Children.Add(new FontIcon { Glyph = "\uE823", FontSize = 12, Foreground = Res<Brush>("TextFillColorSecondaryBrush"), VerticalAlignment = VerticalAlignment.Center });
        head.Children.Add(new TextBlock { Text = title, FontSize = Type.Footnote.Size, Foreground = Res<Brush>("TextFillColorSecondaryBrush"), VerticalAlignment = VerticalAlignment.Center });
        head.Children.Add(new FontIcon { Glyph = open ? "\uE70E" : "\uE70D", FontSize = 10, Foreground = Res<Brush>("TextFillColorTertiaryBrush"), VerticalAlignment = VerticalAlignment.Center });
        var btn = new Button
        {
            Content = head, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0), Padding = new Thickness(10, 4, 10, 4),
            HorizontalAlignment = HorizontalAlignment.Center, CornerRadius = new CornerRadius(12),
        };
        AutomationId(btn, "chat.scheduled-wake");
        btn.Click += (_, _) =>
        {
            if (!Expanded.Remove(key)) Expanded.Add(key);
            Redraw();
        };
        stack.Children.Add(btn);
        if (open)
        {
            stack.Children.Add(new Border
            {
                Child = new TextBlock
                {
                    Text = detail, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true,
                    FontSize = Type.Footnote.Size, Foreground = Res<Brush>("TextFillColorSecondaryBrush"),
                },
                MaxWidth = Column, Padding = new Thickness(12, 8, 12, 8), CornerRadius = new CornerRadius(8),
                Background = Res<Brush>("HQPromptCardBrush"), BorderBrush = Res<Brush>("HQPromptEdgeBrush"),
                BorderThickness = new Thickness(1),
            });
        }
        return stack;
    }

    /// [WIN-CONTRAST-BUBBLE] The box around your words (the high-contrast walk finds it by this name).
    public const string UserBubbleName = "chat.user.bubble";

    /// Yours: a tinted, selectable bubble on the right. Its run-end clock sits inside;
    /// a delivery problem or a pending status stays underneath.
    private static FrameworkElement UserBubble(MessageItem item, List<FrameworkElement> findable)
    {
        var stack = new StackPanel { HorizontalAlignment = HorizontalAlignment.Right };
        // Photos and files you sent, above your words (Features/Attachments draws them).
        foreach (var part in item.Parts)
            if (part is not (TextPart or ReasoningPart or ToolPart)
                && ChatExtensions.PartRenderers.TryGetValue(part.GetType(), out var drawPart))
                stack.Children.Add(new Border
                {
                    Child = drawPart(part, item.Message), HorizontalAlignment = HorizontalAlignment.Right,
                    Margin = new Thickness(0, 0, 0, 4),
                });
        // A photo-only send's default question isn't drawn (spec 1x-attachments A4).
        var photoOnly = item.Text == AttachmentSender.DefaultQuestion
            && item.Parts.Any(p => p is AttachmentPart { Attachment.IsImage: true });
        var rewritten = Hermes.Core.Chat.ThreadContextNote.Stripped(item.Text)
            ?? Hermes.Core.Drafts.DraftCards.RewriteMarkerBubble(item.Text)
            ?? Hermes.Core.Asks.AskCards.RewriteMarkerBubble(item.Text)
            ?? Hermes.Core.Shopping.ShoppingCards.RewriteMarkerBubble(item.Text)
            ?? Hermes.Core.Travel.TravelCards.RewriteMarkerBubble(item.Text);
        TextBlock? words = item.Text.Trim().Length > 0 && !photoOnly
            ? new TextBlock { Text = rewritten ?? Hermes.Core.Questions.ClarifyLate.BubbleWords(item.Text) ?? item.Text, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, FontSize = Type.Body.Size, LineHeight = Type.BodyLine,
                FontWeight = new Windows.UI.Text.FontWeight { Weight = Type.Body.Weight }, Foreground = Res<Brush>("HQMeTextBrush") }
            : null;
        if (words != null) findable.Add(words);
        var m = item.Message;
        var turnClock = m.LatestTimestamp ?? m.Timestamp;
        var time = !ThemeService.State.DesktopLook && !m.IsPending && m.Error == null && item.Display.ShowTime
            && turnClock is { } stamp ? DayLines.Clock(stamp) : null;
        // [WIN-CONTRAST-BUBBLE] Under a contrast theme the bubble and its words are the theme's Highlight pair
        // (HQMeBubbleBrush / HQMeTextBrush there), drawn without WinUI's backplate.
        if (words != null)
        {
            ThemeService.ContrastWords(words);
            var box = new Border
            {
                Child = words, Name = UserBubbleName,
                // ChatMetrics' padding already counts the edge; WinUI adds BorderThickness to Padding.
                Padding = new Thickness(ChatVisualTokens.PadH - ChatVisualTokens.Dip, ChatVisualTokens.PadV - ChatVisualTokens.Dip,
                    ChatVisualTokens.PadH - ChatVisualTokens.Dip, ChatVisualTokens.PadV - ChatVisualTokens.Dip),
                CornerRadius = new CornerRadius(ChatBubbles.MessageCorner(ThemeService.State)),
                Background = Res<Brush>("HQMeBubbleBrush"),
                BorderBrush = Res<Brush>("HQMeBorderBrush"), BorderThickness = new Thickness(ChatVisualTokens.Dip),
            };
            var outline = ChatBubbleLane.Face(box, mine: true, tail: item.Display.Run.Ends, time: time, prose: true);
            outline.HorizontalAlignment = HorizontalAlignment.Right;
            stack.Children.Add(outline);
            if (item.Display.Run.Ends && time == null && !m.IsPending && m.Error == null && turnClock is { } quiet && !m.IsStreaming)
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(words, DayLines.Clock(quiet));
        }
        // [WIN-UNDELIVERED-ACTIONS] A send that may not have reached the gateway: "Delivery Unconfirmed · Check" under it
        // (a read-only look in the stored chat), "Checking Delivery…" while it looks (Features/Transcript/UndeliveredActions).
        if (m.Error != null)
        {
            stack.Children.Add(HermesHQ.Features.Transcript.UndeliveredActions.CheckLine(item, Res<Brush>("SystemFillColorCriticalBrush")));
            return stack;
        }
        var under = m.IsPending ? "Sending…" : words == null ? time : null;
        if (under != null)
            stack.Children.Add(new TextBlock
            {
                Text = under, FontSize = Type.Caption2.Size, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 3, 2, 0),
                TextWrapping = TextWrapping.Wrap,
                Foreground = Res<Brush>("HQLabel2Brush"),
            });
        return stack;
    }

    // MARK: A reply

    /// [groups] The sender line (TextLayout.swift `senderBubble`): a 20 pt face, 6 pt, the name at the notice's size,
    /// semibold, in its bot's colour made readable on the look shown (ChatSenderPalette), else the label colour.
    public const string SenderNameId = "chat.sender.name";

    private static FrameworkElement SenderLine(Hermes.Core.Groups.ChatSender sender)
    {
        const double pt = ChatVisualTokens.Dip;
        var line = new Grid { ColumnSpacing = 6 * pt };
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var head = new BotHead { Width = 20 * pt, Height = 20 * pt, VerticalAlignment = VerticalAlignment.Center, IsHitTestVisible = false };
        if (HermesHQ.Features.Bots.ListsHub.Current?.Bots.Bot(sender.Profile)?.Model is { } bot) head.Bot = bot;
        else head.DisplayName = sender.Profile;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(head, "chat.sender.face");
        line.Children.Add(head);
        var name = new TextBlock
        {
            Text = sender.Name, FontSize = Type.Footnote.Size, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center, MaxLines = 1,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(name, SenderNameId);
        var pair = Hermes.Core.Groups.GroupRoomChrome.NameColor(sender.ColorHex);
        void Paint()
        {
            if (ThemeService.SystemHighContrast || pair is not { } colours) { name.Foreground = Res<Brush>("HQLabelBrush"); return; }
            var c = name.ActualTheme == ElementTheme.Dark ? colours.Dark : colours.Light;
            name.Foreground = new SolidColorBrush(Microsoft.UI.ColorHelper.FromArgb(255, (byte)c.R, (byte)c.G, (byte)c.B));
        }
        Paint();
        name.ActualThemeChanged += (_, _) => Paint();
        // TextLayout.swift:1025–1032. Follow the *measured single line* (including system text
        // size), not UI Scale a second time. The face must not determine the name's height.
        name.SizeChanged += (_, e) => {
            var side = Math.Clamp(Math.Ceiling(e.NewSize.Height / pt), 20, 28) * pt;
            if (head.Width != side) head.Width = head.Height = side;
        };
        Grid.SetColumn(name, 1);
        line.Children.Add(name);
        return line;
    }

    private IEnumerable<FrameworkElement> ReplyRows(MessageItem item)
    {
        var m = item.Message;
        var c = item.Display.Context;
        // Only prose can carry a sender byline (TextLayout.swift senderBubble). Don't put it on
        // an activity/card, on every split part, or in the searchable Markdown subtree.
        var sender = item.Display.ShowsSender ? m.Sender : null;
        // [transcript] A scheduled job's delivery (§2.1): the wrapper goes, the job is named on the byline.
        if (!m.IsStreaming && m.Parts.OfType<TextPart>().FirstOrDefault() is { } first && CronDeliveries.Parse(first.Text) is { } delivery)
        {
            yield return new TextBlock
            {
                Text = CronDeliveries.Header(c.BotName, delivery.Job), FontSize = Type.Footnote.Size, FontWeight = FontWeights.SemiBold,
                Margin = new Thickness(Side, 6, Side, 0), Foreground = Res<Brush>("TextFillColorSecondaryBrush"),
            };
            m = m with { Parts = [.. m.Parts.Select(p => ReferenceEquals(p, first) ? new TextPart(delivery.Body) : p)] };
        }
        // Calm Chat Readability: suppress redundant stock boilerplate prose when a draft/ask card is on the same settled turn.
        if (!m.IsStreaming && m.Tools.Any(t => Hermes.Core.Drafts.DraftCards.IsDraftTool(t.Name) || Hermes.Core.Asks.AskCards.IsAskTool(t.Name)))
        {
            var allProse = string.Join("\n", m.Parts.OfType<TextPart>().Select(p => p.Text).Where(s => !string.IsNullOrWhiteSpace(s)));
            var boilerplate =
                (m.Tools.Any(t => Hermes.Core.Drafts.DraftCards.IsDraftTool(t.Name)) && Hermes.Core.Drafts.DraftCards.IsReadyBoilerplate(allProse))
                || (m.Tools.Any(t => Hermes.Core.Asks.AskCards.IsAskTool(t.Name)) && Hermes.Core.Asks.AskCards.IsReadyBoilerplate(allProse));
            if (boilerplate)
                m = m with { Parts = [.. m.Parts.Where(p => p is not TextPart)] };
        }
        var rows = ReplyLayout.Build(m, c);
        // ActivityRows.swift:661–692 selects after folding/hiding steps. The last eligible
        // rendered bubble, not the last text part (nor the last card), owns the end of a run.
        static bool IsBubble(ReplyRow row) => row is WordsRow or ToolBubbleRow;
        var lastBubble = -1;
        for (var i = rows.Count - 1; i >= 0; i--) if (IsBubble(rows[i])) { lastBubble = i; break; }
        var stamp = (m.LatestTimestamp ?? m.Timestamp) is { } at ? DayLines.Clock(at) : null;
        for (var i = 0; i < rows.Count; i++)
        {
            var last = i == lastBubble && item.Display.Run.Ends;
            var joined = i == 0 ? item.Display.Run.JoinedAbove : IsBubble(rows[i - 1]);
            switch (rows[i])
            {
                case WordsRow w:
                    var body = new StackPanel();
                    var plain = ThemeService.State.AppliedPlainReplies;
                    // Shipping ActivityRows:671–676 reassigns the timestamp when a formerly
                    // unjoined text row joins a tool. Otherwise the normal minute rule stands.
                    var afterTool = i == 0 ? item.Display.ClockFromToolAbove : rows[i - 1] is ToolBubbleRow;
                    var time = last && !m.IsStreaming && (item.Display.ShowTime || afterTool) ? stamp : null;
                    // [transcript] §3.7: a settled reply's lone web address draws as a link chip (Features/Transcript).
                    HermesHQ.Features.Transcript.ReplyWords.Render(w.Text, body, plain ? time : null,
                        settled: LinkChips.Shows(mine: false, streaming: m.IsStreaming),
                        page: (item.Owner, m.Id));   // [page-cards] a lone page draws as its card
                    _findable.Add(body);
                    var h = plain ? 0 : ChatVisualTokens.PadH;
                    if (last && time == null && stamp != null && !m.IsStreaming)
                        Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(body, stamp);
                    // Let a real table use the column without stretching the prose beside it. Swift TextLayout:949–953.
                    var table = body.Children.OfType<FrameworkElement>().Any(e => Equals(e.Tag, MarkdownRenderer.InlineTableTag));
                    if (table)
                        foreach (var child in body.Children.OfType<FrameworkElement>().Where(e => !Equals(e.Tag, MarkdownRenderer.InlineTableTag)))
                        {
                            child.MaxWidth = Math.Min(child.MaxWidth, ChatVisualTokens.BubbleMax - 2 * h);
                            if (child.HorizontalAlignment == HorizontalAlignment.Stretch) child.HorizontalAlignment = HorizontalAlignment.Left;
                        }
                    FrameworkElement content = sender == null ? body : new StackPanel {
                        Spacing = 2 * ChatVisualTokens.Dip, Children = { SenderLine(sender), body },
                    };
                    sender = null;
                    yield return ReplyBubble(content, plain, joined, last, plain ? null : time,
                        prose: body.Children.LastOrDefault() is RichTextBlock, table: table);
                    break;
                case StepsRow s:
                    yield return StepLine(item, s);
                    break;
                case ThoughtRow t:
                    yield return ThoughtLine(item, t);
                    break;
                case ToolBubbleRow b:
                    // ActivityRows.swift:689–690,1358–1372: the tool cell draws its run-end
                    // timestamp directly, unlike prose's spoken-only / streaming time policy.
                    // Desktop Look soft-boxes prose, not the tool cell (ChatCells.swift:208,525).
                    var plainTool = ThemeService.State.AppliedPlainReplies || ThemeService.State.DesktopLook;
                    yield return ReplyBubble(ToolBubble(b), plainTool, joined, last, last ? stamp : null,
                        prose: b.Lines.LastOrDefault()?.Code == null, tool: true);
                    break;
                case CardRow card:
                    if (ChatExtensions.ToolRenderers.TryGetValue(card.Call.Name, out var render) && render(card.Call, m) is FrameworkElement drawn)
                        yield return drawn;
                    else
                    {
                        var title = RunSummary.Summarize([card.Call], card.Call.State == ToolState.Running && m.IsStreaming);
                        yield return StepLine(item, new StepsRow(card.Call.Id, [card.Call], title, RunSummary.GlyphFor(title),
                            card.Call.State == ToolState.Running && m.IsStreaming));
                    }
                    break;
                case ErrorRow err:
                    yield return ErrorCardView(item, err.Error);
                    break;
                case CaptionRow cap:
                    yield return Caption(cap.Text);
                    break;
                case StoppedEarlyRow early:
                    yield return StoppedEarly(item, early);
                    break;
                case PartRow pr when ChatExtensions.PartRenderers.TryGetValue(pr.Part.GetType(), out var drawPart):
                    // A feature's part (photos, files, generated images), in its place.
                    yield return new Border
                    {
                        Child = drawPart(pr.Part, m), Margin = new Thickness(Side, 4, Side, 4), MaxWidth = Column,
                        HorizontalAlignment = HorizontalAlignment.Left,
                    };
                    break;
            }
        }
        // [transcript] "N files changed" once the reply has settled (§12): folded, it opens on the files and their counts.
        if (!m.IsStreaming && ChangedFiles.Derive(m.Tools) is { Count: > 0 } files)
            yield return FilesChanged(item, files);
        // [WIN-THINKING-STEP] In a chat the thinking row stands for a reply that shows nothing yet (ChatRow.swift draws
        // nothing for it); a group room keeps its ring.
        if (rows.Count == 0 && m.IsStreaming && item.Owner == null)
            yield return new ProgressRing { IsActive = true, Width = 16, Height = 16, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(Side, 6, 0, 6) };
        // [chat actions] Under the latest settled reply: Regenerate and More (ChatCells.swift ChatActionsCell).
        if (!m.IsStreaming && item.Owner is { } owner && !owner.Busy
            && Hermes.Core.Chat.ChatActionRules.LatestReplyId(owner.Session.Messages) == m.Id)
            yield return ReplyActions(item, owner);
    }

    private static ChatBubbleLane ReplyBubble(FrameworkElement content, bool plain, bool joined, bool last,
        string? time, bool prose, bool table = false, bool tool = false)
    {
        // WinUI adds the edge to Padding. Keep the text column unchanged even for a skin with
        // a clear edge; both brushes repaint with the skin, or resolve to the opaque Windows pair.
        var edge = plain ? 0 : ChatVisualTokens.Dip;
        var h = (tool ? ChatVisualTokens.ToolPadH : plain ? 0 : ChatVisualTokens.PadH) - edge;
        var v = (tool ? ChatVisualTokens.ToolPadV : ChatVisualTokens.PadV) - edge;
        var box = new Border {
            Child = content, Padding = new Thickness(h, v, h, v),
            CornerRadius = new CornerRadius(plain ? 0 : ChatBubbles.MessageCorner(ThemeService.State)),
            Background = plain ? null : Res<Brush>("HQReplyFillBrush"),
            BorderBrush = plain ? null : Res<Brush>("HQReplyEdgeBrush"), BorderThickness = new Thickness(edge),
        };
        return new ChatBubbleLane(ChatBubbleLane.Face(box, mine: false, tail: last && !plain, time: time, prose: prose),
            mine: false, joined: joined, table: table, tool: tool);
    }

    /// The latest reply's action row: Regenerate (a confirm first) and More (Share…, Select Text, Branch in New Chat).
    private FrameworkElement ReplyActions(MessageItem item, ViewModels.ChatViewModel owner)
    {
        Button Round(string glyph, string label, string id)
        {
            var b = new Button
            {
                Content = new FontIcon { Glyph = glyph, FontSize = 14 }, Width = 32, Height = 32, Padding = new Thickness(0),
                CornerRadius = new CornerRadius(16), Background = null, BorderThickness = new Thickness(0),
                Foreground = Res<Brush>("TextFillColorSecondaryBrush"),
            };
            AutomationName(b, label);
            AutomationId(b, id);
            ToolTipService.SetToolTip(b, label);
            return b;
        }
        var regenerate = Round("\uE72C", Hermes.Core.Chat.ChatActionWords.RegenerateButton, Hermes.Core.Chat.ChatActionWords.RegenerateReplyId);
        regenerate.Click += (_, _) => { if (HermesHQ.Pages.ChatPage.Current is { } page) _ = page.ConfirmRegenerateAsync(); };
        var more = Round("\uE712", Hermes.Core.Chat.ChatActionWords.MoreLabel, Hermes.Core.Chat.ChatActionWords.ReplyMoreId);
        var menu = new MenuFlyout();
        menu.Opening += (_, _) =>
        {
            menu.Items.Clear();
            foreach (var row in Hermes.Core.Chat.ChatActionRules.ReplyMore(owner.Busy, offline: false))
            {
                var entry = new MenuFlyoutItem { Text = row.Title, IsEnabled = !row.Disabled };
                if (row.Subtitle != null) ToolTipService.SetToolTip(entry, row.Subtitle);
                AutomationId(entry, Hermes.Core.Chat.ChatActionWords.ReplyMoreRowId(row.Id));
                var id = row.Id;
                entry.Click += (_, _) => Act(item, id);
                menu.Items.Add(entry);
            }
        };
        more.Flyout = menu;
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, Margin = new Thickness(Side - 6, 2, 0, 6), Tag = "chat.reply.actions" };
        panel.Children.Add(regenerate);
        panel.Children.Add(more);
        return panel;
    }

    private static string Glyph(StepGlyph g) => g switch
    {
        StepGlyph.File => "",       // Document
        StepGlyph.Explore => "",    // Folder
        StepGlyph.Terminal => "",   // CommandPrompt
        StepGlyph.Thinking => "",   // Lightbulb
        StepGlyph.Worked => "",     // Completed (a ticked circle)
        StepGlyph.Subagent => "",   // People
        _ => "",                    // Settings (a gear)
    };

    /// A run's quiet line (Rows), or One Line's whole line centred above the reply's words. A click opens it on its
    /// thought and steps; a step's row opens that step in the inspector.
    private FrameworkElement StepLine(MessageItem item, StepsRow s)
    {
        var key = $"{item.Id}|{s.Key}";
        var open = Expanded.Contains(key);
        var title = new TextBlock
        {
            Text = s.Title, FontSize = s.IsLine ? Type.Footnote.Size : Type.Subhead.Size, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center,
            Foreground = Res<Brush>("TextFillColorSecondaryBrush"),
        };
        if (s.Short is { } brief) ToolTipService.SetToolTip(title, s.Title);
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        row.Children.Add(s.Live
            ? new ProgressRing { IsActive = true, Width = 12, Height = 12, VerticalAlignment = VerticalAlignment.Center }
            : new FontIcon { Glyph = Glyph(s.Glyph), FontSize = 12, VerticalAlignment = VerticalAlignment.Center,
                Foreground = Res<Brush>("TextFillColorSecondaryBrush") });
        row.Children.Add(title);
        if (s.Meta is { } meta && s.Short == null)
            row.Children.Add(new TextBlock { Text = meta, FontSize = Type.Footnote.Size, VerticalAlignment = VerticalAlignment.Center,
                Foreground = Res<Brush>("TextFillColorTertiaryBrush") });
        row.Children.Add(new FontIcon { Glyph = open ? "" : "", FontSize = 9, VerticalAlignment = VerticalAlignment.Center,
            Foreground = Res<Brush>("TextFillColorSecondaryBrush") });
        var button = new Button
        {
            Content = row, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0),
            Padding = new Thickness(6, 3, 6, 3), CornerRadius = new CornerRadius(6),
            HorizontalAlignment = s.IsLine ? HorizontalAlignment.Center : HorizontalAlignment.Left,
        };
        AutomationName(button, s.Title + (s.Meta is { } m2 ? ", " + m2 : ""));
        button.Click += (_, _) => { if (!Expanded.Remove(key)) Expanded.Add(key); Redraw(); };
        var stack = new StackPanel { Margin = new Thickness(Side - 6, 6, Side, 6), Tag = open ? null : QuietFoldTag };
        stack.Children.Add(button);
        if (open)
        {
            var list = new StackPanel { Spacing = 2, Margin = new Thickness(6, 4, 0, 4), MaxWidth = Column };
            if (s.Thought is { } thought)
                list.Children.Add(new TextBlock
                {
                    Text = thought, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, FontSize = Type.Subhead.Size,
                    Margin = new Thickness(0, 0, 0, 6), Foreground = Res<Brush>("TextFillColorSecondaryBrush"),
                });
            foreach (var step in s.Steps) list.Children.Add(StepRow(item, step));
            stack.Children.Add(list);
        }
        return stack;
    }

    /// One step as the Steps list shows it: its emoji, its words ("Ran a command"), the command's first lines, the
    /// time or "Failed". A click opens the step sheet in the inspector.
    internal static FrameworkElement StepRow(MessageItem? item, ToolCall call, Action? open = null)
    {
        var line = ToolLines.Line(call);
        var grid = new Grid { ColumnSpacing = 10 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(new TextBlock { Text = line.Emoji, FontSize = 13, VerticalAlignment = VerticalAlignment.Top });
        var words = new StackPanel();
        words.Children.Add(new TextBlock
        {
            Text = StepWords.Words(call, line), FontSize = Type.Subhead.Size, FontWeight = FontWeights.SemiBold,
            TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = 2, TextWrapping = TextWrapping.Wrap,
        });
        if (line.Code is { } code)
        {
            var (lines, more) = StepWords.CodePreview(code);
            foreach (var l in lines)
                words.Children.Add(new TextBlock { Text = l, FontFamily = Res<FontFamily>("CodeFont"), FontSize = Type.Footnote.Size,
                    TextTrimming = TextTrimming.CharacterEllipsis, Foreground = Res<Brush>("TextFillColorSecondaryBrush") });
            if (more > 0)
                words.Children.Add(new TextBlock { Text = StepWords.MoreLines(more), FontSize = Type.Caption1.Size,
                    Foreground = Res<Brush>("TextFillColorTertiaryBrush") });
        }
        Grid.SetColumn(words, 1);
        grid.Children.Add(words);
        var failed = call.State == ToolState.Failed;
        FrameworkElement meta = call.State == ToolState.Running
            ? new ProgressRing { IsActive = true, Width = 12, Height = 12 }
            : new TextBlock
            {
                Text = failed ? "Failed" : call.DurationSeconds is { } d ? StepWords.FormatDuration(d) : "", FontSize = Type.Footnote.Size,
                Foreground = Res<Brush>(failed ? "SystemFillColorCriticalBrush" : "TextFillColorTertiaryBrush"),
            };
        meta.VerticalAlignment = VerticalAlignment.Top;
        Grid.SetColumn(meta, 2);
        grid.Children.Add(meta);
        var button = new Button
        {
            Content = grid, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0),
            Padding = new Thickness(6, 5, 6, 5), CornerRadius = new CornerRadius(6),
        };
        AutomationName(button, StepWords.Words(call, line));
        button.Click += (_, _) =>
        {
            if (open != null) open();
            else if (item?.Owner is { } owner) ChatExtensions.RequestStep(owner.Session, item.Message, call);
        };
        return button;
    }

    private FrameworkElement FilesChanged(MessageItem item, IReadOnlyList<ChangedFile> files)
    {
        var key = $"{item.Id}|files";
        var open = Expanded.Contains(key);
        var added = files.Sum(f => f.Added);
        var removed = files.Sum(f => f.Removed);
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        row.Children.Add(new FontIcon { Glyph = Glyph(StepGlyph.File), FontSize = 12, Foreground = Res<Brush>("TextFillColorSecondaryBrush") });
        row.Children.Add(new TextBlock { Text = ChangedFiles.Title(files.Count), FontSize = 12.5, Foreground = Res<Brush>("TextFillColorSecondaryBrush") });
        row.Children.Add(new TextBlock { Text = $"+{added}", FontSize = 12, Foreground = Res<Brush>("SystemFillColorSuccessBrush") });
        row.Children.Add(new TextBlock { Text = $"\u2212{removed}", FontSize = 12, Foreground = Res<Brush>("SystemFillColorCriticalBrush") });
        row.Children.Add(new FontIcon { Glyph = open ? "\uE70E" : "\uE70D", FontSize = 9, Foreground = Res<Brush>("TextFillColorSecondaryBrush") });
        var button = new Button
        {
            Content = row, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0),
            Padding = new Thickness(6, 3, 6, 3), HorizontalAlignment = HorizontalAlignment.Left,
        };
        button.Click += (_, _) => { if (!Expanded.Remove(key)) Expanded.Add(key); Redraw(); };
        var stack = new StackPanel { Margin = new Thickness(Side - 6, 4, Side, 4), Tag = open ? null : QuietFoldTag };
        AutomationId(stack, "chat.files-changed");
        stack.Children.Add(button);
        if (open)
            foreach (var f in files)
            {
                var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(12, 2, 0, 2) };
                var name = new TextBlock { Text = f.Name, FontSize = 13 };
                ToolTipService.SetToolTip(name, f.Path);
                line.Children.Add(name);
                line.Children.Add(new TextBlock { Text = $"+{f.Added}", FontSize = 12, Foreground = Res<Brush>("SystemFillColorSuccessBrush") });
                line.Children.Add(new TextBlock { Text = $"\u2212{f.Removed}", FontSize = 12, Foreground = Res<Brush>("SystemFillColorCriticalBrush") });
                if (f.Edits > 1) line.Children.Add(new TextBlock { Text = $"{f.Edits} edits", FontSize = 12, Foreground = Res<Brush>("TextFillColorTertiaryBrush") });
                stack.Children.Add(line);
            }
        return stack;
    }

    /// Rows style: "Thinking" / "Thought for 7s" / "Thought", opening on the thought's words.
    private FrameworkElement ThoughtLine(MessageItem item, ThoughtRow t)
    {
        var key = $"{item.Id}|r{t.PartIndex}";
        var open = Expanded.Contains(key);
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        row.Children.Add(t.Live ? new ProgressRing { IsActive = true, Width = 12, Height = 12 }
            : new FontIcon { Glyph = Glyph(StepGlyph.Thinking), FontSize = 12, Foreground = Res<Brush>("TextFillColorSecondaryBrush") });
        row.Children.Add(new TextBlock { Text = t.Title, FontSize = Type.Footnote.Size, Foreground = Res<Brush>("TextFillColorSecondaryBrush") });
        row.Children.Add(new FontIcon { Glyph = open ? "" : "", FontSize = 9, Foreground = Res<Brush>("TextFillColorSecondaryBrush") });
        var button = new Button
        {
            Content = row, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0),
            Padding = new Thickness(6, 3, 6, 3), HorizontalAlignment = HorizontalAlignment.Left,
        };
        button.Click += (_, _) => { if (!Expanded.Remove(key)) Expanded.Add(key); Redraw(); };
        var stack = new StackPanel { Margin = new Thickness(Side - 6, 4, Side, 4), Tag = open ? null : QuietFoldTag };
        stack.Children.Add(button);
        if (open)
            stack.Children.Add(new TextBlock
            {
                Text = t.Text, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, FontSize = Type.Subhead.Size, MaxWidth = Column,
                Margin = new Thickness(6, 2, 0, 4), Foreground = Res<Brush>("TextFillColorSecondaryBrush"),
            });
        return stack;
    }

    /// Bubbles: the run as Hermes posts it in Telegram, one line per step, commands in a code block.
    private static FrameworkElement ToolBubble(ToolBubbleRow b)
    {
        var stack = new StackPanel { Spacing = 4 };
        if (b.Earlier > 0)
            stack.Children.Add(new TextBlock { Text = $"{b.Earlier} earlier", FontSize = 12, Foreground = Res<Brush>("TextFillColorTertiaryBrush") });
        foreach (var line in b.Lines.Skip(b.Earlier))
        {
            stack.Children.Add(new TextBlock { Text = $"{line.Emoji} {line.Text}", TextWrapping = TextWrapping.Wrap, FontSize = 13 });
            if (line.Code is { } code)
                stack.Children.Add(new Border
                {
                    Child = new TextBlock { Text = code, FontFamily = Res<FontFamily>("CodeFont"), FontSize = 12, TextWrapping = TextWrapping.Wrap,
                        IsTextSelectionEnabled = true, MaxLines = 8 },
                    Padding = new Thickness(8, 6, 8, 6), CornerRadius = new CornerRadius(6),
                    Background = Res<Brush>("SubtleFillColorSecondaryBrush"),
                });
        }
        return stack;
    }

    /// The error card (spec 06 §5.6.1, §6.1): a known failure in the web's words, Try Again or Choose a Model, and
    /// Copy Details.
    private static FrameworkElement ErrorCardView(MessageItem item, string error)
    {
        var bot = item.Display.Context.BotName;
        var words = ErrorCard.Make(error, bot, item.Display.RetryPrompt != null, item.Message.Timestamp);
        var stack = new StackPanel { Spacing = 4 };
        var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        head.Children.Add(new FontIcon { Glyph = "", FontSize = 14, Foreground = Res<Brush>("SystemFillColorCriticalBrush") });
        var titleText = new TextBlock { Text = words.Title, FontSize = Type.Headline.Size, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap };
        AutomationId(titleText, "chat.error.title");   // [WIN-36] the walk reads the card by these ids
        head.Children.Add(titleText);
        stack.Children.Add(head);
        stack.Children.Add(new TextBlock { Text = words.Reason, FontSize = Type.Subhead.Size, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true,
            Foreground = Res<Brush>("TextFillColorSecondaryBrush") });
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 6, 0, 0) };
        if (words.Retry && item.Display.RetryPrompt is { } prompt && item.Owner is { } owner)
        {
            var retry = new Button { Content = "Try Again", Style = Res<Style>("AccentButtonStyle") };
            AutomationId(retry, "chat.error.retry");
            retry.Click += (_, _) => owner.Retry(prompt);
            buttons.Children.Add(retry);
        }
        if (words.ChooseModel)
        {
            var choose = new Button { Content = "Choose a Model" };
            AutomationId(choose, "chat.error.choose-model");
            // The model chip's own menu belongs to the composer feature; it listens for this request.
            choose.Click += (_, _) => ChooseModelRequested?.Invoke(item.Owner?.Session);
            buttons.Children.Add(choose);
        }
        var details = new Button { Content = "Copy Details" };
        AutomationId(details, "chat.error.details");
        details.Click += (_, _) => CopyText(error);
        buttons.Children.Add(details);
        stack.Children.Add(buttons);
        var card = new Border
        {
            Child = stack, Padding = new Thickness(14, 10, 14, 10), CornerRadius = new CornerRadius(ThemeService.State.DesktopLook ? 6 : 12),
            Margin = new Thickness(Side, 6, Side, 6), MaxWidth = Column, HorizontalAlignment = HorizontalAlignment.Left,
            Background = Res<Brush>("HQPromptCardBrush"),
            BorderBrush = Res<Brush>("HQPromptEdgeBrush"), BorderThickness = new Thickness(1),
        };
        AutomationId(card, "chat.error-card");
        return card;
    }

    /// The error card's Choose a Model: the model menu's owner opens its chooser.
    public static event Action<Hermes.Core.Chat.ChatSession?>? ChooseModelRequested;

    /// [WIN-COMPOSER-CARD-IDS] The problem card's Choose a Model goes the same way (`presentModelSheet`).
    public static void RequestChooseModel(Hermes.Core.Chat.ChatSession? session) => ChooseModelRequested?.Invoke(session);

    private static FrameworkElement Caption(string text) => new TextBlock
    {
        Text = text, FontSize = Type.Caption1.Size, Margin = new Thickness(Side, 2, Side, 6), Foreground = Res<Brush>("TextFillColorTertiaryBrush"),
    };

    private static FrameworkElement StoppedEarly(MessageItem item, StoppedEarlyRow row)
    {
        var stack = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Margin = new Thickness(Side, 6, Side, 6) };
        stack.Children.Add(new TextBlock { Text = row.Text, FontSize = Type.Footnote.Size, VerticalAlignment = VerticalAlignment.Center,
            Foreground = Res<Brush>("TextFillColorSecondaryBrush") });
        if (row.Retry && item.Display.RetryPrompt is { } prompt && item.Owner is { } owner)
        {
            var retry = new HyperlinkButton { Content = "Try Again", Padding = new Thickness(4, 0, 4, 0) };
            retry.Click += (_, _) => owner.Retry(prompt);
            stack.Children.Add(retry);
        }
        return stack;
    }

    /// Tapback badges under a message, on its side: one per emoji, a count past one; yours in your bubble's colour.
    private static FrameworkElement Reactions(MessageItem item, IReadOnlyList<MessageReaction> reactions)
    {
        var mine = item.Role == Role.User;
        var panel = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 4,
            HorizontalAlignment = mine ? HorizontalAlignment.Right : HorizontalAlignment.Left,
            Margin = mine ? new Thickness(0, 0, Side + 10, 6) : new Thickness(Side + 10, 0, 0, 6),
        };
        foreach (var chip in MessageReactions.Chips(reactions))
        {
            var chipWords = new TextBlock { Text = chip.Text, FontSize = 12,
                Foreground = Res<Brush>(chip.Mine ? "HQMeTextBrush" : "HQLabel2Brush") };
            // [WIN-CONTRAST-BUBBLE] Yours is your bubble's pair under a contrast theme, without the backplate.
            if (chip.Mine) ThemeService.ContrastWords(chipWords);
            panel.Children.Add(new Border
            {
                Child = chipWords,
                Padding = new Thickness(8, 2, 8, 2), CornerRadius = new CornerRadius(10),
                Background = Res<Brush>(chip.Mine ? "HQMeBubbleBrush" : "HQBotBubbleBrush"),
                BorderBrush = Res<Brush>("CardStrokeColorDefaultBrush"), BorderThickness = new Thickness(1),
            });
        }
        AutomationName(panel, MessageReactions.Spoken(reactions, item.Display.Context.BotName));
        return panel;
    }

    // MARK: The message menu (right-click; the Mac's Control-click)

    private void OnContextRequested(UIElement sender, ContextRequestedEventArgs args)
    {
        if (BuildMenu() is not { } menu) return;
        if (args.TryGetPosition(this, out var point)) menu.ShowAt(this, point);
        else menu.ShowAt(this);
        args.Handled = true;
    }

    /// [chat actions] The message's menu, opened as a right-click opens it (the CI walk, where the click doesn't land).
    internal MenuFlyout? OpenMenu()
    {
        if (BuildMenu() is not { } menu) return null;
        menu.ShowAt(this, new Windows.Foundation.Point(ActualWidth / 2, 12));
        return menu;
    }

    private MenuFlyout? BuildMenu()
    {
        if (Item is not { } item || item.Role == Role.System) return null;
        var m = item.Message;
        var owner = item.Owner;
        var reply = item.Role == Role.Assistant;
        var hide = ChatDisplaySettings.HidesSteps;
        // [chat actions] Regenerate on the newest reply; Edit and Rewind to Here on your stored text messages.
        var rewindable = owner != null && !reply && owner.Session.CanRewind(m.Id);
        var ctx = new MessageMenuContext(
            Streaming: m.IsStreaming, Running: owner?.Busy == true,
            Latest: owner != null && reply && Hermes.Core.Chat.ChatActionRules.LatestReplyId(owner.Session.Messages) == m.Id,
            ShowSteps: owner != null && reply && hide && ReplyLayout.HasSteps(m) ? !owner.Revealed(m.Id) : null,
            CanEdit: rewindable, CanRewind: rewindable,
            // [WIN-UNDELIVERED-ACTIONS] Send Again and Delete on your unconfirmed send (ChatMenus `ctx.undelivered`).
            Undelivered: owner != null && !reply && Hermes.Core.Chat.ChatSession.IsUndelivered(m),
            // [WIN-54] Read Aloud, Stop Reading while this reply is read (ChatVoiceHost.talkIsReading; null: not offered).
            Reading: owner != null && reply ? HermesHQ.Features.Voice.ReadAloudFeature.IsReading(owner.Session, m.Id) : null);
        var menu = new MenuFlyout();
        var title = MessageMenu.Title(reply ? item.Display.Context.BotName : "You", null, null,
            (m.LatestTimestamp ?? m.Timestamp) is { } t ? DayLines.Clock(t) : "");
        menu.Items.Add(new MenuFlyoutItem { Text = title, IsEnabled = false });
        menu.Items.Add(new MenuFlyoutSeparator());
        // Group room messages (owner == null) offer Copy, Share, and Select Text.
        var handled = owner != null
            ? new HashSet<MessageMenuItem> { MessageMenuItem.Copy, MessageMenuItem.Share, MessageMenuItem.SelectText, MessageMenuItem.Steps,
                MessageMenuItem.Edit, MessageMenuItem.Regenerate, MessageMenuItem.Branch, MessageMenuItem.Rewind, MessageMenuItem.ReadAloud,
                MessageMenuItem.Retry, MessageMenuItem.Delete }
            : new HashSet<MessageMenuItem> { MessageMenuItem.Copy, MessageMenuItem.Share, MessageMenuItem.SelectText };
        foreach (var row in MessageMenu.Tiles(reply, ctx).Concat(MessageMenu.Rows(reply, ctx)).Where(r => handled.Contains(r.Id)))
        {
            var entry = new MenuFlyoutItem { Text = row.Title, IsEnabled = !row.Disabled };
            AutomationId(entry, "message-menu." + row.Id.ToString().ToLowerInvariant());
            if (row.Subtitle != null) ToolTipService.SetToolTip(entry, row.Subtitle);
            entry.Icon = new FontIcon { Glyph = row.Id switch
            {
                MessageMenuItem.Copy => "", MessageMenuItem.Share => "", MessageMenuItem.SelectText => "",
                MessageMenuItem.Edit => "\uE70F", MessageMenuItem.Regenerate => "\uE72C", MessageMenuItem.Branch => "\uE8AB",
                MessageMenuItem.Rewind => "\uE7A7",
                // [WIN-UNDELIVERED-ACTIONS] arrow.clockwise / trash
                MessageMenuItem.Retry => "\uE72C", MessageMenuItem.Delete => "\uE74D",
                // [WIN-54] speaker.wave.2 / stop.fill
                MessageMenuItem.ReadAloud => ctx.Reading == true ? "\uE71A" : "\uE767",
                _ => "",
            } };
            var id = row.Id;
            entry.Click += (_, _) => Act(item, id);
            menu.Items.Add(entry);
        }
        // React ▸ (Settings › Chat › Message Reactions, off by default).
        if (owner != null && ChatDisplaySettings.Reactions && !m.IsStreaming && !m.IsPending && m.Error == null)
        {
            var react = new MenuFlyoutSubItem { Text = "React", Icon = new FontIcon { Glyph = "" } };
            var current = m.Reactions?.FirstOrDefault(r => r.IsMine)?.Emoji;
            foreach (var emoji in MessageReactions.Quick)
            {
                var e = new ToggleMenuFlyoutItem { Text = $"{emoji}  {MessageReactions.Name(emoji)}", IsChecked = emoji == current };
                e.Click += async (_, _) =>
                {
                    try { await owner.Session.ReactAsync(m.Id, emoji); }
                    catch (Hermes.Core.Net.GatewayException) { /* the old reactions are back */ }
                };
                react.Items.Add(e);
            }
            menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(react);
        }
        return menu;
    }

    private void Act(MessageItem item, MessageMenuItem id)
    {
        var m = item.Message;
        switch (id)
        {
            case MessageMenuItem.Copy:
                // Copy: the message's text parts joined by a line break, as Markdown (ChatTranscript.messageText).
                CopyText(string.Join("\n", m.Parts.OfType<TextPart>().Select(p => p.Text)));
                break;
            case MessageMenuItem.Share:
                ShareText(ReadableText.Of(m.Text), item.Role == Role.User ? "Your message" : item.Display.Context.BotName);
                break;
            case MessageMenuItem.SelectText:
                _ = SelectTextAsync(ReadableText.Of(m.Text));
                break;
            case MessageMenuItem.Steps:
                item.Owner?.ToggleSteps(m.Id);
                break;
            case MessageMenuItem.ReadAloud:
                // [WIN-54] Read Aloud / Stop Reading (ChatMenus.performMessage → talkToggleRead).
                if (item.Owner is { } chat) HermesHQ.Features.Voice.ReadAloudFeature.Toggle(chat.Session, m.Id);
                break;
            case MessageMenuItem.Edit or MessageMenuItem.Regenerate or MessageMenuItem.Branch or MessageMenuItem.Rewind:
                // [chat actions] The open chat carries them out (Pages/ChatPage.Actions.cs).
                HermesHQ.Pages.ChatPage.Current?.PerformMessageAction(id, m.Id);
                break;
            case MessageMenuItem.Retry or MessageMenuItem.Delete:
                // [WIN-UNDELIVERED-ACTIONS] Send Again / Delete on an unconfirmed send (performMessageAction .retry/.delete).
                if (item.Owner is { } undelivered) HermesHQ.Features.Transcript.UndeliveredActions.Perform(undelivered.Session, id, m.Id);
                break;
        }
    }

    /// Select Text: the words in a sheet where any part of them can be selected and copied.
    private async Task SelectTextAsync(string text)
    {
        if (XamlRoot == null) return;
        var box = new TextBox
        {
            AcceptsReturn = true, Text = text, IsReadOnly = true, TextWrapping = TextWrapping.Wrap,
            MinWidth = 420, MaxHeight = 480, BorderThickness = new Thickness(0),
        };
        ScrollViewer.SetVerticalScrollBarVisibility(box, ScrollBarVisibility.Auto);
        var dialog = new ContentDialog
        {
            Title = "Select Text", Content = box, CloseButtonText = "Done", XamlRoot = XamlRoot, DefaultButton = ContentDialogButton.Close,
        };
        box.Loaded += (_, _) => { box.Focus(FocusState.Programmatic); box.SelectAll(); };
        await HermesHQ.Services.SafeDialog.ShowAsync(XamlRoot, dialog);
    }

    internal static void CopyText(string text) => HermesHQ.Services.SafeClipboard.TrySetText(text);

    /// Share…: Windows's share panel with the text (the Mac's share panel).
    internal static void ShareText(string text, string title)
    {
        if (App.Window is not { } window) { CopyText(text); return; }
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(window);
        var manager = DataTransferManagerInterop.GetForWindow(hwnd);
        void OnRequested(DataTransferManager s, DataRequestedEventArgs e)
        {
            e.Request.Data.Properties.Title = title;
            e.Request.Data.SetText(text);
            s.DataRequested -= OnRequested;
        }
        manager.DataRequested += OnRequested;
        DataTransferManagerInterop.ShowShareUIForWindow(hwnd);
    }

    private static void AutomationId(DependencyObject e, string id) =>
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(e, id);

    private static void AutomationName(DependencyObject e, string name) =>
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(e, name);

    private static T Res<T>(string key) => ThemeBrushes.Res<T>(key);
}

/// A reply as it reads on screen, for Share and Select Text (ChatTranscript.readableText): no Markdown markers, "•"
/// bullets, a link's words then its address; code keeps its text, only the fences go.
internal static class ReadableText
{
    private static readonly System.Text.RegularExpressions.Regex Fence = new(@"^\s*(```|~~~)");
    private static readonly (System.Text.RegularExpressions.Regex Rx, string To)[] Rules =
    [
        (new(@"^(\s*)[-*+]\s+(\[[ xX]\]\s+)?"), "$1• "),
        (new(@"^\s*#{1,6}\s+"), ""),
        (new(@"^\s*>\s?"), ""),
        (new(@"!\[([^\]]*)\]\([^)]*\)"), "$1"),
        (new(@"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"), "$2"),
        (new(@"(?<![\w*])\*(?=\S)([^*\n]+?)(?<=\S)\*(?![\w*])"), "$1"),
        (new(@"(?<![\w])_(?=\S)([^_\n]+?)(?<=\S)_(?![\w])"), "$1"),
        (new(@"~~(?=\S)(.+?)(?<=\S)~~"), "$1"),
        (new("`([^`\\n]+)`"), "$1"),
    ];
    private static readonly System.Text.RegularExpressions.Regex Link = new(@"\[([^\]]+)\]\(([^)\s]+)[^)]*\)");

    public static string Of(string markdown)
    {
        var fenced = false;
        var o = new List<string>();
        foreach (var raw in markdown.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n'))
        {
            if (Fence.IsMatch(raw)) { fenced = !fenced; continue; }
            if (fenced) { o.Add(raw); continue; }
            var line = raw;
            for (var i = 0; i < 4; i++) line = Rules[i].Rx.Replace(line, Rules[i].To);
            line = Link.Replace(line, m => m.Groups[1].Value == m.Groups[2].Value ? m.Groups[1].Value : $"{m.Groups[1].Value} ({m.Groups[2].Value})");
            for (var i = 4; i < Rules.Length; i++) line = Rules[i].Rx.Replace(line, Rules[i].To);
            o.Add(line);
        }
        return string.Join("\n", o);
    }
}
