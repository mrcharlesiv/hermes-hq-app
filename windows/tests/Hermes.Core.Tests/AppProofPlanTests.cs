using System.Text.Json.Nodes;
using Hermes.Core.Shell;
using Xunit;

namespace Hermes.Core.Tests;

public class AppProofPlanTests
{
    private static JsonArray Plan() => JsonNode.Parse("""
        [
          {"tag":"composer","url":"http://127.0.0.1:9750","places":[],"walks":["open-quickly","chat-find"]},
          {"tag":"settings","url":"http://127.0.0.1:9830","places":[],"walks":["settings-file"]},
          {"tag":"groups","url":"http://127.0.0.1:9831","places":[],"walks":["group-room"]},
          {"tag":"sessions","url":"http://127.0.0.1:9771","places":[],"walks":["new-chat-here"]},
          {"tag":"keyboard-only","url":"http://127.0.0.1:9862","places":[],"walks":["keyboard-only"]},
          {"tag":"a11y-audit","url":"http://127.0.0.1:9861","places":[],"walks":["a11y-audit"]}
        ]
        """)!.AsArray();

    [Fact]
    public void AcceptsOnlyACompletePlan()
    {
        var entries = Plan();
        Assert.True(AppProofPlan.Accepts(entries));
        entries.RemoveAt(0);
        Assert.False(AppProofPlan.Accepts(entries));
        Assert.False(AppProofPlan.Accepts(null));
    }

    [Theory]
    [InlineData("tag", "\"other\"")]
    [InlineData("url", "\"http://127.0.0.1:9830/other\"")]
    [InlineData("url", "\"https://example.invalid\"")]
    [InlineData("url", "\"http://127.0.0.1:9831\"")]
    [InlineData("places", "[\"settings\"]")]
    [InlineData("walks", "[\"settings-file\",\"toasts\"]")]
    [InlineData("walks", "null")]
    public void ChangedFixtureOrBroaderWalkIsRejected(string field, string value)
    {
        var entries = Plan();
        entries[1]![field] = JsonNode.Parse(value);
        Assert.False(AppProofPlan.Accepts(entries));
    }
}
