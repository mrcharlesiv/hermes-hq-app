using Hermes.Core.Voice;
using HermesHQ.Services;

namespace HermesHQ.Features.Voice;

/// Port of App/Audio/VoiceConnectedChime.swift: synthesizes a soft two-note ascending chime
/// (C5 -> E5 with gentle sine harmonics and exponential decay) and plays it through WinMM waveOut
/// so connecting a voice conversation gives subtle, immediate audio confirmation without interrupting capture.
public static class VoiceConnectedChime
{
    public const int SampleRate = 24000;
    private static readonly Lazy<byte[]> ChimePcm = new(SynthesizePcm);

    /// Synthesizes the two-note connected chime as 24 kHz 16-bit mono PCM bytes.
    public static byte[] SynthesizePcm()
    {
        const double note1Freq = 523.25; // C5
        const double note2Freq = 659.25; // E5
        const double totalSeconds = 0.28;
        const double secondStart = 0.095;
        const double amplitude = 0.18;

        var totalSamples = (int)(SampleRate * totalSeconds);
        var samples = new short[totalSamples];

        for (var i = 0; i < totalSamples; i++)
        {
            var t = i / (double)SampleRate;
            double v = 0;

            // First note: smooth attack + exponential decay
            if (t < 0.18)
            {
                var attack = Math.Min(1.0, t / 0.008);
                var decay = Math.Exp(-t * 18.0);
                var tone = Math.Sin(2 * Math.PI * note1Freq * t)
                    + 0.22 * Math.Sin(2 * Math.PI * note1Freq * 2.0 * t);
                v += tone * attack * decay;
            }

            // Second note: warm fifth/major third lift
            if (t >= secondStart)
            {
                var dt = t - secondStart;
                var attack = Math.Min(1.0, dt / 0.008);
                var decay = Math.Exp(-dt * 14.0);
                var tone = Math.Sin(2 * Math.PI * note2Freq * dt)
                    + 0.20 * Math.Sin(2 * Math.PI * note2Freq * 2.0 * dt);
                v += tone * attack * decay;
            }

            var clamped = Math.Clamp(v * amplitude, -0.95, 0.95);
            samples[i] = (short)Math.Round(clamped * 32767.0);
        }

        var bytes = new byte[samples.Length * sizeof(short)];
        Buffer.BlockCopy(samples, 0, bytes, 0, bytes.Length);
        return bytes;
    }

    /// Plays the chime asynchronously off the UI thread. Never throws.
    public static void Play()
    {
        _ = Task.Run(() =>
        {
            try
            {
                using var player = new WinMmWaveOutPlayer(SampleRate, 1);
                player.Write(ChimePcm.Value);
                Thread.Sleep(320);
            }
            catch (Exception ex)
            {
                AppLog.Note("voice", $"chime skipped: {ex.GetType().Name}");
            }
        });
    }
}
