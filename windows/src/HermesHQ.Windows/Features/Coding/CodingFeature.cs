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
        Action? onClose = null)
    {
        var activeStore = store ?? GetStore();
        var activeComments = comments ?? GetCommentStore(session.Key);
        return new PullRequestCardView(
            session,
            status,
            activeStore,
            activeComments,
            onAction ?? (action => ExecuteDefaultAction(session, status, action, activeStore, activeComments)),
            onClose);
    }

    /// Opens a PR Card inside a modal `ContentDialog`.
    public static async Task OpenPullRequestCardAsync(
        XamlRoot? root,
        SessionSummary session,
        SessionPRStatus status,
        CodingStore? store = null,
        DiffCommentStore? comments = null,
        Action<PullRequestActionItem>? onAction = null)
    {
        var activeStore = store ?? GetStore();
        var activeComments = comments ?? GetCommentStore(session.Key);
        var card = BuildPullRequestCard(session, status, activeStore, activeComments, onAction);
        card.MinWidth = 520;
        card.MaxHeight = 640;
        var dialog = new ContentDialog
        {
            Title = status.Number is { } n ? $"Pull Request #{n}" : "Pull Request",
            Content = card,
            CloseButtonText = "Done",
            DefaultButton = ContentDialogButton.Close,
        };
        await PageKit.ShowAsync(root, dialog);
    }

    /// Opens the Project Repository page or dialog for linking/updating a project's Git repo.
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
                Navigator.Go(new ChatDestination(session.Profile, session.Id, session.Title,
                    string.IsNullOrWhiteSpace(reviewText) ? (action.BotPrompt ?? "") : reviewText));
                break;

            default:
                if (!string.IsNullOrWhiteSpace(action.BotPrompt))
                    Navigator.Go(new ChatDestination(session.Profile, session.Id, session.Title, action.BotPrompt));
                break;
        }
    }

    private static void AttachToChat(ChatContext ctx)
    {
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
            };
            await store.RefreshPRStatusAsync([(session.Profile, session.Id)], fresh: true, detail: true);
            var status = store.StatusFor(session.Key) ?? new SessionPRStatus(SessionPRState.Unknown, SessionPRUnknownReason.Unmatched);
            await OpenPullRequestCardAsync(ctx.Page.XamlRoot, session, status, store, GetCommentStore(session.Key), action =>
            {
                if (action.Kind is PullRequestQuickAction.Merge or PullRequestQuickAction.Approve or PullRequestQuickAction.AskBotToFixCI
                    or PullRequestQuickAction.AskBotToFixReview or PullRequestQuickAction.Checkout)
                {
                    if (!string.IsNullOrWhiteSpace(action.BotPrompt))
                    {
                        ctx.Composer.Text = action.BotPrompt;
                        ctx.RefreshComposer();
                    }
                    return;
                }
                if (action.Kind == PullRequestQuickAction.RequestChanges)
                {
                    var draft = GetCommentStore(session.Key).FormatReviewMessage(status.Label, action.BotPrompt);
                    ctx.Composer.Text = string.IsNullOrWhiteSpace(draft) ? (action.BotPrompt ?? "") : draft;
                    ctx.RefreshComposer();
                    return;
                }
                ExecuteDefaultAction(session, status, action, store, GetCommentStore(session.Key));
            });
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
