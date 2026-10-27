import Foundation

/// Every tunable parameter of the CRT simulation. Values are normalized to 0...1
/// unless noted otherwise.
public struct CRTSettings: Codable, Equatable, Sendable {
    public enum MaskType: Int, Codable, CaseIterable, Sendable {
        case none, apertureGrille, shadowMask, slotMask

        public var name: String {
            switch self {
            case .none: "None"
            case .apertureGrille: "Grille"
            case .shadowMask: "Dots"
            case .slotMask: "Slots"
            }
        }
    }

    public enum Phosphor: Int, Codable, CaseIterable, Sendable {
        case color, green, amber, white

        public var name: String {
            switch self {
            case .color: "Color"
            case .green: "Green"
            case .amber: "Amber"
            case .white: "White"
            }
        }

        /// Linear-light tint for monochrome tubes.
        var tint: SIMD3<Float>? {
            switch self {
            case .color: nil
            case .green: SIMD3(0.03, 1.0, 0.1)
            case .amber: SIMD3(1.0, 0.42, 0.02)
            case .white: SIMD3(0.85, 0.92, 1.0)
            }
        }
    }

    public var curvature: Double
    public var scanlines: Double
    /// Number of visible scanlines (vertical resolution of the simulated signal).
    public var lines: Double
    public var sharpness: Double
    public var colorBleed: Double
    public var convergence: Double
    public var maskType: MaskType
    public var maskStrength: Double
    /// Width of one phosphor stripe, in points.
    public var maskSize: Double
    public var glow: Double
    public var persistence: Double
    public var noise: Double
    public var vignette: Double
    /// Multiplier, around 1.0.
    public var brightness: Double
    /// Multiplier, around 1.0.
    public var saturation: Double
    public var phosphor: Phosphor

    public static let `default` = CRTPreset.livingRoom.settings
}

public struct CRTPreset: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let settings: CRTSettings

    public static let studioMonitor = CRTPreset(
        id: "studio", name: "Studio Monitor",
        settings: CRTSettings(
            curvature: 0.15, scanlines: 0.85, lines: 480, sharpness: 0.8, colorBleed: 0.05,
            convergence: 0.05, maskType: .apertureGrille, maskStrength: 0.45, maskSize: 1,
            glow: 0.3, persistence: 0.1, noise: 0.0, vignette: 0.2, brightness: 1.05,
            saturation: 1.05, phosphor: .color))

    public static let livingRoom = CRTPreset(
        id: "living-room", name: "Living Room TV",
        settings: CRTSettings(
            curvature: 0.55, scanlines: 0.6, lines: 480, sharpness: 0.45, colorBleed: 0.45,
            convergence: 0.35, maskType: .shadowMask, maskStrength: 0.4, maskSize: 1,
            glow: 0.5, persistence: 0.25, noise: 0.15, vignette: 0.5, brightness: 1.1,
            saturation: 1.1, phosphor: .color))

    public static let arcade = CRTPreset(
        id: "arcade", name: "Arcade Cabinet",
        settings: CRTSettings(
            curvature: 0.4, scanlines: 1.0, lines: 240, sharpness: 0.6, colorBleed: 0.15,
            convergence: 0.15, maskType: .slotMask, maskStrength: 0.5, maskSize: 1,
            glow: 0.6, persistence: 0.2, noise: 0.05, vignette: 0.35, brightness: 1.15,
            saturation: 1.15, phosphor: .color))

    public static let greenTerminal = CRTPreset(
        id: "green", name: "Green Terminal",
        settings: CRTSettings(
            curvature: 0.45, scanlines: 0.85, lines: 360, sharpness: 0.7, colorBleed: 0,
            convergence: 0, maskType: .none, maskStrength: 0, maskSize: 1,
            glow: 0.8, persistence: 0.6, noise: 0.06, vignette: 0.45, brightness: 1.25,
            saturation: 1, phosphor: .green))

    public static let amberTerminal = CRTPreset(
        id: "amber", name: "Amber Terminal",
        settings: CRTSettings(
            curvature: 0.45, scanlines: 0.85, lines: 360, sharpness: 0.7, colorBleed: 0,
            convergence: 0, maskType: .none, maskStrength: 0, maskSize: 1,
            glow: 0.8, persistence: 0.6, noise: 0.06, vignette: 0.45, brightness: 1.25,
            saturation: 1, phosphor: .amber))

    public static let all = [studioMonitor, livingRoom, arcade, greenTerminal, amberTerminal]

    public static func named(_ id: String) -> CRTPreset? {
        all.first { $0.id == id }
    }
}
