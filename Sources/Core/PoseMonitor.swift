import Foundation

/// Derived observations only. No device commands, fusion changes, or raw-data mutation.
public struct PoseMonitor {
    public static let method = "wit_app_monitor_v1"
    public static let frame = "Hamilton_wxyz_active_sensor_to_local_Zup_RzYaw_RyPitch_RxRoll"
    public static let file = "monitor-derived.jsonl"
    private var qs: [(UInt64,[Double])] = [], ms: [(UInt64,[Double])] = []
    private var lastQ: [Double]?, lastM: [Double]?, qNS: UInt64?, mNS: UInt64?
    public private(set) var headingID = "", baselineID = "", yawOffset = 0.0, baseline = 0.0
    private var headingNS: UInt64 = 0, baselineNS: UInt64 = 0
    public init() {}
    public mutating func quaternion(_ ns: UInt64, _ value: [Double]) {
        if ns == qNS { lastQ = value; if !qs.isEmpty { qs[qs.count-1] = (ns,value) }; return }
        guard qNS == nil || ns > qNS! else { return }; qNS = ns; lastQ = value; qs.append((ns,value)); qs.removeAll { ns-$0.0 > 3*secondNS }; if qs.count > 1000 { qs.removeFirst(qs.count-1000) }
    }
    public mutating func magnetic(_ ns: UInt64, _ value: [Double]) {
        if ns == mNS { lastM = value; if !ms.isEmpty { ms[ms.count-1] = (ns,value) }; return }
        guard mNS == nil || ns > mNS! else { return }; mNS = ns; lastM = value; ms.append((ns,value)); ms.removeAll { ns-$0.0 > 3*secondNS }; if ms.count > 1000 { ms.removeFirst(ms.count-1000) }
    }
    public static func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
        [a[0]*b[0]-a[1]*b[1]-a[2]*b[2]-a[3]*b[3], a[0]*b[1]+a[1]*b[0]+a[2]*b[3]-a[3]*b[2], a[0]*b[2]-a[1]*b[3]+a[2]*b[0]+a[3]*b[1], a[0]*b[3]+a[1]*b[2]-a[2]*b[1]+a[3]*b[0]]
    }
    public static func euler(_ input: [Double]) throws -> [Double] {
        let q = try QuaternionMath.normalized(input), w = q[0], x = q[1], y = q[2], z = q[3]
        return [atan2(2*(w*x+y*z),1-2*(x*x+y*y))*180 / .pi, asin(max(-1,min(1,2*(w*y-z*x))))*180 / .pi, atan2(2*(w*z+x*y),1-2*(y*y+z*z))*180 / .pi]
    }
    public static func rotate(_ input: [Double], _ v: [Double]) throws -> [Double] {
        guard v.count == 3 else { throw LabError.invalid("向量维度错误") }
        let q = try QuaternionMath.normalized(input), c = [q[0],-q[1],-q[2],-q[3]]
        return Array(multiply(multiply(q,[0]+v),c).dropFirst())
    }
    public static func magNorm(_ m: [Double]) throws -> Double {
        guard m.count == 3, m.allSatisfy({$0.isFinite && $0 > -32768 && $0 < 32767}) else { throw LabError.invalid("磁场无效或饱和") }
        let n = sqrt(m.reduce(0) { $0+$1*$1 }); guard n > 0 else { throw LabError.invalid("磁场为零") }; return n
    }
    public static func headingDefined(_ q: [Double]) throws -> Bool { abs(cos(try euler(q)[1] * .pi / 180)) >= 0.1 }
    private func window(_ points: [(UInt64,[Double])], _ now: UInt64, _ confirmed: UInt64) throws {
        guard now >= confirmed, now-confirmed >= 3*secondNS else { throw LabError.invalid("确认放稳后请保持至少3秒再保存") }
        guard points.count >= 10, let first = points.first, let last = points.last, first.0 >= confirmed, now >= last.0, now-last.0 < 500_000_000, now-first.0 >= 2_800_000_000 else { throw LabError.invalid("需完整3秒新鲜窗口，至少10个不同接收时间") }
        guard !zip(points,points.dropFirst()).contains(where: { $1.0-$0.0 >= 500_000_000 }) else { throw LabError.invalid("窗口有500ms缺口") }
    }
    public mutating func resetHeading(now: UInt64, confirmed: UInt64) throws {
        guard headingID.isEmpty else { throw LabError.invalid("请先恢复航向，再重新归零") }; try window(qs,now,confirmed)
        let anchor = try QuaternionMath.normalized(qs[0].1)
        var mean = [0.0,0,0,0], values: [[Double]] = []
        for point in qs {
            var q = try QuaternionMath.normalized(point.1)
            if zip(q,anchor).reduce(0.0, { $0+$1.0*$1.1 }) < 0 { q = q.map { -$0 } }
            values.append(q); for i in 0..<4 { mean[i] += q[i]/Double(qs.count) }
        }
        mean = try QuaternionMath.normalized(mean)
        for q in values { let dot = abs(zip(q,mean).reduce(0.0) { $0+$1.0*$1.1 }); guard 2*acos(min(1,dot))*180 / .pi <= 5 else { throw LabError.invalid("姿态波动超过5°，请放稳后重试") } }
        guard try Self.headingDefined(mean) else { throw LabError.invalid("传感器X轴接近竖直，航向不确定") }
        yawOffset = try Self.euler(mean)[2] * .pi / 180; headingID = UUID().uuidString; headingNS = now
    }
    public mutating func setBaseline(now: UInt64, confirmed: UInt64) throws {
        try window(ms,now,confirmed); let values = try ms.map { try Self.magNorm($0.1) }, mean = values.reduce(0,+)/Double(values.count)
        guard values.allSatisfy({abs($0/mean-1) <= 0.1}) else { throw LabError.invalid("磁场窗口波动超过10%，暂不保存基线") }
        baseline = mean; baselineID = UUID().uuidString; baselineNS = now
    }
    public mutating func clearMagnetic() {
        ms = []; mNS = nil; lastM = nil; baseline = 0; baselineID = ""; baselineNS = 0
    }
    public mutating func revert() { headingID = ""; yawOffset = 0; headingNS = 0 }
    public mutating func clear() { self = PoseMonitor() }
    public func adjusted(_ input: [Double]) throws -> [Double] {
        let q = try QuaternionMath.normalized(input)
        return headingID.isEmpty ? q : Self.multiply([cos(yawOffset/2),0,0,-sin(yawOffset/2)],q)
    }
    public var state: [String:Any] { ["heading_id":headingID,"heading_radians":yawOffset,"heading_created_ns":headingNS,"baseline_id":baselineID,"baseline_raw":baseline,"baseline_created_ns":baselineNS] }
    public static var definition: [String:Any] { ["method":method,"file":file,"frame":frame,"frame_validation":"offline_convention; physical_axes_and_absolute_heading_not_validated","magnetic_unit":"raw_counts_and_uT_and_au_fixed_reference_40uT","mag_warning_fraction":0.2,"quality_gate":false,"drift_correction":false,"hardware_commands":false,"lifetime":"in_memory_clear_on_disconnect_task_binding_maintenance_restart"] }
    public struct Snapshot {
        public var q: [Double]?, rpy: [Double]?, norm: Double?, change: Double?
        public var headingDefined = false, warning = false, headingID = "", baselineID = ""
        public var orientationReason = "四元数未更新或已断线", magneticReason = "磁场未更新或已断线"
        public var qNS: UInt64?, mNS: UInt64?
        public init() {}
    }
    public func snapshot(now: UInt64, connected: Bool) -> Snapshot {
        var s = Snapshot(); s.headingID = headingID; s.baselineID = baselineID; s.qNS = qNS; s.mNS = mNS
        if connected, let qNS, now >= qNS, now-qNS < 500_000_000, let lastQ {
            do { let q = try adjusted(lastQ); s.q = q; s.rpy = try Self.euler(q); s.headingDefined = try Self.headingDefined(q); s.orientationReason = "" } catch { s.orientationReason = error.localizedDescription }
        }
        if connected, let mNS, now >= mNS, now-mNS < 500_000_000, let lastM {
            do { let norm = try Self.magNorm(lastM); s.norm = norm; s.magneticReason = ""; if !baselineID.isEmpty { s.change = norm/baseline-1; s.warning = abs(s.change!) > 0.2 } } catch { s.magneticReason = error.localizedDescription }
        }
        return s
    }
    public func row(id: String, ns: UInt64, type: String) -> [String:Any] {
        var row = state; row["method"] = Self.method; row["frame"] = Self.frame; row["address"] = id; row["elapsed_ns"] = ns; row["source_ns"] = ns; row["type"] = type
        do {
            if type == "orientation" { let q = try adjusted(lastQ ?? []); row["quaternion_normalized"] = try QuaternionMath.normalized(lastQ ?? []); row["rpy_raw_deg"] = try Self.euler(lastQ ?? []); row["quaternion_display"] = q; row["rpy_deg"] = try Self.euler(q); row["heading_defined"] = try Self.headingDefined(q) }
            else { let norm = try Self.magNorm(lastM ?? []); row["mag_norm_raw"] = norm; if !baselineID.isEmpty { row["change_fraction"] = norm/baseline-1; row["warning"] = abs(norm/baseline-1) > 0.2 } }
            row["valid"] = true
        } catch { row["valid"] = false; row["reason"] = error.localizedDescription }
        return row
    }
}
