using System.Text.Json.Nodes;
using Hermes.Core.Auth;
using Hermes.Core.Chat;
using Hermes.Core.Composer;
using Hermes.Core.Model;
using Hermes.Core.Net;

namespace Hermes.Core.Tests;

/// The composer against scripts/fixtures/composer-gateway.py (which layers on menus-gateway.py): models, switching with
/// the confirm, reasoning, the commands catalog, typed slash commands, the drawers' completions, steering, and the
/// queue draining with `queued:true`. Run through windows/scripts/e2e.sh (HQW_E2E_COMPOSER_CREDENTIALS); without it
/// these pass vacuously.
[Trait("Category", "E2E")]
[Collection(ComposerStandIn.Name)]
public class ComposerEndToEndTests
{
    private sealed class Ui : IModelSwitchUi
    {
        public List<string> Notices { get; } = [];
        public List<string> Confirms { get; } = [];
        public List<string> Failures { get; } = [];
        public bool Confirm { get; set; } = true;
        public Task<bool> ConfirmModelChange(string message) { lock (Confirms) Confirms.Add(message); return Task.FromResult(Confirm); }
        public void ModelChangeFailed(string reason) { lock (Failures) Failures.Add(reason); }
        public void SwitchNotice(string text, TimeSpan? duration, bool spinner) { lock (Notices) Notices.Add(text); }
        public void HideSwitchNotice() { }
    }

    private static async Task Until(Func<bool> condition, int seconds = 15)
    {
        var until = DateTime.UtcNow.AddSeconds(seconds);
        while (!condition())
        {
            if (DateTime.UtcNow > until) throw new TimeoutException("condition not met");
            await Task.Delay(50);
        }
    }

    private static async Task<JsonNode> Post(string url, string path, object body)
    {
        using var http = new HttpClient();
        var content = new StringContent(System.Text.Json.JsonSerializer.Serialize(body), System.Text.Encoding.UTF8, "application/json");
        var r = await http.PostAsync(url.TrimEnd('/') + path, content);
        r.EnsureSuccessStatusCode();
        return JsonNode.Parse(await r.Content.ReadAsStringAsync())!;
    }

    private static async Task<JsonNode> Get(string url, string path)
    {
        using var http = new HttpClient();
        return JsonNode.Parse(await http.GetStringAsync(url.TrimEnd('/') + path))!;
    }

    private static List<JsonNode> Calls(JsonNode state, string method) =>
        [.. (state.Arr("calls") ?? []).OfType<JsonNode>().Where(c => c.Str("method") == method)];

    /// [WIN-MODEL-YOLO-APPROVAL] The Models selector's foot on the wire: Approval Mode is `config.set approvals.mode`
    /// (Hermes answers with the mode it kept), a refused mode is put back, YOLO is `config.set yolo` "1"/"0", and a
    /// mode the chat's info already carried is not read again.
    [Fact]
    public async Task ApprovalModeAndYoloGoOutAsConfigSetAndARefusalIsPutBack()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_COMPOSER_CREDENTIALS");
        if (path == null || !File.Exists(path)) return;
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        var url = cred.Str("url")!;
        await Post(url, "/__composer/reset", new { });

        var signIn = new SignIn(new MemoryTokenStore());
        var session = await signIn.PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
        await using var client = new HermesClient(session);
        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
        var bot = (await client.BotsAsync()).First(b => b.Name == "default");
        await using var chat = client.OpenChat(bot.Name, await client.BotChatIdAsync(bot), bot.DisplayName);
        using var composer = new ChatComposer(chat, new ModelPrefs(client.AccountId, new MemoryStore()), isBotChat: true);
        await chat.OpenAsync();
        await Until(() => composer.ModelState.ApprovalMode.Length > 0);
        Assert.Equal("smart", composer.ModelState.ApprovalMode);
        Assert.False(composer.ModelState.Yolo);
        Assert.Equal("smart", composer.MenuInput().ApprovalMode);

        // Known from the chat's info: nothing is read.
        await composer.LoadApprovalModeAsync();
        var state = await Get(url, "/__menus/state");
        Assert.DoesNotContain(Calls(state, "config.get"), c => c["params"].Str("key") == "approvals.mode");

        await composer.SetApprovalModeAsync("off");
        Assert.Equal("off", composer.ModelState.ApprovalMode);
        state = await Get(url, "/__menus/state");
        var set = Calls(state, "config.set").Last(c => c["params"].Str("key") == "approvals.mode");
        Assert.Equal("off", set["params"].Str("value"));
        Assert.False(string.IsNullOrEmpty(set["params"].Str("session_id")));

        // A mode Hermes refuses: the alert's words, and the mode it had.
        var refused = await Assert.ThrowsAsync<GatewayException>(() => composer.SetApprovalModeAsync("loud"));
        Assert.Contains("unknown approval mode", MenusText.Of(refused));
        Assert.Equal("off", composer.ModelState.ApprovalMode);

        await composer.SetYoloAsync(true);
        Assert.True(composer.ModelState.Yolo);
        Assert.True(composer.MenuInput().Yolo);
        await composer.SetYoloAsync(false);
        Assert.False(composer.ModelState.Yolo);
        state = await Get(url, "/__menus/state");
        Assert.Equal(["1", "0"], Calls(state, "config.set").Where(c => c["params"].Str("key") == "yolo").Select(c => c["params"].Str("value")));
    }

    [Fact]
    public async Task ModelsCommandsSlashDrawersSteerAndQueue()
    {
        var path = Environment.GetEnvironmentVariable("HQW_E2E_COMPOSER_CREDENTIALS");
        if (path == null || !File.Exists(path)) return;
        var cred = JsonNode.Parse(File.ReadAllText(path))!;
        var url = cred.Str("url")!;
        await Post(url, "/__composer/reset", new { });

        var signIn = new SignIn(new MemoryTokenStore());
        var session = await signIn.PasswordAsync(GatewayAddress.FromTyped(url), cred.Str("username")!, cred.Str("password")!);
        await using var client = new HermesClient(session);
        await client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
        var bot = (await client.BotsAsync()).First(b => b.Name == "default");
        await using var chat = client.OpenChat(bot.Name, await client.BotChatIdAsync(bot), bot.DisplayName);
        using var composer = new ChatComposer(chat, new ModelPrefs(client.AccountId, new MemoryStore()), isBotChat: true);
        await chat.OpenAsync();
        await Until(() => composer.ModelState.Model.Length > 0);
        Assert.Equal(("claude-sonnet-5", "anthropic"), (composer.ModelState.Model, composer.ModelState.Provider));

        // The model list and the menu.
        var models = await composer.LoadModelsAsync();
        Assert.Contains(models, m => m.Id == "claude-haiku-4-5");
        var node = ModelMenuModel.Build(composer.MenuInput());
        Assert.Equal("Sonnet 5", node.Quick[0].Title);
        Assert.Equal("More Models…", node.Quick[^1].Title);
        Assert.NotNull(node.Fast);

        // A switch, and one that asks first.
        var ui = new Ui();
        Assert.True(await composer.SwitchModelAsync(composer.Describe("claude-haiku-4-5", "anthropic"), ui));
        Assert.Equal("claude-haiku-4-5", composer.ModelState.Model);
        Assert.Contains("Model changed to Haiku 4.5.", ui.Notices);
        Assert.True(await composer.SwitchModelAsync(composer.Describe("claude-opus-4-5-20251101", "anthropic"), ui));
        Assert.Contains("Opus 4.5 costs about 5× more per token than Sonnet 5.\n\nSwitch anyway?", ui.Confirms);
        await Until(() => composer.ModelState.Model == "claude-opus-4-5-20251101");
        var state = await Get(url, "/__menus/state");
        var sets = Calls(state, "config.set").Where(c => c["params"].Str("key") == "model").ToList();
        Assert.Equal(true, sets[^1]["params"].Bool("confirm_expensive_model"));
        Assert.Equal("claude-opus-4-5-20251101 --provider anthropic", sets[^1]["params"].Str("value"));
        Assert.Equal(["Opus 4.5", "Haiku 4.5", "Sonnet 5"], composer.Prefs.Recents.Select(r => r.Name));

        // A failing switch rolls back and says why.
        Assert.False(await composer.SwitchModelAsync(composer.Describe("broken-model", "openrouter"), ui));
        Assert.Contains(ui.Failures, f => f.Contains("broken-model failed"));
        Assert.Equal("claude-opus-4-5-20251101", composer.ModelState.Model);

        Assert.True(await composer.SetReasoningAsync("high", ui));
        await Until(() => composer.ModelState.ReasoningEffort == "high");

        // The commands catalog, as the ☰ list shows it.
        var catalog = await composer.LoadCommandsAsync();
        var sections = SlashCatalog.Sections(catalog, isBotChat: true);
        Assert.Contains(sections, s => s.Title == "Session" && s.Rows.Any(r => r.Command == "/status"));
        Assert.DoesNotContain(sections.SelectMany(s => s.Rows), r => r.Command == "/title"); // a bot's own chat

        // Typed slash commands land as output rows.
        composer.Send("/reasoning");
        await Until(() => chat.Messages.Any(m => m.Parts.OfType<SlashOutputPart>().Any(p => p.Output == "reasoning: high · display hide")));
        composer.Send("/status");
        await Until(() => chat.Messages.Any(m => m.Parts.OfType<SlashOutputPart>().Any(p => p.Command == "/status" && p.Output != SlashResults.Running)));
        composer.Send("/fast");
        await Until(() => chat.Messages.Any(m => m.Parts.OfType<SlashOutputPart>().Any(p => p.Command == "/fast" && p.Output.Contains("desktop slash palette"))));
        string? opened = "none";
        composer.Hooks.OpenModels = q => opened = q;
        composer.Send("/model gpt");
        await Until(() => opened == "gpt");

        // The drawers ask the gateway.
        var slash = await composer.CompleteSlashAsync("/mo");
        Assert.Contains(slash.Items, i => i.Display == "/model");
        var options = await composer.CompleteSlashAsync("/reasoning h");
        Assert.Equal(11, options.ReplaceFrom);
        Assert.Contains(options.Items, i => i.Text == "high");
        var files = await composer.CompletePathAsync("@file:src/");
        Assert.Contains(files.Items, i => i.Text == "@file:src/main.py");

        // A reply that runs a while: typed words steer into it; Ctrl+Enter waits in the queue and drains after.
        await Post(url, "/__fixture/plan", new { plans = new[] { new { chunks = Enumerable.Range(0, 60).Select(i => $"w{i} ").ToArray(), chunkDelay = 0.05 } } });
        composer.Send("Write a long answer");
        await Until(() => chat.Messages.LastOrDefault()?.Text.StartsWith("w0") == true);
        composer.Send("and keep it short");
        await Until(() => chat.Messages.Any(m => m.Role == Role.User && m.Text == "and keep it short" && !m.IsPending));
        composer.Send("next question", queue: true);
        Assert.Equal(["next question"], composer.Queue.Items.Select(i => i.Text));
        await Until(() => composer.Queue.Items.Count == 0, 20);
        state = await Get(url, "/__menus/state");
        var submits = Calls(state, "prompt.submit");
        Assert.Equal(true, submits[^1]["params"].Bool("queued"));
        Assert.Equal("next question", submits[^1]["params"].Str("text"));
        Assert.Equal("and keep it short", Calls(state, "session.redirect").Last()["params"].Str("text"));
        await Until(() => !chat.Busy, 20);

        // A gateway that can't redirect: the steer joins the queue with the notice; Send Now is not offered from then on.
        await Post(url, "/__composer/mode", new { redirect = "4010" });
        await Post(url, "/__fixture/plan", new { plans = new[] { new { chunks = Enumerable.Range(0, 60).Select(i => $"v{i} ").ToArray(), chunkDelay = 0.05 } } });
        string? notice = null;
        composer.Notice += n => notice = n;
        composer.Send("Another long one");
        await Until(() => chat.Messages.LastOrDefault()?.Text.StartsWith("v0") == true);
        composer.Send("steer this");
        await Until(() => notice != null);
        Assert.Equal(SteerRule.FailedNotice, notice);
        Assert.True(composer.Queue.RedirectUnsupported);
        // Stop parks it; Resume sends it.
        await chat.StopAsync();
        Assert.True(composer.Queue.Parked);
        composer.Queue.Resume();
        await Until(() => composer.Queue.Items.Count == 0);
        await Until(() => Calls(Get(url, "/__menus/state").Result, "prompt.submit").Any(c => c["params"].Str("text") == "steer this"));
    }
}
