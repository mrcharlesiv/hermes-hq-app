using Hermes.Core.Voice;
using Windows.Media.Core;
using Windows.Media.Playback;
using Windows.Media.SpeechSynthesis;

namespace HermesHQ.Features.Voice;

/// The PC's own voice for Read Aloud (the Mac's device voice, HermesKit/Voice/TalkPhoneVoice.swift): each sentence is
/// rendered on the device by Windows.Media.SpeechSynthesis (installed voices only, nothing leaves the PC) and played by
/// a MediaPlayer in the Speech audio category, one after another. Cancelling pauses the player at once.
internal sealed class WindowsReadAloudVoice : IReadAloudVoice
{
    public async Task SpeakAsync(IReadOnlyList<string> sentences, Action started, CancellationToken cancel)
    {
        if (SpeechSynthesizer.AllVoices.Count == 0) throw new ReadAloudVoiceException("There’s no voice on this PC to read with.");
        using var synthesizer = new SpeechSynthesizer();
        var player = new MediaPlayer { AudioCategory = MediaPlayerAudioCategory.Speech, AutoPlay = false };
        try
        {
            var first = true;
            foreach (var sentence in sentences)
            {
                cancel.ThrowIfCancellationRequested();
                using var stream = await synthesizer.SynthesizeTextToStreamAsync(sentence).AsTask(cancel);
                using var source = MediaSource.CreateFromStream(stream, stream.ContentType);
                var ended = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                void OnEnded(MediaPlayer _, object __) => ended.TrySetResult();
                void OnFailed(MediaPlayer _, MediaPlayerFailedEventArgs e) => ended.TrySetException(new ReadAloudVoiceException(e.ErrorMessage));
                player.MediaEnded += OnEnded;
                player.MediaFailed += OnFailed;
                try
                {
                    player.Source = source;
                    player.Play();
                    if (first) { first = false; started(); }
                    using (cancel.Register(() => ended.TrySetCanceled(cancel))) await ended.Task;
                }
                finally
                {
                    player.MediaEnded -= OnEnded;
                    player.MediaFailed -= OnFailed;
                    player.Pause();
                    player.Source = null;
                }
            }
        }
        finally
        {
            player.Pause();
            player.Source = null;
            player.Dispose();
        }
    }
}
