// [WIN-SCREEN-SETUP-SEND] "Set up with Hermes" on the chat's side (docs/spec/3x-screen.md §5.13), the C# twin of the
// Mac's HermesKit/Chat/LiveChatSession+ScreenSetup.swift at 93f984bb1: hands the installer the app carries to this chat's
// gateway (`file.attach` with the installer as a data URL). The prompt that names it goes through the chat's normal send
// (ChatComposer+ScreenSetup.cs). The app never unpacks or runs the installer.

using System.Text.Json.Nodes;
using Hermes.Core.Net;
using Hermes.Core.Screen;

namespace Hermes.Core.Chat;

public sealed partial class ChatSession
{
    /// How long the setup waits for this chat's runtime id. The Swift waits 4 s; Windows waits 10 s (the Windows lanes'
    /// polling floor: a resume on a loaded CI runner can take longer than 4 s, and the only cost is a later
    /// "did not become ready" when it truly never comes).
    public TimeSpan ScreenSetupRuntimeWait { get; set; } = TimeSpan.FromSeconds(10);

    /// `screenSetupRuntime(limit:)`: this chat's runtime id, resuming it when there is none, or NotReady after the wait.
    public async Task<string> ScreenSetupRuntimeAsync(TimeSpan? limit = null)
    {
        if (_runtimeId is { } bound) return bound;
        using var cancel = new CancellationTokenSource();
        _ = Task.Run(async () =>
        {
            try { await ResumeAsync(cancel.Token); }
            catch (Exception) { /* the wait below says NotReady */ }
        });
        try
        {
            var end = DateTimeOffset.UtcNow + (limit ?? ScreenSetupRuntimeWait);
            while (DateTimeOffset.UtcNow < end)
            {
                if (_runtimeId is { } rid) return rid;
                await Task.Delay(50);
            }
            return _runtimeId ?? throw new ScreenSetupError(ScreenSetupFailure.NotReady);
        }
        finally { cancel.Cancel(); }
    }

    /// `attachScreenSetup(name:dataURL:)`: `file.attach {session_id, profile, name, data_url}` (120 s: the frame is about
    /// 734 KB). A stale runtime id (4001) resumes once and attaches again. Returns the gateway's `ref_text` and the
    /// runtime id it was attached to. Every failure is a ScreenSetupError: the gateway's own words when it said any, the
    /// installer line when the socket timed out or dropped.
    public async Task<(string RefText, string Runtime)> AttachScreenSetupAsync(string name, string dataUrl, CancellationToken ct = default)
    {
        var resumed = false;
        while (true)
        {
            var rid = await ScreenSetupRuntimeAsync();
            var p = new JsonObject { ["session_id"] = rid, ["name"] = name, ["data_url"] = dataUrl, ["profile"] = Profile };
            try
            {
                var answer = await _client.Rpc.RequestAsync("file.attach", p, TimeSpan.FromSeconds(120), ct);
                return (ScreenSetupAttach.RefText(answer), rid);
            }
            catch (GatewayException e) when (e.Code == "rpc" && e.RpcCode == 4001 && !resumed)
            {
                resumed = true;
                _runtimeId = null;
            }
            catch (GatewayException e)
            {
                // `isTimeout || isConnectionLost || isNotConnected`: the installer line; any other refusal: its words.
                throw new ScreenSetupError(ScreenSetupFailure.Installer, e.Code == "rpc" ? e.Message : null);
            }
            catch (ScreenSetupError) { throw; }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (Exception) { throw new ScreenSetupError(ScreenSetupFailure.Installer); }
        }
    }
}
