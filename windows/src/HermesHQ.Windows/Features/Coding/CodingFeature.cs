using Hermes.Core;
using Hermes.Core.Coding;
using Hermes.Core.Composer;
using Hermes.Core.Kanban;
using Hermes.Core.Sessions;
using HermesHQ.Features.Kanban;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.System;

namespace HermesHQ.Features.Coding;

/// Navigation payload for opening a project's Calm Shipping Pipeline view.
public sealed record CodingProjectContext(
    string ProjectKey,
    string Label,
    string? RootFolder = null,
    IReadOnlyList<SessionSummary>? Sessions = null);

/// Entry points for the Coding Pipeline, PR Cards, Interactive Diff Comments, Project Repository, and Project Settings.
/// Hook `CodingFeature.Register()` from `FeatureRegistry.RegisterAll()`.
public static class CodingFeature
{
    public const string PipelinePlaceId = "coding-pipeline";
    public const string RepositoryPlaceId = "coding-repository";

    private static bool _registered;
    private static string? _storeAccount;
    private static CodingStore? _store;
    private static readonly Dictionary<string, DiffCommentStore> CommentStores = new(StringComparer.Ordinal);
    private static readonly List<ChatContext> OpenChats = [];

    /// Registers the Coding Pipeline and Project Repository places and hooks chat PR actions.
    public static void Register()
    {
        if (_registered) return;
        _registered = true;

        RegisterPlace(PipelinePlaceId, "Coding Pipeline", "\uE943", Places.Tools, typeof(CodingPipelinePage),
            ["coding", "pipeline", "pr", "pull requests", "review", "diff", "projects"]);
        RegisterPlace(RepositoryPlaceId, "Project Repository", "\uE8B7", Places.Tools, typeof(ProjectRepositoryPage),
            ["repository", "git", "github", "repo"]);

        AppState.ClientChanged += _ => ResetStore();
        ChatExtensions.OnOpen.Add(AttachToChat);
    }

    /// Returns the per-account `CodingStore` backed by the live gateway add-on and local project preferences.
    public static CodingStore GetStore()
    {
        var client = AppState.Client;
        var accountId = client?.AccountId ?? "offline";
        if (_store != null && _storeAccount == accountId) return _store;

        var api = client != null ? new CodingApi(new GatewaySessionRest(client.Session)) : null;
        var prefsPath = System.IO.Path.Combine(AppPaths.Root, "coding-projects.json");
        _store = new CodingStore(api, new JsonFileStore(prefsPath));
        _storeAccount = accountId;
        return _store;
    }

    /// Returns a persisted inline diff comment store scoped to one session/PR key.
    public static DiffCommentStore GetCommentStore(string sessionKey)
    {
        if (CommentStores.TryGetValue(sessionKey, out var existing)) return existing;
        var prefsPath = System.IO.Path.Combine(AppPaths.Root, "coding-diff-comments.json");
        var store = new DiffCommentStore(new JsonFileStore(prefsPath), "diff." + sessionKey);
        CommentStores[sessionKey] = store;
        return store;
    }

    /// Opens the Calm Shipping Pipeline page for a `CodingProjectContext`.
    public static void OpenProjectPipeline(CodingProjectContext project) =>
        Navigator.Open(PipelinePlaceId, project);

    /// Opens the Calm Shipping Pipeline page for a `SessionProject`.
    public static void OpenProjectPipeline(SessionProject project, string profile = "default", IReadOnlyList<SessionSummary>? sessions = null) =>
        OpenProjectPipeline(new CodingProjectContext(SessionProjects.KeyOf(project, profile), project.Label, project.Root, sessions));

    /// Builds an embeddable Pull Request card control suitable for chat panels, panes, or dialogs.
    public static PullRequestCardView BuildPullRequestCard(
        SessionSummary session,
        SessionPRStatus status,
        CodingStore? store = null,
        DiffCommentStore? comments = null,
        Action<PullRequestActionItem>? onAction = null,
        Action? onClose = null,
        PullRequestCardFocus? initialFocus = null,
        string? botName = null,
        bool? chatWorking = null,
        Action? onRepository = null)
    {
        var activeStore = store ?? GetStore();
        var activeComments = comments ?? GetCommentStore(session.Key);
        var resolvedBot = botName ?? PageKit.BotName(session.Profile);
        var resolvedWorking = chatWorking ?? IsChatWorking(session);
        return new PullRequestCardView(
            session,
            status,
            activeStore,
            activeComments,
            onAction ?? (action => ExecuteDefaultAction(session, status, action, activeStore, activeComments)),
            onClose,
            initialFocus,
            resolvedBot,
            resolvedWorking,
            onRepository);
    }

    /// Opens a PR Card inside a modal `ContentDialog` with confirm-and-deliver directly to the bot session.
    public static async Task OpenPullRequestCardAsync(
        XamlRoot? root,
        SessionSummary session,
        SessionPRStatus status,
        CodingStore? store = null,
        DiffCommentStore? comments = null,
        Action<PullRequestActionItem>? onAction = null,
        PullRequestCardFocus? initialFocus = null,
        Action? openChat = null,
        Action? onRepository = null)
    {
        var activeStore = store ?? GetStore();
        var activeComments = comments ?? GetCommentStore(session.Key);
        ContentDialog? dialog = null;

        Action<PullRequestActionItem> handler = onAction ?? (action =>
        {
            _ = ExecuteActionAsync(
                root,
                session,
                activeStore.StatusFor(session.Profile, session.Id) ?? status,
                action,
                activeStore,
                activeComments,
                closeCard: () => dialog?.Hide(),
                openChat: openChat);
        });

        var card = BuildPullRequestCard(
            session,
            status,
            activeStore,
            activeComments,
            handler,
            onClose: () => dialog?.Hide(),
            initialFocus: initialFocus,
            botName: PageKit.BotName(session.Profile),
            chatWorking: IsChatWorking(session),
            onRepository: onRepository == null ? null : () => { dialog?.Hide(); onRepository(); });
        card.MinWidth = 520;
        card.MaxHeight = 640;

        dialog = new ContentDialog
        {
            Title = status.Number is { } n ? $"Pull Request #{n}" : "Branch",
            Content = card,
            CloseButtonText = "Done",
            DefaultButton = ContentDialogButton.Close,
        };
        await PageKit.ShowAsync(root, dialog);
    }

    /// Opens the Project Repository page for linking/updating a project's Git repo.
    public static void OpenProjectRepository(CodingProjectContext project) =>
        Navigator.Open(RepositoryPlaceId, project);

    /// Opens the Project Settings dialog for a project (`ProjectSettingsPage.swift` port).
    public static Task<ProjectSettings?> OpenProjectSettingsAsync(
        XamlRoot? root,
        string projectKey,
        string projectLabel,
        string? defaultFolder = null,
        CodingStore? store = null) =>
        ProjectSettingsDialog.PresentAsync(root, projectKey, projectLabel, defaultFolder, store ?? GetStore());

    /// Opens the interactive diff viewer with inline line comments for a single changed file.
    public static async Task OpenDiffViewerAsync(
        XamlRoot? root,
        SessionPRFile file,
        DiffCommentStore comments,
        string? prLabel = null,
        Action<string>? onSendReview = null)
    {
        var viewer = new InteractiveDiffView(file, comments, prLabel, onSendReview);
        viewer.MinWidth = 640;
        viewer.MaxHeight = 640;
        var dialog = new ContentDialog
        {
            Title = file.Path,
            Content = viewer,
            CloseButtonText = "Close",
            DefaultButton = ContentDialogButton.Close,
        };
        await PageKit.ShowAsync(root, dialog);
    }

    /// Confirms PR card or row quick actions and delivers the words directly to the bot session (`PullRequestCardSheet.deliver`).
    public static async Task<bool> ExecuteActionAsync(
        XamlRoot? root,
        SessionSummary session,
        SessionPRStatus status,
        PullRequestActionItem action,
        CodingStore store,
        DiffCommentStore comments,
        Action? closeCard = null,
        Action? openChat = null)
    {
        switch (action.Kind)
        {
            case PullRequestQuickAction.OpenInBrowser:
                if (PRFacts.ValidGitHubPullUrl(status.Url) is { } validUrl && Uri.TryCreate(validUrl, UriKind.Absolute, out var uri))
                    _ = Launcher.LaunchUriAsync(uri);
                return true;

            case PullRequestQuickAction.OpenChat:
                closeCard?.Invoke();
                if (openChat != null) openChat();
                else Navigator.Go(new ChatDestination(session.Profile, session.Id, session.Title));
                return true;

            case PullRequestQuickAction.MarkClosed:
                await store.MarkClosedAsync(session.Profile, session.Id, closed: true);
                return true;

            case PullRequestQuickAction.Reopen:
                await store.MarkClosedAsync(session.Profile, session.Id, closed: false);
                return true;

            default:
            {
                var words = action.Kind == PullRequestQuickAction.RequestChanges
                    ? comments.FormatReviewMessage(status.Label, action.BotPrompt)
                    : action.BotPrompt ?? "";
                if (string.IsNullOrWhiteSpace(words)) words = action.BotPrompt ?? "";
                words = words.Trim();
                if (words.Length == 0) return false;

                var confirmTitle = (action.ConfirmationTitle ?? action.Label).Replace("…", "").Trim();
                var confirmBody = !string.IsNullOrWhiteSpace(action.ConfirmationMessage) && action.ConfirmationMessage != words
                    ? $"{action.ConfirmationMessage}\n\n{words}"
                    : words;

                if (root != null)
                {
                    // Close any host dialog and let WinUI finish dismissing it before presenting confirmation.
                    if (closeCard != null)
                    {
                        closeCard();
                        await Task.Delay(50);
                    }
                    var confirmed = await PageKit.ConfirmAsync(root, confirmTitle, confirmBody, "Send");
                    if (!confirmed) return false;
                }
                else
                {
                    closeCard?.Invoke();
                }

                return await DeliverToChatAsync(root, session, words, openChat);
            }
        }
    }

    /// Posts `words` directly to the bot session, opening it first when not already on screen (`PullRequestCardSheet.deliver`).
    /// Never fails silently: if the chat does not open in time, shows an explicit alert with Copy Message.
    public static async Task<bool> DeliverToChatAsync(
        XamlRoot? root,
        SessionSummary session,
        string words,
        Action? openChat = null)
    {
        words = words.Trim();
        if (words.Length == 0) return false;

        var ctx = FindOpenChat(session.Profile, session.Id);
        if (ctx == null)
        {
            if (openChat != null) openChat();
            else Navigator.Go(new ChatDestination(session.Profile, session.Id, session.Title));

            for (var attempt = 0; attempt < 40; attempt++)
            {
                await Task.Delay(50);
                ctx = FindOpenChat(session.Profile, session.Id);
                if (ctx != null) break;
            }
        }

        if (ctx != null)
        {
            if (!(ctx.Session.Busy && ctx.SendHandler != null && ctx.SendHandler(words)))
                _ = ctx.Session.SendAsync(words, queued: ctx.Session.Busy);
            AppLog.Note("coding", $"pr card: delivered prompt ({words.Length} chars)");
            return true;
        }

        AppLog.Note("coding", $"pr card: chat did not open in time ({words.Length} chars)");
        if (root != null)
        {
            var copyDialog = new ContentDialog
            {
                Title = "Couldn’t Send Message",
                Content = PageKit.Text($"The chat didn’t open in time, so nothing was sent:\n\n{words}"),
                PrimaryButtonText = "Copy Message",
                CloseButtonText = "OK",
                DefaultButton = ContentDialogButton.Primary,
            };
            if (await PageKit.ShowAsync(root, copyDialog) == ContentDialogResult.Primary)
                PageKit.Copy(words);
        }
        return false;
    }

    internal static void ExecuteDefaultAction(
        SessionSummary session,
        SessionPRStatus status,
        PullRequestActionItem action,
        CodingStore store,
        DiffCommentStore comments)
    {
        switch (action.Kind)
        {
            case PullRequestQuickAction.OpenInBrowser:
                if (PRFacts.ValidGitHubPullUrl(status.Url) is { } validUrl && Uri.TryCreate(validUrl, UriKind.Absolute, out var uri))
                    _ = Launcher.LaunchUriAsync(uri);
                break;

            case PullRequestQuickAction.OpenChat:
                Navigator.Go(new ChatDestination(session.Profile, session.Id, session.Title));
                break;

            case PullRequestQuickAction.MarkClosed:
                _ = store.MarkClosedAsync(session.Profile, session.Id, closed: true);
                break;

            case PullRequestQuickAction.Reopen:
                _ = store.MarkClosedAsync(session.Profile, session.Id, closed: false);
                break;

            case PullRequestQuickAction.RequestChanges:
                var reviewText = comments.FormatReviewMessage(status.Label, action.BotPrompt);
                _ = DeliverToChatAsync(null, session, string.IsNullOrWhiteSpace(reviewText) ? (action.BotPrompt ?? "") : reviewText);
                break;

            default:
                if (!string.IsNullOrWhiteSpace(action.BotPrompt))
                    _ = DeliverToChatAsync(null, session, action.BotPrompt);
                break;
        }
    }

    private static bool IsChatWorking(SessionSummary session) =>
        session.IsRunning
        || session.Status == SessionStatus.Working
        || FindOpenChat(session.Profile, session.Id)?.Session.Busy == true;

    private static ChatContext? FindOpenChat(string profile, string storedId)
    {
        for (var i = OpenChats.Count - 1; i >= 0; i--)
        {
            var c = OpenChats[i];
            if (string.Equals(c.Session.Profile, profile, StringComparison.Ordinal)
                && string.Equals(c.Session.StoredId, storedId, StringComparison.Ordinal))
                return c;
        }
        return null;
    }

    private static void AttachToChat(ChatContext ctx)
    {
        OpenChats.Add(ctx);
        ctx.Closed += () => OpenChats.Remove(ctx);

        var menuItem = new MenuFlyoutItem
        {
            Text = "Pull Request Details…",
            Icon = new FontIcon { Glyph = "\uE943" },
        };
        menuItem.Click += async (_, _) =>
        {
            var store = GetStore();
            var session = new SessionSummary
            {
                Id = ctx.Session.StoredId,
                Profile = ctx.Session.Profile,
                Title = ctx.Session.Title,
                Cwd = ctx.Session.Cwd,
                IsRunning = ctx.Session.Busy,
                Status = ctx.Session.Busy ? SessionStatus.Working : SessionStatus.Idle,
            };
            await store.RefreshPRStatusAsync([(session.Profile, session.Id)], fresh: true, detail: true);
            var status = store.StatusFor(session.Profile, session.Id)
                ?? new SessionPRStatus(SessionPRState.Unknown, SessionPRUnknownReason.Unmatched);
            await OpenPullRequestCardAsync(ctx.Page.XamlRoot, session, status, store, GetCommentStore(session.Key));
        };
        ctx.MoreMenu.Items.Add(menuItem);
    }

    private static void RegisterPlace(string id, string title, string glyph, string section, Type page, string[] keywords)
    {
        var existing = Places.All.FirstOrDefault(p => p.Id == id);
        if (existing != null) existing.Page = page;
        else Places.All.Add(new Place(id, title, glyph, section, page, keywords));
    }

    private static void ResetStore()
    {
        _store = null;
        _storeAccount = null;
        CommentStores.Clear();
    }
}
