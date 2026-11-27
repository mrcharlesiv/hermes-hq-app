// [WIN-SCREEN-SERVICE] The setup request's words and the installer the app carries (docs/spec/3x-screen.md §5.13; the
// web's `bot-screen-setup.test.ts` and `screen-setup-bundle.test.ts`): the Mac's Tests/Screen/ScreenSetupTests.swift
// at 93f984bb1, case for case. [WIN-SCREEN-SETUP-SEND] theInstallerInTheAppIsTheReviewedOne reads the copy the Windows
// app ships (src/HermesHQ.Windows/Screen/HermesHQScreenSetup.zip, a Content item beside the app).

using System.Text;
using System.Text.Json.Nodes;
using Hermes.Core.Screen;

namespace Hermes.Core.Tests.Screen;

public sealed class ScreenSetupTests
{
    private static string Sha(string text) => ScreenSetupBundle.Hex(Encoding.UTF8.GetBytes(text));

    [Fact]
    public void ThePromptIsTheReviewedTextAndNeverNamesTheOldProduct()
    {
        var text = ScreenSetupPrompt.Text;
        Assert.Equal(3_953, Encoding.UTF8.GetByteCount(text));
        Assert.Equal("fb7b7a4dc80eae6c0a0ca41068874f2e22e22d494d9345c3f59009aca11c6107", Sha(text));
        Assert.Equal(ScreenSetupPrompt.Sha256, Sha(text));
        Assert.DoesNotContain("dispatch", text.ToLowerInvariant());
        Assert.StartsWith("Set up live Mac screen sharing for me in Hermes HQ on the computer running Hermes for this chat.", text, StringComparison.Ordinal);
        Assert.Contains("If this Mac still has the older screen plugin or helper app from before the rename, the installer carries their settings over and removes them so only one helper runs (macOS keeps the existing permissions); if it reports it could not remove the old plugin, run the removal command it reports yourself.", text, StringComparison.Ordinal);
        Assert.Equal(5, ScreenSetupPrompt.Paragraphs.Count);
        Assert.Equal("Set up live screen sharing on my Mac and verify it.", ScreenSetupPrompt.QueueTitle);
    }

    [Fact]
    public void TheMessageEndsWithTheThreeInstallerLines()
    {
        var full = ScreenSetupPrompt.Message("@file:/tmp/hermes-hq-screen-setup.zip", ScreenSetupBundle.ExpectedSha256, ScreenSetupBundle.HelperAppPath);
        Assert.StartsWith(ScreenSetupPrompt.Text, full, StringComparison.Ordinal);
        Assert.EndsWith("\n\nInstaller source: @file:/tmp/hermes-hq-screen-setup.zip\nSHA-256: 71ff241d0a3e803b8a457a9df5f91c14df48c1f227893d785974837af0c8de09\nSigned helper inside the bundle: hermes-hq-screen-setup/Hermes HQ Screen.app", full, StringComparison.Ordinal);
        var bare = ScreenSetupPrompt.Message("@file:/x.zip", "abc", null);
        Assert.EndsWith("\n\nInstaller source: @file:/x.zip\nSHA-256: abc", bare, StringComparison.Ordinal);
    }

    [Fact]
    public async Task TheInstallerInTheAppIsTheReviewedOne()
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        var shipped = Path.Combine(dir, "src", "HermesHQ.Windows", "Screen", ScreenSetupBundle.Resource + ".zip");
        var bundle = await ScreenSetupBundle.Load(shipped);
        Assert.Equal("hermes-hq-screen-setup.zip", bundle.File);
        Assert.Equal("71ff241d0a3e803b8a457a9df5f91c14df48c1f227893d785974837af0c8de09", bundle.Sha256);
        Assert.Equal("hermes-hq-screen-setup/Hermes HQ Screen.app", bundle.HelperApp);
        Assert.StartsWith("data:application/zip;base64,UEsDB", bundle.DataUrl, StringComparison.Ordinal);
        var bytes = Convert.FromBase64String(bundle.DataUrl["data:application/zip;base64,".Length..]);
        Assert.Equal(550_200, bytes.Length);
        Assert.Equal(ScreenSetupBundle.ExpectedSha256, ScreenSetupBundle.Hex(bytes));
        // Where the app looks for it once installed: Screen/HermesHQScreenSetup.zip beside the app (the csproj's Content).
        Assert.Equal(Path.Combine(AppContext.BaseDirectory, "Screen", "HermesHQScreenSetup.zip"), ScreenSetupBundle.DefaultPath);
        var project = File.ReadAllText(Path.Combine(dir, "src", "HermesHQ.Windows", "HermesHQ.Windows.csproj"));
        Assert.Contains(@"<Content Include=""Screen\HermesHQScreenSetup.zip"" CopyToOutputDirectory=""PreserveNewest"" />", project);
    }

    [Fact]
    public async Task AMissingOrAlteredInstallerIsRefused()
    {
        var refused = new ScreenSetupError(ScreenSetupFailure.Installer);
        Assert.Equal(refused, Assert.Throws<ScreenSetupError>(() => ScreenSetupBundle.Verified(null)));
        Assert.Equal(refused, Assert.Throws<ScreenSetupError>(() => ScreenSetupBundle.Verified(Enumerable.Repeat((byte)7, 550_200).ToArray())));
        Assert.Equal(refused, Assert.Throws<ScreenSetupError>(() => ScreenSetupBundle.Verified(Encoding.UTF8.GetBytes("PK"))));
        // A place with no installer (the Mac: `Bundle(for: NSObject.self)`).
        var nowhere = Path.Combine(Path.GetTempPath(), $"hq-no-installer-{Guid.NewGuid():N}", ScreenSetupBundle.Filename);
        Assert.Equal(refused, await Assert.ThrowsAsync<ScreenSetupError>(() => ScreenSetupBundle.Load(nowhere)));
    }

    [Fact]
    public void TheGatewaysAnswerToTheAttachIsHeldToItsWord()
    {
        static JsonNode J(string text) => JsonNode.Parse(text)!;
        Assert.Equal("@file:/h/x.zip", ScreenSetupAttach.RefText(J("""{"attached":true,"ref_text":"@file:/h/x.zip"}""")));
        Assert.Equal(new ScreenSetupError(ScreenSetupFailure.Installer, "No space left on the gateway"),
            Assert.Throws<ScreenSetupError>(() => ScreenSetupAttach.RefText(J("""{"attached":false,"message":"No space left on the gateway"}"""))));
        Assert.Equal(new ScreenSetupError(ScreenSetupFailure.Installer),
            Assert.Throws<ScreenSetupError>(() => ScreenSetupAttach.RefText(J("""{"attached":true,"ref_text":"  "}"""))));
        Assert.Equal(new ScreenSetupError(ScreenSetupFailure.Installer),
            Assert.Throws<ScreenSetupError>(() => ScreenSetupAttach.RefText(J("""{"ref_text":"@file:/h/x.zip"}"""))));
    }

    [Fact]
    public void EveryFailureSaysTheWebsWordsAndNoneNamesTheOldProduct()
    {
        (ScreenSetupError, string)[] all =
        [
            (new(ScreenSetupFailure.NotConnected), "This bot’s gateway is no longer connected."),
            (new(ScreenSetupFailure.ChatDidNotOpen), "Hermes could not open this bot’s chat. Try again."),
            (new(ScreenSetupFailure.ChatChanged), "The selected chat changed before setup could start."),
            (new(ScreenSetupFailure.NotReady), "This bot’s chat did not become ready for setup. Try again."),
            (new(ScreenSetupFailure.ChangedWhilePreparing), "The chat connection changed while preparing setup. Try again."),
            (new(ScreenSetupFailure.Installer), "Hermes could not receive the Mac screen installer. Try again."),
            (new(ScreenSetupFailure.Installer, ""), "Hermes could not receive the Mac screen installer. Try again."),
            (new(ScreenSetupFailure.Installer, "No space left on the gateway"), "No space left on the gateway"),
            (new(ScreenSetupFailure.ChangedBeforeStart), "The chat connection changed before setup could start. Try again."),
            (new(ScreenSetupFailure.NotQueued), "Hermes could not queue the setup request in this chat. Try again."),
        ];
        foreach (var (failure, words) in all)
        {
            Assert.Equal(words, failure.Message);
            Assert.DoesNotContain("dispatch", failure.Message.ToLowerInvariant());
        }
        Assert.Equal("Couldn’t Start Screen Setup", ScreenSetupError.AlertTitle);
    }

    [Fact]
    public void TheCardsWords()
    {
        Assert.Equal("Set Up Viewing and Control", ScreenSetupCopy.Heading(controlOnly: false));
        Assert.Equal("Enable Screen Control", ScreenSetupCopy.Heading(controlOnly: true));
        Assert.Equal("Set Up with Hermes", ScreenSetupCopy.Primary(requested: false, controlOnly: false, working: false));
        Assert.Equal("Continue with Hermes", ScreenSetupCopy.Primary(requested: true, controlOnly: false, working: false));
        Assert.Equal("Enable Control with Hermes", ScreenSetupCopy.Primary(requested: false, controlOnly: true, working: false));
        Assert.Equal("Continue with Hermes", ScreenSetupCopy.Primary(requested: true, controlOnly: true, working: false));
        Assert.Equal("Opening setup…", ScreenSetupCopy.Primary(requested: true, controlOnly: true, working: true));
        Assert.Equal("Check Setup", ScreenSetupCopy.Check(working: false));
        Assert.Equal("Checking…", ScreenSetupCopy.Check(working: true));
        string[] lines = [ScreenSetupCopy.How, ScreenSetupCopy.Shares, ScreenSetupCopy.Update, ScreenSetupCopy.Requested, ScreenSetupCopy.Windows];
        Assert.Equal(
        [
            "Hermes will install the helper, enable viewing and control, and check both permissions in one setup. Follow its progress in your bot’s chat.",
            "This shares your Mac’s entire screen and enables pointer and keyboard control for people with Screen access on your gateway. Approve Screen Recording to view, and Accessibility to click and type, on the Mac when prompted.",
            "Hermes will also check whether your gateway needs an update.",
            "Setup was requested in your bot’s chat. Hermes will report any permissions or requirements that still need attention.",
            "Live screen sharing isn’t available on Windows yet. Your bot’s latest screenshots will appear here.",
        ], lines);
        foreach (var line in lines) Assert.DoesNotContain("dispatch", line.ToLowerInvariant());
    }
}
