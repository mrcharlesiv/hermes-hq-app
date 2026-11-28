using Hermes.Core.Settings;
using HermesHQ.Features.Settings;
using HermesHQ.Features.Transcript;
using Microsoft.UI.System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.System;
using Windows.UI.ViewManagement;
using Xunit;

namespace SettingsColumn.Tests;

// Exercise the linked product handlers, not a second implementation of navigation or selection. All input and
// notification sources are inert. The paint calculation is a layout contract for the SDK, not a raster measurement.
public sealed class SettingsColumnWindowTests : IDisposable
{
    private SettingsWindow Window => SettingsWindow.Showing!;
    private SettingsPage Page => Window.Page!;
    private Grid Root => (Grid)Page.Content!;
    private ScrollViewer Column => (ScrollViewer)Root.Children[0];
    private StackPanel Stack => (StackPanel)Column.Content!;
    private TextBox Search => (TextBox)((Grid)Stack.Children[0]).Children[0];
    private ListView List => Stack.Children.OfType<ListView>().Single();
    private Button Gateway => Stack.Children.OfType<Button>().Single();
    private Border Divider => Root.Children.OfType<Border>().Single();
    private Border Form => (Border)((Grid)Root.Children[^1]).Children.OfType<ScrollViewer>().Single().Content!;
    private static int Index(SettingsCategory c) => Array.IndexOf(SettingsCategories.All, c);
    private ListViewItem Item(SettingsCategory c) => (ListViewItem)List.Items[Index(c)];

    public SettingsColumnWindowTests()
    {
        FilePreferences.Shared = new();
        ThemeService.OsRevision = 0;
        ThemeService.Dark = false;
        ThemeService.Set(ThemeState.Default, false);
        foreach (var name in new[] { "Light", "Dark", "HighContrast" })
            Application.Current.Resources.ThemeDictionaries[name] = new ResourceDictionary { ["HQSettingsMarkBrush"] = new Brush(name + ":mark") };
        Open();
    }

    private void Open() { Assert.True(SettingsWindow.Open(null)); Column.Load(); }
    public void Dispose()
    {
        if (SettingsWindow.Showing == null) return;
        Column.Unload(); Page.Unload(); Window.Close();
        Assert.Null(SettingsWindow.Showing);
    }

    private void Secondary(SettingsCategory c)
    {
        // WinUI OnItemSecondaryInteractionGesture: ItemClick for container.Content, focus, then toggle IsSelected
        // as it stands *after* ItemClick. This differs from just replaying ItemClick or assigning SelectedIndex.
        List.Pick(Item(c).Content!); List.FocusArrow(Index(c));
        List.SelectedIndex = List.SelectedIndex == Index(c) ? -1 : Index(c);
    }

    [Theory]
    [InlineData(SettingsCategory.About, false)] [InlineData(SettingsCategory.Appearance, false)]
    [InlineData(SettingsCategory.About, true)] [InlineData(SettingsCategory.Appearance, true)]
    public void SecondaryGestureKeepsShownCategorySelected(SettingsCategory target, bool queuedText)
    {
        Search.QueueEvents = queuedText;
        Page.ShowCategory(SettingsCategory.About);
        int before = SettingsPanes.CategoriesBuilt;
        Secondary(target);
        var shown = Form.Child;
        Page.DispatcherQueue.Drain(); Search.Drain();
        Assert.Equal(target.Title(), Page.PageTitle); Assert.Equal(Page.PageTitle, Page.MarkedCategory);
        Assert.Same(Item(target), List.FocusedItem); Assert.Same(shown, Form.Child);
        Assert.Equal(target == SettingsCategory.About ? 0 : 1, SettingsPanes.CategoriesBuilt - before);
        List.FocusArrow(Index(SettingsCategory.Gateway));
        Assert.Same(Item(SettingsCategory.Gateway), List.FocusedItem); Assert.Equal(target.Title(), Page.MarkedCategory);
    }

    [Theory]
    [InlineData(SettingsCategory.About, false)] [InlineData(SettingsCategory.Appearance, false)]
    [InlineData(SettingsCategory.About, true)] [InlineData(SettingsCategory.Appearance, true)]
    public void LateSelectionRepairDoesNotUndoANewerFocusMove(SettingsCategory target, bool outsideList)
    {
        Page.ShowCategory(SettingsCategory.About); Secondary(target);
        Control next = outsideList ? Search : Item(SettingsCategory.Gateway);
        if (outsideList) Search.Focus(FocusState.Keyboard); else List.FocusArrow(Index(SettingsCategory.Gateway));
        Page.DispatcherQueue.Drain();
        Assert.Equal(FocusState.Keyboard, next.FocusState);
        Assert.Equal(target.Title(), Page.MarkedCategory); Assert.Equal(target.Title(), Page.PageTitle);
    }

    [Theory]
    [InlineData("search")] [InlineData("gateway")] [InlineData("other category")] [InlineData("detail")]
    public void LateRepairRespectsTheCurrentRoute(string next)
    {
        Page.ShowCategory(SettingsCategory.About); Secondary(SettingsCategory.About);
        switch (next)
        {
            case "search": Search.Text = "theme"; break;
            case "gateway": Gateway.InertClick(); break;
            case "other category": List.SelectedIndex = Index(SettingsCategory.Gateway); break;
            case "detail": Page.Open("licenses"); break;
        }
        var first = Form.Child;
        Page.DispatcherQueue.Drain();
        var (title, mark) = next switch
        {
            "search" => ("Search Results", null), "gateway" => ("Gateway", null),
            "detail" => (LicenseNotices.PageTitle, "About"), _ => ("Hermes", "Hermes"),
        };
        Assert.Equal(title, Page.PageTitle); Assert.Equal(mark, Page.MarkedCategory); Assert.Same(first, Form.Child);
    }

    [Theory]
    [InlineData(false, "selection only")] [InlineData(false, "click first")] [InlineData(false, "selection first")] [InlineData(false, "toggle")]
    [InlineData(true, "selection only")] [InlineData(true, "click first")] [InlineData(true, "selection first")] [InlineData(true, "toggle")]
    public void ChoosingFromSearchInstallsOneCategoryForm(bool queuedText, string order)
    {
        const SettingsCategory c = SettingsCategory.Appearance;
        Page.ShowCategory(SettingsCategory.About); Search.QueueEvents = queuedText;
        Search.Text = "licence"; Search.Drain(); Assert.Null(Page.MarkedCategory);
        int before = SettingsPanes.CategoriesBuilt;
        if (order == "toggle") Secondary(c);
        else
        {
            if (order == "click first") List.Pick(Item(c).Content!);
            List.SelectedIndex = Index(c);
            if (order == "selection first") List.Pick(Item(c).Content!);
        }
        var installed = Form.Child;
        Search.Drain(); Page.DispatcherQueue.Drain();
        Assert.Equal(1, SettingsPanes.CategoriesBuilt - before); Assert.Same(installed, Form.Child);
        Assert.False(Page.Searching); Assert.Equal(c.Title(), Page.PageTitle); Assert.Equal(c.Title(), Page.MarkedCategory);
    }

    [Theory]
    [InlineData(false)] [InlineData(true)]
    public void LaterTypingIsNotMistakenForTheProgrammaticClear(bool userClearsAgain)
    {
        Search.QueueEvents = true; Search.Text = "theme"; Search.Drain();
        List.Pick(Item(SettingsCategory.Appearance).Content!);
        var category = Form.Child;
        Search.Text = "licence"; // The prior clear notification has NOT yet run.
        if (userClearsAgain) Search.Text = "";
        Search.Drain(); Page.DispatcherQueue.Drain();
        if (userClearsAgain) { Assert.Same(category, Form.Child); Assert.Equal("Appearance", Page.MarkedCategory); return; }
        Assert.Equal("Search Results", Page.PageTitle); Assert.Null(Page.MarkedCategory); Assert.NotSame(category, Form.Child);
        Assert.True(Search.Key(VirtualKey.Enter)); var license = Form.Child; Search.Drain();
        Assert.Same(license, Form.Child); Assert.Equal(LicenseNotices.PageTitle, Page.PageTitle); Assert.Equal("About", Page.MarkedCategory);
        Page.Back(); Assert.Equal("about", ((Border)Form.Child!).Tag); Page.Back(); Assert.Equal(SettingsCategory.About, ((Border)Form.Child!).Tag);
        Assert.False(Page.CanGoBack); Dispose(); Open(); Assert.Equal("About", Page.MarkedCategory);
    }

    [Theory]
    [InlineData(false)] [InlineData(true)]
    public void EscapeAndRowOnlySearchRestoreThePage(bool queued)
    {
        Page.ShowCategory(SettingsCategory.Appearance); Search.QueueEvents = queued;
        Search.Text = "desktop look"; Search.Drain(); Assert.Null(Page.MarkedCategory);
        Kit.FormAtLastRowLookup = null;
        Page.Open("row:desktop-look", fromSearch: true);
        ((Grid)Root.Children[^1]).Children.OfType<ScrollViewer>().Single().UpdateLayout(); // before the queued TextChanged
        Search.Drain(); Assert.Same(Form.Child, Kit.FormAtLastRowLookup);
        Assert.Equal(SettingsCategory.Appearance, ((Border)Form.Child!).Tag); Assert.Equal("Appearance", Page.MarkedCategory);
        Gateway.InertClick(); Search.Text = "licence"; Search.Drain(); Assert.Null(Page.MarkedCategory);
        Assert.True(Search.Key(VirtualKey.Escape)); Search.Drain();
        Assert.Equal("Gateway", Page.PageTitle); Assert.Null(Page.MarkedCategory); Assert.NotNull(((Grid)Gateway.Content!).Background);
    }

    [Theory]
    [InlineData(false, false)] [InlineData(false, true)] [InlineData(true, false)] [InlineData(true, true)]
    public void OsPaletteChangesInPlaceAndUnsubscribesOnClose(bool dark, bool gatewayMarked)
    {
        ThemeService.Dark = dark; ThemeService.Set(ThemeState.Default, false);
        Page.ShowCategory(SettingsCategory.About); if (gatewayMarked) Gateway.InertClick();
        List.FocusArrow(Index(SettingsCategory.Gateway));
        var focused = List.FocusedItem; var form = Form.Child;
        var theme = Assert.IsType<ThemeSettings>(ThemeSettings.Last); var colours = Assert.IsType<UISettings>(UISettings.Last);
        Assert.Equal(Window.AppWindow.Id, theme.WindowId); Assert.Equal(1, theme.Listeners); Assert.Equal(1, colours.Listeners);
        void Check(bool hc, int revision)
        {
            var row = (Grid)(gatewayMarked ? Gateway.Content! : Item(SettingsCategory.About).Content!);
            var label = gatewayMarked ? (TextBlock)((StackPanel)row.Children[1]).Children[0] : (TextBlock)row.Children[1];
            var icon = (FontIcon)row.Children[0];
            string Ink(string normal, string contrast) => hc ? $"contrast:{revision}:{contrast}" : $"{(dark ? "dark" : "light")}:{normal}";
            Assert.Equal(Ink("HQSettingsMarkBrush", "Highlight"), row.Background?.Key);
            Assert.Equal(Ink("HQLabelBrush", "HighlightText"), label.Foreground?.Key);
            Assert.Equal(Ink("HQTintTextBrush", "HighlightText"), icon.Foreground?.Key);
            Assert.Equal(hc ? ElementHighContrastAdjustment.None : ElementHighContrastAdjustment.Application, label.HighContrastAdjustment);
            if (gatewayMarked)
            {
                var address = (Grid)((StackPanel)row.Children[1]).Children[1];
                Assert.Equal(Ink("HQLabel2Brush", "HighlightText"), ((TextBlock)address.Children[0]).Foreground?.Key);
            }
            var other = (Grid)Item(SettingsCategory.Gateway).Content!;
            Assert.Null(other.Background); Assert.Equal(hc ? null : Ink("HQLabelBrush", ""), ((TextBlock)other.Children[1]).Foreground?.Key);
            Assert.Equal(Ink("HQSettingsPaneLineBrush", "WindowText"), Divider.Background?.Key);
            Assert.Equal(Ink("HQSettingsFieldBrush", "Window"), Search.Background?.Key); Assert.Equal(hc ? 1 : 0, Search.BorderThickness.Left);
            Assert.Equal(Ink("HQGroupedBrush", "Window"), Page.Background?.Key);
            Assert.True(((ListViewItem)focused!).UseSystemFocusVisuals); Assert.Same(focused, List.FocusedItem); Assert.Same(form, Form.Child);
        }
        Check(false, 0);
        // No ThemeService.Changed / ActualThemeChanged is delivered in these transitions.
        ThemeService.SystemHighContrast = true; ThemeService.OsRevision = 1; theme.Notify(); Window.DispatcherQueue.Drain(); Check(true, 1);
        ThemeService.OsRevision = 2; theme.Notify(); Window.DispatcherQueue.Drain(); Check(true, 2); // another contrast scheme
        ThemeService.OsRevision = 3; colours.Notify(); Window.DispatcherQueue.Drain(); Check(true, 3); // recolour the same scheme
        ThemeService.SystemHighContrast = false; theme.Notify(); Window.DispatcherQueue.Drain(); Check(false, 3);
        var queue = Window.DispatcherQueue; theme.Notify(); colours.Notify(); int count = ThemeService.Refreshes;
        Dispose(); Assert.Equal(0, theme.Listeners); Assert.Equal(0, colours.Listeners);
        theme.Notify(); colours.Notify(); queue.Drain(); Assert.Equal(count, ThemeService.Refreshes);
        ThemeService.SystemHighContrast = true; ThemeService.OsRevision = 4; Open();
        Assert.Equal("contrast:4:WindowText", Divider.Background?.Key); Assert.Equal(1, Search.BorderThickness.Left);
    }

    [Fact]
    public void WindowCloseDetachesEvenBeforeTheVisualTreeUnloads()
    {
        var page = Page; var column = Column; var form = Form;
        var root = (Grid)Window.Content!; var frame = root.Children.OfType<Frame>().Single();
        Assert.Equal(2, frame.GetValue(Grid.SpanDP)); Assert.Equal(SettingsWindow.CaptionHeight, ((Grid)root.Children[^1]).Height);
        Assert.Equal(0, Divider.Margin.Top); Assert.False(Divider.IsHitTestVisible);
        var width = column.Width; var visible = form.Child;
        try
        {
            Window.Close(); // do not rely on either Unloaded event firing first
            ThemeService.Set(ThemeState.Default with { UiScalePercent = 150 }, true);
            column.XamlRoot.Dpi(2); page.DispatcherQueue.Drain();
            Assert.Same(visible, form.Child); Assert.Equal(width, column.Width); Assert.Null(SettingsWindow.Showing);
        }
        finally { column.Unload(); page.Unload(); }
    }

    [Theory]
    [InlineData(false, SettingsCategory.About, false)] [InlineData(false, SettingsCategory.Appearance, false)]
    [InlineData(false, SettingsCategory.About, true)] [InlineData(false, SettingsCategory.Appearance, true)]
    [InlineData(true, SettingsCategory.About, false)] [InlineData(true, SettingsCategory.Appearance, false)]
    [InlineData(true, SettingsCategory.About, true)] [InlineData(true, SettingsCategory.Appearance, true)]
    public void StandaloneMarkSurvivesASecondSettingsHost(bool mainLeaves, SettingsCategory target, bool pointer)
    {
        var standalone = Page;
        Page.ShowCategory(SettingsCategory.About);
        var main = new Frame();
        main.Navigate(typeof(SettingsPage), new HermesHQ.Shell.PlaceArgs(null, "keys")); // the main frame's Open Keys route
        var other = (SettingsPage)main.Content!;
        try
        {
            if (mainLeaves) { other.Leaving(); other.Unload(); }
            var otherMark = other.MarkedCategory;
            var otherTitle = other.PageTitle;
            Assert.True(SettingsWindow.Open(null)); Assert.Same(standalone, Page);

            var item = Item(target);
            List.Pick(item.Content!);
            item.Focus(pointer ? FocusState.Pointer : FocusState.Keyboard);
            List.SelectedIndex = List.SelectedIndex == Index(target) ? -1 : Index(target);
            Assert.Null(Page.MarkedCategory);
            var shown = Form.Child;
            Control nextFocus = pointer ? Search : Item(SettingsCategory.Gateway);
            nextFocus.Focus(FocusState.Keyboard); // a newer Tab or arrow before the repair
            Page.DispatcherQueue.Drain();

            Assert.Equal(target.Title(), Page.MarkedCategory); Assert.Equal(target.Title(), Page.PageTitle);
            Assert.Same(item, Assert.Single(List.Items.Cast<ListViewItem>(), i => ((Grid)i.Content!).Background != null));
            Assert.Same(shown, Form.Child); Assert.Equal(FocusState.Keyboard, nextFocus.FocusState);
            Assert.Equal(otherMark, other.MarkedCategory); Assert.Equal(otherTitle, other.PageTitle);
        }
        finally { if (!mainLeaves) { other.Leaving(); other.Unload(); } }
    }

    [Theory]
    [InlineData(false, false, SettingsCategory.About)] [InlineData(false, true, SettingsCategory.About)]
    [InlineData(true, false, SettingsCategory.About)] [InlineData(true, true, SettingsCategory.About)]
    [InlineData(false, false, SettingsCategory.Appearance)] [InlineData(false, true, SettingsCategory.Appearance)]
    [InlineData(true, false, SettingsCategory.Appearance)] [InlineData(true, true, SettingsCategory.Appearance)]
    public void SelectionBeforeTheClearNotificationInstallsOneCategoryRoot(bool detail, bool escape, SettingsCategory target)
    {
        Page.ShowCategory(SettingsCategory.About);
        if (detail) Page.Open("licenses");
        Search.DispatcherQueue = Page.DispatcherQueue; Search.QueueEvents = true;
        Search.Text = "theme"; Search.Drain();
        if (escape) Assert.True(Search.Key(VirtualKey.Escape)); else Search.Text = "";
        Assert.False(Page.Searching); Assert.Equal("Search Results", Page.PageTitle); Assert.Null(Page.MarkedCategory);
        int before = SettingsPanes.CategoriesBuilt;
        List.SelectedIndex = Index(target); // SelectionItem.Select, no ItemClick
        var installed = Form.Child;
        Assert.Equal(target, Assert.IsType<Border>(installed).Tag); Assert.False(Page.CanGoBack);
        Search.Drain();
        Assert.Equal(target.Title(), Page.MarkedCategory); Assert.Equal(target.Title(), Page.PageTitle);
        Assert.Same(installed, Form.Child); Assert.Equal(before + 1, SettingsPanes.CategoriesBuilt);
    }

    [Theory]
    [InlineData(false)] [InlineData(true)]
    public void PassiveSearchClearRestoresTheDetailButNotItsKeyboardFocus(bool outsideList)
    {
        Page.Open("licenses"); Search.DispatcherQueue = Page.DispatcherQueue; Search.QueueEvents = true;
        Search.Text = "theme"; Search.Drain(); Assert.True(Search.Key(VirtualKey.Escape));
        Control focus = outsideList ? Search : Item(SettingsCategory.Gateway);
        focus.Focus(FocusState.Keyboard); Search.Drain();
        var detail = Form.Child;
        Assert.Equal("licenses", Assert.IsType<Border>(detail).Tag); Assert.True(Page.CanGoBack);
        Assert.Equal("About", Page.MarkedCategory); Assert.Equal(FocusState.Keyboard, focus.FocusState);
        List.SelectedIndex = Index(SettingsCategory.About); // a no-op on a row already marked
        Assert.Same(detail, Form.Child);
        Page.Back(); Assert.Equal("about", Assert.IsType<Border>(Form.Child).Tag);
        Page.Back(); Assert.Equal(SettingsCategory.About, Assert.IsType<Border>(Form.Child).Tag); Assert.False(Page.CanGoBack);
    }

    private static string? SavedCategory => FilePreferences.Shared.Get(SettingsCategories.LastCategoryKey);

    private static void WithMainSettings(Action<SettingsPage> exercise)
    {
        var frame = new Frame(); frame.Navigate(typeof(SettingsPage), new HermesHQ.Shell.PlaceArgs(null, "keys"));
        var other = (SettingsPage)frame.Content!;
        try { exercise(other); }
        finally { other.Leaving(); other.Unload(); }
    }

    private void AssertReopensOn(SettingsCategory expected)
    {
        Dispose(); Assert.Equal(expected.Key(), SavedCategory); // closing isn't a choice
        Open(); Assert.Equal(expected.Title(), Page.MarkedCategory); Assert.Equal(expected.Title(), Page.PageTitle);
    }

    [Theory]
    [InlineData(SettingsCategory.About, false)] [InlineData(SettingsCategory.Appearance, false)]
    [InlineData(SettingsCategory.About, true)] [InlineData(SettingsCategory.Appearance, true)]
    public void ChoosingTheVisibleRootUpdatesTheSharedPreferenceWithoutRebuilding(SettingsCategory shown, bool secondary)
    {
        Page.ShowCategory(shown);
        var form = Form.Child;
        WithMainSettings(other =>
        {
            other.ShowCategory(SettingsCategory.Gateway); Assert.Equal("gateway", SavedCategory);
            if (secondary) Secondary(shown);
            else { List.Pick(Item(shown).Content!); List.SelectedIndex = Index(shown); }
            Assert.Equal(shown.Key(), SavedCategory); // at activation, not when a repair runs or the window closes
            List.FocusArrow(Index(SettingsCategory.Chat)); Page.DispatcherQueue.Drain();
            Assert.Same(Item(SettingsCategory.Chat), List.FocusedItem); Assert.Same(form, Form.Child);
            Assert.Equal(shown.Title(), Page.MarkedCategory); Assert.False(Page.CanGoBack);
            Assert.Equal("Hermes", other.MarkedCategory);
        });
        AssertReopensOn(shown);
    }

    [Theory]
    [InlineData(false, false)] [InlineData(true, false)] [InlineData(false, true)] [InlineData(true, true)]
    public void GenuineSelectionAndPassiveRepairDoNotCompeteForTheLastChoice(bool selectBeforeRepair, bool mainChoosesAgain)
    {
        const SettingsCategory shown = SettingsCategory.About;
        Page.ShowCategory(shown);
        var form = Form.Child;
        var expected = selectBeforeRepair ? shown : SettingsCategory.Gateway;
        WithMainSettings(other =>
        {
            Secondary(shown); Assert.Null(Page.MarkedCategory); // a repair is pending
            other.ShowCategory(SettingsCategory.Gateway);
            if (selectBeforeRepair) List.SelectedIndex = Index(shown); // selection peer; no ItemClick
            Assert.Equal(expected.Key(), SavedCategory);
            if (mainChoosesAgain) { expected = SettingsCategory.Chat; other.ShowCategory(expected); }
            Search.Focus(FocusState.Keyboard); Page.DispatcherQueue.Drain();
            Assert.Equal(shown.Title(), Page.MarkedCategory); Assert.Equal(FocusState.Keyboard, Search.FocusState);
            List.SelectedIndex = Index(shown); // no-op on the now-marked row
            Assert.Same(form, Form.Child); Assert.Equal(expected.Key(), SavedCategory);
        });
        AssertReopensOn(expected);
    }

    [Fact]
    public void LateInputOnAClosedWindowCannotSaveItsOldRoot()
    {
        Page.ShowCategory(SettingsCategory.About);
        var closed = Page; var list = List; var about = Item(SettingsCategory.About); var column = Column;
        Secondary(SettingsCategory.About); Window.Close(); // Closed before Unloaded or the repair
        try
        {
            Open(); Page.ShowCategory(SettingsCategory.Gateway);
            list.Pick(about.Content!); list.SelectedIndex = Index(SettingsCategory.About); closed.DispatcherQueue.Drain();
            Assert.Equal("gateway", SavedCategory); Assert.Equal("Hermes", Page.MarkedCategory);
        }
        finally { column.Unload(); closed.Unload(); }
    }

    [Fact]
    public void ExplicitNavigationStillLetsTheSelectorFocusItsNewCategory()
    {
        Page.ShowCategory(SettingsCategory.About); List.FocusArrow(Index(SettingsCategory.Gateway));
        Page.ShowAsAsked("theme", backToIndex: true);
        Assert.Equal("Theme", Page.PageTitle); Assert.Equal("Appearance", Page.MarkedCategory);
        Assert.Same(Item(SettingsCategory.Appearance), List.FocusedItem);
    }

    [Fact]
    public void OpeningTheMainFrameAfterAGestureDoesNotStealItsFocusOrLoseTheWindowMark()
    {
        Page.ShowCategory(SettingsCategory.About); Secondary(SettingsCategory.About);
        var main = new Frame(); main.Navigate(typeof(SettingsPage), new HermesHQ.Shell.PlaceArgs(null, "keys"));
        var other = (SettingsPage)main.Content!;
        try
        {
            var field = ((Grid)((Grid)other.Content!).Children[0]).Children.OfType<TextBox>().Single();
            field.Focus(FocusState.Keyboard); Page.DispatcherQueue.Drain();
            Assert.Equal("About", Page.MarkedCategory); Assert.Equal(FocusState.Keyboard, field.FocusState);
            Assert.Null(List.FocusedItem);
        }
        finally { other.Leaving(); other.Unload(); }
    }

    [Fact]
    public void AnOlderRepairCannotPreselectTheRowWhileSearchResultsAreStillVisible()
    {
        Search.DispatcherQueue = Page.DispatcherQueue;
        Page.ShowCategory(SettingsCategory.About); Secondary(SettingsCategory.About); // repair posted first
        Page.Open("licenses"); Search.Text = "theme";
        Page.DispatcherQueue.TryEnqueue(() =>
        {
            Assert.Equal("Search Results", Page.PageTitle); Assert.Null(Page.MarkedCategory);
            List.SelectedIndex = Index(SettingsCategory.About); // actual selection between repair and TextChanged
        });
        Search.QueueEvents = true; Assert.True(Search.Key(VirtualKey.Escape)); Search.Drain();
        Assert.Equal(SettingsCategory.About, Assert.IsType<Border>(Form.Child).Tag);
        Assert.Equal("About", Page.MarkedCategory); Assert.False(Page.CanGoBack);
    }

    [Theory]
    [InlineData(false)] [InlineData(true)]
    public void PendingSearchClearCannotRebuildAClosedPage(bool reopen)
    {
        var page = Page; var column = Column; var field = Search; var form = Form;
        page.Open("licenses"); field.DispatcherQueue = page.DispatcherQueue; field.QueueEvents = true;
        field.Text = "theme"; field.Drain(); var results = form.Child;
        Assert.True(field.Key(VirtualKey.Escape)); Window.Close(); // before either Unloaded or TextChanged
        try
        {
            if (reopen) { Open(); Page.ShowCategory(SettingsCategory.Gateway); }
            field.Drain(); Assert.Same(results, form.Child); Assert.Null(page.MarkedCategory);
            if (reopen) Assert.Equal("Hermes", Page.MarkedCategory);
        }
        finally { column.Unload(); page.Unload(); }
    }

    [Theory]
    [InlineData(80, 1.25)] [InlineData(100, 1)] [InlineData(125, 1.5)] [InlineData(150, 2)]
    public void TheStretchedContentPaintsTheWholeFieldWidth(int percent, double dpi)
    {
        ThemeService.Set(ThemeState.Default with { UiScalePercent = percent }, false); Column.XamlRoot.Dpi(dpi);
        Page.ShowCategory(SettingsCategory.About); List.FocusArrow(Index(SettingsCategory.Appearance));
        var item = Item(SettingsCategory.About); var row = (Grid)item.Content!;
        Assert.Equal("light:HQSettingsMarkBrush", row.Background?.Key); // the owner painted, not just the list's slot
        Assert.Equal(item.CornerRadius, row.CornerRadius); Assert.True(row.CornerRadius.Radius > 0);
        var searchBox = (Grid)Stack.Children[0];
        Assert.All(new FrameworkElement[] { Stack, searchBox, Search, List, item, row }, e => Assert.Equal(HorizontalAlignment.Stretch, e.HorizontalAlignment));
        Assert.False(List.SingleSelectionFollowsFocus); Assert.False((bool)List.Resources["ListViewItemSelectionIndicatorVisualEnabled"]);
        Assert.Equal(ListViewSelectionMode.Single, List.SelectionMode); Assert.Equal(HorizontalAlignment.Stretch, item.HorizontalContentAlignment);
        // WinUI ArrangeNewStyle -> ArrangeTemplateChild: a stretched child's width loses the container's content
        // margin (= Padding) and border, not its backplate margin. The Grid's own Padding insets words, not its fill.
        var left = Stack.Padding.Left + List.Margin.Left + List.Padding.Left + item.Margin.Left + item.Padding.Left + item.BorderThickness.Left + row.Margin.Left;
        var right = Column.Width - Stack.Padding.Right - List.Margin.Right - List.Padding.Right - item.Margin.Right - item.Padding.Right - item.BorderThickness.Right - row.Margin.Right;
        Assert.Equal(Stack.Padding.Left + searchBox.Margin.Left + Search.Margin.Left, left, 8);
        Assert.Equal(Column.Width - Stack.Padding.Right - searchBox.Margin.Right - Search.Margin.Right, right, 8);
        Assert.True(right > left); Assert.True(row.Padding.Left > 0);
        foreach (var state in new[] { "Selected", "SelectedPointerOver", "SelectedPressed", "SelectedDisabled" })
            Assert.Equal(Microsoft.UI.Colors.Transparent, ((SolidColorBrush)List.Resources["ListViewItemBackground" + state]).Color);
        Assert.DoesNotContain(List.Resources.Keys, k => k.Contains("Focus") || k is "ListViewItemBackgroundPointerOver" or "ListViewItemBackgroundPressed");
        Assert.Null(((Grid)Item(SettingsCategory.Appearance).Content!).Background); Assert.Same(Item(SettingsCategory.Appearance), List.FocusedItem);
    }
}
