using System.Text.RegularExpressions;
using System.Xml.Linq;
using Hermes.Core.Shell;
using Xunit;

namespace Hermes.Core.Tests;

/// [WIN-55] The accessibility audit: what counts as a name Narrator can't read, the Mac's labels by id, the walk's
/// report, and a source check that every icon-only button in the app carries AutomationProperties.Name.
public class A11yAuditTests
{
    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("\uE712")]            // Segoe Fluent's More
    [InlineData("\uE74A ")]
    [InlineData("⋯")]
    [InlineData("+")]
    [InlineData("×")]
    [InlineData("› ›")]
    [InlineData("&#xE712;")]
    [InlineData("\\uE74A")]
    [InlineData("U+E713")]
    [InlineData("0xE710")]
    public void UnreadableNames(string? name) => Assert.True(A11yAuditWalkProof.IsUnreadable(name));

    [Theory]
    [InlineData("Send")]
    [InlineData("Chat Actions")]
    [InlineData("Hide Sidebar")]
    [InlineData("3")]
    [InlineData("⋯ More")]
    [InlineData("Café")]
    [InlineData("New Chat in This Project")]
    public void ReadableNames(string name) => Assert.False(A11yAuditWalkProof.IsUnreadable(name));

    [Fact]
    public void ASubclassIsHeldToItsBasesRule()
    {
        Assert.Equal("Button", A11yAuditWalkProof.AuditedAs(["DropDownButton", "Button", "ButtonBase", "ContentControl"]));
        Assert.Equal("MenuFlyoutItem", A11yAuditWalkProof.AuditedAs(["ToggleMenuFlyoutItem", "MenuFlyoutItem", "MenuFlyoutItemBase"]));
        Assert.Equal("AppBarButton", A11yAuditWalkProof.AuditedAs(["AppBarButton", "Button"]));
        Assert.Null(A11yAuditWalkProof.AuditedAs(["TextBlock", "FrameworkElement"]));
    }

    [Fact]
    public void TheMacsLabelsByIdAreItsExactWords()
    {
        Assert.Equal("Send", A11yAuditWalkProof.MacLabel("chat.send"));
        Assert.Equal("Attach", A11yAuditWalkProof.MacLabel("composer.attach"));
        Assert.Equal("Chat Actions", A11yAuditWalkProof.MacLabel("chat.more"));
        Assert.Equal("Inspector", A11yAuditWalkProof.MacLabel("chat.inspector"));
        Assert.Equal("Filter and Sort", A11yAuditWalkProof.MacLabel("sessions.filter"));
        Assert.Equal("Hide Sidebar", A11yAuditWalkProof.MacLabel("shell.fold"));
        Assert.Equal("Add to Sidebar", A11yAuditWalkProof.MacLabel("shell.add"));
        Assert.Equal("Goal Actions", A11yAuditWalkProof.MacLabel("shelf.goal.more"));
        Assert.Null(A11yAuditWalkProof.MacLabel("no.such.control"));
        Assert.All(A11yAuditWalkProof.MacLabels.Values, l => Assert.False(A11yAuditWalkProof.IsUnreadable(l)));
    }

    [Fact]
    public void TheReportListsEachPageCountAndEveryFinding()
    {
        var visited = A11yAuditWalkProof.Pages;
        Assert.Null(A11yAuditWalkProof.Report([], visited));
        A11yFinding[] found = [new("Chats", "Button", "MoreButton"), new("Chats", "Button", ""), new("Settings", "TextBox", "settings.search")];
        var counts = A11yAuditWalkProof.Counts(found, visited);
        Assert.Equal(2, counts["Chats"]);
        Assert.Equal(1, counts["Settings"]);
        Assert.Equal(0, counts["Kanban"]);
        Assert.Equal(visited.Length, counts.Count);
        var report = A11yAuditWalkProof.Report(found, visited)!;
        Assert.StartsWith("3 controls have no name Narrator can read (Chats 2, Sessions 0,", report);
        Assert.Contains("  Chats · Button · MoreButton", report);
        Assert.Contains("  Chats · Button · (no id)", report);
        Assert.Contains("  Settings · TextBox · settings.search", report);
    }

    // ------------------------------------------------------------------ the app's source

    private static string WindowsDir()
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        return dir;
    }

    [Fact]
    public void ChatComposerHasAnExplicitNameIndependentOfItsPlaceholder()
    {
        var page = XDocument.Load(Path.Combine(WindowsDir(), "src", "HermesHQ.Windows", "Pages", "ChatPage.xaml"));
        var editor = Assert.Single(page.Descendants(), e => (string?)e.Attribute("AutomationProperties.AutomationId") == "chat.composer");
        XNamespace x = "http://schemas.microsoft.com/winfx/2006/xaml";
        Assert.Equal(page.Root!.GetDefaultNamespace() + "TextBox", editor.Name);
        Assert.Equal("Composer", (string?)editor.Attribute(x + "Name"));
        // ComposerView.swift names the editor itself; the placeholder can include the chat title.
        Assert.Equal("Message", (string?)editor.Attribute("AutomationProperties.Name"));
    }

    private static readonly Regex XamlButton = new(@"<(Button|ToggleButton|AppBarButton|DropDownButton|HyperlinkButton|SplitButton)(?=[\s/>])([^>]*?)(/?)>", RegexOptions.Singleline);

    /// XAML buttons whose only content is an icon and that carry no AutomationProperties.Name ("file: x:Name or tooltip").
    internal static List<string> UnnamedXamlIconButtons(string app)
    {
        var found = new List<string>();
        foreach (var path in Directory.EnumerateFiles(app, "*.xaml", SearchOption.AllDirectories))
        {
            var xaml = File.ReadAllText(path);
            foreach (Match m in XamlButton.Matches(xaml))
            {
                var attrs = m.Groups[2].Value;
                if (attrs.Contains("AutomationProperties.Name=", StringComparison.Ordinal) || attrs.Contains(" Content=", StringComparison.Ordinal)) continue;
                if (m.Groups[3].Value == "/") continue;
                var close = xaml.IndexOf("</" + m.Groups[1].Value + ">", m.Index, StringComparison.Ordinal);
                var body = close < 0 ? "" : xaml[(m.Index + m.Length)..close];
                body = Regex.Replace(body, @"<(\w+)\.(Flyout|KeyboardAccelerators|ContextFlyout)>.*?</\1\.\2>", "", RegexOptions.Singleline);
                if (body.Contains("<TextBlock", StringComparison.Ordinal) || !body.Contains("Icon", StringComparison.Ordinal)) continue;
                var name = Regex.Match(attrs, "x:Name=\"([^\"]+)\"") is { Success: true } n ? n.Groups[1].Value
                    : Regex.Match(attrs, "ToolTip=\"([^\"]+)\"") is { Success: true } t ? t.Groups[1].Value : "?";
                found.Add($"{Path.GetFileName(path)}: {name}");
            }
        }
        return found;
    }

    private static readonly Regex CsIconButton = new(
        @"(_?\w+)\s*=\s*new\s*(?:Button|ToggleButton|AppBarButton|DropDownButton|HyperlinkButton|SplitButton)?\s*(?:\(\))?\s*\{[^;{}]*?Content\s*=\s*new\s+(?:FontIcon|SymbolIcon)\b");
    private static readonly Regex CsIconContent = new(@"(_?\w+)\.Content\s*=\s*new\s+(?:FontIcon|SymbolIcon)\b");

    /// C# buttons made with an icon as their content whose file never names them (SetName) ("file: variable").
    internal static List<string> UnnamedCsIconButtons(string app)
    {
        var found = new List<string>();
        foreach (var path in Directory.EnumerateFiles(app, "*.cs", SearchOption.AllDirectories))
        {
            if (Path.GetFileName(path).StartsWith("ProofWalks", StringComparison.Ordinal)) continue;
            var cs = File.ReadAllText(path);
            foreach (var m in CsIconButton.Matches(cs).Concat(CsIconContent.Matches(cs)))
            {
                var v = m.Groups[1].Value;
                // AutomationProperties.SetName, or MessageView's own AutomationName(element, name) helper around it.
                if (Regex.IsMatch(cs, @"(?:AutomationProperties\.SetName|\bAutomationName)\(\s*" + Regex.Escape(v) + @"\b")) continue;
                found.Add($"{Path.GetFileName(path)}: {v}");
            }
        }
        return found;
    }

    [Fact]
    public void EveryIconOnlyButtonInTheAppHasAName()
    {
        var app = Path.Combine(WindowsDir(), "src", "HermesHQ.Windows");
        var unnamed = UnnamedXamlIconButtons(app).Concat(UnnamedCsIconButtons(app)).ToList();
        Assert.True(unnamed.Count == 0, "icon-only buttons with no AutomationProperties.Name:\n" + string.Join("\n", unnamed));
    }

    [Fact]
    public void TheSourceCheckSeesAnUnnamedIconButton()
    {
        var dir = Path.Combine(Path.GetTempPath(), "a11y-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        try
        {
            File.WriteAllText(Path.Combine(dir, "Page.xaml"),
                "<Button x:Name=\"Bare\" ToolTipService.ToolTip=\"More\"><FontIcon Glyph=\"&#xE712;\" /><Button.Flyout><MenuFlyout /></Button.Flyout></Button>\n" +
                "<Button x:Name=\"Named\" AutomationProperties.Name=\"More\"><FontIcon Glyph=\"&#xE712;\" /></Button>\n" +
                "<Button x:Name=\"Words\"><StackPanel><FontIcon Glyph=\"&#xE8F2;\" /><TextBlock Text=\"Chats\" /></StackPanel></Button>");
            File.WriteAllText(Path.Combine(dir, "Page.cs"),
                "var more = new Button { Content = new FontIcon { Glyph = \"\\uE712\" } };\n" +
                "var close = new Button { Content = new FontIcon { Glyph = \"\\uE711\" } };\nAutomationProperties.SetName(close, \"Close\");");
            Assert.Equal(["Page.xaml: Bare"], UnnamedXamlIconButtons(dir));
            Assert.Equal(["Page.cs: more"], UnnamedCsIconButtons(dir));
        }
        finally { Directory.Delete(dir, true); }
    }

    [Fact]
    public void TheWalkIsAskedForWithItsTwoPictures()
    {
        var dir = WindowsDir();
        var yml = File.ReadAllText(Path.Combine(dir, "ci", "windows.yml"));
        var line = yml.Split('\n').Single(l => l.Contains("tag = \"a11y-audit\"", StringComparison.Ordinal));
        Assert.Contains("walks = @(\"a11y-audit\")", line);
        Assert.Contains("\"a11y-audit-chats\"", line);
        Assert.Contains("\"a11y-audit-settings\"", line);
        var port = Regex.Match(line, "\"--port\",\"(\\d+)\"").Groups[1].Value;
        Assert.Single(yml.Split('\n'), l => l.Contains($"\"--port\",\"{port}\"", StringComparison.Ordinal));
        var walk = File.ReadAllText(Path.Combine(dir, "src", "HermesHQ.Windows", "Services", "ProofWalks.A11yAudit.cs"));
        Assert.Contains("Automation.NamedWalks[\"a11y-audit\"]", walk);
        var registry = File.ReadAllText(Path.Combine(dir, "src", "HermesHQ.Windows", "Services", "ProofWalks.cs"));
        Assert.Contains("RegisterA11yAuditWalks();", registry);
    }
}
