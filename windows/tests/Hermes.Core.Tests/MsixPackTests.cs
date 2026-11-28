using System.IO.Compression;
using System.Reflection;
using System.Reflection.Emit;
using System.Runtime.InteropServices;
using System.Xml.Linq;
using HermesHQ.MsixPack;

namespace Hermes.Core.Tests;

/// [WIN-INSTALL-PACK] The opt-in, unsigned, local MSIX pack (windows/tools/msix-pack, windows/scripts/pack-msix.ps1)
/// against a synthetic publish folder: identity, architecture, executable, logos, version rules, the file mapping, and
/// the unpacked package checked file by file. [WIN-PACK-OUTPUTS] Short-lived synthetic tools prove the runner's one
/// bounded lifetime, and disposable folders with marker bytes prove that no failure touches the previous outputs. A zip-based stand-in plays MakeAppx here; the real MakeAppx runs only on
/// Windows through pack-msix.ps1. Packing is not signing, installing or an upgrade test.
public class MsixPackTests : IDisposable
{
    private readonly string root = Directory.CreateTempSubdirectory("hq-msix-").FullName;
    public void Dispose() { try { Directory.Delete(root, true); } catch { } }

    private static string WindowsDir()
    {
        for (var d = new DirectoryInfo(AppContext.BaseDirectory); d != null; d = d.Parent)
            if (File.Exists(Path.Combine(d.FullName, "windows", "src", "HermesHQ.Windows", "HermesHQ.Windows.csproj"))) return Path.Combine(d.FullName, "windows");
        throw new InvalidOperationException("windows/ not found above the test folder");
    }

    private static string AppProject => Path.Combine(WindowsDir(), "src", "HermesHQ.Windows", "HermesHQ.Windows.csproj");
    private static string AppIcon => Path.Combine(WindowsDir(), "src", "HermesHQ.Windows", "Assets", "HermesHQ-256.png");

    // ---------------------------------------------------------------- synthetic inputs

    private const string PreviousPackageVersion = "0.1.1.0", CurrentPackageVersion = "0.1.2.0";

    // Only the historical unit fixture needs version XML. Always test the current version against the actual project.
    private string ProjectFor(string packageVersion)
    {
        if (packageVersion == CurrentPackageVersion) return AppProject;
        Assert.Equal(PreviousPackageVersion, packageVersion);
        var path = Path.Combine(root, "previous-version.xml");
        File.WriteAllText(path, "<Project><PropertyGroup><Version>0.1.1</Version></PropertyGroup></Project>");
        return path;
    }

    private static byte[] Pe(ushort machine)
    {
        var b = new byte[0x200];
        b[0] = (byte)'M'; b[1] = (byte)'Z';
        BitConverter.GetBytes(0x80).CopyTo(b, 0x3C);
        b[0x80] = (byte)'P'; b[0x81] = (byte)'E';
        BitConverter.GetBytes(machine).CopyTo(b, 0x84);
        return b;
    }

    private static void ManagedDll(string path, Version version)
    {
        var ab = new PersistedAssemblyBuilder(new AssemblyName("HermesHQ") { Version = version }, typeof(object).Assembly);
        ab.DefineDynamicModule("HermesHQ").DefineType("HermesHQ.Stub", TypeAttributes.Public).CreateType();
        ab.Save(path);
    }

    private static byte[] Png(int w, int h)
    {
        var b = new byte[33];
        new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, (byte)'I', (byte)'H', (byte)'D', (byte)'R' }.CopyTo(b, 0);
        b[16] = (byte)(w >> 24); b[17] = (byte)(w >> 16); b[18] = (byte)(w >> 8); b[19] = (byte)w;
        b[20] = (byte)(h >> 24); b[21] = (byte)(h >> 16); b[22] = (byte)(h >> 8); b[23] = (byte)h;
        return b;
    }

    /// A made-up publish folder shaped like `dotnet publish -r win-x64` of HermesHQ.Windows (apphost, managed dll,
    /// runtimeconfig, resources.pri, the app's own icon PNG and a nested runtime folder).
    private string Publish(string arch = "x64", Version? version = null)
    {
        var p = Path.Combine(root, "publish-" + arch);
        Directory.CreateDirectory(Path.Combine(p, "Assets"));
        Directory.CreateDirectory(Path.Combine(p, "runtimes", "win-" + arch, "native"));
        File.WriteAllBytes(Path.Combine(p, "HermesHQ.exe"), Pe(arch == "x64" ? (ushort)0x8664 : (ushort)0xAA64));
        ManagedDll(Path.Combine(p, "HermesHQ.dll"), version ?? Version.Parse(CurrentPackageVersion));
        File.WriteAllText(Path.Combine(p, "HermesHQ.runtimeconfig.json"), "{\"runtimeOptions\":{}}");
        File.WriteAllBytes(Path.Combine(p, "resources.pri"), [1, 2, 3]);
        File.Copy(AppIcon, Path.Combine(p, "Assets", "HermesHQ-256.png"));
        File.WriteAllText(Path.Combine(p, "runtimes", "win-" + arch, "native", "Example Native.dll"), "native");
        return p;
    }

    private string Out(string name) => Path.Combine(root, "out", name);

    // ---------------------------------------------------------------- the default app stays unpackaged

    [Fact]
    public void TheAppProjectStaysUnpackagedAndItsVersionIsThePackageVersion()
    {
        var doc = XDocument.Load(AppProject);
        Assert.Equal("None", doc.Descendants("WindowsPackageType").Single().Value);
        Assert.Equal("0.1.2", doc.Descendants("Version").Single().Value);
        Assert.Equal(CurrentPackageVersion, MsixPlan.ProjectPackageVersion(AppProject));
        Assert.False(File.Exists(Path.Combine(WindowsDir(), "src", "HermesHQ.Windows", "Package.appxmanifest")));
        // The logos are the app's existing icon: a square PNG at least 150 px.
        Assert.Equal((256, 256), Inputs.PngSize(AppIcon));
    }

    // ---------------------------------------------------------------- version rules

    [Theory]
    [InlineData("0.1.0", "0.1.0.0")]
    [InlineData("1.2.3.0", "1.2.3.0")]
    [InlineData("65535.0.65535", "65535.0.65535.0")]
    public void VersionsBecomeFourPartsWithRevisionZero(string v, string expected) => Assert.Equal(expected, Inputs.PackageVersion(v));

    [Theory]
    [InlineData("1.2.3.4")]       // the revision is reserved (Store rule): it must be 0
    [InlineData("65536.0.0")]
    [InlineData("1.2")]
    [InlineData("1.-2.3")]
    [InlineData("v1.2.3")]
    [InlineData("1.2.3-beta")]
    [InlineData("")]
    [InlineData("1.2.3.0.0")]
    public void BadVersionsAreRefused(string v) => Assert.Throws<PackException>(() => Inputs.PackageVersion(v));

    [Theory]
    [InlineData(PreviousPackageVersion, CurrentPackageVersion)]
    [InlineData(CurrentPackageVersion, PreviousPackageVersion)]
    [InlineData("0.2.0.0", CurrentPackageVersion)]
    public void TheManagedAppVersionMustMatchTheProject(string assemblyVersion, string packageVersion)
    {
        var p = Publish(version: Version.Parse(assemblyVersion));
        var work = Out("work");
        var e = Assert.Throws<PackException>(() => Packer.Plan(p, ProjectFor(packageVersion), "x64", work));
        Assert.Equal($"HermesHQ.dll is version {assemblyVersion}, but the project (and so the package) is {packageVersion}: publish again from this tree", e.Message);
        Assert.False(Directory.Exists(work));
    }

    // ---------------------------------------------------------------- the plan: identity, architecture, executable, logos

    [Theory]
    [InlineData(PreviousPackageVersion)]
    [InlineData(CurrentPackageVersion)]
    public void ThePlanCarriesTheLocalUnsignedIdentityArchitectureExecutableAndLogos(string packageVersion)
    {
        var p = Publish(version: Version.Parse(packageVersion));
        var work = Out("work");
        var (plan, _) = Packer.Plan(p, ProjectFor(packageVersion), "x64", work);
        Assert.Equal(packageVersion, plan.Version);
        var m = XDocument.Load(Path.Combine(work, "AppxManifest.xml"));
        XNamespace f = "http://schemas.microsoft.com/appx/manifest/foundation/windows10";
        XNamespace uap = "http://schemas.microsoft.com/appx/manifest/uap/windows10";
        XNamespace rescap = "http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities";
        var id = m.Root!.Element(f + "Identity")!;
        Assert.Equal("HermesHQ.LocalUnsigned", (string?)id.Attribute("Name"));
        Assert.Equal("CN=Hermes HQ Unsigned Local Build", (string?)id.Attribute("Publisher"));
        Assert.Equal(packageVersion, (string?)id.Attribute("Version"));
        Assert.Equal("x64", (string?)id.Attribute("ProcessorArchitecture"));
        Assert.Equal("Hermes HQ", m.Root.Element(f + "Properties")!.Element(f + "DisplayName")!.Value);
        Assert.Equal(@"Assets\HermesHQ-256.png", m.Root.Element(f + "Properties")!.Element(f + "Logo")!.Value);
        var app = m.Root.Element(f + "Applications")!.Element(f + "Application")!;
        Assert.Equal("HermesHQ", (string?)app.Attribute("Id"));
        Assert.Equal("HermesHQ.exe", (string?)app.Attribute("Executable"));
        Assert.Equal("Windows.FullTrustApplication", (string?)app.Attribute("EntryPoint"));
        var ve = app.Element(uap + "VisualElements")!;
        Assert.Equal(@"Assets\HermesHQ-256.png", (string?)ve.Attribute("Square150x150Logo"));
        Assert.Equal(@"Assets\HermesHQ-256.png", (string?)ve.Attribute("Square44x44Logo"));
        var tdf = m.Root.Element(f + "Dependencies")!.Element(f + "TargetDeviceFamily")!;
        Assert.Equal("Windows.Desktop", (string?)tdf.Attribute("Name"));
        Assert.Equal("10.0.17763.0", (string?)tdf.Attribute("MinVersion"));
        Assert.Equal("runFullTrust", (string?)m.Root.Element(f + "Capabilities")!.Element(rescap + "Capability")!.Attribute("Name"));
        // Every published file, in order, mapped to its own relative path with Windows separators.
        Assert.Equal(["Assets\\HermesHQ-256.png", "HermesHQ.dll", "HermesHQ.exe", "HermesHQ.runtimeconfig.json", "resources.pri", "runtimes\\win-x64\\native\\Example Native.dll"],
                     plan.Files.Select(x => x.Target).ToArray());
        Assert.All(plan.Files, x => Assert.StartsWith(Path.GetFullPath(p), x.Source));
        Assert.Empty(Manifest.Problems(m, packageVersion, "x64", t => plan.Files.Any(x => x.Target == t)));
    }

    [Theory]
    [InlineData("HermesHQ.pri", false)]
    [InlineData("hermeshq.PRI", false)]
    [InlineData("HermesHQ.pri", true)]
    public void ThePublishedAppIndexKeepsItsOriginalPackagePath(string name, bool keepGeneric)
    {
        var p = Publish();
        var generic = Path.Combine(p, "resources.pri");
        if (!keepGeneric) File.Delete(generic);
        var index = Path.Combine(p, name);
        File.WriteAllBytes(index, [4, 5, 6]);
        var (plan, mapping) = Packer.Plan(p, AppProject, "x64", Out("work"));
        var entries = Mapping.Parse(File.ReadAllText(mapping));
        Assert.Contains((index, name), entries);
        var genericEntries = entries.Where(e => e.Target.Equals("resources.pri", StringComparison.OrdinalIgnoreCase)).ToArray();
        if (keepGeneric) Assert.Equal((generic, "resources.pri"), Assert.Single(genericEntries));
        else Assert.Empty(genericEntries);
        Assert.Equal(plan.Files.Count + 1, entries.Count); // plus the generated manifest
        Assert.Equal(new byte[] { 4, 5, 6 }, File.ReadAllBytes(index));
    }

    [Theory]
    [InlineData("Microsoft.UI.pri")]
    [InlineData("fr/HermesHQ.pri")]
    [InlineData("fr/resources.pri")]
    public void FrameworkOrNestedIndicesDoNotReplaceTheRootAppIndex(string relative)
    {
        var p = Publish();
        var other = Path.Combine(p, relative);
        Directory.CreateDirectory(Path.GetDirectoryName(other)!);
        File.Move(Path.Combine(p, "resources.pri"), other);
        var error = Assert.Throws<PackException>(() => Packer.Plan(p, AppProject, "x64", Out("work")));
        Assert.Contains("resources.pri", error.Message);
        Assert.False(Directory.Exists(Out("work")));
    }

    [Fact]
    public void Arm64PlansAnArm64Package()
    {
        var plan = MsixPlan.Create(Publish("arm64"), AppProject, "arm64");
        Assert.Contains("ProcessorArchitecture=\"arm64\"", plan.ManifestXml);
    }

    [Fact]
    public void TheMappingFileQuotesEverySourceAndTargetAndCarriesTheManifest()
    {
        var plan = MsixPlan.Create(Publish(), AppProject, "x64");
        var work = Out("work");
        var mapping = plan.WriteInputs(work);
        var lines = File.ReadAllLines(mapping);
        Assert.Equal("[Files]", lines[0]);
        var parsed = Mapping.Parse(File.ReadAllText(mapping));
        Assert.Equal("AppxManifest.xml", parsed[0].Target);
        Assert.Equal(Path.Combine(work, "AppxManifest.xml"), parsed[0].Source);
        Assert.Equal(plan.Files.Select(x => (x.Source, x.Target)), parsed.Skip(1).Select(x => (x.Source, x.Target)));
        Assert.Equal(plan.ManifestXml, File.ReadAllText(Path.Combine(work, "AppxManifest.xml")));
        // The same inputs twice are byte for byte the same.
        var again = plan.WriteInputs(Out("work2"));
        Assert.Equal(File.ReadAllText(mapping).Replace(work, "W"), File.ReadAllText(again).Replace(Out("work2"), "W"));
    }

    [Fact]
    public void AnotherPublisherOrIdentityIsAProblem()
    {
        var plan = MsixPlan.Create(Publish(), AppProject, "x64");
        bool Has(string t) => plan.Files.Any(x => x.Target == t);
        var contoso = XDocument.Parse(plan.ManifestXml.Replace("CN=Hermes HQ Unsigned Local Build", "CN=Contoso Ltd"));
        Assert.Contains(Manifest.Problems(contoso, CurrentPackageVersion, "x64", Has), s => s.Contains("Publisher"));
        var other = XDocument.Parse(plan.ManifestXml.Replace("Executable=\"HermesHQ.exe\"", "Executable=\"Other.exe\""));
        Assert.Contains(Manifest.Problems(other, CurrentPackageVersion, "x64", Has), s => s.Contains("Executable"));
        Assert.Contains(Manifest.Problems(XDocument.Parse(plan.ManifestXml), CurrentPackageVersion, "arm64", Has), s => s.Contains("ProcessorArchitecture"));
        Assert.Contains(Manifest.Problems(XDocument.Parse(plan.ManifestXml), "0.2.0.0", "x64", Has), s => s.Contains("Version"));
        Assert.Contains(Manifest.Problems(XDocument.Parse(plan.ManifestXml), CurrentPackageVersion, "x64", t => t != @"Assets\HermesHQ-256.png" && Has(t)), s => s.Contains("logo"));
    }

    // ---------------------------------------------------------------- failing early

    [Theory]
    [InlineData("HermesHQ.exe")]
    [InlineData("HermesHQ.dll")]
    [InlineData("HermesHQ.runtimeconfig.json")]
    [InlineData("resources.pri")]
    [InlineData("Assets/HermesHQ-256.png")]
    public void AMissingPayloadFileStopsThePlan(string file)
    {
        var p = Publish();
        File.Delete(Path.Combine(p, file));
        var e = Assert.Throws<PackException>(() => MsixPlan.Create(p, AppProject, "x64"));
        Assert.Contains(file.Replace('/', '\\'), e.Message);
    }

    [Fact]
    public void AMissingOrEmptyPublishFolderStopsThePlan()
    {
        Assert.Throws<PackException>(() => MsixPlan.Create(Path.Combine(root, "nope"), AppProject, "x64"));
        Directory.CreateDirectory(Path.Combine(root, "empty"));
        Assert.Throws<PackException>(() => MsixPlan.Create(Path.Combine(root, "empty"), AppProject, "x64"));
    }

    [Fact]
    public void AnExecutableForTheOtherArchitectureStopsThePlan()
    {
        var p = Publish("x64");
        var e = Assert.Throws<PackException>(() => MsixPlan.Create(p, AppProject, "arm64"));
        Assert.Contains("x64", e.Message);
        File.WriteAllText(Path.Combine(p, "HermesHQ.exe"), "not a PE file");
        Assert.Throws<PackException>(() => MsixPlan.Create(p, AppProject, "x64"));
        Assert.Throws<PackException>(() => MsixPlan.Create(Publish("arm64"), AppProject, "x86"));
    }

    [Fact]
    public void ALogoThatIsNotASquarePngOfAtLeast150PxStopsThePlan()
    {
        var p = Publish();
        var logo = Path.Combine(p, "Assets", "HermesHQ-256.png");
        File.WriteAllBytes(logo, Png(256, 128));
        Assert.Throws<PackException>(() => MsixPlan.Create(p, AppProject, "x64"));
        File.WriteAllBytes(logo, Png(64, 64));
        Assert.Throws<PackException>(() => MsixPlan.Create(p, AppProject, "x64"));
        File.WriteAllText(logo, "GIF89a");
        Assert.Throws<PackException>(() => MsixPlan.Create(p, AppProject, "x64"));
    }

    [Theory]
    [InlineData(@"..\evil.dll")]
    [InlineData(@"a\..\..\evil.dll")]
    [InlineData(@"a\.\b.dll")]
    [InlineData(@"C:\Windows\evil.dll")]
    [InlineData(@"\evil.dll")]
    [InlineData(@"a\\b.dll")]
    [InlineData("a\"b.dll")]
    [InlineData("AppxManifest.xml")]
    [InlineData("appxblockmap.xml")]
    [InlineData("AppxSignature.p7x")]
    [InlineData("[Content_Types].xml")]
    [InlineData(@"AppxMetadata\CodeIntegrity.cat")]
    public void TraversalRootedQuotedAndReservedTargetsAreRefused(string target) => Assert.Throws<PackException>(() => Inputs.Target(target));

    [Fact]
    public void AReservedFileInThePublishFolderStopsThePlan()
    {
        var p = Publish();
        File.WriteAllText(Path.Combine(p, "AppxManifest.xml"), "<Package/>");
        Assert.Contains("AppxManifest.xml", Assert.Throws<PackException>(() => MsixPlan.Create(p, AppProject, "x64")).Message);
    }

    [Fact]
    public void ALinkInThePublishFolderStopsThePlan()
    {
        var p = Publish();
        var outside = Path.Combine(root, "outside.txt");
        File.WriteAllText(outside, "outside the publish folder");
        try { File.CreateSymbolicLink(Path.Combine(p, "linked.txt"), outside); }
        catch (Exception) when (RuntimeInformation.IsOSPlatform(OSPlatform.Windows)) { return; }   // no symlink privilege
        Assert.Contains("link", Assert.Throws<PackException>(() => MsixPlan.Create(p, AppProject, "x64")).Message);
    }

    [Fact]
    public void ThePackageAndWorkFolderMayNotSitInsideThePublishFolder()
    {
        var p = Publish();
        Assert.Throws<PackException>(() => Packer.Run(p, AppProject, "x64", Path.Combine(p, "HermesHQ.msix"), Out("w"), new ZipMakeAppx()));
        Assert.Throws<PackException>(() => Packer.Run(p, AppProject, "x64", Out("HermesHQ.msix"), Path.Combine(p, "work"), new ZipMakeAppx()));
    }

    // ---------------------------------------------------------------- pack, unpack, check

    [Fact]
    public void PackThenUnpackMatchesThePlanFileByFile()
    {
        var p = Publish();
        var result = Packer.Run(p, AppProject, "x64", Out("HermesHQ-x64-unsigned.msix"), Out("work"), new ZipMakeAppx());
        Assert.True(File.Exists(result.Package));
        Assert.Equal(6, result.Files);
        Assert.Equal(CurrentPackageVersion, result.Version);
        Assert.True(File.Exists(Path.Combine(result.Unpacked, "AppxManifest.xml")));
        Assert.False(File.Exists(Path.Combine(result.Unpacked, "AppxSignature.p7x")));
    }

    [Fact]
    public void AToolFailureStopsThePack()
    {
        var p = Publish();
        Assert.Contains("pack failed", Assert.Throws<PackException>(() => Packer.Run(p, AppProject, "x64", Out("a.msix"), Out("w1"), new ZipMakeAppx { FailPack = true })).Message);
        Assert.Contains("unpack failed", Assert.Throws<PackException>(() => Packer.Run(p, AppProject, "x64", Out("b.msix"), Out("w2"), new ZipMakeAppx { FailUnpack = true })).Message);
        Assert.Contains("no package", Assert.Throws<PackException>(() => Packer.Run(p, AppProject, "x64", Out("c.msix"), Out("w3"), new ZipMakeAppx { WriteNothing = true })).Message);
    }

    [Theory]
    [InlineData("changed", "differs")]
    [InlineData("dropped", "missing")]
    [InlineData("extra", "not in the plan")]
    [InlineData("signed", "AppxSignature.p7x")]
    [InlineData("manifest", $"Identity Version is \"{PreviousPackageVersion}\", expected \"{CurrentPackageVersion}\"")]
    [InlineData("noblockmap", "AppxBlockMap.xml")]
    public void AnUnpackedPackageThatDiffersFromThePlanIsRefused(string tamper, string expected)
    {
        var p = Publish();
        var e = Assert.Throws<PackException>(() => Packer.Run(p, AppProject, "x64", Out("t.msix"), Out("w"), new ZipMakeAppx { Tamper = tamper }));
        Assert.Contains(expected, e.Message);
    }

    [Fact]
    public void TheRealMakeAppxRunnerReportsAMissingOrFailingTool()
    {
        var plan = MsixPlan.Create(Publish(), AppProject, "x64");
        var mapping = plan.WriteInputs(Out("w"));
        Assert.Contains("not found", Assert.Throws<PackException>(() => new MakeAppxProcess(Path.Combine(root, "no-makeappx.exe")).Pack(mapping, Out("x.msix"))).Message);
        string fake;
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
        {
            fake = Path.Combine(root, "fail.cmd");
            File.WriteAllText(fake, "@echo MakeAppx : error: synthetic failure\r\n@exit /b 3\r\n");
        }
        else
        {
            fake = Path.Combine(root, "fail.sh");
            File.WriteAllText(fake, "#!/bin/sh\necho 'MakeAppx : error: synthetic failure'\nexit 3\n");
            File.SetUnixFileMode(fake, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        }
        var e = Assert.Throws<PackException>(() => new MakeAppxProcess(fake).Pack(mapping, Out("x.msix")));
        Assert.Contains("exit 3", e.Message);
        Assert.Contains("synthetic failure", e.Message);
    }

    // ---------------------------------------------------------------- [WIN-PACK-OUTPUTS] a bounded tool, kept outputs

    private static bool OnWindows => RuntimeInformation.IsOSPlatform(OSPlatform.Windows);

    /// A short-lived synthetic stand-in for MakeAppx: a .cmd on Windows, a sh script elsewhere.
    private string Tool(string name, string sh, string cmd)
    {
        if (OperatingSystem.IsWindows())
        {
            var c = Path.Combine(root, name + ".cmd");
            File.WriteAllText(c, cmd.Replace("\n", "\r\n"));
            return c;
        }
        var f = Path.Combine(root, name + ".sh");
        File.WriteAllText(f, "#!/bin/sh\n" + sh);
        File.SetUnixFileMode(f, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        return f;
    }

    private static bool Running(int pid)
    {
        try { using var p = System.Diagnostics.Process.GetProcessById(pid); return !p.HasExited; }
        catch (ArgumentException) { return false; }
        catch (InvalidOperationException) { return false; }
    }

    private static bool GoneWithin(int pid, TimeSpan t)
    {
        var until = DateTime.UtcNow + t;
        while (Running(pid)) { if (DateTime.UtcNow > until) return false; Thread.Sleep(25); }
        return true;
    }

    /// Every file under a folder with its SHA-256 (relative paths, sorted).
    private static string[] Snapshot(string dir) =>
        Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories)
            .Select(f => Path.GetRelativePath(dir, f) + " " + Inputs.Sha256(f)).OrderBy(x => x, StringComparer.Ordinal).ToArray();

    private string[] Staging() => Directory.Exists(Out("")) ? Directory.GetFileSystemEntries(Out(""), Outputs.StagingPrefix + "*") : [];

    [Fact]
    public void TheToolRunnerReturnsOnASuccessfulExitWithOutputOnBothStreams()
    {
        var tool = Tool("ok", "echo packed\necho note 1>&2\nexit 0\n", "@echo packed\n@echo note 1>&2\n@exit /b 0\n");
        var sw = System.Diagnostics.Stopwatch.StartNew();
        new MakeAppxProcess(tool, TimeSpan.FromSeconds(20)).Pack(Out("m.txt"), Out("x.msix"));
        Assert.True(sw.Elapsed < TimeSpan.FromSeconds(15));
    }

    [Fact]
    public void ANonzeroExitKeepsTheToolsStdoutAndStderr()
    {
        var tool = Tool("bad", "echo 'on stdout: step 1'\necho 'MakeAppx : error: synthetic failure' 1>&2\nexit 7\n",
                        "@echo on stdout: step 1\n@echo MakeAppx : error: synthetic failure 1>&2\n@exit /b 7\n");
        var e = Assert.Throws<PackException>(() => new MakeAppxProcess(tool, TimeSpan.FromSeconds(20)).Unpack(Out("x.msix"), Out("u")));
        Assert.Contains("unpack failed (exit 7)", e.Message);
        Assert.Contains("on stdout: step 1", e.Message);
        Assert.Contains("synthetic failure", e.Message);
    }

    [Fact]
    public void AStalledToolIsStoppedAtTheLimitWithItsOutputAndItsOwnProcessTreeIsReaped()
    {
        var pids = Path.Combine(root, "pids");
        var tool = Tool("stall", $"echo partial-output\necho $$ > '{pids}'\nsleep 30 &\necho $! >> '{pids}'\nwait\n",
                        "@echo partial-output\n@ping -n 30 127.0.0.1 >nul\n");
        var sw = System.Diagnostics.Stopwatch.StartNew();
        var e = Assert.Throws<PackException>(() => new MakeAppxProcess(tool, TimeSpan.FromSeconds(1)).Pack(Out("m.txt"), Out("x.msix")));
        Assert.True(sw.Elapsed < TimeSpan.FromSeconds(10), $"took {sw.Elapsed.TotalSeconds:F1}s");
        Assert.Contains("pack timed out", e.Message);
        Assert.Contains("stopped its process", e.Message);
        Assert.Contains("partial-output", e.Message);
        if (OnWindows) return;
        var ids = File.ReadAllLines(pids).Select(int.Parse).ToArray();
        Assert.Equal(2, ids.Length);
        Assert.All(ids, id => Assert.True(GoneWithin(id, TimeSpan.FromSeconds(5)), $"process {id} still runs"));
    }

    [Fact]
    public void ADescendantHoldingStdoutOpenAfterTheToolExitsIsBoundedByTheSameLimit()
    {
        if (OnWindows) return;   // a detached holder is a POSIX shell idiom; the stalled-tool test covers Windows
        var holder = Path.Combine(root, "holder");
        var tool = Tool("held", $"echo partial\nsh -c 'echo $$ > \"{holder}\"; exec sleep 20' &\nexit 0\n", "");
        try
        {
            var sw = System.Diagnostics.Stopwatch.StartNew();
            var e = Assert.Throws<PackException>(() => new MakeAppxProcess(tool, TimeSpan.FromSeconds(1)).Pack(Out("m.txt"), Out("x.msix")));
            Assert.True(sw.Elapsed < TimeSpan.FromSeconds(10), $"Pack returned after {sw.Elapsed.TotalSeconds:F1}s");
            Assert.Contains("kept its output open", e.Message);
            Assert.Contains("partial", e.Message);
        }
        finally
        {
            // The holder escaped the tool's tree, so the runner leaves it; the test owns it and stops it.
            if (File.Exists(holder) && int.TryParse(File.ReadAllText(holder).Trim(), out var id) && Running(id))
                try { using var h = System.Diagnostics.Process.GetProcessById(id); h.Kill(); h.WaitForExit(5000); } catch { }
        }
    }

    [Fact]
    public void AnUnownedWorkFolderIsRefusedAndItsMarkerBytesSurvive()
    {
        var p = Publish();
        Directory.CreateDirectory(Out("work"));
        File.WriteAllBytes(Path.Combine(Out("work"), "marker.bin"), [0xC0, 0xFF, 0xEE]);
        var e = Assert.Throws<PackException>(() => Packer.Run(p, AppProject, "x64", Out("a.msix"), Out("work"), new ZipMakeAppx()));
        Assert.Contains("isn't one this tool made", e.Message);
        Assert.Throws<PackException>(() => Packer.Plan(p, AppProject, "x64", Out("work")));
        Assert.Equal([0xC0, 0xFF, 0xEE], File.ReadAllBytes(Path.Combine(Out("work"), "marker.bin")));
        Assert.Single(Directory.GetFileSystemEntries(Out("work")));
        Assert.False(File.Exists(Out("a.msix")));
        Assert.Empty(Staging());
    }

    [Fact]
    public void AnUnverifiedPackageAtTheOutputIsRefusedAndKept()
    {
        var p = Publish();
        Directory.CreateDirectory(Out(""));
        File.WriteAllBytes(Out("a.msix"), [1, 2, 3, 4]);
        Assert.Contains("last verified", Assert.Throws<PackException>(() => Packer.Run(p, AppProject, "x64", Out("a.msix"), Out("work"), new ZipMakeAppx())).Message);
        Assert.Equal([1, 2, 3, 4], File.ReadAllBytes(Out("a.msix")));
        Assert.False(Directory.Exists(Out("work")));
        // A verified package that was since changed is no longer the tool's either.
        Packer.Run(p, AppProject, "x64", Out("b.msix"), Out("work"), new ZipMakeAppx());
        File.AppendAllText(Out("b.msix"), "x");
        var changed = File.ReadAllBytes(Out("b.msix"));
        Assert.Throws<PackException>(() => Packer.Run(p, AppProject, "x64", Out("b.msix"), Out("work"), new ZipMakeAppx()));
        Assert.Equal(changed, File.ReadAllBytes(Out("b.msix")));
    }

    [Fact]
    public void OutputsThatOverlapTheInputsOrEachOtherAreRefusedWithoutDeletingAnything()
    {
        var p = Publish();
        var before = Snapshot(p);
        // A work folder that holds the publish folder (the old code would have deleted the publish folder with it).
        Assert.Contains("holds the publish folder", Assert.Throws<PackException>(() => Packer.Run(p, AppProject, "x64", Path.Combine(root, "x.msix"), root, new ZipMakeAppx())).Message);
        Assert.Contains("holds the publish folder", Assert.Throws<PackException>(() => Packer.Plan(p, AppProject, "x64", root)).Message);
        Assert.Contains("holds the project", Assert.Throws<PackException>(() => Packer.Plan(p, AppProject, "x64", Path.GetDirectoryName(AppProject)!)).Message);
        Assert.Equal(before, Snapshot(p));
        Assert.Throws<PackException>(() => Packer.Run(p, AppProject, "x64", Out("work"), Out("work"), new ZipMakeAppx()));
        Assert.Contains(".msix", Assert.Throws<PackException>(() => Packer.Run(p, AppProject, "x64", Out("a.txt"), Out("work"), new ZipMakeAppx())).Message);
        Assert.Contains("same folder", Assert.Throws<PackException>(() => Packer.Run(p, AppProject, "x64", Path.Combine(root, "elsewhere", "a.msix"), Out("work"), new ZipMakeAppx())).Message);
        Directory.CreateDirectory(Out("dir.msix"));
        File.WriteAllBytes(Path.Combine(Out("dir.msix"), "marker.bin"), [9]);
        Assert.Contains("is a folder", Assert.Throws<PackException>(() => Packer.Run(p, AppProject, "x64", Out("dir.msix"), Out("work"), new ZipMakeAppx())).Message);
        Assert.Equal([9], File.ReadAllBytes(Path.Combine(Out("dir.msix"), "marker.bin")));
        Assert.Empty(Staging());
    }

    [Theory]
    [InlineData("failpack")]
    [InlineData("failunpack")]
    [InlineData("nothing")]
    [InlineData("tamper")]
    [InlineData("timeout")]
    public void AnyFailureLeavesTheLastVerifiedPackageAndWorkFolderByteForByte(string failure)
    {
        var p = Publish();
        var first = Packer.Run(p, AppProject, "x64", Out("HermesHQ.msix"), Out("work"), new ZipMakeAppx());
        File.WriteAllBytes(Path.Combine(Out("work"), "marker.bin"), [0xC0, 0xFF, 0xEE]);   // the tool's folder, with marker bytes
        var package = File.ReadAllBytes(first.Package);
        var work = Snapshot(Out("work"));

        IMakeAppx tool = failure switch
        {
            "failpack" => new ZipMakeAppx { FailPack = true },
            "failunpack" => new ZipMakeAppx { FailUnpack = true },
            "nothing" => new ZipMakeAppx { WriteNothing = true },
            "tamper" => new ZipMakeAppx { Tamper = "changed" },
            _ => new MakeAppxProcess(Tool("stall", $"echo partial-output\necho $$ > '{Path.Combine(root, "pids")}'\nsleep 30\n",
                                          "@echo partial-output\n@ping -n 30 127.0.0.1 >nul\n"), TimeSpan.FromSeconds(1)),
        };
        var e = Assert.Throws<PackException>(() => Packer.Run(p, AppProject, "x64", Out("HermesHQ.msix"), Out("work"), tool));
        if (failure == "timeout")
        {
            Assert.Contains("timed out", e.Message);
            if (!OnWindows) Assert.True(GoneWithin(int.Parse(File.ReadAllText(Path.Combine(root, "pids")).Trim()), TimeSpan.FromSeconds(5)));
        }

        Assert.Equal(package, File.ReadAllBytes(Out("HermesHQ.msix")));
        Assert.Equal(work, Snapshot(Out("work")));
        Assert.Equal([0xC0, 0xFF, 0xEE], File.ReadAllBytes(Path.Combine(Out("work"), "marker.bin")));
        if (!OnWindows || failure != "timeout") Assert.Empty(Staging());
    }

    [Fact]
    public void ASuccessfulRunReplacesItsOwnPreviousOutputsAndRecordsThePackage()
    {
        var p = Publish();
        Packer.Run(p, AppProject, "x64", Out("HermesHQ.msix"), Out("work"), new ZipMakeAppx());
        File.WriteAllBytes(Path.Combine(Out("work"), "stale.bin"), [1]);
        File.AppendAllText(Path.Combine(p, "resources.pri"), "v2");   // a new publish
        var r = Packer.Run(p, AppProject, "x64", Out("HermesHQ.msix"), Out("work"), new ZipMakeAppx());
        Assert.False(File.Exists(Path.Combine(Out("work"), "stale.bin")));
        Assert.Equal(Inputs.Sha256(Path.Combine(p, "resources.pri")), Inputs.Sha256(Path.Combine(r.Unpacked, "resources.pri")));
        var owner = Outputs.ReadOwner(Out("work"))!;
        Assert.Equal("HermesHQ.msix", owner.Package);
        Assert.Equal(Inputs.Sha256(r.Package), owner.Sha256);
        // The committed mapping names the committed manifest, not the staging folder.
        Assert.Equal(Path.Combine(Path.GetFullPath(Out("work")), "AppxManifest.xml"), Mapping.Parse(File.ReadAllText(Path.Combine(Out("work"), "mapping.txt")))[0].Source);
        Assert.Empty(Staging());
        // plan reuses the tool's own work folder too.
        var (_, mapping) = Packer.Plan(p, AppProject, "x64", Out("work"));
        Assert.True(File.Exists(mapping));
        Assert.False(Directory.Exists(Path.Combine(Out("work"), "unpacked")));
    }

    /// Plays MakeAppx: pack zips the mapping (plus a block map and content types, as MakeAppx adds); unpack extracts.
    private sealed class ZipMakeAppx : IMakeAppx
    {
        public bool FailPack, FailUnpack, WriteNothing;
        public string? Tamper;

        public void Pack(string mappingFile, string package)
        {
            if (FailPack) throw new PackException("MakeAppx pack failed (exit 1): synthetic");
            if (WriteNothing) return;
            Directory.CreateDirectory(Path.GetDirectoryName(package)!);
            using var zip = ZipFile.Open(package, ZipArchiveMode.Create);
            foreach (var (source, target) in Mapping.Parse(File.ReadAllText(mappingFile)))
            {
                if (Tamper == "dropped" && target == "resources.pri") continue;
                if (Tamper == "manifest" && target == "AppxManifest.xml")
                {
                    using var w = new StreamWriter(zip.CreateEntry(target).Open());
                    var manifest = XDocument.Load(source);
                    manifest.Root!.Element(Manifest.F + "Identity")!.SetAttributeValue("Version", PreviousPackageVersion);
                    manifest.Save(w);
                    continue;
                }
                zip.CreateEntryFromFile(source, target.Replace('\\', '/'));
            }
            if (Tamper != "noblockmap") using (var w = new StreamWriter(zip.CreateEntry("AppxBlockMap.xml").Open())) w.Write("<BlockMap/>");
            using (var w = new StreamWriter(zip.CreateEntry("[Content_Types].xml").Open())) w.Write("<Types/>");
            if (Tamper == "extra") using (var w = new StreamWriter(zip.CreateEntry("stray.txt").Open())) w.Write("x");
            if (Tamper == "signed") using (var w = new StreamWriter(zip.CreateEntry("AppxSignature.p7x").Open())) w.Write("x");
        }

        public void Unpack(string package, string folder)
        {
            if (FailUnpack) throw new PackException("MakeAppx unpack failed (exit 1): synthetic");
            ZipFile.ExtractToDirectory(package, folder);
            if (Tamper == "changed") File.AppendAllText(Path.Combine(folder, "HermesHQ.runtimeconfig.json"), " ");
        }
    }
}
