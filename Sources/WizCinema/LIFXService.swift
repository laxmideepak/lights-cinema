import Darwin
import Foundation

final class LIFXService: @unchecked Sendable {
    private let worker = DispatchQueue(label: "WizCinema.LIFXService", qos: .userInitiated)

    func discover() async -> [LIFXLight] {
        await withCheckedContinuation { continuation in
            worker.async { continuation.resume(returning: self.discoverSynchronously()) }
        }
    }

    func inspect(_ light: LIFXLight) async -> LIFXLight {
        await withCheckedContinuation { continuation in
            worker.async { continuation.resume(returning: self.inspectSynchronously(light)) }
        }
    }

    func send(target: LightTarget, to light: LIFXLight) {
        worker.async {
            self.send(LIFXProtocol.setPower(target: light.target, level: UInt16.max), to: light.ipAddress, port: light.port)
            self.send(LIFXProtocol.setColor(target: light.target, color: target.color, brightness: target.brightness), to: light.ipAddress, port: light.port)
        }
    }

    func restore(_ state: LIFXState, to light: LIFXLight) {
        worker.async {
            let color = Self.rgb(hue: state.hue, saturation: state.saturation)
            let brightness = Int((Double(state.brightness) / Double(UInt16.max) * 100).rounded())
            self.send(LIFXProtocol.setColor(target: light.target, color: color, brightness: brightness, durationMilliseconds: 180), to: light.ipAddress, port: light.port)
            self.send(LIFXProtocol.setPower(target: light.target, level: state.power, durationMilliseconds: 180), to: light.ipAddress, port: light.port)
        }
    }

    private func discoverSynchronously() -> [LIFXLight] {
        let socket = makeSocket(receiveTimeoutMilliseconds: 130, broadcast: true)
        guard socket >= 0 else { return [] }
        defer { close(socket) }
        var lights = [String: LIFXLight]()
        let deadline = Date().addingTimeInterval(2.2)
        var nextBroadcast = Date.distantPast
        while Date() < deadline {
            if Date() >= nextBroadcast {
                send(LIFXProtocol.getService(), descriptor: socket, to: "255.255.255.255", port: LIFXProtocol.port)
                nextBroadcast = Date().addingTimeInterval(0.55)
            }
            guard let response = receive(descriptor: socket), let service = LIFXProtocol.service(from: response.data) else { continue }
            let serial = LIFXProtocol.serial(from: service.target)
            lights[serial] = LIFXLight(id: serial, ipAddress: response.ipAddress, port: service.port, target: service.target, label: "", state: nil, selected: true)
        }
        return lights.values.sorted { $0.ipAddress.localizedStandardCompare($1.ipAddress) == .orderedAscending }
    }

    private func inspectSynchronously(_ light: LIFXLight) -> LIFXLight {
        let socket = makeSocket(receiveTimeoutMilliseconds: 650, broadcast: false)
        guard socket >= 0 else { return light }
        defer { close(socket) }
        send(LIFXProtocol.getColor(target: light.target), descriptor: socket, to: light.ipAddress, port: light.port)
        while let response = receive(descriptor: socket) {
            guard let snapshot = LIFXProtocol.lightState(from: response.data) else { continue }
            var result = light
            result.state = snapshot.state
            result.label = snapshot.label
            return result
        }
        return light
    }

    private func send(_ data: Data, to ipAddress: String, port: UInt16) {
        let socket = makeSocket(receiveTimeoutMilliseconds: 0, broadcast: false)
        guard socket >= 0 else { return }
        defer { close(socket) }
        send(data, descriptor: socket, to: ipAddress, port: port)
    }

    @discardableResult
    private func send(_ data: Data, descriptor: Int32, to ipAddress: String, port: UInt16) -> ssize_t {
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ipAddress, &destination.sin_addr) == 1 else { return -1 }
        return data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &destination) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    Darwin.sendto(descriptor, bytes.baseAddress, bytes.count, 0, address, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func receive(descriptor: Int32) -> (data: Data, ipAddress: String)? {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        var buffer = [UInt8](repeating: 0, count: 1_024)
        let count = withUnsafeMutablePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                Darwin.recvfrom(descriptor, &buffer, buffer.count, 0, address, &length)
            }
        }
        guard count > 0, storage.ss_family == sa_family_t(AF_INET) else { return nil }
        let ipAddress = withUnsafePointer(to: &storage) { pointer -> String? in
            pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { address in
                var source = address.pointee.sin_addr
                var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &source, &text, socklen_t(text.count)) != nil else { return nil }
                return String(cString: text)
            }
        }
        guard let ipAddress else { return nil }
        return (Data(buffer.prefix(Int(count))), ipAddress)
    }

    private func makeSocket(receiveTimeoutMilliseconds: Int, broadcast: Bool) -> Int32 {
        let socket = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socket >= 0 else { return -1 }
        var reuse: Int32 = 1
        _ = setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        if broadcast {
            var enabled: Int32 = 1
            _ = setsockopt(socket, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout<Int32>.size))
        }
        if receiveTimeoutMilliseconds > 0 {
            var timeout = timeval(tv_sec: receiveTimeoutMilliseconds / 1_000, tv_usec: __darwin_suseconds_t((receiveTimeoutMilliseconds % 1_000) * 1_000))
            _ = setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        }
        return socket
    }

    private static func rgb(hue: UInt16, saturation: UInt16) -> RGBColor {
        let h = Double(hue) / Double(UInt16.max) * 6
        let saturation = Double(saturation) / Double(UInt16.max)
        let x = 1 - abs((h.truncatingRemainder(dividingBy: 2)) - 1)
        let (red, green, blue): (Double, Double, Double)
        switch h {
        case 0 ..< 1: (red, green, blue) = (1, x, 0)
        case 1 ..< 2: (red, green, blue) = (x, 1, 0)
        case 2 ..< 3: (red, green, blue) = (0, 1, x)
        case 3 ..< 4: (red, green, blue) = (0, x, 1)
        case 4 ..< 5: (red, green, blue) = (x, 0, 1)
        default: (red, green, blue) = (1, 0, x)
        }
        return RGBColor(red: (red * saturation + 1 - saturation) * 255, green: (green * saturation + 1 - saturation) * 255, blue: (blue * saturation + 1 - saturation) * 255)
    }
}
