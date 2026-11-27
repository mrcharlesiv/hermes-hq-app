using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Automation;
using Hermes.Core.Shell;
using Windows.System;
using Node = System.Windows.Automation.AutomationElement;

/// Not a desktop driver. Bind only to the foreground Microsoft shell Notification Center. Inside it ask for the
/// *exact* stamped app group, and only inside that for the stamped reply. A shell layout we can't identify is a gap.
internal sealed class ShellCenter(Node center, int pid, string appName) : IReplyView<Node>
{
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(nint window, StringBuilder name, int size);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(nint window, StringBuilder name, int size);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(nint window, out int process);

    private static (nint Window, int Pid)? ForegroundCenter()
    {
        var window = GetForegroundWindow();
        var name = new StringBuilder(128);
        if (window == 0 || GetClassName(window, name, name.Capacity) == 0 || name.ToString() != "Windows.UI.Core.CoreWindow") return null;
        GetWindowThreadProcessId(window, out var processId);
        using var process = Process.GetProcessById(processId);
        var image = process.MainModule?.FileName;
        var windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        string[] hosts = [@"SystemApps\ShellExperienceHost_cw5n1h2txyewy\ShellExperienceHost.exe",
            @"SystemApps\MicrosoftWindows.Client.CBS_cw5n1h2txyewy\ShellHost.exe", @"System32\ShellHost.exe"];
        if (!hosts.Any(h => string.Equals(image, Path.Combine(windows, h), StringComparison.OrdinalIgnoreCase))) return null;
        if (GetWindowText(window, name, name.Capacity) == 0 || name.ToString() is not ("Notification Center" or "Notification center" or "Action center")) return null;
        return (window, processId);
    }

    private static async Task OpenCenterAsync()
    {
        // Documented targeted URI activation. Never use an arbitrary default association, the app picker, keys
        // or the taskbar. Some Windows versions do not register this shell URI: that is a recorded gap.
        var uri = new Uri("ms-actioncenter:");
        string[] families = ["Microsoft.Windows.ShellExperienceHost_cw5n1h2txyewy", "MicrosoftWindows.Client.CBS_cw5n1h2txyewy"];
        var handlers = new List<string>();
        foreach (var family in families)
            if (await Launcher.QueryUriSupportAsync(uri, LaunchQuerySupportType.Uri, family) == LaunchQuerySupportStatus.Available)
                handlers.Add(family);
        if (handlers.Count != 1) throw new ReplyGap("no unique Windows shell handler for Notification Center");
        if (!await Launcher.LaunchUriAsync(uri, new LauncherOptions { TargetApplicationPackageFamilyName = handlers[0], DisplayApplicationPicker = false }))
            throw new ReplyGap("Notification Center activation unavailable");
    }

    public static void OpenReply(DesktopProof proof, ReplyPhase phase)
    {
        var shell = ForegroundCenter();
        if (shell == null)
        {
            // No keystrokes or taskbar fallback. If this shell doesn't expose Notification Center, stop.
            try { OpenCenterAsync().GetAwaiter().GetResult(); }
            catch (COMException e) { throw new ReplyGap($"Notification Center activation unavailable (0x{e.HResult:X8})"); }
            var wait = Stopwatch.StartNew();
            while ((shell = ForegroundCenter()) == null && wait.Elapsed < TimeSpan.FromSeconds(8)) Thread.Sleep(200);
        }
        if (shell is not { } host) throw new ReplyGap("no verified foreground Notification Center");
        var center = AutomationElement.FromHandle(host.Window);
        if (center.Current.ProcessId != host.Pid) throw new ReplyGap("Notification Center owner changed");
        var adapter = new ShellCenter(center, host.Pid, proof.AppName);
        var body = ReplySelection.Select(adapter, proof, phase);
        if (!body.TryGetCurrentPattern(InvokePattern.Pattern, out var pattern) || pattern is not InvokePattern invoke)
            throw new ReplyGap("plain notification row does not offer Invoke");
        if (!Node.Equals(body, ReplySelection.Select(adapter, proof, phase)) || ForegroundCenter() != host)
            throw new ReplyGap("notification changed before invocation");
        invoke.Invoke();
    }

    private static Condition Eq(AutomationProperty key, object value) => new PropertyCondition(key, value);
    private List<Node> Named(Node parent, Condition role, string name) => parent.FindAll(TreeScope.Descendants,
        new AndCondition(role, Eq(Node.NameProperty, name), Eq(Node.ProcessIdProperty, pid))).Cast<Node>().ToList();
    public IReadOnlyList<Node> AppGroups() => Named(center,
        new OrCondition(Eq(Node.ControlTypeProperty, ControlType.Group), Eq(Node.ControlTypeProperty, ControlType.List)), appName);
    public IReadOnlyList<Node> ExactBodyTexts(Node group, string body) => Named(group, Eq(Node.ControlTypeProperty, ControlType.Text), body);

    public Node? ListItemContaining(Node text, Node group)
    {
        // Intersect the exact text with list items *beneath this group*, without ever following a parent
        // towards the desktop if the shell removes or reparents an element. Nested or duplicate rows refuse.
        var rows = group.FindAll(TreeScope.Descendants, new AndCondition(Eq(Node.ControlTypeProperty, ControlType.ListItem),
            Eq(Node.ProcessIdProperty, pid))).Cast<Node>().Where(r => Named(r, Eq(Node.ControlTypeProperty, ControlType.Text),
                text.Current.Name).Any(t => Node.Equals(t, text))).Take(2).ToArray();
        return rows.Length == 1 ? rows[0] : null;
    }

    public bool IsPlainRow(Node row, string title, string body)
    {
        var c = row.Current;
        if (c.ProcessId != pid || c.ControlType != ControlType.ListItem || c.IsOffscreen || !c.IsEnabled || c.IsPassword) return false;
        var children = row.FindAll(TreeScope.Descendants, Automation.ControlViewCondition).Cast<Node>().Select(n =>
        {
            var v = n.Current;
            bool interactive = v.IsKeyboardFocusable || n.GetSupportedPatterns().Any(p => p == InvokePattern.Pattern || p == ValuePattern.Pattern
                || p == TogglePattern.Pattern || p == SelectionItemPattern.Pattern || p == ExpandCollapsePattern.Pattern);
            return new ReplyChild(v.ControlType == ControlType.Text ? "Text" : v.ControlType == ControlType.Pane ? "Pane" :
                v.ControlType == ControlType.Image ? "Image" : v.ControlType == ControlType.Button ? "Button" : "Unknown",
                v.Name, v.AutomationId, v.ProcessId == pid, v.IsPassword, interactive);
        });
        return ReplySelection.Plain(children, title, body);
    }
}
