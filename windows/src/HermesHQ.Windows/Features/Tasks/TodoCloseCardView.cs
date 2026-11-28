using System.Text.Json.Nodes;
using Hermes.Core.Model;
using Hermes.Core.Tasks;
using HermesHQ.Features.Kanban;
using HermesHQ.Shell;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using static HermesHQ.Features.Kanban.PageKit;

namespace HermesHQ.Features.Tasks;

/// Inline Mark Done / Keep Open / Undo chat card for `tasks_update` close offers (`TodoCloseCards.swift`, `c37d7ddad`).
internal static class TodoCloseCardView
{
    public static UIElement? Render(ToolCall call, ChatMessage message)
    {
        if (call.Name != "tasks_update" || call.State == ToolState.Running) return null;
        var args = ParseJson(call.ArgsJson);
        var result = ParseJson(call.ResultText);
        if (TodoCloseCards.FromTasksUpdate(args, result) is not { } payload) return null;
        return new CardControl(payload);
    }

    private static JsonNode? ParseJson(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return null;
        try { return JsonNode.Parse(raw); }
        catch { return null; }
    }

    private sealed class CardControl : UserControl
    {
        private readonly TodoCloseCardToolPayload _payload;
        private readonly Microsoft.UI.Dispatching.DispatcherQueue? _ui = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
        private readonly StackPanel _body = new() { Spacing = 8 };
        private readonly StackPanel _footer = new() { Orientation = Orientation.Horizontal, Spacing = 8 };
        private bool _busy;

        public CardControl(TodoCloseCardToolPayload payload)
        {
            _payload = payload;
            IsTabStop = false;
            HorizontalAlignment = HorizontalAlignment.Left;
            MaxWidth = 460;
            Margin = new Thickness(0, 4, 0, 4);

            var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            header.Children.Add(new FontIcon { Glyph = "\uE73E", FontSize = 13, Foreground = Accent, VerticalAlignment = VerticalAlignment.Center });
            var openBtn = new HyperlinkButton
            {
                Content = payload.Title,
                Padding = new Thickness(0),
                FontSize = 14,
                FontWeight = FontWeights.SemiBold,
            };
            AutomationProperties.SetName(openBtn, $"Open task {payload.Title}");
            openBtn.Click += (_, _) => Navigator.Open("tasks", payload.TaskId);
            header.Children.Add(openBtn);
            _body.Children.Add(header);

            if (!string.IsNullOrWhiteSpace(payload.Offer?.Text))
            {
                _body.Children.Add(new TextBlock
                {
                    Text = payload.Offer.Text,
                    FontSize = 13,
                    TextWrapping = TextWrapping.Wrap,
                    Foreground = Brush("TextFillColorSecondaryBrush"),
                });
            }

            _body.Children.Add(_footer);

            Content = new Border
            {
                CornerRadius = new CornerRadius(12),
                Padding = new Thickness(14, 10, 14, 10),
                Background = Brush("HQPromptCardBrush"),
                BorderBrush = Brush("HQPromptEdgeBrush"),
                BorderThickness = new Thickness(1),
                Child = _body,
            };
            AutomationProperties.SetAutomationId(this, "chat.todo-close-card");

            Loaded += (_, _) =>
            {
                TodoTaskStates.Changed -= OnStatesChanged;
                TodoTaskStates.Changed += OnStatesChanged;
                Refresh();
            };
            Unloaded += (_, _) => TodoTaskStates.Changed -= OnStatesChanged;
            Refresh();
        }

        private void OnStatesChanged()
        {
            if (_ui == null || _ui.HasThreadAccess) Refresh();
            else _ui.TryEnqueue(Refresh);
        }

        private void Refresh()
        {
            _footer.Children.Clear();
            var snapshot = TodoTaskStates.GetSnapshot();
            var res = TodoCloseCards.State(_payload.Asked, _payload.Offer, _payload.TaskId, newest: true, snapshot);
            if (res == null)
            {
                TodoTaskStates.Want(_payload.TaskId, _payload.Offer?.At);
                _footer.Children.Add(new TextBlock
                {
                    Text = "Checking task…",
                    FontSize = 12,
                    Foreground = Brush("TextFillColorSecondaryBrush"),
                    VerticalAlignment = VerticalAlignment.Center,
                });
                return;
            }

            if (res.State == TodoCloseCardState.Waiting && !snapshot.ReadOnly)
            {
                var markDone = new Button
                {
                    Content = "Mark Done",
                    Style = Style("AccentButtonStyle"),
                    IsEnabled = !_busy,
                    Padding = new Thickness(12, 5, 12, 5),
                };
                AutomationProperties.SetAutomationId(markDone, "chat.todo-close.mark-done");
                markDone.Click += (_, _) => _ = RunActionAsync(TodoCloseCardAction.MarkDone);

                var keepOpen = new Button
                {
                    Content = "Keep Open",
                    IsEnabled = !_busy,
                    Padding = new Thickness(12, 5, 12, 5),
                };
                AutomationProperties.SetAutomationId(keepOpen, "chat.todo-close.keep-open");
                keepOpen.Click += (_, _) => _ = RunActionAsync(TodoCloseCardAction.KeepOpen);

                _footer.Children.Add(markDone);
                _footer.Children.Add(keepOpen);
                return;
            }

            var words = TodoCloseCards.Words(res) ?? "Still open";
            _footer.Children.Add(new TextBlock
            {
                Text = words,
                FontSize = 12,
                Foreground = Brush("TextFillColorSecondaryBrush"),
                VerticalAlignment = VerticalAlignment.Center,
            });
            if (res.State == TodoCloseCardState.Done && res.Undo)
            {
                var undo = new HyperlinkButton
                {
                    Content = "Undo",
                    IsEnabled = !_busy,
                    Padding = new Thickness(4, 0, 4, 0),
                    FontSize = 12,
                };
                AutomationProperties.SetAutomationId(undo, "chat.todo-close.undo");
                undo.Click += (_, _) => _ = RunActionAsync(TodoCloseCardAction.Reopen);
                _footer.Children.Add(undo);
            }
        }

        private async Task RunActionAsync(TodoCloseCardAction action)
        {
            if (_busy || TasksHub.Current?.Store is not { } store) return;
            _busy = true;
            Refresh();
            try
            {
                switch (action)
                {
                    case TodoCloseCardAction.MarkDone:
                        await store.SetDoneAsync(_payload.TaskId, true);
                        break;
                    case TodoCloseCardAction.KeepOpen:
                        await store.KeepTaskOpenAsync(_payload.TaskId);
                        break;
                    case TodoCloseCardAction.Reopen:
                        if (await store.SetDoneAsync(_payload.TaskId, false))
                            TodoTaskStates.NoteReopened(_payload.TaskId);
                        break;
                }
            }
            catch { /* store surfaces status on its own */ }
            finally
            {
                _busy = false;
                OnStatesChanged();
            }
        }
    }
}
