using System.Text.Json.Nodes;
using Hermes.Core.Net;

namespace Hermes.Core.Tests;

/// [authority] A gateway-hosted Hermes answers /api/ws from its session authority, which admits a `prompt.submit` only
/// with a request id; the plain sidecar refuses that key. Ports Tests/Gateways/AuthorityWireTests.swift (93f984bb1)
/// case for case.
public class AuthorityWireTests
{
    private static JsonObject Send() => new() { ["session_id"] = "rt-1", ["text"] = "Hi", ["profile"] = "default" };

    private static bool Same(JsonNode? a, JsonNode? b) => JsonNode.DeepEquals(a, b);

    [Fact]
    public void AuthoritySendGetsARequestId()
    {
        var output = AuthorityWire.Adapt("prompt.submit", Send(), authority: true).Params;
        Assert.False(string.IsNullOrEmpty(output.Str("submission_id")));
        Assert.Equal("Hi", output.Str("text"));
        Assert.Equal("rt-1", output.Str("session_id"));
    }

    [Fact]
    public void ASendKeepsItsOwnIdThroughRetries()
    {
        var parameters = Send();
        parameters["submission_id"] = AuthorityWire.SubmissionId("local-user-3-42");
        var first = AuthorityWire.Adapt("prompt.submit", parameters, authority: true).Params;
        var again = AuthorityWire.Adapt("prompt.submit", parameters, authority: true).Params;
        Assert.Equal(first.Str("submission_id"), again.Str("submission_id"));
        Assert.Equal("hq-local-user-3-42", first.Str("submission_id"));
    }

    [Fact]
    public void SidecarNeverSeesTheId()
    {
        var parameters = Send();
        parameters["submission_id"] = AuthorityWire.SubmissionId("local-user-3-42");
        var output = AuthorityWire.Adapt("prompt.submit", parameters, authority: false).Params;
        Assert.Null(output.Get("submission_id"));
        Assert.True(Same(output, Send()));
        // The caller's own copy keeps its id for the next retry.
        Assert.Equal("hq-local-user-3-42", parameters.Str("submission_id"));
    }

    [Fact]
    public void OtherCallsPassUntouched()
    {
        var parameters = new JsonObject { ["session_id"] = "rt-1" };
        var output = AuthorityWire.Adapt("session.resume", parameters, authority: true, generation: 3);
        Assert.Equal("session.resume", output.Method);
        Assert.True(Same(output.Params, parameters));
        var plain = AuthorityWire.Adapt("session.activate", parameters, authority: false, generation: 3);
        Assert.Equal("session.activate", plain.Method);
        Assert.True(Same(plain.Params, parameters));
        // The plain sidecar's frame is the caller's own object, unchanged (byte-identical on the wire).
        Assert.Same(parameters, plain.Params);
        var send = Send();
        Assert.Same(send, AuthorityWire.Adapt("prompt.submit", send, authority: false).Params);
    }

    [Fact]
    public void ActivateIsAResumeOnTheAuthority()
    {
        var parameters = new JsonObject { ["session_id"] = "rt-1", ["cols"] = 96, ["omit_messages"] = true, ["profile"] = "default" };
        var output = AuthorityWire.Adapt("session.activate", parameters, authority: true, generation: 2);
        Assert.Equal("session.resume", output.Method);
        Assert.True(Same(output.Params, parameters));
    }

    [Fact]
    public void TurnControlsNameTheRunningTurn()
    {
        foreach (var method in new[] { "session.redirect", "session.interrupt" })
        {
            var output = AuthorityWire.Adapt(method, new JsonObject { ["session_id"] = "rt-1", ["text"] = "also this" }, authority: true, generation: 4);
            Assert.Equal(method, output.Method);
            Assert.Equal(4, AuthorityWire.Generation(output.Params));
            // Unknown turn: nothing invented; the sidecar never gets the key.
            Assert.Null(AuthorityWire.Adapt(method, new JsonObject { ["session_id"] = "rt-1" }, authority: true).Params.Get("execution_generation"));
            Assert.Null(AuthorityWire.Adapt(method, new JsonObject { ["session_id"] = "rt-1" }, authority: false, generation: 4).Params.Get("execution_generation"));
        }
    }

    [Fact]
    public void ApprovalAnswerUsesTheAuthorityShape()
    {
        JsonObject Params() => new() { ["session_id"] = "rt-1", ["choice"] = "once", ["all"] = false, ["request_id"] = "p-9", ["profile"] = "default" };
        var output = AuthorityWire.Adapt("approval.respond", Params(), authority: true, generation: 1).Params;
        Assert.True(Same(output, new JsonObject
        {
            ["session_id"] = "rt-1", ["choice"] = "once", ["prompt_id"] = "p-9", ["profile"] = "default", ["execution_generation"] = 1,
        }));
        Assert.True(Same(AuthorityWire.Adapt("approval.respond", Params(), authority: false, generation: 1).Params, Params()));
    }

    [Fact]
    public void CreateUsesTheAuthorityShape()
    {
        JsonObject Chat() => new() { ["profile"] = "default", ["source"] = "desktop", ["cwd"] = "/w", ["cwd_explicit"] = true };
        Assert.True(Same(AuthorityWire.Adapt("session.create", Chat(), authority: true).Params,
            new JsonObject { ["profile"] = "default", ["source"] = "gui", ["cwd"] = "/w", ["cwd_explicit"] = true }));
        Assert.True(Same(AuthorityWire.Adapt("session.create", Chat(), authority: false).Params, Chat()));
        var member = new JsonObject
        {
            ["profile"] = "ops", ["title"] = "Group: r · t", ["hidden"] = true, ["room_plumbing"] = true,
            ["follow_profile_config"] = true, ["idempotency_key"] = "k-1",
        };
        Assert.True(Same(AuthorityWire.Adapt("session.create", member, authority: true).Params, new JsonObject
        {
            ["profile"] = "ops", ["title"] = "Group: r · t", ["hidden"] = true, ["follow_profile_config"] = true,
            ["request_id"] = "k-1", ["source"] = "gui",
        }));
        // A terminal width the create contract doesn't take.
        var wide = Chat();
        wide["cols"] = 96;
        Assert.Null(AuthorityWire.Adapt("session.create", wide, authority: true).Params.Get("cols"));
    }

    [Fact]
    public void FramesCarryTheirTurn()
    {
        var frame = JsonNode.Parse("""{"jsonrpc":"2.0","method":"event","params":{"authority_epoch":4,"execution_generation":1,"type":"message.start","session_id":"rt-1","payload":{}}}""");
        Assert.Equal(1, AuthorityWire.Generation(frame.Get("params")));
        var replayed = new JsonObject { ["type"] = "agent.step", ["session_id"] = "rt-1", ["execution_generation"] = 2 };
        Assert.Equal(2, AuthorityWire.Generation(replayed));
        Assert.Null(AuthorityWire.Generation(new JsonObject { ["execution_generation"] = true }));
        Assert.Null(AuthorityWire.Generation(new JsonObject { ["type"] = "message.start" }));
    }
}
