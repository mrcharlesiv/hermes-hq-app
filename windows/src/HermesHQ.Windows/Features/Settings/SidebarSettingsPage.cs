using Hermes.Core.Bots;
using Hermes.Core.Shell;
using HermesHQ.Features.Bots;
using HermesHQ.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Features.Settings;

/// [taborder] Settings › Appearance › Sidebar, the Mac's TabOrderPage (93f984bb1): the places in the sidebar in its
/// order, each with a switch, dragged to move them (the Mac's list is always editing); what other features put on the
/// page (Jobs Badge); Add to Sidebar, the places that can join them; Use Default Tabs while the order is not the default.
/// A change is saved to the sidebar's own file at once and the sidebar follows (`SidebarLayout.Changed`), as the
/// sidebar's right-click edits do the other way round. Rules and words: Hermes.Core `SidebarLayout`, `SidebarPage`.
/// Not here, as the Mac has them: Bots in Sidebar and the Kanban or Artifacts picker (no Windows surface).
internal static class SidebarSettingsPage
{
    private static readonly FileDeviceStore Disk = new(ListsHub.DevicePath);

    private static List<PlaceInfo> Infos() => Places.All.Select(p => new PlaceInfo(p.Id, p.Title, p.Section == Places.Tools)).ToList();

    public static FrameworkElement Make()
    {
        var root = (StackPanel)Kit.Page();
        Draw(root);
        // The sidebar's own menu edits the same list: this page follows it while it is open.
        void Follow() => root.DispatcherQueue.TryEnqueue(() => { if (root.IsLoaded && !HermesHQ.Services.AppShutdown.Stopping) Draw(root); });
        root.Loaded += (_, _) => { SidebarLayout.Changed -= Follow; SidebarLayout.Changed += Follow; Draw(root); };
        root.Unloaded += (_, _) => SidebarLayout.Changed -= Follow;
        return root;
    }

    private static void Save(SidebarLayout layout)
    {
        layout.Save(Disk);
        SidebarLayout.NotifyChanged();
    }

    private static void Draw(StackPanel root)
    {
        root.Children.Clear();
        var layout = SidebarLayout.Load(Disk);
        var infos = Infos();
        var shown = layout.Shown(infos);
        // Sidebar: the shown places, a switch each (off only while another place is left) and dragged to reorder.
        root.Children.Add(ShownSection(layout, infos, shown));
        // Jobs Badge (JobsSidebarBadge), between them as the Mac's jobsBadgeSection.
        foreach (var make in SettingsHooks.Sidebar) if (make() is { } part) root.Children.Add(part);
        var add = layout.AddRows(infos);
        if (add.Count > 0)
            root.Children.Add(Kit.Section(SidebarPage.AddHeader, SidebarPage.AddFooter,
                [.. add.Select(p => (UIElement?)PlaceRow(p.Id, on: false, enabled: true, on => { if (on) { layout.Add(p.Id, infos); Save(layout); } }))]));
        if (!layout.IsDefault(infos))
        {
            var reset = Kit.Push(SidebarPage.UseDefault, () => { layout.UseDefault(); Save(layout); });
            AutomationProperties.SetAutomationId(reset, SidebarPage.UseDefaultId);
            root.Children.Add(Kit.Card(new Border { Padding = new Thickness(14, 8, 14, 8), Child = reset }));
        }
    }

    private static StackPanel ShownSection(SidebarLayout layout, List<PlaceInfo> infos, List<string> shown)
    {
        var list = new ListView
        {
            SelectionMode = ListViewSelectionMode.None, CanDragItems = true, CanReorderItems = true, AllowDrop = true,
            IsItemClickEnabled = false, Padding = new Thickness(0),
        };
        AutomationProperties.SetName(list, SidebarPage.ShownHeader);
        foreach (var id in shown)
        {
            var row = PlaceRow(id, on: true, enabled: layout.CanRemove(id, infos), on => { if (!on) { layout.Remove(id, infos); Save(layout); } });
            // The keyboard's way to move a row (the drag's): Move Up / Move Down, as the sidebar's own right-click.
            var menu = new MenuFlyout();
            menu.Items.Add(MenuItem("Move Up", layout.CanMove(id, -1, infos), () => { layout.Move(id, -1, infos); Save(layout); }));
            menu.Items.Add(MenuItem("Move Down", layout.CanMove(id, 1, infos), () => { layout.Move(id, 1, infos); Save(layout); }));
            var item = new ListViewItem { Content = row, Tag = id, Padding = new Thickness(0), HorizontalContentAlignment = HorizontalAlignment.Stretch, ContextFlyout = menu };
            AutomationProperties.SetName(item, Places.Get(id).Title);
            list.Items.Add(item);
        }
        list.DragItemsCompleted += (_, _) =>
        {
            var order = list.Items.OfType<ListViewItem>().Select(i => (string)i.Tag).ToList();
            if (order.SequenceEqual(layout.Shown(infos))) return;
            layout.Arrange(order, infos);
            Save(layout);
        };
        return Kit.Section(SidebarPage.ShownHeader, SidebarPage.ShownFooter(shown), list);
    }

    private static MenuFlyoutItem MenuItem(string text, bool enabled, Action run)
    {
        var item = new MenuFlyoutItem { Text = text, IsEnabled = enabled };
        item.Click += (_, _) => run();
        return item;
    }

    /// A place's row: its glyph and name (as the sidebar draws them) and its switch (`row(_:pages:isOn:enabled:)`).
    private static Grid PlaceRow(string id, bool on, bool enabled, Action<bool> set)
    {
        var place = Places.Get(id);
        return Kit.Toggle(place.Glyph, place.Title, null, on, set, SidebarPage.RowAutomationId(id), enabled);
    }
}
