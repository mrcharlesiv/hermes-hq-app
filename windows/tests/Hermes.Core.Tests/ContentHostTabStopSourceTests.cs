using System.Text.RegularExpressions;
using Xunit;

namespace Hermes.Core.Tests;

/// A WinUI ContentControl is a tab stop unless told otherwise, so a ContentControl used only to hold other content
/// takes a Tab of its own: CI run 45016548914's keyboard-only walk landed on the chat's empty card hosts (767×0, no
/// focus visual) and the sidebar's gateway line host. The Mac's key loop never stops on a container. Every
/// ContentControl in the app says IsTabStop, false unless it is a deliberate stop (the Tasks row host, which draws the
/// system's focus ring and answers Enter and Space).
public class ContentHostTabStopSourceTests
{
    private static readonly Regex CsHost = new(@"(?:new ContentControl|ContentControl\??\s+\w+\s*=\s*new\(\))\s*\{(.*?)\}\s*;", RegexOptions.Singleline);
    private static readonly Regex XamlHost = new(@"<ContentControl(?=[\s/>])([^>]*)>", RegexOptions.Singleline);

    internal static List<string> HostsWithoutTabStop(string file, string source)
    {
        var found = new List<string>();
        var hosts = file.EndsWith(".xaml", StringComparison.OrdinalIgnoreCase) ? XamlHost : CsHost;
        foreach (Match m in hosts.Matches(source))
            if (!m.Groups[1].Value.Contains("IsTabStop", StringComparison.Ordinal))
                found.Add($"{file}:{source[..m.Index].Count(c => c == '\n') + 1}");
        return found;
    }

    [Fact]
    public void TheRuleCatchesAHostWithoutIsTabStop()
    {
        Assert.Single(HostsWithoutTabStop("a.cs", "var h = new ContentControl { HorizontalContentAlignment = x };"));
        Assert.Empty(HostsWithoutTabStop("a.cs", "var h = new ContentControl { IsTabStop = false, HorizontalContentAlignment = x };"));
        Assert.Single(HostsWithoutTabStop("a.cs", "private readonly ContentControl _host = new() { HorizontalContentAlignment = x };"));
        Assert.Empty(HostsWithoutTabStop("a.cs", "private readonly ContentControl _host = new() { IsTabStop = false, HorizontalContentAlignment = x };"));
        Assert.Single(HostsWithoutTabStop("a.xaml", "<ContentControl x:Name=\"Dock\" />"));
        Assert.Empty(HostsWithoutTabStop("a.xaml", "<ContentControl IsTabStop=\"False\" x:Name=\"Dock\" />"));
    }

    [Fact]
    public void EveryContentControlSaysWhetherItIsATabStop()
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        var app = Path.Combine(dir, "src", "HermesHQ.Windows");
        var found = Directory.EnumerateFiles(app, "*.*", SearchOption.AllDirectories)
            .Where(p => p.EndsWith(".cs", StringComparison.Ordinal) || p.EndsWith(".xaml", StringComparison.Ordinal))
            .Where(p => !p.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}", StringComparison.Ordinal))
            .SelectMany(p => HostsWithoutTabStop(Path.GetRelativePath(app, p), File.ReadAllText(p)))
            .ToList();
        Assert.True(found.Count == 0, "ContentControl with no IsTabStop (a container the keyboard would stop on):\n" + string.Join("\n", found));
    }
}
