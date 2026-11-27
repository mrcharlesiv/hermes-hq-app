using System.Text.Json.Nodes;
using Hermes.Core.Chat;
using Hermes.Core.Composer;
using Hermes.Core.Model;

namespace Hermes.Core.Tests;

// Unit checks for the composer port (HermesKit Tests/Composer and Tests/Menus vectors). No network.

public class ComposerRulesTests
{
    [Theory]
    [InlineData(1, false, false, "Queued")]
    [InlineData(3, false, false, "3 Queued")]
    [InlineData(1, false, true, "Queued · Sends After This Reply")]
    [InlineData(2, false, true, "2 Queued · Send After This Reply")]
    [InlineData(1, true, true, "Queue Paused")]
    [InlineData(2, true, false, "Queue Paused · 2 Messages")]
    public void QueueHeader(int count, bool paused, bool running, string words) =>
        Assert.Equal(words, QueueWords.Header(count, paused, running));

    [Fact]
    public void QueueCaptionsAndMore()
    {
        Assert.Equal("Sending…", QueueWords.Caption(true, true, "2 Photos"));
        Assert.Equal("Editing · 2 Photos", QueueWords.Caption(false, true, "2 Photos"));
        Assert.Null(QueueWords.Caption(false, false, null));
        Assert.Equal("More, Fix the typo", QueueWords.MoreLabel("Fix the\ntypo"));
        Assert.Equal("More", QueueWords.MoreLabel("  "));
        Assert.Equal("typed\nqueued", QueueWords.EditedField("typed  ", "queued"));
        Assert.True(QueueWords.ShowsResume(1, true));
        Assert.False(QueueWords.ShowsResume(0, true));
    }

    [Theory]
    [InlineData("/usage", true)]
    [InlineData("/plan do it", true)]
    [InlineData("/", true)]
    [InlineData("/usr/local/bin", false)]
    [InlineData("run /x", false)]
    public void SlashCommandsAreSpottedAsTheWebDoes(string text, bool slash)
    {
        Assert.Equal(slash, SlashCommand.Matches(text));
        Assert.Equal(slash, SteerRule.IsSlashCommand(text));
    }

    [Fact]
    public void SlashParse()
    {
        Assert.Equal(("reasoning", "high --global"), SlashCommand.Parse("/Reasoning  high --global "));
        Assert.Equal(("", ""), SlashCommand.Parse("/ words"));
        Assert.Equal("/status", SlashCatalog.Normalize("Status now"));
    }

    [Fact]
    public void EmptyReturnRules()
    {
        Assert.Equal(EmptyReturn.Nothing, EmptyReturnRule.Decide(false, 0, false, true));
        Assert.Equal(EmptyReturn.Nothing, EmptyReturnRule.Decide(false, 2, true, true));
        Assert.Equal(EmptyReturn.SendNext, EmptyReturnRule.Decide(false, 2, false, true));
        Assert.Equal(EmptyReturn.SendNowHead, EmptyReturnRule.Decide(true, 2, false, true));
    }

    [Theory]
    [InlineData("example.com/post", "https://example.com/post", true)]
    [InlineData("192.168.1.20:8080/x", "https://192.168.1.20:8080/x", true)]
    [InlineData("hello world", "hello world", false)]
    [InlineData("mailto:a@b.co", "mailto:a@b.co", false)]
    [InlineData("http://x", "http://x", true)]
    public void LinkTextAsTheWebTypesIt(string typed, string normalised, bool link)
    {
        Assert.Equal(normalised, LinkText.Normalised(typed));
        Assert.Equal(link, LinkText.IsLink(LinkText.Normalised(typed)));
    }

    [Fact]
    public void RefValueQuotes()
    {
        Assert.Equal("@url:https://a.b/c", RefValue.UrlRef("https://a.b/c"));
        Assert.Equal("`a b`", RefValue.Format("a b"));
        Assert.Equal("\"a `b\"", RefValue.Format("a `b"));
    }

    [Fact]
    public void LeftoverLineBreaks()
    {
        Assert.True(ComposerText.IsLeftoverLineBreaks(" \n "));
        Assert.False(ComposerText.IsLeftoverLineBreaks("  "));
        Assert.Equal("a\n\nb", ComposerText.SendText("\n a\n\nb \n"));
    }
}

public class ModelNameTests
{
    [Theory]
    [InlineData("claude-opus-4-5-20251101", "Opus 4.5", "Opus 4.5")]
    [InlineData("claude-sonnet-5[1m]", "Sonnet 5 1M", "Sonnet 5")]
    [InlineData("gpt-5.5-fast", "GPT-5.5 Fast", "GPT-5.5 · Fast")]
    [InlineData("gemini-2.5-pro", "Gemini 2.5 Pro", "Gemini 2.5 Pro")]
    [InlineData("glm-5.2", "GLM 5.2", "GLM 5.2")]
    [InlineData("deepseek-v4.1-flash", "DeepSeek V4.1 Flash", "DeepSeek V4.1 · Flash")]
    [InlineData("anthropic/claude-opus-4.5", "Opus 4.5", "Opus 4.5")]
    [InlineData("qwen2.5-coder:14b", "Qwen2.5 Coder:14B", "Qwen2.5 Coder:14B")]
    [InlineData("Qwen3-30B-A3B-Instruct-2507-UD-Q4_K_XL", "Qwen3 30B A3B Q4", "Qwen3 30B A3B")]
    [InlineData("moonshotai/kimi-k2-thinking", "Kimi K2 Thinking", "Kimi K2 · Thinking")]
    [InlineData("hermes-4", "Hermes 4", "Hermes 4")]
    [InlineData("", "No model", "No model")]
    public void Vectors(string id, string display, string pill)
    {
        Assert.Equal(display, ModelNames.DisplayModelName(id));
        Assert.Equal(pill, ModelNames.FormatModelPillLabel(id));
    }

    [Theory]
    [InlineData("us.anthropic.claude-3-7-sonnet-20250219-v1:0", "3.7 Sonnet")]
    [InlineData("amazon.nova-pro-v1:0", "Nova Pro")]
    [InlineData("claude-sonnet-4@20250514", "Sonnet 4")]
    [InlineData("meta-llama/llama-3.3-70b-instruct:free", "Llama 3.3 70B Instruct Free")]
    [InlineData("gpt-4o-2024-08-06", "GPT-4o")]
    [InlineData("ft:gpt-4o-mini-2024-07-18:acme::9abcDEF", "GPT-4o-mini Fine-tuned")]
    [InlineData("unsloth/Qwen3-30B-A3B-GGUF:Q4_K_M", "Qwen3 30B A3B Q4")]
    public void CloudWrappers(string id, string display) => Assert.Equal(display, ModelNames.DisplayModelName(id));

    [Fact]
    public void ProvidersAndEfforts()
    {
        Assert.Equal("Claude Subscription", ModelNames.PlainProviderName("Claude Subscription DirectSDK (Experimental)"));
        Assert.Equal("Custom", ModelNames.PlainProviderName("Custom [local]"));
        Assert.Equal("(x)", ModelNames.PlainProviderName("(x)"));
        Assert.Equal("ChatGPT or Codex Subscription", ModelNames.ProviderDisplayName("openai-codex"));
        Assert.Equal("openrouter", ModelNames.ProviderDisplayName("openrouter"));
        Assert.Equal("Claude Subscription", ModelNames.PlainProviderName("claude-subscription-directsdk-experimental"));
        Assert.Equal("Extra Deep", ModelNames.EffortLabel("extra_deep"));
        Assert.Equal("Extra High", ModelNames.EffortLabel("xhigh"));
        Assert.Equal("Off", ModelNames.EffortLabel("none"));
        Assert.Equal(("a", "p"), ModelNames.CurrentPickerSelection(("a", "p"), ("b", "q")));
        Assert.Equal(("b", "q"), ModelNames.CurrentPickerSelection(("a", ""), ("b", "q")));
        Assert.Equal(("a", "q"), ModelNames.CurrentPickerSelection(("a", ""), ("", "q")));
    }
}

public class ModelMenuTests
{
    private static readonly ModelChoice Current = new("sonnet", "Sonnet", "anthropic", "Anthropic");
    private static readonly ModelChoice[] Recent =
    [
        new("opus", "Opus", "anthropic", "Anthropic"), new("gpt", "GPT", "openai", "OpenAI"), new("gemini", "Gemini", "google", "Google"),
    ];

    private static ModelMenuInput Input(bool offline = false, IReadOnlyList<ModelChoice>? favorites = null) =>
        new(Current, Recent, favorites ?? [], ["low", "medium", "high", "xhigh", "max"], "medium", true, true, true, offline);

    private static string Id(ModelMenuItem i) => i.Action switch
    {
        ModelMenuAction.Model m => "model:" + m.Choice.Id,
        ModelMenuAction.MoreModels => "more-models",
        ModelMenuAction.Reasoning r => "reasoning:" + r.Level,
        _ => "fast",
    };

    [Fact]
    public void QuickListOrder()
    {
        var node = ModelMenuModel.Build(Input(favorites: [new ModelChoice("gemini", "Gemini", "google", "Google")]));
        Assert.Equal(["model:sonnet", "model:gemini", "model:opus", "model:gpt", "more-models"], node.Quick.Select(Id));
        Assert.True(node.Quick[0].On);
        Assert.Equal("Google", node.Quick[1].Subtitle);
        Assert.Null(node.Quick[2].Subtitle); // same provider as the current model
        Assert.Equal(["reasoning:none", "reasoning:low", "reasoning:medium", "reasoning:high", "reasoning:xhigh", "reasoning:max"],
            node.Reasoning!.Value.Items.Select(Id));
        Assert.Equal("Medium", node.Reasoning!.Value.Subtitle);
        Assert.Equal("Sonnet · Medium", node.Subtitle);
        Assert.True(node.Fast!.On);
        Assert.Equal(new ModelMenuAction.Fast(false), node.Fast.Action);
    }

    [Fact]
    public void OfflineDimsEveryWrite()
    {
        var node = ModelMenuModel.Build(Input(offline: true));
        Assert.All(node.Quick, i => Assert.True(i.Disabled && i.Subtitle == "Offline"));
        Assert.Equal("Offline", node.Subtitle);
    }

    internal static JsonNode Catalog() => JsonNode.Parse("""
        {"model":"claude-sonnet-5","provider":"anthropic","providers":[
          {"slug":"anthropic","name":"Anthropic","authenticated":true,
           "models":["claude-sonnet-5","claude-opus-4-5-20251101","claude-haiku-4-5"],
           "capabilities":{"claude-sonnet-5":{"fast":true,"reasoning":true,"can_disable_reasoning":true},
                           "claude-haiku-4-5":{"fast":false,"reasoning":false}},
           "pricing":{"claude-sonnet-5":{"input":"$3.00","output":"$15.00","cache":"$0.30","free":false}},
           "usage":{"windows":[{"label":"Session","used_percent":38,"resets_at":"2030-01-01T00:00:00+00:00","scope":"account"},
                               {"label":"Weekly","used_percent":71,"resets_at":"2030-01-05T00:00:00+00:00","scope":"account"}]}},
          {"slug":"openai-codex","name":"ChatGPT or Codex Subscription (Experimental)","aliases":["codex"],"authenticated":true,
           "models":["gpt-5.5","gpt-5.5-fast","gpt-5.5-mini","openai/gpt-5.5-mini"],
           "usage":{"windows":[],"accounts":[{"id":"codex:work","label":"work","state":"ready",
               "windows":[{"label":"Weekly","used_percent":14,"resets_at":"2030-01-06T00:00:00+00:00"}]},
             {"id":"codex:home","label":"home","state":"limited","resets_at":"2030-01-02T00:00:00+00:00","windows":[]}]}},
          {"slug":"openrouter","name":"OpenRouter","authenticated":true,"models":["deepseek/deepseek-v4.1-flash","x-ai/grok-4"],
           "pricing":{"deepseek/deepseek-v4.1-flash":{"input":"$0.10","output":"$0.40","free":false}}},
          {"slug":"nope","name":"Nope","authenticated":false,"models":["x"]}
        ]}
        """)!;

    [Fact]
    public void CatalogParsesAndDescribes()
    {
        var o = ModelOptions.Parse(Catalog());
        Assert.Equal(4, o.Providers.Count);
        Assert.Equal("openai-codex", o.Row("codex")!.Slug);
        Assert.False(o.CapabilitiesOf("anthropic", "claude-haiku-4-5")!.Reasoning);
        var opus = o.Describe("claude-opus-4-5-20251101", "anthropic");
        Assert.Equal(new ModelChoice("claude-opus-4-5-20251101", "Opus 4.5", "anthropic", "Anthropic"), opus);
        Assert.Equal("ChatGPT or Codex Subscription", o.Describe("gpt-5.5", "codex").ProviderName);
        Assert.Equal("$3.00 in · $15.00 out · $0.30 cached", o.Row("anthropic")!.Pricing["claude-sonnet-5"].Line);
    }

    [Fact]
    public void SectionsOneRowPerNameTheCurrentWins()
    {
        var o = ModelOptions.Parse(Catalog());
        var sections = ModelSheetModel.Sections(o.Choices, "", ("openai/gpt-5.5-mini", "openai-codex"));
        var codex = sections.Single(s => s.Provider == "openai-codex");
        Assert.Equal(["gpt-5.5", "gpt-5.5-fast", "openai/gpt-5.5-mini"], codex.Models.Select(m => m.Id));
        Assert.Equal("ChatGPT or Codex Subscription", codex.Title);
        var found = ModelSheetModel.Sections(o.Choices, "opus anthropic", null);
        Assert.Equal("claude-opus-4-5-20251101", Assert.Single(Assert.Single(found).Models).Id);
        var favs = ModelSheetModel.FavoriteRows(o.Choices, ["openrouter::x-ai/grok-4", "gone::m", "anthropic::claude-sonnet-5"]);
        Assert.Equal(["x-ai/grok-4", "claude-sonnet-5"], favs.Select(m => m.Id));
        Assert.Equal("Sonnet 5", Assert.Single(ModelSheetModel.FavoritesFromKeys(["anthropic::claude-sonnet-5", "bad"])).Name);
    }

    [Fact]
    public void PrefsKeepFavoritesRecentsPresetsPerAccount()
    {
        var store = new MemoryStore();
        var prefs = new ModelPrefs("acct", store);
        prefs.ToggleFavorite("anthropic", "opus");
        prefs.ToggleFavorite("openai", "gpt");
        prefs.ToggleFavorite("anthropic", "opus");
        Assert.Equal(["openai::gpt"], prefs.Favorites);
        Assert.Equal("[\"openai::gpt\"]", store.Get("hermes.desktop.favorite-models|acct"));
        Assert.Empty(new ModelPrefs("other", store).Favorites);
        foreach (var id in new[] { "a", "b", "c", "d", "b" }) prefs.Remember(new ModelChoice(id, id.ToUpperInvariant(), "p"));
        Assert.Equal(["b", "d", "c"], prefs.Recents.Select(r => r.Id));
        prefs.SetPreset("p", "a", new ModelPreset(Effort: "high"));
        prefs.SetPreset("p", "a", new ModelPreset(Fast: true));
        Assert.Equal(new ModelPreset("high", true), prefs.Preset("p", "a"));
        prefs.ToggleFavoriteCommand("/Status now");
        Assert.Equal(["/status"], prefs.FavoriteCommands);
    }

    [Fact]
    public void SwitchWordingReadsAsASentence()
    {
        var raw = "!!! LARGE CONTEXT MODEL SWITCH !!!\nThis session holds 180K tokens (providers key prompt caches per model).\n" +
                  "Switching will re-read all of it uncached.\nThreshold: model_switch.warn_tokens\nConfirm only if you mean it.";
        Assert.Equal("This chat holds 180K tokens.\nSwitching will read all of it again without the cache.", ModelSwitchWording.Plain(raw));
        Assert.Equal("Opus costs more.", ModelSwitchWording.Plain("Opus costs more."));
    }
}

public class UsageAndPricesTests
{
    private static readonly DateTimeOffset Now = DateTimeOffset.Parse("2029-12-31T20:00:00+00:00");

    [Fact]
    public void BlocksLeadWithTheChatsProvider()
    {
        var o = ModelOptions.Parse(ModelMenuTests.Catalog());
        var blocks = UsageLimitsModel.Blocks(o, "openai-codex", Now);
        Assert.Equal(["openai-codex.codex:work", "openai-codex.codex:home", "anthropic"], blocks.Select(b => b.Id));
        Assert.Equal("work", blocks[0].Account);
        Assert.Equal("86% left · resets in 5d 4h", blocks[0].Gauges[0].Detail);
        Assert.Equal(["Used up · resets in 1d 4h"], blocks[1].Notes);
        Assert.Equal("Weekly · 29% left", UsageLimitsModel.MenuSubtitle(o, "anthropic", Now));
    }

    [Fact]
    public void PassedResetRefills()
    {
        var o = ModelOptions.Parse(ModelMenuTests.Catalog());
        var later = DateTimeOffset.Parse("2030-01-03T00:00:00+00:00");
        var session = UsageLimitsModel.Blocks(o, "anthropic", later)[0].Gauges[0];
        Assert.Equal(1, session.Left);
        Assert.Equal("refilled", session.Reset);
    }

    [Theory]
    [InlineData(-1, "soon")]
    [InlineData(5, "in 5m")]
    [InlineData(134, "in 2h 14m")]
    [InlineData(120, "in 2h")]
    [InlineData(8820, "in 6d 3h")]
    public void Until(int minutes, string words) => Assert.Equal(words, UsageDates.Until(Now.AddMinutes(minutes), Now));

    [Fact]
    public void BalancesFromTheUsageReport()
    {
        var report = "Usage: 12 calls\n\n📈 Account limits\nProvider: openrouter\nCredits balance: $12.34\n\n📈 Nous credits\n" +
                     "Provider: nous\nTop-up credits: $7.50\nTotal usable: $7.50";
        var b = UsageLimitsModel.ReportedBalances(report);
        Assert.Equal(new UsageBalance.Amount("$12.34"), b["openrouter"]);
        Assert.Equal(new UsageBalance.Amount("$7.50"), b["nous"]);
        Assert.Equal("-$1.23", UsageLimitsModel.Dollars("$-1.23"));
        Assert.Null(UsageLimitsModel.Dollars("$nan"));
        var billing = JsonNode.Parse("""{"logged_in":true,"balance_display":"$3.40","usage":{"available":true,"total_spendable_display":"$7.50"}}""");
        Assert.Equal(new UsageBalance.Amount("$7.50"), UsageLimitsModel.NousBalance(billing));
    }

    [Fact]
    public void ChatRowsAsSessionInfoWritesThem()
    {
        var usage = JsonNode.Parse("""{"total":52114,"input":48210,"output":3904,"context_used":62000,"context_max":200000,"calls":12,"cost_usd":0.4321}""");
        var rows = UsageLimitsModel.ChatRows(usage);
        Assert.Equal(("Context", "31%"), (rows[0].Label, rows[0].Value));
        Assert.Equal("62K of 200K · 138K left", rows[0].Note);
        Assert.Equal(("Tokens", "52.1K"), (rows[1].Label, rows[1].Value));
        Assert.Equal("Calls", rows[2].Label);
        Assert.Equal("$0.43", rows[3].Value);
    }

    [Theory]
    [InlineData(3, "$3.00")]
    [InlineData(0, "free")]
    [InlineData(0.0042, "$0.0042")]
    [InlineData(0.00015, "$0.00015")]
    public void PriceFormat(double perMillion, string text) => Assert.Equal(text, ModelPrice.Format(perMillion));

    [Fact]
    public void PriceSections()
    {
        var o = ModelOptions.Parse(ModelMenuTests.Catalog());
        var sections = ModelPricesModel.Sections(o, null, current: ("x-ai/grok-4", "openrouter"));
        Assert.Equal(["openrouter", "anthropic", "openai-codex"], sections.Select(s => s.Id));
        Assert.Equal("$0.10 in · $0.40 out", sections[0].Rows[0].Detail);
        Assert.Equal(ModelPricesModel.NoPrice, sections[0].Rows[1].Detail);
        Assert.True(sections[0].Rows[1].Current);
        Assert.All(sections[2].Rows, r => Assert.Equal("Included", r.Detail));
        Assert.Equal("Included with your subscription.", sections[2].Footer);
        Assert.Equal("$3.00 in · $15.00 out", ModelPricesModel.MenuSubtitle(o, "claude-sonnet-5", "anthropic"));
        Assert.Equal("Included", ModelPricesModel.MenuSubtitle(o, "gpt-5.5", "codex"));
        var dev = ModelsDevPrices.Parse("""{"xai":{"models":{"grok-4":{"cost":{"input":3,"output":15},"limit":{"context":256000}}}}}""")!;
        Assert.Equal("$3.00 in · $15.00 out", dev.Prices("xai", ["x-ai/grok-4"])["x-ai/grok-4"].Line);
        Assert.Equal(256000, dev.ContextWindow("openrouter-unknown", "grok-4"));
    }

    [Fact]
    public void PromptLibraryKeepsOneOfEachAndUndoes()
    {
        var lib = new PromptLibrary(new MemoryStore());
        lib.Add("Summarise this\nin three lines");
        lib.Add("Translate to French", "French");
        lib.Add("  Summarise this\nin three lines  ", "Summary");
        Assert.Equal(["Summary", "French"], lib.Prompts.Select(p => p.DisplayTitle));
        Assert.Equal("2 saved", lib.MenuSubtitle);
        var gone = lib.Delete([lib.Prompts[0].Id]);
        Assert.Single(lib.Prompts);
        lib.Restore(gone);
        Assert.Equal("Summary", lib.Prompts[0].DisplayTitle);
        Assert.Equal("Summarise this in three lines", lib.Prompts[0].Preview);
        Assert.Equal("in three lines", SavedPrompt.New("", "Summarise this\nin three lines").Preview);
    }
}

public class CommandsTests
{
    internal static CommandsCatalog Catalog() => CommandsCatalog.Parse(JsonNode.Parse("""
        {"categories":[
          {"name":"Session","pairs":[["/new","Start a new session (usage: /new [name])"],["/status","Show session info"],
                                     ["/title","Set a title (usage: /title [name])"],["/resume","Resume"],["/help","Show available commands"]]},
          {"name":"Configuration","pairs":[["/model","Switch model"],["/reasoning","Manage reasoning (usage: /reasoning [level|show|hide])"],
                                           ["/yolo","Toggle YOLO"],["/fast","Toggle fast mode"],["/config","Show current configuration"]]}],
         "pairs":[["/new","x"],["/status","x"],["/release-notes","Draft release notes from the changelog"],["/gif-search","Find a GIF"]],
         "commands":{"/new":{"argument_mode":"text"},"/status":{},"/title":{"argument_mode":"text"},"/model":{"desktop":"hidden"},
                     "/reasoning":{"argument_mode":"options"},"/yolo":{},"/fast":{"argument_mode":"options","desktop":"advanced"},
                     "/config":{"desktop":"terminal"},"/resume":{"argument_mode":"mixed"},"/help":{}},
         "skills":{"/release-notes":{"usage":3,"origin":"local"},"/gif-search":{"usage":0,"origin":"bundled"}}}
        """));

    [Fact]
    public void SectionsAsTheMacListsThem()
    {
        var sections = SlashCatalog.Sections(Catalog());
        Assert.Equal(["Session", "Configuration", "Skills"], sections.Select(s => s.Title));
        Assert.Equal(["/new", "/status", "/title"], sections[0].Rows.Select(r => r.Command));
        Assert.Equal("Start a new chat", sections[0].Rows[0].Description);
        Assert.Equal(["/reasoning", "/yolo"], sections[1].Rows.Select(r => r.Command));
        Assert.Equal("Reasoning effort, or show or hide the reasoning", sections[1].Rows[0].Description);
        Assert.Equal(["/release-notes"], sections[2].Rows.Select(r => r.Command)); // the unused bundled skill is dropped
        Assert.DoesNotContain(SlashCatalog.Sections(Catalog(), isBotChat: true)[0].Rows, r => r.Command == "/title");
        var drawer = SlashCatalog.Sections(Catalog(), forDrawer: true);
        Assert.Contains(drawer.SelectMany(s => s.Rows), r => r.Command == "/model");
        Assert.Contains(drawer.SelectMany(s => s.Rows), r => r.Command == "/help");
    }

    [Fact]
    public void PicksAndConfirmations()
    {
        var c = Catalog();
        Assert.Equal(PickAction.Send, SlashCatalog.PickActionFor(new CommandRow("/status", "", false), c));
        Assert.Equal(PickAction.Insert, SlashCatalog.PickActionFor(new CommandRow("/title", "", false), c));
        Assert.Equal(PickAction.Models, SlashCatalog.PickActionFor(new CommandRow("/model", "", false), c));
        Assert.Equal(PickAction.Insert, SlashCatalog.PickActionFor(new CommandRow("/release-notes", "", true), c));
        Assert.Equal("Turn On YOLO?", SlashCatalog.Confirmation("/yolo", yoloOn: false)!.Title);
        Assert.Null(SlashCatalog.Confirmation("/yolo", yoloOn: true));
        Assert.IsType<SlashSurface.Unavailable>(SlashCatalog.Resolve("/fast", c)!.Surface);
        Assert.Equal("/fast is not shown in the desktop slash palette. Use the relevant desktop control or terminal interface instead.",
            SlashCatalog.UnavailableMessage("advanced", "/fast"));
        Assert.Equal("/new", SlashCatalog.Canonical("/clear", c));
    }

    [Fact]
    public void SearchRanksNamesFirst()
    {
        var sections = SlashCatalog.Sections(Catalog());
        var found = SlashCatalog.Ranked(SlashCatalog.Filter(sections, "st"), "st");
        Assert.Equal("/status", found[0].Rows[0].Command);
        var led = SlashCatalog.FavoritesLeading(sections, sections, ["/yolo"]);
        Assert.Equal("Favorites", led[0].Title);
        Assert.DoesNotContain(led.Skip(1).SelectMany(s => s.Rows), r => r.Command == "/yolo");
    }

    [Fact]
    public void PlainDescriptions()
    {
        Assert.Equal("Set a title", SlashCatalog.PlainDescription("/x", "Set a title (usage: /title [name])"));
        Assert.Equal("Manage tools", SlashCatalog.PlainDescription("/tools2", "Manage tools: /tools [list|disable|enable] [name...]"));
        Assert.Equal("Show the commands list", SlashCatalog.PlainDescription("/help", "whatever"));
    }

    [Fact]
    public void RpcResultsRender()
    {
        Assert.Equal("✓ Compressed\n  10K → 4K", SlashResults.Render(JsonNode.Parse("""{"summary":{"headline":"Compressed","token_line":"10K → 4K"}}""")));
        Assert.Equal("Stopped 2 background processes.", SlashResults.Render(JsonNode.Parse("""{"killed":2}""")));
        Assert.Equal("Saved transcript to /tmp/a.json", SlashResults.Render(JsonNode.Parse("""{"file":"/tmp/a.json"}""")));
        Assert.Equal(("high", "global"), SlashResults.ReasoningParams("high --global"));
        Assert.Null(SlashResults.ReasoningParams("  "));
        Assert.Equal("/release-notes v2", ChatComposer.SkillInvocationText(
            "[IMPORTANT: The user has invoked the \"release-notes\" skill. The full skill content is loaded below.]\n" +
            "The user has provided the following instruction alongside the skill invocation: v2\n\n[Runtime note: x]"));
        Assert.Null(ChatComposer.SkillInvocationText("plain"));
    }
}

public class DrawerTests
{
    [Fact]
    public void Triggers()
    {
        Assert.Equal(new ComposerDrawer.Mode.Slash("/mo"), ComposerDrawer.ModeFor("/mo", 3));
        Assert.Equal(new ComposerDrawer.Mode.Slash("/reasoning h"), ComposerDrawer.ModeFor("/reasoning h", 12));
        Assert.IsType<ComposerDrawer.Mode.Closed>(ComposerDrawer.ModeFor("/usr/local", 10));
        Assert.Equal(new ComposerDrawer.Mode.Skill("/rel", 4, 4), ComposerDrawer.ModeFor("use /rel", 8));
        Assert.Equal(new ComposerDrawer.Mode.At("file:src/", 4, 10), ComposerDrawer.ModeFor("see @file:src/", 14));
        Assert.IsType<ComposerDrawer.Mode.Closed>(ComposerDrawer.ModeFor("a@b.co", 6));
        Assert.True(ComposerDrawer.ModeFor("/st", 3).MarksFirstMatch);
        Assert.False(ComposerDrawer.ModeFor("/", 1).MarksFirstMatch);
    }

    [Fact]
    public void Picks()
    {
        Assert.Equal(new ComposerDrawer.Edit("see @file:src/main.py  more", 22),
            ComposerDrawer.ApplyMention("@file:src/main.py", 4, 7, "see @file:s more"));
        Assert.Equal("see @file:", ComposerDrawer.ApplyMention("@file:", 4, 2, "see @f").Text);
        Assert.Equal("/reasoning ", ComposerDrawer.OptionPrefix("/reasoning h", 11));
        Assert.Equal("/reasoning ", ComposerDrawer.OptionPrefix("/reasoning h", null));
        Assert.True(ComposerDrawer.ApplyOption("/a ", "b ").KeepOpen);
    }

    [Fact]
    public void SlashDrawerRows()
    {
        var c = CommandsTests.Catalog();
        var bare = ComposerDrawer.SlashSections("/", c, false, false, false, null, [], ["/yolo"])!;
        Assert.Equal("Favorites", bare[0].Title);
        Assert.Equal("fav.cmd./yolo", bare[0].Rows[0].Id);
        var typed = ComposerDrawer.SlashSections("/st", c, false, false, false, null, [])!;
        Assert.Equal("/status", typed[0].Rows[0].Title);
        Assert.Equal(ComposerDrawer.LoadingCommands, ComposerDrawer.SlashSections("/", null, true, false, false, null, [])![0].Rows[0].Title);
        var remote = ComposerDrawer.ParseAnswer(JsonNode.Parse("""{"items":[{"text":"high","display":"high","meta":""},{"text":"hide","meta":"Hide reasoning"}],"replace_from":11}"""), "/reasoning h");
        var options = ComposerDrawer.SlashSections("/reasoning h", c, false, false, false, remote, [])!;
        Assert.Equal(new ComposerDrawer.RowAction.Option("/reasoning ", "high"), options[0].Rows[0].Action);
        var empty = ComposerDrawer.SlashSections("/", new CommandsCatalog(), false, false, false, null, [])!;
        Assert.Equal(ComposerDrawer.NoCommands, empty[0].Rows[0].Title);
    }

    [Fact]
    public void AtDrawerRows()
    {
        var bots = new[] { new ComposerDrawer.BotEntry("default", "Hermes"), new ComposerDrawer.BotEntry("ivy", "Ivy") };
        var start = ComposerDrawer.AtSections("", 0, 1, bots, "ivy", null, false, false, false, null);
        Assert.Equal("@file:", start[0].Rows[0].Title);
        Assert.Equal("@hermes", Assert.Single(start[1].Rows).Title);
        var remote = ComposerDrawer.ParseAnswer(JsonNode.Parse("""{"items":[{"text":"@file:src/main.py","display":"src/main.py"},{"text":"@file:.env"}]}"""), "@file:");
        var files = ComposerDrawer.AtSections("file:", 0, 6, bots, "default", remote, false, false, false, null);
        var row = Assert.Single(files.SelectMany(s => s.Rows));
        Assert.Equal(("main.py", "src/"), (row.Title, row.Parent));
        Assert.Equal(ComposerDrawer.FolderMissing, ComposerDrawer.AtSections("file:", 0, 6, bots, "default", null, true, false, true, null)[0].Rows[0].Title);
    }

    [Fact]
    public void GateDropsStaleAnswers()
    {
        var gate = new CompletionGate();
        gate.Want("slash|/r");
        Assert.Equal("slash|/r", gate.Next());
        gate.Want("slash|/reasoning h");
        Assert.Null(gate.Next());
        Assert.False(gate.Finished("slash|/r"));
        Assert.Equal("slash|/reasoning h", gate.Next());
        Assert.True(gate.Finished("slash|/reasoning h"));
    }
}

/// The queue's state machine against a stand-in chat.
public class QueueTests
{
    private sealed class FakeHost : IQueueHost
    {
        public bool Busy { get; set; }
        public bool CanSteerNow => Busy && !Stopping;
        public bool Stopping { get; set; }
        public SendOutcome Outcome { get; set; } = SendOutcome.Accepted;
        public SteerOutcome Steer { get; set; } = SteerOutcome.Redirected;
        public bool SteerUnsupported { get; set; }
        public List<(string Text, bool Queued)> Sent { get; } = [];
        public List<string> Steered { get; } = [];
        public int Stops { get; private set; }
        public ComposerQueue? Queue { get; set; }

        public Task<SendOutcome> SendAsync(QueuedMessage message, bool queued)
        {
            lock (Sent) Sent.Add((message.Text, queued));
            Busy = Outcome == SendOutcome.Accepted;
            return Task.FromResult(Outcome);
        }

        public void Stop()
        {
            Stops++;
            Busy = false;
            Queue?.Stopped();
        }

        public string BeginSteer(string shown) => "local-" + shown;

        public Task<(SteerOutcome, bool)> FinishSteerAsync(string localId, string text)
        {
            Steered.Add(text);
            return Task.FromResult((Steer, SteerUnsupported));
        }
    }

    private static (FakeHost, ComposerQueue) Make()
    {
        var host = new FakeHost();
        var q = new ComposerQueue(host) { DrainFallback = TimeSpan.FromMilliseconds(30) };
        host.Queue = q;
        return (host, q);
    }

    private static async Task Until(Func<bool> condition)
    {
        var until = DateTime.UtcNow.AddSeconds(10); // generous: the Windows build machine is slower than a Mac
        while (!condition() && DateTime.UtcNow < until) await Task.Delay(10);
        Assert.True(condition());
    }

    [Fact]
    public async Task IdleSendGoesNowAndBusyQueueWaitsForTheTurnsEnd()
    {
        var (host, q) = Make();
        q.Send("first");
        Assert.Equal([("first", false)], host.Sent);
        q.QueuesNextSend = true; // Ctrl+Enter
        q.Send("second");
        q.QueuesNextSend = true;
        q.Send("third");
        Assert.Equal(["second", "third"], q.Items.Select(i => i.Text));
        host.Busy = false;
        q.TurnEnded(confirmed: false);
        await Until(() => host.Sent.Count == 2);
        Assert.Equal(("second", true), host.Sent[1]);
        Assert.Equal(["third"], q.Items.Select(i => i.Text));
        host.Busy = false;
        q.TurnEnded(confirmed: true);
        await Until(() => host.Sent.Count == 3);
        Assert.Empty(q.Items);
    }

    [Fact]
    public async Task TypingWhileARunsSteersIntoIt()
    {
        var (host, q) = Make();
        host.Busy = true;
        q.Send("also check the tests");
        await Until(() => host.Steered.Count == 1);
        Assert.Empty(host.Sent);
        Assert.Empty(q.Items);
        q.Send("/status"); // a slash command never steers
        Assert.Equal(["/status"], q.Items.Select(i => i.Text));
    }

    [Fact]
    public async Task ASteerTurnedDownJoinsTheQueueWithANotice()
    {
        var (host, q) = Make();
        host.Busy = true;
        host.Steer = SteerOutcome.Failed;
        host.SteerUnsupported = true;
        string? notice = null;
        q.Notice += n => notice = n;
        q.Send("fix it");
        // The turned-down steer runs on its own task: the row joins the queue (Changed), then the notice is told. Wait
        // for both, or the row can show a moment before the notice and the check below reads null.
        await Until(() => q.Items.Count == 1 && Volatile.Read(ref notice) != null);
        Assert.Equal(SteerRule.FailedNotice, notice);
        Assert.True(q.RedirectUnsupported);
        q.Send("more"); // no longer steers
        Assert.Equal(["fix it", "more"], q.Items.Select(i => i.Text));
        Assert.False(q.CanSteer(q.Items[0].Id));
    }

    [Fact]
    public async Task StopParksResumeAndSendNowUnpark()
    {
        var (host, q) = Make();
        host.Busy = true;
        q.QueuesNextSend = true;
        q.Send("a");
        q.QueuesNextSend = true;
        q.Send("b");
        host.Stop();
        Assert.True(q.Parked);
        q.TurnEnded(true);
        await Task.Delay(60);
        Assert.Empty(host.Sent);
        q.Resume();
        Assert.False(q.Parked);
        Assert.Equal(("a", true), Assert.Single(host.Sent));
        // Busy again (a sent): Stop and Send on b stops the reply and sends it.
        q.SendNow(q.Items[0].Id);
        Assert.Equal(2, host.Stops);
        await Until(() => host.Sent.Count == 2);
        Assert.Equal(("b", true), host.Sent[1]);
    }

    [Fact]
    public async Task SendNowWhileBusySteersASteerableRow()
    {
        var (host, q) = Make();
        host.Busy = true;
        q.QueuesNextSend = true;
        q.Send("steer me");
        var id = q.Items[0].Id;
        Assert.True(q.CanSteer(id));
        Assert.True(q.CanSendNow(q.Items[0]));
        await q.SendNowFromCard(id);
        Assert.Equal(["steer me"], host.Steered);
        Assert.Empty(q.Items);
        Assert.Equal(0, host.Stops);
    }

    [Fact]
    public async Task ARefusedSendParksTheRest()
    {
        var (host, q) = Make();
        host.Busy = true;
        q.QueuesNextSend = true;
        q.Send("a");
        q.QueuesNextSend = true;
        q.Send("b");
        host.Busy = false;
        host.Outcome = SendOutcome.Refused;
        q.TurnEnded(true);
        await Until(() => q.Parked);
        Assert.Equal(["b"], q.Items.Select(i => i.Text));
        // A fresh send un-parks: it goes first while idle, the parked one follows its reply.
        host.Outcome = SendOutcome.Accepted;
        q.Send("c");
        Assert.False(q.Parked);
    }

    [Fact]
    public async Task AnEditHoldsTheRowAndSaveKeepsItsPlace()
    {
        var (host, q) = Make();
        host.Busy = true;
        q.QueuesNextSend = true;
        q.Send("tpyo");
        q.QueuesNextSend = true;
        q.Send("next");
        var id = q.Items[0].Id;
        Assert.Equal("tpyo", q.BeginEdit(id));
        Assert.Null(q.BeginEdit(q.Items[1].Id)); // one edit at a time
        host.Busy = false;
        q.TurnEnded(true);
        await Task.Delay(60);
        Assert.Empty(host.Sent); // held
        Assert.True(q.SaveEdit(id, "typo"));
        await Until(() => host.Sent.Count == 1);
        Assert.Equal(("typo", true), host.Sent[0]);
        Assert.Equal(["next"], q.Items.Select(i => i.Text));
    }

    [Fact]
    public void DeleteAndRemove()
    {
        var (host, q) = Make();
        host.Busy = true;
        q.QueuesNextSend = true;
        q.Send("x");
        q.EnqueueHidden("internal prompt", null);
        Assert.Equal(("Continue toward goal", true), QueueWords.RowWords(q.Items[1]));
        Assert.Null(q.Remove(q.Items[1].Id)); // a hidden continuation never reaches the field
        Assert.Equal("x", q.Remove(q.Items[0].Id));
        Assert.Empty(q.Items);
        Assert.Equal(EmptyReturn.Nothing, q.EmptyReturnNow());
    }
}

public class SteerTranscriptTests
{

    [Fact]
    public void ASteerSealsTheLiveBubbleAndTheReplyGoesOnBelowIt()
    {
        var t = new Transcript();
        t.AddLocalUser("start");
        t.Apply(new Rpc.RpcEvent("message.delta", "rt", JsonNode.Parse("""{"text":"Working"}"""), null));
        var steer = t.BeginSteer("also this");
        t.Apply(new Rpc.RpcEvent("message.delta", "rt", JsonNode.Parse("""{"text":"Done"}"""), null));
        Assert.Equal(["start", "Working", "also this", "Done"], t.Messages.Select(m => m.Text));
        t.SteerTaken(steer);
        Assert.False(t.Messages[2].IsPending);
    }

    [Fact]
    public void AFailedSteerUnsealsAndANextTurnSteerMovesToTheEnd()
    {
        var t = new Transcript();
        t.AddLocalUser("start");
        t.Apply(new Rpc.RpcEvent("message.delta", "rt", JsonNode.Parse("""{"text":"Work"}"""), null));
        var failed = t.BeginSteer("nope");
        t.SteerFailed(failed);
        t.Apply(new Rpc.RpcEvent("message.delta", "rt", JsonNode.Parse("""{"text":"ing"}"""), null));
        Assert.Equal(["start", "Working"], t.Messages.Select(m => m.Text));
        var next = t.BeginSteer("later");
        t.Apply(new Rpc.RpcEvent("message.delta", "rt", JsonNode.Parse("""{"text":" more"}"""), null));
        t.SteerNextTurn(next);
        Assert.Equal("later", t.Messages[^1].Text);
    }

    [Fact]
    public void LocalRowsSurviveAHistoryRead()
    {
        var t = new Transcript();
        var id = t.AddLocal(Role.System, new SlashOutputPart("/status", "Session ok"));
        t.ReplaceWithHistory([]);
        Assert.Equal(id, Assert.Single(t.Messages).Id);
        t.ReplaceLocal(id, null);
        Assert.Empty(t.Messages);
    }
}
