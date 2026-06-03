import AVFoundation

@MainActor
final class WordAudioPlayer {
    static let shared = WordAudioPlayer()

    enum Style {
        case normal
        case wrong
    }

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var effectPlayer: AVAudioPlayer?

    private static let wrongPitchCents: Float = -500
    private static let wrongSpeechPitchMultiplier: Float = 0.72

    private init() {}

    func playWord(from card: WordCardContent, style: Style = .normal) {
        guard AppSettings.shared.isSoundEnabled else { return }
        if let url = card.audioWordURL {
            playFile(
                at: url,
                pitchCents: style == .wrong ? Self.wrongPitchCents : 0
            )
        } else {
            speak(
                card: card,
                pitchMultiplier: style == .wrong ? Self.wrongSpeechPitchMultiplier : 1
            )
        }
    }

    func playExample(from card: WordCardContent) {
        guard AppSettings.shared.isSoundEnabled else { return }
        if let url = card.audioExampleURL {
            playFile(at: url, pitchCents: 0)
        } else {
            let sentence = card.clozeExamplePlainText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentence.isEmpty else { return }
            speakSentence(sentence)
        }
    }

    /// Plays a bundled sound effect (e.g. the new-record jingle at the end of a round).
    func playEffect(named name: String, withExtension ext: String = "mp3") {
        guard AppSettings.shared.isSoundEnabled else { return }
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else { return }
        configureAudioSession()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = outputVolume
            effectPlayer = player
            player.play()
        } catch {
            // Best-effort: a missing/broken effect should not disrupt the round.
        }
    }

    func applyVolume(_ volume: Double) {
        let value = Float(min(max(volume, 0), 1))
        playerNode.volume = value
        engine.mainMixerNode.outputVolume = value
        effectPlayer?.volume = value
    }

    func stop() {
        playerNode.stop()
        if engine.isRunning {
            engine.stop()
        }
        engine.reset()
        speechSynthesizer.stopSpeaking(at: .immediate)
    }

    private func playFile(at url: URL, pitchCents: Float) {
        speechSynthesizer.stopSpeaking(at: .immediate)
        configureAudioSession()

        guard let file = try? AVAudioFile(forReading: url) else { return }

        stopEnginePlayback()

        timePitch.pitch = pitchCents
        timePitch.rate = 1
        applyVolume(AppSettings.shared.soundVolume)

        let format = file.processingFormat
        engine.attach(playerNode)
        engine.attach(timePitch)
        engine.connect(playerNode, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)

        do {
            try engine.start()
            playerNode.scheduleFile(file, at: nil, completionHandler: nil)
            playerNode.play()
        } catch {
            engine.stop()
            engine.reset()
        }
    }

    private func speak(card: WordCardContent, pitchMultiplier: Float) {
        stopEnginePlayback()
        speechSynthesizer.stopSpeaking(at: .immediate)
        configureAudioSession()

        let utterance = AVSpeechUtterance(string: WordCardContent.headword(from: card.word))
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = pitchMultiplier
        utterance.volume = outputVolume
        speechSynthesizer.speak(utterance)
    }

    private func speakSentence(_ sentence: String) {
        stopEnginePlayback()
        speechSynthesizer.stopSpeaking(at: .immediate)
        configureAudioSession()

        let utterance = AVSpeechUtterance(string: sentence)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.volume = outputVolume
        speechSynthesizer.speak(utterance)
    }

    private func stopEnginePlayback() {
        playerNode.stop()
        if engine.isRunning {
            engine.stop()
        }
        engine.reset()
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.duckOthers])
        try? session.setActive(true)
    }

    private var outputVolume: Float {
        Float(min(max(AppSettings.shared.soundVolume, 0), 1))
    }
}
