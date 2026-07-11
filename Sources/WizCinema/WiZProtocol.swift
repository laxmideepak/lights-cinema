import Foundation

enum WiZProtocol {
    static let port: UInt16 = 38_899

    static let discoveryMessage = Data(
        "{\"method\":\"registration\",\"params\":{\"phoneMac\":\"AAAAAAAAAAAA\",\"register\":false,\"phoneIp\":\"1.2.3.4\",\"id\":\"1\"}}".utf8
    )

    static func request(_ method: String, parameters: [String: Any] = [:]) -> Data? {
        let payload: [String: Any] = ["method": method, "params": parameters]
        return try? JSONSerialization.data(withJSONObject: payload, options: [])
    }

    static func setPilot(color: RGBColor?, brightness: Int, state: Bool = true) -> Data? {
        var parameters: [String: Any] = [
            "state": state,
            "dimming": min(max(brightness, 1), 100)
        ]
        if let color {
            let (red, green, blue) = color.wizValues
            parameters["r"] = red
            parameters["g"] = green
            parameters["b"] = blue
        }
        return request("setPilot", parameters: parameters)
    }

    static func setPilot(parameters: [String: Any]) -> Data? {
        request("setPilot", parameters: parameters)
    }

    static func discoveryMAC(from data: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let result = json["result"] as? [String: Any],
            let mac = result["mac"] as? String,
            !mac.isEmpty
        else { return nil }
        return mac
    }

    static func pilotState(from data: Data) -> PilotState? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let result = json["result"] as? [String: Any]
        else { return nil }

        return PilotState(
            state: result["state"] as? Bool,
            dimming: result["dimming"] as? Int,
            red: result["r"] as? Int,
            green: result["g"] as? Int,
            blue: result["b"] as? Int,
            temperature: result["temp"] as? Int,
            sceneID: result["sceneId"] as? Int
        )
    }

    static func systemInfo(from data: Data) -> (module: String?, firmware: String?, interval: Int?) {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let result = json["result"] as? [String: Any]
        else { return (nil, nil, nil) }
        return (
            result["moduleName"] as? String,
            result["fwVersion"] as? String,
            result["accUdpPropRate"] as? Int
        )
    }

    static func supportsColor(module: String?, modelConfig: Data?) -> Bool {
        if let module, module.localizedCaseInsensitiveContains("RGB") { return true }
        guard
            let modelConfig,
            let json = try? JSONSerialization.jsonObject(with: modelConfig) as? [String: Any],
            let result = json["result"] as? [String: Any]
        else { return false }
        return (result["lightType"] as? Int) == 1 || (result["hasGradient"] as? Int) == 1
    }
}
