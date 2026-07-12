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
        try testExplicitCinemaSessionSafety()
        try testHomeAssistantHTTPClient()
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
            ["entity_id": "media_player.receiver", "state": "playing", "attributes": ["device_class": "receiver", "volume_level": 0.35]],
            ["entity_id": "media_player.tv", "state": "idle", "attributes": ["device_class": "tv"]],
            ["entity_id": "cover.living_room_shade", "state": "open", "attributes": ["device_class": "shade", "current_position": 100]],
            ["entity_id": "cover.garage", "state": "closed", "attributes": ["device_class": "garage"]],
            ["entity_id": "cover.unknown", "state": "closed", "attributes": [:]],
            ["entity_id": "lock.front_door", "state": "locked", "attributes": ["friendly_name": "Front Door"]]
        ]
        let devices = HomeAssistantClient.devices(from: states)
        try check(devices.count == 4, "Unsafe Home Assistant domains and unsafe cover classes must be excluded.")
        let light = try require(devices.first(where: { $0.providerIdentifier == "light.cinema" }), "Safe light must be discovered.")
        try check(light.supportsLiveAmbientSync, "RGB HA light must support live ambient sync.")
        try check(devices.contains(where: { $0.providerIdentifier == "cover.living_room_shade" }), "Window shades must be discoverable.")
        try check(!devices.contains(where: { $0.providerIdentifier == "cover.garage" }), "Garage covers must never be exposed as cinema shades.")
        try check(!devices.contains(where: { $0.providerIdentifier == "cover.unknown" }), "Covers without a safe class must never be guessed safe.")
        let receiver = try require(devices.first(where: { $0.providerIdentifier == "media_player.receiver" }), "A receiver must be discovered.")
        try check(receiver.category == .receiver && CinemaRole.available(for: receiver).contains(.mediaVolume), "Volume-capable receivers must expose the media-volume role.")
        let television = try require(devices.first(where: { $0.providerIdentifier == "media_player.tv" }), "A television must be discovered.")
        try check(television.category == .television && CinemaRole.available(for: television) == [.observeOnly], "TVs without reported volume control must remain observe-only.")
        let payload = try require(HomeAssistantClient.servicePayload(domain: "light", service: "turn_on", data: ["entity_id": "light.cinema", "brightness_pct": 45]), "Safe light payload must serialize.")
        try check((try JSONSerialization.jsonObject(with: payload) as? [String: Any])?["brightness_pct"] as? Int == 45, "Service payload must retain brightness.")
        try check(HomeAssistantClient.servicePayload(domain: "cover", service: "set_cover_position", data: ["entity_id": "cover.living_room_shade", "position": 0]) != nil, "A valid explicit shade position must serialize.")
        try check(HomeAssistantClient.servicePayload(domain: "cover", service: "set_cover_position", data: ["entity_id": "cover.living_room_shade", "position": 101]) == nil, "Out-of-range shade positions must be rejected.")
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

    private static func testExplicitCinemaSessionSafety() throws {
        let speaker = CinemaDevice(id: "ha:media_player.receiver", provider: .homeAssistant, providerIdentifier: "media_player.receiver", displayName: "Receiver", category: .speaker, capabilities: [.volume], state: CinemaDeviceState(), selected: true, role: .mediaVolume)
        try check(CinemaSafetyPolicy.allowsSessionAction(for: speaker), "Selected media players may receive one explicit volume action.")

        let fan = CinemaDevice(id: "ha:fan.cinema", provider: .homeAssistant, providerIdentifier: "fan.cinema", displayName: "Cinema Fan", category: .fan, capabilities: [.speed], state: CinemaDeviceState(), selected: true, role: .fan)
        try check(CinemaSafetyPolicy.allowsSessionAction(for: fan), "Selected fans may receive one explicit speed action.")
        try check(CinemaRole.available(for: .switchDevice) == [.observeOnly], "Generic switches must remain observe-only.")

        let settings = CinemaSessionSettings(mediaVolume: 2, shadePosition: -1, fanSpeed: 130)
        try check(settings.normalizedMediaVolume == 1, "Cinema volume must clamp to a normalized value.")
        try check(settings.normalizedShadePosition == 0 && settings.normalizedFanSpeed == 100, "Cinema percentage settings must clamp safely.")
    }

    private static func testHomeAssistantHTTPClient() throws {
        MockHomeAssistantURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockHomeAssistantURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let states: [[String: Any]] = [
            ["entity_id": "media_player.receiver", "state": "playing", "attributes": ["device_class": "receiver", "volume_level": 0.6]]
        ]
        MockHomeAssistantURLProtocol.handler = { request in
            MockHomeAssistantURLProtocol.requests.append(request)
            MockHomeAssistantURLProtocol.bodies.append(MockHomeAssistantURLProtocol.body(from: request))
            let path = request.url?.path ?? ""
            let body: Data
            switch path {
            case "/api":
                body = Data("{}".utf8)
            case "/api/states":
                body = try! JSONSerialization.data(withJSONObject: states)
            case "/api/services/media_player/volume_set":
                body = Data("[]".utf8)
            default:
                body = Data("{}".utf8)
            }
            let validPaths: Set<String> = ["/api", "/api/states", "/api/services/media_player/volume_set"]
            let response = HTTPURLResponse(url: request.url!, statusCode: validPaths.contains(path) ? 200 : 404, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (response, body)
        }

        try awaitResult {
            guard let client = HomeAssistantClient(urlString: "http://homeassistant.local:8123", token: "test-token", session: session) else {
                throw Failure(message: "Mock Home Assistant client could not initialize.")
            }
            try await client.validateConnection()
            let devices = try await client.fetchDevices()
            var receiver = try require(devices.first, "Mock receiver must be discovered.")
            receiver.role = .mediaVolume
            try await client.applyCinemaSession(receiver, settings: CinemaSessionSettings(mediaVolume: 0.4))
        }

        let requests = MockHomeAssistantURLProtocol.requests
        let paths = requests.map { $0.url?.path }
        try check(paths == ["/api", "/api/states", "/api/services/media_player/volume_set"], "Home Assistant API requests must use the documented paths; got \(paths).")
        try check(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-token" }, "Home Assistant requests must authenticate with the supplied bearer token.")
        guard let payload = MockHomeAssistantURLProtocol.bodies.last ?? nil,
              let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw Failure(message: "Mock media volume payload was missing.")
        }
        try check(object["entity_id"] as? String == "media_player.receiver", "Explicit media action must target the chosen entity.")
        try check(object["volume_level"] as? Double == 0.4, "Explicit media action must use the selected normalized volume.")
        MockHomeAssistantURLProtocol.reset()
    }

    private static func awaitResult<T>(_ operation: @escaping () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<T, Error>?
        Task {
            do {
                result = .success(try await operation())
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 5) == .success, let result else {
            throw Failure(message: "Timed out while testing Home Assistant HTTP requests.")
        }
        return try result.get()
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

private final class MockHomeAssistantURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
    static var requests = [URLRequest]()
    static var bodies = [Data?]()

    static func reset() {
        handler = nil
        requests.removeAll()
        bodies.removeAll()
    }

    static func body(from request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
