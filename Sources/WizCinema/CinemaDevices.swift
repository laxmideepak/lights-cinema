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
