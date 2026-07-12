import Foundation

struct RGBColor: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    static let black = RGBColor(red: 0, green: 0, blue: 0)

    func clamped() -> RGBColor {
        RGBColor(
            red: min(max(red, 0), 255),
            green: min(max(green, 0), 255),
            blue: min(max(blue, 0), 255)
        )
    }

    func blended(with other: RGBColor, amount: Double) -> RGBColor {
        let t = min(max(amount, 0), 1)
        return RGBColor(
            red: red + (other.red - red) * t,
            green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t
        )
    }

    var wizValues: (Int, Int, Int) {
        let color = clamped()
        return (Int(color.red.rounded()), Int(color.green.rounded()), Int(color.blue.rounded()))
    }

}

struct PilotState: Codable, Equatable, Sendable {
    var state: Bool?
    var dimming: Int?
    var red: Int?
    var green: Int?
    var blue: Int?
    var temperature: Int?
    var sceneID: Int?

    init(
        state: Bool? = nil,
        dimming: Int? = nil,
        red: Int? = nil,
        green: Int? = nil,
        blue: Int? = nil,
        temperature: Int? = nil,
        sceneID: Int? = nil
    ) {
        self.state = state
        self.dimming = dimming
        self.red = red
        self.green = green
        self.blue = blue
        self.temperature = temperature
        self.sceneID = sceneID
    }

    var restoreParameters: [String: Any] {
        var parameters = [String: Any]()
        if let state { parameters["state"] = state }
        if let dimming { parameters["dimming"] = dimming }
        if let sceneID, sceneID != 0 {
            parameters["sceneId"] = sceneID
        } else if let red, let green, let blue {
            parameters["r"] = red
            parameters["g"] = green
            parameters["b"] = blue
        } else if let temperature {
            parameters["temp"] = temperature
        }
        return parameters
    }
}

struct WiZBulb: Identifiable, Equatable, Sendable {
    let id: String
    var ipAddress: String
    var macAddress: String?
    var moduleName: String?
    var firmwareVersion: String?
    var updateIntervalMilliseconds: Int?
    var supportsColor: Bool
    var pilot: PilotState?
    var selected: Bool

    init(
        ipAddress: String,
        macAddress: String? = nil,
        moduleName: String? = nil,
        firmwareVersion: String? = nil,
        updateIntervalMilliseconds: Int? = nil,
        supportsColor: Bool = true,
        pilot: PilotState? = nil,
        selected: Bool = true
    ) {
        self.id = macAddress ?? ipAddress
        self.ipAddress = ipAddress
        self.macAddress = macAddress
        self.moduleName = moduleName
        self.firmwareVersion = firmwareVersion
        self.updateIntervalMilliseconds = updateIntervalMilliseconds
        self.supportsColor = supportsColor
        self.pilot = pilot
        self.selected = selected
    }

    var displayName: String {
        if let moduleName { return moduleName }
        if let macAddress { return "WiZ \(macAddress.suffix(4))" }
        return "WiZ light"
    }

    var detail: String {
        var parts = [ipAddress]
        if let firmwareVersion { parts.append("FW \(firmwareVersion)") }
        parts.append(supportsColor ? "Full color" : "White")
        return parts.joined(separator: " · ")
    }
}

struct LIFXState: Equatable, Sendable {
    var hue: UInt16
    var saturation: UInt16
    var brightness: UInt16
    var kelvin: UInt16
    var power: UInt16
}

struct LIFXLight: Identifiable, Equatable, Sendable {
    let id: String
    var ipAddress: String
    var port: UInt16
    var target: Data
    var label: String
    var state: LIFXState?
    var selected: Bool

    var displayName: String {
        label.isEmpty ? "LIFX \(id.suffix(6).uppercased())" : label
    }

    var detail: String {
        "\(ipAddress) · LIFX LAN · Full color"
    }
}

struct HueBridge: Identifiable, Equatable, Sendable {
    let id: String
    var ipAddress: String

    var displayName: String { "Philips Hue Bridge" }
    var detail: String { "\(ipAddress) · Press its link button to pair" }
}

enum LightPalette: String, CaseIterable, Identifiable, Sendable {
    case cinema = "Cinema"
    case warm = "Warm"
    case ocean = "Ocean"
    case neon = "Neon"

    var id: String { rawValue }

    var anchors: (bass: RGBColor, mid: RGBColor, treble: RGBColor) {
        switch self {
        case .cinema:
            return (
                RGBColor(red: 244, green: 83, blue: 54),
                RGBColor(red: 136, green: 80, blue: 230),
                RGBColor(red: 55, green: 190, blue: 255)
            )
        case .warm:
            return (
                RGBColor(red: 255, green: 78, blue: 26),
                RGBColor(red: 255, green: 157, blue: 50),
                RGBColor(red: 255, green: 220, blue: 160)
            )
        case .ocean:
            return (
                RGBColor(red: 20, green: 58, blue: 173),
                RGBColor(red: 16, green: 158, blue: 190),
                RGBColor(red: 120, green: 225, blue: 255)
            )
        case .neon:
            return (
                RGBColor(red: 255, green: 30, blue: 130),
                RGBColor(red: 154, green: 60, blue: 255),
                RGBColor(red: 25, green: 225, blue: 255)
            )
        }
    }
}

struct AudioMetrics: Equatable, Sendable {
    var level: Double = 0
    var bass: Double = 0
    var mid: Double = 0
    var treble: Double = 0
    var dynamics: Double = 0
    var transient: Double = 0
    var mood: CinemaMood = .ambience
    var event: CinemaEvent = .quiet
    var confidence: Double = 0
    var beat: Bool = false
    var isSilent: Bool = true
}

enum CinemaMood: String, Equatable, Sendable {
    case ambience = "Ambient"
    case dialogue = "Dialogue"
    case suspense = "Suspense"
    case action = "Action"
}

enum CinemaEvent: String, Equatable, Sendable {
    case settle = "Settle"
    case dialogueLine = "Dialogue line"
    case crescendo = "Crescendo"
    case pulse = "Pulse"
    case stinger = "Stinger"
    case release = "Release"
    case quiet = "Quiet"
}

struct LightTarget: Equatable, Sendable {
    var color: RGBColor
    var brightness: Int
}

struct LightingSettings: Equatable, Sendable {
    var palette: LightPalette = .cinema
    var minimumBrightness: Double = 8
    var maximumBrightness: Double = 65
    var sensitivity: Double = 1
    var responsiveness: Double = 0.5
    var cinemaDepth: Double = 0.72
}
