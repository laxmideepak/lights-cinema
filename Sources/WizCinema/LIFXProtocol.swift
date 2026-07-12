import Foundation

enum LIFXProtocol {
    static let port: UInt16 = 56_700
    private static let headerSize = 36

    struct Service: Equatable, Sendable {
        var target: Data
        var port: UInt16
    }

    static func getService() -> Data {
        packet(type: 2, tagged: true)
    }

    static func getColor(target: Data) -> Data {
        packet(type: 101, target: target)
    }

    static func setColor(target: Data, color: RGBColor, brightness: Int, durationMilliseconds: UInt32 = 90) -> Data {
        let (hue, saturation) = hsb(from: color)
        let level = UInt16((min(max(brightness, 0), 100) * 65_535) / 100)
        var payload = [UInt8(0)]
        append(hue, to: &payload)
        append(saturation, to: &payload)
        append(level, to: &payload)
        append(UInt16(3_500), to: &payload)
        append(durationMilliseconds, to: &payload)
        return packet(type: 102, target: target, payload: payload)
    }

    static func setPower(target: Data, level: UInt16, durationMilliseconds: UInt32 = 90) -> Data {
        var payload = [UInt8]()
        append(level, to: &payload)
        append(durationMilliseconds, to: &payload)
        return packet(type: 117, target: target, payload: payload)
    }

    static func service(from data: Data) -> Service? {
        guard messageType(in: data) == 3, data.count >= headerSize + 5, data[headerSize] == 1 else { return nil }
        guard let port = readUInt32(data, at: headerSize + 1), port <= UInt32(UInt16.max) else { return nil }
        return Service(target: Data(data[8 ..< 16]), port: UInt16(port))
    }

    static func lightState(from data: Data) -> (state: LIFXState, label: String)? {
        guard messageType(in: data) == 107, data.count >= headerSize + 52,
              let hue = readUInt16(data, at: headerSize),
              let saturation = readUInt16(data, at: headerSize + 2),
              let brightness = readUInt16(data, at: headerSize + 4),
              let kelvin = readUInt16(data, at: headerSize + 6),
              let power = readUInt16(data, at: headerSize + 10) else { return nil }
        let labelBytes = data[(headerSize + 12) ..< (headerSize + 44)]
        let label = String(bytes: labelBytes.prefix { $0 != 0 }, encoding: .utf8) ?? ""
        return (LIFXState(hue: hue, saturation: saturation, brightness: brightness, kelvin: kelvin, power: power), label)
    }

    static func serial(from target: Data) -> String {
        target.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    private static func packet(type: UInt16, target: Data = Data(repeating: 0, count: 8), tagged: Bool = false, payload: [UInt8] = []) -> Data {
        let size = headerSize + payload.count
        var bytes = [UInt8](repeating: 0, count: headerSize)
        bytes[0] = UInt8(size & 0xFF)
        bytes[1] = UInt8((size >> 8) & 0xFF)
        // Protocol 1024, addressable frame, and tagged broadcasts where needed.
        let frame: UInt16 = 0x1400 | (tagged ? 0x2000 : 0)
        bytes[2] = UInt8(frame & 0xFF)
        bytes[3] = UInt8((frame >> 8) & 0xFF)
        for (index, value) in target.prefix(8).enumerated() { bytes[8 + index] = value }
        bytes[32] = UInt8(type & 0xFF)
        bytes[33] = UInt8((type >> 8) & 0xFF)
        bytes.append(contentsOf: payload)
        return Data(bytes)
    }

    private static func messageType(in data: Data) -> UInt16? {
        readUInt16(data, at: 32)
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16? {
        guard data.count >= offset + 2 else { return nil }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard data.count >= offset + 4 else { return nil }
        return UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }

    private static func append(_ value: UInt16, to bytes: inout [UInt8]) {
        bytes.append(UInt8(value & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
    }

    private static func append(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8(value & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8((value >> 24) & 0xFF))
    }

    private static func hsb(from color: RGBColor) -> (UInt16, UInt16) {
        let c = color.clamped()
        let red = c.red / 255
        let green = c.green / 255
        let blue = c.blue / 255
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum
        guard delta > 0.000_01 else { return (0, 0) }
        let degrees: Double
        if maximum == red {
            degrees = 60 * ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        } else if maximum == green {
            degrees = 60 * ((blue - red) / delta + 2)
        } else {
            degrees = 60 * ((red - green) / delta + 4)
        }
        let hue = (degrees < 0 ? degrees + 360 : degrees) / 360
        return (UInt16((hue * 65_535).rounded()), UInt16(((delta / maximum) * 65_535).rounded()))
    }
}
