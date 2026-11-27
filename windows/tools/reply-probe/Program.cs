using Hermes.Core.Notifications;
using Hermes.Core.Shell;

var proof = DesktopProof.ForRunner(Environment.GetEnvironmentVariable, OperatingSystem.IsWindows());
if (args is ["guard", "toasts"])
{
    try { ToastQuietProbe.RequireRunner(OperatingSystem.IsWindows(), Environment.GetEnvironmentVariable); }
    catch (QuietWalkStopped stop) { Console.Error.WriteLine(stop.StopLine); return 1; }
    if (proof != null) return 0;
    Console.Error.WriteLine("toast-quiet-stop/v1 phase=runner gap=runner-not-authorized");
    return 1;
}
if (proof == null) { Console.Error.WriteLine("refused: requires the opted-in private hosted Windows push runner"); return 1; }
if (args is ["guard"]) return 0;
if (DesktopProof.Phase(args) is not { } phase) { Console.Error.WriteLine("refused: expected warm or cold only"); return 1; }
try
{
    ShellCenter.OpenReply(proof, phase);
    Console.WriteLine("reply probe: invoked");
    return 0;
}
catch (ReplyGap gap) { Console.WriteLine("reply probe: gap: " + gap.Message); return 2; }
catch (Exception error) { Console.Error.WriteLine("reply probe failed: " + error.GetType().Name); return 1; }
