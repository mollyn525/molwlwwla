import Foundation

public let secondNS: UInt64 = 1_000_000_000
public let staleNS: UInt64 = 500_000_000
public let streams = ["acceleration", "angular_velocity", "magnetic_field", "quaternion"]
public enum QualityPolicy: String, Codable {
    case legacy = "four_streams_gte30_v1"
    case inertial = "inertial_gt40_v2"
    public static let current = QualityPolicy.inertial
    public var requiredNames: [String] { self == .inertial ? Array(streams.prefix(2)) : streams }
    public var title: String { self == .inertial ? "加速度、角速度各 >40 Hz" : "历史标准：四项各 ≥30 Hz" }
    public func ratePasses(_ hz: Double) -> Bool { hz.isFinite && (self == .inertial ? hz > 40 : hz >= 30) }
    public func requires(_ index: Int) -> Bool { requiredNames.indices.contains(index) }
    public func recentDataHealthy(_ ages: [Double?]) -> Bool {
        requiredNames.indices.allSatisfy { i in ages.indices.contains(i) && ages[i].map { $0.isFinite && $0 >= 0 && $0 < 500 } == true }
    }
    public func recentRatesPass(_ hz: [Double]) -> Bool {
        requiredNames.indices.allSatisfy { hz.indices.contains($0) && ratePasses(hz[$0]) }
    }
    public func passes(_ results: [StreamResult], discarded: Int = 0, tail: Int = 0, invalidQ: Int = 0) -> Bool {
        guard discarded == 0, tail == 0, self != .legacy || invalidQ == 0 else { return false }
        return requiredNames.allSatisfy { name in
            let rows = results.filter { $0.name == name }
            return rows.count == 1 && ratePasses(rows[0].average_hz) && rows[0].frames > 0 && rows[0].max_gap_ms.isFinite && rows[0].max_gap_ms >= 0 && rows[0].max_gap_ms < 500
        }
    }
    public var metadata: [String:Any] {
        ["id":rawValue,"required_streams":requiredNames,"average_hz_threshold":self == .inertial ? 40:30,
         "average_hz_comparison":self == .inertial ? ">":">=","max_gap_ms_exclusive":500,
         "duration_includes_gaps":true,"auxiliary_streams_recorded":true]
    }
    public static func recorded(metadata: [String:Any], summary: [String:Any]) -> QualityPolicy? {
        let raw = (summary["quality_policy"] as? [String:Any])?["id"] as? String ?? (metadata["quality_policy"] as? [String:Any])?["id"] as? String
        if let raw { return QualityPolicy(rawValue:raw) }; return .legacy
    }
}
public struct StreamResult: Codable {
    public var name: String, frames: Int, average_hz: Double, max_gap_ms: Double
    public var complete_seconds_below_30: Int, second_frame_counts: [Int]
    public var complete_seconds_at_or_below_40: Int? = nil
    public var passed: Bool { QualityPolicy.current.ratePasses(average_hz) && max_gap_ms < 500 }
}
public struct TrialStream {
    public let start: UInt64
    private var count = 0, bins: [Int] = []
    private var last: UInt64, maxGap: UInt64 = 0
    public init(start: UInt64) { self.start = start; last = start }
    public mutating func add(_ at: UInt64) {
        guard at >= start, at >= last else { return }
        count += 1; maxGap = max(maxGap, at-last); last = at
        let bin = Int((at-start)/secondNS)
        while bins.count <= bin { bins.append(0) }; bins[bin] += 1
    }
    public func result(end: UInt64, name: String) -> StreamResult {
        let duration = end > start ? Double(end-start)/1e9 : 0
        let complete = Int(duration)
        return StreamResult(name: name, frames: count, average_hz: duration > 0 ? Double(count)/duration : 0,
            max_gap_ms: Double(max(maxGap, end > last ? end-last : 0))/1e6,
            complete_seconds_below_30: (0..<complete).filter { $0 >= bins.count || bins[$0] < 30 }.count, second_frame_counts: bins,
            complete_seconds_at_or_below_40: (0..<complete).filter { $0 >= bins.count || bins[$0] <= 40 }.count)
    }
}
public struct RecentStream {
    private var values: [UInt64] = []
    public private(set) var last: UInt64?
    public init() {}
    public mutating func add(_ at: UInt64) { last = at; values.append(at); prune(at) }
    private mutating func prune(_ now: UInt64) { values.removeAll { now >= $0 && now-$0 >= 10*secondNS } }
    public mutating func rate(_ now: UInt64, seconds: Int) -> Double {
        prune(now); return Double(values.filter { now >= $0 && now-$0 < UInt64(seconds)*secondNS }.count)/Double(seconds)
    }
    public func age(_ now: UInt64) -> Double? { last.map { Double(now >= $0 ? now-$0 : 0)/1e6 } }
}
public struct QueryScheduler {
    public private(set) var next: UInt64 = 0
    private var m: [UInt64] = [], q: [UInt64] = [], receivedM = 0, receivedQ = 0, previous = -1, consecutive = 0, nextQ = false
    public init() {}
    public mutating func choose(_ now: UInt64) -> Int {
        m.removeAll { now >= $0 && now-$0 >= 40_000_000 }; q.removeAll { now >= $0 && now-$0 >= 40_000_000 }
        if consecutive >= 2 { return previous == 0x51 ? 0x3a : 0x51 }
        let mc = receivedM + m.count, qc = receivedQ + q.count
        return (mc == qc ? nextQ : qc < mc) ? 0x51 : 0x3a
    }
    public mutating func sent(_ reg: Int, at: UInt64, hz: Int) {
        if reg == 0x51 { q.append(at) } else { m.append(at) }
        consecutive = previous == reg ? consecutive+1 : 1; previous = reg; nextQ = reg == 0x3a
        next = at + secondNS/UInt64(max(1, hz))
    }
    public mutating func reply(_ reg: Int) {
        if reg == 0x51 { receivedQ += 1; if !q.isEmpty { q.removeFirst() } }
        if reg == 0x3a { receivedM += 1; if !m.isEmpty { m.removeFirst() } }
    }
}
public struct PoseSample { public let ns: UInt64; public let acceleration: [Double]; public let speed: Double }
public struct PoseWindow {
    private var samples: [PoseSample] = []
    public init() {}
    public mutating func add(ns: UInt64, acceleration: [Double], gyro: [Double]) {
        guard acceleration.count == 3, gyro.count == 3 else { return }
        samples.append(PoseSample(ns: ns, acceleration: acceleration, speed: sqrt(gyro.reduce(0) { $0+$1*$1 })))
        samples.removeAll { ns >= $0.ns && ns-$0.ns > 3*secondNS }
    }
    public var mean: [Double] { (0..<3).map { i in samples.isEmpty ? 0 : samples.reduce(0) { $0+$1.acceleration[i] }/Double(samples.count) } }
    /// Specific failure conditions are retained, including cases missing in the Android r3 audit.
    public func stabilityIssues(now: UInt64) -> [String] {
        var issues: [String] = []; let avg = mean
        if samples.count < 60 { issues.append("静态样本不足60帧") }
        if let first = samples.first, let last = samples.last {
            if now < last.ns || now-last.ns > 200_000_000 { issues.append("惯性数据超过200ms未更新") }
            if now < first.ns || now-first.ns < 2_800_000_000 { issues.append("连续静态窗口不足2.8秒") }
        } else { issues.append("没有惯性数据") }
        if samples.contains(where: { $0.speed >= 1 }) { issues.append("角速度达到1°/s") }
        if samples.contains(where: { sample in sqrt((0..<3).reduce(0) { sum,i in sum+pow(sample.acceleration[i]-avg[i],2) }) > 0.04 }) { issues.append("加速度相对窗口均值波动超过0.04g") }
        let norm = sqrt(avg.reduce(0) { $0+$1*$1 })
        if norm < 0.9 || norm > 1.1 { issues.append("重力模长不在0.9–1.1g") }
        if zip(samples,samples.dropFirst()).contains(where: { pair in pair.1.ns < pair.0.ns || pair.1.ns-pair.0.ns >= 200_000_000 }) { issues.append("静态窗口有200ms以上数据缺口") }
        return issues
    }
    public func issues(now: UInt64, tolerance: Double = 0.08) -> [String] {
        var result = stabilityIssues(now: now); let avg = mean
        if abs(avg[0]) > tolerance || abs(avg[1]) > tolerance || abs(avg[2]-1) > tolerance { result.append("原始+Z参考姿态不满足门限") }
        return result
    }
}
