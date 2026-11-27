using Hermes.Core.Settings;
using HermesHQ.Services;
using Windows.Media.Core;
using Windows.Media.Playback;
using Windows.Storage.Streams;

namespace HermesHQ.Features.Settings;

/// The completion cue (CompletionCue.swift). Playback, source replacement and quit run on the UI thread;
/// only the pure WAV renderer runs off it. No native stream or player is held by a pending render.
internal static class CompletionCue
{
    private static MediaPlayer? _player;
    private static CueSource? _playing;
    private static int _variant = -1;
    private static byte[]? _wav;

    public static void Preview(int id) => Play(id);

    /// The player releases its source before the source and its backing stream close.
    internal static void StopForQuit()
    {
        var player = _player;
        var playing = _playing;
        _player = null;
        _playing = null;
        _wav = null;
        try { player?.Dispose(); }
        finally { playing?.Dispose(); }
    }

    public static void Play(int id) => _ = PlayAsync(id);

    internal static async Task PlayAsync(int id)
    {
        if (AppShutdown.Stopping) return;
        try
        {
            if (_wav == null || _variant != id)
            {
                var wav = await Task.Run(() => CompletionSoundSynth.Wav(id));
                if (AppShutdown.Stopping) return;
                _wav = wav;
                _variant = id;
            }
            _player ??= new MediaPlayer { AudioCategory = MediaPlayerAudioCategory.SoundEffects };
            var next = new CueSource(_wav);
            try { _player.Source = next.Source; }
            catch { next.Dispose(); throw; }
            var previous = _playing;
            _playing = next;
            previous?.Dispose();
            _player.Play();
        }
        catch (Exception x)
        {
            AppLog.Note("sound", $"cue failed: {x.GetType().Name}");
        }
    }

    // The WAV is already in memory. Adapt those bytes instead of starting a second, asynchronous WinRT copy
    // which could still be writing when the app quits. Keep the read-only stream alive as long as playback.
    private sealed class CueSource : IDisposable
    {
        private readonly IRandomAccessStream _stream;
        internal MediaSource Source { get; }

        internal CueSource(byte[] wav)
        {
            _stream = new MemoryStream(wav, writable: false).AsRandomAccessStream();
            try { Source = MediaSource.CreateFromStream(_stream, "audio/wav"); }
            catch { _stream.Dispose(); throw; }
        }

        public void Dispose()
        {
            try { Source.Dispose(); }
            finally { _stream.Dispose(); }
        }
    }
}
