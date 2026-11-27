namespace Hermes.Core.Transcripts;

/// The device and host words the transcript's sentences use (Shared/DeviceWord.swift `DeviceWord` and `HostWord`),
/// with the Mac's values: a Windows PC is driven by a mouse as the Mac is. Kept here, under a transcript-only name, so
/// a later shared port of DeviceWord/HostWord can replace it without a clash.
public static class TranscriptWords
{
    /// HostWord.phrase: the computer the bots run on, mid-sentence. Never "gateway", never bare "Hermes".
    public const string HostPhrase = "the computer running Hermes";
    /// HostWord.sentence: the same at the start of a sentence.
    public const string HostSentence = "The computer running Hermes";
    /// DeviceWord.Tap on the Mac: what you do to a control at the start of an instruction ("Click Try Again").
    public const string Tap = "Click";
    /// DeviceWord.tap on the Mac, mid-sentence.
    public const string TapLower = "click";
}
