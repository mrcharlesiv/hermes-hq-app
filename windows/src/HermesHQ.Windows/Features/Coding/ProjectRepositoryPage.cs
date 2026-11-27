using Hermes.Core.Coding;
using HermesHQ.Features.Kanban;
using HermesHQ.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using static HermesHQ.Features.Kanban.PageKit;

namespace HermesHQ.Features.Coding;

/// Project Repository setup page (`App/Sessions/ProjectRepositoryPage.swift` port):
/// choose folder (`This project's folder` vs `Another folder`), default branch, public GitHub `owner/repo` mirror,
/// Link / Update / Unlink, and inline validation + error retry.
[Microsoft.UI.Xaml.Data.Bindable]
public sealed partial class ProjectRepositoryPage : Page
{
    private readonly CodingStore _store;
    private CodingProjectContext _project = new("default", "Project");
    private readonly StackPanel _body = new() { Spacing = 10, Padding = new Thickness(20, 12, 20, 28), MaxWidth = 640 };
    private readonly TextBlock _barTitle = new() { Text = "Repository", VerticalAlignment = VerticalAlignment.Center };
    private readonly NoticeLine _notice = new();

    private bool _useOtherFolder;
    private string _otherFolder = "";
    private string _mainBranch = "main";
    private bool _usePublicMirror;
    private string _publicRepo = "";
    private string? _error;
    private bool _saving;

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
        Render();
        _ = RefreshAsync();
    }

    private async Task RefreshAsync()
    {
        await _store.RefreshReposAsync();
        LoadFromStore();
        Render();
    }

    private void LoadFromStore()
    {
        var existing = _store.RepoFor(_project.ProjectKey);
        var defaultRoot = RepoPathHelpers.NormalizeFolderPath(_project.RootFolder);
        if (existing != null)
        {
            _useOtherFolder = !string.IsNullOrEmpty(defaultRoot)
                && !string.Equals(RepoPathHelpers.NormalizeFolderPath(existing.Path), defaultRoot, StringComparison.OrdinalIgnoreCase);
            _otherFolder = existing.Path;
            _mainBranch = string.IsNullOrWhiteSpace(existing.Main) ? "main" : existing.Main;
            _usePublicMirror = existing.Mirror || !string.IsNullOrWhiteSpace(existing.PublicRepo);
            _publicRepo = existing.PublicRepo ?? "";
        }
        else
        {
            _useOtherFolder = string.IsNullOrEmpty(defaultRoot);
            _otherFolder = defaultRoot;
            _mainBranch = "main";
            _usePublicMirror = false;
            _publicRepo = "";
        }
    }

    private void Render()
    {
        _barTitle.Text = $"{_project.Label} · Repository";
        _body.Children.Clear();

        var existing = _store.RepoFor(_project.ProjectKey);
        var defaultRoot = RepoPathHelpers.NormalizeFolderPath(_project.RootFolder);

        _body.Children.Add(Text(
            "Link the Git checkout for this project so Hermes can check open pull requests, CI checks, and diff stats.",
            13, color: Secondary));

        // Folder choice
        _body.Children.Add(Header("Repository Folder"));
        var folderCard = new StackPanel { Spacing = 8 };
        if (!string.IsNullOrEmpty(defaultRoot))
        {
            var here = new RadioButton { Content = $"Project folder ({defaultRoot})", GroupName = "repo-folder", IsChecked = !_useOtherFolder };
            here.Checked += (_, _) => { _useOtherFolder = false; Render(); };
            folderCard.Children.Add(here);
        }
        var elsewhere = new RadioButton { Content = "Another folder on the gateway", GroupName = "repo-folder", IsChecked = _useOtherFolder };
        elsewhere.Checked += (_, _) => { _useOtherFolder = true; Render(); };
        folderCard.Children.Add(elsewhere);

        if (_useOtherFolder)
        {
            var pathBox = new TextBox { Text = _otherFolder, PlaceholderText = "~/Projects/my-repo" };
            pathBox.TextChanged += (_, _) => _otherFolder = pathBox.Text;
            AutomationProperties.SetAutomationId(pathBox, "coding.repo.path");
            folderCard.Children.Add(pathBox);
        }
        _body.Children.Add(Card(folderCard, 12));

        // Default branch
        _body.Children.Add(Header("Default Branch"));
        var branchBox = new TextBox { Text = _mainBranch, PlaceholderText = "main" };
        branchBox.TextChanged += (_, _) => _mainBranch = branchBox.Text;
        AutomationProperties.SetAutomationId(branchBox, "coding.repo.main");
        _body.Children.Add(Card(branchBox, 10));

        // GitHub / Public Mirror choice
        _body.Children.Add(Header("GitHub Repository"));
        var pubCard = new StackPanel { Spacing = 8 };
        var sameRepo = new RadioButton { Content = "Use the git origin remote", GroupName = "repo-public", IsChecked = !_usePublicMirror };
        sameRepo.Checked += (_, _) => { _usePublicMirror = false; Render(); };
        var mirrorRepo = new RadioButton { Content = "Match PRs against a GitHub repository (owner/repo)", GroupName = "repo-public", IsChecked = _usePublicMirror };
        mirrorRepo.Checked += (_, _) => { _usePublicMirror = true; Render(); };
        pubCard.Children.Add(sameRepo);
        pubCard.Children.Add(mirrorRepo);

        if (_usePublicMirror)
        {
            var pubBox = new TextBox { Text = _publicRepo, PlaceholderText = "owner/repo or https://github.com/owner/repo" };
            pubBox.TextChanged += (_, _) => _publicRepo = pubBox.Text;
            AutomationProperties.SetAutomationId(pubBox, "coding.repo.public");
            pubCard.Children.Add(pubBox);
        }
        _body.Children.Add(Card(pubCard, 12));

        if (!string.IsNullOrEmpty(_error))
            _body.Children.Add(Text(_error, 13, color: Critical));

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 8, 0, 0) };
        var saveBtn = Push(existing != null ? "Update Repository" : "Link Repository", () => _ = SaveAsync(), accent: true);
        saveBtn.IsEnabled = !_saving;
        AutomationProperties.SetAutomationId(saveBtn, "coding.repo.save");
        actions.Children.Add(saveBtn);

        if (existing != null)
        {
            var unlinkBtn = Push("Unlink Repository", () => _ = UnlinkAsync());
            unlinkBtn.Foreground = Critical;
            unlinkBtn.IsEnabled = !_saving;
            AutomationProperties.SetAutomationId(unlinkBtn, "coding.repo.unlink");
            actions.Children.Add(unlinkBtn);
        }
        _body.Children.Add(actions);
    }

    private async Task SaveAsync()
    {
        _error = null;
        var defaultRoot = RepoPathHelpers.NormalizeFolderPath(_project.RootFolder);
        var path = RepoPathHelpers.NormalizeFolderPath(_useOtherFolder ? _otherFolder : defaultRoot);
        if (string.IsNullOrEmpty(path))
        {
            _error = "Enter the repository folder path.";
            Render();
            return;
        }

        string? normalizedPublic = null;
        if (_usePublicMirror)
        {
            normalizedPublic = RepoPathHelpers.NormalizePublicRepo(_publicRepo);
            if (normalizedPublic == null)
            {
                _error = "Enter a valid GitHub repository as owner/repo (for example, acme/widget).";
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
                Mirror: _usePublicMirror);
            await _store.LinkRepoAsync(repo);
            _notice.Show("Repository linked.");
            CodingFeature.OpenProjectPipeline(_project);
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
        Render();
        try
        {
            await _store.UnlinkRepoAsync(_project.ProjectKey);
            _notice.Show("Repository unlinked.");
            LoadFromStore();
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
