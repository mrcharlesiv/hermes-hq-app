using Hermes.Core.Shell;
using HermesHQ;
using HermesHQ.Features.Artifacts;
using HermesHQ.Features.Attachments;
using HermesHQ.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Hermes.Core.Tests;

[Collection("Shutdown UI")]
public class OwnedViewShutdownTests
{
    // The same registrations and close callbacks as AppShutdown.RunAsync. A successful Close may mutate the registry/tree.
    [Theory]
    [InlineData(false, false)]
    [InlineData(true, false)]
    [InlineData(false, true)]
    [InlineData(true, true)]
    public async Task BothCollectionsAttemptEveryMemberBeforeExit(bool fileRefuses, bool viewRefuses)
    {
        var calls = new List<string>();
        var notes = new List<string>();
        var marks = new List<(ShutdownStage, ShutdownProgress)>();
        void Close(string name, bool refuse)
        {
            calls.Add(name);
            if (refuse) throw new InvalidOperationException("private fixture detail");
        }
        var first = ArtifactFileWindow.AddFixture("file", () => Close("file", fileRefuses && calls.Count == 0));
        var second = ArtifactFileWindow.AddFixture("page", () => Close("page", fileRefuses && calls.Count == 0));
        var fileOrder = ArtifactFileWindow.OpenKeys; // the registry does not promise insertion order after Closed
        var root = (App.Window = new Window()).Content;
        root.Children.Add(new WebView2(() => Close("web", viewRefuses)));
        var popupView = new WebView2(() => Close("popup web", false));
        root.XamlRoot.Popups.Add(new Popup(popupView));
        root.XamlRoot.Popups.Add(new Popup(popupView)); // two paths to one control are still one close request
        try
        {
            var plan = AppShutdown.Build();
            IReadOnlyList<ShutdownStepResult> results = [];
            await ShutdownPlan.FinishWalkAsync(() => Task.CompletedTask,
                async () => results = await plan.RunAsync("walk", notes.Add, milestone: (s, p) => marks.Add((s, p))),
                () => calls.Add("exit"));
            Assert.Empty(await plan.RunAsync("second quit", notes.Add));
            Assert.Equal(fileOrder.Concat(["web", "popup web", "exit"]), calls);
            foreach (var (stage, refused) in new[] { (ShutdownStage.Windows, fileRefuses), (ShutdownStage.WebViews, viewRefuses) })
            {
                Assert.Equal(refused ? "threw InvalidOperationException 0x80131509" : "done", results.Last(r => r.Stage == stage).Outcome);
                Assert.Equal(refused ? ShutdownProgress.Threw : ShutdownProgress.Done, marks.Last(m => m.Item1 == stage).Item2);
            }
            Assert.DoesNotContain(notes, line => line.Contains("private fixture detail"));
            Assert.Equal(ShutdownStage.Drain, results.Last().Stage);
        }
        finally { first.ForgetFixture(); second.ForgetFixture(); App.Window = null; }
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ChatPhotoViewerClosesBeforeExitOnlyIfStillOpen(bool alreadyClosed)
    {
        MediaViewerWindow.Show([new ViewerItem()], 0);
        var viewer = Assert.IsType<MediaViewerWindow>(MediaViewerWindow.Activated);
        if (alreadyClosed) viewer.Close();
        try
        {
            var plan = AppShutdown.Build();
            IReadOnlyList<ShutdownStepResult> results = [];
            var requestsAtExit = -1;
            await ShutdownPlan.FinishWalkAsync(() => Task.CompletedTask,
                async () => results = await plan.RunAsync("window closing", _ => { }),
                () => requestsAtExit = viewer.Requests);
            Assert.Equal(1, requestsAtExit);
            Assert.Contains(results, r => r.Stage == ShutdownStage.Windows && r.Name == "chat photo viewer" && r.Outcome == "done");
            Assert.Equal(1, viewer.Requests);
            Assert.Empty(await plan.RunAsync("second quit", _ => { }));
            Assert.Equal(1, viewer.Requests);
        }
        finally { if (viewer.Requests == 0) viewer.Close(); }
    }
}
