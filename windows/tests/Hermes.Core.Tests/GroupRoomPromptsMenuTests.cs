using System.Text.RegularExpressions;
using Hermes.Core.Composer;
using Hermes.Core.Groups;
using Xunit;

namespace Hermes.Core.Tests;

/// The room's ⋯ › Prompts and the Can’t Send alert's Add Bots… (App/Groups/GroupRoomChrome.swift `moreItems`,
/// `explain(.noMembers)`; App/Chat/ComposerView.swift `insertPrompt`, `dictationInsert`; build 1200, 93f984bb1).
public class GroupRoomPromptsMenuTests
{
    [Fact]
    public void PromptsSitsBetweenAddBotsAndActivityInEveryState()
    {
        foreach (var online in new[] { true, false })
        foreach (var fixedMembers in new[] { true, false })
        foreach (var running in new[] { true, false })
        foreach (var paused in new[] { true, false })
        {
            var top = GroupRoomChrome.MoreItems(online, fixedMembers, running, paused)[0].Select(i => i.Id).ToList();
            var expected = new List<string> { "find", "info" };
            if (online && !fixedMembers) expected.Add("add");
            expected.Add("prompts");
            expected.Add("activity");
            Assert.Equal(expected, top);
        }
        var prompts = GroupRoomChrome.MoreItems(true, false, false, false)[0].Single(i => i.Id == "prompts");
        Assert.Equal("Prompts", prompts.Title);
        Assert.Equal("room.more.prompts", prompts.AutomationId);
        Assert.False(prompts.Destructive);
    }

    [Fact]
    public void CantSendOffersAddBotsOnlyOnlineWithMembersThatCanChange()
    {
        Assert.Equal("Can’t Send", GroupRoomChrome.CantSendTitle);
        Assert.Equal("Planning has no members to send to — add a bot, or reopen the group chat if members are still loading.",
            GroupRoomChrome.CantSendMessage("Planning"));
        Assert.Equal(["Add Bots…", "OK"], GroupRoomChrome.CantSendButtons(online: true, fixedMembers: false));
        Assert.Equal(["OK"], GroupRoomChrome.CantSendButtons(online: true, fixedMembers: true));
        Assert.Equal(["OK"], GroupRoomChrome.CantSendButtons(online: false, fixedMembers: false));
        Assert.Equal(["OK"], GroupRoomChrome.CantSendButtons(online: false, fixedMembers: true));
    }

    [Fact]
    public void APromptFillsAnEmptyFieldAndGoesInAtTheCaretOtherwise()
    {
        // An empty (or blank) field takes the prompt whole, caret at its end.
        Assert.Equal(("Summarise this", 14), ComposerText.InsertPrompt("", 0, 0, "Summarise this"));
        Assert.Equal(("Summarise this", 14), ComposerText.InsertPrompt("  \n", 1, 0, "Summarise this"));
        // Otherwise at the caret, with a space when the text before it does not end in white space.
        Assert.Equal(("hello Summarise", 15), ComposerText.InsertPrompt("hello", 5, 0, "Summarise"));
        Assert.Equal(("hello Summarise", 15), ComposerText.InsertPrompt("hello ", 6, 0, "Summarise"));
        Assert.Equal(("Summarisehello", 9), ComposerText.InsertPrompt("hello", 0, 0, "Summarise"));
        // A selection is replaced; out-of-range carets are clamped.
        Assert.Equal(("say Summarise now", 13), ComposerText.InsertPrompt("say this now", 4, 4, "Summarise"));
        Assert.Equal(("hi Summarise", 12), ComposerText.InsertPrompt("hi", 99, 5, "Summarise"));
        Assert.Equal(("line\nSummarise", 14), ComposerText.InsertPrompt("line\n", 5, 0, "Summarise"));
    }

    // ------------------------------------------------------------------ the page (source: WinUI can't run here)

    private static string Source(params string[] parts)
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        return File.ReadAllText(Path.Combine([dir, "src", "HermesHQ.Windows", .. parts])).Replace("\r\n", "\n");
    }

    private static string Body(string source, string signature)
    {
        var m = Regex.Match(source, Regex.Escape(signature) + @"[^{]*\{(?<body>.*?)\n    \}", RegexOptions.Singleline);
        Assert.True(m.Success, signature + " not found");
        return m.Groups["body"].Value;
    }

    [Fact]
    public void TheRoomsPromptsItemOpensTheChatsPromptsOnTheRoomField()
    {
        var fill = Body(Source("Pages", "GroupRoomPage.cs"), "private void FillMore()");
        Assert.Matches(@"""prompts""\s*=>\s*\(""[^""]+"",\s*\(\)\s*=>\s*_\s*=\s*ShowPrompts\(\)\)", fill);
        var show = Regex.Match(Source("Pages", "GroupRoomPage.cs"), @"private Task ShowPrompts\(\) =>[^;]*;").Value;
        Assert.NotEmpty(show);
        Assert.Contains("PromptsDialog.ShowAsync(XamlRoot, ComposerServices.Prompts, _composer)", show);
        Assert.DoesNotContain("Send", show);
    }

    [Fact]
    public void ChoosingAPromptFillsTheFieldWithoutSending()
    {
        var dialog = Source("Features", "Composer", "PromptsDialog.cs");
        var use = Body(dialog, "void Use(SavedPrompt prompt)".Insert(0, "    "));
        Assert.Contains("ComposerText.InsertPrompt(composer.Text, composer.SelectionStart, composer.SelectionLength, prompt.Text)", use);
        Assert.Contains("composer.SelectionStart", use);
        Assert.DoesNotContain("Send", use);
        Assert.DoesNotContain("Send", dialog.Replace("SendText", ""));
    }

    [Fact]
    public void TheCantSendAlertOffersAddBotsThroughTheRoomsPicker()
    {
        var page = Source("Pages", "GroupRoomPage.cs");
        var send = Body(page, "private void SendOrStop()");
        Assert.Contains("_ = CantSend(name)", send);
        Assert.DoesNotContain("_ = Alert(\"Can’t Send\"", send);
        var cant = Body(page, "private async Task CantSend(string name)");
        Assert.Contains("GroupRoomChrome.CantSendButtons(", cant);
        Assert.Contains("GroupManageFeature.Writable(hub)", cant);
        Assert.Contains("IsHosted == true", cant);
        Assert.Contains("GroupManageFeature.ShowPickerAsync(hub, XamlRoot, key)", cant);
        Assert.Contains("ContentDialogResult.Primary", cant);
    }
}
