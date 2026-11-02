import Foundation

public enum QuaternionMath {
    public static func normalized(_ q: [Double]) throws -> [Double] {
        guard q.count == 4, q.allSatisfy(\.isFinite) else { throw LabError.invalid("四元数无效") }
        let n = sqrt(q.reduce(0) { $0+$1*$1 })
        guard (0.8...1.2).contains(n) else { throw LabError.invalid("四元数范数异常") }
        return q.map { $0/n }
    }
    public static func relative(reference: [Double], current: [Double]) throws -> [Double] {
        var a = try normalized(reference); let b = try normalized(current)
        for k in 1..<4 { a[k] = -a[k] }
        return [a[0]*b[0]-a[1]*b[1]-a[2]*b[2]-a[3]*b[3],
                a[0]*b[1]+a[1]*b[0]+a[2]*b[3]-a[3]*b[2],
                a[0]*b[2]-a[1]*b[3]+a[2]*b[0]+a[3]*b[1],
                a[0]*b[3]+a[1]*b[2]-a[2]*b[1]+a[3]*b[0]]
    }
}
public struct QuaternionWindow {
    private var samples: [(UInt64,[Double])] = []
    public init() {}
    public mutating func add(_ ns: UInt64, _ q: [Double]) {
        samples.append((ns,q)); samples.removeAll { ns >= $0.0 && ns-$0.0 > 3*secondNS }
    }
    /// Neutral reference only; hemisphere alignment does not correct yaw drift.
    public func estimate(now: UInt64) throws -> [Double] {
        guard samples.count >= 20, let first = samples.first, let last = samples.last,
              now >= last.0, now-last.0 < 200_000_000, now >= first.0, now-first.0 >= 2_800_000_000 else { throw LabError.invalid("四元数参考窗口不足或停更，请保持站姿至少3秒") }
        guard !zip(samples,samples.dropFirst()).contains(where: { pair in pair.1.0 < pair.0.0 || pair.1.0-pair.0.0 >= 200_000_000 }) else { throw LabError.invalid("四元数参考窗口存在200ms缺口") }
        let anchor = try QuaternionMath.normalized(first.1)
        var total = [0.0,0,0,0], aligned: [[Double]] = []
        for sample in samples {
            var q = try QuaternionMath.normalized(sample.1)
            if zip(q,anchor).reduce(0.0, { $0+$1.0*$1.1 }) < 0 { q = q.map { -$0 } }
            aligned.append(q); for k in 0..<4 { total[k] += q[k]/Double(samples.count) }
        }
        let mean = try QuaternionMath.normalized(total)
        for q in aligned {
            let dot = min(1,abs(zip(q,mean).reduce(0.0) { $0+$1.0*$1.1 }))
            guard 2*acos(dot)*180/Double.pi <= 5 else { throw LabError.invalid("参考四元数波动超过5°，请重新放稳") }
        }
        return mean
    }
}
public struct MovementWindow: Sendable {
    public let start: UInt64, end: UInt64
    private var last: UInt64?, lastSpeed = 0.0, covered: UInt64 = 0, maxGap: UInt64 = 0, invalid = false
    public private(set) var integral = 0.0, count = 0
    public init(start: UInt64, end: UInt64) { self.start = start; self.end = end }
    public mutating func add(_ ns: UInt64, speed: Double) {
        guard ns >= start && ns <= end else { return }
        guard speed.isFinite && speed >= 0 else { invalid = true; return }
        if let last, ns <= last { return }
        let gap = ns-(last ?? start); maxGap = max(maxGap,gap)
        if last != nil && gap < 200_000_000 { integral += (lastSpeed+speed)*0.5*Double(gap)/1e9; covered += gap }
        last = ns; lastSpeed = speed; count += 1
    }
    public var gapMS: Double { Double(max(maxGap,end-(last ?? start)))/1e6 }
    public var coverage: Double { end > start ? Double(covered)/Double(end-start) : 0 }
    public var sufficient: Bool { !invalid && count >= 30 && coverage >= 0.9 && gapMS < 200 }
}
public struct MovementEvidence: Codable, Sendable {
    public var role: String, integralDegrees: Double, coverage: Double, maxGapMS: Double, distinctTimes: Int, sufficient: Bool, coupled: Bool
    public init(role: String, window: MovementWindow, coupled: Bool) { self.role = role; integralDegrees = window.integral; coverage = window.coverage; maxGapMS = window.gapMS; distinctTimes = window.count; sufficient = window.sufficient; self.coupled = coupled }
}
public struct MovementReport: Codable, Sendable {
    public var role: String, result: String, wallMS: Int64, evidence: [MovementEvidence]
    public var method = "receive_time_trapezoids_no_gap_fill_v1"
    public init(role: String, at: Int64, evidence: [MovementEvidence]) {
        self.role = role; wallMS = at; self.evidence = evidence
        if evidence.count != 15 { result = "无法判断：15部位对照不完整" }
        else if evidence.contains(where: { !$0.sufficient }) { result = "无法判断：目标或对照部位数据覆盖不足/存在缺口" }
        else if let target = evidence.first(where: { $0.role == role }), target.integralDegrees >= 20 {
            let unrelated = evidence.filter { !$0.coupled }.map(\.integralDegrees).max() ?? 0
            result = unrelated > target.integralDegrees*2 ? "疑似异常：非联动部位响应更大，请核对编号" : "运动响应存在，联动不作错绑依据；仍需人工确认"
        } else { result = "无法判断：目标运动不足" }
    }
    public static func coupled(target: String, other: String) -> Bool {
        guard let t = BodyRole.all.firstIndex(where: { $0.id == target }), let o = BodyRole.all.firstIndex(where: { $0.id == other }) else { return false }
        if t == o || t < 3 { return true }
        for group in [[3,5,7],[4,6,8],[9,11,13],[10,12,14]] where group.contains(t) { return group.contains(o) || o == (t<9 ? 1:2) }
        return false
    }
}
public struct CalibrationMonitor {
    public let initial: [Double]
    private var last: UInt64
    public private(set) var count = 0, maxGapMS = 0.0, maxGyro = 0.0, maxDeviation = 0.0
    public init(start: UInt64, initial: [Double]) { self.initial = initial; last = start }
    public mutating func add(_ ns: UInt64, acceleration: [Double], gyro: [Double]) {
        guard ns >= last, acceleration.count == 3, gyro.count == 3 else { maxDeviation = .infinity; return }
        maxGapMS = max(maxGapMS,Double(ns-last)/1e6); last = ns; count += 1
        maxGyro = max(maxGyro,sqrt(gyro.reduce(0) { $0+$1*$1 }))
        maxDeviation = max(maxDeviation,sqrt(zip(acceleration,initial).reduce(0) { $0+pow($1.0-$1.1,2) }))
    }
    public func issues(now: UInt64) -> [String] {
        var result: [String] = []
        if count < 60 { result.append("过程样本不足") }
        if now < last || max(maxGapMS,Double(now >= last ? now-last : 0)/1e6) >= 500 { result.append("过程数据间隙达到500ms") }
        if maxGyro >= 1 { result.append("过程角速度达到1°/s") }
        if maxDeviation > 0.08 { result.append("过程加速度变化超过0.08g") }
        return result
    }
}
