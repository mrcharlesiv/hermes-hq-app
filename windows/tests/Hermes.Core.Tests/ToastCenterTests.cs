using System.Xml.Linq;
using Hermes.Core.Notifications;
using Hermes.Core.Settings;
using Hermes.Core.Shell;

namespace Hermes.Core.Tests;

/// These tests exercise decisions with values only. No desktop, account, process launch, network or answer handler.
public class ToastCenterTests
{
    private static Dictionary<string, string> Environment() => new()
    {
        ["GITHUB_ACTIONS"] = "true", ["RUNNER_ENVIRONMENT"] = "github-hosted", ["RUNNER_OS"] = "Windows",
        ["GITHUB_EVENT_NAME"] = "push", ["GITHUB_REF"] = "refs/heads/feat/windows",
        ["GITHUB_REPOSITORY"] = "mrcharlesiv/hermes-hq-windows", ["HQW_PRIVATE_MIRROR"] = "true",
        ["GITHUB_WORKFLOW_REF"] = "mrcharlesiv/hermes-hq-windows/.github/workflows/windows.yml@refs/heads/feat/windows",
        ["HQW_DESKTOP_PROOF"] = "1", ["GITHUB_RUN_ID"] = "72", ["GITHUB_RUN_ATTEMPT"] = "3",
    };
    private static DesktopProof Proof => DesktopProof.ForRunner(k => Environment().GetValueOrDefault(k), true)!;
    private static LocalToast Reply(DesktopProof p, ReplyPhase phase) =>
        new LocalAlerts(() => NotificationPrefs.Default, () => true, _ => false, () => true, () => true)
        .ObserveTurnEnd("fixture-runtime", 1, false, p.Body(phase), new(new(ToastsWalkProof.Sender, "", "", true), DesktopProof.Chat, DesktopProof.Profile)).Toast!;

    [Fact]
    public void RunnerRequiresEveryExactFactIncludingOptInAndPlatform()
    {
        var env = Environment();
        DesktopProof? Gate(bool windows = true) => DesktopProof.ForRunner(k => env.GetValueOrDefault(k), windows);
        Assert.Equal("72.3", Gate()!.Stamp);
        Assert.Equal("Hermes HQ test 72.3", DesktopProof.AppNameFor(Gate()!.Stamp));
        foreach (var value in new[] { null, "hello", "72.3 ", "72.0", "72.3.4" }) Assert.Null(DesktopProof.AppNameFor(value));
        Assert.Null(Gate(false));
        foreach (var (key, value) in Environment())
        {
            env.Remove(key); Assert.Null(Gate());
            env[key] = value + " "; Assert.Null(Gate());
            env[key] = value;
        }
        foreach (var bad in new[] { "0", "-1", "01", "3.2", "٣", "123456789012345678901", "1\n" })
        {
            env["GITHUB_RUN_ATTEMPT"] = bad; Assert.Null(Gate());
        }
    }

    [Fact]
    public void ProbeAcceptsOnlyTheTwoLiteralPhases()
    {
        Assert.Equal(ReplyPhase.Warm, DesktopProof.Phase(["warm"]));
        Assert.Equal(ReplyPhase.Cold, DesktopProof.Phase(["cold"]));
        string[][] rejected = [[], [""], ["Warm"], ["cold "] , ["123", "32"], ["--text", "hello"], ["--button", "sample"], ["warm", "cold"], ["warm", "--list"]];
        foreach (var args in rejected) Assert.Null(DesktopProof.Phase(args));
    }

    [Fact]
    public void SensitiveActionsOnlyProduceTwoExactInMemoryRecords()
    {
        var sample = RecordedToastActions.Sample();
        RecordedToastActions.Verify(sample);
        var receiver = new RecordedToastActions();
        foreach (var button in sample.Buttons) receiver.Record(button);
        var chat = new NotificationTarget(DesktopProof.Chat, DesktopProof.Profile);
        Assert.Equal([new("Approve Once", "approve", new(chat, "fixture-request", true)), new("Deny", "deny", new(chat, "fixture-request", false))], receiver.Entries);
        Assert.False(Proof.MayShow(sample));
        Assert.Null(Proof.NavigationPhase(sample));
        Assert.Throws<InvalidOperationException>(() => RecordedToastActions.Verify(sample with { Buttons = [sample.Buttons[1], sample.Buttons[0]] }));
        Assert.Throws<InvalidOperationException>(() => RecordedToastActions.Verify(sample with { Buttons = [sample.Buttons[0], sample.Buttons[0]] }));
        Assert.Throws<InvalidOperationException>(() => RecordedToastActions.Verify(sample with { Arguments = [.. sample.Arguments, new("action", "approve")] }));
        var first = sample.Buttons[0];
        Assert.Throws<InvalidOperationException>(() => receiver.Record(first with { Title = "Deny" }));
        Assert.Equal(2, receiver.Entries.Count);
        foreach (var key in first.Arguments.Select(p => p.Key))
        {
            var changed = first.Arguments.Select(p => p.Key == key ? new(p.Key, "other") : p).ToArray();
            Assert.Throws<InvalidOperationException>(() => RecordedToastActions.Verify(sample with { Buttons = [first with { Arguments = changed }, sample.Buttons[1]] }));
        }
        Assert.Throws<InvalidOperationException>(() => receiver.Record(first with { Arguments = [.. first.Arguments, new("extra", "")] }));
    }

    [Theory]
    [InlineData(ReplyPhase.Warm)]
    [InlineData(ReplyPhase.Cold)]
    public void OnlyThisRunsPlainReplyCanBePostedAndActivated(ReplyPhase phase)
    {
        var p = Proof;
        var reply = Reply(p, phase);
        var other = phase == ReplyPhase.Warm ? ReplyPhase.Cold : ReplyPhase.Warm;
        Assert.True(p.MayShow(reply)); Assert.Equal(phase, p.NavigationPhase(reply));
        Assert.Null(p.NavigationPhase(reply with { Body = ToastsWalkProof.ReplyAwayText }));
        Assert.False(p.MayShow(reply with { Body = reply.Body + "!" }));
        Assert.False(p.MayShow(reply with { Group = "other" }));
        Assert.False(p.MayShow(reply with { Buttons = RecordedToastActions.Sample().Buttons }));
        Assert.False(p.MayShow(reply with { Arguments = [.. reply.Arguments, new("request", "")] }));
        var args = ToastsWalkProof.AsActivated(reply.Arguments).Append(new(DesktopProof.Marker, p.Id(phase))).ToArray();
        Assert.True(DesktopProof.IsActivation(args, phase, p.Stamp, out var stamp)); Assert.Equal(p.Stamp, stamp);
        var wire = NotificationArguments.Encode(args);
        Assert.True(DesktopProof.IsWireActivation(wire, phase, p.Stamp));
        foreach (var bad in new[] { ";" + wire, wire + ";", wire + ";" + args[0].Key + "=other", wire + ";action", wire + ";extra=", "" })
            Assert.False(DesktopProof.IsWireActivation(bad, phase, p.Stamp));
        Assert.False(DesktopProof.IsActivation(args, other, p.Stamp, out _));
        Assert.False(DesktopProof.IsActivation(args, phase, "72.4", out _));
        foreach (var (k, _) in args)
        {
            Assert.False(DesktopProof.IsActivation(args.Where(a => a.Key != k), phase, p.Stamp, out _));
            Assert.False(DesktopProof.IsActivation(args.Select(a => a.Key == k ? new(k, "elsewhere") : a), phase, p.Stamp, out _));
        }
        foreach (var k in new[] { "action", "request", "another", "stored", DesktopProof.Marker })
            Assert.False(DesktopProof.IsActivation([.. args, new(k, "")], phase, p.Stamp, out _));
        var xml = new XElement("toast", new XAttribute("launch", NotificationArguments.Encode(args)),
            new XElement("visual", new XElement("binding", new XAttribute("template", "ToastGeneric"),
                new XElement("text", reply.Title), new XElement("text", reply.Body)))).ToString();
        Assert.True(p.IsReplyPayload(xml, phase)); Assert.False(p.IsReplyPayload(xml, other));
        foreach (var unsafeXml in new[] { xml.Replace("<visual>", "<actions/><visual>"), xml.Replace("<visual>", "<visual><input/>"),
            xml.Replace("<toast ", "<toast activationType=\"protocol\" "), xml.Replace("<text>", "<text hint-inputId=\"x\">"),
            xml.Replace(reply.Body, reply.Body + "!"), xml.Replace("ToastGeneric", "other"), xml.Replace(";kind=", ";action=approve;kind="),
            xml.Replace("</binding>", "<text>other</text></binding>"), "<toast>", "" })
            Assert.False(p.IsReplyPayload(unsafeXml, phase));
    }

    [Theory]
    [InlineData(ReplyPhase.Warm)]
    [InlineData(ReplyPhase.Cold)]
    public void VerifiedHarmlessRouteOpensOnceEvenIfTheShellIsNotReadyYet(ReplyPhase phase)
    {
        var p = Proof;
        var args = ToastsWalkProof.AsActivated(Reply(p, phase).Arguments).Append(new(DesktopProof.Marker, p.Id(phase))).ToArray();
        var raw = NotificationArguments.Encode(args);
        Assert.Null(DesktopProof.ReplyTarget(raw, [.. args, new("request", "anything")], phase, p.Stamp));
        Assert.Null(DesktopProof.ReplyTarget(raw + ";action=other", args, phase, p.Stamp));
        var target = Assert.IsType<NotificationTarget>(DesktopProof.ReplyTarget(raw, args, phase, p.Stamp));
        var opened = new List<NotificationTarget>();
        var navigator = new NotificationOpener();
        if (phase == ReplyPhase.Warm) navigator.Ready(opened.Add);
        navigator.Tapped(target);
        if (phase == ReplyPhase.Cold) { Assert.Empty(opened); navigator.Ready(opened.Add); }
        Assert.Equal(new NotificationTarget(DesktopProof.Chat, DesktopProof.Profile), Assert.Single(opened));
        Assert.Null(navigator.TakePending());
    }

    [Fact]
    public void LocalInputRequiresALiteralLoopbackFixtureAndAnOrdinaryControl()
    {
        Assert.True(DesktopProof.FixtureAddress(DesktopProof.Fixture));
        foreach (var bad in new[] { null, "http://localhost:9736", DesktopProof.Fixture + "/", DesktopProof.Fixture + "?x", DesktopProof.Fixture + "@example.invalid",
            "https://127.0.0.1:9736", "http://127.0.0.1:98900", "http://127.0.0.1:22", "http://127.0.0.1:09736", "http://example.invalid:9736" })
            Assert.False(DesktopProof.FixtureAddress(bad));
        Assert.True(DesktopProof.SafeControl("chat.composer", false, false));
        Assert.True(DesktopProof.SafeControl("shortcuts.sheet", false, true));
        Assert.False(DesktopProof.SafeControl("chat.composer", true, false));
        foreach (var id in new[] { "prompt.approval", "prompt.credential", "prompt.consent", "clarify.note" })
            Assert.False(DesktopProof.SafeControl(id, false, false));
        foreach (var id in new[] { "", "other-dialog", "confirm", "new-chat-sheet-other" })
            Assert.False(DesktopProof.SafeControl(id, false, true));
    }

    private sealed class View(int groups = 1, int bodies = 1, bool hasRow = true, bool plain = true) : IReplyView<string>
    {
        public int Searches { get; private set; }
        public IReadOnlyList<string> AppGroups() => Enumerable.Repeat("this-app", groups).ToArray();
        public IReadOnlyList<string> ExactBodyTexts(string group, string body)
        {
            Assert.Equal("this-app", group); Assert.Equal(Proof.Body(ReplyPhase.Warm), body); Searches++;
            return Enumerable.Repeat("matched text", bodies).ToArray();
        }
        public string? ListItemContaining(string text, string group) { Assert.Equal("matched text", text); return hasRow ? "reply row" : null; }
        public bool IsPlainRow(string row, string title, string body) => plain && row == "reply row" && title == "Sam" && body == Proof.Body(ReplyPhase.Warm);
    }

    [Fact]
    public void AmbiguityOrAbsenceNeverSelectsTheFirstOrSearchesElsewhere()
    {
        foreach (var count in new[] { 0, 2 })
        {
            var v = new View(groups: count); Assert.Throws<ReplyGap>(() => ReplySelection.Select(v, Proof, ReplyPhase.Warm));
            Assert.Equal(0, v.Searches);
            Assert.Throws<ReplyGap>(() => ReplySelection.Select(new View(bodies: count), Proof, ReplyPhase.Warm));
        }
        Assert.Throws<ReplyGap>(() => ReplySelection.Select(new View(hasRow: false), Proof, ReplyPhase.Warm));
        Assert.Throws<ReplyGap>(() => ReplySelection.Select(new View(plain: false), Proof, ReplyPhase.Warm));
        Assert.Equal("reply row", ReplySelection.Select(new View(), Proof, ReplyPhase.Warm));
    }

    [Fact]
    public void ShellChromeIsNeverAnActionTargetAndUnfamiliarOrInteractiveContentRefusesTheRow()
    {
        var body = Proof.Body(ReplyPhase.Warm);
        var title = new ReplyChild("Text", "Sam", "", true, false, false);
        var text = title with { Name = body };
        bool Accept(params ReplyChild[] children) => ReplySelection.Plain(children, "Sam", body);
        Assert.True(Accept(title, text));
        Assert.True(Accept(title, text, new("Button", "Dismiss notification", "DismissButton", true, false, true)));
        Assert.False(Accept(title)); Assert.False(Accept(text, text)); Assert.False(Accept(title, text, text));
        foreach (var other in new[] { title with { Name = "Approve Once" }, title with { Role = "Button", Name = "Approve Once" },
            title with { Role = "Button", Id = "DismissButton", Name = "other" }, title with { Role = "Edit" },
            title with { Role = "Pane", Name = "", Interactive = true }, title with { Password = true }, title with { Local = false } })
            Assert.False(Accept(title, text, other));
    }
}
