using System.Text.Json.Nodes;
using Hermes.Core.Chat;
using Hermes.Core.Model;
using Hermes.Core.Questions;
using Hermes.Core.Rpc;

namespace Hermes.Core.Tests;

public class QuestionParityAndApprovalWatchTests
{
    private static readonly QuestionCenter.Timing Fast = new()
    {
        ProbeDebounce = TimeSpan.FromMilliseconds(10),
        StaleDrop = TimeSpan.FromMilliseconds(100),
        UndeliveredAfter = TimeSpan.FromMilliseconds(50),
        ApprovalPollDelay = TimeSpan.FromMilliseconds(30),
        ApprovalPollInterval = TimeSpan.FromMilliseconds(35),
        ApprovalPollLimit = 8,
        Leaving = TimeSpan.Zero,
    };

    private static (QuestionCenter Center, FakeQuestionTransport Transport, ChatQuestions Link) Make(
        QuestionCenter.Timing? timing = null, string session = "rt1")
    {
        var transport = new FakeQuestionTransport();
        var center = new QuestionCenter(transport, timing ?? Fast);
        var link = center.Link("deploys");
        link.Observing = false;
        link.Bind(session, "stored1");
        return (center, transport, link);
    }

    private static async Task Until(Func<bool> condition, int timeoutMs = 5000)
    {
        var until = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        while (!condition() && DateTime.UtcNow < until) await Task.Delay(10);
        Assert.True(condition());
    }

    private static JsonNode PendingApproval(string requestId = "req-rm", string command = "rm -rf /tmp/scratch") =>
        JsonNode.Parse($$"""
            {"approvals":[{"request_id":"{{requestId}}","command":"{{command}}","description":"Recursive delete","allow_permanent":true}]}
            """)!;

    // ------------------------------------------------------------------ #530 approval.request & watchApproval

    [Fact]
    public async Task ApprovalRequestImmediatelyTriggersApprovalPendingReplay()
    {
        var timing = Fast with { ApprovalPollDelay = TimeSpan.FromSeconds(10) };
        var (center, transport, link) = Make(timing);
        using var centerScope = center;
        transport.Answer = (method, _) => method == "approval.pending" ? PendingApproval() : new JsonObject();

        center.Receive(new RpcEvent("approval.request", "rt1", new JsonObject(), 1));

        await Until(() => link.Prompts.Approvals.Count == 1);
        var approval = Assert.Single(link.Prompts.Approvals);
        Assert.Equal("rm -rf /tmp/scratch", approval.Command);
        Assert.Equal("queue:req-rm", approval.Id);
        Assert.Contains(transport.Calls, c => c.Method == "approval.pending" && c.Params.Str("session_id") == "rt1");
    }

    [Fact]
    public async Task NonClarifyToolStartTriggersDelayedWatchApprovalAndStopsWhenApprovalArrives()
    {
        var timing = Fast with
        {
            ApprovalPollDelay = TimeSpan.FromMilliseconds(45),
            ApprovalPollInterval = TimeSpan.FromMilliseconds(35),
            ApprovalPollLimit = 8,
        };
        var (center, transport, link) = Make(timing);
        using var centerScope = center;
        var pollCount = 0;
        transport.Answer = (method, _) =>
        {
            if (method != "approval.pending") return new JsonObject();
            var n = Interlocked.Increment(ref pollCount);
            return n >= 2 ? PendingApproval() : JsonNode.Parse("""{"approvals":[]}""")!;
        };

        center.Receive(new RpcEvent("tool.start", "rt1", JsonNode.Parse("""{"name":"terminal","tool_id":"t-1"}"""), 1));
        Assert.Equal(0, Volatile.Read(ref pollCount)); // delayed by ApprovalPollDelay

        await Until(() => link.Prompts.Approvals.Count == 1);
        Assert.Equal("rm -rf /tmp/scratch", Assert.Single(link.Prompts.Approvals).Command);
        var pollsWhenArrived = Volatile.Read(ref pollCount);
        await Task.Delay(140);
        Assert.Equal(pollsWhenArrived, Volatile.Read(ref pollCount)); // watcher stopped once approval arrived
    }

    [Fact]
    public async Task WatchApprovalStopsAtApprovalPollLimitWhenNoApprovalArrives()
    {
        var timing = Fast with
        {
            ApprovalPollDelay = TimeSpan.FromMilliseconds(15),
            ApprovalPollInterval = TimeSpan.FromMilliseconds(15),
            ApprovalPollLimit = 3,
        };
        var (center, transport, _) = Make(timing);
        using var centerScope = center;
        var pollCount = 0;
        transport.Answer = (method, _) =>
        {
            if (method == "approval.pending") Interlocked.Increment(ref pollCount);
            return JsonNode.Parse("""{"approvals":[]}""")!;
        };

        center.Receive(new RpcEvent("tool.start", "rt1", JsonNode.Parse("""{"name":"terminal","tool_id":"t-lim"}"""), 1));
        await Until(() => Volatile.Read(ref pollCount) == 3);
        await Task.Delay(120);
        Assert.Equal(3, Volatile.Read(ref pollCount));
    }

    [Theory]
    [InlineData("tool.complete")]
    [InlineData("message.complete")]
    [InlineData("error")]
    public async Task WatchApprovalCancelsCleanlyOnTerminalEvents(string stopEvent)
    {
        var timing = Fast with
        {
            ApprovalPollDelay = TimeSpan.FromMilliseconds(60),
            ApprovalPollInterval = TimeSpan.FromMilliseconds(25),
            ApprovalPollLimit = 8,
        };
        var (center, transport, _) = Make(timing);
        using var centerScope = center;
        var pollCount = 0;
        transport.Answer = (method, _) =>
        {
            if (method == "approval.pending") Interlocked.Increment(ref pollCount);
            return JsonNode.Parse("""{"approvals":[]}""")!;
        };

        center.Receive(new RpcEvent("tool.start", "rt1", JsonNode.Parse("""{"name":"terminal","tool_id":"t-stop"}"""), 1));
        center.Receive(new RpcEvent(stopEvent, "rt1", JsonNode.Parse("""{"name":"terminal"}"""), 2));

        await Task.Delay(160);
        Assert.Equal(0, Volatile.Read(ref pollCount));
    }

    [Fact]
    public async Task WatchApprovalCancelsCleanlyOnDisposeAndIsolatesSessions()
    {
        var timing = Fast with
        {
            ApprovalPollDelay = TimeSpan.FromMilliseconds(35),
            ApprovalPollInterval = TimeSpan.FromMilliseconds(25),
            ApprovalPollLimit = 8,
        };
        var transport = new FakeQuestionTransport();
        var center = new QuestionCenter(transport, timing);
        var linkA = center.Link("deploys");
        var linkB = center.Link("deploys");
        linkA.Observing = false;
        linkB.Observing = false;
        linkA.Bind("rtA", "sA");
        linkB.Bind("rtB", "sB");

        var pollsA = 0;
        var pollsB = 0;
        transport.Answer = (method, p) =>
        {
            if (method != "approval.pending") return new JsonObject();
            if (p.Str("session_id") == "rtA") Interlocked.Increment(ref pollsA);
            if (p.Str("session_id") == "rtB") Interlocked.Increment(ref pollsB);
            return JsonNode.Parse("""{"approvals":[]}""")!;
        };

        center.Receive(new RpcEvent("tool.start", "rtA", JsonNode.Parse("""{"name":"terminal"}"""), 1));
        center.Receive(new RpcEvent("tool.start", "rtB", JsonNode.Parse("""{"name":"terminal"}"""), 2));
        center.Receive(new RpcEvent("tool.complete", "rtA", JsonNode.Parse("""{"name":"terminal"}"""), 3));

        await Until(() => Volatile.Read(ref pollsB) >= 1);
        Assert.Equal(0, Volatile.Read(ref pollsA)); // session A cancelled; session B kept polling

        center.Dispose();
        var afterDispose = Volatile.Read(ref pollsB);
        await Task.Delay(120);
        Assert.Equal(afterDispose, Volatile.Read(ref pollsB));
    }

    [Fact]
    public async Task ClarifyToolStartDoesNotTriggerWatchApproval()
    {
        var timing = Fast with
        {
            ApprovalPollDelay = TimeSpan.FromMilliseconds(15),
            ApprovalPollInterval = TimeSpan.FromMilliseconds(15),
            UndeliveredAfter = TimeSpan.FromSeconds(5),
        };
        var (center, transport, _) = Make(timing);
        using var centerScope = center;
        var approvalPolls = 0;
        transport.Answer = (method, _) =>
        {
            if (method == "approval.pending") Interlocked.Increment(ref approvalPolls);
            return JsonNode.Parse("""{"approvals":[]}""")!;
        };

        center.Receive(new RpcEvent("tool.start", "rt1", JsonNode.Parse("""{"name":"clarify","tool_id":"c-1"}"""), 1));
        await Task.Delay(120);
        Assert.Equal(0, Volatile.Read(ref approvalPolls));
    }

    // ------------------------------------------------------------------ H2 ApprovalExpiry.Timeout clamp

    [Fact]
    public void ApprovalExpiryTimeoutClampsExtremeAndNonFiniteValuesWithoutThrowing()
    {
        Assert.Equal(ApprovalExpiry.DefaultTimeout, ApprovalExpiry.Timeout(null));
        Assert.Equal(ApprovalExpiry.DefaultTimeout, ApprovalExpiry.Timeout(new JsonObject()));
        Assert.Equal(ApprovalExpiry.DefaultTimeout,
            ApprovalExpiry.Timeout(new JsonObject { ["approvals"] = new JsonObject { ["timeout"] = double.NaN } }));
        Assert.Equal(ApprovalExpiry.DefaultTimeout,
            ApprovalExpiry.Timeout(new JsonObject { ["approvals"] = new JsonObject { ["timeout"] = double.PositiveInfinity } }));
        Assert.Equal(ApprovalExpiry.DefaultTimeout,
            ApprovalExpiry.Timeout(new JsonObject { ["approvals"] = new JsonObject { ["timeout"] = double.NegativeInfinity } }));
        Assert.Equal(ApprovalExpiry.DefaultTimeout,
            ApprovalExpiry.Timeout(JsonNode.Parse("""{"approvals":{"timeout":"NaN"}}""")));
        Assert.Equal(ApprovalExpiry.DefaultTimeout,
            ApprovalExpiry.Timeout(JsonNode.Parse("""{"approvals":{"timeout":"Infinity"}}""")));
        Assert.Equal(ApprovalExpiry.DefaultTimeout,
            ApprovalExpiry.Timeout(JsonNode.Parse("""{"approvals":{"timeout":-10}}""")));
        Assert.Equal(ApprovalExpiry.DefaultTimeout,
            ApprovalExpiry.Timeout(JsonNode.Parse("""{"approvals":{"timeout":-1e20}}""")));
        Assert.Equal(ApprovalExpiry.DefaultTimeout,
            ApprovalExpiry.Timeout(JsonNode.Parse("""{"approvals":{"timeout":0}}""")));

        var hugeFromJson = ApprovalExpiry.Timeout(JsonNode.Parse("""{"approvals":{"timeout":1e20}}"""));
        var hugeMaxDouble = ApprovalExpiry.Timeout(new JsonObject { ["approvals"] = new JsonObject { ["timeout"] = double.MaxValue } });
        Assert.Equal(ApprovalExpiry.MaxTimeout, hugeFromJson);
        Assert.Equal(ApprovalExpiry.MaxTimeout, hugeMaxDouble);

        // Using the clamped timeout in Label / Countdown must not throw OverflowException or ArgumentOutOfRangeException.
        var seen = DateTimeOffset.FromUnixTimeSeconds(1_700_000_000);
        var label = ApprovalExpiry.Label(seen, hugeMaxDouble, seen);
        Assert.StartsWith("Expires within ", label);
        var (countdownLabel, stale) = ApprovalExpiry.Countdown(seen, hugeMaxDouble, seen, seen);
        Assert.StartsWith("Expires within ", countdownLabel);
        Assert.False(stale);
    }

    // ------------------------------------------------------------------ VerificationCodePrompt

    [Theory]
    [InlineData("Acme sent a 6-digit verification code to your email. Please enter it so I can finish signing in.")]
    [InlineData("I’m trying to log in to Example Shop — what’s the SMS code they just sent?")]
    [InlineData("They texted a one-time code to your phone. Reply with the code to continue.")]
    [InlineData("Enter the 2FA code from your authenticator app.")]
    [InlineData("Please share the security code sent to your inbox.")]
    [InlineData("The site is asking for a login code (emailed to you).")]
    [InlineData("Can you send me the sign-in code?")]
    [InlineData("Waiting for the OTP sent to your email address.")]
    [InlineData("What is the 4-digit passcode sent via SMS?")]
    [InlineData("They emailed a code to verify your account — drop it here when it arrives.")]
    [InlineData("Please paste the authentication code so I can complete login.")]
    [InlineData("I need the confirmation code from your messages.")]
    [InlineData("What's the 6 digit code from your text?")]
    [InlineData("I'm logged in to the portal, but billing now asks for a verification code — can you share it?")]
    public void VerificationCodePromptDetectsOtpPrompts(string text)
    {
        Assert.True(VerificationCodePrompt.AsksForCode(text));
    }

    [Theory]
    [InlineData("Can you send me the source code for that file?")]
    [InlineData("The server returned HTTP status code 502. Should I retry?")]
    [InlineData("What's the zip code for the delivery address?")]
    [InlineData("Do you have a promo code or discount code to apply at checkout?")]
    [InlineData("Please share the error code from the terminal output.")]
    [InlineData("Scan the QR code on the receipt?")]
    [InlineData("Here is the hex color code: #FFAA00. Want me to change it?")]
    [InlineData("Can you share the hex code for the primary accent?")]
    [InlineData("The process exited with exit code 1. Want me to inspect the logs?")]
    [InlineData("Can you review this code snippet before I push?")]
    [InlineData("What's the country code for that phone number?")]
    [InlineData("Can you open VS Code and check the terminal output?")]
    [InlineData("Waiting for VS Code to finish indexing — want me to restart it?")]
    [InlineData("The verification code format is 6 digits.")]
    [InlineData("I entered the verification code and I'm logged in now. Here are your recent orders.")]
    [InlineData("Verification succeeded and I signed in successfully to Example Shop.")]
    [InlineData("Login complete. I pulled your receipts.")]
    [InlineData("Good morning! How can I help you today?")]
    [InlineData("")]
    public void VerificationCodePromptIgnoresNonOtpAndCompletedLogins(string text)
    {
        Assert.False(VerificationCodePrompt.AsksForCode(text));
    }

    [Fact]
    public void VerificationCodePromptNormalizeTrimsWhitespace()
    {
        Assert.Equal("482910", VerificationCodePrompt.Normalize("  482910 \r\n\t "));
        Assert.Equal("123 456", VerificationCodePrompt.Normalize("\n 123 456 \n"));
        Assert.Equal("", VerificationCodePrompt.Normalize("   \t\n  "));
        Assert.Equal("", VerificationCodePrompt.Normalize(null));
    }

    [Fact]
    public void VerificationCodePromptActiveMessageIdTracksUnansweredAssistantPrompts()
    {
        var userAsk = new ChatMessage("u1", Role.User, [new TextPart("Log into Example Shop")]);
        var botCode = new ChatMessage("a1", Role.Assistant,
            [new TextPart("Example Shop sent a verification code to your email."), new TextPart("Please reply with the code.")]);
        var systemNote = new ChatMessage("s1", Role.System, [new TextPart("Background task updated")]);
        var userReply = new ChatMessage("u2", Role.User, [new TextPart("482910")]);
        var botDone = new ChatMessage("a2", Role.Assistant,
            [new TextPart("Thanks, I entered the verification code and I'm logged in now.")]);

        Assert.Null(VerificationCodePrompt.ActiveMessageId([]));
        Assert.Null(VerificationCodePrompt.ActiveMessageId([userAsk]));
        Assert.Equal("a1", VerificationCodePrompt.ActiveMessageId([userAsk, botCode]));
        Assert.Equal("a1", VerificationCodePrompt.ActiveMessageId([userAsk, botCode, systemNote]));
        Assert.Null(VerificationCodePrompt.ActiveMessageId([userAsk, botCode, userReply]));
        Assert.Null(VerificationCodePrompt.ActiveMessageId([userAsk, botCode, userReply, botDone]));
    }
}
