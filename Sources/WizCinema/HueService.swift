import Foundation
import Security

enum HueServiceError: LocalizedError {
    case bridge(String)
    case response(String)

    var errorDescription: String? {
        switch self {
        case .bridge(let message), .response(let message): return message
        }
    }
}

final class HueCredentialStore: @unchecked Sendable {
    private let service = "com.local.WizCinema.hue"

    func username(for bridgeID: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: bridgeID,
            kSecReturnData: true
        ]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(username: String, for bridgeID: String) {
        let attributes: [CFString: Any] = [kSecValueData: Data(username.utf8)]
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: bridgeID]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var insert = query
            insert[kSecValueData] = Data(username.utf8)
            _ = SecItemAdd(insert as CFDictionary, nil)
        }
    }
}

final class HueService: @unchecked Sendable {
    private struct PairResponse: Decodable {
        struct Success: Decodable { let username: String }
        struct ErrorBody: Decodable { let description: String }
        let success: Success?
        let error: ErrorBody?
    }

    private struct LightPayload: Decodable {
        struct State: Decodable {
            let on: Bool
            let bri: Int?
            let hue: Int?
            let sat: Int?
            let ct: Int?
        }
        let name: String
        let state: State
    }

    let credentials = HueCredentialStore()

    func pair(bridge: HueBridge) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["devicetype": "wizcinema#mac"])
        let response = try await request(path: "/api", bridgeAddress: bridge.ipAddress, method: "POST", body: body)
        let results = try JSONDecoder().decode([PairResponse].self, from: response)
        if let username = results.first?.success?.username {
            credentials.save(username: username, for: bridge.id)
            return username
        }
        let message = results.first?.error?.description ?? "The Hue bridge rejected pairing."
        throw HueServiceError.bridge(message)
    }

    func lights(bridge: HueBridge, username: String) async throws -> [HueLight] {
        let data = try await request(path: "/api/\(username)/lights", bridgeAddress: bridge.ipAddress, method: "GET")
        let payloads = try JSONDecoder().decode([String: LightPayload].self, from: data)
        return payloads.map { lightID, payload in
            let state = HueLightState(on: payload.state.on, brightness: payload.state.bri ?? 1, hue: payload.state.hue, saturation: payload.state.sat, colorTemperature: payload.state.ct)
            return HueLight(
                id: "\(bridge.id):\(lightID)", bridgeID: bridge.id, bridgeAddress: bridge.ipAddress,
                username: username, lightID: lightID, name: payload.name,
                supportsColor: payload.state.hue != nil && payload.state.sat != nil,
                state: state, selected: true
            )
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func refresh(_ light: HueLight) async -> HueLight? {
        do {
            let data = try await request(path: "/api/\(light.username)/lights/\(light.lightID)", bridgeAddress: light.bridgeAddress, method: "GET")
            let payload = try JSONDecoder().decode(LightPayload.self, from: data)
            var updated = light
            updated.name = payload.name
            updated.supportsColor = payload.state.hue != nil && payload.state.sat != nil
            updated.state = HueLightState(on: payload.state.on, brightness: payload.state.bri ?? 1, hue: payload.state.hue, saturation: payload.state.sat, colorTemperature: payload.state.ct)
            return updated
        } catch { return nil }
    }

    func send(target: LightTarget, to light: HueLight) async {
        let hsb = hsb(from: target.color)
        var payload: [String: Any] = ["on": true, "bri": max(1, min(254, Int((Double(target.brightness) / 100 * 254).rounded()))), "transitiontime": 1]
        if light.supportsColor {
            payload["hue"] = hsb.hue
            payload["sat"] = hsb.saturation
        }
        await put(payload, light: light)
    }

    func restore(_ state: HueLightState, to light: HueLight) async {
        var payload: [String: Any] = ["on": state.on, "bri": max(1, min(254, state.brightness)), "transitiontime": 2]
        if let hue = state.hue, let saturation = state.saturation { payload["hue"] = hue; payload["sat"] = saturation }
        if let colorTemperature = state.colorTemperature { payload["ct"] = colorTemperature }
        await put(payload, light: light)
    }

    private func put(_ payload: [String: Any], light: HueLight) async {
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        _ = try? await request(path: "/api/\(light.username)/lights/\(light.lightID)/state", bridgeAddress: light.bridgeAddress, method: "PUT", body: body)
    }

    private func request(path: String, bridgeAddress: String, method: String, body: Data? = nil) async throws -> Data {
        guard let url = URL(string: "https://\(bridgeAddress)\(path)") else { throw HueServiceError.bridge("The Hue bridge address is invalid.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 4
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw HueServiceError.response("The Hue bridge did not accept the request.")
        }
        return data
    }

    private func hsb(from color: RGBColor) -> (hue: Int, saturation: Int) {
        let c = color.clamped()
        let red = c.red / 255, green = c.green / 255, blue = c.blue / 255
        let maximum = max(red, green, blue), minimum = min(red, green, blue), delta = maximum - minimum
        guard delta > 0.000_01 else { return (0, 0) }
        let degrees: Double
        if maximum == red { degrees = 60 * ((green - blue) / delta).truncatingRemainder(dividingBy: 6) }
        else if maximum == green { degrees = 60 * ((blue - red) / delta + 2) }
        else { degrees = 60 * ((red - green) / delta + 4) }
        return (Int((((degrees < 0 ? degrees + 360 : degrees) / 360) * 65_535).rounded()), Int(((delta / maximum) * 254).rounded()))
    }
}
