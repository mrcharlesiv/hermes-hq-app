// Reading aloud always works (docs/spec/3x-talk.md §7.7): when the computer's voice (the gateway's text to speech)
// fails, the reply is spoken by the iPhone's own voice instead of stopping with an error. Also the explicit "iPhone
// Voice" choice in Settings › Voice › Text to Speech, kept on this device only (never written to `tts.provider`).
//
// Here: the choice, the per gateway+profile memory of a failing computer voice (30 minutes, then the gateway is asked
// again), the one quiet notice, the voice picked for a reply's language, and the renderer that turns a sentence into
// PCM with `AVSpeechSynthesizer.write(_:toBufferCallback:)` (public API) so the speech session plays it through the
// same output as the gateway's PCM: inside the conversation's engine (echo cancellation, barge-in) and on the meter.

import AVFAudio
import Foundation
import NaturalLanguage
import Synchronization

// MARK: - The choice (this device only)

nonisolated enum PhoneVoiceChoice: String, Sendable, Equatable, CaseIterable {
    /// The gateway's Text to Speech provider; the iPhone's voice only when it fails.
    case computer
    /// Always the iPhone's own voice.
    case phone = "iphone"

    static let key = "hq.voice.replyVoice"
    static let changed = Notification.Name("hq.voice.replyVoice.changed")

    static func current(_ defaults: UserDefaults = .standard) -> PhoneVoiceChoice {
        defaults.string(forKey: key).flatMap(PhoneVoiceChoice.init(rawValue:)) ?? .computer
    }

    static func set(_ choice: PhoneVoiceChoice, defaults: UserDefaults = .standard) {
        defaults.set(choice.rawValue, forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    var title: String {
        switch self {
        // [mac] Stress test 2026-10-28 #97: on a Mac "Computer’s Voice" reads as the Mac's own; it is Hermes's.
        case .computer: DeviceWord.isMac ? "Hermes Voice" : "Computer’s Voice"
        case .phone: "\(DeviceWord.name) Voice"
        }
    }

    /// The Settings row's footer. Stress test 2026-10-28 #96/#97, round 2 (both): one paragraph (the better-voice hint
    /// joins it), "below" only when the page shows a provider, and the device named ("this Mac", not "this device").
    static func footer(providerBelow: Bool = true, betterVoiceHint: String? = nil) -> String {
        let device = DeviceWord.name
        let source = providerBelow ? "the Text to Speech provider below" : "the voice set on \(HostWord.phrase)"
        let text = "\(PhoneVoiceChoice.computer.title) uses \(source), and the \(device)’s own voice when it isn’t working. \(device) Voice always reads on this \(device). \(DeviceWord.onlyHere)"
        guard let betterVoiceHint, !betterVoiceHint.isEmpty else { return text }
        return text + " " + betterVoiceHint
    }
}

// MARK: - The voice the person picked (this device only)

/// Which of the installed voices the iPhone's voice uses (Settings › Voice › Text to Speech › Voice). None is
/// Automatic: the Spoken Content voice for the person's own language, else the best installed voice for the reply's.
/// Tester, 2026-11-08: "On read aloud, the voice sounds very robotic and not the same as 'Speak' everywhere else".
nonisolated enum PhoneVoicePreference {
    static let key = "hq.voice.phoneVoiceId"
    static let changed = Notification.Name("hq.voice.phoneVoiceId.changed")

    static func current(_ defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: key).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func set(_ identifier: String?, defaults: UserDefaults = .standard) {
        if let identifier, !identifier.isEmpty { defaults.set(identifier, forKey: key) } else { defaults.removeObject(forKey: key) }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static let automatic = "Automatic"
    static let automaticHint = DeviceWord.isMac
        ? "Automatic uses the voice set in System Settings › Accessibility › Spoken Content, or the best voice on this Mac for a reply in another language."
        : "Automatic uses the voice set in Settings › Accessibility › Spoken Content, as Speak does, or the best voice on this \(DeviceWord.name) for a reply in another language."

    /// The Voice row's value: Automatic, or the picked voice's name ("Ava (Premium)"). A voice since removed reads
    /// Automatic, which is what speaks.
    static func label(_ identifier: String?, candidates: [PhoneVoiceCandidate]) -> String {
        guard let identifier, let voice = candidates.first(where: { $0.identifier == identifier }) else { return automatic }
        return voice.title
    }
}

// MARK: - Memory and the notice

/// Which computers' voices failed lately, per gateway and profile, and whether the person was told. Shared across
/// threads (a settings save on any thread forgets it).
nonisolated final class PhoneVoiceFallback: Sendable {
    static let shared = PhoneVoiceFallback()
    /// A failing computer voice is skipped this long, then asked again.
    static let lifetime: TimeInterval = 30 * 60
    /// The speaker took the iPhone's voice for a reply (userInfo: `account`, `profile`).
    static let started = Notification.Name("hq.voice.phoneVoiceStarted")

    private struct State: Sendable {
        var failedAt: [String: Date] = [:]
        var told: Set<String> = []
    }
    private let state = Locked(State())
    let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    static func key(account: String, profile: String?) -> String { "\(account)|\(profile ?? "")" }

    /// The computer's voice failed for this gateway and profile.
    func remember(_ key: String) {
        let at = now()
        state.mutate { $0.failedAt[key] = at }
    }

    /// Whether replies skip the computer's voice for now.
    func isFailing(_ key: String) -> Bool {
        let at = now()
        return state.mutate { state -> Bool in
            guard let failed = state.failedAt[key] else { return false }
            if at.timeIntervalSince(failed) >= Self.lifetime {
                state.failedAt[key] = nil
                return false
            }
            return true
        }
    }

    /// Once per gateway and profile while the app runs: true the first time a chat shows the notice.
    func claimNotice(_ key: String) -> Bool { state.mutate { $0.told.insert(key).inserted } }

    /// The gateway's voice settings were saved (Fix… went somewhere): the next reply asks the computer again.
    func forget() { state.mutate { $0.failedAt.removeAll() } }

    func reset() { state.set(State()) }
}

/// The notice's words and what goes to the log.
nonisolated enum PhoneVoiceWords {
    /// Mac polish #136: one short sentence, the bot named once ("Hermes’s voice isn’t working, so the Mac’s voice is reading.").
    static func notice(botName: String) -> String {
        let name = botName.trimmingCharacters(in: .whitespaces).isEmpty ? "Your bot" : botName
        return "\(name)’s voice isn’t working, so the \(DeviceWord.name)’s voice is reading."
    }
    static let fix = "Fix…"
    /// Under the Voice choice when only default (compact) voices are installed for the person's language.
    /// [mac] Stress test 2026-10-28 #97: the Mac's path is System Settings › Accessibility › Spoken Content › System Voice.
    static let enhancedHint = DeviceWord.isMac
        ? "For a more natural voice, choose or download one in System Settings › Accessibility › Spoken Content › System Voice."
        : "For a more natural voice, download an Enhanced voice in Settings › Accessibility › Spoken Content › Voices."

    /// The computer's failure for the log: no address, query string or token (`VoiceReport.scrub`).
    static func logLine(_ failure: VoiceFailure) -> String {
        var text = failure.reason
        if let detail = failure.detail, !detail.isEmpty, detail != "unplayable" { text += " (\(detail))" }
        return "speech: computer voice failed: \(VoiceReport.scrub(text.replacingOccurrences(of: "\n", with: " ")))"
    }
}

// MARK: - Which voice

nonisolated struct PhoneVoiceCandidate: Equatable, Sendable {
    var identifier: String
    var language: String
    var name: String
    /// 1 default, 2 enhanced, 3 premium.
    var quality: Int
    /// Novelty and Personal Voice are never picked.
    var excluded = false

    /// "Ava (Premium)", "Samantha": the quality the Spoken Content list shows beside a name.
    var title: String {
        switch quality {
        case 3: "\(name) (Premium)"
        case 2: "\(name) (Enhanced)"
        default: name
        }
    }
}

/// One language's voices in Settings › Voice (`PhoneVoicePicker.offered`).
nonisolated struct PhoneVoiceGroup: Equatable, Sendable, Identifiable {
    var language: String
    var voices: [PhoneVoiceCandidate]
    var id: String { language }

    /// A voice's row: its title, with its region when the language has voices from more than one ("Daniel · United
    /// Kingdom" beside "Samantha · United States").
    func title(for voice: PhoneVoiceCandidate, locale: Locale = .current) -> String {
        let regions = Set(voices.map { Self.region(of: $0.language) })
        guard regions.count > 1, let code = Self.region(of: voice.language),
              let region = locale.localizedString(forRegionCode: code) else { return voice.title }
        return voice.title + " · " + region
    }

    private static func region(of language: String) -> String? {
        let parts = language.replacingOccurrences(of: "_", with: "-").split(separator: "-")
        return parts.count > 1 ? String(parts[parts.count - 1]).uppercased() : nil
    }
}

nonisolated enum PhoneVoicePicker {
    /// The language of a reply ("en", "es"…): the recogniser's answer for text long enough to judge, else the
    /// person's own first language.
    static func language(of text: String, preferred: [String] = Locale.preferredLanguages) -> String {
        let fallback = base(preferred.first ?? "en")
        let sample = String(text.prefix(600))
        guard sample.count >= 16 else { return fallback }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, confidence >= 0.5 else { return fallback }
        return base(language.rawValue)
    }

    static func base(_ language: String) -> String {
        String(language.lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-").first ?? "en")
    }

    /// The best installed voice for `language`: the best quality first (premium, then enhanced, then default), then a
    /// region the person uses, then the language's own default region. nil when no voice speaks it.
    /// `chosen` (Settings › Voice) wins when it is installed and speaks the reply's language.
    static func pick(language: String, candidates: [PhoneVoiceCandidate], preferred: [String] = Locale.preferredLanguages,
                     defaultRegion: String? = nil, chosen: String? = nil) -> PhoneVoiceCandidate? {
        let wanted = base(language)
        if let chosen, let voice = candidates.first(where: { $0.identifier == chosen }), !voice.excluded, base(voice.language) == wanted {
            return voice
        }
        let regions = preferred.map { $0.lowercased().replacingOccurrences(of: "_", with: "-") }.filter { base($0) == wanted }
        func score(_ voice: PhoneVoiceCandidate) -> Int {
            let lang = voice.language.lowercased().replacingOccurrences(of: "_", with: "-")
            var score = voice.quality * 100
            if let index = regions.firstIndex(of: lang) { score += 50 - min(index, 20) }
            else if let defaultRegion, lang == defaultRegion.lowercased().replacingOccurrences(of: "_", with: "-") { score += 25 }
            return score
        }
        return candidates
            .filter { !$0.excluded && base($0.language) == wanted }
            .sorted { (score($0), $1.name) > (score($1), $0.name) }
            .first
    }

    /// Automatic follows the Spoken Content voice (`prefersAssistiveTechnologySettings`) only for a reply in the person's
    /// own first language: that voice speaks one language, and a reply in another is read by a voice that speaks it.
    static func followsSpokenContent(language: String, chosen: PhoneVoiceCandidate?, preferred: [String] = Locale.preferredLanguages) -> Bool {
        chosen == nil && base(language) == base(preferred.first ?? "en")
    }

    /// The voices Settings offers: those speaking one of the person's languages, theirs first, then by quality and name.
    /// Novelty voices and Personal Voice are left out.
    static func offered(_ candidates: [PhoneVoiceCandidate], preferred: [String] = Locale.preferredLanguages) -> [PhoneVoiceGroup] {
        var languages: [String] = []
        for language in preferred.map(base) where !languages.contains(language) { languages.append(language) }
        if languages.isEmpty { languages = ["en"] }
        return languages.compactMap { language in
            let voices = candidates
                .filter { !$0.excluded && base($0.language) == language }
                .sorted { ($0.quality, $1.name, $1.language) > ($1.quality, $0.name, $0.language) }
            return voices.isEmpty ? nil : PhoneVoiceGroup(language: language, voices: voices)
        }
    }

    /// Only default-quality voices (or none) speak the person's language: Settings suggests an Enhanced one.
    static func suggestsBetterVoice(candidates: [PhoneVoiceCandidate], preferred: [String] = Locale.preferredLanguages) -> Bool {
        let language = base(preferred.first ?? "en")
        return (pick(language: language, candidates: candidates, preferred: preferred)?.quality ?? 1) < 2
    }

    static func describe(_ voice: PhoneVoiceCandidate?) -> String {
        guard let voice else { return "the system default" }
        let quality = voice.quality >= 3 ? "premium" : voice.quality == 2 ? "enhanced" : "default"
        return "\(voice.language), \(quality)"
    }
}

// MARK: - The renderer

/// A piece of spoken audio: little-endian int16 PCM, interleaved.
nonisolated struct PhonePCM: Sendable, Equatable {
    var data: Data
    var sampleRate: Double
    var channels: Int
}

@MainActor protocol PhoneSpeechRendering: AnyObject {
    /// Picks the voice for a reply from (a sample of) its text; says which, for the log.
    func chooseVoice(for text: String) -> String
    /// One sentence's audio, in pieces. Ends when the sentence is done; throws when nothing can be made.
    func render(_ sentence: String) -> AsyncThrowingStream<PhonePCM, any Error>
    func cancel()
}

/// The installed voices, read once and kept. Mac polish #34: the first `speechVoices()` after launch held the main
/// thread for about 0.76 s, so opening Speech to Text or Text to Speech froze the app; the pages read them off the
/// main thread (`load`). A voice downloaded or removed has them read again.
nonisolated enum PhoneVoiceList {
    private static let kept = Mutex<[PhoneVoiceCandidate]?>(nil)
    /// Forgets the list when the system's voices change (set up by the first read).
    private static let watching: Void = {
        _ = NotificationCenter.default.addObserver(forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification,
                                                   object: nil, queue: nil) { _ in kept.withLock { $0 = nil } }
    }()

    /// The voices, read here if they have not been yet.
    static func now() -> [PhoneVoiceCandidate] {
        if let list = kept.withLock({ $0 }) { return list }
        let list = read()
        kept.withLock { $0 = list }
        return list
    }

    /// The voices, read on a background thread if they have not been yet.
    @concurrent static func load() async -> [PhoneVoiceCandidate] { now() }

    /// The voices if they have been read, without reading them here (a reply read aloud, on the main thread).
    static func ifRead() -> [PhoneVoiceCandidate]? { kept.withLock { $0 } }

    private static func read() -> [PhoneVoiceCandidate] {
        _ = watching
        return AVSpeechSynthesisVoice.speechVoices().map { voice in
            let quality: Int = switch voice.quality {
            case .premium: 3
            case .enhanced: 2
            default: 1
            }
            let excluded = voice.voiceTraits.contains(.isNoveltyVoice) || voice.voiceTraits.contains(.isPersonalVoice)
            return PhoneVoiceCandidate(identifier: voice.identifier, language: voice.language, name: voice.name, quality: quality, excluded: excluded)
        }
    }
}

/// `AVSpeechSynthesizer` writing into buffers (no sound of its own): the session schedules the PCM.
@MainActor final class SystemPhoneSpeechRenderer: PhoneSpeechRendering {
    /// No first buffer this long: the iPhone's voice is not available.
    static let firstBufferTimeout: TimeInterval = 6
    private let synthesizer = AVSpeechSynthesizer()
    private var voice: AVSpeechSynthesisVoice?
    /// Automatic, for the person's own language: the Spoken Content voice, rate and pitch ("Speak"'s) win over `voice`.
    private var followsSpokenContent = false

    init() {
        // Writing never plays: the app's own session (the conversation's, or the speech owner's) stays as it is.
        synthesizer.usesApplicationAudioSession = true
        // The voices are read off the main thread while the first sentence is on its way (Mac polish #34).
        Task { _ = await PhoneVoiceList.load() }
    }

    static func candidates() -> [PhoneVoiceCandidate] { PhoneVoiceList.now() }

    func chooseVoice(for text: String) -> String {
        let language = PhoneVoicePicker.language(of: text)
        let fallbackRegion = AVSpeechSynthesisVoice(language: language)?.language
        // Mac polish #34: the first reply right after the voice took over asked before `load` was done and read the list
        // here, on the main thread; until it's read, the language's own voice speaks.
        let candidates = PhoneVoiceList.ifRead() ?? []
        let chosen = PhoneVoicePreference.current()
        let picked = PhoneVoicePicker.pick(language: language, candidates: candidates, defaultRegion: fallbackRegion, chosen: chosen)
        voice = picked.flatMap { AVSpeechSynthesisVoice(identifier: $0.identifier) } ?? AVSpeechSynthesisVoice(language: language)
        let own = picked.flatMap { voice in chosen == voice.identifier ? voice : nil }
        followsSpokenContent = PhoneVoicePicker.followsSpokenContent(language: language, chosen: own)
        return PhoneVoicePicker.describe(picked) + (own != nil ? ", picked" : followsSpokenContent ? ", Spoken Content first" : "")
    }

    func render(_ sentence: String) -> AsyncThrowingStream<PhonePCM, any Error> {
        let utterance = AVSpeechUtterance(string: sentence)
        utterance.voice = voice
        utterance.prefersAssistiveTechnologySettings = followsSpokenContent
        let (stream, continuation) = AsyncThrowingStream<PhonePCM, any Error>.makeStream()
        let box = RenderBox(continuation: continuation)
        synthesizer.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {
                box.finish()
                return
            }
            if let piece = PhonePCMConvert.int16(pcm) { box.yield(piece) }
        }
        // A voice that never answers (none installed, a stuck synthesizer) is a failure, not silence for ever.
        Task { [weak box] in
            try? await Task.sleep(for: .seconds(Self.firstBufferTimeout))
            box?.timeOut()
        }
        continuation.onTermination = { [weak self] reason in
            guard case .cancelled = reason else { return }
            Task { @MainActor in self?.cancel() }
        }
        return stream
    }

    func cancel() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}

private nonisolated final class RenderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<PhonePCM, any Error>.Continuation?
    private var gotAny = false

    init(continuation: AsyncThrowingStream<PhonePCM, any Error>.Continuation) { self.continuation = continuation }

    func yield(_ piece: PhonePCM) {
        lock.lock(); defer { lock.unlock() }
        gotAny = true
        continuation?.yield(piece)
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        continuation?.finish()
        continuation = nil
    }

    func timeOut() {
        lock.lock(); defer { lock.unlock() }
        guard !gotAny, let continuation else { return }
        continuation.finish(throwing: VoiceFailure(reason: "The \(DeviceWord.name)’s voice didn’t start.", detail: "phone voice timeout"))
        self.continuation = nil
    }
}

nonisolated enum PhonePCMConvert {
    /// Any PCM buffer the synthesizer writes (int16 or float, interleaved or not) as interleaved little-endian int16,
    /// at most two channels.
    static func int16(_ buffer: AVAudioPCMBuffer) -> PhonePCM? {
        let frames = Int(buffer.frameLength)
        let channels = min(2, Int(buffer.format.channelCount))
        guard frames > 0, channels > 0 else { return nil }
        let interleaved = buffer.format.isInterleaved
        let stride = Int(buffer.format.channelCount)
        var out = [Int16](repeating: 0, count: frames * channels)
        switch buffer.format.commonFormat {
        case .pcmFormatInt16:
            guard let data = buffer.int16ChannelData else { return nil }
            for frame in 0..<frames {
                for channel in 0..<channels {
                    out[frame * channels + channel] = interleaved ? data[0][frame * stride + channel] : data[channel][frame]
                }
            }
        case .pcmFormatFloat32:
            guard let data = buffer.floatChannelData else { return nil }
            for frame in 0..<frames {
                for channel in 0..<channels {
                    let value = interleaved ? data[0][frame * stride + channel] : data[channel][frame]
                    out[frame * channels + channel] = Int16(max(-1, min(1, value.isFinite ? value : 0)) * 32_767)
                }
            }
        case .pcmFormatInt32:
            guard let data = buffer.int32ChannelData else { return nil }
            for frame in 0..<frames {
                for channel in 0..<channels {
                    let value = interleaved ? data[0][frame * stride + channel] : data[channel][frame]
                    out[frame * channels + channel] = Int16(truncatingIfNeeded: value >> 16)
                }
            }
        default:
            return nil
        }
        let bytes = out.withUnsafeBufferPointer { pointer in
            Data(buffer: UnsafeBufferPointer(start: UnsafeRawPointer(pointer.baseAddress!).assumingMemoryBound(to: UInt8.self),
                                             count: pointer.count * 2))
        }
        return PhonePCM(data: bytes, sampleRate: buffer.format.sampleRate, channels: channels)
    }

    /// Pieces of about `seconds` each, whole frames: the meter moves with the voice rather than once per sentence.
    static func slices(_ pcm: PhonePCM, seconds: Double = 0.08) -> [Data] {
        let frameBytes = 2 * max(1, pcm.channels)
        let size = max(frameBytes, Int(pcm.sampleRate * seconds) * frameBytes)
        var pieces: [Data] = []
        var start = 0
        while start < pcm.data.count {
            let end = min(pcm.data.count, start + size)
            pieces.append(pcm.data.subdata(in: start..<end))
            start = end
        }
        return pieces
    }
}

#if DEBUG
/// No synthesizer: a quiet tone, `msPerCharacter` ms per character at 22 050 Hz mono, so tests keep time.
@MainActor final class FixturePhoneSpeechRenderer: PhoneSpeechRendering {
    private(set) var spoken: [String] = []
    private(set) var chosenFor: [String] = []
    var fails = false
    var msPerCharacter = 2.0

    func chooseVoice(for text: String) -> String {
        chosenFor.append(text)
        return "fixture"
    }

    func render(_ sentence: String) -> AsyncThrowingStream<PhonePCM, any Error> {
        spoken.append(sentence)
        let fails = self.fails
        let frames = Int(22_050 * Double(sentence.count) * msPerCharacter / 1000)
        return AsyncThrowingStream { continuation in
            if fails {
                continuation.finish(throwing: VoiceFailure(reason: "no voice", detail: nil))
                return
            }
            var pcm = Data(capacity: frames * 2)
            for index in 0..<frames {
                let sample = Int16(3_000 * sin(2 * Double.pi * 330 * Double(index) / 22_050))
                withUnsafeBytes(of: sample.littleEndian) { pcm.append(contentsOf: $0) }
            }
            continuation.yield(PhonePCM(data: pcm, sampleRate: 22_050, channels: 1))
            continuation.finish()
        }
    }

    func cancel() {}
}
#endif
