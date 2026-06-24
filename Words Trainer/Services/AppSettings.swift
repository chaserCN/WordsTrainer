import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
final class AppSettings {
    static let shared = AppSettings()

    private enum Keys {
        static let soundEnabled = "settings.soundEnabled"
        static let soundVolume = "settings.soundVolume"
        static let paceBarEnabled = "settings.paceBarEnabled"
        static let flashcardDisplayMode = "settings.flashcardDisplayMode"
    }

    private static let defaultSoundVolume = 0.75

    var soundVolume: Double {
        didSet {
            let clamped = Self.clampedVolume(soundVolume)
            if soundVolume != clamped {
                soundVolume = clamped
                return
            }
            UserDefaults.standard.set(soundVolume, forKey: Keys.soundVolume)
            UserDefaults.standard.set(isSoundEnabled, forKey: Keys.soundEnabled)
            WordAudioPlayer.shared.applyVolume(soundVolume)
            if soundVolume == 0 {
                WordAudioPlayer.shared.stop()
            }
        }
    }

    var isSoundEnabled: Bool {
        get { soundVolume > 0 }
        set {
            soundVolume = newValue ? max(soundVolume, Self.defaultSoundVolume) : 0
        }
    }

    /// Показывать ли шкалу рекорда (темп-линию) в matching.
    var isPaceBarEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isPaceBarEnabled, forKey: Keys.paceBarEnabled)
        }
    }

    var flashcardDisplayMode: FlashcardDisplayMode {
        didSet {
            UserDefaults.standard.set(flashcardDisplayMode.rawValue, forKey: Keys.flashcardDisplayMode)
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        if let savedVolume = defaults.object(forKey: Keys.soundVolume) as? Double {
            soundVolume = Self.clampedVolume(savedVolume)
        } else {
            let legacySoundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true
            soundVolume = legacySoundEnabled ? Self.defaultSoundVolume : 0
        }
        isPaceBarEnabled = defaults.object(forKey: Keys.paceBarEnabled) as? Bool ?? true
        if let rawMode = defaults.string(forKey: Keys.flashcardDisplayMode),
           let mode = FlashcardDisplayMode(rawValue: rawMode) {
            flashcardDisplayMode = mode
        } else {
            flashcardDisplayMode = .oneSense
        }
        WordAudioPlayer.shared.applyVolume(soundVolume)
    }

    private static func clampedVolume(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

/// Шестерёнка настроек на главном окне (слева от синхронизации). Пока только
/// громкость звука; единая точка входа в настройки приложения.
struct MainSettingsButton: View {
    @State private var isShowingSettings = false

    var body: some View {
        Button {
            isShowingSettings.toggle()
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(LovableSurface.foreground)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle().stroke(.white.opacity(0.58), lineWidth: 0.8)
                }
                .shadow(color: oklch(0.18, 0.05, 260, 0.12), radius: 12, x: 0, y: 6)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text("Настройки"))
        .popover(isPresented: $isShowingSettings) {
            SoundSettingsPopover()
                .presentationCompactAdaptation(.popover)
        }
    }
}

/// Меню-шестерёнка в тулбаре matching: звук и шкала рекорда.
struct MatchingSettingsMenu: View {
    @Environment(AppSettings.self) private var settings
    @State private var isShowingSettings = false

    var body: some View {
        Button {
            isShowingSettings.toggle()
        } label: {
            Image(systemName: "gearshape.fill")
        }
        .accessibilityLabel("Настройки")
        .popover(isPresented: $isShowingSettings) {
            SoundSettingsPopover(showsSound: false, showsPaceBarToggle: true)
                .presentationCompactAdaptation(.popover)
        }
    }
}

/// Меню-шестерёнка в тулбаре flashcards: способ показа senses.
struct FlashcardSettingsMenu: View {
    @State private var isShowingSettings = false

    var body: some View {
        Button {
            isShowingSettings.toggle()
        } label: {
            Image(systemName: "gearshape.fill")
        }
        .accessibilityLabel("Настройки")
        .popover(isPresented: $isShowingSettings) {
            SoundSettingsPopover(showsSound: false, showsFlashcardMode: true)
                .presentationCompactAdaptation(.popover)
        }
    }
}

private struct SoundSettingsPopover: View {
    @Environment(AppSettings.self) private var settings
    let showsSound: Bool
    let showsPaceBarToggle: Bool
    let showsFlashcardMode: Bool

    init(showsSound: Bool = true, showsPaceBarToggle: Bool = false, showsFlashcardMode: Bool = false) {
        self.showsSound = showsSound
        self.showsPaceBarToggle = showsPaceBarToggle
        self.showsFlashcardMode = showsFlashcardMode
    }

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 18) {
            if showsSound {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: settings.isSoundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .frame(width: 24)
                        Text("Громкость")
                            .font(.headline)
                        Spacer()
                        Text("\(Int((settings.soundVolume * 100).rounded()))%")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Slider(value: $settings.soundVolume, in: 0...1) {
                        Text("Громкость")
                    } minimumValueLabel: {
                        Image(systemName: "speaker.slash.fill")
                    } maximumValueLabel: {
                        Image(systemName: "speaker.wave.2.fill")
                    }
                }
            }

            if showsFlashcardMode {
                if showsSound { Divider() }
                VStack(alignment: .leading, spacing: 10) {
                    Label(L10n.text("Значения"), systemImage: "rectangle.stack.fill")
                        .font(.headline)
                    Picker(L10n.text("Значения"), selection: $settings.flashcardDisplayMode) {
                        Text(L10n.text("Одной картой")).tag(FlashcardDisplayMode.wholeCard)
                        Text(L10n.text("Несколькими")).tag(FlashcardDisplayMode.oneSense)
                    }
                    .pickerStyle(.segmented)
                }
            }

            if showsPaceBarToggle {
                if showsSound || showsFlashcardMode { Divider() }
                Toggle(isOn: $settings.isPaceBarEnabled) {
                    Label("Шкала рекорда", systemImage: "trophy.fill")
                }
            }
        }
        .padding(20)
        .frame(width: 300)
        .presentationDetents([.height(popoverHeight)])
    }

    private var popoverHeight: CGFloat {
        var height: CGFloat = 40 // вертикальные отступы контейнера
        if showsSound { height += 90 }
        if showsFlashcardMode { height += 80 }
        if showsPaceBarToggle { height += 50 }
        return max(height, 110)
    }
}
