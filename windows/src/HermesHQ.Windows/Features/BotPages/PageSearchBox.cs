using Hermes.Core.BotPages;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace HermesHQ.Features.BotPages;

/// The search every list page shares (the Mac's bar magnifier, `PageBarCapsule.search`, which unfolds a field over the
/// list): a field on the page's bar that filters as you type. Any list page can adopt it:
///
///     var search = new PageSearchBox("Search Profiles");
///     search.QueryChanged += q => { query = q; Draw(); };
///     public override IEnumerable<UIElement> Bar() => [search];   // a Screen's bar, or any panel
///     search.FocusOn(page);   // Ctrl+F puts the caret in it
///
/// and filter with `Hermes.Core.BotPages.ListSearch.Filter`, showing `Kit.SearchMiss(query)` when nothing matches.
/// Esc clears it; Return raises `Submitted` (open the first row). `IsAvailable = false` dims it while there is
/// nothing to search (the Mac keeps the magnifier on the bar, dimmed, rather than hiding it).
public sealed partial class PageSearchBox : UserControl
{
    public event Action<string>? QueryChanged;
    public event Action<string>? Submitted;
    private readonly AutoSuggestBox _box;

    public string Query => _box.Text ?? "";
    public bool IsSearching => ListSearch.IsSearching(Query);

    public PageSearchBox(string placeholder = ListSearch.Placeholder, double width = 220)
    {
        _box = new AutoSuggestBox { PlaceholderText = placeholder, QueryIcon = new SymbolIcon(Symbol.Find), Width = width };
        Content = _box;
        VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetName(_box, placeholder);
        string last = "";
        _box.TextChanged += (_, _) =>
        {
            if (Query == last) return;
            last = Query;
            QueryChanged?.Invoke(Query);
        };
        _box.QuerySubmitted += (_, _) => Submitted?.Invoke(Query);
        _box.KeyDown += (_, e) =>
        {
            if (e.Key != VirtualKey.Escape || Query.Length == 0) return;
            e.Handled = true;
            Clear();
        };
    }

    /// Dimmed while there is nothing to search.
    public bool IsAvailable
    {
        get => _box.IsEnabled;
        set => _box.IsEnabled = value;
    }

    public void Clear() => _box.Text = "";

    public void FocusBox() => _box.Focus(FocusState.Keyboard);

    /// Ctrl+F on `page` puts the caret in this box.
    public void FocusOn(UIElement page)
    {
        var a = new KeyboardAccelerator { Key = VirtualKey.F, Modifiers = VirtualKeyModifiers.Control };
        a.Invoked += (_, e) => { e.Handled = true; if (_box.IsEnabled) FocusBox(); };
        page.KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;
        page.KeyboardAccelerators.Add(a);
    }
}
