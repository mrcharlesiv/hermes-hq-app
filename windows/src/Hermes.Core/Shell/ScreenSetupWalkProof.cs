// [WIN-SCREEN-SETUP-SEND-WALK] What the bot-screen-setup-send walk (HermesHQ.Windows/Services/ProofWalks.ScreenSetup.cs)
// presses and checks: Set Up with Hermes on otto's setup card, over the real wire against
// windows/ci/fixtures/screen-gateway.py. On the Mac (93f984bb1 App/Screen/AppModel+Screen.swift `runScreenSetup`,
// HermesKit/Chat/LiveChatSession+ScreenSetup.swift) the press closes the Screen, opens the bot's own chat, attaches the
// reviewed installer with `file.attach {session_id, profile, name, data_url}` and sends the prompt through the chat's
// normal send (`prompt.submit`, the bubble under the short title). The stand-in records both frames (the installer's
// decoded size and SHA-256, never its bytes) and runs nothing. Each check answers null when right, else what is wrong.

using System.Text.Json.Nodes;
using Hermes.Core.Model;
using Hermes.Core.Screen;

namespace Hermes.Core.Shell;

public static class ScreenSetupWalkProof
{
    public const string Walk = "bot-screen-setup-send";
    /// The stand-in's tag in windows.yml's screenshot extras (the same stand-in as bot-screen-wire).
    public const string Tag = ScreenWireWalkProof.Tag;
    public const string Bot = ScreenWireWalkProof.Bot;
    public const string BotName = ScreenWireWalkProof.BotName;
    public const string StandIn = ScreenWireWalkProof.StandIn;
    /// The stand-in's answer to file.attach (screen-gateway.py SETUP_REF_TEXT).
    public const string RefText = "@file:/fixture/uploads/hermes-hq-screen-setup.zip";
    /// The card's primary before any request this run.
    public const string Primary = "Set Up with Hermes";

    /// The chat after the send: the short-titled bubble in otto's chat.
    public const string Shot = "bot-screen-setup-sent";
    /// The walk's last shot, named after the walk (windows.yml wants a picture per walk name): the chat once the
    /// stand-in's synthetic reply has come in under the request.
    public const string FinalShot = Walk;
    public static readonly IReadOnlyList<string> Shots = [Shot];

    /// The prompt the Mac sends for the stand-in's ref_text and the reviewed installer.
    public static string Message => ScreenSetupPrompt.Message(RefText, ScreenSetupBundle.ExpectedSha256, ScreenSetupBundle.HelperAppPath);

    /// The keys the Mac's `file.attach` carries.
    public static readonly IReadOnlyList<string> AttachKeys = ["data_url", "name", "profile", "session_id"];
    /// The keys a send to an idle bot chat carries on Windows; the Mac also sends `submission_id` ([authority],
    /// LiveChatSession.swift), allowed here so the check holds once Windows sends it too.
    public static readonly IReadOnlyList<string> SubmitKeys = ["profile", "session_id", "text"];
    public const string SubmissionKey = "submission_id";

    /// otto is in the roster with its own chat: its stored session id, or null.
    public static string? StoredSession(JsonNode? profiles) =>
        (profiles?["profiles"] as JsonArray)?.OfType<JsonObject>().FirstOrDefault(p => p.Str("name") == Bot)?["canonical_session"].Str("id");

    /// The roster names otto Otto and gives it a chat (Set Up with Hermes opens the bot's chat from the bot list).
    public static string? Roster(JsonNode? profiles)
    {
        var otto = (profiles?["profiles"] as JsonArray)?.OfType<JsonObject>().FirstOrDefault(p => p.Str("name") == Bot);
        if (otto == null) return $"roster: no {Bot} in profiles.list";
        if (otto["ui_meta"]?["hermes-bots"].Str("display_name") != BotName) return $"roster: {Bot} isn't named {BotName}";
        if (StoredSession(profiles) is not { Length: > 0 }) return $"roster: {Bot} has no chat of its own";
        return null;
    }

    /// Before the press: the setup card (not control-only) with its buttons and Set Up with Hermes, enabled.
    public static string? Card(ScreenSetupCardLook look)
    {
        if (look.AutomationId != "screen.setup.card") return $"card: it is {look.AutomationId}, not the setup card";
        if (look.WindowsNoteShown || !look.ButtonsShown) return "card: no buttons (a Windows gateway's sentence?)";
        if (look.Heading != ScreenSetupCopy.Heading(false)) return $"card: the heading is \"{look.Heading}\"";
        if (look.Primary != Primary) return $"card: the button says \"{look.Primary}\", not \"{Primary}\" (already requested this run?)";
        if (!look.Enabled) return "card: the button is disabled";
        return null;
    }

    /// [WIN-SCREEN-SETUP-LAYOUT] Before the press (and the setup card's shot): Set Up with Hermes is where the owner can
    /// see it, inside the window's client area and inside the screenshots page's visible part (not under the bar, not
    /// below the fold). `button` and `page` are in the window content's coordinates; `client` is the content's size.
    public static string? InView(ScreenRect button, ScreenSize client, ScreenRect page)
    {
        const double slack = 0.5;
        if (client.Width <= 0 || client.Height <= 0) return "layout: the Screen's window has no client area";
        if (button.Width <= 0 || button.Height <= 0) return $"layout: {Primary} has no size";
        var where = $"{Primary} at {button.MinX:0},{button.MinY:0} {button.Width:0}×{button.Height:0}";
        var top = Math.Max(0, page.MinY);
        var bottom = Math.Min(client.Height, page.MaxY);
        if (button.MaxY > bottom + slack) return $"layout: {where} is below the fold (the page shows to y {bottom:0} of a {client.Width:0}×{client.Height:0} window)";
        if (button.MinY < top - slack) return $"layout: {where} is above the page's visible top (y {top:0})";
        if (button.MinX < Math.Max(0, page.MinX) - slack || button.MaxX > Math.Min(client.Width, page.MaxX) + slack)
            return $"layout: {where} is beside the page (0…{Math.Min(client.Width, page.MaxX):0} wide)";
        return null;
    }

    /// After the press: the Screen is gone (window and viewer).
    public static string? Closed(bool screenShowing, bool viewerOpen) =>
        screenShowing ? "screen: the Screen's window is still open" : viewerOpen ? "screen: the viewer is still open" : null;

    /// After the press: otto's own chat is the one in the pane (the bot chat, not a session of it).
    public static string? ChatOpen(OpenPane pane, string? paneProfile, string? chatProfile)
    {
        if (pane != OpenPane.BotChat) return $"chat: the pane shows {pane}, not a bot chat";
        if (paneProfile != Bot || chatProfile != Bot) return $"chat: the pane is {paneProfile ?? "nobody"}'s chat ({chatProfile ?? "no session"}), not {Bot}'s";
        return null;
    }

    /// The stand-in's build 47 plan control: the next prompt's synthetic reply waits `ReplyDelay` seconds, so the chat
    /// right after the send (the shot) is the request alone, never a race with the reply.
    public const string Plan = "/__fixture/plan";
    public const double ReplyDelay = 2.5;
    public static string PlanBody() => new JsonObject { ["plans"] = new JsonArray(new JsonObject { ["replyDelay"] = ReplyDelay }) }.ToJsonString();

    /// Right after the send the chat shows the request as the Mac does: your newest bubble says the short title, not
    /// the prompt's words. (Once the reply settles the chat reads its history back, where the gateway keeps the whole
    /// prompt as the message, D26, so this holds only until then.)
    public static string? Bubble(IEnumerable<ChatMessage> messages)
    {
        if (messages.LastOrDefault(m => m.Role == Role.User) is not { } last) return "bubble: no bubble of yours";
        if (last.Text == ScreenSetupPrompt.QueueTitle) return null;
        return last.Text.StartsWith(ScreenSetupPrompt.Text, StringComparison.Ordinal)
            ? "bubble: the prompt's own words show, not its short title"
            : $"bubble: your newest bubble says \"{last.Text[..Math.Min(60, last.Text.Length)]}\"";
    }

    /// A reply of the bot's came in after the request (its bubble the short title, or the stored prompt once read back).
    public static bool Replied(IReadOnlyList<ChatMessage> messages)
    {
        var request = messages.ToList().FindLastIndex(m => m.Role == Role.User && (m.Text == ScreenSetupPrompt.QueueTitle || m.Text == Message));
        return request >= 0 && messages.Skip(request + 1).Any(m => m.Role == Role.Assistant && !m.IsStreaming && m.Text.Length > 0);
    }

    /// How many chat frames the stand-in has recorded (a mark before the press).
    public static int Chat(JsonNode? record) => record?["chat"] is JsonArray list ? list.Count : 0;

    /// After `mark`: exactly one file.attach then one prompt.submit, both to otto's chat, with the Mac's params and words.
    public static string? Sent(JsonNode? record, int mark)
    {
        var frames = record?["chat"] is JsonArray list ? list.Skip(mark).OfType<JsonObject>().ToList() : [];
        var attaches = frames.Where(f => f.Str("method") == "file.attach").ToList();
        var submits = frames.Where(f => f.Str("method") == "prompt.submit").ToList();
        if (attaches.Count == 0) return "attach: no file.attach reached the stand-in";
        if (attaches.Count > 1) return $"attach: {attaches.Count} file.attach frames, not one";
        if (submits.Count == 0) return "prompt: no prompt.submit reached the stand-in";
        if (submits.Count > 1) return $"prompt: {submits.Count} prompt.submit frames, not one";
        var a = attaches[0];
        var s = submits[0];
        if (frames.IndexOf(a) > frames.IndexOf(s)) return "order: the prompt went out before the installer was attached";

        var aKeys = Keys(a);
        if (!aKeys.SequenceEqual(AttachKeys)) return $"attach: sent {string.Join(", ", aKeys)}, not {string.Join(", ", AttachKeys)}";
        if (a.Str("profile") != Bot) return $"attach: profile {a.Str("profile")}";
        if (a.Str("owner") != Bot) return $"attach: the session id {a.Str("session_id")} is {a.Str("owner")}'s chat, not {Bot}'s";
        if (a.Str("name") != ScreenSetupBundle.Filename) return $"attach: named {a.Str("name")}";
        if (a.Str("data_url_prefix") != "data:application/zip;base64,") return "attach: the data URL isn't a base64 zip";
        if (a.Int("data_bytes") != ScreenSetupBundle.ByteCount) return $"attach: {a.Int("data_bytes")} bytes, not {ScreenSetupBundle.ByteCount}";
        if (a.Str("data_sha256") != ScreenSetupBundle.ExpectedSha256) return $"attach: SHA-256 {a.Str("data_sha256")}, not the reviewed installer's";

        var sKeys = Keys(s);
        var extra = sKeys.Except(SubmitKeys).Except([SubmissionKey]).ToList();
        if (SubmitKeys.Except(sKeys).FirstOrDefault() is { } missing) return $"prompt: no {missing}";
        if (extra.Count > 0) return $"prompt: also sent {string.Join(", ", extra)} (an idle chat's send carries none)";
        if (s.Bool("queued") == true) return "prompt: sent as queued";
        if (s.Str("profile") != Bot || s.Str("owner") != Bot) return $"prompt: sent to {s.Str("owner")} as {s.Str("profile")}, not {Bot}";
        if (s.Str("session_id") != a.Str("session_id")) return "prompt: sent to another runtime than the installer was attached to";
        var text = s.Str("text") ?? "";
        if (text != Message)
        {
            if (!text.StartsWith(ScreenSetupPrompt.Text, StringComparison.Ordinal)) return "prompt: the words aren't the reviewed prompt";
            return $"prompt: the installer lines are \"{text[Math.Min(text.Length, ScreenSetupPrompt.Text.Length)..].Trim()}\"";
        }
        return null;
    }

    private static List<string> Keys(JsonObject frame) =>
        frame["keys"] is JsonArray keys ? keys.Select(J.AsString).OfType<string>().OrderBy(k => k, StringComparer.Ordinal).ToList() : [];
}
