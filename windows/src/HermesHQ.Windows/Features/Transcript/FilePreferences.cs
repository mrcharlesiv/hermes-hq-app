using System.Text.Json;
using Hermes.Core.Transcripts;
using HermesHQ.Services;

namespace HermesHQ.Features.Transcript;

/// The device's display preferences (the Mac's UserDefaults): one JSON file under LocalAppData\HermesHQ. An
/// unpackaged app has no ApplicationData, so this stands in for it. Values are strings; a null removes the key.
public sealed class FilePreferences : IPreferences
{
    private readonly string _path;
    private readonly object _lock = new();
    private Dictionary<string, string> _values;

    public FilePreferences(string path)
    {
        _path = path;
        try { _values = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(path)) ?? []; }
        catch (Exception x) when (x is IOException or JsonException or UnauthorizedAccessException) { _values = []; }
    }

    public static FilePreferences Shared { get; } = new(Path.Combine(AppPaths.Root, "preferences.json"));

    public string? Get(string key)
    {
        lock (_lock) return _values.GetValueOrDefault(key);
    }

    public void Set(string key, string? value)
    {
        string json;
        lock (_lock)
        {
            if (value == null) _values.Remove(key); else _values[key] = value;
            json = JsonSerializer.Serialize(_values);
        }
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            File.WriteAllText(_path, json);
        }
        catch (Exception x) when (x is IOException or UnauthorizedAccessException) { AppLog.Note("prefs", "couldn't save"); }
    }
}
