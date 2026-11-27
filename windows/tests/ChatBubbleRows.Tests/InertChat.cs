using Hermes.Core.Model;
using Hermes.Core.Settings;
using Hermes.Core.Shell;
using Hermes.Core.Transcripts;
using HermesHQ.Features.Settings;
using HermesHQ.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.Settings
{
    internal static partial class ThemeService
    {
        public static ThemeState State = ThemeState.Default;
        public static bool SystemHighContrast, Dark, AccessibilityTextSize;
        // The production Map supplies the actual normal picks. Windows supplies these two
        // synthetic, opaque contrast palettes; the app's actual HQ* mapping chooses their entries.
        public static Brush Resolve(string key)
        {
            if (SystemHighContrast && HighContrastWalkProof.SystemColourFor(key) is { } element)
            {
                var c = element switch { "WindowText" => Dark ? 0xffffffu : 0u, "Window" => Dark ? 0u : 0xffffffu,
                    "Highlight" => 0x008080u, "HighlightText" => 0xffff00u, _ => 0x808080u };
                return new Brush(Rgba.Hex(c), element);
            }
            var pick = Map.FirstOrDefault(p => p.Key == key).Pick;
            if (pick == null && key.StartsWith("HQ", StringComparison.Ordinal)) throw new KeyNotFoundException(key);
            return new(pick?.Invoke(ThemeResolver.Resolve(State).Tokens(Dark)) ?? Rgba.Clear);
        }
        public static void ContrastWords(FrameworkElement e) { if (e is TextBlock t) t.BackplateDisabled = SystemHighContrast; }
    }
}
namespace HermesHQ { internal static class ThemeBrushes { public static Brush Get(string key) => ThemeService.Resolve(key); } }
namespace HermesHQ.Features.Bots
{
    // No bot lookup or account exists. Exercise the renderer's ordinary seeded head fallback.
    internal class ListsHub { public static ListsHub? Current => null; public ListsHub Bots => this; public ListsHub? Bot(string key) => null; public object? Model => null; }
}
namespace HermesHQ.ViewModels
{
    internal sealed class MemoryPrefs : IPreferences
    {
        private readonly Dictionary<string, string?> _values = [];
        public string? Get(string key) => _values.GetValueOrDefault(key);
        public void Set(string key, string? value) => _values[key] = value;
    }
    public sealed partial class ChatViewModel
    {
        public bool Busy => true;
        public Session Session { get; } = new();
        public string BotName => "Ivy";
        private readonly HashSet<string> _revealed = [];
        private Func<Session, bool>? ShowReasoning => null;
        private Func<Session, ChatMessage, IReadOnlyDictionary<int, double>?>? ReasoningSeconds => null;
        public List<MessageDisplay> Project(IReadOnlyList<ChatMessage> history) => Displays(history);
    }
    public sealed class Session
    {
        public List<ChatMessage> Messages { get; } = [];
        public bool Busy => false;
        public bool ExternalWorking => false;
        public object? WaitingForOwner => null;
        public double? TurnSeconds(ChatMessage prompt) => null;
    }
}
namespace HermesHQ.Controls
{
    internal class BotHead : FrameworkElement { public object? Bot { get; set; } public string? DisplayName { get; set; } }

    internal static class MarkdownRenderer { public const string InlineTableTag = "chat.markdown.inline-table"; }
    internal static class ChatExtensions
    {
        public static readonly Dictionary<string, Func<ToolCall, ChatMessage, FrameworkElement>> ToolRenderers = [];
        public static readonly Dictionary<Type, Func<ChatPart, ChatMessage, FrameworkElement>> PartRenderers = [];
    }
    internal partial class MessageView
    {
        private const double Side = ChatVisualTokens.Side, Column = ChatVisualTokens.BubbleMax;
        private static ChatVisualTokens.TypeRamp Type => ChatVisualTokens.Type(ThemeService.State.DesktopLook);
        private readonly List<FrameworkElement> _findable = [];
        public IReadOnlyList<FrameworkElement> Findable => _findable;
        public FrameworkElement[] Draw(MessageItem item) => item.Message.Role == Role.User ? [UserBubble(item, _findable)] : [.. ReplyRows(item)];
        private static T Res<T>(string key) => (T)(object)(typeof(T) == typeof(Brush) ? (object)ThemeService.Resolve(key) : new FontFamily());
        private static FrameworkElement StepLine(MessageItem m, StepsRow r) => new() { Id = "steps" };
        private static FrameworkElement ThoughtLine(MessageItem m, ThoughtRow r) => new() { Id = "thought" };
        private static FrameworkElement ErrorCardView(MessageItem m, string error) => new() { Id = "error" };
        private static FrameworkElement Caption(string text) => new() { Id = "caption" };
        private static FrameworkElement StoppedEarly(MessageItem m, StoppedEarlyRow r) => new() { Id = "stopped" };
        private static FrameworkElement FilesChanged(MessageItem m, IReadOnlyList<ChangedFile> files) => new() { Id = "files" };
        private static FrameworkElement ReplyActions(MessageItem m, ChatViewModel o) => new() { Id = "actions" };
    }
}
namespace HermesHQ.Features.Transcript
{
    using HermesHQ.Controls;
    internal static class UndeliveredActions { public static FrameworkElement CheckLine(MessageItem i, Brush ink) => new(); }
    internal static class ReplyWords
    {
        // Markdown/links themselves are tested elsewhere. Keep their search root, table tag,
        // pending/settled arguments and inline plain-mode time observable without loading controls.
        public static void Render(string markdown, Panel into, string? trailing, bool settled, (ChatViewModel?, string)? page)
        {
            into.Children.Add(new RichTextBlock { Trailing = trailing, Id = settled ? "settled-words" : "streaming-words" });
            if (markdown.Contains('|')) into.Children.Add(new FrameworkElement { Tag = MarkdownRenderer.InlineTableTag, Id = "table" });
        }
    }
}
