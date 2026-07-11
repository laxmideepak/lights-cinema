import Foundation
import Darwin

final class WiZService: @unchecked Sendable {
    private let worker = DispatchQueue(label: "WizCinema.WiZService", qos: .userInitiated)

    func discover() async -> [WiZBulb] {
        await withCheckedContinuation { continuation in
            worker.async {
                continuation.resume(returning: self.discoverSynchronously())
            }
        }
    }

    func inspect(ipAddress: String, knownMAC: String? = nil) async -> WiZBulb? {
        await withCheckedContinuation { continuation in
            worker.async {
                continuation.resume(returning: self.inspectSynchronously(ipAddress: ipAddress, knownMAC: knownMAC))
            }
        }
    }

    func send(target: LightTarget, to bulb: WiZBulb) {
        guard let message = WiZProtocol.setPilot(color: bulb.supportsColor ? target.color : nil, brightness: target.brightness) else { return }
        worker.async {
            self.send(message, to: bulb.ipAddress)
        }
    }

    func restore(_ state: PilotState, to bulb: WiZBulb) {
        guard !state.restoreParameters.isEmpty, let message = WiZProtocol.setPilot(parameters: state.restoreParameters) else { return }
        worker.async {
            self.send(message, to: bulb.ipAddress)
        }
    }

    private func discoverSynchronously() -> [WiZBulb] {
        let descriptor = makeSocket(receiveTimeoutMilliseconds: 160, enableBroadcast: true)
        guard descriptor >= 0 else { return [] }
        defer { close(descriptor) }

        var results = [String: WiZBulb]()
        let deadline = Date().addingTimeInterval(4)
        var nextBroadcast = Date.distantPast
        while Date() < deadline {
            if Date() >= nextBroadcast {
                send(WiZProtocol.discoveryMessage, descriptor: descriptor, to: "255.255.255.255")
                nextBroadcast = Date().addingTimeInterval(0.75)
            }
            guard let response = receive(descriptor: descriptor), let mac = WiZProtocol.discoveryMAC(from: response.data) else {
                continue
            }
            results[mac] = WiZBulb(ipAddress: response.ipAddress, macAddress: mac, supportsColor: true)
        }

        return results.values.sorted { $0.ipAddress.localizedStandardCompare($1.ipAddress) == .orderedAscending }
    }

    private func inspectSynchronously(ipAddress: String, knownMAC: String?) -> WiZBulb? {
        let systemData = request(method: "getSystemConfig", ipAddress: ipAddress)
        let modelData = request(method: "getModelConfig", ipAddress: ipAddress)
        let pilotData = request(method: "getPilot", ipAddress: ipAddress)

        let system = systemData.map(WiZProtocol.systemInfo(from:))
        let mac = knownMAC ?? systemData.flatMap(WiZProtocol.discoveryMAC(from:))
        guard systemData != nil || modelData != nil || pilotData != nil || knownMAC != nil else { return nil }
        let module = system?.module
        return WiZBulb(
            ipAddress: ipAddress,
            macAddress: mac,
            moduleName: module,
            firmwareVersion: system?.firmware,
            updateIntervalMilliseconds: system?.interval,
            supportsColor: WiZProtocol.supportsColor(module: module, modelConfig: modelData),
            pilot: pilotData.flatMap(WiZProtocol.pilotState(from:)),
            selected: true
        )
    }

    private func request(method: String, ipAddress: String) -> Data? {
        guard let message = WiZProtocol.request(method) else { return nil }
        let descriptor = makeSocket(receiveTimeoutMilliseconds: 850, enableBroadcast: false)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        send(message, descriptor: descriptor, to: ipAddress)
        return receive(descriptor: descriptor)?.data
    }

    private func send(_ data: Data, to ipAddress: String) {
        let descriptor = makeSocket(receiveTimeoutMilliseconds: 0, enableBroadcast: false)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        send(data, descriptor: descriptor, to: ipAddress)
    }

    @discardableResult
    private func send(_ data: Data, descriptor: Int32, to ipAddress: String) -> ssize_t {
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = WiZProtocol.port.bigEndian
        guard inet_pton(AF_INET, ipAddress, &destination.sin_addr) == 1 else { return -1 }

        return data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &destination) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.sendto(descriptor, bytes.baseAddress, bytes.count, 0, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func receive(descriptor: Int32) -> (data: Data, ipAddress: String)? {
        var storage = sockaddr_storage()
        var addressLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        var buffer = [UInt8](repeating: 0, count: 4_096)
        let received = withUnsafeMutablePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                Darwin.recvfrom(descriptor, &buffer, buffer.count, 0, address, &addressLength)
            }
        }
        guard received > 0 else { return nil }
        guard storage.ss_family == sa_family_t(AF_INET) else { return nil }

        let ipAddress = withUnsafePointer(to: &storage) { pointer -> String? in
            pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { address in
                var sourceAddress = address.pointee.sin_addr
                var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &sourceAddress, &text, socklen_t(text.count)) != nil else { return nil }
                return String(cString: text)
            }
        }
        guard let ipAddress else { return nil }
        return (Data(buffer.prefix(Int(received))), ipAddress)
    }

    private func makeSocket(receiveTimeoutMilliseconds: Int, enableBroadcast: Bool) -> Int32 {
        let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { return -1 }

        var reuseAddress: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuseAddress, socklen_t(MemoryLayout<Int32>.size))
        if enableBroadcast {
            var broadcast: Int32 = 1
            _ = setsockopt(descriptor, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int32>.size))
        }
        if receiveTimeoutMilliseconds > 0 {
            var timeout = timeval(
                tv_sec: receiveTimeoutMilliseconds / 1_000,
                tv_usec: __darwin_suseconds_t((receiveTimeoutMilliseconds % 1_000) * 1_000)
            )
            _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        }
        return descriptor
    }
}
