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

    var selectedCount: Int { bulbs.filter(\.selected).count }

    var settings: LightingSettings {
        LightingSettings(
            palette: palette,
            minimumBrightness: minimumBrightness,
            maximumBrightness: maximumBrightness,
            sensitivity: sensitivity,
            responsiveness: responsiveness
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
                status = "Listening to Mac audio and syncing \(selectedCount) light\(selectedCount == 1 ? "" : "s")."
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
        VStack(spacing: 18) {
            header
            HStack(alignment: .top, spacing: 16) {
                lightsPanel
                controlPanel
            }
            footer
        }
        .padding(20)
        .frame(minWidth: 780, idealWidth: 860, minHeight: 570)
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
        HStack(spacing: 12) {
            Image(systemName: model.isRunning ? "waveform.circle.fill" : "sparkles")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(model.isRunning ? Color.green : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("WizCinema").font(.title2.bold())
                Text("Movie sound, gently reflected in your WiZ lights.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(model.isRunning ? "Live" : "Idle", systemImage: model.isRunning ? "record.circle.fill" : "circle")
                .foregroundStyle(model.isRunning ? .green : .secondary)
        }
    }

    private var lightsPanel: some View {
        GroupBox("WiZ lights") {
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
            .frame(width: 370, alignment: .leading)
            .padding(4)
        }
    }

    private var controlPanel: some View {
        GroupBox("Sound response") {
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
            .frame(width: 390, alignment: .leading)
            .padding(4)
        }
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.shield").foregroundStyle(.secondary)
            Text("First run asks for System Audio Recording. WizCinema analyzes sound only on this Mac; it does not record or upload audio. In WiZ, keep Settings → Security → Allow local communication enabled.")
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
}
