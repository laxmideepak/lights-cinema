import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

enum ScreenSceneSamplerError: LocalizedError {
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "No display was available for movie-scene matching."
        }
    }
}

/// Captures a deliberately low-resolution stream of the main display and
/// reduces each frame to colour, brightness, and cut/motion values. Raw image
/// frames never leave this class and are never written to disk.
final class ScreenSceneSampler: NSObject, SCStreamOutput {
    private let sampleQueue = DispatchQueue(label: "WizCinema.ScreenSceneSampler", qos: .userInitiated)
    private let stateLock = NSLock()
    private let onMetrics: (SceneMetrics) -> Void
    private var previousColor: RGBColor?
    private var stream: SCStream?

    init(onMetrics: @escaping (SceneMetrics) -> Void) {
        self.onMetrics = onMetrics
        super.init()
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainDisplayID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainDisplayID }) ?? content.displays.first else {
            throw ScreenSceneSamplerError.noDisplay
        }

        let thisApp = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: thisApp, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = 192
        configuration.height = 108
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 6)
        configuration.queueDepth = 2
        configuration.capturesAudio = false
        configuration.showsCursor = false

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        stream = newStream
        try await newStream.startCapture()
    }

    func stop() {
        let activeStream = stream
        stream = nil
        stateLock.lock()
        previousColor = nil
        stateLock.unlock()
        guard let activeStream else { return }
        Task { try? await activeStream.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let metrics = summarize(pixelBuffer)
        onMetrics(metrics)
    }

    private func summarize(_ pixelBuffer: CVPixelBuffer) -> SceneMetrics {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return SceneMetrics() }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0 else { return SceneMetrics() }

        let pixels = baseAddress.assumingMemoryBound(to: UInt8.self)
        let xStep = max(width / 24, 1)
        let yStep = max(height / 14, 1)
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var count = 0.0

        for y in stride(from: yStep / 2, to: height, by: yStep) {
            for x in stride(from: xStep / 2, to: width, by: xStep) {
                let offset = y * bytesPerRow + x * 4
                blue += Double(pixels[offset])
                green += Double(pixels[offset + 1])
                red += Double(pixels[offset + 2])
                count += 1
            }
        }
        guard count > 0 else { return SceneMetrics() }

        let color = RGBColor(red: red / count, green: green / count, blue: blue / count)
        let maximum = max(color.red, color.green, color.blue)
        let minimum = min(color.red, color.green, color.blue)
        let saturation = maximum > 0 ? (maximum - minimum) / maximum : 0

        stateLock.lock()
        let motion: Double
        if let previousColor {
            let distance = abs(color.red - previousColor.red) + abs(color.green - previousColor.green) + abs(color.blue - previousColor.blue)
            motion = min(max(distance / 190, 0), 1)
        } else {
            motion = 0
        }
        previousColor = color
        stateLock.unlock()

        return SceneMetrics(
            color: color,
            luminance: color.relativeLuminance,
            saturation: min(max(saturation, 0), 1),
            motion: motion,
            isAvailable: true
        )
    }
}
