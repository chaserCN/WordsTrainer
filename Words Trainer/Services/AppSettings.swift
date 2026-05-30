import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
final class AppSettings {
    static let shared = AppSettings()

    private enum Keys {
        static let soundEnabled = "settings.soundEnabled"
    }

    var isSoundEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isSoundEnabled, forKey: Keys.soundEnabled)
            if !isSoundEnabled {
                WordAudioPlayer.shared.stop()
            }
        }
    }

    private init() {
        if UserDefaults.standard.object(forKey: Keys.soundEnabled) != nil {
            isSoundEnabled = UserDefaults.standard.bool(forKey: Keys.soundEnabled)
        } else {
            isSoundEnabled = true
        }
    }
}

struct SoundToggleToolbarButton: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Button {
            settings.isSoundEnabled.toggle()
        } label: {
            Image(systemName: settings.isSoundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
        }
        .accessibilityLabel(settings.isSoundEnabled ? "Выключить звук" : "Включить звук")
    }
}
