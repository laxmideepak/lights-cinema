import Foundation
import Security

enum HomeAssistantError: LocalizedError {
    case invalidURL
    case invalidResponse
    case server(status: Int, message: String)
    case unsafeOperation

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Enter a valid Home Assistant URL, such as http://homeassistant.local:8123."
        case .invalidResponse: return "Home Assistant returned an unreadable response."
        case let .server(status, message): return "Home Assistant error \(status): \(message)"
        case .unsafeOperation: return "WizCinema blocked an unsafe automatic device operation."
        }
    }
}

enum HomeAssistantTokenStore {
    static let service = "com.local.WizCinema.home-assistant"

    static func normalizedAccount(for baseURL: URL) -> String {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = ""
        components?.query = nil
        components?.fragment = nil
        return (components?.url?.absoluteString ?? baseURL.absoluteString).lowercased()
    }

    static func save(_ token: String, for baseURL: URL) throws {
        let account = normalizedAccount(for: baseURL)
        let data = Data(token.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        let result = SecItemAdd(item as CFDictionary, nil)
        guard result == errSecSuccess else { throw HomeAssistantError.server(status: Int(result), message: "Could not save the local access token.") }
    }

    static func read(for baseURL: URL) throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: normalizedAccount(for: baseURL),
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw HomeAssistantError.server(status: Int(status), message: "Could not read the local access token.") }
        return String(data: data, encoding: .utf8)
    }

    static func delete(for baseURL: URL) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service,
                       kSecAttrAccount as String: normalizedAccount(for: baseURL)] as CFDictionary)
    }
}

final class HomeAssistantClient: @unchecked Sendable {
    let baseURL: URL
    private let token: String
    private let session: URLSession

    init?(urlString: String, token: String, session: URLSession = .shared) {
        guard let normalized = Self.normalizedURL(urlString), !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.baseURL = normalized
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    static func normalizedURL(_ value: String) -> URL? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "http://\(text)" }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.host != nil else { return nil }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { return nil }
        return url
    }

    func validateConnection() async throws {
        let (_, response) = try await request(path: "api/", method: "GET")
        guard response.statusCode == 200 else { throw responseError(response) }
    }

    func fetchDevices() async throws -> [CinemaDevice] {
        let (data, response) = try await request(path: "api/states", method: "GET")
        guard response.statusCode == 200 else { throw responseError(response) }
        guard let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw HomeAssistantError.invalidResponse }
        return Self.devices(from: objects)
    }

    func sendLiveLighting(_ target: LightTarget, to device: CinemaDevice) async throws {
        guard device.provider == .homeAssistant, device.supportsLiveAmbientSync else { throw HomeAssistantError.unsafeOperation }
        let (red, green, blue) = target.color.wizValues
        _ = try await callService(domain: "light", service: "turn_on", data: [
            "entity_id": device.providerIdentifier,
            "brightness_pct": min(max(target.brightness, 1), 100),
            "rgb_color": [red, green, blue]
        ])
    }

    func restore(_ snapshot: CinemaDeviceSnapshot) async throws {
        guard snapshot.provider == .homeAssistant else { return }
        switch snapshot.category {
        case .light:
            var data: [String: Any] = ["entity_id": snapshot.providerIdentifier]
            if snapshot.state.isOn == false {
                _ = try await callService(domain: "light", service: "turn_off", data: data)
                return
            }
            if let brightness = snapshot.state.brightness { data["brightness_pct"] = Int((brightness * 100).rounded()) }
            if let color = snapshot.state.color { data["rgb_color"] = [color.wizValues.0, color.wizValues.1, color.wizValues.2] }
            _ = try await callService(domain: "light", service: "turn_on", data: data)
        case .speaker, .television, .receiver:
            guard let volume = snapshot.state.volume else { return }
            _ = try await callService(domain: "media_player", service: "volume_set", data: ["entity_id": snapshot.providerIdentifier, "volume_level": volume])
        case .cover, .fan, .switchDevice, .restricted:
            return
        }
    }

    @discardableResult
    func callService(domain: String, service: String, data: [String: Any]) async throws -> Data {
        guard Self.permitted(domain: domain, service: service, data: data) else { throw HomeAssistantError.unsafeOperation }
        guard let body = try? JSONSerialization.data(withJSONObject: data) else { throw HomeAssistantError.invalidResponse }
        let (responseData, response) = try await request(path: "api/services/\(domain)/\(service)", method: "POST", body: body)
        guard (200 ..< 300).contains(response.statusCode) else { throw responseError(response, data: responseData) }
        return responseData
    }

    static func servicePayload(domain: String, service: String, data: [String: Any]) -> Data? {
        guard permitted(domain: domain, service: service, data: data) else { return nil }
        return try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys])
    }

    static func devices(from states: [[String: Any]]) -> [CinemaDevice] {
        states.compactMap(device(from:))
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private func request(path: String, method: String, body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw HomeAssistantError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HomeAssistantError.invalidResponse }
        return (data, http)
    }

    private func responseError(_ response: HTTPURLResponse, data: Data = Data()) -> HomeAssistantError {
        let message = String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
        return .server(status: response.statusCode, message: message)
    }

    private static func device(from state: [String: Any]) -> CinemaDevice? {
        guard let entityID = state["entity_id"] as? String else { return nil }
        let domain = entityID.split(separator: ".").first.map(String.init) ?? ""
        guard let category = category(for: domain), CinemaSafetyPolicy.allowsSelection(for: category) else { return nil }
        let attributes = state["attributes"] as? [String: Any] ?? [:]
        let capabilities = capabilities(for: domain, attributes: attributes)
        let friendlyName = attributes["friendly_name"] as? String ?? entityID
        return CinemaDevice(
            id: "ha:\(entityID)", provider: .homeAssistant, providerIdentifier: entityID,
            displayName: friendlyName, category: category, capabilities: capabilities,
            state: deviceState(domain: domain, state: state["state"] as? String, attributes: attributes),
            selected: category == .light && capabilities.contains(.brightness),
            role: category == .light ? .ambientLight : .observeOnly
        )
    }

    private static func category(for domain: String) -> CinemaDeviceCategory? {
        switch domain {
        case "light": return .light
        case "media_player": return .speaker
        case "cover": return .cover
        case "fan": return .fan
        case "switch": return .switchDevice
        default: return nil
        }
    }

    private static func capabilities(for domain: String, attributes: [String: Any]) -> Set<CinemaDeviceCapability> {
        switch domain {
        case "light":
            var result: Set<CinemaDeviceCapability> = [.power]
            if attributes["brightness"] != nil || attributes["supported_color_modes"] != nil { result.insert(.brightness) }
            let modes = attributes["supported_color_modes"] as? [String] ?? []
            if modes.contains(where: { $0.contains("rgb") || $0 == "hs" || $0 == "xy" }) { result.insert(.color) }
            if modes.contains(where: { $0.contains("temp") }) { result.insert(.colorTemperature) }
            return result
        case "media_player": return [.power, .volume, .mute, .playback]
        case "cover": return [.position]
        case "fan": return [.power, .speed]
        case "switch": return [.power]
        default: return []
        }
    }

    private static func deviceState(domain: String, state: String?, attributes: [String: Any]) -> CinemaDeviceState {
        let isOn = state.map { $0 != "off" && $0 != "unavailable" && $0 != "unknown" }
        let brightness = (attributes["brightness"] as? Double).map { min(max($0 / 255, 0), 1) }
            ?? (attributes["brightness"] as? Int).map { min(max(Double($0) / 255, 0), 1) }
        var color: RGBColor?
        if let rgb = attributes["rgb_color"] as? [Double], rgb.count == 3 { color = RGBColor(red: rgb[0], green: rgb[1], blue: rgb[2]) }
        if let rgb = attributes["rgb_color"] as? [Int], rgb.count == 3 { color = RGBColor(red: Double(rgb[0]), green: Double(rgb[1]), blue: Double(rgb[2])) }
        return CinemaDeviceState(
            isOn: isOn, brightness: brightness, color: color,
            volume: attributes["volume_level"] as? Double,
            isMuted: attributes["is_volume_muted"] as? Bool,
            position: attributes["current_position"] as? Double,
            speed: attributes["percentage"] as? Double
        )
    }

    private static func permitted(domain: String, service: String, data: [String: Any]) -> Bool {
        guard let entityID = data["entity_id"] as? String, entityID.hasPrefix("\(domain).") else { return false }
        switch (domain, service) {
        case ("light", "turn_on"), ("light", "turn_off"), ("media_player", "volume_set"):
            return true
        default:
            return false
        }
    }
}
