import Combine
import AppKit
import Darwin
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var bulbs = [WiZBulb]()
    @Published var palette: LightPalette = .cinema
    @Published var minimumBrightness = 8.0
    @Published var maximumBrightness = 65.0
    @Published var sensitivity = 1.0
    @Published var responsiveness = 0.5
    @Published var metrics = AudioMetrics()
    @Published var cinemaDepth = 72.0
    @Published var isDiscovering = false
    @Published var isRunning = false
    @Published var isStarting = false
    @Published var status = "Ready to find lights on your Wi‑Fi."
    @Published var errorMessage: String?
    @Published var manualIP = ""

    private let service = WiZService()
    private let analyzer = AudioAnalyzer()
    private var audioTap: SystemAudioTap?
    private var tickTimer: Timer?
    private var previousTarget: LightTarget?
    private var lastSentTarget: LightTarget?
    private var savedStates = [String: PilotState]()
    var selectedCount: Int {
        bulbs.filter(\.selected).count
    }

    var settings: LightingSettings {
        LightingSettings(
            palette: palette,
            minimumBrightness: minimumBrightness,
            maximumBrightness: maximumBrightness,
            sensitivity: sensitivity,
            responsiveness: responsiveness,
            cinemaDepth: cinemaDepth / 100
        )
    }

    func discover() {
        guard !isDiscovering else { return }
        isDiscovering = true
        errorMessage = nil
        status = "Looking for WiZ lights…"
        let selectedIDs = Set(bulbs.filter(\.selected).map(\.id))

        Task {
            let found = await service.discover()
            var inspected = [WiZBulb]()
            for bulb in found {
                var profile = await service.inspect(ipAddress: bulb.ipAddress, knownMAC: bulb.macAddress) ?? bulb
                profile.selected = selectedIDs.isEmpty || selectedIDs.contains(profile.id)
                inspected.append(profile)
            }
            bulbs = inspected
            isDiscovering = false
            if bulbs.isEmpty {
                status = "No WiZ lights found. Check Wi‑Fi and Allow local communication."
            } else {
                status = "Found \(bulbs.count) WiZ \(bulbs.count == 1 ? "light" : "lights")."
            }
        }
    }

    func addManualIP() {
        let address = manualIP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return }
        errorMessage = nil
        status = "Checking \(address)…"
        Task {
            guard var bulb = await service.inspect(ipAddress: address) else {
                errorMessage = "\(address) did not answer as a WiZ light."
                status = "Manual connection failed."
                return
            }
            if let index = bulbs.firstIndex(where: { $0.id == bulb.id || $0.ipAddress == bulb.ipAddress }) {
                bulb.selected = bulbs[index].selected
                bulbs[index] = bulb
            } else {
                bulbs.append(bulb)
            }
            manualIP = ""
            status = "Added \(bulb.displayName)."
        }
    }

    func start() {
        guard !isRunning, !isStarting else { return }
        guard selectedCount > 0 else {
            errorMessage = "Select at least one WiZ light before starting."
            return
        }

        isStarting = true
        errorMessage = nil
        status = "Saving your current light settings…"
        Task {
            savedStates.removeAll()
            for index in bulbs.indices where bulbs[index].selected {
                if let refreshed = await service.inspect(ipAddress: bulbs[index].ipAddress, knownMAC: bulbs[index].macAddress) {
                    bulbs[index] = refreshed
                }
                if let state = bulbs[index].pilot { savedStates[bulbs[index].id] = state }
            }

            analyzer.reset()
            previousTarget = nil
            lastSentTarget = nil
            let tap = SystemAudioTap { [weak self] samples, sampleRate in
                guard let self else { return }
                let newMetrics = self.analyzer.analyze(samples: samples, sampleRate: sampleRate)
                DispatchQueue.main.async {
                    self.metrics = newMetrics
                }
            }

            do {
                try tap.start()
                audioTap = tap
                isRunning = true
                isStarting = false
                status = "Listening to the soundtrack and shaping \(selectedCount) ambient light\(selectedCount == 1 ? "" : "s") with cinematic motion."
                tickTimer?.invalidate()
                tickTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        self?.sendLatestLightingTarget()
                    }
                }
            } catch {
                isStarting = false
                errorMessage = error.localizedDescription
                status = "System-audio permission or capture could not start."
            }
        }
    }

    func stop(restore: Bool = true) {
        tickTimer?.invalidate()
        tickTimer = nil
        audioTap?.stop()
        audioTap = nil
        isRunning = false
        isStarting = false
        previousTarget = nil
        lastSentTarget = nil
        metrics = AudioMetrics()

        if restore {
            let restorePairs = bulbs.compactMap { bulb -> (WiZBulb, PilotState)? in
                guard let state = savedStates[bulb.id] else { return nil }
                return (bulb, state)
            }
            for (bulb, state) in restorePairs { service.restore(state, to: bulb) }
            status = restorePairs.isEmpty ? "Stopped." : "Stopped and restoring the previous light settings."
        } else {
            status = "Stopped."
        }
        savedStates.removeAll()
    }

    private func sendLatestLightingTarget() {
        guard isRunning else { return }
        let target = LightingMapper.target(metrics: metrics, settings: settings, previous: previousTarget)
        previousTarget = target
        guard LightingMapper.meaningfullyDifferent(target, from: lastSentTarget) else { return }
        lastSentTarget = target
        for bulb in bulbs where bulb.selected { service.send(target: target, to: bulb) }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.035, green: 0.05, blue: 0.11), Color(red: 0.08, green: 0.055, blue: 0.17), Color(red: 0.025, green: 0.09, blue: 0.16)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    header
                    HStack(alignment: .top, spacing: 16) {
                        lightsPanel
                        controlPanel
                    }
                    footer
                }
                .padding(22)
                .frame(maxWidth: 980)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(minWidth: 850, idealWidth: 940, minHeight: 790)
        .alert("WizCinema", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .frame(width: 58, height: 58)
            VStack(alignment: .leading, spacing: 2) {
                Text("WizCinema").font(.title.bold())
                Text("Immersive soundtrack ambience for your room.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Label(model.isRunning ? "Cinema live" : "Ready", systemImage: model.isRunning ? "record.circle.fill" : "circle")
                    .font(.headline)
                    .foregroundStyle(model.isRunning ? .green : .secondary)
                Text("\(model.metrics.mood.rawValue) soundtrack mood")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var lightsPanel: some View {
        GroupBox("Your WiZ lights") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(model.status).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        model.discover()
                    } label: {
                        Label(model.isDiscovering ? "Searching…" : "Discover", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .disabled(model.isDiscovering || model.isRunning)
                }

                if model.bulbs.isEmpty {
                    ContentUnavailableView(
                        "No lights yet",
                        systemImage: "lightbulb.slash",
                        description: Text("Discover lights on this Wi‑Fi, or add a WiZ light by IP address.")
                    )
                    .frame(height: 190)
                } else {
                    VStack(spacing: 8) {
                        ForEach($model.bulbs) { $bulb in
                            Toggle(isOn: $bulb.selected) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(bulb.displayName).fontWeight(.medium)
                                    Text(bulb.detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .disabled(model.isRunning)
                        }
                    }
                    .frame(minHeight: 190, alignment: .top)
                }

                Divider()
                HStack {
                    TextField("WiZ IP address (e.g. 10.0.0.78)", text: $model.manualIP)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.isRunning)
                    Button("Add") { model.addManualIP() }
                        .disabled(model.manualIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isRunning)
                }
            }
            .frame(width: 390, alignment: .leading)
            .padding(4)
        }
    }

    private var controlPanel: some View {
        GroupBox("Cinema engine") {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Palette", selection: $model.palette) {
                    ForEach(LightPalette.allCases) { palette in Text(palette.rawValue).tag(palette) }
                }
                .disabled(model.isRunning)

                sliderRow("Minimum brightness", value: $model.minimumBrightness, range: 1 ... 60, suffix: "%")
                sliderRow("Maximum brightness", value: $model.maximumBrightness, range: 15 ... 100, suffix: "%")
                sliderRow("Sensitivity", value: $model.sensitivity, range: 0.4 ... 2.5, suffix: "×")
                sliderRow("Responsiveness", value: $model.responsiveness, range: 0 ... 1, suffix: "")

                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Label("Audio-only cinematic intelligence", systemImage: "waveform.and.mic")
                        .font(.subheadline.weight(.semibold))
                    Text("Local mood inference follows dialogue, suspense, ambience, and action — without seeing or recording your screen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    sliderRow("Cinema depth", value: $model.cinemaDepth, range: 20 ... 100, suffix: "%")
                    HStack {
                        Label("Mood: \(model.metrics.mood.rawValue)", systemImage: moodSymbol(model.metrics.mood))
                        Spacer()
                        Label("Event: \(model.metrics.event.rawValue)", systemImage: "waveform.path.ecg")
                    }
                        .font(.caption)
                        .foregroundStyle(.cyan)
                    Text("Inference confidence \(Int((model.metrics.confidence * 100).rounded()))% — a local signal-quality score, not a claim to know the movie frame.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Divider()
                meter("Energy", value: model.metrics.level, color: .white)
                meter("Bass", value: model.metrics.bass, color: .red)
                meter("Middle", value: model.metrics.mid, color: .purple)
                meter("Treble", value: model.metrics.treble, color: .cyan)

                Spacer(minLength: 2)
                Button {
                    model.isRunning ? model.stop() : model.start()
                } label: {
                    Label(
                        model.isStarting ? "Starting…" : (model.isRunning ? "Stop and restore lights" : "Start cinema sync"),
                        systemImage: model.isRunning ? "stop.fill" : "play.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isStarting || (!model.isRunning && model.selectedCount == 0))
            }
            .frame(width: 420, alignment: .leading)
            .padding(4)
        }
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.shield").foregroundStyle(.secondary)
            Text("WizCinema analyzes soundtrack features only on this Mac. It never sees, records, saves, or uploads your screen or audio. First use asks only for System Audio Recording permission.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                Spacer()
                Text("\(Int(value.wrappedValue.rounded()))\(suffix)").monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.caption)
            Slider(value: value, in: range)
                .disabled(model.isRunning)
        }
    }

    private func meter(_ label: String, value: Double, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).frame(width: 48, alignment: .leading)
            ProgressView(value: min(max(value, 0), 1))
                .tint(color.opacity(value > 0 ? 1 : 0.35))
            Text("\(Int((min(max(value, 0), 1) * 100).rounded()))")
                .font(.caption.monospacedDigit())
                .frame(width: 28, alignment: .trailing)
        }
    }

    private func moodSymbol(_ mood: CinemaMood) -> String {
        switch mood {
        case .ambience: return "sparkles"
        case .dialogue: return "quote.bubble.fill"
        case .suspense: return "moon.stars.fill"
        case .action: return "bolt.fill"
        }
    }

}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationWillTerminate(_ notification: Notification) {
        model?.stop()
    }
}

struct WizCinemaApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onAppear { appDelegate.model = model }
        }
        .windowStyle(.automatic)
    }
}

@main
enum WizCinemaEntry {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            do {
                try SelfTests.run()
                print("WizCinema self-tests passed.")
            } catch {
                fputs("WizCinema self-test failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        if CommandLine.arguments.contains("--diagnose-wiz") {
            runWiZDiagnostic()
            return
        }
        if CommandLine.arguments.contains("--audio-probe") {
            runAudioProbe()
            return
        }
        if CommandLine.arguments.contains("--sync-probe") {
            runSyncProbe()
            return
        }
        WizCinemaApp.main()
    }

    private static func runWiZDiagnostic() {
        let resultBox = DiagnosticResultBox()
        let completion = DispatchSemaphore(value: 0)
        Task.detached {
            let service = WiZService()
            let discovered = await service.discover()
            var inspected = [WiZBulb]()
            for bulb in discovered {
                inspected.append(await service.inspect(ipAddress: bulb.ipAddress, knownMAC: bulb.macAddress) ?? bulb)
            }
            resultBox.set(inspected)
            completion.signal()
        }
        guard completion.wait(timeout: .now() + 12) == .success else {
            fputs("WiZ discovery diagnostic timed out.\n", stderr)
            exit(2)
        }
        let bulbs = resultBox.value()
        for bulb in bulbs {
            print("\(bulb.displayName) | \(bulb.detail) | \(bulb.macAddress ?? "no MAC")")
        }
        print("Discovered \(bulbs.count) WiZ light(s).")
    }

    /// A no-light-control validation aid. Run this while film audio is playing
    /// to confirm that the macOS permission and Core Audio tap are working.
    private static func runAudioProbe() {
        let analyzer = AudioAnalyzer()
        let resultBox = AudioProbeResultBox()
        let tap = SystemAudioTap { samples, sampleRate in
            resultBox.record(analyzer.analyze(samples: samples, sampleRate: sampleRate))
        }
        do {
            try tap.start()
            print("Listening to system audio for five seconds. No WiZ lights will change.")
            Thread.sleep(forTimeInterval: 5)
            tap.stop()
            guard let metrics = resultBox.value else {
                fputs("No system-audio samples arrived. Check System Audio Recording permission.\n", stderr)
                exit(2)
            }
            print(String(format: "Audio received — energy %.0f%%, bass %.0f%%, mid %.0f%%, treble %.0f%%.", metrics.level * 100, metrics.bass * 100, metrics.mid * 100, metrics.treble * 100))
        } catch {
            fputs("Audio probe could not start: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    /// Exercises the entire local pipeline: system audio -> analyzer -> WiZ
    /// UDP commands. It always restores every light state it successfully read.
    private static func runSyncProbe() {
        let lights = discoverInspectableBulbs()
        let activeLights = lights.filter { $0.pilot != nil }
        guard !activeLights.isEmpty else {
            fputs("No WiZ light with a readable pre-session state was found; not changing any lights.\n", stderr)
            exit(2)
        }

        let service = WiZService()
        let analyzer = AudioAnalyzer()
        let metricsBox = LatestAudioMetricsBox()
        let tap = SystemAudioTap { samples, sampleRate in
            metricsBox.record(analyzer.analyze(samples: samples, sampleRate: sampleRate))
        }
        let savedStates = Dictionary(uniqueKeysWithValues: activeLights.compactMap { bulb in
            bulb.pilot.map { (bulb.id, $0) }
        })
        let stopBox = StopSignalBox()
        let stopSignals = installStopSignalHandlers(stopBox)

        defer {
            tap.stop()
            for bulb in activeLights {
                if let state = savedStates[bulb.id] { service.restore(state, to: bulb) }
            }
            // WiZ transport is UDP and asynchronous; give the final restore
            // packets a moment to leave the local serial queue before exit.
            Thread.sleep(forTimeInterval: 0.8)
            stopSignals.forEach { $0.cancel() }
            for signalNumber in [SIGINT, SIGTERM, SIGHUP] { Darwin.signal(signalNumber, SIG_DFL) }
        }

        do {
            try tap.start()
            print("Syncing \(activeLights.count) light(s) to Mac audio for five seconds; every light will then be restored.")
            let settings = LightingSettings()
            let deadline = Date().addingTimeInterval(5)
            var previous: LightTarget?
            var lastSent: LightTarget?
            while Date() < deadline && !stopBox.isRequested {
                let metrics = metricsBox.value
                let target = LightingMapper.target(metrics: metrics, settings: settings, previous: previous)
                previous = target
                if LightingMapper.meaningfullyDifferent(target, from: lastSent) {
                    for bulb in activeLights { service.send(target: target, to: bulb) }
                    lastSent = target
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            print(stopBox.isRequested
                ? "Sync probe interrupted; restore commands are being sent for \(savedStates.count) light(s)."
                : "Sync probe complete; restore commands are being sent for \(savedStates.count) light(s).")
        } catch {
            fputs("Sync probe could not start: \(error.localizedDescription)\n", stderr)
        }
    }

    private static func installStopSignalHandlers(_ stopBox: StopSignalBox) -> [DispatchSourceSignal] {
        [SIGINT, SIGTERM, SIGHUP].map { signalNumber in
            Darwin.signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: DispatchQueue.global(qos: .userInitiated))
            source.setEventHandler { stopBox.requestStop() }
            source.resume()
            return source
        }
    }

    private static func discoverInspectableBulbs() -> [WiZBulb] {
        let resultBox = DiagnosticResultBox()
        let completion = DispatchSemaphore(value: 0)
        Task.detached {
            let service = WiZService()
            let discovered = await service.discover()
            var inspected = [WiZBulb]()
            for bulb in discovered {
                inspected.append(await service.inspect(ipAddress: bulb.ipAddress, knownMAC: bulb.macAddress) ?? bulb)
            }
            resultBox.set(inspected)
            completion.signal()
        }
        guard completion.wait(timeout: .now() + 12) == .success else {
            fputs("WiZ discovery timed out; not changing any lights.\n", stderr)
            exit(2)
        }
        return resultBox.value()
    }

    private final class DiagnosticResultBox: @unchecked Sendable {
        private let queue = DispatchQueue(label: "WizCinema.diagnostic-result")
        private var stored = [WiZBulb]()

        func set(_ bulbs: [WiZBulb]) {
            queue.sync { stored = bulbs }
        }

        func value() -> [WiZBulb] {
            queue.sync { stored }
        }
    }

    private final class AudioProbeResultBox: @unchecked Sendable {
        private let queue = DispatchQueue(label: "WizCinema.audio-probe")
        private var strongest: AudioMetrics?

        func record(_ metrics: AudioMetrics) {
            queue.async {
                guard let strongest = self.strongest else {
                    self.strongest = metrics
                    return
                }
                if metrics.level > strongest.level { self.strongest = metrics }
            }
        }

        var value: AudioMetrics? {
            queue.sync { strongest }
        }
    }

    private final class LatestAudioMetricsBox: @unchecked Sendable {
        private let queue = DispatchQueue(label: "WizCinema.live-metrics")
        private var latest = AudioMetrics()

        func record(_ metrics: AudioMetrics) {
            queue.async { self.latest = metrics }
        }

        var value: AudioMetrics {
            queue.sync { latest }
        }
    }

    private final class StopSignalBox: @unchecked Sendable {
        private let queue = DispatchQueue(label: "WizCinema.stop-signal")
        private var requested = false

        func requestStop() {
            queue.async { self.requested = true }
        }

        var isRequested: Bool {
            queue.sync { requested }
        }
    }
}
