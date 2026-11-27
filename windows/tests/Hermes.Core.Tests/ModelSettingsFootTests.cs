using System.Text.Json.Nodes;
using Hermes.Core.Composer;

namespace Hermes.Core.Tests;

/// [WIN-MODEL-YOLO-APPROVAL] The Models selector's foot as the Mac draws it (App/Chat/Menus/MacModelPicker.swift
/// MacModelSettingsFoot at 93f984bb1): Thinking, Fast | YOLO side by side, then Approval Mode with its pop-up
/// (HermesKit/Chat/ModelPanelModel.swift approvalModes; ModelPanel.swift approvalsReach), and the requests behind it
/// (HermesKit/Chat/ModelSwitcher.swift setApprovalMode / loadApprovalMode / setYolo).
public class ModelSettingsFootTests
{
    private static string Src(params string[] parts)
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir)!;
        return File.ReadAllText(Path.Combine([dir, .. parts])).Replace("\r\n", "\n");
    }

    [Fact]
    public void ApprovalModesAreTheMacsThreeInItsOrderWithTheirLines()
    {
        Assert.Equal(
        [
            new ApprovalModeRow("manual", "Manual", "Ask before actions that require approval"),
            new ApprovalModeRow("smart", "Smart", "Automatically assess actions and ask when needed"),
            new ApprovalModeRow("off", "Off", "Run without approval prompts"),
        ], ModelSettingsFoot.ApprovalModes);
        Assert.Equal("Smart", ModelSettingsFoot.ApprovalValue("smart"));
        Assert.Equal("Off", ModelSettingsFoot.ApprovalValue("off"));
        Assert.Null(ModelSettingsFoot.ApprovalValue(""));      // not known yet: the button shows no word
        Assert.Null(ModelSettingsFoot.ApprovalValue("SMART")); // the state keeps it lower-cased
        Assert.Equal("model.panel.approvals.manual", ModelSettingsFoot.ApprovalItemId("manual"));
    }

    [Fact]
    public void ReachWordsNameTheBotOrSayThisBot()
    {
        Assert.Equal("Every chat with Ivy", ModelSettingsFoot.ApprovalsReach("Ivy"));
        Assert.Equal("Every chat with this bot", ModelSettingsFoot.ApprovalsReach(null));
        Assert.Equal("Every chat with this bot", ModelSettingsFoot.ApprovalsReach("  "));
        Assert.Equal("all Ivy chats", ModelSettingsFoot.ReachNote("Ivy"));
        Assert.Equal("all this bot’s chats", ModelSettingsFoot.ReachNote(null));
        Assert.Equal("Approval Mode: Every chat with Ivy", ModelSettingsFoot.ApprovalTip("Ivy"));
        Assert.Equal("Approval Mode: Every chat with this bot", ModelSettingsFoot.ApprovalTip(null));
        Assert.Equal("Smart, Every chat with Ivy", ModelSettingsFoot.ApprovalAccessibleValue("smart", "Ivy"));
        Assert.Equal("Every chat with Ivy", ModelSettingsFoot.ApprovalAccessibleValue("", "Ivy"));
    }

    [Fact]
    public void BotNameIsTheProfileCapitalisedAndHermesForTheDefault()
    {
        Assert.Equal("Ivy", ModelSettingsFoot.BotName("ivy"));
        Assert.Equal("Hermes", ModelSettingsFoot.BotName("default"));
        Assert.Null(ModelSettingsFoot.BotName(""));
    }

    [Fact]
    public void TheCardsWordsAreTheMacs()
    {
        Assert.Equal("Thinking", ModelSettingsFoot.ThinkingTitle);
        Assert.Equal("Fast", ModelSettingsFoot.FastName);
        Assert.Equal("YOLO", ModelSettingsFoot.YoloName);
        Assert.Equal("Approval Mode", ModelSettingsFoot.ApprovalTitle);
        Assert.Equal("No prompts in this chat", ModelSettingsFoot.YoloNote);
        Assert.Equal("Fast: the model's quicker tier, in this chat", ModelSettingsFoot.FastTip(supported: true));
        Assert.Equal("Not on this model", ModelSettingsFoot.FastTip(supported: false));
        Assert.Equal("Offline · changes wait for the gateway", ModelSettingsFoot.OfflineNote);
        Assert.Equal(("model.panel.fast", "model.panel.skip", "model.panel.approvals", "model.panel.offline"),
            (ModelSettingsFoot.FastId, ModelSettingsFoot.YoloId, ModelSettingsFoot.ApprovalsId, ModelSettingsFoot.OfflineId));
        Assert.Equal("Couldn’t Change Approvals", ModelSettingsFoot.ApprovalFailureTitle);
        Assert.Equal("Couldn’t Turn On YOLO", ModelSettingsFoot.YoloFailureTitle(true));
        Assert.Equal("Couldn’t Turn Off YOLO", ModelSettingsFoot.YoloFailureTitle(false));
        // The shield warns (orange, the exclamation) when approvals are off; YOLO's warns while it is on.
        Assert.True(ModelSettingsFoot.ApprovalWarns("off"));
        Assert.False(ModelSettingsFoot.ApprovalWarns("smart"));
        Assert.False(ModelSettingsFoot.ApprovalWarns(""));
    }

    [Fact]
    public void OfflineOrMidSwitchNothingOnTheCardCanBeSet()
    {
        var on = ModelSettingsFoot.Enabled(offline: false, switching: false, fastSupported: true);
        Assert.Equal(new FootEnablement(Bar: true, Fast: true, Yolo: true, Approvals: true, Facts: true), on);
        Assert.False(ModelSettingsFoot.Enabled(false, false, fastSupported: false).Fast);
        Assert.Equal(new FootEnablement(false, false, false, false, Facts: false), ModelSettingsFoot.Enabled(offline: true, switching: false, fastSupported: true));
        // Mid-switch the facts still open their pages; only offline closes them.
        Assert.Equal(new FootEnablement(false, false, false, false, Facts: true), ModelSettingsFoot.Enabled(offline: false, switching: true, fastSupported: true));
    }

    [Fact]
    public void TabStopsAreTheBarFastYoloThenApprovalMode()
    {
        Assert.Equal([FootStop.Bar, FootStop.Fast, FootStop.Yolo, FootStop.Approvals],
            ModelSettingsFoot.TabStops(efforts: 4, fastSupported: true, offline: false, switching: false));
        Assert.Equal([FootStop.Yolo, FootStop.Approvals], ModelSettingsFoot.TabStops(efforts: 1, fastSupported: false, offline: false, switching: false));
        Assert.Equal([FootStop.Fast, FootStop.Yolo, FootStop.Approvals], ModelSettingsFoot.TabStops(efforts: 0, fastSupported: true, offline: false, switching: false));
        Assert.Empty(ModelSettingsFoot.TabStops(4, true, offline: true, switching: false));
        Assert.Empty(ModelSettingsFoot.TabStops(4, true, offline: false, switching: true));
    }

    [Fact]
    public void ChoosingTheModeAlreadySetSendsNothingAndAnUnknownModeIsReadOnce()
    {
        Assert.False(ModelSettingsFoot.ShouldSetApprovalMode(current: "smart", chosen: "smart"));
        Assert.True(ModelSettingsFoot.ShouldSetApprovalMode(current: "smart", chosen: "off"));
        Assert.True(ModelSettingsFoot.ShouldSetApprovalMode(current: "", chosen: "manual"));
        Assert.True(ModelSettingsFoot.ShouldLoadApprovals(mode: "", offline: false));
        Assert.False(ModelSettingsFoot.ShouldLoadApprovals(mode: "", offline: true));
        Assert.False(ModelSettingsFoot.ShouldLoadApprovals(mode: "smart", offline: false));
        // A late answer repaints only when it told us the mode, and only while the selector is still open.
        Assert.True(ModelSettingsFoot.RepaintAfterLoad(closed: false, mode: "manual"));
        Assert.False(ModelSettingsFoot.RepaintAfterLoad(closed: false, mode: ""));
        Assert.False(ModelSettingsFoot.RepaintAfterLoad(closed: true, mode: "manual"));
    }

    [Fact]
    public void TheRequestsAreConfigSetAndGetWithHermesKeys()
    {
        Assert.Equal("""{"key":"approvals.mode","value":"off"}""", ModelSettingsFoot.ApprovalModeSet("off").ToJsonString());
        Assert.Equal("""{"key":"approvals.mode"}""", ModelSettingsFoot.ApprovalModeGet().ToJsonString());
        Assert.Equal("""{"key":"yolo","value":"1"}""", ModelSettingsFoot.YoloSet(true).ToJsonString());
        Assert.Equal("""{"key":"yolo","value":"0"}""", ModelSettingsFoot.YoloSet(false).ToJsonString());
        Assert.Equal("config.set", ModelSettingsFoot.SetMethod);
        Assert.Equal("config.get", ModelSettingsFoot.GetMethod);
        // Hermes answers with the mode it kept, any case; an empty or missing value keeps ours.
        Assert.Equal("manual", ModelSettingsFoot.KeptApprovalMode(JsonNode.Parse("""{"key":"approvals.mode","value":"MANUAL"}""")));
        Assert.Null(ModelSettingsFoot.KeptApprovalMode(JsonNode.Parse("""{"value":""}""")));
        Assert.Null(ModelSettingsFoot.KeptApprovalMode(JsonNode.Parse("""{}""")));
        Assert.True(ModelSettingsFoot.KeptYolo(JsonNode.Parse("""{"key":"yolo","value":"1","scope":"session"}""")));
        Assert.False(ModelSettingsFoot.KeptYolo(JsonNode.Parse("""{"key":"yolo","value":"0"}""")));
        Assert.False(ModelSettingsFoot.KeptYolo(JsonNode.Parse("""{}""")));
    }

    [Fact]
    public void TheComposerSendsTheFootsRequests()
    {
        var models = Src("src", "Hermes.Core", "Composer", "ChatComposer.Models.cs");
        Assert.Contains("ModelSettingsFoot.ApprovalModeSet(mode)", models);
        Assert.Contains("ModelSettingsFoot.YoloSet(on)", models);
        Assert.Contains("public async Task LoadApprovalModeAsync(", models);
        Assert.Contains("ModelSettingsFoot.ApprovalModeGet()", models);
        Assert.DoesNotContain("[\"key\"] = \"approvals.mode\"", models);
    }

    [Fact]
    public void TheWindowsFootDrawsFastYoloAndApprovalModeFromTheseRules()
    {
        var dialog = Src("src", "HermesHQ.Windows", "Features", "Composer", "ModelsDialog.cs");
        foreach (var use in new[]
        {
            "ModelSettingsFoot.YoloId", "ModelSettingsFoot.FastId", "ModelSettingsFoot.ApprovalsId", "ModelSettingsFoot.OfflineId",
            "ModelSettingsFoot.ApprovalModes", "ModelSettingsFoot.ApprovalTip(", "ModelSettingsFoot.ReachNote(",
            "ModelSettingsFoot.ApprovalsReach(", "ModelSettingsFoot.ApprovalAccessibleValue(", "ModelSettingsFoot.YoloNote",
            "ModelSettingsFoot.Enabled(", "ModelSettingsFoot.TabStops(", "ModelSettingsFoot.ShouldSetApprovalMode(",
            "ModelSettingsFoot.ShouldLoadApprovals(", "ModelSettingsFoot.RepaintAfterLoad(", "c.SetYoloAsync(", "c.SetApprovalModeAsync(",
            "c.LoadApprovalModeAsync(", "ModelSettingsFoot.YoloFailureTitle(", "ModelSettingsFoot.ApprovalFailureTitle",
        })
            Assert.Contains(use, dialog);
        // Fast before YOLO, YOLO before Approval Mode, in the card as in the tab order.
        var fast = dialog.IndexOf("ModelSettingsFoot.FastId", StringComparison.Ordinal);
        var yolo = dialog.IndexOf("ModelSettingsFoot.YoloId", StringComparison.Ordinal);
        var approvals = dialog.IndexOf("ModelSettingsFoot.ApprovalsId", StringComparison.Ordinal);
        Assert.True(fast < yolo && yolo < approvals, $"{fast} {yolo} {approvals}");
        // A late answer must not paint a closed selector.
        Assert.Contains("dialog.Closed +=", dialog);
    }
}
