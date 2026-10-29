import Foundation
import Observation

public struct SubtitleSettings: Codable, Equatable, Sendable {
    public struct Color: Codable, Equatable, Sendable {
        public var red: Double
        public var green: Double
        public var blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        var mpvValue: String { "\(red)/\(green)/\(blue)" }
    }

    public var scale = 1.0
    public var font = "sans-serif"
    public var color = Color(red: 1, green: 1, blue: 1)
    public var bold = false
    public var italic = false
    public var outlineSize = 1.65
    public var outlineColor = Color(red: 0, green: 0, blue: 0)
    public var shadow = false
    public var backgroundOpacity = 0.0
    public var overrideEmbeddedStyles = false

    public init() {}

    var mpvOptions: [String: String] {
        [
            "sub-scale": String(scale),
            "sub-font": font,
            "sub-color": color.mpvValue,
            "sub-bold": bold ? "yes" : "no",
            "sub-italic": italic ? "yes" : "no",
            "sub-outline-size": String(outlineSize),
            "sub-outline-color": outlineColor.mpvValue,
            "sub-border-style": backgroundOpacity > 0 ? "background-box" : "outline-and-shadow",
            "sub-back-color": "0/0/0/\(backgroundOpacity > 0 ? backgroundOpacity : 0.68)",
            "sub-shadow-offset": backgroundOpacity > 0 ? "4" : (shadow ? "2" : "0"),
            "sub-ass-override": overrideEmbeddedStyles ? "force" : "scale",
        ]
    }
}

/// Appearance is shared across windows; track selection stays local to each player.
@Observable
public final class SubtitleSettingsStore {
    public static let shared = SubtitleSettingsStore()
    public var settings: SubtitleSettings {
        didSet {
            if let data = try? JSONEncoder().encode(settings) {
                defaults?.set(data, forKey: Self.key)
            }
        }
    }

    @ObservationIgnored private let defaults: UserDefaults?
    private static let key = "subtitleSettings"

    public init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        settings = defaults?.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(SubtitleSettings.self, from: $0) } ?? SubtitleSettings()
    }
}
