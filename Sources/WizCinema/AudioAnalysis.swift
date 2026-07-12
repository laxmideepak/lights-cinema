import Foundation

final class AudioAnalyzer {
    private var lowPass: Double = 0
    private var midPass: Double = 0
    private var noiseFloor: Double = 0.008
    private var runningPeak: Double = 0.08
    private var slowLevel: Double = 0
    private var lastBeatTime: TimeInterval = -.infinity

    private let lock = NSLock()

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        lowPass = 0
        midPass = 0
        noiseFloor = 0.008
        runningPeak = 0.08
        slowLevel = 0
        lastBeatTime = -.infinity
    }

    func analyze(samples: [Float], sampleRate: Double) -> AudioMetrics {
        lock.lock()
        defer { lock.unlock() }

        guard !samples.isEmpty, sampleRate > 0 else { return AudioMetrics() }

        let bassAlpha = 1 - exp(-2 * .pi * 180 / sampleRate)
        let midAlpha = 1 - exp(-2 * .pi * 2_000 / sampleRate)
        var totalSquared = 0.0
        var bassSquared = 0.0
        var midSquared = 0.0
        var trebleSquared = 0.0

        for rawSample in samples {
            let sample = Double(rawSample)
            lowPass += bassAlpha * (sample - lowPass)
            midPass += midAlpha * (sample - midPass)
            let bass = lowPass
            let mid = midPass - lowPass
            let treble = sample - midPass
            totalSquared += sample * sample
            bassSquared += bass * bass
            midSquared += mid * mid
            trebleSquared += treble * treble
        }

        let divisor = Double(samples.count)
        let rms = sqrt(totalSquared / divisor)
        let bass = sqrt(bassSquared / divisor)
        let mid = sqrt(midSquared / divisor)
        let treble = sqrt(trebleSquared / divisor)

        // The floor follows quiet sections slowly; the peak decays slowly enough
        // to avoid a trailer or explosion making the rest of a film look dim.
        if rms < noiseFloor * 1.8 {
            noiseFloor = noiseFloor * 0.995 + rms * 0.005
        }
        runningPeak = max(rms, runningPeak * 0.998)
        let usableRange = max(runningPeak - noiseFloor, 0.015)
        let normalized = min(max((rms - noiseFloor) / usableRange, 0), 1)
        let silent = rms < max(noiseFloor * 1.25, 0.003)

        let now = Date.timeIntervalSinceReferenceDate
        let beatThreshold = max(0.14, slowLevel * 1.55)
        let beat = !silent && normalized > beatThreshold && now - lastBeatTime > 0.28
        if beat { lastBeatTime = now }
        slowLevel = slowLevel * 0.965 + normalized * 0.035

        let bandTotal = max(bass + mid + treble, 0.0001)
        return AudioMetrics(
            level: normalized,
            bass: min(max(bass / bandTotal, 0), 1),
            mid: min(max(mid / bandTotal, 0), 1),
            treble: min(max(treble / bandTotal, 0), 1),
            beat: beat,
            isSilent: silent
        )
    }
}

enum LightingMapper {
    static func target(
        metrics: AudioMetrics,
        settings: LightingSettings,
        scene: SceneMetrics? = nil,
        previous: LightTarget? = nil
    ) -> LightTarget {
        let minimum = min(max(settings.minimumBrightness, 1), 100)
        let maximum = min(max(settings.maximumBrightness, minimum), 100)
        let adjustedLevel = min(max(metrics.level * settings.sensitivity, 0), 1)
        let perceptualLevel = pow(adjustedLevel, 0.7)
        var desiredBrightness = minimum + (maximum - minimum) * perceptualLevel
        if metrics.beat && !metrics.isSilent {
            desiredBrightness = min(maximum, desiredBrightness + 7)
        }
        if metrics.isSilent { desiredBrightness = minimum }

        let anchors = settings.palette.anchors
        let weightTotal = max(metrics.bass + metrics.mid + metrics.treble, 0.0001)
        let bassWeight = metrics.bass / weightTotal
        let midWeight = metrics.mid / weightTotal
        let trebleWeight = metrics.treble / weightTotal
        var color = RGBColor(
            red: anchors.bass.red * bassWeight + anchors.mid.red * midWeight + anchors.treble.red * trebleWeight,
            green: anchors.bass.green * bassWeight + anchors.mid.green * midWeight + anchors.treble.green * trebleWeight,
            blue: anchors.bass.blue * bassWeight + anchors.mid.blue * midWeight + anchors.treble.blue * trebleWeight
        )

        if metrics.isSilent, scene?.isAvailable != true, let previous {
            color = previous.color
        }

        if let scene, scene.isAvailable {
            let influence = min(max(settings.sceneInfluence, 0), 1)
            // Saturated movie frames take the lead. Low-saturation frames keep
            // a little audio palette colour, so a grey dialogue scene does not
            // make the room feel lifeless.
            let colorWeight = influence * (0.35 + 0.65 * min(max(scene.saturation, 0), 1))
            color = color.blended(with: scene.color, amount: colorWeight)

            let visualBrightness = minimum + (maximum - minimum) * pow(min(max(scene.luminance, 0), 1), 0.82)
            desiredBrightness = desiredBrightness * (1 - 0.62 * influence) + visualBrightness * (0.62 * influence)
            if metrics.beat && !metrics.isSilent {
                desiredBrightness = min(maximum, desiredBrightness + 4)
            }
        }
        let desired = LightTarget(color: color.clamped(), brightness: Int(desiredBrightness.rounded()))
        guard let previous else { return desired }

        let response = min(max(settings.responsiveness, 0), 1)
        // A theatre-like ambience should glide between shots. These bounded
        // filters avoid strobing even when the film cuts quickly.
        let motionBoost = scene?.isAvailable == true ? 0.85 + min(max(scene?.motion ?? 0, 0), 1) * 0.15 : 1
        let brightnessFactor = (0.05 + response * 0.22) * motionBoost
        let colorFactor = (0.035 + response * 0.18) * motionBoost
        return LightTarget(
            color: previous.color.blended(with: desired.color, amount: colorFactor),
            brightness: Int((Double(previous.brightness) + (Double(desired.brightness - previous.brightness) * brightnessFactor)).rounded())
        )
    }

    static func meaningfullyDifferent(_ new: LightTarget, from old: LightTarget?) -> Bool {
        guard let old else { return true }
        let colorDifference = abs(new.color.red - old.color.red)
            + abs(new.color.green - old.color.green)
            + abs(new.color.blue - old.color.blue)
        return abs(new.brightness - old.brightness) >= 2 || colorDifference >= 9
    }
}
