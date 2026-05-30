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
}
