using Hermes.Core.Coding;
using HermesHQ.Features.Bots;
using HermesHQ.Features.Kanban;
using HermesHQ.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using static HermesHQ.Features.Kanban.PageKit;

namespace HermesHQ.Features.Coding;

/// Project Repository setup page (`App/Sessions/ProjectRepositoryPage.swift` port):
/// one-tap folder choices (`here` + collapsible `elsewhere`) and suggested `owner/repo` choices alongside custom entry,
/// automatic folder linking on coding projects, `prAutoLinkFailed` / load-failed health banners, and Link / Update / Unlink.
[Microsoft.UI.Xaml.Data.Bindable]
public sealed partial class ProjectRepositoryPage : Page
{
    private readonly CodingStore _store;
    private CodingProjectContext _project = new("default", "Project");
    private readonly StackPanel _body = new() { Spacing = 10, Padding = new Thickness(20, 12, 20, 28), MaxWidth = 640 };
    private readonly TextBlock _barTitle = new() { Text = "Repository", VerticalAlignment = VerticalAlignment.Center };
    private readonly NoticeLine _notice = new();

    private string _folder = "";
    private string _mainBranch = "main";
    private string _publicRepo = "";
    private string? _error;
    private string? _statusNote;
    private bool _othersOpen;
    private bool _saving;
    private RepositoryFolderChoiceSet _folderChoices = new([], []);
    private IReadOnlyList<string> _publicChoices = [];

    public ProjectRepositoryPage()
    {
        _store = CodingFeature.GetStore();
        AutomationProperties.SetAutomationId(this, "coding.repo-page");
        HermesHQ.Shell.PageBar.Title(_barTitle, "coding-repository");

        var back = Quiet("‹ Pipeline", () => CodingFeature.OpenProjectPipeline(_project));
        var bar = new Grid { Padding = HermesHQ.Shell.PageBar.Padding(12, 4), ColumnSpacing = 10 };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.Children.Add(back);
        Grid.SetColumn(_barTitle, 1);
        bar.Children.Add(_barTitle);

        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.Children.Add(bar);
        var scroller = new ScrollViewer { Content = _body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        Grid.SetRow(scroller, 1);
        root.Children.Add(scroller);
        Grid.SetRow(_notice.Bar, 1);
        root.Children.Add(_notice.Bar);
        Content = root;
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        if (e.Parameter is PlaceArgs { Argument: CodingProjectContext ctx }) _project = ctx;
        else if (e.Parameter is CodingProjectContext direct) _project = direct;

        LoadFromStore();
        ReadChoices();
        Render();
        _ = RefreshAsync();
    }

    private async Task RefreshAsync()
    {
        await _store.RefreshReposAsync();
        if (_store.RepoFor(_project.ProjectKey) == null
            && _store.SettingsFor(_project.ProjectKey).CodingProject
            && !_store.HasAutoLinkFailed(_project.ProjectKey))
        {
            await _store.LinkOwnFolderIfUnlinkedAsync(_project.ProjectKey, _project.RootFolder);
        }
        LoadFromStore();
        ReadChoices();
        Render();
    }

    private void LoadFromStore()
    {
        var existing = _store.RepoFor(_project.ProjectKey);
        var defaultRoot = RepoPathHelpers.NormalizeFolderPath(_project.RootFolder ?? _project.ProjectKey);
        if (existing != null)
        {
            _folder = existing.Path;
            _mainBranch = string.IsNullOrWhiteSpace(existing.Main) ? "main" : existing.Main;
            _publicRepo = existing.Mirror || !string.IsNullOrWhiteSpace(existing.PublicRepo) ? (existing.PublicRepo ?? "") : "";
        }
        else if (string.IsNullOrWhiteSpace(_folder))
        {
            _folder = RepoPathHelpers.IsAbsoluteFolderPath(defaultRoot) ? defaultRoot : "";
            _mainBranch = "main";
            _publicRepo = "";
        }
    }

    private void ReadChoices()
    {
        var byProfile = ListsHub.Current?.Sessions.ProjectsByProfile;
        _folderChoices = _store.RepositoryFolderChoices(_project.ProjectKey, byProfile, _project.RootFolder);
        _publicChoices = _store.PublicRepoChoices();
        var normalized = RepoPathHelpers.NormalizeFolderPath(_folder);
        if (_folderChoices.Elsewhere.Contains(normalized, StringComparer.Ordinal))
            _othersOpen = true;
    }

    private void Render()
    {
        _barTitle.Text = $"{_project.Label} · Repository";
        _body.Children.Clear();

        var existing = _store.RepoFor(_project.ProjectKey);

        // Load failed banner (`ProjectRepositoryPage.swift` `loadFailed`)
        if (_store.ReposState == SessionPRReposState.Failed && _store.Repos.Count == 0)
        {
            var retryRow = new Grid { ColumnSpacing = 10 };
            retryRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            retryRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            retryRow.Children.Add(Text("Couldn’t load linked repositories from the gateway.", 13, color: Secondary));
            var retryBtn = Push("Retry", () => _ = RefreshAsync());
            retryBtn.IsEnabled = !_saving;
            AutomationProperties.SetAutomationId(retryBtn, "project.repository.retry");
            Grid.SetColumn(retryBtn, 1);
            retryRow.Children.Add(retryBtn);
            _body.Children.Add(Card(retryRow, 10));
        }

        // Auto-link failed banner (`prAutoLinkFailed`)
        if (_store.HasAutoLinkFailed(_project.ProjectKey) && existing == null)
        {
            var autoBanner = new StackPanel { Spacing = 2 };
            autoBanner.Children.Add(Text("Link a git repository to track pull requests.", 13, bold: true));
            autoBanner.Children.Add(Text(
                "This project’s own folder isn’t a git repository on the computer running Hermes. Pick a known repository below or enter a path.",
                12, color: Secondary));
            var card = Card(autoBanner, 10);
            AutomationProperties.SetAutomationId(card, "project.repository.autoLinkFailed");
            _body.Children.Add(card);
        }

        // Folder section (`Folder` free-type + `here` choices + collapsible `elsewhere` choices)
        _body.Children.Add(Header("Folder"));
        var folderCard = new StackPanel { Spacing = 8 };
        var pathBox = new TextBox { Text = _folder, PlaceholderText = "/Users/you/Projects/app" };
        pathBox.TextChanged += (_, _) => { _folder = pathBox.Text; _error = null; };
        AutomationProperties.SetAutomationId(pathBox, "coding.repo.path");
        folderCard.Children.Add(pathBox);

        if (!string.IsNullOrEmpty(_error))
            folderCard.Children.Add(Text(_error, 12, color: Critical));
        if (!string.IsNullOrEmpty(_statusNote))
            folderCard.Children.Add(Text(_statusNote, 12, color: Solid(Green)));

        var normalizedFolder = RepoPathHelpers.NormalizeFolderPath(_folder);
        foreach (var choice in _folderChoices.Here)
            folderCard.Children.Add(FolderChoiceRow(choice, string.Equals(normalizedFolder, choice, StringComparison.Ordinal)));

        if (_folderChoices.Elsewhere.Count > 0)
        {
            var othersHeader = new Grid { ColumnSpacing = 8 };
            othersHeader.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            othersHeader.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var othersLabel = _folderChoices.Here.Count == 0 ? "Repositories" : "Other Repositories";
            othersHeader.Children.Add(Text(othersLabel, 13, bold: true));
            var rightMeta = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
            rightMeta.Children.Add(Text(_folderChoices.Elsewhere.Count.ToString(), 12, color: Secondary, wrap: false));
            rightMeta.Children.Add(new FontIcon { Glyph = _othersOpen ? "\uE70D" : "\uE76C", FontSize = 10, Foreground = Tertiary });
            Grid.SetColumn(rightMeta, 1);
            othersHeader.Children.Add(rightMeta);

            var toggleBtn = new Button
            {
                Content = othersHeader,
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Stretch,
                Style = Style("QuietButtonStyle"),
                Padding = new Thickness(6, 6, 6, 6),
            };
            AutomationProperties.SetAutomationId(toggleBtn, "project.repository.others");
            toggleBtn.Click += (_, _) => { _othersOpen = !_othersOpen; Render(); };
            folderCard.Children.Add(toggleBtn);

            if (_othersOpen)
            {
                foreach (var choice in _folderChoices.Elsewhere)
                    folderCard.Children.Add(FolderChoiceRow(choice, string.Equals(normalizedFolder, choice, StringComparison.Ordinal)));
            }
        }
        _body.Children.Add(Card(folderCard, 12));
        _body.Children.Add(Text(
            "The git repository on the computer running Hermes that this project’s chats work in. Each chat’s mark is read from the branches it made there.",
            12, color: Secondary));

        // Default branch
        _body.Children.Add(Header("Main Branch"));
        var branchBox = new TextBox { Text = _mainBranch, PlaceholderText = "main" };
        branchBox.TextChanged += (_, _) => _mainBranch = branchBox.Text;
        AutomationProperties.SetAutomationId(branchBox, "coding.repo.main");
        _body.Children.Add(Card(branchBox, 10));

        // Public Repository section (`Public Repository` free-type + `The Folder’s Own` + suggested `owner/repo` choices)
        _body.Children.Add(Header("Public Repository"));
        var pubCard = new StackPanel { Spacing = 8 };
        var pubBox = new TextBox { Text = _publicRepo, PlaceholderText = "owner/repo or a GitHub link" };
        pubBox.TextChanged += (_, _) => { _publicRepo = pubBox.Text; _error = null; };
        AutomationProperties.SetAutomationId(pubBox, "coding.repo.public");
        pubCard.Children.Add(pubBox);

        var isOwnPicked = string.IsNullOrWhiteSpace(_publicRepo);
        pubCard.Children.Add(ChoiceRow(
            "The Folder’s Own",
            "Whatever GitHub repository its origin is",
            isOwnPicked,
            "project.repository.public.own",
            () => { _publicRepo = ""; _error = null; Render(); }));

        var normalizedPublic = RepoPathHelpers.NormalizePublicRepo(_publicRepo);
        foreach (var slug in _publicChoices)
        {
            var picked = string.Equals(normalizedPublic, slug, StringComparison.OrdinalIgnoreCase);
            var captured = slug;
            pubCard.Children.Add(ChoiceRow(
                captured,
                null,
                picked,
                "project.repository.public." + captured,
                () => { _publicRepo = captured; _error = null; Render(); }));
        }
        _body.Children.Add(Card(pubCard, 12));
        _body.Children.Add(Text(
            "Leave it on The Folder’s Own unless the code is published to a different GitHub repository than the folder’s own. You can paste a GitHub link.",
            12, color: Secondary));

        // Linked summary
        if (existing != null)
        {
            _body.Children.Add(Header("Linked"));
            var linkedStack = new StackPanel { Spacing = 6 };
            linkedStack.Children.Add(InfoRow("Main Branch", existing.Main));
            if (!string.IsNullOrWhiteSpace(existing.PublicRepo))
                linkedStack.Children.Add(InfoRow(existing.Mirror ? "Publishes To" : "On GitHub", existing.PublicRepo!));
            _body.Children.Add(Card(linkedStack, 10));
        }

        // Actions
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 8, 0, 0) };
        var saveBtn = Push(existing != null ? "Update Link" : "Link Repository", () => _ = SaveAsync(), accent: true);
        saveBtn.IsEnabled = !_saving && !string.IsNullOrWhiteSpace(_folder);
        AutomationProperties.SetAutomationId(saveBtn, "coding.repo.save");
        actions.Children.Add(saveBtn);

        if (existing != null)
        {
            var unlinkBtn = Push("Unlink", () => _ = UnlinkAsync());
            unlinkBtn.Foreground = Critical;
            unlinkBtn.IsEnabled = !_saving;
            AutomationProperties.SetAutomationId(unlinkBtn, "coding.repo.unlink");
            actions.Children.Add(unlinkBtn);
        }
        _body.Children.Add(actions);
    }

    private FrameworkElement FolderChoiceRow(string path, bool picked) =>
        ChoiceRow(
            RepoPathHelpers.FolderName(path),
            RepoPathHelpers.ParentFolder(path),
            picked,
            "project.repository.folder." + RepoPathHelpers.FolderName(path),
            () =>
            {
                _folder = path;
                _error = null;
                Render();
            });

    private FrameworkElement ChoiceRow(string title, string? subtitle, bool picked, string automationId, Action onPick)
    {
        var grid = new Grid { ColumnSpacing = 10 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var stack = new StackPanel { Spacing = 1 };
        stack.Children.Add(Text(title, 13, bold: picked, wrap: false));
        if (!string.IsNullOrWhiteSpace(subtitle))
            stack.Children.Add(Text(subtitle, 11, color: Secondary, wrap: false));
        grid.Children.Add(stack);

        if (picked)
        {
            var check = new FontIcon { Glyph = "\uE73E", FontSize = 13, Foreground = Accent, VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(check, 1);
            grid.Children.Add(check);
        }

        var btn = new Button
        {
            Content = grid,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Style = Style("QuietButtonStyle"),
            Padding = new Thickness(8, 6, 8, 6),
            IsEnabled = !_saving,
        };
        AutomationProperties.SetAutomationId(btn, automationId);
        btn.Click += (_, _) => { if (!picked) onPick(); };
        return btn;
    }

    private static FrameworkElement InfoRow(string title, string value)
    {
        var grid = new Grid { ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(Text(title, 13));
        var val = Text(value, 13, color: Secondary, wrap: false);
        Grid.SetColumn(val, 1);
        grid.Children.Add(val);
        return grid;
    }

    private async Task SaveAsync()
    {
        _error = null;
        _statusNote = null;
        var path = RepoPathHelpers.NormalizeFolderPath(_folder);
        if (string.IsNullOrEmpty(path))
        {
            _error = "Enter the repository folder path.";
            Render();
            return;
        }

        string? normalizedPublic = null;
        var hasPublic = !string.IsNullOrWhiteSpace(_publicRepo);
        if (hasPublic)
        {
            normalizedPublic = RepoPathHelpers.NormalizePublicRepo(_publicRepo);
            if (normalizedPublic == null)
            {
                _error = "Write the public repository as owner/repo.";
                Render();
                return;
            }
        }

        _saving = true;
        Render();
        try
        {
            var repo = new SessionPRRepo(
                Project: _project.ProjectKey,
                Path: path,
                Main: string.IsNullOrWhiteSpace(_mainBranch) ? "main" : _mainBranch.Trim(),
                PublicRepo: normalizedPublic,
                Mirror: hasPublic);
            var saved = await _store.LinkRepoAsync(repo);
            _statusNote = $"Linked to {RepoPathHelpers.FolderName(saved.Path)} ({saved.Main}). Checking pull requests…";
            _notice.Show("Repository linked.");
            LoadFromStore();
            ReadChoices();
        }
        catch (SessionPRRepoException ex) when (ex.Kind == SessionPRRepoErrorKind.NotARepository)
        {
            _error = "That folder isn’t a git repository on the computer running Hermes.";
        }
        catch (SessionPRRepoException ex) when (ex.Kind == SessionPRRepoErrorKind.InvalidPublicRepo)
        {
            _error = "Write the public repository as owner/repo.";
        }
        catch (Exception ex)
        {
            _error = ex.Message;
        }
        finally
        {
            _saving = false;
            Render();
        }
    }

    private async Task UnlinkAsync()
    {
        if (!await ConfirmAsync(XamlRoot, "Unlink Repository?", "Pull request status will stop updating for this project until linked again.", "Unlink"))
            return;

        _saving = true;
        _error = null;
        _statusNote = null;
        Render();
        try
        {
            await _store.UnlinkRepoAsync(_project.ProjectKey);
            _notice.Show("Repository unlinked.");
            LoadFromStore();
            ReadChoices();
        }
        catch (Exception ex)
        {
            _error = ex.Message;
        }
        finally
        {
            _saving = false;
            Render();
        }
    }
}
