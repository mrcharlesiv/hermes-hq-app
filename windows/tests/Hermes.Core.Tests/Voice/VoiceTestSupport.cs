// [WIN-VOICE-FILES-UPLOAD] Tests/Voice/VoiceTestSupport.swift at 93f984bb1: a recording fake gateway for the memo
// pipeline (every REST read, transfer and attach lands in one ordered log with its body), and memo stores in a temp
// folder. Synthetic data only: a made-up account, the /Users/owner root, a generated sine WAV.

using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;
using Hermes.Core.Net;
using Hermes.Core.Voice;

namespace Hermes.Core.Tests.Voice;

internal sealed class VoiceFakeClient : IMemoTransfers
{
    public sealed record Entry(string Kind, IReadOnlyList<KeyValuePair<string, string>> Query, byte[]? Body = null,
        string? ContentType = null, JsonObject? Params = null)
    {
        public JsonNode? BodyJson => Body == null ? null : JsonNode.Parse(Encoding.UTF8.GetString(Body));
    }

    public delegate byte[] Rest(string method, string path, byte[]? body);
    public delegate JsonNode Call(string method, JsonObject parameters, int attempt);

    public const string Root = "/Users/owner";
    public const string Rid = "5cc537d1";

    private readonly object _gate = new();
    private readonly List<Entry> _log = [];
    private readonly Dictionary<string, int> _attempts = [];
    private readonly Dictionary<string, TimeSpan> _delays = [];
    private Rest _rest = DefaultRest;
    private Call _call = DefaultCall;

    public string AccountId { get; }

    public VoiceFakeClient(string? accountId = null) => AccountId = accountId ?? $"voice-fake-{Guid.NewGuid()}";

    /// The happy path: files root, an upload that answers its own path, STT on, a transcript.
    public static byte[] DefaultRest(string method, string path, byte[]? body)
    {
        static byte[] B(string s) => Encoding.UTF8.GetBytes(s);
        switch (method, path)
        {
            case ("GET", "/api/files"): return B("""{"path":"/Users/owner","parent":null,"entries":[]}""");
            case ("GET", "/api/config"): return B("""{"stt":{"enabled":true}}""");
            case ("POST", "/api/files/upload-stream"):
                var text = Encoding.UTF8.GetString(body ?? []);
                var after = text.Split("name=\"path\"\r\n\r\n").Skip(1).FirstOrDefault() ?? "";
                var stored = after.Split("\r\n")[0];
                return B(new JsonObject { ["ok"] = true, ["path"] = stored }.ToJsonString());
            case ("DELETE", "/api/files"): return B("""{"ok":true}""");
            case ("POST", "/api/audio/transcribe"): return B("""{"ok":true,"transcript":"Pick up milk on the way home.","provider":"fake"}""");
            default: return B("""{"messages":[],"pagination":{"returned":0,"has_more":false}}""");
        }
    }

    public static JsonNode DefaultCall(string method, JsonObject parameters, int attempt)
    {
        switch (method)
        {
            case "file.attach":
                var name = parameters.Str("name") ?? "voice-memo.m4a";
                var stored = $"{Root}/.hermes/profiles/ivy/attachments/{name}";
                return new JsonObject
                {
                    ["attached"] = true, ["name"] = name, ["path"] = stored, ["ref_path"] = stored,
                    ["ref_text"] = $"@file:{stored}", ["uploaded"] = true,
                };
            default: return new JsonObject();
        }
    }

    public void OnRest(Rest rest) { lock (_gate) _rest = rest; }
    public void OnCall(Call call) { lock (_gate) _call = call; }
    public void Delay(string kind, TimeSpan duration) { lock (_gate) _delays[kind] = duration; }

    public IReadOnlyList<Entry> Log { get { lock (_gate) return _log.ToArray(); } }
    public IReadOnlyList<string> Kinds => Log.Select(e => e.Kind).ToArray();
    public IReadOnlyList<Entry> Entries(string kind) => Log.Where(e => e.Kind == kind).ToArray();

    private async Task Wait(string kind, CancellationToken ct)
    {
        TimeSpan? duration;
        lock (_gate) duration = _delays.TryGetValue(kind, out var d) ? d : null;
        if (duration is { } wait) await Task.Delay(wait, ct);
    }

    public async Task<byte[]> RestAsync(string method, string path, IReadOnlyList<KeyValuePair<string, string>> query, byte[]? body,
        CancellationToken ct)
    {
        Rest responder;
        lock (_gate)
        {
            _log.Add(new Entry($"{method} {path}", query.ToArray(), body));
            responder = _rest;
        }
        await Wait($"{method} {path}", ct);
        return responder(method, path, body);
    }

    // The protocol's default configData: a GET of /api/config.
    public Task<byte[]> ConfigDataAsync(IReadOnlyList<KeyValuePair<string, string>> query, TimeSpan maxAge, CancellationToken ct) =>
        RestAsync("GET", "/api/config", query, null, ct);

    public async Task<byte[]> TransferAsync(string method, string path, IReadOnlyList<KeyValuePair<string, string>> query, byte[]? body,
        string contentType, double timeoutSeconds, CancellationToken ct)
    {
        Rest responder;
        lock (_gate)
        {
            _log.Add(new Entry($"{method} {path}", query.ToArray(), body, contentType));
            responder = _rest;
        }
        await Wait($"{method} {path}", ct);
        return responder(method, path, body);
    }

    /// An RPC as the chat's client sends it (the uploader's `attach` closure calls this).
    public async Task<JsonNode> CallAsync(string method, JsonObject parameters, CancellationToken ct)
    {
        Call responder;
        int attempt;
        lock (_gate)
        {
            _log.Add(new Entry($"rpc {method}", [], Params: (JsonObject)parameters.DeepClone()));
            _attempts[method] = _attempts.GetValueOrDefault(method) + 1;
            attempt = _attempts[method];
            responder = _call;
        }
        await Wait($"rpc {method}", ct);
        return responder(method, parameters, attempt);
    }

    /// The chat's `file.attach` closure: the runtime session id added, as LiveChatSession does.
    public Func<JsonObject, CancellationToken, Task<JsonNode?>> Attach => async (parameters, ct) =>
    {
        var withSession = new JsonObject { ["session_id"] = Rid };
        foreach (var (key, value) in parameters) withSession[key] = value?.DeepClone();
        return await CallAsync("file.attach", withSession, ct);
    };
}

/// Memo stores in a temp folder, for one test class.
internal sealed class VoiceTestStores : IDisposable
{
    public string Base { get; } = Path.Combine(Path.GetTempPath(), $"hq-voice-tests-{Guid.NewGuid()}");
    public MemoPaths Paths { get; }
    public RecordingGuard Guard { get; } = new();
    public MemoAccountStores Stores { get; }

    public VoiceTestStores()
    {
        Paths = new MemoPaths(Path.Combine(Base, "support"), Path.Combine(Base, "caches"), Guard);
        Stores = new MemoAccountStores(Paths);
    }

    /// Activates the stores for `accountId` under the test folder.
    public void Activate(string accountId) => Stores.Activate(accountId);

    /// A recording file under memos/<key>/ (a short WAV).
    public MemoFile Recording(string accountId, double seconds = 2)
    {
        var path = Paths.NewRecording(MemoPaths.AccountKey(accountId), "wav");
        Paths.Ensure(Path.GetDirectoryName(path)!);
        File.WriteAllBytes(path, VoiceFixtures.FixtureWave(seconds, [0.3, 0.6, 0.9]));
        return new MemoFile(path, seconds, VoiceFixtures.Peaks([0.3, 0.6, 0.9]), "audio/wav");
    }

    public void Dispose()
    {
        MemoDisk.Flush();
        try { Directory.Delete(Base, recursive: true); } catch (IOException) { }
    }

    /// Records every folder the stores protected (the Mac's isExcludedFromBackup flag, read back).
    public sealed class RecordingGuard : IMemoFolderGuard
    {
        private readonly HashSet<string> _folders = [];
        public void Protect(string folder) { lock (_folders) _folders.Add(Path.GetFullPath(folder)); }
        public bool Protected(string folder) { lock (_folders) return _folders.Contains(Path.GetFullPath(folder)); }
    }
}

internal static class VoiceFixtures
{
    /// MemoRecorder.fixtureWave: a 16 kHz mono WAV whose loudness follows the take's levels.
    public static byte[] FixtureWave(double seconds, double[] levels)
    {
        const int rate = 16000;
        var count = Math.Max(1, (int)(seconds * rate));
        using var pcm = new MemoryStream(count * 2);
        for (var index = 0; index < count; index++)
        {
            var t = (double)index / rate;
            var level = levels.Length == 0 ? 0.3 : levels[Math.Min(levels.Length - 1, (int)(t * 10))];
            var value = (short)Math.Max(-32767, Math.Min(32767, level * 9000 * Math.Sin(2 * Math.PI * 220 * t) * (0.6 + 0.4 * Math.Sin(2 * Math.PI * 3 * t))));
            pcm.Write(BitConverter.GetBytes(value));
        }
        return Wave(rate, pcm.ToArray());
    }

    public static byte[] Wave(int rate, byte[] pcm, int dataBytes = -1)
    {
        using var header = new MemoryStream();
        void U32(long v) => header.Write(BitConverter.GetBytes((uint)v));
        void U16(int v) => header.Write(BitConverter.GetBytes((ushort)v));
        var size = dataBytes < 0 ? pcm.Length : dataBytes;
        header.Write("RIFF"u8); U32(36 + size); header.Write("WAVEfmt "u8);
        U32(16); U16(1); U16(1); U32(rate); U32(rate * 2); U16(2); U16(16);
        header.Write("data"u8); U32(size);
        header.Write(pcm);
        return header.ToArray();
    }

    /// MemoPolicy.peaks (the recorder's, not ported to Core): `count` bars, each the loudest sample in its slice.
    public static double[] Peaks(double[] samples, int count = 48)
    {
        if (samples.Length == 0 || count <= 0) return new double[Math.Max(0, count)];
        return Enumerable.Range(0, count).Select(bar =>
        {
            var start = bar * samples.Length / count;
            var end = Math.Max(start + 1, (bar + 1) * samples.Length / count);
            var slice = samples[Math.Min(start, samples.Length - 1)..Math.Min(end, samples.Length)];
            return Math.Round(slice.Max() * 1000, MidpointRounding.AwayFromZero) / 1000;
        }).ToArray();
    }

    /// Polls until `condition` holds or 10 s pass.
    public static async Task<bool> WaitUntil(Func<bool> condition, double seconds = 10)
    {
        var clock = Stopwatch.StartNew();
        while (clock.Elapsed.TotalSeconds < seconds)
        {
            if (condition()) return true;
            await Task.Delay(10);
        }
        return condition();
    }
}
