import CRTCore
import Foundation
import Observation

/// App-wide CRT settings, shared by every player window and persisted across launches.
@Observable
final class CRTSettingsStore {
    /// A preset switch or on/off toggle that windows announce, like a TV
    /// changing channels. `id` makes repeats of the same text distinct.
    struct Announcement: Equatable, Sendable {
        let id: Int
        let text: String
    }

    static let shared = CRTSettingsStore()

    var settings: CRTSettings {
        didSet { save() }
    }
    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
            announce(isEnabled ? (preset?.name ?? "CRT On") : "CRT Off")
        }
    }
    private(set) var announcement: Announcement?
    /// Show the picture as light on a translucent glass window instead of a black one.
    var glassPane: Bool {
        didSet { UserDefaults.standard.set(glassPane, forKey: Keys.glassPane) }
    }
    /// How see-through the picture is in glass-pane mode, 0...1.
    var glassTransparency: Double {
        didSet { UserDefaults.standard.set(glassTransparency, forKey: Keys.glassTransparency) }
    }
    /// How light the glass is in glass-pane mode: 0 dark smoked, 1 bright frosted.
    var glassBrightness: Double {
        didSet { UserDefaults.standard.set(glassBrightness, forKey: Keys.glassBrightness) }
    }

    /// The preset matching the current settings exactly, if any.
    var preset: CRTPreset? {
        CRTPreset.all.first { $0.settings == settings }
    }

    private enum Keys {
        static let settings = "crtSettings"
        static let enabled = "crtEnabled"
        static let glassPane = "glassPane"
        static let glassTransparency = "glassTransparency"
        static let glassBrightness = "glassBrightness"
    }

    private init() {
        let defaults = UserDefaults.standard
        settings = defaults.data(forKey: Keys.settings)
            .flatMap { try? JSONDecoder().decode(CRTSettings.self, from: $0) } ?? .default
        isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        glassPane = defaults.bool(forKey: Keys.glassPane)
        glassTransparency = defaults.object(forKey: Keys.glassTransparency) as? Double ?? 0.4
        glassBrightness = defaults.object(forKey: Keys.glassBrightness) as? Double ?? 0.45
    }

    func apply(_ preset: CRTPreset) {
        settings = preset.settings
        if isEnabled {
            announce(preset.name)
        } else {
            isEnabled = true
        }
    }

    /// Steps through presets in order; from custom settings, starts at the first.
    @discardableResult
    func cyclePreset(by offset: Int) -> CRTPreset {
        let all = CRTPreset.all
        let index = preset.flatMap { current in all.firstIndex { $0.id == current.id } }
        let next = index.map { (($0 + offset) % all.count + all.count) % all.count } ?? 0
        apply(all[next])
        return all[next]
    }

    private func announce(_ text: String) {
        announcement = Announcement(id: (announcement?.id ?? 0) + 1, text: text)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Keys.settings)
        }
    }
}
