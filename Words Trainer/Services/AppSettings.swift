import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
final class AppSettings {
    static let shared = AppSettings()

    private enum Keys {
        static let soundEnabled = "settings.soundEnabled"
        static let paceBarEnabled = "settings.paceBarEnabled"
    }

    var isSoundEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isSoundEnabled, forKey: Keys.soundEnabled)
            if !isSoundEnabled {
                WordAudioPlayer.shared.stop()
            }
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
        isSoundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true
        isPaceBarEnabled = defaults.object(forKey: Keys.paceBarEnabled) as? Bool ?? true
    }
}

/// Меню-шестерёнка в тулбаре matching: звук и шкала рекорда.
struct MatchingSettingsMenu: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Menu {
            Toggle(isOn: $settings.isSoundEnabled) {
                Label("Звук", systemImage: "speaker.wave.2.fill")
            }
            Toggle(isOn: $settings.isPaceBarEnabled) {
                Label("Шкала рекорда", systemImage: "trophy.fill")
            }
        } label: {
            Image(systemName: "gearshape.fill")
        }
        .accessibilityLabel("Настройки")
    }
}
