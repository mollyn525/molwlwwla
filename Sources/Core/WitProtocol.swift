import Foundation

public enum LabError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let s) = self { return s }; return nil }
}
public enum WitProtocol {
    // Vendor UUIDs end in 9A34FB, not Bluetooth's standard 9B34FB base.
    // Short forms such as FFE5 address a different service in CoreBluetooth.
    public static let service = "0000ffe5-0000-1000-8000-00805f9a34fb"
    public static let notify = "0000ffe4-0000-1000-8000-00805f9a34fb"
    public static let write = "0000ffe9-0000-1000-8000-00805f9a34fb"
    public static let profile = "wt9011dcl-ios-independent-v1"
    public static func read(_ register: Int) throws -> Data {
        guard [0x51,0x3a,0x2e,0x03,0x01,0x05,0x1f,0x23,0x24,0x63,0x72,0x96].contains(register) else { throw LabError.invalid("不支持的寄存器") }
        return Data([0xff,0xaa,0x27,UInt8(register),0])
    }
    public static func signed16(_ b: [UInt8], _ offset: Int) -> Int { Int(Int16(bitPattern: UInt16(b[offset]) | UInt16(b[offset+1]) << 8)) }
    public static func hex(_ b: Data) -> String { b.map { String(format: "%02X", $0) }.joined() }
    public static func unhex(_ text: String) throws -> Data {
        guard text.count % 2 == 0 else { throw LabError.invalid("奇数长度十六进制") }
        var output = Data(); var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<end], radix: 16) else { throw LabError.invalid("十六进制格式错误") }
            output.append(byte); index = end
        }; return output
    }
}
public struct WitFrame {
    public let bytes: Data, register: Int, words: [Int]
    public init(_ bytes: Data) {
        precondition(bytes.count == 20)
        self.bytes = bytes; let b = Array(bytes)
        register = b[1] == 0x61 ? -1 : Int(b[2]) | Int(b[3]) << 8
        let offset = register == -1 ? 2 : 4
        words = (0..<(register == -1 ? 9 : 8)).map { WitProtocol.signed16(b, offset + $0 * 2) }
    }
    public var kind: String { register == -1 ? "inertial" : register == 0x51 ? "quaternion" : register == 0x3a ? "mag" : "register" }
    public var acceleration: [Double] { words.prefix(3).map { Double($0) / 2048 } }
    public var gyro: [Double] { words.dropFirst(3).prefix(3).map { Double($0) * 2000 / 32768 } }
    public var quaternion: [Double] { words.prefix(4).map { Double($0) / 32768 } }
    public var quaternionNorm: Double { sqrt(quaternion.reduce(0) { $0 + $1 * $1 }) }
    public var quaternionValid: Bool { register == 0x51 && (0.8...1.2).contains(quaternionNorm) }
    public func csv(identifier: String, ns: UInt64, wall: Int64, inertialVerified: Bool) -> String {
        var c = Array(repeating: "", count: 21)
        c[0] = String(ns); c[1] = String(wall); c[2] = identifier; c[3] = kind
        if register == -1 {
            if inertialVerified { for i in 0..<3 { c[4+i] = String(acceleration[i]); c[7+i] = String(gyro[i]) } }
            else { c[3] = "inertial_unverified" }
        } else if register == 0x51 {
            for i in 0..<4 { c[10+i] = String(quaternion[i]) }; c[19] = String(quaternionNorm); c[20] = quaternionValid ? "pass" : "fail"
        } else if register == 0x3a { for i in 0..<3 { c[14+i] = String(words[i]) } }
        c[17] = String(register); c[18] = WitProtocol.hex(bytes); return c.joined(separator: ",") + "\n"
    }
}
public struct WitParser {
    private var pending = Data()
    public private(set) var discarded = 0
    public init() {}
    public var pendingBytes: Int { pending.count }
    public mutating func accept(_ data: Data) -> [WitFrame] {
        let bytes = Array(pending + data); var offset = 0; var frames: [WitFrame] = []
        while bytes.count-offset >= 2 {
            if bytes[offset] != 0x55 || ![0x61,0x71].contains(bytes[offset+1]) { offset += 1; discarded += 1; continue }
            if bytes.count-offset < 20 { break }
            frames.append(WitFrame(Data(bytes[offset..<offset+20]))); offset += 20
        }
        pending = Data(bytes.dropFirst(offset)); return frames
    }
}
