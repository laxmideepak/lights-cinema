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
    @Published var homeAssistantURL = UserDefaults.standard.string(forKey: "homeAssistantURL") ?? ""
    @Published var homeAssistantToken = ""
    @Published var hasSavedHomeAssistantToken = false
    @Published var homeAssistantDevices = [CinemaDevice]()
    @Published var isConnectingHomeAssistant = false
    @Published var homeAssistantStatus = "Connect a local Home Assistant hub to add supported mixed-brand devices."
    @Published var cinemaVolume = 25.0
    @Published var cinemaShadePosition = 0.0
    @Published var cinemaFanSpeed = 30.0
    @Published var isApplyingCinemaSession = false

    private let service = WiZService()
    private let analyzer = AudioAnalyzer()
    private var audioTap: SystemAudioTap?
    private var tickTimer: Timer?
    private var previousTarget: LightTarget?
    private var lastSentTarget: LightTarget?
    private var savedStates = [String: PilotState]()
    private var homeAssistantClient: HomeAssistantClient?
    private var homeAssistantSnapshots = [CinemaDeviceSnapshot]()

    init() {
        if let url = HomeAssistantClient.normalizedURL(homeAssistantURL),
           (try? HomeAssistantTokenStore.read(for: url)) != nil {
            hasSavedHomeAssistantToken = true
        }
    }

    var selectedCount: Int {
        bulbs.filter(\.selected).count + homeAssistantDevices.filter { $0.selected && $0.supportsLiveAmbientSync }.count
    }

    var settings: LightingSettings {
        LightingSettings(
            palette: palette,
            minimumBrightness: minimumBrightness,
            maximumBrightness: maximumBrightness,
            sensitivity: sensitivity,
            responsiveness: responsiveness
        )
    }

    private var cinemaSessionSettings: CinemaSessionSettings {
        CinemaSessionSettings(
            mediaVolume: cinemaVolume / 100,
            shadePosition: cinemaShadePosition,
            fanSpeed: cinemaFanSpeed
        )
    }

    var selectedSessionDeviceCount: Int {
        homeAssistantDevices.filter { $0.selected && CinemaSafetyPolicy.allowsSessionAction(for: $0) }.count
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

    func connectHomeAssistant() {
        guard !isConnectingHomeAssistant else { return }
        guard let baseURL = HomeAssistantClient.normalizedURL(homeAssistantURL) else {
            errorMessage = "Enter a valid Home Assistant URL, for example http://homeassistant.local:8123."
            return
        }
        let enteredToken = homeAssistantToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let token: String?
        if !enteredToken.isEmpty {
            token = enteredToken
        } else {
            token = try? HomeAssistantTokenStore.read(for: baseURL)
        }
        guard let token, let client = HomeAssistantClient(urlString: baseURL.absoluteString, token: token) else {
            errorMessage = "Enter a Home Assistant long-lived access token. The token is stored only in this Mac’s Keychain."
            return
        }

        isConnectingHomeAssistant = true
        homeAssistantStatus = "Connecting to Home Assistant…"
        Task {
            do {
                try await client.validateConnection()
                let devices = try await client.fetchDevices()
                if !enteredToken.isEmpty { try HomeAssistantTokenStore.save(enteredToken, for: baseURL) }
                UserDefaults.standard.set(baseURL.absoluteString, forKey: "homeAssistantURL")
                homeAssistantURL = baseURL.absoluteString
                homeAssistantToken = ""
                hasSavedHomeAssistantToken = true
                homeAssistantClient = client
                homeAssistantDevices = devices
                homeAssistantStatus = devices.isEmpty
                    ? "Connected, but no cinema-safe Home Assistant devices were found."
                    : "Connected. Found \(devices.count) compatible Home Assistant device\(devices.count == 1 ? "" : "s")."
            } catch {
                homeAssistantStatus = "Home Assistant connection failed."
                errorMessage = error.localizedDescription
            }
            isConnectingHomeAssistant = false
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
            homeAssistantSnapshots.removeAll()
            for index in bulbs.indices where bulbs[index].selected {
                if let refreshed = await service.inspect(ipAddress: bulbs[index].ipAddress, knownMAC: bulbs[index].macAddress) {
                    bulbs[index] = refreshed
                }
                if let state = bulbs[index].pilot { savedStates[bulbs[index].id] = state }
            }
            homeAssistantSnapshots = homeAssistantDevices
                .filter { $0.selected && CinemaSafetyPolicy.allowsSelection(for: $0.category) }
                .map(CinemaSafetyPolicy.snapshot(for:))

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
                status = "Listening to Mac audio and syncing \(selectedCount) ambient light\(selectedCount == 1 ? "" : "s")."
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

    func applyCinemaSession() {
        guard !isRunning, !isApplyingCinemaSession else { return }
        guard let client = homeAssistantClient else {
            errorMessage = "Connect Home Assistant before applying cinema session settings."
            return
        }
        let devices = homeAssistantDevices.filter { $0.selected && CinemaSafetyPolicy.allowsSessionAction(for: $0) }
        guard !devices.isEmpty else {
            errorMessage = "Select a speaker, shade, or fan role before applying a cinema session."
            return
        }

        isApplyingCinemaSession = true
        homeAssistantStatus = "Applying explicit cinema settings…"
        let settings = cinemaSessionSettings
        Task {
            var failures = [String]()
            var applied = 0
            for device in devices {
                do {
                    try await client.applyCinemaSession(device, settings: settings)
                    applied += 1
                } catch {
                    failures.append(device.displayName)
                }
            }
            isApplyingCinemaSession = false
            if failures.isEmpty {
                homeAssistantStatus = "Applied cinema settings to \(applied) device\(applied == 1 ? "" : "s")."
            } else {
                homeAssistantStatus = "Applied cinema settings to \(applied) device\(applied == 1 ? "" : "s"); \(failures.count) failed."
                errorMessage = "Could not apply settings to: \(failures.joined(separator: ", "))."
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
            let snapshots = homeAssistantSnapshots
            let client = homeAssistantClient
            if let client, !snapshots.isEmpty {
                Task {
                    for snapshot in snapshots { try? await client.restore(snapshot) }
                }
            }
            status = restorePairs.isEmpty ? "Stopped." : "Stopped and restoring the previous light settings."
        } else {
            status = "Stopped."
        }
        savedStates.removeAll()
        homeAssistantSnapshots.removeAll()
    }

    private func sendLatestLightingTarget() {
        guard isRunning else { return }
        let target = LightingMapper.target(metrics: metrics, settings: settings, previous: previousTarget)
        previousTarget = target
        guard LightingMapper.meaningfullyDifferent(target, from: lastSentTarget) else { return }
        lastSentTarget = target
        for bulb in bulbs where bulb.selected { service.send(target: target, to: bulb) }
        if let client = homeAssistantClient {
            let devices = homeAssistantDevices.filter { $0.selected && $0.supportsLiveAmbientSync }
            Task {
                for device in devices { try? await client.sendLiveLighting(target, to: device) }
            }
        }
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
            homeAssistantPanel
            footer
        }
        .padding(20)
        .frame(minWidth: 780, idealWidth: 860, minHeight: 760)
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

    private var homeAssistantPanel: some View {
        GroupBox("Home Assistant — mixed-brand devices") {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.homeAssistantStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("http://homeassistant.local:8123", text: $model.homeAssistantURL)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.isRunning || model.isConnectingHomeAssistant)
                    SecureField(model.hasSavedHomeAssistantToken ? "New token (optional)" : "Long-lived access token", text: $model.homeAssistantToken)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.isRunning || model.isConnectingHomeAssistant)
                    Button(model.isConnectingHomeAssistant ? "Connecting…" : "Connect") {
                        model.connectHomeAssistant()
                    }
                    .disabled(model.isRunning || model.isConnectingHomeAssistant || model.homeAssistantURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if !model.homeAssistantDevices.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach($model.homeAssistantDevices) { $device in
                                HStack(spacing: 10) {
                                    Toggle("", isOn: $device.selected)
                                        .labelsHidden()
                                        .toggleStyle(.checkbox)
                                        .disabled(model.isRunning || !CinemaSafetyPolicy.allowsSelection(for: device.category))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(device.displayName).fontWeight(.medium)
                                        Text(homeAssistantDetail(device))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Picker("Role", selection: $device.role) {
                                        ForEach(CinemaRole.available(for: device)) { role in Text(role.rawValue).tag(role) }
                                    }
                                    .labelsHidden()
                                    .frame(width: 135)
                                    .disabled(model.isRunning || !CinemaSafetyPolicy.allowsSelection(for: device.category))
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 155)
                    cinemaSessionControls
                }

                Text("Live soundtrack changes are limited to selected color-capable lights. Cinema settings are only sent once after you press Apply. Locks, security, water, cooking, cameras, garages, gates, doors, and HVAC are not automated.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(4)
        }
    }

    @ViewBuilder
    private var cinemaSessionControls: some View {
        let selected = model.homeAssistantDevices.filter { $0.selected && CinemaSafetyPolicy.allowsSessionAction(for: $0) }
        if !selected.isEmpty {
            let hasMedia = selected.contains { $0.role == .mediaVolume }
            let hasShades = selected.contains { $0.role == .shades }
            let hasFan = selected.contains { $0.role == .fan }

            Divider()
            VStack(alignment: .leading, spacing: 7) {
                Text("Explicit cinema session").font(.caption.weight(.semibold))
                if hasMedia {
                    sessionSlider("Media volume", value: $model.cinemaVolume, range: 0 ... 100, suffix: "%")
                }
                if hasShades {
                    sessionSlider("Shade position", value: $model.cinemaShadePosition, range: 0 ... 100, suffix: "% open")
                }
                if hasFan {
                    sessionSlider("Fan speed", value: $model.cinemaFanSpeed, range: 0 ... 100, suffix: "%")
                }
                Button {
                    model.applyCinemaSession()
                } label: {
                    Label(model.isApplyingCinemaSession ? "Applying…" : "Apply selected cinema settings", systemImage: "theatermasks.fill")
                }
                .disabled(model.isRunning || model.isApplyingCinemaSession)
            }
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

    private func sessionSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.caption).frame(width: 92, alignment: .leading)
            Slider(value: value, in: range)
            Text("\(Int(value.wrappedValue.rounded()))\(suffix)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)
        }
    }

    private func homeAssistantDetail(_ device: CinemaDevice) -> String {
        let capabilities = device.capabilities.map(\.rawValue).sorted().joined(separator: ", ")
        let live = device.supportsLiveAmbientSync ? "Live ambience" : "Session/observe"
        return "\(device.category.rawValue.capitalized) · \(live) · \(capabilities)"
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
