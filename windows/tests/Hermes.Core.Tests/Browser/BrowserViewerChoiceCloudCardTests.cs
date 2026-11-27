// Watch Browser viewer controller, Chrome profile choice, Browser Use Cloud settings, and chat card state tests.

using System.Text.Json.Nodes;
using Hermes.Core.Browser;
using Hermes.Core.Net;
using Hermes.Core.Screen;
using Hermes.Core.Tests.Screen;

namespace Hermes.Core.Tests.Browser;

public sealed class BrowserViewerChoiceCloudCardTests : IDisposable
{
    private const string RowId = "0123456789abcdef01234567";
    private readonly string _lastPageDir = Path.Combine(Path.GetTempPath(), "browser-viewer-tests-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        try { if (Directory.Exists(_lastPageDir)) Directory.Delete(_lastPageDir, recursive: true); } catch (IOException) { }
    }

    private sealed class FakeViewerHost : IBrowserViewerHost
    {
        public BrowserViewerState LastState { get; private set; } = new();
        public List<BrowserDecodedImage> Frames { get; } = [];
        public List<BrowserPageDialog> ShownDialogs { get; } = [];
        public int DismissedDialogCount { get; private set; }
        public int PopupsUpdateOffers { get; private set; }
        public string? Copied { get; private set; }
        public string? ClipboardText { get; set; }
        public bool KeyboardFocused { get; set; }
        public BrowserKeyboardSlot? FocusedSlot { get; set; }
        public bool Dismissed { get; private set; }
        public List<string> Announcements { get; } = [];

        public void Render(BrowserViewerState state) => LastState = state;
        public void ShowFrame(BrowserDecodedImage image, BrowserSize pageSize) => Frames.Add(image);
        public void CopyText(string text) => Copied = text;
        public Task<string?> ReadClipboardAsync() => Task.FromResult(ClipboardText);
        public void RaiseKeyboard(BrowserKeyboardSlot slot, BrowserKeyboardKind kind) { KeyboardFocused = true; FocusedSlot = slot; }
        public void LowerKeyboard() { KeyboardFocused = false; FocusedSlot = null; }
        public void ShowPageDialog(BrowserPageDialog dialog) => ShownDialogs.Add(dialog);
        public void DismissPageDialog() => DismissedDialogCount++;
        public void OfferPopupsUpdate(bool useUpdateSheet, string helperName) => PopupsUpdateOffers++;
        public void Announce(string text) => Announcements.Add(text);
        public void Dismiss() => Dismissed = true;
        public (double Width, double Height, double Scale) StageMetrics => (800, 600, 1.0);
    }

    private static JsonNode ReadyHealth(bool dialogs = true, bool cloudAll = true, bool hosted = false, string version = "3.10.0") =>
        JsonNode.Parse($$"""
            {
              "installed": true,
              "protocol": 3,
              "version": "{{version}}",
              "hosted": {{(hosted ? "true" : "false")}},
              "features": {
                "control": true,
                "choice": true,
                "cloud": true,
                "cloud_all": {{(cloudAll ? "true" : "false")}},
                "dialogs": {{(dialogs ? "true" : "false")}},
                "hosted": true
              }
            }
            """)!;

    [Fact]
    public async Task ViewerShowsLastPageWhenClosedThenGoesLiveAndHandlesControlAddressDialogsAndClipboard()
    {
        var activitySocket = new FakeBrowserSocket();
        var watchSocket = new FakeBrowserSocket();
        var gw = new FakeBrowserGateway
        {
            OnJson = (_, path, _, _) =>
            {
                if (path.EndsWith("/health")) return Task.FromResult(ReadyHealth(dialogs: true));
                if (path.EndsWith("/bots"))
                    return Task.FromResult(JsonNode.Parse("""{"schema":"dispatch-browser.bots.v1","bots":[{"profile":"ivy","status":"cloud"}]}""")!);
                throw new GatewayException("http", "404", 404);
            },
            OnSocket = (path, _) => Task.FromResult<IBrowserSocket>(path.EndsWith("/activity") ? activitySocket : watchSocket),
        };

        var lastPages = new BrowserLastPages(_lastPageDir, protector: null);
        var now = new DateTimeOffset(2026, 11, 20, 15, 0, 0, TimeSpan.Zero);
        lastPages.Keep(
            new BrowserLastPage(ScreenTestImage.Red64, 64, 64, "https://shop.example.com/saved", "Saved", "chat-1", now.AddMinutes(-5)),
            gw.AccountId,
            "ivy");

        var service = new BrowserService(gw, new FakeMemoryStore()) { LastPages = lastPages };
        var host = new FakeViewerHost { ClipboardText = "pasted text" };
        var scope = new BrowserScope("ivy", "Ivy");
        var viewer = new BrowserViewerController(service, scope, host, now: () => now);
        // Initial empty list marks the activity channel connected
        activitySocket.Enqueue("""{"schema":"dispatch-browser.list.v3","browsers":[]}""");
        viewer.Load();
        viewer.Appeared();

        // While no live row exists and /bots status is "cloud", last page replaces empty screen
        await WaitUntilAsync(() => viewer.State.ShowingLastPage);
        Assert.Equal(BrowserViewerBarMode.LastPage, viewer.State.Bar.Mode);
        Assert.Equal("shop.example.com", viewer.State.AddressText);

        // Activity announces an active browser -> viewer attaches live watch socket
        var jpegB64 = Convert.ToBase64String(ScreenTestImage.Green64);
        watchSocket.Enqueue("""
            {"type":"state","tabs":[{"id":"t1","title":"Docs","url":"https://docs.example.com/start"}],"tab":"t1","follow":true,
             "control":{"state":"bot","mine":false,"epoch":1},
             "dialog":{"id":10,"kind":"confirm","site":"docs.example.com","message":"Continue?"}}
            """);
        watchSocket.Enqueue($$"""{"type":"frame","seq":1,"tab":"t1","epoch":1,"width":64,"height":64,"image":"data:image/jpeg;base64,{{jpegB64}}"}""");
        activitySocket.Enqueue($$"""
            {"schema":"dispatch-browser.list.v3","browsers":[
              {"id":"{{RowId}}","profile":"ivy","session_id":"chat-1","url":"https://docs.example.com","active":true,"control":"bot","agent_at":200}
            ]}
            """);
        await WaitUntilAsync(() => viewer.State.Live);

        // Watching a page with a dialog shows notice instead of opening the dialog
        Assert.Empty(host.ShownDialogs);
        Assert.Contains("Take control", viewer.State.NoticeText ?? "");
        // Editing address while watching is blocked and shows a hint
        Assert.False(viewer.TryBeginAddressEdit(out _));

        // Taking control transitions to Mine, opens the pending dialog, allows address edit and paste
        viewer.TakeControl();
        watchSocket.Enqueue("""
            {"type":"state","tabs":[{"id":"t1","title":"Docs","url":"https://docs.example.com/start"}],"tab":"t1","follow":true,
             "control":{"state":"person","mine":true,"epoch":2},
             "field":{"focus":"password"},
             "dialog":{"id":10,"kind":"confirm","site":"docs.example.com","message":"Continue?"}}
            """);
        await WaitUntilAsync(() => viewer.State.Mine);
        Assert.Equal(BrowserViewerBarMode.Mine, viewer.State.Bar.Mode);
        Assert.Single(host.ShownDialogs);
        Assert.Equal(10, host.ShownDialogs[0].Id);

        viewer.AnswerDialog(10, accept: true);
        Assert.Contains(watchSocket.Sent, s => s.Contains("\"type\":\"answer\"") && s.Contains("\"id\":10") && s.Contains("\"accept\":true"));

        Assert.True(viewer.TryBeginAddressEdit(out var fullUrl));
        Assert.Equal("https://docs.example.com/start", fullUrl);
        viewer.CommitAddress("example.org");
        Assert.Contains(watchSocket.Sent, s => s.Contains("\"type\":\"go\"") && s.Contains("https://example.org"));

        await viewer.PasteAsync();
        Assert.Contains(watchSocket.Sent, s => s.Contains("\"type\":\"text\"") && s.Contains("pasted text"));

        host.ClipboardText = null;
        await viewer.PasteAsync();
        Assert.Equal(ControlWords.NothingToPaste, viewer.State.NoticeText);

        viewer.Close();
        Assert.True(host.Dismissed);
        service.Shutdown();
    }

    [Fact]
    public async Task ViewerOffersPopupsUpdateOncePerVersionAndHandlesInstallPrecheck()
    {
        var activitySocket = new FakeBrowserSocket();
        var watch1 = new FakeBrowserSocket();
        var watch2 = new FakeBrowserSocket();
        var watchDials = 0;
        var gw = new FakeBrowserGateway
        {
            OnJson = (_, path, _, _) =>
            {
                if (path.EndsWith("/health")) return Task.FromResult(ReadyHealth(dialogs: false, version: "3.6.2"));
                throw new GatewayException("http", "404", 404);
            },
            OnSocket = (path, _) => Task.FromResult<IBrowserSocket>(
                path.EndsWith("/activity")
                    ? activitySocket
                    : (Interlocked.Increment(ref watchDials) == 1 ? watch1 : watch2)),
        };
        var prefs = new FakeMemoryStore();
        var service = new BrowserService(gw, prefs);
        var host = new FakeViewerHost();
        var viewer = new BrowserViewerController(service, new BrowserScope("ivy", "Ivy"), host)
        {
            AskToInstall = _ => Task.CompletedTask,
        };

        activitySocket.Enqueue($$"""
            {"schema":"dispatch-browser.list.v3","browsers":[
              {"id":"{{RowId}}","profile":"ivy","session_id":"c1","url":"https://example.com","active":true,"control":"bot","agent_at":100}
            ]}
            """);
        watch1.Enqueue("""{"type":"state","tabs":[{"id":"t1","title":"Site","url":"https://example.com"}],"tab":"t1","follow":true,"control":{"state":"person","mine":true,"epoch":1}}""");

        viewer.Load();
        viewer.Appeared();
        await WaitUntilAsync(() => host.PopupsUpdateOffers == 1);
        Assert.Equal("3.6.2", prefs.Get(BrowserHealth.PopupsOfferKey));
        viewer.Close();

        // Re-opening and taking control does not offer popups update a second time for the same version
        var host2 = new FakeViewerHost();
        var viewer2 = new BrowserViewerController(service, new BrowserScope("ivy", "Ivy"), host2)
        {
            AskToInstall = _ => Task.CompletedTask,
        };
        watch2.Enqueue("""{"type":"state","tabs":[{"id":"t1","title":"Site","url":"https://example.com"}],"tab":"t1","follow":true,"control":{"state":"person","mine":true,"epoch":2}}""");
        viewer2.Load();
        viewer2.Appeared();
        await WaitUntilAsync(() => viewer2.State.Mine);
        Assert.Equal(0, host2.PopupsUpdateOffers);
        viewer2.Close();
        service.Shutdown();

        // Failing CanAsk when plugin is missing keeps viewer open and surfaces ProblemText
        var missingGw = new FakeBrowserGateway
        {
            OnJson = (_, _, _, _) => throw new GatewayException("http", "404", 404),
        };
        var missingService = new BrowserService(missingGw, new FakeMemoryStore());
        var missingHost = new FakeViewerHost();
        var missingViewer = new BrowserViewerController(missingService, new BrowserScope("ivy", "Ivy"), missingHost)
        {
            AskToInstall = _ => Task.CompletedTask,
            CanAsk = () => throw new InvalidOperationException("Main bot offline"),
        };
        missingViewer.Load();
        await WaitUntilAsync(() => missingViewer.Setup == BrowserViewerSetup.Missing.Instance);
        missingViewer.Install(BrowserSetupPrompt.Text);
        Assert.False(missingViewer.Closing);
        Assert.Equal("Main bot offline", missingViewer.State.Empty?.ProblemText);
        missingViewer.Close();
        missingService.Shutdown();
    }

    [Fact]
    public async Task BrowserChoiceModelWordingAndAsyncFlows()
    {
        // Pure wording helpers
        var changeableOwn = new BrowserChoice("ivy", Copy: null, CopiedAt: null, NormalWindow: false, Changeable: true);
        var copyChoice = changeableOwn with { Copy = new ChromeProfile("Profile 1", "Work", "ivy@example.com") };
        var cloudChoice = new BrowserChoice("ivy", null, null, false, false, Blocked: "cloud");
        var realProfile = new BrowserChoice("ivy", null, null, false, false, Blocked: "real_profile", CanTakeOver: true);
        var hostedChoice = new BrowserChoice("ivy", null, null, false, false, Blocked: "hosted", Hosted: true);

        Assert.Null(BrowserChoiceModel.Explanation(changeableOwn, "Ivy"));
        Assert.Null(BrowserChoiceModel.Explanation(cloudChoice, "Ivy"));
        Assert.Null(BrowserChoiceModel.Explanation(hostedChoice, "Ivy"));
        Assert.Contains("real Chrome profile", BrowserChoiceModel.Explanation(realProfile, "Ivy"));

        Assert.Equal("Its Own", BrowserChoiceModel.Summary(changeableOwn));
        Assert.Equal("Copy of Work", BrowserChoiceModel.Summary(copyChoice));
        Assert.Equal("Browser Use Cloud", BrowserChoiceModel.Summary(cloudChoice));
        Assert.Equal("Hermes Cloud", BrowserChoiceModel.Summary(hostedChoice));
        Assert.Equal("Real Chrome", BrowserChoiceModel.Summary(realProfile));

        Assert.Equal("Let Hermes HQ Run Ivy’s Browser", BrowserChoiceModel.TakeOverTitle(realProfile, "Ivy"));
        Assert.Null(BrowserChoiceModel.TakeOverTitle(changeableOwn, "Ivy"));
        Assert.Contains("real Chrome profile", BrowserChoiceModel.TakeOverMessage(realProfile, "Ivy"));
        Assert.Equal("choice copy: ok", BrowserChoiceModel.Outcome(new BrowserChoiceChange.Copy("Default"), null));
        Assert.Equal("choice cloud: failed (HTTP 422)", BrowserChoiceModel.Outcome(BrowserChoiceChange.Cloud.Instance, 422));
        Assert.Equal("Invalid key", BrowserChoiceModel.Detail("""{"detail":"Invalid key"}"""));
        Assert.Contains("Full Disk Access", BrowserChoiceModel.Unsupported("no_access", "/usr/bin/python3"));

        // Async load, save key + switch to cloud, and error handling
        var currentMode = "own";
        var keySet = false;
        var gw = new FakeBrowserGateway
        {
            OnJson = (method, path, _, body) =>
            {
                if (path.EndsWith("/health")) return Task.FromResult(ReadyHealth());
                if (path.EndsWith("/choice") && method == "GET")
                {
                    return Task.FromResult(JsonNode.Parse($$"""
                        {"schema":"hermes-hq-browser.choice.v1","profile":"ivy","mode":"{{currentMode}}","window":"hidden","changeable":{{(currentMode == "cloud" ? "false" : "true")}},"blocked":{{(currentMode == "cloud" ? "\"cloud\"" : "null")}}}
                        """)!);
                }
                if (path.EndsWith("/choice") && method == "POST")
                {
                    currentMode = body?["mode"]?.GetValue<string>() ?? currentMode;
                    return Task.FromResult(JsonNode.Parse($$"""
                        {"schema":"hermes-hq-browser.choice.v1","profile":"ivy","mode":"{{currentMode}}","window":"hidden","changeable":{{(currentMode == "cloud" ? "false" : "true")}},"blocked":{{(currentMode == "cloud" ? "\"cloud\"" : "null")}}}
                        """)!);
                }
                if (path.EndsWith("/cloud") && method == "GET")
                    return Task.FromResult(JsonNode.Parse($$"""{"schema":"hermes-hq-browser.cloud.v1","key_set":{{(keySet ? "true" : "false")}},"key_hint":{{(keySet ? "\"bu_…1234\"" : "null")}}}""")!);
                if (path.EndsWith("/cloud") && method == "POST")
                {
                    var key = body?["key"]?.GetValue<string>() ?? "";
                    if (key == "bad") throw new GatewayException("http", "bad", 400, """{"detail":"Key rejected by Browser Use."}""");
                    keySet = key.Length > 0;
                    return Task.FromResult(JsonNode.Parse($$"""{"schema":"hermes-hq-browser.cloud.v1","key_set":{{(keySet ? "true" : "false")}},"key_hint":{{(keySet ? "\"bu_…1234\"" : "null")}}}""")!);
                }
                if (path.EndsWith("/chrome-profiles"))
                    return Task.FromResult(JsonNode.Parse("""{"supported":true,"browser":"Chrome","profiles":[{"dir":"Default","name":"Personal","account":"otto@example.com"}]}""")!);
                throw new GatewayException("http", "404", 404);
            },
        };

        var service = new BrowserService(gw, new FakeMemoryStore());
        var model = new BrowserChoiceModel(service, "ivy", "Ivy");
        await model.LoadAsync();
        Assert.False(model.Loading);
        Assert.NotNull(model.Choice);
        Assert.True(model.Choice!.Changeable);
        Assert.Single(model.Profiles!.Profiles);

        await model.SaveKeyAsync("bad", thenSwitch: true);
        Assert.Equal("Key rejected by Browser Use.", model.Failure);
        model.DismissFailure();
        Assert.Null(model.Failure);

        await model.SaveKeyAsync("bu_valid_key", thenSwitch: true);
        Assert.True(model.Cloud!.KeySet);
        Assert.True(model.Choice!.Cloud);

        await model.ForgetKeyAsync();
        Assert.False(model.Cloud!.KeySet);
        service.Shutdown();
    }

    [Fact]
    public async Task BrowserCloudSettingsModelLifecycleAndSkippedFormatting()
    {
        Assert.Null(BrowserCloudSettingsModel.SkippedLine([]));
        Assert.Contains("otto was left as it was", BrowserCloudSettingsModel.SkippedLine(["otto"]));
        Assert.Contains("otto and ivy were left as they were", BrowserCloudSettingsModel.SkippedLine(["otto", "ivy"]));
        Assert.Contains("otto, ivy and 2 more were left", BrowserCloudSettingsModel.SkippedLine(["otto", "ivy", "wren", "juno"]));

        var keySet = false;
        var allOn = false;
        var gw = new FakeBrowserGateway
        {
            OnJson = (method, path, _, body) =>
            {
                if (path.EndsWith("/health")) return Task.FromResult(ReadyHealth(cloudAll: true));
                if (path.EndsWith("/cloud") && method == "GET")
                    return Task.FromResult(JsonNode.Parse($$"""{"schema":"hermes-hq-browser.cloud.v1","key_set":{{(keySet ? "true" : "false")}},"all":{{(allOn ? "true" : "false")}}}""")!);
                if (path.EndsWith("/cloud") && method == "POST")
                {
                    if (body?["key"] != null) keySet = body["key"]!.GetValue<string>().Length > 0;
                    if (body?["all"] != null) allOn = body["all"]!.GetValue<bool>();
                    return Task.FromResult(JsonNode.Parse($$"""{"schema":"hermes-hq-browser.cloud.v1","key_set":{{(keySet ? "true" : "false")}},"all":{{(allOn ? "true" : "false")}},"skipped":{{(allOn ? "[\"wren\"]" : "[]")}}}""")!);
                }
                throw new GatewayException("http", "404", 404);
            },
        };
        var service = new BrowserService(gw, new FakeMemoryStore());
        var model = new BrowserCloudSettingsModel(service);
        await model.LoadAsync();
        Assert.True(model.OffersAll);
        Assert.False(model.AddOnMissing);

        await model.SaveKeyAsync("bu_test_key", thenAll: true);
        Assert.True(model.Cloud!.KeySet);
        Assert.True(model.Cloud.All);
        Assert.Equal(["wren"], model.Skipped);

        await model.ForgetKeyAsync();
        Assert.False(model.Cloud!.KeySet);
        Assert.False(model.Cloud.All);
        Assert.Empty(model.Skipped);
        service.Shutdown();
    }

    [Fact]
    public async Task BrowserChatCardModelShowsOnlyDrivingChatAndRetainsWhileTurnRuns()
    {
        var activitySocket = new FakeBrowserSocket();
        var gw = new FakeBrowserGateway
        {
            OnJson = (_, _, _, _) => Task.FromResult(ReadyHealth()),
            OnSocket = (_, _) => Task.FromResult<IBrowserSocket>(activitySocket),
        };
        var service = new BrowserService(gw, new FakeMemoryStore());
        var turnRunning = true;
        var currentChat = "chat-1";

        using var card = new BrowserChatCardModel(
            service,
            () => new BrowserScope("ivy", "Ivy", sessionIds: [currentChat], chatOnly: true),
            () => turnRunning);

        var chips = new List<BrowserChatChip?>();
        card.Changed += c => chips.Add(c);

        // Browser driven by another chat -> connects activity channel, card stays hidden
        activitySocket.Enqueue($$"""
            {"schema":"dispatch-browser.list.v3","browsers":[
              {"id":"{{RowId}}","profile":"ivy","session_id":"other-chat","url":"https://shop.example.com","active":true,"control":"bot","agent_at":10}
            ]}
            """);
        card.SetVisible(true);
        await WaitUntilAsync(() => service.Activity.Connected);
        Assert.Null(card.Chip);

        // Browser driven by this chat and asking -> orange asking chip
        activitySocket.Enqueue($$"""
            {"schema":"dispatch-browser.list.v3","browsers":[
              {"id":"{{RowId}}","profile":"ivy","session_id":"chat-1","url":"https://shop.example.com","active":true,"control":"bot","ask":"Confirm login","agent_at":20}
            ]}
            """);
        await WaitUntilAsync(() => card.Chip != null);
        Assert.Equal(new BrowserChatChip("Ivy needs you in its browser", Asking: true), card.Chip);

        // Browser goes idle while turn is still running -> chip stays visible
        activitySocket.Enqueue($$"""
            {"schema":"dispatch-browser.list.v3","browsers":[
              {"id":"{{RowId}}","profile":"ivy","session_id":"chat-1","url":"https://shop.example.com","active":false,"control":"bot","agent_at":20}
            ]}
            """);
        await WaitUntilAsync(() => card.Chip is { Asking: false });
        Assert.Equal(new BrowserChatChip("Browsing shop.example.com", Asking: false), card.Chip);

        // Turn finishes -> chip disappears
        turnRunning = false;
        card.Update();
        Assert.Null(card.Chip);

        card.SetVisible(false);
        service.Shutdown();
    }

    private static async Task WaitUntilAsync(Func<bool> predicate, int timeoutMs = 4000)
    {
        var deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        while (!predicate() && DateTime.UtcNow < deadline)
            await Task.Delay(15);
        Assert.True(predicate());
    }
}
