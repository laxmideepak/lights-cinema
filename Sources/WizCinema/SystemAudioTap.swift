import AVFoundation
import AudioToolbox
import Darwin
import Foundation

enum SystemAudioTapError: LocalizedError {
    case status(String, OSStatus)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case let .status(operation, status): return "\(operation) failed (Core Audio error \(status))."
        case let .unavailable(message): return message
        }
    }
}

/// A private, unmuted Core Audio process tap. It is deliberately global: the
/// user can watch from any browser/player, including while using headphones.
final class SystemAudioTap {
    typealias SampleHandler = (_ monoSamples: [Float], _ sampleRate: Double) -> Void

    private let sampleHandler: SampleHandler
    private let callbackQueue = DispatchQueue(label: "WizCinema.SystemAudioTap", qos: .userInitiated)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var format: AVAudioFormat?
    private(set) var isRunning = false

    init(sampleHandler: @escaping SampleHandler) {
        self.sampleHandler = sampleHandler
    }

    func start() throws {
        guard !isRunning else { return }

        let excluded = Self.audioProcessObjectID(for: getpid()).map { [$0] } ?? []
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.name = "WizCinema System Audio"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTapID)
        guard tapStatus == noErr else { throw SystemAudioTapError.status("Creating the system-audio tap", tapStatus) }
        tapID = newTapID

        do {
            var streamDescription: AudioStreamBasicDescription = try readProperty(
                objectID: tapID,
                selector: kAudioTapPropertyFormat,
                defaultValue: AudioStreamBasicDescription()
            )
            guard let audioFormat = AVAudioFormat(streamDescription: &streamDescription) else {
                throw SystemAudioTapError.unavailable("The Mac did not provide a readable system-audio format.")
            }
            format = audioFormat

            let outputDevice = try Self.defaultSystemOutputDevice()
            let outputUID: String = try readProperty(
                objectID: outputDevice,
                selector: kAudioDevicePropertyDeviceUID,
                defaultValue: "" as CFString
            ) as String
            guard !outputUID.isEmpty else {
                throw SystemAudioTapError.unavailable("The current audio output has no device identifier.")
            }

            let aggregateUID = "com.local.WizCinema.tap.\(UUID().uuidString)"
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "WizCinema Audio Tap",
                kAudioAggregateDeviceUIDKey: aggregateUID,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString
                ]]
            ]
            var aggregateID = AudioObjectID(kAudioObjectUnknown)
            let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
            guard aggregateStatus == noErr else {
                throw SystemAudioTapError.status("Creating the private audio device", aggregateStatus)
            }
            aggregateDeviceID = aggregateID

            var newIOProc: AudioDeviceIOProcID?
            let procStatus = AudioDeviceCreateIOProcIDWithBlock(&newIOProc, aggregateDeviceID, callbackQueue) { [weak self] _, inputData, _, _, _ in
                self?.consume(inputData)
            }
            guard procStatus == noErr, let newIOProc else {
                throw SystemAudioTapError.status("Starting the audio processing callback", procStatus)
            }
            ioProcID = newIOProc

            let startStatus = AudioDeviceStart(aggregateDeviceID, newIOProc)
            guard startStatus == noErr else {
                throw SystemAudioTapError.status("Starting system-audio capture", startStatus)
            }
            isRunning = true
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            if let ioProcID {
                _ = AudioDeviceStop(aggregateDeviceID, ioProcID)
                _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            }
            ioProcID = nil
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            _ = AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        format = nil
        isRunning = false
    }

    deinit { stop() }

    private func consume(_ inputData: UnsafePointer<AudioBufferList>?) {
        guard
            let inputData,
            let format,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil),
            let channelData = buffer.floatChannelData
        else { return }

        let frameCount = Int(buffer.frameLength)
        let channelCount = max(Int(buffer.format.channelCount), 1)
        guard frameCount > 0 else { return }
        var mono = [Float](repeating: 0, count: frameCount)

        if format.isInterleaved {
            let interleaved = channelData[0]
            for frame in 0 ..< frameCount {
                var total: Float = 0
                let offset = frame * channelCount
                for channel in 0 ..< channelCount { total += interleaved[offset + channel] }
                mono[frame] = total / Float(channelCount)
            }
        } else {
            for frame in 0 ..< frameCount {
                var total: Float = 0
                for channel in 0 ..< channelCount { total += channelData[channel][frame] }
                mono[frame] = total / Float(channelCount)
            }
        }
        sampleHandler(mono, format.sampleRate)
    }

    private static func audioProcessObjectID(for pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var translated = AudioObjectID(kAudioObjectUnknown)
        var valueSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var processID = pid
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &processID,
            &valueSize,
            &translated
        )
        return status == noErr && translated != AudioObjectID(kAudioObjectUnknown) ? translated : nil
    }

    private static func defaultSystemOutputDevice() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else {
            throw SystemAudioTapError.status("Finding the default audio output", status)
        }
        return deviceID
    }

    private func readProperty<T>(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        defaultValue: T
    ) throws -> T {
        try Self.readProperty(objectID: objectID, selector: selector, defaultValue: defaultValue)
    }

    private static func readProperty<T>(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        defaultValue: T
    ) throws -> T {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = defaultValue
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { throw SystemAudioTapError.status("Reading an audio-device property", status) }
        return value
    }
}
