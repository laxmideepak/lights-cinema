import Foundation

enum CinemaDeviceProviderKind: String, Codable, Sendable {
    case wiz
    case homeAssistant
    case matter
    case vendorAdapter
}

enum CinemaDeviceCategory: String, Codable, Sendable {
    case light
    case speaker
    case television
    case receiver
    case cover
    case fan
    case switchDevice
    case restricted
}

enum CinemaDeviceCapability: String, CaseIterable, Codable, Hashable, Sendable {
    case power
    case brightness
    case color
    case colorTemperature
    case volume
    case mute
    case playback
    case position
    case speed
}

enum CinemaRole: String, CaseIterable, Codable, Identifiable, Sendable {
    case ambientLight = "Ambient light"
    case mediaVolume = "Media volume"
    case shades = "Shades"
    case fan = "Fan"
    case observeOnly = "Observe only"

    var id: String { rawValue }

    static func available(for category: CinemaDeviceCategory) -> [CinemaRole] {
        switch category {
        case .light:
            return [.ambientLight, .observeOnly]
        case .speaker, .television, .receiver:
            return [.mediaVolume, .observeOnly]
        case .cover:
            return [.shades, .observeOnly]
        case .fan:
            return [.fan, .observeOnly]
        case .switchDevice, .restricted:
            return [.observeOnly]
        }
    }

    static func available(for device: CinemaDevice) -> [CinemaRole] {
        switch device.category {
        case .light:
            return [.ambientLight, .observeOnly]
        case .speaker, .television, .receiver:
            return device.capabilities.contains(.volume) ? [.mediaVolume, .observeOnly] : [.observeOnly]
        case .cover:
            return device.capabilities.contains(.position) ? [.shades, .observeOnly] : [.observeOnly]
        case .fan:
            return device.capabilities.contains(.speed) ? [.fan, .observeOnly] : [.observeOnly]
        case .switchDevice, .restricted:
            return [.observeOnly]
        }
    }
}

struct CinemaSessionSettings: Equatable, Sendable {
    /// Home Assistant uses normalized volume, while cover and fan services use percentages.
    var mediaVolume: Double = 0.25
    var shadePosition: Double = 0
    var fanSpeed: Double = 30

    var normalizedMediaVolume: Double { min(max(mediaVolume, 0), 1) }
    var normalizedShadePosition: Int { Int(min(max(shadePosition, 0), 100).rounded()) }
    var normalizedFanSpeed: Int { Int(min(max(fanSpeed, 0), 100).rounded()) }
}

struct CinemaDeviceState: Codable, Equatable, Sendable {
    var isOn: Bool?
    var brightness: Double?
    var color: RGBColor?
    var volume: Double?
    var isMuted: Bool?
    var position: Double?
    var speed: Double?
}

struct CinemaDevice: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var provider: CinemaDeviceProviderKind
    var providerIdentifier: String
    var displayName: String
    var category: CinemaDeviceCategory
    var capabilities: Set<CinemaDeviceCapability>
    var state: CinemaDeviceState
    var selected: Bool
    var role: CinemaRole

    var supportsLiveAmbientSync: Bool {
        CinemaSafetyPolicy.allowsLiveAudio(for: self)
    }
}

struct CinemaDeviceSnapshot: Codable, Equatable, Sendable {
    var deviceID: String
    var provider: CinemaDeviceProviderKind
    var providerIdentifier: String
    var category: CinemaDeviceCategory
    var state: CinemaDeviceState
}

enum CinemaSafetyPolicy {
    static func allowsSelection(for category: CinemaDeviceCategory) -> Bool {
        switch category {
        case .light, .speaker, .television, .receiver, .cover, .fan, .switchDevice:
            return true
        case .restricted:
            return false
        }
    }

    /// Only lights may react continuously to soundtrack samples. Other device
    /// categories may be used for explicit session actions and always restore.
    static func allowsLiveAudio(for device: CinemaDevice) -> Bool {
        device.category == .light
            && device.capabilities.contains(.brightness)
            && (device.capabilities.contains(.color) || device.capabilities.contains(.colorTemperature))
    }

    /// These commands are only sent after the person explicitly presses the
    /// cinema-session button; they never follow individual soundtrack samples.
    static func allowsSessionAction(for device: CinemaDevice) -> Bool {
        switch device.role {
        case .mediaVolume:
            return [.speaker, .television, .receiver].contains(device.category)
                && device.capabilities.contains(.volume)
        case .shades:
            return device.category == .cover && device.capabilities.contains(.position)
        case .fan:
            return device.category == .fan && device.capabilities.contains(.speed)
        case .ambientLight, .observeOnly:
            return false
        }
    }

    static func snapshot(for device: CinemaDevice) -> CinemaDeviceSnapshot {
        CinemaDeviceSnapshot(
            deviceID: device.id,
            provider: device.provider,
            providerIdentifier: device.providerIdentifier,
            category: device.category,
            state: device.state
        )
    }
}
