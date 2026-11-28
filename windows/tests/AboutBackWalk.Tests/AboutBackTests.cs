using Hermes.Core.Settings;
using HermesHQ.Features.Settings;
using HermesHQ.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Xunit;
using Xunit.Abstractions;

namespace AboutBackWalk.Tests;

public class AboutBackTests
{
    private readonly SettingsPage page = new();
    private readonly List<string> backs = [];
    private readonly List<string> shots = [];
    private readonly ITestOutputHelper output;
    private Action? afterBack;
    private Func<string, Task>? atShot;

    public AboutBackTests(ITestOutputHelper output)
    {
        this.output = output;
        Automation.AppOnly = false;
        Automation.Desktop = new Proof("7.1");
        AppState.Client = new Client();
        App.Window = new Window();
        page.Parent = App.Window.Content;
        page.XamlRoot = page.Parent!.XamlRoot;
        SettingsPage.Current = page;
        Notice();

        ProofWalks.AfterShowing = null;
        ProofWalks.BetweenPolls = null;
        ProofWalks.OnInvoke = e =>
        {
            Assert.Same(page, e.Parent);
            Assert.Contains(e, page.Children);
            backs.Add(Assert.IsType<string>(Assert.IsType<HyperlinkButton>(e).Content));
            afterBack?.Invoke();
        };
    }

    private void Notice() => page.Show(LicenseNotices.First, "‹ Open-Source Licenses", "license.text");
    private void Licenses() => page.Show("Open-Source Licenses", "‹ About", "licenses.intro");
    private void Detail() => page.Show("About", "‹ About", "about.version", "about.detailed-log");
    private void Category() => page.Show("About", null, "settings.about", "row:discord", "row:support");
    private void OpenPopup(bool withChild = true) => page.XamlRoot!.Popups.Add(new Popup(withChild ? new FrameworkElement() : null));
    private void OnBackShow(params Action[] panes)
    {
        var next = new Queue<Action>(panes);
        afterBack = () => next.Dequeue()(); // Any extra action fails the test.
    }
    private Task Walk(bool notice = true) => ProofWalks.Run(name =>
    {
        shots.Add(name);
        return atShot?.Invoke(name) ?? Task.CompletedTask;
    }, notice);

    private static async Task Stops(Task walk, string phase, string guard)
    {
        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => walk);
        Assert.Equal($"about-back-stop/v1 phase={phase} guard={guard}", error.Message);
    }

    [Theory]
    [InlineData(false, "CurrentPage")]
    [InlineData(true, "OpenPopup")]
    public async Task OnlyOneBoundaryBreaksOnTheListAfterNoticeBack(bool popup, string guard)
    {
        afterBack = () =>
        {
            Licenses();
            if (popup) OpenPopup();
            else SettingsPage.Current = new SettingsPage();
        };
        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => Walk());
        Assert.Equal("Open-Source Licenses", page.PageTitle);
        Assert.Equal(new[] { "‹ Open-Source Licenses" }, backs);
        Assert.Empty(shots);
        output.WriteLine($"only {guard} changed; notice Backs={backs.Count}; later Backs=0; stop={error.Message}");
        Assert.Equal($"about-back-stop/v1 phase=ObserveLicenses guard={guard}", error.Message);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task ObservesTheRightAboutPagesInOrder(bool fromNotice)
    {
        if (fromNotice) OnBackShow(Licenses, Detail, Category);
        else { Detail(); OnBackShow(Category); }
        atShot = name =>
        {
            Assert.Equal("About", page.PageTitle);
            Assert.Contains(page.Children, e => e.Id == (name == "licenses-back-about-detail" ? "about.version" : "settings.about"));
            return Task.CompletedTask;
        };
        await Walk(fromNotice);
        Assert.Equal(fromNotice ? ["‹ Open-Source Licenses", "‹ About", "‹ About"] : new[] { "‹ About" }, backs);
        Assert.Equal(fromNotice ? ["licenses-back-about-detail", "licenses-back-about-category"] : new[] { "detailed-log-back-about-category" }, shots);
    }

    [Fact]
    public async Task AppOnlyPlanNeverEntersTheDesktopWalk()
    {
        Automation.AppOnly = true;
        Automation.Desktop = null;
        SettingsPage.Current = null;
        await Walk();
        Assert.Empty(backs);
        Assert.Empty(shots);
    }

    [Theory]
    [InlineData("DesktopWalk")]
    [InlineData("FixtureClient")]
    [InlineData("CurrentWindow")]
    [InlineData("CurrentPage")]
    public async Task MissingBindingIsNotAuthority(string guard)
    {
        switch (guard)
        {
            case "DesktopWalk": Automation.Desktop = null; break;
            case "FixtureClient": AppState.Client = null; break;
            case "CurrentWindow": App.Window = null; break;
            case "CurrentPage": SettingsPage.Current = null; break;
        }
        await Stops(Walk(), "ObserveNotice", guard);
        Assert.Empty(backs);
        Assert.Empty(shots);
    }

    [Theory]
    [InlineData("DesktopWalk")]
    [InlineData("FixtureAddress")]
    [InlineData("CurrentClient")]
    [InlineData("DesktopStamp")]
    [InlineData("CurrentWindow")]
    [InlineData("PageThread")]
    [InlineData("CurrentPage")]
    [InlineData("PageLoaded")]
    [InlineData("PageOwner")]
    [InlineData("XamlRoot")]
    [InlineData("Sheet")]
    [InlineData("MarkedCategory")]
    [InlineData("Search")]
    [InlineData("OpenPopup")]
    public async Task LosingOneBindingAfterSeeingTheMarkerIssuesNoBack(string guard)
    {
        ProofWalks.AfterShowing = _ =>
        {
            switch (guard)
            {
                case "DesktopWalk": Automation.AppOnly = true; break;
                case "FixtureAddress": AppState.Client!.Session.Address = "https://example.com"; break;
                case "CurrentClient": AppState.Client = new Client(); break; // Identical address, different session.
                case "DesktopStamp": Automation.Desktop = new Proof("7.2"); break;
                case "CurrentWindow": App.Window = new Window { Content = App.Window!.Content }; break;
                case "PageThread": page.DispatcherQueue.HasThreadAccess = false; break;
                case "CurrentPage": SettingsPage.Current = new SettingsPage(); break;
                case "PageLoaded": page.IsLoaded = false; break;
                case "PageOwner": page.Parent = new FrameworkElement(); break;
                case "XamlRoot": App.Window!.Content!.XamlRoot = null; break;
                case "Sheet": App.Window!.SheetShown = true; break;
                case "MarkedCategory": page.MarkedCategory = null; break;
                case "Search": page.Searching = true; break;
                case "OpenPopup": OpenPopup(); break;
            }
        };
        await Stops(Walk(), "ObserveNotice", guard);
        Assert.Empty(backs);
        Assert.Empty(shots);
    }

    [Theory]
    [InlineData("stack", "BackStack")]
    [InlineData("wrong-type", "BackControl")]
    [InlineData("unloaded", "BackControl")]
    [InlineData("zero-width", "BackControl")]
    [InlineData("zero-height", "BackControl")]
    [InlineData("duplicate", "DuplicateMarker")]
    [InlineData("owner", "BackOwner")]
    [InlineData("disabled", "BackEnabled")]
    [InlineData("uri", "BackUri")]
    [InlineData("label", "BackLabel")]
    public async Task RejectsALookalikeNoticeBack(string defect, string guard)
    {
        var back = page.Children.OfType<HyperlinkButton>().Single();
        switch (defect)
        {
            case "stack": page.CanGoBack = false; break;
            case "wrong-type": page.Children.Remove(back); page.Children.Add(new FrameworkElement("settings.back")); break;
            case "unloaded": back.IsLoaded = false; break;
            case "zero-width": back.ActualWidth = 0; break;
            case "zero-height": back.ActualHeight = 0; break;
            case "duplicate": page.Children.Add(new HyperlinkButton("‹ Open-Source Licenses") { Parent = page }); break;
            case "owner": back.Parent = new SettingsPage(); break;
            case "disabled": back.IsEnabled = false; break;
            case "uri": back.NavigateUri = new Uri("https://example.com"); break;
            case "label": back.Content = "‹ About"; break;
        }
        await Stops(Walk(), "NoticeToLicenses", guard);
        Assert.Empty(backs);
        Assert.Empty(shots);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task WaitingForAMarkerCannotAuthorizeAChangedFixture(bool changeClient)
    {
        page.Children.RemoveAll(e => e.Id == "license.text");
        ProofWalks.BetweenPolls = () =>
        {
            Assert.Empty(backs);
            Notice();
            if (changeClient) AppState.Client = new Client();
        };
        OnBackShow(Licenses, Detail, Category);
        if (changeClient)
        {
            await Stops(Walk(), "ObserveNotice", "CurrentClient");
            Assert.Empty(backs);
            Assert.Empty(shots);
        }
        else { await Walk(); Assert.Equal(3, backs.Count); }
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task NeverWaitsForAPopupToGoAway(bool withChild)
    {
        OpenPopup(withChild);
        ProofWalks.BetweenPolls = () => throw new InvalidOperationException("must not wait through a failed guard");
        await Stops(Walk(), "ObserveNotice", "OpenPopup");
        Assert.Empty(backs);
        Assert.Empty(shots);
    }

    [Theory]
    [InlineData("client", "CurrentClient")]
    [InlineData("popup", "OpenPopup")]
    [InlineData("owner", "PageOwner")]
    [InlineData("xaml-root", "XamlRoot")]
    [InlineData("category", "RouteMarker")]
    [InlineData("both", "OtherRouteMarker")]
    public async Task RechecksTheSourceAfterTheDetailFrameYields(string change, string guard)
    {
        OnBackShow(Licenses, Detail, Category);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        atShot = _ => release.Task;
        var walk = Walk();
        Assert.False(walk.IsCompleted);
        Assert.Equal("licenses-back-about-detail", Assert.Single(shots));
        switch (change)
        {
            case "client": AppState.Client = new Client(); break;
            case "popup": OpenPopup(); break;
            case "owner": page.Parent = App.Window!.Content = new FrameworkElement { XamlRoot = page.XamlRoot }; break;
            case "xaml-root": page.XamlRoot = page.Parent!.XamlRoot = new XamlRoot(); break;
            case "category": page.Show("About", "‹ About", "settings.about", "row:discord", "row:support"); break;
            case "both": page.Children.Add(new FrameworkElement("settings.about") { Parent = page }); break;
        }
        release.SetResult();
        await Stops(walk, "LicensesDetailToCategory", guard);
        Assert.Equal(new[] { "‹ Open-Source Licenses", "‹ About" }, backs); // No third Back, even with the same title and label.
        Assert.Single(shots);
    }

    [Theory]
    [InlineData("title", "RouteTitle")]
    [InlineData("marker", "RouteMarker")]
    [InlineData("logging", "DetailedLogRow")]
    public async Task UnknownAboutDetailNeverTriggersTheLoggingBack(string missing, string guard)
    {
        Detail();
        if (missing == "title") page.PageTitle = "Unrecognized fixture pane";
        else page.Children.RemoveAll(e => e.Id == (missing == "logging" ? "about.detailed-log" : "about.version"));
        if (missing == "marker")
        {
            var error = await Assert.ThrowsAsync<TimeoutException>(() => Walk(notice: false));
            Assert.Equal("waited too long for about-back-stop/v1 phase=ObserveLoggingDetail guard=RouteMarker", error.Message);
        }
        else await Stops(Walk(notice: false), "ObserveLoggingDetail", guard);
        Assert.Empty(backs);
        Assert.Empty(shots);
    }

    [Theory]
    [InlineData("version", "OtherRouteMarker")]
    [InlineData("stack", "BackStack")]
    [InlineData("back", "BackControl")]
    [InlineData("row:discord", "DiscordRow")]
    [InlineData("row:support", "SupportRow")]
    public async Task LoggingBackDoesNotCallAnIncompleteIndexACategoryFrame(string defect, string guard)
    {
        Detail();
        afterBack = () =>
        {
            Category();
            switch (defect)
            {
                case "version": page.Children.Add(new FrameworkElement("about.version") { Parent = page }); break;
                case "stack": page.CanGoBack = true; break;
                case "back": page.Children.Add(new HyperlinkButton("‹ About") { Parent = page }); break;
                default: page.Children.RemoveAll(e => e.Id == defect); break;
            }
        };
        await Stops(Walk(notice: false), "ObserveLoggingCategory", guard);
        Assert.Equal("‹ About", Assert.Single(backs));
        Assert.Empty(shots);
    }
}
