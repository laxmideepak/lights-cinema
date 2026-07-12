import Foundation

enum NanoleafServiceError: LocalizedError {
    case request(String)
    var errorDescription: String? {
        switch self {
        case .request(let message): return message
        }
    }
}

final class NanoleafService: @unchecked Sendable {
    private struct TokenResponse: Decodable { let auth_token: String }
    private struct Value: Decodable { let value: Int }
    private struct BoolValue: Decodable { let value: Bool }
    private struct Info: Decodable {
        struct State: Decodable {
            let on: BoolValue
            let brightness: Value
            let hue: Value
            let sat: Value
            let ct: Value
        }
        let name: String
        let state: State
    }

    let credentials = HueCredentialStore(service: "com.local.WizCinema.nanoleaf")

    func pair(device: NanoleafDevice) async throws -> String {
        let data = try await request(path: "/api/v1/new", device: device, method: "POST")
        let token = try JSONDecoder().decode(TokenResponse.self, from: data).auth_token
        credentials.save(username: token, for: device.id)
        return token
    }

    func light(device: NanoleafDevice, token: String) async throws -> NanoleafLight {
        let info = try await info(device: device, token: token)
        return NanoleafLight(id: "nanoleaf:\(device.id)", deviceID: device.id, host: device.host, port: device.port, token: token, name: info.name, state: state(from: info), selected: true)
    }

    func refresh(_ light: NanoleafLight) async -> NanoleafLight? {
        let device = NanoleafDevice(id: light.deviceID, host: light.host, port: light.port)
        guard let info = try? await info(device: device, token: light.token) else { return nil }
        var refreshed = light
        refreshed.name = info.name
        refreshed.state = state(from: info)
        return refreshed
    }

    func send(target: LightTarget, to light: NanoleafLight) async {
        let hsb = hsb(from: target.color)
        let payload: [String: Any] = ["on": ["value": true], "brightness": ["value": target.brightness], "hue": ["value": hsb.hue], "sat": ["value": hsb.saturation], "transitionTime": 1]
        await put(payload, light: light)
    }

    func restore(_ state: NanoleafState, to light: NanoleafLight) async {
        let payload: [String: Any] = ["on": ["value": state.on], "brightness": ["value": state.brightness], "hue": ["value": state.hue], "sat": ["value": state.saturation], "ct": ["value": state.colorTemperature], "transitionTime": 2]
        await put(payload, light: light)
    }

    private func info(device: NanoleafDevice, token: String) async throws -> Info {
        let data = try await request(path: "/api/v1/\(token)", device: device, method: "GET")
        return try JSONDecoder().decode(Info.self, from: data)
    }

    private func put(_ payload: [String: Any], light: NanoleafLight) async {
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let device = NanoleafDevice(id: light.deviceID, host: light.host, port: light.port)
        _ = try? await request(path: "/api/v1/\(light.token)/state", device: device, method: "PUT", body: body)
    }

    private func request(path: String, device: NanoleafDevice, method: String, body: Data? = nil) async throws -> Data {
        guard let url = URL(string: "http://\(device.host):\(device.port)\(path)") else { throw NanoleafServiceError.request("The Nanoleaf address is invalid.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 4
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else { throw NanoleafServiceError.request("Nanoleaf did not accept the local request.") }
        return data
    }

    private func state(from info: Info) -> NanoleafState {
        NanoleafState(on: info.state.on.value, brightness: info.state.brightness.value, hue: info.state.hue.value, saturation: info.state.sat.value, colorTemperature: info.state.ct.value)
    }

    private func hsb(from color: RGBColor) -> (hue: Int, saturation: Int) {
        let c = color.clamped(), red = c.red / 255, green = c.green / 255, blue = c.blue / 255
        let maximum = max(red, green, blue), minimum = min(red, green, blue), delta = maximum - minimum
        guard delta > 0.000_01 else { return (0, 0) }
        let degrees: Double
        if maximum == red { degrees = 60 * ((green - blue) / delta).truncatingRemainder(dividingBy: 6) }
        else if maximum == green { degrees = 60 * ((blue - red) / delta + 2) }
        else { degrees = 60 * ((red - green) / delta + 4) }
        return (Int((degrees < 0 ? degrees + 360 : degrees).rounded()), Int(((delta / maximum) * 100).rounded()))
    }
}
