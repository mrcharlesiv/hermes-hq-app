using System.Text.RegularExpressions;
using Hermes.Core.Groups;
using Hermes.Core.Shell;
using Xunit;

namespace Hermes.Core.Tests;

/// [WIN-59] The group-mentions walk's checks (Hermes.Core.Shell.GroupMentionsWalkProof) say yes to what the Mac shows
/// and name each way it can be wrong.
public class GroupMentionsWalkProofTests
{
    private static readonly GroupMentionList.Row Research = new("research", "Research", "@research", new ChatSender("research", "Research", null, "research", null));

    [Fact]
    public void TheDrawerShowsResearchAlone()
    {
        Assert.Null(GroupMentionsWalkProof.Drawer(true, [Research], ["research"]));
        Assert.NotNull(GroupMentionsWalkProof.Drawer(false, [Research], ["research"]));
        Assert.NotNull(GroupMentionsWalkProof.Drawer(true, [Research, Research with { Tag = "ivy" }], ["research", "ivy"]));
        Assert.NotNull(GroupMentionsWalkProof.Drawer(true, [Research with { Detail = "research" }], ["research"]));
        Assert.NotNull(GroupMentionsWalkProof.Drawer(true, [Research], [null]));
    }

    [Fact]
    public void DownMarksTheFirstRow()
    {
        Assert.Null(GroupMentionsWalkProof.Marked(0, [Research], 0));
        Assert.NotNull(GroupMentionsWalkProof.Marked(null, [Research], null));
        Assert.NotNull(GroupMentionsWalkProof.Marked(0, [Research], null));   // marked, but not drawn so
    }

    [Fact]
    public void APickLeavesTheTagAndClosesTheList()
    {
        Assert.Null(GroupMentionsWalkProof.AfterPick("@research ", 10, open: false));
        Assert.NotNull(GroupMentionsWalkProof.AfterPick("@Re", 3, open: false));
        Assert.NotNull(GroupMentionsWalkProof.AfterPick("@research ", 3, open: false));
        Assert.NotNull(GroupMentionsWalkProof.AfterPick("@research ", 10, open: true));
    }

    [Fact]
    public void EscClosesAndTypingReopens()
    {
        Assert.Null(GroupMentionsWalkProof.Escaped("@Re", openAfterEsc: false, openAfterTyping: true));
        Assert.NotNull(GroupMentionsWalkProof.Escaped("@Re", openAfterEsc: true, openAfterTyping: true));
        Assert.NotNull(GroupMentionsWalkProof.Escaped("@Re", openAfterEsc: false, openAfterTyping: false));
        Assert.NotNull(GroupMentionsWalkProof.Escaped("", openAfterEsc: false, openAfterTyping: true));
    }

    /// windows.yml's extra for the walk and the E2E stand-in: settings-gateway.py --group-rooms, each on a port no other
    /// stand-in in windows.yml uses; e2e.sh starts its own and hands its credentials to GroupMentionsEndToEndTests.
    [Fact]
    public void TheWalkAndItsEndToEndTestRunOnTheirOwnGroupRoomsStandIns()
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "windows", "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("repo root not found");
        var yml = File.ReadAllText(Path.Combine(dir, "windows", "ci", "windows.yml"));
        var extra = Regex.Match(yml, """@\{ tag = "group-mentions"; args = @\((?<args>[^)]*)\);(?<rest>[^\n]*)\}""");
        Assert.True(extra.Success);
        Assert.Equal(""" "windows/ci/fixtures/settings-gateway.py","--port","9835","--group-rooms" """.Trim(), extra.Groups["args"].Value);
        Assert.Contains("""walks = @("group-mentions")""", extra.Groups["rest"].Value);
        Assert.Contains("""shots = @("group-mention-drawer","group-mention-picked")""", extra.Groups["rest"].Value);
        var ports = Regex.Matches(yml, """ "--port","(\d+)" """.Trim()).Select(m => m.Groups[1].Value).ToList();
        Assert.Single(ports, p => p == "9835");
        Assert.Single(ports, p => p == "9836");
        Assert.Contains("$env:HQW_E2E_GROUPMENTIONS_CREDENTIALS", yml);
        var e2e = File.ReadAllText(Path.Combine(dir, "windows", "scripts", "e2e.sh"));
        Assert.Matches(@"settings-gateway\.py --port \$GMNPORT --group-rooms --credentials", e2e);
        Assert.Contains("export HQW_E2E_GROUPMENTIONS_CREDENTIALS=", e2e);
    }

    [Fact]
    public void TheLineAsksResearchAlone()
    {
        List<(string?, string, string)> rows = [(null, "user", GroupMentionsWalkProof.Line), ("Research", "assistant", "Research here: noted.")];
        List<(GroupActivityKind, string)> asked = [(GroupActivityKind.Queued, ""), (GroupActivityKind.Working, "research"), (GroupActivityKind.Replied, "research"), (GroupActivityKind.Settled, "")];
        Assert.Null(GroupMentionsWalkProof.Addressed(asked, rows));
        Assert.NotNull(GroupMentionsWalkProof.Addressed([.. asked, (GroupActivityKind.Working, "ivy")], rows));
        Assert.NotNull(GroupMentionsWalkProof.Addressed([(GroupActivityKind.Queued, "")], rows));
        Assert.NotNull(GroupMentionsWalkProof.Addressed(asked, [.. rows, ("Ivy", "assistant", "Ivy here: noted.")]));
        Assert.NotNull(GroupMentionsWalkProof.Addressed(asked, [(null, "user", GroupMentionsWalkProof.Line)]));
        Assert.NotNull(GroupMentionsWalkProof.Addressed(asked, [(null, "user", "@Re"), ("Research", "assistant", "Research here: noted.")]));
    }
}
