using System.Globalization;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Model;
using Hermes.Core.Chat;
using Hermes.Core.Net;

namespace Hermes.Core.Composer;

/// The RPC answers a slash command shows (HermesKit/Chat/SlashRunner.swift SlashResults).
public static class SlashResults
{
    /// `renderRpcResult` (V:…/use-prompt-actions/utils.ts:525-600) for the RPCs the app routes to.
    public static string Render(JsonNode? response)
    {
        if (response is not JsonObject r) return "";
        if (r.Obj("summary") is { } summary && summary.Str("headline") is { Length: > 0 } headline)
        {
            var lines = new List<string> { $"{(summary.Bool("noop") == true ? "" : "✓ ")}{headline}" };
            if (summary.Text("token_line") is { } token) lines.Add("  " + token);
            if (summary.Text("note") is { } note) lines.Add("  " + note);
            return string.Join("\n", lines);
        }
        if (r.Str("status") is "queued" or "rejected")
        {
            var text = r.Str("text") ?? "";
            if (r.Str("status") == "queued") return text.Length == 0 ? "Steered next tool call" : $"Steered · \"{text}\" queued for next tool call";
            return "Steer rejected — agent declined input";
        }
        if (r.Get("killed") is JsonValue kv && kv.TryGetValue(out double killed))
        {
            var n = (int)killed;
            return n > 0 ? $"Stopped {n} background process{(n == 1 ? "" : "es")}." : "No background processes to stop.";
        }
        if (r.Str("file") is { Length: > 0 } file) return $"Saved transcript to {file}";
        if (r.Str("output") is { Length: > 0 } output) return output;
        if (r.ContainsKey("total") || r.ContainsKey("input") || r.ContainsKey("output") || r.ContainsKey("calls"))
        {
            string N(string key) => (r.Num(key) ?? 0).ToString("N0", CultureInfo.InvariantCulture);
            var lines = new List<string> { $"Usage: {N("calls")} calls · {N("input")} in / {N("output")} out · {N("total")} total" };
            foreach (var extra in new[] { r.Arr("account_lines"), r.Arr("credits_lines") })
                foreach (var line in extra ?? [])
                    if (J.AsString(line)?.Trim() is { Length: > 0 } s) lines.Add(s);
            return string.Join("\n", lines);
        }
        return "";
    }

    /// `/reasoning <arg>`'s `config.set` value and scope; null = nothing to set.
    public static (string Value, string? Scope)? ReasoningParams(string arg)
    {
        string? scope = null;
        var values = new List<string>();
        foreach (var part in arg.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
        {
            switch (part.ToLowerInvariant())
            {
                case "--global" or "-g" or "global": scope = "global"; break;
                case "--session" or "-s" or "session": scope = "session"; break;
                default: values.Add(part); break;
            }
        }
        return values.Count == 0 ? null : (string.Join(" ", values), scope);
    }

    /// `parseCommandDispatch`: a directive, or null for a malformed or plain answer.
    public static JsonNode? Directive(JsonNode? raw) => raw.Str("type") switch
    {
        "alias" => raw.Str("target") != null ? raw : null,
        "exec" or "plugin" => raw,
        "prefill" or "send" => raw.Str("message") != null ? raw : null,
        "skill" => raw.Str("name") != null ? raw : null,
        _ => null,
    };

    public static bool IsMissingMethod(Exception e) => e is GatewayException { RpcCode: -32601 };

    public static readonly Regex NotACommand = new(@"not a quick/plugin/(?:bundle/)?skill command", RegexOptions.IgnoreCase);
    public const string QueuedLine = "session busy — message queued to send when the current turn finishes";
    public const string BotChatTitle = "A bot's own chat keeps its name. Rename the bot instead.";
    public const string NewChatFailed = "Couldn’t start a new chat with this bot.";
    public const string CompressWait = "Wait for this reply to finish, then compress.";
    public const string CompressPending = "Compression is still running in the background.";
    public const string CompressTimedOut = "Couldn’t compress: your gateway didn’t answer in time.";
    public static readonly TimeSpan CompressTimeout = TimeSpan.FromSeconds(660);
    public const string Running = "Running…";
    public const string AppName = "Hermes HQ";

    public static string Compressing(string topic) =>
        topic.Trim().Length == 0 ? "Compressing context…" : $"Compressing context for: {topic.Trim()}…";

    /// `session.compress`'s answer as the result row.
    public static string CompressText(JsonNode? r)
    {
        var status = r.Str("status");
        if (status == "pending") return CompressPending;
        if (r.Bool("lock_held") == true) return r.Text("message") ?? "Another compression is already running for this chat.";
        var summary = r.Obj("summary");
        var headline = summary.Text("headline");
        if (status == "aborted" || summary.Bool("aborted") == true) return headline ?? "Compression was stopped.";
        var removed = r.Int("removed");
        if (summary.Bool("noop") == true || (headline == null && removed == 0)) return headline ?? "Nothing to compress.";
        if (headline != null)
            return string.Join("\n", new[] { headline, summary.Text("token_line"), summary.Text("note") }.OfType<string>());
        if (r.Obj("host_ack").Str("output")?.Trim() is { Length: > 0 } output) return output;
        var n = removed ?? 0;
        return n > 0 ? $"Compressed {n} message{(n == 1 ? "" : "s")}." : "Nothing to compress.";
    }

    public static string CompressError(Exception e)
    {
        if (e is GatewayException { RpcCode: 4009 }) return CompressWait;
        if (e is GatewayException { Code: "timeout" }) return CompressTimedOut;
        var message = MenusText.Of(e);
        return "Couldn’t compress: " + (message.Length > 160 ? message[..159] + "…" : message);
    }

    // /btw and /bg (SideTasks.swift)
    public static string SideUsage(string kind) => kind == "btw"
        ? "Type a question after /btw. It's answered from this chat so far, without interrupting it."
        : "Type a task after /bg. It runs in a separate session, and the result shows here when it's done.";

    public static string SideStarted(string kind) => kind == "btw"
        ? "Asking on the side… the answer will show here."
        : "Started in the background. Keep chatting; the result will show here when it's done.";

    public static string SideCouldNotStart(string kind, string reason) => kind == "btw"
        ? $"Couldn’t ask: {reason}" : $"Couldn’t start the background task: {reason}";
}

// The slash dispatcher (HermesKit/Chat/SlashRunner.swift; spec 1x §8): a sent "/command" runs here instead of
// prompt.submit. Output lands as slash rows.
public sealed partial class ChatComposer
{
    /// One command's output: a "Running…" row after a moment, replaced by the answer.
    private sealed class SlashOutput
    {
        private readonly ChatComposer _chat;
        private readonly CancellationTokenSource _placeholder = new();
        private readonly object _lock = new();
        private bool _finished;
        public string? Command { get; }
        public string? RowId { get; private set; }

        public SlashOutput(ChatComposer chat, string? command, TimeSpan? placeholderAfter, string running)
        {
            _chat = chat;
            Command = command;
            if (placeholderAfter is { } after)
                _ = Task.Run(async () =>
                {
                    try { await Task.Delay(after, _placeholder.Token); } catch (OperationCanceledException) { return; }
                    lock (_lock)
                    {
                        if (_finished || RowId != null) return;
                        RowId = _chat.Session.AddLocalRow(Role.System, new SlashOutputPart(Command, running));
                    }
                });
        }

        public void Finish(string output)
        {
            _placeholder.Cancel();
            lock (_lock)
            {
                if (RowId is { } id && !_finished) _chat.Session.UpdateLocalRow(id, new SlashOutputPart(Command, output));
                else RowId = _chat.Session.AddLocalRow(Role.System, new SlashOutputPart(Command, output));
                _finished = true;
            }
        }

        public void Cancel()
        {
            _placeholder.Cancel();
            lock (_lock)
            {
                if (RowId is { } id && !_finished) _chat.Session.UpdateLocalRow(id, null);
                if (!_finished) RowId = null;
                _finished = true;
            }
        }
    }

    private void AppendSlashRow(string? command, string output) =>
        Session.AddLocalRow(Role.System, new SlashOutputPart(command, output));

    private bool _compressing;

    /// The whole dispatcher: resolve the command's surface, then act on it. `recordInput` false for an alias's re-run.
    public async Task RunSlashAsync(string commandText, bool recordInput)
    {
        var command = commandText.Trim();
        var (name, arg) = SlashCommand.Parse(command);
        if (name.Length == 0)
        {
            if (command.TrimStart('/').Trim().Length > 0) Hooks.Prefill?.Invoke(command);
            AppendSlashRow(null, "empty slash command");
            return;
        }
        var shown = recordInput ? "/" + name : null;
        var catalog = LatestCommands;
        if (SlashCatalog.NativeUnsupported.Contains(name))
        {
            AppendSlashRow(shown, $"/{name} isn't available in {SlashResults.AppName} yet.");
            return;
        }
        if (name == "title" && arg.Length > 0 && IsBotChat)
        {
            AppendSlashRow(shown, SlashResults.BotChatTitle);
            return;
        }
        var spec = SlashCatalog.Resolve("/" + name, catalog);
        switch (spec?.Surface)
        {
            case SlashSurface.Unavailable u:
                AppendSlashRow(shown, SlashCatalog.UnavailableMessage(u.Reason, SlashCatalog.Canonical("/" + name, catalog)));
                return;
            case SlashSurface.Picker { Name: "model" }:
                Hooks.OpenModels?.Invoke(arg.Length == 0 ? null : arg);
                return;
            case SlashSurface.Action { Name: "help" }:
                Hooks.OpenCommands?.Invoke();
                return;
            case SlashSurface.Action { Name: "btw" } when arg.Length == 0:
                AppendSlashRow(shown, SlashResults.SideUsage("btw"));
                return;
            case SlashSurface.Action { Name: "background" } when arg.Length == 0:
                AppendSlashRow(shown, SlashResults.SideUsage("bg"));
                return;
            case SlashSurface.Action { Name: "new" }:
                if (Hooks.NewChat?.Invoke(arg) != true) AppendSlashRow(shown, SlashResults.NewChatFailed);
                return;
            case SlashSurface.Action { Name: "compress" } when Running:
                AppendSlashRow(shown, SlashResults.CompressWait);
                return;
            case SlashSurface.Action { Name: "compress" } when _compressing:
                return;
            case SlashSurface.Picker:
            case SlashSurface.Action { Name: "branch" or "profile" or "skin" or "wake" or "handoff" or "browser" or "journey" or "pet" or "hatch" }:
                AppendSlashRow(shown, $"/{name} isn't available in {SlashResults.AppName} yet.");
                return;
        }
        var compress = spec?.Surface is SlashSurface.Action { Name: "compress" };
        if (compress) _compressing = true;
        try
        {
            var output = new SlashOutput(this, shown, RunningPlaceholderAfter, compress ? SlashResults.Compressing(arg) : SlashResults.Running);
            // Every path from here talks to the chat's live session: resume it first.
            if (Session.RuntimeId == null)
            {
                try { await Session.EnsureRuntimeAsync(); }
                catch (GatewayException)
                {
                    output.Finish("error: Couldn’t reach this chat.");
                    return;
                }
            }
            switch (spec?.Surface)
            {
                case SlashSurface.Action { Name: "stop" }: await SlashStop(output); break;
                case SlashSurface.Action { Name: "title" } when arg.Length > 0: await SlashTitle(arg, output); break;
                case SlashSurface.Action { Name: "reasoning" }: await SlashReasoning(name, arg, command, output); break;
                case SlashSurface.Action { Name: "yolo" }: await SlashYolo(output); break;
                case SlashSurface.Action { Name: "btw" }: await SlashSide("btw", name, arg, command, output); break;
                case SlashSurface.Action { Name: "background" }: await SlashSide("bg", name, arg, command, output); break;
                case SlashSurface.Action { Name: "compress" }: await SlashCompress(name, arg, command, output); break;
                case SlashSurface.Rpc rpc: await SlashRpc(rpc.Method, name, arg, command, output); break;
                default: await RunExec(name, arg, command, output); break;
            }
        }
        finally { if (compress) _compressing = false; }
    }

    private Task<JsonNode> Slash(string method, JsonObject p, TimeSpan timeout) =>
        Session.CallAsync(method, p, timeout, SessionNeed.ResumeFirst);

    private async Task RunExec(string name, string arg, string command, SlashOutput output)
    {
        Exception? execError;
        try
        {
            var line = command.TrimStart('/');
            var res = await Slash("slash.exec", new JsonObject { ["command"] = line }, TimeSpan.FromSeconds(60));
            if (SlashResults.Directive(res) is { } directive)
            {
                await HandleDirective(directive, name, arg, output);
                return;
            }
            var text = res.Str("output") is { Length: > 0 } o ? o : $"/{name}: no output";
            output.Finish(res.Str("warning") is { Length: > 0 } warning ? $"warning: {warning}\n{text}" : text);
            return;
        }
        catch (GatewayException e) { execError = e; }
        try
        {
            var raw = await Slash("command.dispatch", new JsonObject { ["name"] = name, ["arg"] = arg }, TimeSpan.FromSeconds(60));
            if (SlashResults.Directive(raw) is not { } directive)
            {
                output.Finish("error: invalid response: command.dispatch");
                return;
            }
            await HandleDirective(directive, name, arg, output);
        }
        catch (GatewayException e)
        {
            var message = MenusText.Of(e);
            output.Finish(SlashResults.NotACommand.IsMatch(message) ? $"error: /{name} failed: {MenusText.Of(execError)}" : $"error: {message}");
        }
    }

    private async Task HandleDirective(JsonNode d, string name, string arg, SlashOutput output)
    {
        var type = d.Str("type") ?? "";
        switch (type)
        {
            case "exec" or "plugin":
                output.Finish(d.Str("output") ?? "(no output)");
                return;
            case "alias":
                output.Cancel();
                var target = d.Str("target") ?? name;
                await RunSlashAsync($"/{target}{(arg.Length == 0 ? "" : " " + arg)}", recordInput: false);
                return;
        }
        var noticed = false;
        if (type is "send" or "prefill" && d.Str("notice")?.Trim() is { Length: > 0 } notice)
        {
            output.Finish(notice);
            noticed = true;
        }
        var message = (d.Str("message") ?? "").Trim();
        if (type == "prefill")
        {
            if (!noticed) output.Cancel();
            if (message.Length > 0) Hooks.Prefill?.Invoke(message);
            return;
        }
        if (message.Length == 0)
        {
            output.Finish($"/{name}: {(type == "skill" ? "skill payload missing message" : "empty message")}");
            return;
        }
        // The expanded skill body is model-facing: the bubble shows the invocation.
        var projected = d.Str("display")?.Trim() ?? "";
        var display = projected.Length == 0 ? SkillInvocationText(message) : projected;
        var queues = Running || (Queue.Items.Count > 0 && !Queue.Parked);
        Queue.QueuesNextSend = true; // a command's message waits behind a running reply; it is never steered into it
        Queue.Send(message, display);
        if (queues) output.Finish(SlashResults.QueuedLine);
        else if (!noticed) output.Cancel();
    }

    /// What the bubble shows for a skill's expanded body (Hydration.skillInvocationText): "/skill" and the instruction
    /// typed with it; null when the body isn't a skill invocation.
    public static string? SkillInvocationText(string text)
    {
        const string prefix = "[IMPORTANT: The user has invoked the ";
        if (!text.StartsWith(prefix, StringComparison.Ordinal)) return null;
        var after = text[prefix.Length..];
        if (after.Length == 0 || after[0] != '"') return null;
        var close = after.IndexOf('"', 1);
        if (close < 0) return null;
        var name = after[1..close].Trim();
        if (name.Length == 0) return null;
        var label = name.StartsWith('/') ? name : "/" + name;
        string Between(string marker, string end, bool fromEnd)
        {
            var at = fromEnd ? text.LastIndexOf(marker, StringComparison.Ordinal) : text.IndexOf(marker, StringComparison.Ordinal);
            if (at < 0) return "";
            var tail = text[(at + marker.Length)..];
            var stop = tail.IndexOf(end, StringComparison.Ordinal);
            return (stop >= 0 ? tail[..stop] : tail).Trim();
        }
        var instruction = text.Contains(" skill bundle,")
            ? Between("\nUser instruction: ", "\n\n[Loaded as part of the ", false)
            : text.Contains("The full skill content is loaded below.]")
                ? Between("The user has provided the following instruction alongside the skill invocation: ", "\n\n[Runtime note:", true)
                : "";
        return instruction.Length == 0 ? label : $"{label} {Regex.Replace(instruction, @"\s+", " ").Trim()}";
    }

    private async Task SlashRpc(string method, string name, string arg, string command, SlashOutput output)
    {
        try
        {
            var body = SlashResults.Render(await Slash(method, [], TimeSpan.FromSeconds(30)));
            output.Finish(body.Length == 0 ? $"/{name}: no output" : body);
        }
        catch (GatewayException e)
        {
            if (SlashResults.IsMissingMethod(e)) { await RunExec(name, arg, command, output); return; }
            output.Finish($"error: {MenusText.Of(e)}");
        }
    }

    /// The Stop button's own path for the turn, then `process.stop`.
    private async Task SlashStop(SlashOutput output)
    {
        var lines = new List<string>();
        if (Running)
        {
            _ = Session.StopAsync();
            lines.Add("Stopped the active turn.");
        }
        else
        {
            try
            {
                await Slash("session.interrupt", [], TimeSpan.FromSeconds(40));
                lines.Add("Stopped the active turn.");
            }
            catch (GatewayException e) { lines.Add($"Couldn’t stop the active turn: {MenusText.Of(e)}"); }
        }
        try
        {
            var text = SlashResults.Render(await Slash("process.stop", [], TimeSpan.FromSeconds(30)));
            if (text.Length > 0) lines.Add(text);
        }
        catch (GatewayException e) { lines.Add($"Couldn’t stop background processes: {MenusText.Of(e)}"); }
        output.Finish(string.Join("\n", lines));
    }

    private async Task SlashTitle(string arg, SlashOutput output)
    {
        try
        {
            var res = await Slash("session.title", new JsonObject { ["title"] = arg }, TimeSpan.FromSeconds(30));
            var queued = res.Bool("pending") == true;
            var final = (res.Str("title") is { Length: > 0 } t ? t : arg).Trim();
            if (final.Length > 0) Hooks.TitleApplied?.Invoke(final);
            output.Finish(final.Length == 0 ? "Session title cleared."
                : $"Session title set: {final}{(queued ? " (queued while session initializes)" : "")}");
        }
        catch (GatewayException e) { output.Finish($"error: {MenusText.Of(e)}"); }
    }

    private async Task SlashReasoning(string name, string arg, string command, SlashOutput output)
    {
        try
        {
            if (SlashResults.ReasoningParams(arg) is not { } p)
            {
                var current = await Slash("config.get", new JsonObject { ["key"] = "reasoning" }, TimeSpan.FromSeconds(15));
                var value = current.Str("value") is { Length: > 0 } v ? v : "medium";
                var display = current.Str("display") is { Length: > 0 } dv ? dv : "hide";
                output.Finish($"reasoning: {value} · display {display}");
                return;
            }
            var set = new JsonObject { ["key"] = "reasoning", ["value"] = p.Value };
            if (p.Scope != null) set["scope"] = p.Scope;
            var res = await Slash("config.set", set, TimeSpan.FromSeconds(15));
            var answer = res.Str("value") is { Length: > 0 } a ? a : p.Value;
            if (ModelNames.ReasoningEffortValues.Contains(answer.ToLowerInvariant()))
                SetState(s => s with { ReasoningEffort = answer.ToLowerInvariant() });
            output.Finish($"reasoning: {answer}");
        }
        catch (GatewayException e)
        {
            if (SlashResults.IsMissingMethod(e)) { await RunExec(name, arg, command, output); return; }
            output.Finish($"error: {MenusText.Of(e)}");
        }
    }

    /// `/btw <question>`, `/bg <prompt>`: the task starts beside the turn and its result lands later.
    private async Task SlashSide(string kind, string name, string arg, string command, SlashOutput output)
    {
        try
        {
            var res = await Slash(kind == "btw" ? "prompt.btw" : "prompt.background", new JsonObject { ["text"] = arg }, TimeSpan.FromSeconds(30));
            if (res.Text("task_id") is not { } taskId)
            {
                output.Finish(SlashResults.SideStarted(kind));
                return;
            }
            bool done;
            lock (_lock) done = _sideDone.Contains(taskId);
            if (done) { output.Cancel(); return; }
            output.Finish(SlashResults.SideStarted(kind));
            lock (_lock) _sideTasks[taskId] = (kind, arg, output.RowId);
        }
        catch (GatewayException e)
        {
            if (SlashResults.IsMissingMethod(e)) { await RunExec(name, arg, command, output); return; }
            output.Finish(SlashResults.SideCouldNotStart(kind, MenusText.Of(e)));
        }
    }

    private async Task SlashCompress(string name, string arg, string command, SlashOutput output)
    {
        var topic = arg.Trim();
        try
        {
            var p = topic.Length == 0 ? new JsonObject() : new JsonObject { ["focus_topic"] = topic };
            var res = await Slash("session.compress", p, SlashResults.CompressTimeout);
            if (res.Obj("info") is { } info) ApplyInfo(info);
            else if (res.Obj("usage") is { } usage) Usage = usage.DeepClone();
            StateChanged?.Invoke();
            output.Finish(SlashResults.CompressText(res));
        }
        catch (GatewayException e)
        {
            if (SlashResults.IsMissingMethod(e)) { await RunExec(name, arg, command, output); return; }
            output.Finish(SlashResults.CompressError(e));
        }
    }

    /// `/yolo`: the session's approval bypass, toggled.
    private async Task SlashYolo(SlashOutput output)
    {
        var next = !ModelState.Yolo;
        try
        {
            var res = await Slash("config.set", new JsonObject { ["key"] = "yolo", ["value"] = next ? "1" : "0" }, TimeSpan.FromSeconds(15));
            var active = res.Str("value") == "1";
            SetState(s => s with { Yolo = active });
            output.Finish($"YOLO {(active ? "on" : "off")} for this session");
        }
        catch (GatewayException)
        {
            output.Cancel();
            Hooks.Alert?.Invoke("YOLO", "Couldn’t turn YOLO on or off.");
        }
    }
}
