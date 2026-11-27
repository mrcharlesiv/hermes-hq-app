using System.Diagnostics;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Xml.Linq;

namespace HermesHQ.MsixPack;

// [WIN-INSTALL-PACK] An opt-in, unsigned, local MSIX of an existing publish folder. It checks the inputs, writes the
// manifest and a MakeAppx mapping file, packs, unpacks and compares the unpacked package with the plan file by file.
// It never signs, installs, uploads or changes a trust store: an unsigned package won't install as is, and nothing here
// shows the packaged app runs, installs or upgrades.

public sealed class PackException(string message) : Exception(message);

/// The package's identity. A made-up local publisher on purpose: no production publisher is claimed, and a signed
/// release will need its own certificate subject here (an open gate).
public static class Identity
{
    public const string Name = "HermesHQ.LocalUnsigned";
    public const string Publisher = "CN=Hermes HQ Unsigned Local Build";
    public const string PublisherDisplayName = "Hermes HQ (unsigned local build)";
    public const string DisplayName = "Hermes HQ";   // the Mac's HQ_DISPLAY_NAME (project.yml)
    public const string Description = "Hermes HQ";
    public const string ApplicationId = "HermesHQ";
    public const string Executable = "HermesHQ.exe";
    public const string ManagedApp = "HermesHQ.dll";
    public const string Logo = @"Assets\HermesHQ-256.png";   // the app's own icon, already in the publish folder
    public const string MinVersion = "10.0.17763.0";          // HermesHQ.Windows.csproj TargetPlatformMinVersion
    public const string MaxVersionTested = "10.0.26100.0";    // the Windows SDK build tools the app references

    /// Required in addition to the root app resource index (published under either name below).
    public static readonly string[] Required = [Executable, ManagedApp, "HermesHQ.runtimeconfig.json", Logo];
    public const string PublishedIndex = "HermesHQ.pri";
    public const string DefaultIndex = "resources.pri";

    /// MakeAppx writes these itself; a payload file by any of these names would collide or pose as a signature.
    public static readonly string[] Reserved = ["AppxManifest.xml", "AppxBlockMap.xml", "AppxSignature.p7x", "[Content_Types].xml"];

    public static readonly Dictionary<string, ushort> Machines = new() { ["x64"] = 0x8664, ["arm64"] = 0xAA64 };
}

public static class Inputs
{
    /// The project's version as a package version: three or four numbers of 0–65535, the fourth (revision) 0.
    public static string PackageVersion(string version)
    {
        var parts = (version ?? "").Split('.');
        if (parts.Length is < 3 or > 4) throw new PackException($"version \"{version}\" needs 3 or 4 numbers (major.minor.build[.0])");
        foreach (var p in parts)
            if (p.Length == 0 || p.Length > 5 || !p.All(char.IsAsciiDigit) || int.Parse(p) > 65535)
                throw new PackException($"version \"{version}\": \"{p}\" isn't a number from 0 to 65535");
        if (parts.Length == 4 && int.Parse(parts[3]) != 0) throw new PackException($"version \"{version}\": the revision (4th number) must be 0");
        return string.Join('.', parts.Select(p => int.Parse(p).ToString()).Concat(parts.Length == 3 ? ["0"] : []));
    }

    /// A package path: relative, backslashes, no empty / . / .. segments, no drive, quote or control character, not a
    /// name MakeAppx owns.
    public static string Target(string relative)
    {
        var t = relative.Replace('/', '\\');
        if (t.Length == 0 || t.StartsWith('\\') || t.Contains(':') || Path.IsPathRooted(relative)) throw new PackException($"\"{relative}\" isn't a relative package path");
        if (t.Any(c => c == '"' || char.IsControl(c) || c is '*' or '?' or '<' or '>' or '|')) throw new PackException($"\"{relative}\" has a character a package path can't hold");
        if (t.Split('\\').Any(s => s is "" or "." or "..")) throw new PackException($"\"{relative}\" leaves or skips a folder (traversal)");
        if (Identity.Reserved.Any(r => r.Equals(t, StringComparison.OrdinalIgnoreCase)) || t.StartsWith(@"AppxMetadata\", StringComparison.OrdinalIgnoreCase))
            throw new PackException($"\"{relative}\" is a name MakeAppx writes itself; it can't come from the publish folder");
        return t;
    }

    /// The machine a PE file was built for (IMAGE_FILE_HEADER.Machine).
    public static ushort PeMachine(string path)
    {
        var b = new byte[4096];
        int n;
        using (var f = File.OpenRead(path)) n = f.Read(b, 0, b.Length);
        if (n < 0x40 || b[0] != 'M' || b[1] != 'Z') throw new PackException($"{Path.GetFileName(path)} isn't a Windows executable (no MZ header)");
        var pe = BitConverter.ToInt32(b, 0x3C);
        if (pe < 0x40 || pe + 6 > n || b[pe] != 'P' || b[pe + 1] != 'E' || b[pe + 2] != 0 || b[pe + 3] != 0)
            throw new PackException($"{Path.GetFileName(path)} isn't a Windows executable (no PE header)");
        return BitConverter.ToUInt16(b, pe + 4);
    }

    public static string MachineName(ushort m) => Identity.Machines.FirstOrDefault(kv => kv.Value == m).Key ?? $"0x{m:X4}";

    /// A PNG's width and height (its IHDR).
    public static (int Width, int Height) PngSize(string path)
    {
        var b = new byte[24];
        int n;
        using (var f = File.OpenRead(path)) n = f.Read(b, 0, b.Length);
        byte[] sig = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
        if (n < 24 || !b.AsSpan(0, 8).SequenceEqual(sig) || Encoding.ASCII.GetString(b, 12, 4) != "IHDR")
            throw new PackException($"{Path.GetFileName(path)} isn't a PNG");
        static int Be(byte[] x, int i) => (x[i] << 24) | (x[i + 1] << 16) | (x[i + 2] << 8) | x[i + 3];
        return (Be(b, 16), Be(b, 20));
    }

    public static string Sha256(string path)
    {
        using var f = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(f));
    }
}

/// MakeAppx's mapping file: `[Files]`, then one `"source" "target"` per line.
public static class Mapping
{
    public static string Write(IEnumerable<(string Source, string Target)> files)
    {
        var sb = new StringBuilder("[Files]\r\n");
        foreach (var (s, t) in files)
        {
            if (s.Contains('"') || t.Contains('"')) throw new PackException($"a quote in \"{s}\" or \"{t}\" would break the mapping file");
            sb.Append('"').Append(s).Append("\" \"").Append(t).Append("\"\r\n");
        }
        return sb.ToString();
    }

    private static readonly Regex Line = new("^\"([^\"]+)\"\\s+\"([^\"]+)\"$");

    public static List<(string Source, string Target)> Parse(string text)
    {
        var lines = text.Split('\n').Select(l => l.TrimEnd('\r')).Where(l => l.Length > 0).ToList();
        if (lines.Count == 0 || lines[0] != "[Files]") throw new PackException("the mapping file doesn't start with [Files]");
        return lines.Skip(1).Select(l =>
        {
            var m = Line.Match(l);
            if (!m.Success) throw new PackException($"mapping line isn't \"source\" \"target\": {l}");
            return (m.Groups[1].Value, m.Groups[2].Value);
        }).ToList();
    }
}

public static class Manifest
{
    public static readonly XNamespace F = "http://schemas.microsoft.com/appx/manifest/foundation/windows10";
    public static readonly XNamespace Uap = "http://schemas.microsoft.com/appx/manifest/uap/windows10";
    public static readonly XNamespace Rescap = "http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities";

    public static string Create(string version, string arch)
    {
        var doc = new XDocument(new XDeclaration("1.0", "utf-8", null),
            new XElement(F + "Package",
                new XAttribute(XNamespace.Xmlns + "uap", Uap), new XAttribute(XNamespace.Xmlns + "rescap", Rescap),
                new XAttribute("IgnorableNamespaces", "uap rescap"),
                new XElement(F + "Identity", new XAttribute("Name", Identity.Name), new XAttribute("Publisher", Identity.Publisher),
                    new XAttribute("Version", version), new XAttribute("ProcessorArchitecture", arch)),
                new XElement(F + "Properties",
                    new XElement(F + "DisplayName", Identity.DisplayName),
                    new XElement(F + "PublisherDisplayName", Identity.PublisherDisplayName),
                    new XElement(F + "Logo", Identity.Logo)),
                new XElement(F + "Dependencies",
                    new XElement(F + "TargetDeviceFamily", new XAttribute("Name", "Windows.Desktop"),
                        new XAttribute("MinVersion", Identity.MinVersion), new XAttribute("MaxVersionTested", Identity.MaxVersionTested))),
                new XElement(F + "Resources", new XElement(F + "Resource", new XAttribute("Language", "en-us"))),
                new XElement(F + "Applications",
                    new XElement(F + "Application", new XAttribute("Id", Identity.ApplicationId), new XAttribute("Executable", Identity.Executable),
                        new XAttribute("EntryPoint", "Windows.FullTrustApplication"),
                        new XElement(Uap + "VisualElements", new XAttribute("DisplayName", Identity.DisplayName),
                            new XAttribute("Description", Identity.Description), new XAttribute("BackgroundColor", "transparent"),
                            new XAttribute("Square150x150Logo", Identity.Logo), new XAttribute("Square44x44Logo", Identity.Logo)))),
                new XElement(F + "Capabilities", new XElement(Rescap + "Capability", new XAttribute("Name", "runFullTrust")))));
        using var w = new Utf8Writer();
        doc.Save(w);
        return w.ToString();
    }

    private sealed class Utf8Writer : StringWriter { public override Encoding Encoding => new UTF8Encoding(false); }

    /// What's wrong with a manifest against the expected identity, version, architecture and payload (empty: nothing).
    public static List<string> Problems(XDocument doc, string version, string arch, Func<string, bool> inPayload)
    {
        var p = new List<string>();
        var root = doc.Root;
        if (root?.Name != F + "Package") return ["AppxManifest.xml has no Package root"];
        var id = root.Element(F + "Identity");
        void Expect(XElement? e, string attr, string want, string what)
        {
            var got = (string?)e?.Attribute(attr);
            if (got != want) p.Add($"{what} is \"{got}\", expected \"{want}\"");
        }
        Expect(id, "Name", Identity.Name, "Identity Name");
        Expect(id, "Publisher", Identity.Publisher, "Identity Publisher (only the local unsigned publisher; no production claim)");
        Expect(id, "Version", version, "Identity Version");
        Expect(id, "ProcessorArchitecture", arch, "Identity ProcessorArchitecture");
        var apps = root.Element(F + "Applications")?.Elements(F + "Application").ToList() ?? [];
        if (apps.Count != 1) p.Add($"{apps.Count} Application entries, expected 1");
        var app = apps.FirstOrDefault();
        Expect(app, "Executable", Identity.Executable, "Application Executable");
        Expect(app, "EntryPoint", "Windows.FullTrustApplication", "Application EntryPoint");
        var exe = (string?)app?.Attribute("Executable");
        if (exe != null && !inPayload(exe)) p.Add($"Application Executable {exe} isn't in the package");
        var ve = app?.Element(Uap + "VisualElements");
        var logos = new[] { ("Properties Logo", root.Element(F + "Properties")?.Element(F + "Logo")?.Value),
                            ("Square150x150Logo", (string?)ve?.Attribute("Square150x150Logo")),
                            ("Square44x44Logo", (string?)ve?.Attribute("Square44x44Logo")) };
        foreach (var (what, path) in logos)
            if (string.IsNullOrEmpty(path)) p.Add($"{what}: no logo");
            else if (!inPayload(path)) p.Add($"{what}: logo {path} isn't in the package");
        var tdf = root.Element(F + "Dependencies")?.Element(F + "TargetDeviceFamily");
        Expect(tdf, "Name", "Windows.Desktop", "TargetDeviceFamily Name");
        Expect(tdf, "MinVersion", Identity.MinVersion, "TargetDeviceFamily MinVersion");
        if (root.Element(F + "Capabilities")?.Element(Rescap + "Capability") is not { } cap || (string?)cap.Attribute("Name") != "runFullTrust")
            p.Add("the runFullTrust capability is missing");
        return p;
    }
}

public sealed record MsixPlan(string PublishDir, string Version, string Arch, IReadOnlyList<(string Source, string Target)> Files, string ManifestXml)
{
    /// The package version from HermesHQ.Windows.csproj's one <Version>.
    public static string ProjectPackageVersion(string csproj)
    {
        if (!File.Exists(csproj)) throw new PackException($"project {csproj} not found");
        var versions = XDocument.Load(csproj).Descendants("Version").Select(v => v.Value.Trim()).ToList();
        if (versions.Count != 1) throw new PackException($"{Path.GetFileName(csproj)} has {versions.Count} <Version> elements, expected 1");
        return Inputs.PackageVersion(versions[0]);
    }

    /// Checks the publish folder against the project and the architecture and lays out the package. Throws on the
    /// first thing wrong, before any tool runs.
    public static MsixPlan Create(string publishDir, string csproj, string arch)
    {
        if (!Identity.Machines.ContainsKey(arch)) throw new PackException($"architecture \"{arch}\" isn't x64 or arm64");
        var version = ProjectPackageVersion(csproj);
        var root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(publishDir));
        if (!Directory.Exists(root)) throw new PackException($"publish folder {root} not found (run dotnet publish first)");
        if (new DirectoryInfo(root).LinkTarget != null) throw new PackException($"publish folder {root} is a link");

        var files = new List<(string Source, string Target)>();
        var seen = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        void Walk(DirectoryInfo dir)
        {
            foreach (var e in dir.EnumerateFileSystemInfos().OrderBy(e => e.Name, StringComparer.Ordinal))
            {
                var rel = Path.GetRelativePath(root, e.FullName);
                if (e.LinkTarget != null || e.Attributes.HasFlag(FileAttributes.ReparsePoint))
                    throw new PackException($"{rel} is a link (symlink or junction); the package takes real files only");
                if (e is DirectoryInfo d) { Walk(d); continue; }
                var target = Inputs.Target(rel);
                if (!seen.TryAdd(target, rel)) throw new PackException($"{rel} and {seen[target]} map to the same package path");
                var source = Path.GetFullPath(e.FullName);
                if (!source.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.Ordinal)) throw new PackException($"{rel} resolves outside the publish folder");
                files.Add((source, target));
            }
        }
        Walk(new DirectoryInfo(root));
        if (files.Count == 0) throw new PackException($"publish folder {root} is empty");
        files.Sort((a, b) => StringComparer.OrdinalIgnoreCase.Compare(a.Target, b.Target) is var c && c != 0 ? c : string.CompareOrdinal(a.Target, b.Target));

        var missing = Identity.Required.Where(r => !seen.ContainsKey(r)).ToList();
        // WinUI publishes HermesHQ.pri beside the app. Do not substitute a dependency or rename the index.
        if (!seen.ContainsKey(Identity.PublishedIndex) && !seen.ContainsKey(Identity.DefaultIndex))
            missing.Add($"{Identity.PublishedIndex} or {Identity.DefaultIndex}");
        if (missing.Count > 0) throw new PackException($"the publish folder is missing {string.Join(", ", missing)}");
        string Src(string target) => files.First(f => f.Target.Equals(target, StringComparison.OrdinalIgnoreCase)).Source;

        var machine = Inputs.PeMachine(Src(Identity.Executable));
        if (machine != Identity.Machines[arch])
            throw new PackException($"{Identity.Executable} is built for {Inputs.MachineName(machine)}, but the package is {arch}");

        Version? managed;
        try { managed = AssemblyName.GetAssemblyName(Src(Identity.ManagedApp)).Version; }
        catch (Exception e) when (e is BadImageFormatException or FileLoadException) { throw new PackException($"{Identity.ManagedApp} isn't a .NET assembly: {e.Message}"); }
        if (managed?.ToString() != version)
            throw new PackException($"{Identity.ManagedApp} is version {managed}, but the project (and so the package) is {version}: publish again from this tree");

        var (w, h) = Inputs.PngSize(Src(Identity.Logo));
        if (w != h || w < 150) throw new PackException($"{Identity.Logo} is {w}×{h}; the logos need a square PNG of at least 150 px");

        var manifest = Manifest.Create(version, arch);
        var problems = Manifest.Problems(XDocument.Parse(manifest), version, arch, t => seen.ContainsKey(t));
        if (problems.Count > 0) throw new PackException("the manifest: " + string.Join("; ", problems));
        return new MsixPlan(root, version, arch, files, manifest);
    }

    /// Writes AppxManifest.xml and mapping.txt into a fresh work folder; returns the mapping file. The mapping names
    /// the manifest in `mappedDir` (default: the work folder itself), so inputs written in staging can point at the
    /// folder they are committed to.
    public string WriteInputs(string workDir, string? mappedDir = null)
    {
        Directory.CreateDirectory(workDir);
        var manifest = Path.Combine(Path.GetFullPath(workDir), "AppxManifest.xml");
        File.WriteAllText(manifest, ManifestXml, new UTF8Encoding(false));
        var mapping = Path.Combine(Path.GetFullPath(workDir), "mapping.txt");
        var mapped = Path.Combine(Path.GetFullPath(mappedDir ?? workDir), "AppxManifest.xml");
        File.WriteAllText(mapping, Mapping.Write(Files.Prepend((mapped, "AppxManifest.xml"))), new UTF8Encoding(false));
        return mapping;
    }
}

public interface IMakeAppx
{
    void Pack(string mappingFile, string package);
    void Unpack(string package, string folder);
}

/// The Windows SDK's MakeAppx.exe (pack-msix.ps1 finds it in the Microsoft.Windows.SDK.BuildTools package the app
/// already references, or in Windows Kits). Any exit but 0 is a failure, with its output.
/// [WIN-PACK-OUTPUTS] One bounded lifetime covers the tool's exit and the end of both its stdout and stderr: both are
/// read asynchronously, so neither a stalled tool nor a descendant holding a pipe open can block past the limit. On the
/// limit only the process this runner started (and its own process tree) is killed and reaped; the error carries the
/// last output lines.
public sealed class MakeAppxProcess(string exe, TimeSpan? lifetime = null) : IMakeAppx
{
    public static readonly TimeSpan DefaultLifetime = TimeSpan.FromMinutes(10);
    private static readonly TimeSpan ReapGrace = TimeSpan.FromSeconds(5);
    private const int KeptLines = 200, ShownLines = 40;
    private readonly TimeSpan limit = lifetime is { } l && l > TimeSpan.Zero ? l : DefaultLifetime;

    public void Pack(string mappingFile, string package) => Run("pack", "pack", "/o", "/h", "SHA256", "/f", mappingFile, "/p", package);
    public void Unpack(string package, string folder) => Run("unpack", "unpack", "/o", "/p", package, "/d", folder);

    private void Run(string what, params string[] args)
    {
        if (!File.Exists(exe)) throw new PackException($"MakeAppx {exe} not found");
        var psi = new ProcessStartInfo(exe) { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false };
        foreach (var a in args) psi.ArgumentList.Add(a);

        var lines = new Queue<string>();
        void Keep(string line) { lock (lines) { lines.Enqueue(line); while (lines.Count > KeptLines) lines.Dequeue(); } }
        string Tail() { lock (lines) return string.Join('\n', lines.TakeLast(ShownLines)); }
        var outDone = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var errDone = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        using var p = new Process { StartInfo = psi };
        p.OutputDataReceived += (_, e) => { if (e.Data is null) outDone.TrySetResult(); else Keep(e.Data); };
        p.ErrorDataReceived += (_, e) => { if (e.Data is null) errDone.TrySetResult(); else Keep(e.Data); };
        try { if (!p.Start()) throw new PackException($"MakeAppx {what} didn't start"); }
        catch (System.ComponentModel.Win32Exception e) { throw new PackException($"MakeAppx {what} didn't start: {e.Message}"); }
        var pid = p.Id;
        p.BeginOutputReadLine();
        p.BeginErrorReadLine();

        var exited = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        p.EnableRaisingEvents = true;
        p.Exited += (_, _) => exited.TrySetResult();
        if (p.HasExited) exited.TrySetResult();

        bool finished;
        try { finished = Task.WhenAll(exited.Task, outDone.Task, errDone.Task).Wait(limit); }
        catch (AggregateException) { finished = true; }

        if (!finished)
        {
            var hadExited = p.HasExited;
            if (!hadExited) { try { p.Kill(entireProcessTree: true); } catch (InvalidOperationException) { } catch (System.ComponentModel.Win32Exception) { } }
            var reaped = Reap(p);
            try { p.CancelOutputRead(); } catch (InvalidOperationException) { }
            try { p.CancelErrorRead(); } catch (InvalidOperationException) { }
            var why = hadExited
                ? $"exited but kept its output open past {Seconds(limit)}"
                : $"ran past {Seconds(limit)}; stopped its process {pid}" + (reaped ? "" : $" (still not gone after {Seconds(ReapGrace)})");
            throw new PackException($"MakeAppx {what} timed out: it {why}. Last output:\n{Tail()}");
        }
        if (p.ExitCode != 0) throw new PackException($"MakeAppx {what} failed (exit {p.ExitCode}):\n{Tail()}");
    }

    private static bool Reap(Process p)
    {
        var until = DateTime.UtcNow + ReapGrace;
        while (true)
        {
            try { if (p.HasExited) return true; } catch (InvalidOperationException) { return true; }
            if (DateTime.UtcNow >= until) return false;
            Thread.Sleep(20);
        }
    }

    private static string Seconds(TimeSpan t) => $"{t.TotalSeconds:0.###} s";
}

public sealed record PackResult(string Package, string Unpacked, string Version, string Arch, int Files);

/// [WIN-PACK-OUTPUTS] Where pack and plan write. The work folder is the tool's own: it is used only if it doesn't exist
/// yet or carries the tool's owner file; a package already at --out is replaced only if that owner file recorded its
/// SHA-256 as the last package this tool verified. Everything new is built in a fresh staging folder beside the outputs
/// and moved into place only after the check passed, so any failure leaves the previous package and work folder as
/// they were. Nothing deletes a folder the caller named.
public static class Outputs
{
    public const string OwnerFile = ".hermes-msix-pack";
    private const string OwnerHeader = "hermes-msix-pack work v1";
    public const string StagingPrefix = ".hq-msix-staging-";
    private const string Previous = "previous-work";

    private static readonly StringComparison PathCmp = OperatingSystem.IsLinux() ? StringComparison.Ordinal : StringComparison.OrdinalIgnoreCase;

    private static string Full(string path) => Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));

    /// a is b or inside b (case-insensitive on purpose: a refusal errs on the side of overlap).
    private static bool Within(string a, string b) =>
        a.Equals(b, StringComparison.OrdinalIgnoreCase) || a.StartsWith(b + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);

    private static bool IsLink(FileSystemInfo f) => f.Exists && (f.LinkTarget != null || f.Attributes.HasFlag(FileAttributes.ReparsePoint));

    public record Owner(string Package, string Sha256);

    /// The owner record of a work folder, or null when it isn't one this tool made.
    public static Owner? ReadOwner(string work)
    {
        var f = new FileInfo(Path.Combine(work, OwnerFile));
        if (!f.Exists || IsLink(f) || f.Length > 4096) return null;
        var lines = File.ReadAllLines(f.FullName);
        if (lines.Length != 3 || lines[0] != OwnerHeader || !lines[1].StartsWith("package=") || !lines[2].StartsWith("sha256=")) return null;
        return new Owner(lines[1]["package=".Length..], lines[2]["sha256=".Length..]);
    }

    private static void WriteOwner(string work, string package, string sha) =>
        File.WriteAllText(Path.Combine(work, OwnerFile), $"{OwnerHeader}\npackage={package}\nsha256={sha}\n", new UTF8Encoding(false));

    /// Fails closed, before anything is written, on a work folder or package that overlaps the inputs, is a link, or
    /// already exists without being this tool's own.
    public static (string? Package, string Work) Check(string publishDir, string csproj, string? package, string workDir)
    {
        var publish = Full(publishDir);
        var project = Full(csproj);
        var work = Full(workDir);
        var pkg = package == null ? null : Full(package);
        var named = pkg == null ? new[] { ("work folder", work) } : new[] { ("package", pkg), ("work folder", work) };
        foreach (var (what, path) in named)
        {
            if (Within(path, publish)) throw new PackException($"the {what} {path} is inside the publish folder; put it outside");
            if (Within(publish, path)) throw new PackException($"the {what} {path} holds the publish folder {publish}; choose a folder of its own");
            if (Within(project, path)) throw new PackException($"the {what} {path} holds the project {project}; choose a folder of its own");
            if (Path.GetDirectoryName(path) is not { Length: > 0 } || Path.GetPathRoot(path) == path) throw new PackException($"the {what} {path} can't be a filesystem root");
        }
        if (pkg != null)
        {
            if (!pkg.EndsWith(".msix", StringComparison.OrdinalIgnoreCase)) throw new PackException($"the package {pkg} must end in .msix");
            if (Within(pkg, work) || Within(work, pkg)) throw new PackException($"the package {pkg} and the work folder {work} overlap");
            if (!string.Equals(Path.GetDirectoryName(pkg), Path.GetDirectoryName(work), PathCmp))
                throw new PackException($"the package {pkg} and the work folder {work} must sit in the same folder (so both are replaced in place, on one volume)");
        }

        var wd = new DirectoryInfo(work);
        if (File.Exists(work)) throw new PackException($"the work folder {work} is a file; it was left alone");
        if (IsLink(wd)) throw new PackException($"the work folder {work} is a link; it was left alone");
        Owner? owner = null;
        if (wd.Exists && (owner = ReadOwner(work)) == null)
            throw new PackException($"the work folder {work} already exists and isn't one this tool made (no {OwnerFile}); it was left alone. Move it away or choose another --work");

        if (pkg != null)
        {
            var pf = new FileInfo(pkg);
            if (Directory.Exists(pkg)) throw new PackException($"the package {pkg} is a folder; it was left alone");
            if (IsLink(pf)) throw new PackException($"the package {pkg} is a link; it was left alone");
            if (pf.Exists && (owner == null || owner.Package != pf.Name || !owner.Sha256.Equals(Inputs.Sha256(pkg), StringComparison.OrdinalIgnoreCase)))
                throw new PackException($"the package {pkg} already exists and isn't the one this tool last verified in {work}; it was left alone. Move it away or choose another --out");
        }
        return (pkg, work);
    }

    /// A fresh staging folder of this run's own in `parent`.
    public static string Stage(string parent)
    {
        Directory.CreateDirectory(parent);
        var stage = Path.Combine(parent, StagingPrefix + Guid.NewGuid().ToString("N"));
        if (Path.Exists(stage)) throw new PackException($"staging folder {stage} already exists");
        Directory.CreateDirectory(stage);
        return stage;
    }

    /// Moves the checked work folder (and package) from staging into place. The previous work folder goes into staging
    /// first and comes back if a move fails.
    public static void Commit(string stage, string stagedWork, string work, string? stagedPackage, string? package, string? sha)
    {
        WriteOwner(stagedWork, package == null ? "" : Path.GetFileName(package), sha ?? "");
        var previous = Path.Combine(stage, Previous);
        if (Directory.Exists(work))
        {
            if (ReadOwner(work) == null) throw new PackException($"the work folder {work} changed during the run and isn't this tool's; it was left alone");
            Directory.Move(work, previous);
        }
        try
        {
            Directory.Move(stagedWork, work);
            try { if (package != null) File.Move(stagedPackage!, package, overwrite: true); }
            catch { Directory.Move(work, stagedWork); throw; }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            if (Directory.Exists(previous) && !Path.Exists(work)) Directory.Move(previous, work);
            throw new PackException($"couldn't move the checked output into place: {e.Message}; the previous output was kept");
        }
        // The previous work folder is the tool's own (owner file checked above) and now sits inside this run's staging.
        try { if (Directory.Exists(previous)) Directory.Delete(previous, true); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    /// Removes this run's staging folder, unless it still holds the previous work folder (a failed restore), which is
    /// then left for the caller.
    public static void Discard(string stage)
    {
        if (Directory.Exists(Path.Combine(stage, Previous))) return;
        try { Directory.Delete(stage, true); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
}

public static class Packer
{
    /// Plan, pack, unpack and compare with the plan, all in staging; only then replace the package and work folder.
    /// Throws at the first failure, leaving the previous package and work folder untouched.
    public static PackResult Run(string publishDir, string csproj, string arch, string package, string workDir, IMakeAppx tool)
    {
        var plan = MsixPlan.Create(publishDir, csproj, arch);
        var (pkg, work) = Outputs.Check(plan.PublishDir, csproj, package, workDir);
        var stage = Outputs.Stage(Path.GetDirectoryName(work)!);
        try
        {
            var stagedWork = Path.Combine(stage, "work");
            var stagedPkg = Path.Combine(stage, "package", Path.GetFileName(pkg!));
            Directory.CreateDirectory(Path.GetDirectoryName(stagedPkg)!);
            var mapping = plan.WriteInputs(stagedWork);

            tool.Pack(mapping, stagedPkg);
            if (!File.Exists(stagedPkg) || new FileInfo(stagedPkg).Length == 0) throw new PackException($"MakeAppx pack made no package at {stagedPkg}");

            tool.Unpack(stagedPkg, Path.Combine(stagedWork, "unpacked"));
            Verify(plan, Path.Combine(stagedWork, "unpacked"));
            plan.WriteInputs(stagedWork, work);
            Outputs.Commit(stage, stagedWork, work, stagedPkg, pkg, Inputs.Sha256(stagedPkg));
        }
        finally { Outputs.Discard(stage); }
        return new PackResult(pkg!, Path.Combine(work, "unpacked"), plan.Version, plan.Arch, plan.Files.Count);
    }

    /// Checks the inputs and writes AppxManifest.xml + mapping.txt to the work folder (through staging). Returns the
    /// mapping file.
    public static (MsixPlan Plan, string Mapping) Plan(string publishDir, string csproj, string arch, string workDir)
    {
        var plan = MsixPlan.Create(publishDir, csproj, arch);
        var (_, work) = Outputs.Check(plan.PublishDir, csproj, null, workDir);
        var stage = Outputs.Stage(Path.GetDirectoryName(work)!);
        try
        {
            var stagedWork = Path.Combine(stage, "work");
            plan.WriteInputs(stagedWork, work);
            Outputs.Commit(stage, stagedWork, work, null, null, null);
        }
        finally { Outputs.Discard(stage); }
        return (plan, Path.Combine(work, "mapping.txt"));
    }

    /// The unpacked package holds exactly the plan's files, byte for byte, the plan's manifest, MakeAppx's block map
    /// and content types, and no signature.
    public static void Verify(MsixPlan plan, string unpacked)
    {
        if (!Directory.Exists(unpacked)) throw new PackException($"MakeAppx unpack made no folder at {unpacked}");
        if (File.Exists(Path.Combine(unpacked, "AppxSignature.p7x"))) throw new PackException("the package has AppxSignature.p7x; this path makes unsigned packages only");
        foreach (var f in new[] { "AppxBlockMap.xml", "[Content_Types].xml" })
            if (!File.Exists(Path.Combine(unpacked, f))) throw new PackException($"the unpacked package has no {f}");
        var manifestPath = Path.Combine(unpacked, "AppxManifest.xml");
        if (!File.Exists(manifestPath)) throw new PackException("the unpacked package has no AppxManifest.xml");
        var manifest = XDocument.Load(manifestPath);
        var targets = new HashSet<string>(plan.Files.Select(f => f.Target), StringComparer.OrdinalIgnoreCase);
        var problems = Manifest.Problems(manifest, plan.Version, plan.Arch, targets.Contains);
        if (problems.Count > 0) throw new PackException("the unpacked AppxManifest.xml: " + string.Join("; ", problems));
        if (!XNode.DeepEquals(manifest.Root, XDocument.Parse(plan.ManifestXml).Root)) throw new PackException("the unpacked AppxManifest.xml differs from the planned one");

        foreach (var (source, target) in plan.Files)
        {
            var got = Path.Combine(unpacked, target.Replace('\\', Path.DirectorySeparatorChar));
            if (!File.Exists(got)) throw new PackException($"{target} is missing from the unpacked package");
            if (new FileInfo(got).Length != new FileInfo(source).Length || Inputs.Sha256(got) != Inputs.Sha256(source))
                throw new PackException($"{target} in the unpacked package differs from the publish folder");
        }
        var known = new HashSet<string>(targets, StringComparer.OrdinalIgnoreCase) { "AppxManifest.xml", "AppxBlockMap.xml", "[Content_Types].xml" };
        var extra = Directory.EnumerateFiles(unpacked, "*", SearchOption.AllDirectories)
            .Select(f => Path.GetRelativePath(unpacked, f).Replace(Path.DirectorySeparatorChar, '\\'))
            .Where(t => !known.Contains(t)).OrderBy(t => t, StringComparer.Ordinal).ToList();
        if (extra.Count > 0) throw new PackException($"the unpacked package has files not in the plan: {string.Join(", ", extra)}");
        var machine = Inputs.PeMachine(Path.Combine(unpacked, Identity.Executable));
        if (machine != Identity.Machines[plan.Arch]) throw new PackException($"the unpacked {Identity.Executable} is {Inputs.MachineName(machine)}, not {plan.Arch}");
    }
}
