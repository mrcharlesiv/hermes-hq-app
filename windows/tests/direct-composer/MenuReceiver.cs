// Only the direct page's actual registration, Opening handler and selector callback are linked. No WinUI, I/O or model switch.
enum Visibility { Visible, Collapsed }
class MenuFlyoutItem
{
    public string Text = "", KeyboardAcceleratorTextOverride = "";
    public object? Icon;
    public bool IsEnabled = true;
    public Visibility Visibility = Visibility.Visible;
    public event Action<object?, object?>? Click;
    public void Request() => Click?.Invoke(this, null);
}
class MenuFlyoutSeparator : MenuFlyoutItem;
class Menu
{
    public List<MenuFlyoutItem> Items = [];
    public event Action<object?, object?>? Opening;
    public void ObserveOpening() => Opening?.Invoke(this, null);
}
class Page { public object XamlRoot = new(); }
class RoutedEventArgs;
class Context { public Page Page = new(); public Menu MoreMenu = new(); public object Composer = new(); public Action? OpenModelPicker; }
class Chat(bool offline)
{
    public bool Offline => offline;
    public void WarmUp() { }
    public object? Options => null;
    public (string Id, string Provider) Current() => ("test", "fixture");
    public object MenuInput() => this;
}
static class Ui { public static object Glyph(string _) => new(); }
class ModelMenuModel { public string Subtitle = ""; public static ModelMenuModel Build(object _) => new(); }
static class PromptLibrary { public const string Title = "Prompts"; }
static class ModelsDialog
{
    public static List<(object Root, Chat Chat, Route Owner, string? Query)> Requested = [];
    public static Task ShowAsync(object root, Chat chat, Route owner, string? query)
    { Requested.Add((root, chat, owner, query)); return Task.CompletedTask; }
}
class ComposerServices
{
    public static ComposerServices Prompts = new(), ModelsDev = new();
    public string? MenuSubtitle => null;
    public object? Stored() => null;
}
static class UsageLimitsModel { public const string Title = "Usage"; public static string? MenuSubtitle(object? o, string p) => null; }
static class ModelPricesModel { public const string Title = "Prices"; public static string? MenuSubtitle(object? o, string id, string p, object? s) => null; }
static class PromptsDialog { public static Task ShowAsync(params object[] _) => throw new InvalidOperationException(); }
static class UsageDialog { public static Task ShowAsync(params object[] _) => throw new InvalidOperationException(); }
static class PricesDialog { public static Task ShowAsync(params object[] _) => throw new InvalidOperationException(); }
partial class Route(bool offline)
{
    readonly Context _ctx = new(); readonly Chat _c = new(offline);
    Context? _context => _ctx;
    MenuFlyoutItem? _modelItem, _promptsItem, _usageItem, _pricesItem;
    readonly MenuFlyoutItem MoreButton = new() { Visibility = Visibility.Collapsed };
    Menu MoreMenu => _ctx.MoreMenu;
    public static void Main()
    {
        foreach (var offline in new[] { false, true })
        {
            var r = new Route(offline); r.Install(); r.MoreMenu.ObserveOpening();
            var item = r.MoreMenu.Items.Single(i => i.Text == "Model");
            if (!item.IsEnabled || item.Visibility != Visibility.Visible || r.MoreButton.Visibility != Visibility.Visible)
                throw new Exception("No available Model in the header menu");
            ModelsDialog.Requested.Clear(); item.Request(); r.ComposerModel_Click(r, new());
            if (ModelsDialog.Requested.Count != 2 || ModelsDialog.Requested.Any(p => p != (r._ctx.Page.XamlRoot, r._c, r, null)))
                throw new Exception("Wrong picker target");
        }
        Console.WriteLine("Chat Actions > Model and chip, online and offline; both routes: same picker, current chat, null query; no model selected");
    }
}
