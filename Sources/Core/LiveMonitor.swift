import Foundation

public struct MonitorPoint {
    public let ns: UInt64
    public let values: [Double]?
}

public struct FieldReading {
    public static let reference = 40.0
    public let microtesla: [Double], axes: [Double], norm: Double
    public init(raw: [Double], type: Int?) throws {
        _ = try PoseMonitor.magNorm(raw)
        guard let scale = VendorTXT.magneticScale(type) else { throw LabError.invalid("等待已知的磁场类型（0x72）") }
        microtesla = raw.map { $0 * scale }
        axes = microtesla.map { $0 / Self.reference }
        norm = sqrt(axes.reduce(0) { $0 + $1*$1 })
    }
    public var plotted: [Double] { axes + [norm] }
}

public struct LiveMonitor {
    public var pose = PoseMonitor()
    public private(set) var field: FieldReading?
    public private(set) var magPoints: [MonitorPoint] = [], anglePoints: [MonitorPoint] = []
    public private(set) var fieldReason = "等待磁场数据", type: Int?
    public init() {}
    public mutating func setType(_ newType: Int?) {
        if type != newType { field = nil; magPoints = []; fieldReason = "等待新磁场数据" }
        type = newType
    }
    private static func append(_ points: inout [MonitorPoint], _ ns: UInt64, _ values: [Double]?) {
        if points.count == 180 { points.removeFirst() }
        points.append(MonitorPoint(ns: ns, values: values))
    }
    public mutating func magnetic(_ ns: UInt64, _ raw: [Double]) {
        pose.magnetic(ns, raw)
        do { field = try FieldReading(raw: raw, type: type); fieldReason = "" }
        catch { field = nil; fieldReason = error.localizedDescription }
        Self.append(&magPoints, ns, field?.plotted)
    }
    public mutating func quaternion(_ ns: UInt64, _ raw: [Double]) {
        pose.quaternion(ns, raw)
        Self.append(&anglePoints, ns, try? PoseMonitor.euler(pose.adjusted(raw)))
    }
    public mutating func changeHeading(_ next: PoseMonitor) { pose = next; anglePoints = [] }
    public func row(id: String, ns: UInt64, magnetic: Bool) -> [String:Any] {
        var row = pose.row(id: id, ns: ns, type: magnetic ? "magnetic" : "orientation")
        if magnetic {
            row["magnetic_type"] = type
            row["reference_ut"] = FieldReading.reference
            row["magnetic_normalized_valid"] = field != nil
            if let field {
                row["mag_ut"] = field.microtesla; row["mag_au"] = field.axes
                row["mag_norm_au"] = field.norm; row["mag_norm_ut"] = field.norm * FieldReading.reference
            } else { row["conversion_reason"] = fieldReason }
        }
        return row
    }
}

/// Each sequence begins only after the corresponding manual action.
public enum WitMagSequence {
    public static let intervalNS: UInt64 = 100_000_000
    public static let start = [Data([0xff,0xaa,0x69,0x88,0xb5]), Data([0xff,0xaa,0x01,0x07,0x00])]
    public static let finish = [Data([0xff,0xaa,0x69,0x88,0xb5]), Data([0xff,0xaa,0x01,0x00,0x00]), Data([0xff,0xaa,0x00,0x00,0x00])]
}

