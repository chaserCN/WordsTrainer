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

    private init() {
        let defaults = UserDefaults.standard
        if let savedVolume = defaults.object(forKey: Keys.soundVolume) as? Double {
            soundVolume = Self.clampedVolume(savedVolume)
        } else {
            let legacySoundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true
            soundVolume = legacySoundEnabled ? Self.defaultSoundVolume : 0
        }
        isPaceBarEnabled = defaults.object(forKey: Keys.paceBarEnabled) as? Bool ?? true
    }

    private static func clampedVolume(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

/// Кнопка настройки громкости в тулбаре.
struct SoundToggleButton: View {
    @Environment(AppSettings.self) private var settings
    @State private var isShowingVolume = false

    var body: some View {
        Button {
            isShowingVolume.toggle()
        } label: {
            Image(systemName: soundIcon)
        }
        .accessibilityLabel("Громкость")
        .accessibilityValue(volumeAccessibilityValue)
        .popover(isPresented: $isShowingVolume) {
            SoundSettingsPopover()
                .presentationCompactAdaptation(.popover)
        }
    }

    private var soundIcon: String {
        switch settings.soundVolume {
        case 0:
            return "speaker.slash.fill"
        case ..<0.45:
            return "speaker.wave.1.fill"
        default:
            return "speaker.wave.2.fill"
        }
    }

    private var volumeAccessibilityValue: String {
        "\(Int((settings.soundVolume * 100).rounded()))%"
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
            SoundSettingsPopover(showsPaceBarToggle: true)
                .presentationCompactAdaptation(.popover)
        }
    }
}

private struct SoundSettingsPopover: View {
    @Environment(AppSettings.self) private var settings
    let showsPaceBarToggle: Bool

    init(showsPaceBarToggle: Bool = false) {
        self.showsPaceBarToggle = showsPaceBarToggle
    }

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 18) {
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

            if showsPaceBarToggle {
                Divider()
                Toggle(isOn: $settings.isPaceBarEnabled) {
                    Label("Шкала рекорда", systemImage: "trophy.fill")
                }
            }
        }
        .padding(20)
        .frame(width: 300)
        .presentationDetents([.height(showsPaceBarToggle ? 220 : 170)])
    }
}
