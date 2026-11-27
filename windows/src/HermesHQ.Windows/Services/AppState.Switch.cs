using Hermes.Core;
using Hermes.Core.Gateways;

namespace HermesHQ.Services;

static partial class AppState
{
    /// Switches to another saved gateway (the switcher, Manage Gateways, the offline screen). Throws
    /// GatewayNeedsSignInException when its session ended: the caller opens the sign-in prefilled.
    public static async Task<HermesClient> SwitchToAsync(string key, CancellationToken stop = default)
    {
        var account = Gateways.BeginSwitch(key);
        var switched = false;
        try
        {
            await Task.Delay(60, stop); // the "Switching to …" line draws before the window repaints
            // The delay can finish and post this continuation just before quit cancels it.
            stop.ThrowIfCancellationRequested();
            if (AppShutdown.Stopping) throw new OperationCanceledException(stop);
            var session = SignIn.Resume(account) ?? throw new GatewayNeedsSignInException(account);
            ParkRoster();
            switched = true;
            Gateways.EndSwitch(switched: true);
            var client = Adopt(session);
            AppLog.Note("gateways", "switched gateway");
            return client;
        }
        finally
        {
            if (!switched) Gateways.EndSwitch(switched: false);
        }
    }
}