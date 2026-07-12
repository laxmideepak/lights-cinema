import Foundation

final class AudioAnalyzer {
    private var lowPass: Double = 0
    private var midPass: Double = 0
    private var noiseFloor: Double = 0.008
    private var runningPeak: Double = 0.08
    private var slowLevel: Double = 0
    private var slowRMS: Double = 0
    private var previousSpectrum = [Double]()
    private var fluxFloor: Double = 0.02
    private var elapsedSeconds: TimeInterval = 0
    private var lastBeatTime: TimeInterval = -.infinity
    private var moodEvidence = [Double](repeating: 0.25, count: 4)
    private var stableMood: CinemaMood = .ambience
    private var pendingMood: CinemaMood?
    private var pendingMoodSeconds: Double = 0
    private var risingFrames = 0
    private var fallingFrames = 0
    private var heldEvent: CinemaEvent = .quiet
    private var eventHoldUntil: TimeInterval = 0

    private let lock = NSLock()

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        lowPass = 0
        midPass = 0
        noiseFloor = 0.008
        runningPeak = 0.08
        slowLevel = 0
        slowRMS = 0
        previousSpectrum.removeAll()
        fluxFloor = 0.02
        elapsedSeconds = 0
        lastBeatTime = -.infinity
        moodEvidence = [Double](repeating: 0.25, count: 4)
        stableMood = .ambience
        pendingMood = nil
        pendingMoodSeconds = 0
        risingFrames = 0
        fallingFrames = 0
        heldEvent = .quiet
        eventHoldUntil = 0
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

        let frameDuration = Double(samples.count) / sampleRate
        elapsedSeconds += frameDuration
        if slowRMS == 0 { slowRMS = rms }
        let energySlope = (rms - slowRMS) / max(slowRMS, 0.015)
        let rmsAlpha = 1 - exp(-frameDuration / 1.2)
        slowRMS += (rms - slowRMS) * rmsAlpha
        let levelDynamics = min(max(energySlope * 0.55, 0), 1)
        let spectrum = spectralProfile(samples: samples, sampleRate: sampleRate)
        let flux: Double
        if previousSpectrum.count == spectrum.count {
            let rise = zip(spectrum, previousSpectrum).reduce(0.0) { $0 + max($1.0 - $1.1, 0) }
            flux = rise / max(spectrum.reduce(0, +), 0.0001)
        } else {
            flux = 0
        }
        previousSpectrum = spectrum
        fluxFloor = fluxFloor * 0.94 + flux * 0.06
        let transient = min(max((flux - fluxFloor) / max(fluxFloor * 3, 0.025), 0), 1)
        let dynamics = max(levelDynamics, transient)
        let now = elapsedSeconds
        let beatThreshold = max(0.14, slowLevel * 1.55)
        let beat = !silent && normalized > beatThreshold && now - lastBeatTime > 0.28
        if beat { lastBeatTime = now }
        slowLevel = slowLevel * 0.965 + normalized * 0.035

        let bandTotal = max(bass + mid + treble, 0.0001)
        let bassShare = min(max(bass / bandTotal, 0), 1)
        let midShare = min(max(mid / bandTotal, 0), 1)
        let trebleShare = min(max(treble / bandTotal, 0), 1)
        let rawMoodEvidence = [
            0.12 + 0.68 * bassShare + 0.58 * dynamics + 0.20 * normalized,
            0.15 + 0.82 * midShare + 0.30 * (1 - dynamics) + 0.14 * (normalized > 0.08 && normalized < 0.7 ? 1 : 0),
            0.16 + 0.34 * trebleShare + 0.34 * (1 - normalized) + 0.24 * (1 - dynamics),
            0.20 + 0.32 * (1 - dynamics) + 0.22 * normalized + 0.16 * (1 - max(bassShare, midShare, trebleShare))
        ]
        // A 650 ms evidence window and a 550 ms handoff prevent the room from
        // reacting to every syllable while still following a scene transition.
        let evidenceAlpha = 1 - exp(-frameDuration / 0.65)
        for index in moodEvidence.indices {
            moodEvidence[index] += (rawMoodEvidence[index] - moodEvidence[index]) * evidenceAlpha
        }
        let ranked = moodEvidence.enumerated().sorted { $0.element > $1.element }
        let candidateMood = Self.mood(at: ranked[0].offset)
        let candidateScore = ranked[0].element
        let runnerUpScore = ranked[1].element
        let clarity = min(max((candidateScore - runnerUpScore) / max(candidateScore, 0.0001), 0), 1)
        if candidateMood == stableMood {
            pendingMood = nil
            pendingMoodSeconds = 0
        } else if candidateScore > moodEvidence[Self.index(of: stableMood)] * 1.12, clarity > 0.12 {
            if pendingMood == candidateMood {
                pendingMoodSeconds += frameDuration
            } else {
                pendingMood = candidateMood
                pendingMoodSeconds = frameDuration
            }
            if pendingMoodSeconds >= 0.55 {
                stableMood = candidateMood
                pendingMood = nil
                pendingMoodSeconds = 0
            }
        } else {
            pendingMood = nil
            pendingMoodSeconds = 0
        }
        let signalQuality = min(max((rms - noiseFloor) / max(runningPeak * 0.38, 0.012), 0), 1)
        let stability = candidateMood == stableMood ? 1 : max(0, 1 - pendingMoodSeconds / 0.55)
        let confidence = silent
            ? 0
            : min(0.96, 0.10 + 0.43 * clarity + 0.27 * signalQuality + 0.20 * stability)

        risingFrames = energySlope > 0.08 ? risingFrames + 1 : max(risingFrames - 1, 0)
        fallingFrames = energySlope < -0.10 ? fallingFrames + 1 : max(fallingFrames - 1, 0)
        let candidateEvent: CinemaEvent
        if silent {
            candidateEvent = .quiet
        } else if transient > 0.68 && normalized > 0.28 {
            candidateEvent = .stinger
        } else if beat && transient > 0.18 {
            candidateEvent = .pulse
        } else if risingFrames >= 4 && normalized > 0.18 && dynamics > 0.10 {
            candidateEvent = .crescendo
        } else if stableMood == .dialogue && confidence > 0.48 && dynamics < 0.25 {
            candidateEvent = .dialogueLine
        } else if fallingFrames >= 3 {
            candidateEvent = .release
        } else {
            candidateEvent = .settle
        }
        let event = heldEvent(for: candidateEvent, silent: silent, now: now)
        return AudioMetrics(
            level: normalized,
            bass: bassShare,
            mid: midShare,
            treble: trebleShare,
            dynamics: dynamics,
            transient: transient,
            mood: stableMood,
            event: event,
            confidence: confidence,
            beat: beat,
            isSilent: silent
        )
    }

    private func heldEvent(for candidate: CinemaEvent, silent: Bool, now: TimeInterval) -> CinemaEvent {
        guard !silent else {
            heldEvent = .quiet
            eventHoldUntil = now
            return .quiet
        }
        let hold: TimeInterval
        switch candidate {
        case .stinger: hold = 0.42
        case .pulse: hold = 0.24
        case .crescendo: hold = 0.34
        case .release: hold = 0.2
        case .dialogueLine, .settle, .quiet: hold = 0
        }
        if hold > 0 {
            heldEvent = candidate
            eventHoldUntil = now + hold
            return candidate
        }
        return now < eventHoldUntil ? heldEvent : candidate
    }

    private static func mood(at index: Int) -> CinemaMood {
        switch index {
        case 0: return .action
        case 1: return .dialogue
        case 2: return .suspense
        default: return .ambience
        }
    }

    private static func index(of mood: CinemaMood) -> Int {
        switch mood {
        case .action: return 0
        case .dialogue: return 1
        case .suspense: return 2
        case .ambience: return 3
        }
    }

    /// A compact Goertzel filter bank gives robust onset information without
    /// retaining audio. It is a standard spectral-analysis technique for a
    /// small fixed set of cinematic frequency bands.
    private func spectralProfile(samples: [Float], sampleRate: Double) -> [Double] {
        let frame = Array(samples.suffix(1_024))
        guard frame.count >= 128 else { return [] }
        let frequencies = [55.0, 90, 160, 280, 500, 900, 1_600, 2_800, 5_000, 8_000]
        return frequencies.map { frequency in
            let omega = 2 * Double.pi * frequency / sampleRate
            let coefficient = 2 * cos(omega)
            var q1 = 0.0
            var q2 = 0.0
            for (index, raw) in frame.enumerated() {
                let window = 0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(frame.count - 1))
                let q0 = Double(raw) * window + coefficient * q1 - q2
                q2 = q1
                q1 = q0
            }
            return max(q1 * q1 + q2 * q2 - coefficient * q1 * q2, 0)
        }
    }
}

enum LightingMapper {
    static func target(
        metrics: AudioMetrics,
        settings: LightingSettings,
        previous: LightTarget? = nil
    ) -> LightTarget {
        let minimum = min(max(settings.minimumBrightness, 1), 100)
        let maximum = min(max(settings.maximumBrightness, minimum), 100)
        let adjustedLevel = min(max(metrics.level * settings.sensitivity, 0), 1)
        let perceptualLevel = pow(adjustedLevel, 0.7)
        var desiredBrightness = minimum + (maximum - minimum) * perceptualLevel
        let depth = min(max(settings.cinemaDepth, 0), 1)
        switch metrics.mood {
        case .dialogue:
            desiredBrightness = minimum + (desiredBrightness - minimum) * 0.58
        case .suspense:
            desiredBrightness = minimum + (desiredBrightness - minimum) * 0.36
        case .action:
            desiredBrightness = minimum + (desiredBrightness - minimum) * (0.78 + 0.22 * metrics.dynamics)
            if metrics.beat { desiredBrightness = min(maximum, desiredBrightness + 4 + 4 * depth) }
        case .ambience:
            desiredBrightness = minimum + (desiredBrightness - minimum) * 0.75
        }
        switch metrics.event {
        case .stinger:
            desiredBrightness += 12 * depth
        case .pulse:
            desiredBrightness += 6 * depth
        case .crescendo:
            desiredBrightness += 8 * depth
        case .dialogueLine:
            desiredBrightness = minimum + (desiredBrightness - minimum) * 0.82
        case .release:
            desiredBrightness -= 5 * depth
        case .settle, .quiet:
            break
        }
        desiredBrightness = min(max(desiredBrightness, minimum), maximum)
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

        if metrics.isSilent, let previous {
            color = previous.color
        }
        let moodAccent: RGBColor
        switch metrics.mood {
        case .dialogue: moodAccent = RGBColor(red: 255, green: 158, blue: 82)
        case .suspense: moodAccent = RGBColor(red: 55, green: 88, blue: 210)
        case .action: moodAccent = RGBColor(red: 255, green: 48, blue: 62)
        case .ambience: moodAccent = RGBColor(red: 82, green: 190, blue: 235)
        }
        color = color.blended(with: moodAccent, amount: 0.11 + 0.19 * depth)
        let eventAccent: RGBColor?
        switch metrics.event {
        case .stinger: eventAccent = RGBColor(red: 255, green: 232, blue: 195)
        case .pulse: eventAccent = RGBColor(red: 255, green: 78, blue: 104)
        case .crescendo: eventAccent = RGBColor(red: 255, green: 166, blue: 88)
        case .dialogueLine: eventAccent = RGBColor(red: 255, green: 194, blue: 128)
        case .release: eventAccent = RGBColor(red: 96, green: 144, blue: 255)
        case .settle, .quiet: eventAccent = nil
        }
        if let eventAccent {
            let accentAmount: Double
            switch metrics.event {
            case .stinger: accentAmount = 0.24 * depth
            case .pulse: accentAmount = 0.14 * depth
            case .crescendo: accentAmount = 0.16 * depth
            case .dialogueLine, .release: accentAmount = 0.08 * depth
            case .settle, .quiet: accentAmount = 0
            }
            color = color.blended(with: eventAccent, amount: accentAmount)
        }
        let desired = LightTarget(color: color.clamped(), brightness: Int(desiredBrightness.rounded()))
        guard let previous else { return desired }

        let response = min(max(settings.responsiveness, 0), 1)
        // Soundtrack mood changes are intentionally filtered. This is the
        // theatre-like layer: dialogue and suspense drift, while action is
        // allowed only a controlled increase in motion.
        let moodMotion: Double
        switch metrics.mood {
        case .dialogue: moodMotion = 0.62
        case .suspense: moodMotion = 0.5
        case .action: moodMotion = 1.15 + 0.15 * metrics.dynamics
        case .ambience: moodMotion = 0.8
        }
        let brightnessFactor = min((0.04 + response * 0.18) * moodMotion, 0.26)
        let colorFactor = min((0.03 + response * 0.14) * moodMotion, 0.21)
        let eventMotion: Double
        switch metrics.event {
        case .stinger: eventMotion = 1.85
        case .pulse: eventMotion = 1.35
        case .crescendo: eventMotion = 1.25
        case .dialogueLine: eventMotion = 0.68
        case .release: eventMotion = 0.76
        case .settle, .quiet: eventMotion = 1
        }
        return LightTarget(
            color: previous.color.blended(with: desired.color, amount: min(colorFactor * eventMotion, 0.31)),
            brightness: Int((Double(previous.brightness) + (Double(desired.brightness - previous.brightness) * min(brightnessFactor * eventMotion, 0.42))).rounded())
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
