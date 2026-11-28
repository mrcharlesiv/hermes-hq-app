using Hermes.Core.Coding;
using Hermes.Core.Sessions;
using HermesHQ.Features.Kanban;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.System;
using Windows.UI;
using static HermesHQ.Features.Kanban.PageKit;

namespace HermesHQ.Features.Coding;

/// Interactive Pull Request card (`App/Sessions/PullRequestCardView.swift` + `PullRequestCardPages.swift` + `PRVerdictView.swift`):
/// single calm pinned bottom primary action bar (including `"Ask <Bot> to Open PR"` for bare branches),
/// `chatWorking` warning on merge confirm, per-failing-check `"Ask <Bot> to Fix"` in the Checks subpage,
/// interactive diff viewer, and sibling PR switching.
public sealed class PullRequestCardView : UserControl
{
    private readonly SessionSummary _session;
    private SessionPRStatus _status;
    private readonly CodingStore _store;
    private readonly DiffCommentStore _comments;
    private readonly Action<PullRequestActionItem> _onAction;
    private readonly Action? _onClose;
    private readonly string _botName;
    private readonly bool _chatWorking;
    private readonly Action? _onRepository;

    private PullRequestCardFocus _focus;
    private bool _showingChecks;
    private PullRequestFileRow? _openDiffFile;
    private readonly StackPanel _body = new() { Spacing = 10, Padding = new Thickness(16, 8, 16, 20) };
    private readonly TextBlock _headerTitle = Text("Pull Request", 14, bold: true, wrap: false);
    private readonly Button _backButton;
    private readonly Border _pinnedBar;

    public PullRequestCardView(
        SessionSummary session,
        SessionPRStatus status,
        CodingStore store,
        DiffCommentStore comments,
        Action<PullRequestActionItem> onAction,
        Action? onClose = null,
        PullRequestCardFocus? initialFocus = null,
        string? botName = null,
        bool? chatWorking = null,
        Action? onRepository = null)
    {
        _session = session;
        _status = status;
        _store = store;
        _comments = comments;
        _onAction = onAction;
        _onClose = onClose;
        _focus = initialFocus ?? new PullRequestCardFocus.Lead();
        _botName = string.IsNullOrWhiteSpace(botName) ? BotName(session.Profile) : botName.Trim();
        _chatWorking = chatWorking ?? (session.IsRunning || session.Status == SessionStatus.Working);
        _onRepository = onRepository;

        AutomationProperties.SetAutomationId(this, "coding.pr-card");

        _backButton = new Button
        {
            Content = new FontIcon { Glyph = "\uE72B", FontSize = 13 },
            Style = Style("QuietButtonStyle"),
            Visibility = Visibility.Collapsed,
        };
        AutomationProperties.SetName(_backButton, "Back to Pull Request");
        _backButton.Click += (_, _) =>
        {
            _showingChecks = false;
            _openDiffFile = null;
            Render();
        };

        var refreshBtn = new Button { Content = new FontIcon { Glyph = "\uE72C", FontSize = 13 }, Style = Style("QuietButtonStyle") };
        AutomationProperties.SetName(refreshBtn, "Refresh Pull Request");
        AutomationProperties.SetAutomationId(refreshBtn, "prcard.refresh");
        refreshBtn.Click += (_, _) => _ = RefreshStatusAsync();

        var bar = new Grid { Padding = new Thickness(10, 8, 10, 6), ColumnSpacing = 8 };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.Children.Add(_backButton);
        _headerTitle.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(_headerTitle, 1);
        bar.Children.Add(_headerTitle);

        var trailing = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        trailing.Children.Add(refreshBtn);
        if (_onClose != null)
        {
            var close = new Button { Content = new FontIcon { Glyph = "\uE711", FontSize = 13 }, Style = Style("QuietButtonStyle") };
            AutomationProperties.SetName(close, "Close Pull Request Card");
            close.Click += (_, _) => _onClose();
            trailing.Children.Add(close);
        }
        Grid.SetColumn(trailing, 2);
        bar.Children.Add(trailing);

        _pinnedBar = new Border
        {
            Padding = new Thickness(16, 10, 16, 12),
            BorderThickness = new Thickness(0, 1, 0, 0),
            BorderBrush = Brush("DividerStrokeColorDefaultBrush"),
            Background = Brush("LayerFillColorDefaultBrush"),
            Visibility = Visibility.Collapsed,
        };
        AutomationProperties.SetAutomationId(_pinnedBar, "prcard.pinnedBar");

        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.Children.Add(bar);

        var scroller = new ScrollViewer { Content = _body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollMode = ScrollMode.Disabled };
        Grid.SetRow(scroller, 1);
        root.Children.Add(scroller);
        Grid.SetRow(_pinnedBar, 2);
        root.Children.Add(_pinnedBar);
        Content = root;

        _comments.Changed += OnCommentsChanged;
        Unloaded += (_, _) => _comments.Changed -= OnCommentsChanged;
        Render();
    }

    private void OnCommentsChanged() => Render();

    private async Task RefreshStatusAsync()
    {
        await _store.RefreshPRStatusAsync([(_session.Profile, _session.Id)], fresh: true, detail: true);
        if (_store.StatusFor(_session.Profile, _session.Id) is { } freshStatus) _status = freshStatus;
        Render();
    }

    public void UpdateStatus(SessionPRStatus status)
    {
        _status = status;
        Render();
    }

    public void Render()
    {
        _body.Children.Clear();
        _pinnedBar.Child = null;
        _pinnedBar.Visibility = Visibility.Collapsed;

        var model = PullRequestCardModel.Build(
            _session,
            _status,
            _focus,
            _comments.CountsByFile(openOnly: true),
            _store.RefreshedAt(_session.Key),
            botName: _botName,
            chatWorking: _chatWorking);

        if (_openDiffFile != null)
        {
            _backButton.Visibility = Visibility.Visible;
            _headerTitle.Text = _openDiffFile.FileName;
            var file = new SessionPRFile(_openDiffFile.Path, _openDiffFile.Additions, _openDiffFile.Deletions,
                _openDiffFile.Binary, _openDiffFile.Patch, _openDiffFile.PatchCut);
            var diffView = new InteractiveDiffView(file, _comments, model.BadgeLabel, reviewMessage =>
            {
                _onAction(new PullRequestActionItem(
                    PullRequestQuickAction.RequestChanges,
                    $"Send Review to {model.BotName}",
                    ConfirmationTitle: $"Send Review to {model.BotName}",
                    ConfirmationMessage: reviewMessage,
                    BotPrompt: reviewMessage));
            });
            _body.Children.Add(diffView);
            return;
        }

        if (_showingChecks && model.Checks != null)
        {
            _backButton.Visibility = Visibility.Visible;
            _headerTitle.Text = "Checks";
            RenderChecksSubpage(model, model.Checks);
            return;
        }

        _backButton.Visibility = Visibility.Collapsed;
        _headerTitle.Text = model.Number is { } n ? $"PR #{n}" : model.SheetTitle;

        // Title + State Badge + Verdict
        var topStack = new StackPanel { Spacing = 6 };
        var badgeRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        badgeRow.Children.Add(CodingPipelinePage.BadgePill(model.StateWords, StateColor(model.State)));
        if (model.Verdict != null) badgeRow.Children.Add(CodingPipelinePage.VerdictPill(model.Verdict));
        if (model.ReviewVerdict != PRReviewVerdict.None)
            badgeRow.Children.Add(CodingPipelinePage.BadgePill(model.ReviewVerdict.LabelWord(), ReviewColor(model.ReviewVerdict)));
        topStack.Children.Add(badgeRow);
        topStack.Children.Add(Text(model.Title, 17, bold: true));

        var metaParts = new List<string>();
        if (!string.IsNullOrWhiteSpace(model.Repo)) metaParts.Add(model.Repo!);
        if (!string.IsNullOrWhiteSpace(model.BranchRoute)) metaParts.Add(model.BranchRoute);
        if (model.CommentsCount > 0) metaParts.Add($"{model.CommentsCount} PR comments");
        if (_comments.OpenCount > 0) metaParts.Add($"{_comments.OpenCount} inline draft comments");
        if (metaParts.Count > 0) topStack.Children.Add(Text(string.Join(" · ", metaParts), 12, color: Secondary));
        if (model.RefreshedText != null) topStack.Children.Add(Text(model.RefreshedText, 11, color: Tertiary));
        _body.Children.Add(topStack);

        if (model.UnknownExplanation != null)
        {
            var warn = new StackPanel { Spacing = 8 };
            warn.Children.Add(Text(model.UnknownExplanation, 13, color: Secondary));
            var warnButtons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            warnButtons.Children.Add(Push("Try Again", () => _ = RefreshStatusAsync()));
            if (model.UnknownReason == SessionPRUnknownReason.Unmatched && _onRepository != null)
                warnButtons.Children.Add(Push("Link Repository…", () => _onRepository()));
            warn.Children.Add(warnButtons);
            _body.Children.Add(Card(warn, 10));
        }

        // Checks section
        if (model.Checks is { } checks)
        {
            _body.Children.Add(Header("Checks"));
            var rowGrid = new Grid { ColumnSpacing = 8 };
            rowGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            rowGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            rowGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            rowGrid.Children.Add(Dot(CheckColor(checks.State), 10));
            var summary = Text(checks.Summary, 13, bold: true, color: checks.State == SessionPRCheckState.Failed ? Critical : null);
            Grid.SetColumn(summary, 1);
            rowGrid.Children.Add(summary);
            if (checks.CanDrillIn)
            {
                var open = Quiet($"Details ({checks.Runs.Count}) ›", () => { _showingChecks = true; Render(); });
                Grid.SetColumn(open, 2);
                rowGrid.Children.Add(open);
            }
            var checksCard = Card(rowGrid, 10);
            if (checks.CanDrillIn) checksCard.Tapped += (_, _) => { _showingChecks = true; Render(); };
            _body.Children.Add(checksCard);
        }

        // Changed files section
        if (model.Files.Count > 0 || model.ChangesLabel != null)
        {
            _body.Children.Add(Header(model.ChangesLabel != null ? $"Changes · {model.ChangesLabel}" : "Changes"));
            var filesStack = new StackPanel { Spacing = 4 };
            foreach (var file in model.Files)
                filesStack.Children.Add(FileRowControl(file));
            if (model.MoreFilesWords != null)
                filesStack.Children.Add(Text(model.MoreFilesWords, 12, color: Secondary));
            _body.Children.Add(filesStack);
        }

        // Inline review comments summary bar
        if (_comments.OpenCount > 0)
        {
            var reviewBox = new Grid { ColumnSpacing = 8 };
            reviewBox.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            reviewBox.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            reviewBox.Children.Add(Text($"{_comments.OpenCount} inline review {(_comments.OpenCount == 1 ? "comment" : "comments")} ready", 13, bold: true));
            var sendBtn = Push($"Send Review to {model.BotName}", () =>
            {
                var msg = _comments.FormatReviewMessage(model.BadgeLabel);
                _onAction(new PullRequestActionItem(
                    PullRequestQuickAction.RequestChanges,
                    $"Send Review to {model.BotName}",
                    ConfirmationTitle: $"Send Review to {model.BotName}",
                    ConfirmationMessage: msg,
                    BotPrompt: msg));
            }, accent: true);
            Grid.SetColumn(sendBtn, 1);
            reviewBox.Children.Add(sendBtn);
            _body.Children.Add(Card(reviewBox, 10));
        }

        // Secondary actions (excluding the action already pinned to the calm bottom bar).
        var pinned = model.PinnedPrimaryAction;
        var listActions = model.Actions.Where(a =>
            (pinned == null || a.Kind != pinned.Kind)
            && (pinned == null || a.Kind != PullRequestQuickAction.OpenChat)).ToList();

        if (listActions.Count > 0)
        {
            _body.Children.Add(Header("Actions"));
            var actionsStack = new StackPanel { Spacing = 6 };
            foreach (var action in listActions)
            {
                var a = action;
                var btn = Push(a.Label, () => TriggerAction(model, a));
                btn.HorizontalAlignment = HorizontalAlignment.Stretch;
                btn.HorizontalContentAlignment = HorizontalAlignment.Left;
                if (a.Destructive) btn.Foreground = Critical;
                actionsStack.Children.Add(btn);
            }
            _body.Children.Add(actionsStack);
        }

        // Also in this chat
        if (model.Others.Count > 0)
        {
            _body.Children.Add(Header("Also in This Chat"));
            foreach (var sibling in model.Others)
            {
                var idx = sibling.Index;
                var row = new Grid { ColumnSpacing = 8 };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                row.Children.Add(Text(sibling.Title ?? sibling.Label, 13, wrap: false));
                var right = CodingPipelinePage.BadgePill(sibling.Label, StateColor(sibling.State));
                Grid.SetColumn(right, 1);
                row.Children.Add(right);
                var box = Card(row, 8);
                box.Tapped += (_, _) => { _focus = new PullRequestCardFocus.Item(idx); Render(); };
                _body.Children.Add(box);
            }
        }

        // Calm pinned bottom primary action bar (`PullRequestCardView.swift` `pinnedActionBar`).
        if (pinned != null)
            RenderPinnedActionBar(model, pinned);
    }

    private void RenderPinnedActionBar(PullRequestCardModel model, PullRequestActionItem primary)
    {
        var barGrid = new Grid { ColumnSpacing = 10 };
        barGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        barGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var label = primary.Kind switch
        {
            PullRequestQuickAction.AskBotToFixCI => $"Ask {model.BotName} to Fix Checks…",
            PullRequestQuickAction.AskBotToOpenPR => PullRequestCardModel.OpenPRTitle(model.BotName),
            PullRequestQuickAction.Merge => $"Ask {model.BotName} to Merge…",
            _ => primary.Label,
        };

        var primaryBtn = new Button
        {
            Content = Text(label, 13, bold: true, color: Solid(Microsoft.UI.Colors.White), wrap: false),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Center,
            Padding = new Thickness(12, 10, 12, 10),
            CornerRadius = new CornerRadius(8),
        };

        if (primary.Kind == PullRequestQuickAction.AskBotToFixCI)
        {
            primaryBtn.Background = Solid(Red);
            AutomationProperties.SetAutomationId(primaryBtn, "prcard.askToFixChecks");
        }
        else if (primary.Kind == PullRequestQuickAction.AskBotToOpenPR)
        {
            primaryBtn.Style = Style("AccentButtonStyle");
            primaryBtn.Content = label;
            AutomationProperties.SetAutomationId(primaryBtn, "prcard.askToOpenPR");
        }
        else if (primary.Kind == PullRequestQuickAction.Merge)
        {
            var isCleanReady = model.State == SessionPRState.Open
                && model.Checks?.State is not (SessionPRCheckState.Failed or SessionPRCheckState.Running)
                && !model.ChatWorking;
            if (isCleanReady)
            {
                primaryBtn.Background = Solid(Green);
            }
            else
            {
                primaryBtn.Style = Style("AccentButtonStyle");
                primaryBtn.Content = label;
            }
            AutomationProperties.SetAutomationId(primaryBtn, "prcard.askToMerge");
        }
        else
        {
            primaryBtn.Style = Style("AccentButtonStyle");
            primaryBtn.Content = label;
        }

        primaryBtn.Click += (_, _) => TriggerAction(model, primary);
        barGrid.Children.Add(primaryBtn);

        var openChatBtn = Push("Open Chat", () => _onAction(new PullRequestActionItem(PullRequestQuickAction.OpenChat, "Open Chat")));
        openChatBtn.Padding = new Thickness(14, 10, 14, 10);
        AutomationProperties.SetAutomationId(openChatBtn, "prcard.openChat");
        Grid.SetColumn(openChatBtn, 1);
        barGrid.Children.Add(openChatBtn);

        _pinnedBar.Child = barGrid;
        _pinnedBar.Visibility = Visibility.Visible;
    }

    private void TriggerAction(PullRequestCardModel model, PullRequestActionItem action)
    {
        if (action.Kind == PullRequestQuickAction.Merge)
        {
            // Ensure merge confirmation always carries the exact `chatWorking` / draft / failing-checks warning title.
            var mergeTitle = model.MergeConfirmTitle(_chatWorking);
            _onAction(action with { ConfirmationTitle = mergeTitle });
            return;
        }
        _onAction(action);
    }

    private FrameworkElement FileRowControl(PullRequestFileRow file)
    {
        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var left = new StackPanel { Spacing = 1 };
        var titleRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        titleRow.Children.Add(Text(file.FileName, 13, bold: true, wrap: false));
        if (file.CommentCount > 0)
            titleRow.Children.Add(CodingPipelinePage.BadgePill($"{file.CommentCount} notes", Blue));
        left.Children.Add(titleRow);
        if (!string.IsNullOrEmpty(file.Directory))
            left.Children.Add(Text(file.Directory, 11, color: Secondary, wrap: false));
        grid.Children.Add(left);

        var right = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        right.Children.Add(Text(file.StatsLabel, 12, color: Secondary, wrap: false));
        if (file.CanOpenDiff)
        {
            var openBtn = Quiet("Diff ›", () => { _openDiffFile = file; Render(); });
            right.Children.Add(openBtn);
        }
        else if (file.BodyKind == PullRequestFileBodyKind.TooLarge)
        {
            right.Children.Add(Text("Too large", 11, color: Tertiary, wrap: false));
        }
        Grid.SetColumn(right, 1);
        grid.Children.Add(right);

        var card = Card(grid, 8);
        if (file.CanOpenDiff) card.Tapped += (_, _) => { _openDiffFile = file; Render(); };
        return card;
    }

    private void RenderChecksSubpage(PullRequestCardModel model, PullRequestChecksRow checks)
    {
        _body.Children.Add(Text(checks.Summary, 15, bold: true, color: checks.State == SessionPRCheckState.Failed ? Critical : null));
        for (var i = 0; i < checks.Runs.Count; i++)
        {
            var run = checks.Runs[i];
            var grid = new Grid { ColumnSpacing = 8 };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.Children.Add(Dot(CheckColor(run.State), 8));

            var info = new StackPanel { Spacing = 2 };
            info.Children.Add(Text(run.Name, 13, bold: true));
            if (!string.IsNullOrWhiteSpace(run.Summary))
                info.Children.Add(Text(run.Summary!, 12, color: run.State == SessionPRCheckState.Failed ? Critical : Secondary));
            Grid.SetColumn(info, 1);
            grid.Children.Add(info);

            var trailing = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
            if (run.State == SessionPRCheckState.Failed)
            {
                var captured = run;
                var fixBtn = Push(model.FixSingleCheckLabel, () =>
                {
                    var prompt = model.PromptForFailingCheck(captured);
                    _onAction(new PullRequestActionItem(
                        PullRequestQuickAction.AskBotToFixCI,
                        model.FixSingleCheckLabel,
                        ConfirmationTitle: model.FixSingleCheckLabel,
                        ConfirmationMessage: prompt,
                        BotPrompt: prompt));
                });
                fixBtn.Foreground = Critical;
                AutomationProperties.SetAutomationId(fixBtn, $"prcard.run.{i}.fix");
                trailing.Children.Add(fixBtn);
            }
            if (PRFacts.ValidCheckRunUrl(run.Url) is { } validUrl && Uri.TryCreate(validUrl, UriKind.Absolute, out var uri))
            {
                var open = Quiet("Open", () => _ = Launcher.LaunchUriAsync(uri));
                AutomationProperties.SetAutomationId(open, $"prcard.run.{i}.open");
                trailing.Children.Add(open);
            }
            if (trailing.Children.Count > 0)
            {
                Grid.SetColumn(trailing, 2);
                grid.Children.Add(trailing);
            }

            _body.Children.Add(Card(grid, 8));
        }
    }

    private static Color StateColor(SessionPRState state) => state switch
    {
        SessionPRState.Open => Green,
        SessionPRState.Merged => Rgb(0xAF, 0x52, 0xDE),
        SessionPRState.Closed => Red,
        SessionPRState.Draft => Rgb(0x8E, 0x8E, 0x93),
        _ => Orange,
    };

    private static Color CheckColor(SessionPRCheckState state) => state switch
    {
        SessionPRCheckState.Passed => Green,
        SessionPRCheckState.Failed => Red,
        _ => Blue,
    };

    private static Color ReviewColor(PRReviewVerdict verdict) => verdict switch
    {
        PRReviewVerdict.Approved => Green,
        PRReviewVerdict.ChangesRequested => Red,
        PRReviewVerdict.ReviewRequired => Orange,
        _ => Rgb(0x8E, 0x8E, 0x93),
    };
}
