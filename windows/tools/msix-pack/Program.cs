using HermesHQ.MsixPack;

// Usage (from windows/):
//   dotnet run --project tools/msix-pack -- plan --publish build/app --arch x64 --work build/msix/work
//   dotnet run --project tools/msix-pack -- pack --publish build/app --arch x64 --out build/msix/HermesHQ-x64-unsigned.msix
//                                                --work build/msix/work --makeappx <path to makeappx.exe>
// `plan` checks the inputs and writes AppxManifest.xml + mapping.txt (any OS). `pack` also packs, unpacks and compares.
// --work is the tool's own folder: new, or one it made before. --out sits beside it. Both are replaced only after a
// successful check; a failure leaves the previous ones as they were. Optional --timeout SECONDS bounds each MakeAppx run.
// The package is unsigned: it isn't installable as is, and this doesn't install, sign, upload or test an upgrade.

var a = new Dictionary<string, string>();
if (args.Length == 0 || args[0] is not ("plan" or "pack")) return Usage();
for (var i = 1; i < args.Length; i += 2)
{
    if (!args[i].StartsWith("--") || i + 1 >= args.Length) return Usage();
    a[args[i][2..]] = args[i + 1];
}
string Arg(string k, string? fallback = null) => a.TryGetValue(k, out var v) ? v : fallback ?? throw new PackException($"--{k} is required");
TimeSpan? Timeout() => !a.TryGetValue("timeout", out var t) ? null
    : int.TryParse(t, out var s) && s is > 0 and <= 86_400 ? TimeSpan.FromSeconds(s) : throw new PackException($"--timeout \"{t}\" isn't a number of seconds from 1 to 86400");

try
{
    var project = Arg("project", Path.Combine("src", "HermesHQ.Windows", "HermesHQ.Windows.csproj"));
    var publish = Arg("publish");
    var arch = Arg("arch", "x64");
    var work = Arg("work");
    if (args[0] == "plan")
    {
        var (plan, mapping) = Packer.Plan(publish, project, arch, work);
        Console.WriteLine($"plan ok: {Identity.Name} {plan.Version} {plan.Arch}, {plan.Files.Count} files, mapping {mapping}");
        return 0;
    }
    var r = Packer.Run(publish, project, arch, Arg("out"), work, new MakeAppxProcess(Arg("makeappx"), Timeout()));
    Console.WriteLine($"pack ok: {r.Package} ({new FileInfo(r.Package).Length} bytes)");
    Console.WriteLine($"unpacked and matched: {r.Files} files + AppxManifest.xml, {Identity.Name} {r.Version} {r.Arch}, publisher {Identity.Publisher}");
    Console.WriteLine("UNSIGNED local package: not signed, not installed, not upgrade-tested. Those gates stay open.");
    return 0;
}
catch (PackException e)
{
    Console.Error.WriteLine($"msix-pack: {e.Message}");
    return 1;
}

static int Usage()
{
    Console.Error.WriteLine("usage: msix-pack plan|pack --publish DIR --work DIR [--arch x64|arm64] [--project CSPROJ] [--out MSIX --makeappx EXE [--timeout SECONDS]]");
    return 2;
}
