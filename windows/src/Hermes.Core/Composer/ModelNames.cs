using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Hermes.Core.Composer;

/// Model and provider names as people read them (HermesKit/Model/ModelNames.swift; spec 1x §2.2). Pure.
public static class ModelNames
{
    /// Hermes' reasoning levels in ascending order. `none` is thinking off, not a level.
    public static readonly string[] ReasoningEfforts = ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"];
    public static readonly string[] ReasoningEffortValues = ["none", .. ReasoningEfforts];
    public const string DefaultReasoningEffort = "medium";

    private static Regex Rx(string pattern, bool ignoreCase = false) =>
        new(pattern, ignoreCase ? RegexOptions.IgnoreCase | RegexOptions.CultureInvariant : RegexOptions.CultureInvariant);

    /// A profile's configured effort as a `config.set reasoning` value: false/"false"/"disabled" → "none".
    public static string? NormalizeConfigEffort(JsonNode? value)
    {
        if (value is JsonValue v && v.TryGetValue(out bool b) && !b) return "none";
        if (value is not JsonValue sv || !sv.TryGetValue(out string? raw)) return null;
        var effort = raw.Trim().ToLowerInvariant();
        if (effort.Length == 0) return null;
        return effort is "false" or "disabled" ? "none" : effort;
    }

    /// Text after the last `/`.
    public static string ModelBaseId(string model)
    {
        var t = model.Trim();
        var slash = t.LastIndexOf('/');
        return slash < 0 ? t : t[(slash + 1)..];
    }

    private static readonly (Regex, string)[] VariantTags =
    [
        (Rx("-fast$", true), "Fast"), (Rx("-flash$", true), "Flash"), (Rx("-thinking$", true), "Thinking"),
        (Rx("-preview$", true), "Preview"), (Rx("-latest$", true), "Latest"),
    ];
    private static readonly Regex Quant = Rx(@"-(?:UD-)?(Q\d(?:_[A-Z0-9]+)*|IQ\d(?:_[A-Z0-9]+)*|F16|BF16)$", true);
    private static readonly Regex InstructTail = Rx(@"-(?:Instruct|Chat)(?:-\d{4})?$", true);
    private static readonly Regex ContextWindow = Rx(@"\[(\d+[mk])\]$", true);
    private static readonly Regex DatePin = Rx(@"-\d{8}$");
    private static readonly Regex WordStart = Rx(@"\b\w");
    private static readonly Regex ParameterCount = Rx(@"\b(a?)(\d+(?:\.\d+)?)b\b", true);
    private static readonly (Regex, string)[] VendorCasing =
    [
        (Rx(@"\bDeepseek\b"), "DeepSeek"), (Rx(@"\bGlm\b"), "GLM"), (Rx(@"\bMinimax\b"), "MiniMax"),
        (Rx(@"\bOpenai\b"), "OpenAI"), (Rx(@"\bErnie\b"), "ERNIE"), (Rx(@"\bMimo\b"), "MiMo"), (Rx(@"\bBge\b"), "BGE"),
        (Rx(@"\bVl\b"), "VL"), (Rx(@"\bIt\b"), "IT"), (Rx(@"\bFp8\b"), "FP8"), (Rx(@"\bAi\b"), "AI"),
    ];
    private static readonly Regex ClaudePrefix = Rx("^claude-", true);
    private static readonly Regex DigitHyphenDigit = Rx(@"(\d)-(?=\d)");
    private static readonly Regex GptPrefix = Rx("^gpt-", true);
    private static readonly Regex GeminiPrefix = Rx("^gemini-", true);

    /// Upper-cases the first character of every word (JS `\b\w`), then trims.
    public static string TitleCase(string text) => WordStart.Replace(text, m => m.Value.ToUpperInvariant()).Trim();

    private static string ApplyVendorCasing(string text)
    {
        var cased = ParameterCount.Replace(text, m => $"{m.Groups[1].Value.ToUpperInvariant()}{m.Groups[2].Value}B");
        foreach (var (pattern, replacement) in VendorCasing) cased = pattern.Replace(cased, replacement);
        return cased;
    }

    private static string PrettifyBase(string b)
    {
        if (ClaudePrefix.IsMatch(b))
        {
            var s = ClaudePrefix.Replace(b, "");
            s = DigitHyphenDigit.Replace(s, "$1.");
            return ApplyVendorCasing(TitleCase(s.Replace('-', ' ')));
        }
        if (GptPrefix.IsMatch(b)) return GptPrefix.Replace(b, "GPT-");
        if (GeminiPrefix.IsMatch(b)) return ApplyVendorCasing(TitleCase(GeminiPrefix.Replace(b, "Gemini ").Replace('-', ' ')));
        return ApplyVendorCasing(TitleCase(b.Replace('-', ' ')));
    }

    /// A variant tag and a GGUF quant, in either order.
    public static (string Base, string Variant, string Quant) SplitTrailingTags(string input)
    {
        string b = input, variant = "", quant = "";
        var progress = true;
        while (progress)
        {
            progress = false;
            if (variant.Length == 0)
                foreach (var (pattern, label) in VariantTags)
                {
                    if (!pattern.IsMatch(b)) continue;
                    variant = label;
                    b = pattern.Replace(b, "");
                    progress = true;
                    break;
                }
            if (quant.Length == 0 && Quant.Match(b) is { Success: true } m)
            {
                quant = m.Groups[1].Value.Split('_')[0].ToUpperInvariant();
                b = b[..^m.Value.Length];
                b = InstructTail.Replace(b, "");
                progress = true;
            }
        }
        return (b, variant, quant);
    }

    private static readonly Regex FineTune = Rx(@"^ft:([^:]+):");
    private static readonly Regex RouteSuffix = Rx(@":(free|beta|extended|nitro|floor|online|thinking|exacto)$", true);
    private static readonly Regex BedrockVendor = Rx(@"^(?:(?:us|eu|apac|ap|au|ca|jp|global|us-gov)\.)?(?:anthropic|amazon|meta|cohere|ai21|mistral|deepseek|qwen|openai|writer|twelvelabs|stability|luma|minimax|moonshot|moonshotai|google|nvidia)\.", true);
    private static readonly Regex BedrockVersion = Rx(@"-v\d+(?::\d+)?$", true);
    private static readonly Regex VertexPin = Rx(@"@(?:\d{8}|\d{3}|latest|default)$", true);
    private static readonly Regex DashedDate = Rx(@"-\d{4}-\d{2}-\d{2}$");
    private static readonly Regex GgufWord = Rx("-GGUF$", true);
    private static readonly Regex ColonQuant = Rx(@":(?=(?:UD-)?(?:Q\d(?:_[A-Z0-9]+)*|IQ\d(?:_[A-Z0-9]+)*|F16|BF16)$)", true);

    private static (string Id, List<string> Tags) Unwrap(string id)
    {
        var tags = new List<string>();
        if (FineTune.Match(id) is { Success: true } ft)
        {
            id = ft.Groups[1].Value;
            tags.Add("Fine-tuned");
        }
        if (RouteSuffix.Match(id) is { Success: true } route)
        {
            id = id[..^route.Value.Length];
            var word = route.Groups[1].Value;
            tags.Add(word[..1].ToUpperInvariant() + word[1..].ToLowerInvariant());
        }
        if (BedrockVendor.IsMatch(id)) id = BedrockVersion.Replace(BedrockVendor.Replace(id, ""), "");
        id = VertexPin.Replace(id, "");
        id = ColonQuant.Replace(id, "-");
        return (id, tags);
    }

    /// A clean display name plus an optional tag ("Fast", "Q4", "1M").
    public static (string Name, string Tag) ModelDisplayParts(string model)
    {
        var unwrapped = Unwrap(ModelBaseId(model));
        var (b, variant, quant) = SplitTrailingTags(unwrapped.Id);
        var tags = new List<string>();
        if (variant.Length > 0) tags.Add(variant);
        if (quant.Length > 0) tags.Add(quant);
        if (ContextWindow.Match(b) is { Success: true } window)
        {
            tags.Add(window.Groups[1].Value.ToUpperInvariant());
            b = b[..^window.Value.Length];
        }
        tags.AddRange(unwrapped.Tags.Where(t => !tags.Contains(t)));
        b = DatePin.Replace(b, "");
        b = DashedDate.Replace(b, "");
        b = GgufWord.Replace(b, "");
        var pretty = PrettifyBase(b);
        var trimmed = model.Trim();
        return (pretty.Length == 0 ? (trimmed.Length == 0 ? "No model" : trimmed) : pretty, string.Join(" ", tags));
    }

    /// "Opus 4.5", "GPT-5.5 Fast", "Sonnet 5 1M"; "No model" for "".
    public static string DisplayModelName(string model)
    {
        var parts = ModelDisplayParts(model);
        return parts.Tag.Length == 0 ? parts.Name : $"{parts.Name} {parts.Tag}";
    }

    /// The variant tag a model id carries (Fast, Flash, Thinking, Preview, Latest).
    public static string ModelVariantTag(string model) => SplitTrailingTags(ModelBaseId(model)).Variant;

    /// "GPT-5.5 · Fast" — the switch notices' label.
    public static string FormatModelPillLabel(string model, bool fastMode = false)
    {
        var name = ModelDisplayParts(model).Name;
        var blank = model.Trim().Length == 0;
        var tag = blank ? "" : fastMode ? "Fast" : ModelVariantTag(model);
        return tag.Length == 0 ? name : $"{name} · {tag}";
    }

    // ------------------------------------------------------------------ providers

    public static readonly Dictionary<string, string> ProviderDisplayNames = new()
    {
        ["anthropic"] = "Anthropic Account",
        ["claude-code"] = "Anthropic OAuth: Required Extra Usage Credits to Use Subscription",
        ["minimax-oauth"] = "MiniMax", ["nous"] = "Nous Portal", ["openai-codex"] = "ChatGPT or Codex Subscription",
        ["qwen-oauth"] = "Qwen Code", ["xai"] = "xAI", ["xai-oauth"] = "xAI Grok",
    };

    public static string ProviderDisplayName(string provider)
    {
        var t = provider.Trim();
        return ProviderDisplayNames.TryGetValue(t.ToLowerInvariant(), out var n) ? n : t;
    }

    /// Hermes' own names for its providers (hermes_cli/models_catalog_static.py CANONICAL_PROVIDERS).
    public static readonly Dictionary<string, string> HermesProviderNames = new()
    {
        ["nous"] = "Nous Portal", ["fireworks"] = "Fireworks AI", ["openrouter"] = "OpenRouter", ["moa"] = "Mixture of Agents",
        ["novita"] = "NovitaAI", ["lmstudio"] = "LM Studio", ["anthropic"] = "Anthropic",
        ["openai-codex"] = "ChatGPT or Codex Subscription", ["openai-api"] = "OpenAI API", ["openai"] = "OpenAI",
        ["alibaba"] = "Qwen Cloud", ["xai-oauth"] = "xAI Grok OAuth", ["xiaomi"] = "Xiaomi MiMo",
        ["tencent-tokenhub"] = "Tencent TokenHub", ["tencent-tokenplan"] = "Tencent TokenPlan", ["nvidia"] = "NVIDIA NIM",
        ["copilot"] = "GitHub Copilot", ["copilot-acp"] = "GitHub Copilot ACP", ["huggingface"] = "Hugging Face",
        ["gemini"] = "Google AI Studio", ["vertex"] = "Google Vertex AI", ["deepseek"] = "DeepSeek", ["xai"] = "xAI",
        ["zai"] = "Z.AI / GLM", ["kimi-coding"] = "Kimi / Kimi Coding Plan", ["kimi-coding-cn"] = "Kimi / Moonshot",
        ["stepfun"] = "StepFun Step Plan", ["minimax"] = "MiniMax", ["minimax-oauth"] = "MiniMax", ["minimax-cn"] = "MiniMax",
        ["ollama-cloud"] = "Ollama Cloud", ["ollama"] = "Ollama", ["arcee"] = "Arcee AI", ["gmi"] = "GMI Cloud",
        ["kilocode"] = "Kilo Code", ["opencode-zen"] = "OpenCode Zen", ["opencode-go"] = "OpenCode Go",
        ["bedrock"] = "AWS Bedrock", ["azure-foundry"] = "Azure Foundry", ["ai-gateway"] = "Vercel AI Gateway",
        ["qwen-oauth"] = "Qwen OAuth", ["claude-code"] = "Claude Code", ["custom"] = "Custom endpoint",
    };

    private static readonly Regex BracketGroup = Rx(@"\s*[(\[][^)\]]*[)\]]\s*");
    private static readonly Regex SdkWord = Rx(@"\b(?:Direct)?SDK\b", true);
    private static readonly Regex Spaces = Rx(@"\s+");
    private static readonly Regex BareSlug = Rx(@"^[A-Za-z0-9]+(?:[_-]+[A-Za-z0-9]+)+$");
    private static readonly HashSet<string> SlugNotes = ["sdk", "directsdk", "experimental"];

    /// The catalog's provider name without its build notes: "Claude Subscription DirectSDK (Experimental)" →
    /// "Claude Subscription"; a bare slug reads as Hermes names it, else as its words without the notes.
    public static string PlainProviderName(string name)
    {
        var bare = name.Trim();
        if (BareSlug.IsMatch(bare))
        {
            if (HermesProviderNames.TryGetValue(bare.ToLowerInvariant(), out var known)) return known;
            var words = bare.Split('-', '_').Where(w => w.Length > 0).ToList();
            var kept = words.Where(w => !SlugNotes.Contains(w.ToLowerInvariant())).ToList();
            return ApplyVendorCasing(TitleCase(string.Join(" ", kept.Count == 0 ? words : kept)));
        }
        var plain = BracketGroup.Replace(name, " ");
        plain = SdkWord.Replace(plain, " ");
        plain = Spaces.Replace(plain, " ").Trim();
        return plain.Length == 0 ? name.Trim() : plain;
    }

    // ------------------------------------------------------------------ reasoning

    private static readonly Dictionary<string, string> EffortNames = new()
    {
        ["none"] = "Off", ["minimal"] = "Minimal", ["low"] = "Low", ["medium"] = "Medium", ["high"] = "High",
        ["xhigh"] = "Extra High", ["max"] = "Max", ["ultra"] = "Ultra",
    };
    private static readonly Regex Separators = Rx("[_-]+");

    /// "Off", "Extra High"; anything else in words ("extra_deep" → "Extra Deep").
    public static string EffortLabel(string level) =>
        EffortNames.TryGetValue(level, out var known) ? known
            : WordStart.Replace(Separators.Replace(level, " "), m => m.Value.ToUpperInvariant());

    /// Which pair a picker marks current: the chat's own complete pair, else the catalog's, else whichever parts exist.
    public static (string Model, string Provider) CurrentPickerSelection((string Model, string Provider) store,
        (string Model, string Provider)? options)
    {
        if (store.Model.Length > 0 && store.Provider.Length > 0) return store;
        if (options is { } o && o.Model.Length > 0 && o.Provider.Length > 0) return o;
        return (store.Model.Length == 0 ? options?.Model ?? "" : store.Model,
            store.Provider.Length == 0 ? options?.Provider ?? "" : store.Provider);
    }
}
