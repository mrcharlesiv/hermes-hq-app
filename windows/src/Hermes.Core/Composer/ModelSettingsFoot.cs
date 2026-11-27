using System.Text.Json.Nodes;

namespace Hermes.Core.Composer;

/// One row of the Approval Mode pop-up: the mode Hermes keeps, its name and what it does.
public sealed record ApprovalModeRow(string Mode, string Name, string Line);

/// What on the foot can be set now (the Mac's `applyEnabled`).
public sealed record FootEnablement(bool Bar, bool Fast, bool Yolo, bool Approvals, bool Facts);

/// The foot's keyboard stops, in the Mac's order.
public enum FootStop { Bar, Fast, Yolo, Approvals }

/// [WIN-MODEL-YOLO-APPROVAL] The Models selector's foot (App/Chat/Menus/MacModelPicker.swift MacModelSettingsFoot at
/// 93f984bb1): Thinking (its name and line, the step bar), Fast and YOLO side by side with an upright hairline between,
/// then Approval Mode with its pop-up, all on one card; the facts line under it. Its words come from
/// HermesKit/Chat/ModelPanelModel.swift (approvalModes, approvalValue) and App/Chat/Menus/ModelPanel.swift
/// (approvalsReach); its requests from HermesKit/Chat/ModelSwitcher.swift (setApprovalMode, loadApprovalMode, setYolo).
public static class ModelSettingsFoot
{
    public const string ThinkingTitle = "Thinking";
    public const string FastName = "Fast";
    public const string YoloName = "YOLO";
    public const string ApprovalTitle = "Approval Mode";
    /// YOLO's hint: it is this chat's own skip, unlike Approval Mode (every chat with the bot).
    public const string YoloNote = "No prompts in this chat";
    public const string OfflineNote = "Offline · changes wait for the gateway";
    public const string FastId = "model.panel.fast";
    public const string YoloId = "model.panel.skip";
    public const string ApprovalsId = "model.panel.approvals";
    public const string OfflineId = "model.panel.offline";
    public const string ApprovalFailureTitle = "Couldn’t Change Approvals";
    public const string SetMethod = "config.set";
    public const string GetMethod = "config.get";
    private const string ApprovalKey = "approvals.mode";
    private const string YoloKey = "yolo";

    /// The approval modes in the order the pop-up lists them (V:i18n/en.ts approvalMode).
    public static IReadOnlyList<ApprovalModeRow> ApprovalModes { get; } =
    [
        new("manual", "Manual", "Ask before actions that require approval"),
        new("smart", "Smart", "Automatically assess actions and ask when needed"),
        new("off", "Off", "Run without approval prompts"),
    ];

    /// What the pop-up's button says: the mode by name; null while not known yet (only its ⌃⌄ shows).
    public static string? ApprovalValue(string mode) => ApprovalModes.FirstOrDefault(m => m.Mode == mode)?.Name;

    public static string ApprovalItemId(string mode) => $"{ApprovalsId}.{mode}";

    /// How far Approval Mode reaches: the bot's rule, for all its chats (the pop-up's heading and its tooltip).
    public static string ApprovalsReach(string? bot) =>
        bot is null || bot.Trim().Length == 0 ? "Every chat with this bot" : $"Every chat with {bot}";

    /// The short form beside the row's name ("all Otto chats").
    public static string ReachNote(string? bot) => bot is null ? "all this bot’s chats" : $"all {bot} chats";

    public static string ApprovalTip(string? bot) => $"{ApprovalTitle}: {ApprovalsReach(bot)}";

    /// What a screen reader hears on the pop-up's button: the mode (when known) and how far it reaches.
    public static string ApprovalAccessibleValue(string mode, string? bot) =>
        string.Join(", ", new[] { ApprovalValue(mode), ApprovalsReach(bot) }.OfType<string>());

    /// The chat's bot by name, as the chat's own words name it: the default profile is "Hermes"; null when none.
    public static string? BotName(string profile) =>
        profile.Length == 0 ? null : profile == "default" ? "Hermes" : char.ToUpperInvariant(profile[0]) + profile[1..];

    public static string FastTip(bool supported) => supported ? "Fast: the model's quicker tier, in this chat" : "Not on this model";

    public static string YoloFailureTitle(bool on) => on ? "Couldn’t Turn On YOLO" : "Couldn’t Turn Off YOLO";

    /// Approvals off: the shield warns (orange, its exclamation) instead of the tint's check.
    public static bool ApprovalWarns(string mode) => mode == "off";

    /// Offline or mid-switch nothing on the card can be set; Fast also needs the model to have it. The facts open
    /// their pages unless offline (Usage & Limits and Model Prices read the gateway).
    public static FootEnablement Enabled(bool offline, bool switching, bool fastSupported)
    {
        var on = !offline && !switching;
        return new FootEnablement(on, on && fastSupported, on, on, !offline);
    }

    /// The bar (when the model has levels to step), Fast (when the model has it), YOLO, Approval Mode; offline or
    /// mid-switch, none.
    public static IReadOnlyList<FootStop> TabStops(int efforts, bool fastSupported, bool offline, bool switching)
    {
        if (offline || switching) return [];
        var stops = new List<FootStop>();
        if (efforts > 1) stops.Add(FootStop.Bar);
        if (fastSupported) stops.Add(FootStop.Fast);
        stops.Add(FootStop.Yolo);
        stops.Add(FootStop.Approvals);
        return stops;
    }

    /// Setting the mode the bot already has is a no-op: nothing is sent.
    public static bool ShouldSetApprovalMode(string current, string chosen) => chosen != current;

    /// An older Hermes leaves the mode out of the chat's info: read it once when the selector opens online.
    public static bool ShouldLoadApprovals(string mode, bool offline) => mode.Length == 0 && !offline;

    /// The late read repaints the foot only when it learned the mode and the selector is still open.
    public static bool RepaintAfterLoad(bool closed, string mode) => !closed && mode.Length > 0;

    /// `config.set approvals.mode`: the bot's config, so every chat with it (and its jobs) follows.
    public static JsonObject ApprovalModeSet(string mode) => new() { ["key"] = ApprovalKey, ["value"] = mode };

    public static JsonObject ApprovalModeGet() => new() { ["key"] = ApprovalKey };

    /// `config.set yolo`: this chat's approval bypass, as `/yolo` sets it ("1" / "0").
    public static JsonObject YoloSet(bool on) => new() { ["key"] = YoloKey, ["value"] = on ? "1" : "0" };

    /// The mode Hermes kept, lower-cased; null when it said none.
    public static string? KeptApprovalMode(JsonNode? result) =>
        result.Text("value")?.ToLowerInvariant();

    public static bool KeptYolo(JsonNode? result) => result.Str("value") == "1";
}
