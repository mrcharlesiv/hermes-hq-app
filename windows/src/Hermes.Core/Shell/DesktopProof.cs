using System.Xml;
using System.Xml.Linq;
using Hermes.Core.Notifications;

namespace Hermes.Core.Shell;

public enum ReplyPhase { Warm, Cold }

/// Authority for the full CI walk, not an alternate sign-in or an elevation mechanism. The non-secret run/attempt
/// distinguishes this run's two notifications from older lookalikes. No caller-supplied message, route or executable.
public sealed class DesktopProof
{
    public const string Fixture = "http://127.0.0.1:9736";
    public const string Chat = "20260929_120000_aabbcc02";
    public const string Profile = "sam";
    public const string Marker = "hqTestReply";
    public string Stamp { get; }
    public string AppName => AppNameFor(Stamp)!;
    // Display name only, not the Windows identity. Keep this identical when the shell starts the same executable.
    public static string? AppNameFor(string? stamp) => stamp?.Split('.') is [var run, var attempt] && Number(run) && Number(attempt)
        ? "Hermes HQ test " + stamp : null;
    private DesktopProof(string stamp) => Stamp = stamp;

    public static DesktopProof? ForRunner(Func<string, string?> env, bool windows) =>
        windows && env("GITHUB_ACTIONS") == "true" && env("RUNNER_ENVIRONMENT") == "github-hosted" && env("RUNNER_OS") == "Windows"
        && env("GITHUB_EVENT_NAME") == "push" && env("GITHUB_REF") == "refs/heads/feat/windows"
        && env("GITHUB_REPOSITORY") == "mrcharlesiv/hermes-hq-windows" && env("HQW_PRIVATE_MIRROR") == "true"
        && env("GITHUB_WORKFLOW_REF") == "mrcharlesiv/hermes-hq-windows/.github/workflows/windows.yml@refs/heads/feat/windows"
        && env("HQW_DESKTOP_PROOF") == "1" && Number(env("GITHUB_RUN_ID")) && Number(env("GITHUB_RUN_ATTEMPT"))
        ? new(env("GITHUB_RUN_ID") + "." + env("GITHUB_RUN_ATTEMPT")) : null;

    private static bool Number(string? s) => s is { Length: > 0 and <= 20 } && s[0] != '0' && s.All(char.IsAsciiDigit);
    // Never normalize a caller's string into an acceptable address (userinfo, trailing path, query, alias, etc.).
    public static bool FixtureAddress(string? url) => Uri.TryCreate(url, UriKind.Absolute, out var value)
        && value.Port is >= 9700 and < 9900 && url == $"http://127.0.0.1:{value.Port}";

    public static bool SafeControl(string id, bool password, bool dialog) => !password
        && !id.StartsWith("prompt.", StringComparison.Ordinal) && id is not ("clarify.note" or "clarify.answerNow")
        && (!dialog || id is "shortcuts.sheet" or "new-chat-sheet" or "group-info" or "group-bots-picker" or "group-settings" or "table.sheet");

    public static ReplyPhase? Phase(string[] args) => args switch { ["warm"] => ReplyPhase.Warm, ["cold"] => ReplyPhase.Cold, _ => null };
    public string Id(ReplyPhase phase) => $"{phase.ToString().ToLowerInvariant()}:{Stamp}";
    public string Body(ReplyPhase phase) => (phase == ReplyPhase.Warm ? ToastsWalkProof.ReplyText : ToastsWalkProof.ColdText) + " HQ test " + Stamp;
    public NotificationCopy Copy(ReplyPhase phase) => new(ToastsWalkProof.Sender, "", Body(phase));

    private static bool Route(IEnumerable<KeyValuePair<string, string>> args, string kind, string? marker)
    {
        // Reject (don't normalize away) duplicate keys, empty/unknown/action/request arguments, wrong sessions or profiles.
        var expected = new Dictionary<string, string> { ["session"] = Chat, ["stored"] = Chat, ["kind"] = kind, ["profile"] = Profile };
        if (marker != null) expected.Add(Marker, marker);
        foreach (var (k, v) in args) if (!expected.Remove(k, out var value) || v != value) return false;
        return expected.Count == 0;
    }

    public bool MayShow(LocalToast t) => t.Buttons.Count == 0 && t.Title == ToastsWalkProof.Sender && t.Subtitle == ""
        && t.Group == LocalToast.Key(Chat) && t.Tag == LocalToast.Key(t.Id)
        && t.Arguments.Count(a => a is { Key: "request", Value: "" }) == 1
        && Route(t.Arguments.Where(a => a is not { Key: "request", Value: "" }), t.Kind, null)
        && (t.Kind == "message.complete" && (t.Body == Body(ReplyPhase.Warm) || t.Body == Body(ReplyPhase.Cold) || t.Body == ToastsWalkProof.ReplyAwayText)
            || t.Kind == "turnError" && t.Body == ToastsWalkProof.Failure.Body);

    public ReplyPhase? NavigationPhase(LocalToast t) => MayShow(t)
        ? t.Body == Body(ReplyPhase.Warm) ? ReplyPhase.Warm : t.Body == Body(ReplyPhase.Cold) ? ReplyPhase.Cold : null : null;

    /// A marked cold activation can arrive from the shell without the CI parent's environment. The marker grants
    /// nothing: only the complete buttonless fixture-chat route is valid, with no request or action of any kind.
    public static bool IsActivation(IEnumerable<KeyValuePair<string, string>> args, ReplyPhase phase, string expectedStamp, out string stamp)
    {
        var pairs = args.ToList();
        var marker = pairs.FirstOrDefault(p => p.Key == Marker).Value;
        var prefix = phase.ToString().ToLowerInvariant() + ":";
        stamp = "";
        if (marker == null || !marker.StartsWith(prefix, StringComparison.Ordinal)) return false;
        var actual = marker[prefix.Length..];
        if (actual.Split('.') is not [var run, var attempt] || !Number(run) || !Number(attempt)
            || actual != expectedStamp || !Route(pairs, "message.complete", marker)) return false;
        stamp = actual;
        return true;
    }

    public static bool IsWireActivation(string? raw, ReplyPhase phase, string stamp) => raw is { Length: > 0 and <= 1024 }
        && raw.Split(';').All(p => p.IndexOf('=') > 0 && p.IndexOf('=') == p.LastIndexOf('=') && !p.EndsWith('='))
        && IsActivation(NotificationArguments.Decode(raw), phase, stamp, out _);

    // Return only a chat target, never an action or a request. Check both SDK forms before any route is queued.
    public static NotificationTarget? ReplyTarget(string? raw, IEnumerable<KeyValuePair<string, string>> args, ReplyPhase phase, string stamp) =>
        IsWireActivation(raw, phase, stamp) && IsActivation(args, phase, stamp, out _) ? new(Chat, Profile) : null;

    /// The app's own SDK history must give us one matching tag/group (checked by caller) with just the expected
    /// plain launch and text. An action, input, protocol/background activation or a partial match is not evidence.
    public bool IsReplyPayload(string? xml, ReplyPhase phase)
    {
        if (xml is not { Length: > 0 and <= 8192 }) return false;
        try
        {
            using var reader = XmlReader.Create(new StringReader(xml), new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null });
            var root = XDocument.Load(reader).Root;
            if (root?.Name != "toast" || (string?)root.Attribute("activationType") is not (null or "foreground")
                || root.Attributes().Any(a => a.Name != "launch" && a.Name != "activationType")
                || root.Elements().ToList() is not [var visual] || visual.Name != "visual" || visual.HasAttributes
                || visual.Elements().ToList() is not [var binding] || binding.Name != "binding"
                || (string?)binding.Attribute("template") != "ToastGeneric" || binding.Attributes().Count() != 1
                || binding.Elements().ToList() is not [var title, var body]
                || new[] { title, body }.Any(e => e.Name != "text" || e.HasAttributes || e.HasElements)) return false;
            return title.Value == ToastsWalkProof.Sender && body.Value == Body(phase)
                && IsWireActivation((string?)root.Attribute("launch"), phase, Stamp);
        }
        catch (System.Xml.XmlException) { return false; }
    }
}
