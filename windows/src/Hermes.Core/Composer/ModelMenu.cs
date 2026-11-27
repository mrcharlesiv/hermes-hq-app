using Hermes.Core.Net;

namespace Hermes.Core.Composer;

/// The open chat's model, reasoning and Fast as the gateway last reported them, with this PC's optimistic picks
/// (HermesKit/Contracts+menus.swift ChatModelState; spec 1x §2.1). "" = unknown.
public sealed record ChatModelState(string Model = "", string Provider = "", string ReasoningEffort = "", bool Fast = false,
    bool Yolo = false, string ApprovalMode = "");

/// What the ⋯ › Model row and the Models list's settings strip are built from (`TitleMenuInput`).
public sealed record ModelMenuInput(ModelChoice Current, IReadOnlyList<ModelChoice> Recents, IReadOnlyList<ModelChoice> Favorites,
    IReadOnlyList<string> ReasoningLevels, string ReasoningCurrent, bool CanTurnOff, bool FastSupported, bool FastOn, bool Offline,
    string ApprovalMode = "", bool Yolo = false);

public abstract record ModelMenuAction
{
    public sealed record Model(ModelChoice Choice) : ModelMenuAction;
    public sealed record MoreModels : ModelMenuAction;
    public sealed record Reasoning(string Level) : ModelMenuAction;
    public sealed record Fast(bool On) : ModelMenuAction;
}

public sealed record ModelMenuItem(ModelMenuAction Action, string Title, string? Subtitle = null, bool On = false, bool Disabled = false);

/// "Model ▸" with its "Model for Next Reply" section, Reasoning ▸ and Fast (HermesKit/Chat/ModelMenuModel.swift).
public sealed record ModelMenuNode(string Subtitle, IReadOnlyList<ModelMenuItem> Quick,
    (string Subtitle, IReadOnlyList<ModelMenuItem> Items)? Reasoning, ModelMenuItem? Fast)
{
    public string Title => "Model";
    public string QuickTitle => "Model for Next Reply";
}

public static class ModelMenuModel
{
    public const int FavoritesShown = 5;
    public const int RecentsShown = 2;

    public static ModelMenuNode Build(ModelMenuInput input)
    {
        ModelMenuItem Write(ModelMenuItem item) => input.Offline ? item with { Disabled = true, Subtitle = "Offline" } : item;
        var seen = new HashSet<string> { input.Current.Id };
        List<ModelChoice> Fresh(IEnumerable<ModelChoice> models, int most)
        {
            var list = new List<ModelChoice>();
            foreach (var m in models)
            {
                if (list.Count >= most) break;
                if (seen.Add(m.Id)) list.Add(m);
            }
            return list;
        }
        var favorites = Fresh(input.Favorites, FavoritesShown);
        var recents = Fresh(input.Recents, RecentsShown);
        var quick = new List<ModelMenuItem> { Write(new ModelMenuItem(new ModelMenuAction.Model(input.Current), input.Current.Name, On: true)) };
        foreach (var row in favorites.Concat(recents))
        {
            var subtitle = row.Provider != input.Current.Provider ? row.ProviderName ?? row.Provider : null;
            quick.Add(Write(new ModelMenuItem(new ModelMenuAction.Model(row), row.Name, subtitle)));
        }
        quick.Add(Write(new ModelMenuItem(new ModelMenuAction.MoreModels(), "More Models…")));

        (string, IReadOnlyList<ModelMenuItem>)? reasoning = null;
        if (input.ReasoningLevels.Count > 0)
        {
            var levels = input.CanTurnOff ? new List<string> { "none" } : [];
            foreach (var level in input.ReasoningLevels)
                if (level != "none" && !levels.Contains(level)) levels.Add(level);
            var items = levels.Select(l => Write(new ModelMenuItem(new ModelMenuAction.Reasoning(l), ModelNames.EffortLabel(l),
                On: l == input.ReasoningCurrent))).ToList();
            reasoning = (input.Offline ? "Offline" : ModelNames.EffortLabel(input.ReasoningCurrent), items);
        }
        ModelMenuItem? fast = input.FastSupported
            ? Write(new ModelMenuItem(new ModelMenuAction.Fast(!input.FastOn), "Fast", On: input.FastOn))
            : null;
        var effort = input.ReasoningLevels.Count == 0 ? "" : ModelNames.EffortLabel(input.ReasoningCurrent);
        var sub = input.Offline ? "Offline" : string.Join(" · ", new[] { input.Current.Name, effort }.Where(s => s.Length > 0));
        return new ModelMenuNode(sub, quick, reasoning, fast);
    }
}

/// The words an alert or output row shows for an error (HermesKit MenusError.text): the gateway's own reason when it
/// gave one in words, else plain words.
public static class MenusText
{
    public const string Offline = "You’re offline.";
    public const string Loading = "This chat is still loading. Try again when it is ready.";

    public static string Of(Exception error) => error switch
    {
        GatewayException { Code: "offline" } => Offline,
        GatewayException g when g.Message.Trim().Length > 0 => g.Message,
        OperationCanceledException => "Cancelled.",
        _ when error.Message.Trim().Length > 0 && error is InvalidOperationException => error.Message,
        _ => "Something went wrong. Try again.",
    };

    /// Show Details: everything the error carries.
    public static string Details(Exception error) => error switch
    {
        GatewayException { Code: "rpc" } g => $"{g.Message} ({g.RpcCode})",
        GatewayException { Status: > 0 } g => g.Body is { Length: > 0 } body ? $"HTTP {g.Status}\n\n{body[..Math.Min(4000, body.Length)]}" : $"HTTP {g.Status}",
        _ => error.Message,
    };
}

/// The model list's load rules and failure words (HermesKit/Chat/ModelLoad.swift).
public static class ModelLoad
{
    public const int Tries = 2;
    public const int MessageLimit = 120;
    public const string FailureTitle = "Couldn’t Load Models";
    public const string LoadingWords = "Loading models…";
    public const string MenuFailure = "Couldn’t load models";
    public const string RestartWords = "The computer running Hermes was updated and needs a restart before it can list models.";

    public static bool NeedsRestart(Exception error) =>
        error is GatewayException g && (g.RpcCode == 5098 || g.Message.Contains("checkout on disk is now"));

    /// Whether asking again at once can do better.
    public static bool SecondTryHelps(Exception error)
    {
        if (error is OperationCanceledException) return false;
        if (error is GatewayException g)
        {
            if (g.Code is "offline" or "loading") return false;
            if (g.RpcCode is 4000 or -32601 || NeedsRestart(g)) return false;
        }
        return true;
    }

    /// The line under "Couldn’t Load Models": null = the title alone.
    public static string? Words(Exception error, bool offline)
    {
        if (offline || error is GatewayException { Code: "offline" }) return MenusText.Offline;
        if (NeedsRestart(error)) return RestartWords;
        if (error is GatewayException { Code: "timeout" }) return "The computer running Hermes didn’t answer in time.";
        return Cut(MenusText.Of(error));
    }

    /// A gateway's own message, trimmed and cut at 120 characters with "…"; null when it says nothing.
    public static string? Cut(string message)
    {
        var text = message.Trim();
        if (text.Length == 0) return null;
        return text.Length <= MessageLimit ? text : text[..MessageLimit].Trim() + "…";
    }
}

/// The line under "Couldn’t Load Commands" (HermesKit CommandsLoad).
public static class CommandsLoad
{
    public const string Title = "Couldn’t Load Commands";

    public static string Words(Exception error) => error switch
    {
        GatewayException { Code: "offline" } => MenusText.Offline,
        GatewayException { Code: "timeout" } => "The computer running Hermes didn’t answer in time.",
        _ => "The computer running Hermes didn’t send its list of commands. Show Details has the reason.",
    };
}

/// Hermes writes its switch warnings for a terminal; here they read as a sentence about this chat.
public static class ModelSwitchWording
{
    public static string Plain(string message)
    {
        var lines = message.Split('\n').Select(l => l.Trim()).ToList();
        var kept = lines.Where(l => !(l.StartsWith("!!!") && l.EndsWith("!!!")) && !l.StartsWith("Threshold:")
            && !l.StartsWith("Confirm only if")).ToList();
        if (kept.Count == lines.Count) return message;
        var text = string.Join("\n", kept);
        while (text.Contains("\n\n\n")) text = text.Replace("\n\n\n", "\n\n");
        text = text.Replace("This session holds", "This chat holds")
            .Replace(" (providers key prompt caches per model)", "")
            .Replace("re-read all of it uncached", "read all of it again without the cache");
        return text.Trim();
    }
}
