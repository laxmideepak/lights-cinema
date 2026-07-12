import Foundation

enum SelfTests {
    static func run() throws {
        try testDiscoveryRequiresARealResultMAC()
        try testSetPilotClampsBrightnessAndColor()
        try testPilotRestorePreservesSceneBeforeColor()
        try testAnalyzerSeparatesLowAndHighTones()
        try testMapperUsesMinimumBrightnessInSilenceAndSmooths()
        try testAudioMoodDrivesCinematicMotion()
    }

    private static func testDiscoveryRequiresARealResultMAC() throws {
        let echo = Data("{\"method\":\"registration\",\"params\":{\"phoneMac\":\"AAAAAAAAAAAA\"}}".utf8)
        let bulb = Data("{\"method\":\"registration\",\"result\":{\"mac\":\"cc4085a89152\",\"success\":true}}".utf8)
        try check(WiZProtocol.discoveryMAC(from: echo) == nil, "Discovery must reject a broadcast echo.")
        try check(WiZProtocol.discoveryMAC(from: bulb) == "cc4085a89152", "Discovery must read a bulb MAC.")
    }

    private static func testSetPilotClampsBrightnessAndColor() throws {
        guard let payload = WiZProtocol.setPilot(color: RGBColor(red: 300, green: -8, blue: 27.8), brightness: 132),
              let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let parameters = json["params"] as? [String: Any] else { throw Failure(message: "Could not decode setPilot.") }
        try check(parameters["dimming"] as? Int == 100, "Brightness must clamp.")
        try check(parameters["r"] as? Int == 255 && parameters["g"] as? Int == 0 && parameters["b"] as? Int == 28, "RGB must clamp and round.")
    }

    private static func testPilotRestorePreservesSceneBeforeColor() throws {
        let state = PilotState(state: true, dimming: 44, red: 1, green: 2, blue: 3, temperature: 2700, sceneID: 11)
        let parameters = state.restoreParameters
        try check(parameters["sceneId"] as? Int == 11 && parameters["r"] == nil, "Scene restore must not be overridden by RGB.")
    }

    private static func testAnalyzerSeparatesLowAndHighTones() throws {
        let analyzer = AudioAnalyzer()
        let low = analyzer.analyze(samples: sineWave(frequency: 100, frames: 16_384), sampleRate: 48_000)
        try check(low.bass > low.treble, "100 Hz must bias bass.")
        analyzer.reset()
        let high = analyzer.analyze(samples: sineWave(frequency: 5_000, frames: 16_384), sampleRate: 48_000)
        try check(high.treble > high.bass && !high.isSilent, "5 kHz must bias treble.")
    }

    private static func testMapperUsesMinimumBrightnessInSilenceAndSmooths() throws {
        let settings = LightingSettings(palette: .ocean, minimumBrightness: 8, maximumBrightness: 65, sensitivity: 1, responsiveness: 0.5)
        let previous = LightTarget(color: .black, brightness: 8)
        let silence = LightingMapper.target(metrics: AudioMetrics(), settings: settings, previous: previous)
        try check(silence.brightness == 8, "Silence must use the minimum brightness.")
        let loud = AudioMetrics(level: 1, bass: 0.8, mid: 0.15, treble: 0.05, dynamics: 0.8, mood: .action, beat: true, isSilent: false)
        let target = LightingMapper.target(metrics: loud, settings: settings, previous: silence)
        try check(target.brightness > silence.brightness && target.brightness <= 65, "Mapped brightness must stay in range.")
    }

    private static func testAudioMoodDrivesCinematicMotion() throws {
        let settings = LightingSettings(palette: .warm, minimumBrightness: 8, maximumBrightness: 65, sensitivity: 1, responsiveness: 1, cinemaDepth: 1)
        let action = AudioMetrics(level: 0.9, bass: 0.66, mid: 0.2, treble: 0.14, dynamics: 0.9, mood: .action, beat: true, isSilent: false)
        let actionTarget = LightingMapper.target(metrics: action, settings: settings, previous: LightTarget(color: .black, brightness: 8))
        try check(actionTarget.brightness > 8 && actionTarget.brightness < 30, "Action must be energetic but smooth.")
    }

    private static func sineWave(frequency: Double, frames: Int) -> [Float] {
        (0 ..< frames).map { Float(sin(2 * .pi * frequency * Double($0) / 48_000) * 0.4) }
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
    }

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
