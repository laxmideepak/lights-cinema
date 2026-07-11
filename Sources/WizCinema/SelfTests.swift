import Foundation

enum SelfTests {
    static func run() throws {
        try testDiscoveryRequiresARealResultMAC()
        try testSetPilotClampsBrightnessAndColor()
        try testPilotRestorePreservesSceneBeforeColor()
        try testAnalyzerSeparatesLowAndHighTones()
        try testMapperUsesMinimumBrightnessInSilenceAndSmooths()
        try testHomeAssistantURLAndKeychainAccountNormalization()
        try testHomeAssistantSafeEntityTranslationAndPayload()
        try testCinemaSafetyAndSnapshot()
    }

    private static func testDiscoveryRequiresARealResultMAC() throws {
        let selfEcho = Data("{\"method\":\"registration\",\"params\":{\"phoneMac\":\"AAAAAAAAAAAA\"}}".utf8)
        let bulbResponse = Data("{\"method\":\"registration\",\"result\":{\"mac\":\"cc4085a89152\",\"success\":true}}".utf8)
        try check(WiZProtocol.discoveryMAC(from: selfEcho) == nil, "Discovery must reject our broadcast echo.")
        try check(WiZProtocol.discoveryMAC(from: bulbResponse) == "cc4085a89152", "Discovery must read a bulb MAC.")
    }

    private static func testSetPilotClampsBrightnessAndColor() throws {
        guard
            let payload = WiZProtocol.setPilot(color: RGBColor(red: 300, green: -8, blue: 27.8), brightness: 132),
            let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
            let parameters = json["params"] as? [String: Any]
        else { throw Failure(message: "Could not decode a setPilot payload.") }
        try check(parameters["dimming"] as? Int == 100, "Brightness must clamp to 100.")
        try check(parameters["r"] as? Int == 255, "Red must clamp to 255.")
        try check(parameters["g"] as? Int == 0, "Green must clamp to 0.")
        try check(parameters["b"] as? Int == 28, "Blue should round normally.")
    }

    private static func testPilotRestorePreservesSceneBeforeColor() throws {
        let state = PilotState(state: true, dimming: 44, red: 1, green: 2, blue: 3, temperature: 2700, sceneID: 11)
        let parameters = state.restoreParameters
        try check(parameters["sceneId"] as? Int == 11, "Scene must be restored.")
        try check(parameters["r"] == nil, "Scene restore must not override the scene with stale RGB.")
        try check(parameters["dimming"] as? Int == 44, "Brightness must be restored.")
    }

    private static func testAnalyzerSeparatesLowAndHighTones() throws {
        let analyzer = AudioAnalyzer()
        let sampleRate = 48_000.0
        let low = analyzer.analyze(samples: sineWave(frequency: 100, sampleRate: sampleRate, frames: 16_384), sampleRate: sampleRate)
        try check(low.bass > low.treble, "100 Hz should bias toward bass.")

        analyzer.reset()
        let high = analyzer.analyze(samples: sineWave(frequency: 5_000, sampleRate: sampleRate, frames: 16_384), sampleRate: sampleRate)
        try check(high.treble > high.bass, "5 kHz should bias toward treble.")
        try check(!high.isSilent, "A 0.4-amplitude sine should not be silent.")
    }

    private static func testMapperUsesMinimumBrightnessInSilenceAndSmooths() throws {
        let settings = LightingSettings(palette: .ocean, minimumBrightness: 8, maximumBrightness: 65, sensitivity: 1, responsiveness: 0.5)
        let previous = LightTarget(color: .black, brightness: 8)
        let silence = LightingMapper.target(metrics: AudioMetrics(), settings: settings, previous: previous)
        try check(silence.brightness == 8, "Silence must use the minimum brightness.")

        let loud = AudioMetrics(level: 1, bass: 0.8, mid: 0.15, treble: 0.05, beat: false, isSilent: false)
        let target = LightingMapper.target(metrics: loud, settings: settings, previous: silence)
        try check(target.brightness > silence.brightness && target.brightness <= 65, "Mapped brightness must stay in range.")
        try check(LightingMapper.meaningfullyDifferent(target, from: silence), "A loud change must be emitted.")
    }

    private static func testHomeAssistantURLAndKeychainAccountNormalization() throws {
        let url = try require(HomeAssistantClient.normalizedURL("http://homeassistant.local:8123/"), "HA URL should normalize.")
        try check(url.absoluteString == "http://homeassistant.local:8123", "HA URL must remove a trailing slash.")
        try check(HomeAssistantTokenStore.normalizedAccount(for: url) == "http://homeassistant.local:8123", "Keychain account must be stable.")
        try check(HomeAssistantClient.normalizedURL("ftp://homeassistant.local") == nil, "Only explicit HTTP(S) HA URLs are valid.")
    }

    private static func testHomeAssistantSafeEntityTranslationAndPayload() throws {
        let states: [[String: Any]] = [
            ["entity_id": "light.cinema", "state": "on", "attributes": ["friendly_name": "Cinema Lamp", "brightness": 128, "supported_color_modes": ["rgb"]]],
            ["entity_id": "media_player.receiver", "state": "playing", "attributes": ["volume_level": 0.35]],
            ["entity_id": "lock.front_door", "state": "locked", "attributes": ["friendly_name": "Front Door"]]
        ]
        let devices = HomeAssistantClient.devices(from: states)
        try check(devices.count == 2, "Unsafe Home Assistant domains must be excluded.")
        let light = try require(devices.first(where: { $0.providerIdentifier == "light.cinema" }), "Safe light must be discovered.")
        try check(light.supportsLiveAmbientSync, "RGB HA light must support live ambient sync.")
        let payload = try require(HomeAssistantClient.servicePayload(domain: "light", service: "turn_on", data: ["entity_id": "light.cinema", "brightness_pct": 45]), "Safe light payload must serialize.")
        try check((try JSONSerialization.jsonObject(with: payload) as? [String: Any])?["brightness_pct"] as? Int == 45, "Service payload must retain brightness.")
        try check(HomeAssistantClient.servicePayload(domain: "lock", service: "unlock", data: ["entity_id": "lock.front_door"]) == nil, "Unsafe services must never serialize.")
    }

    private static func testCinemaSafetyAndSnapshot() throws {
        let device = CinemaDevice(id: "ha:light.cinema", provider: .homeAssistant, providerIdentifier: "light.cinema", displayName: "Cinema", category: .light, capabilities: [.power, .brightness, .color], state: CinemaDeviceState(isOn: true, brightness: 0.5, color: RGBColor(red: 12, green: 34, blue: 56)), selected: true, role: .ambientLight)
        try check(CinemaSafetyPolicy.allowsLiveAudio(for: device), "Color lights are safe for live audio.")
        let snapshot = CinemaSafetyPolicy.snapshot(for: device)
        try check(snapshot.state.color == RGBColor(red: 12, green: 34, blue: 56), "Snapshots must retain a device color.")
        var unsafe = device
        unsafe.category = .restricted
        try check(!CinemaSafetyPolicy.allowsSelection(for: unsafe.category), "Restricted categories cannot be automated.")
    }

    private static func sineWave(frequency: Double, sampleRate: Double, frames: Int) -> [Float] {
        (0 ..< frames).map { frame in Float(sin(2 * .pi * frequency * Double(frame) / sampleRate) * 0.4) }
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw Failure(message: message) }
        return value
    }

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
