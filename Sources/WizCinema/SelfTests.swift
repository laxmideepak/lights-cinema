import Foundation

enum SelfTests {
    static func run() throws {
        try testDiscoveryRequiresARealResultMAC()
        try testSetPilotClampsBrightnessAndColor()
        try testPilotRestorePreservesSceneBeforeColor()
        try testAnalyzerSeparatesLowAndHighTones()
        try testMapperUsesMinimumBrightnessInSilenceAndSmooths()
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

    private static func sineWave(frequency: Double, sampleRate: Double, frames: Int) -> [Float] {
        (0 ..< frames).map { frame in Float(sin(2 * .pi * frequency * Double(frame) / sampleRate) * 0.4) }
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
    }

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
