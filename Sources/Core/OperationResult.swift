import Foundation

/// Read-only projection of the append-only journal, including older releases.
public struct OperationDetail: Identifiable {
    public let id: String, title: String, name: String, address: String, batchID: String, result: String
    public let calibration: Bool, passed: Bool, saveSubmitted: Bool, at: Int64
    public let beforeMean: [Double]?, afterMean: [Double]?, finalWindowPassed: Bool?
    public let recoveredBeforeSave: Bool, recoveredAfterSave: Bool
    public let longestGapMS: Double?, maxGyro: Double?
    public var delta: [Double]? {
        guard let beforeMean, let afterMean else { return nil }
        return zip(afterMean,beforeMean).map { $0.0-$0.1 }
    }
    public var status: String {
        if passed { return calibration ? "保存后静态复核通过":"配置回读通过" }
        return saveSubmitted ? "已提交保存，结果待核验":"未提交保存，未通过 / 未执行"
    }
    public init?(_ row: [String:Any]) {
        guard ["operation_result","operation_interrupted"].contains(row["type"] as? String ?? ""),
              let d = row["details"] as? [String:Any], let id = d["operation_id"] as? String else { return nil }
        self.id = id; name = d["name"] as? String ?? "设备"; address = d["address"] as? String ?? "未记录设备标识"
        batchID = d["batch_id"] as? String ?? "历史批次"
        calibration = d["type"] as? String == "accelerometer_calibration"
        title = name+" · "+(calibration ? "加速度校准":(d["type"] as? String == "magnetic_calibration" ? "磁场校准" : "配置"))
        result = d["result"] as? String ?? "结果待核验"
        saveSubmitted = d["save_submitted"] as? Bool == true
        passed = row["type"] as? String != "operation_interrupted" && (calibration ? (saveSubmitted && d["static_check_passed"] as? Bool == true) : d["verified"] as? Bool == true)
        at = (row["wall_ms"] as? NSNumber)?.int64Value ?? 0
        beforeMean = Self.vector((d["fresh_before"] as? [String:Any])?["static_mean_g"] ?? (d["before"] as? [String:Any])?["static_mean_g"])
        afterMean = Self.vector((d["after"] as? [String:Any])?["static_mean_g"])
        finalWindowPassed = d["final_window_passed"] as? Bool
        recoveredBeforeSave = d["recovering_before_save_entered"] as? Bool == true
        recoveredAfterSave = d["recovering_after_save_entered"] as? Bool == true
        let monitor = d["motion_monitor"] as? [String:Any] ?? [:]
        longestGapMS = monitor["max_gap_ms"] as? Double; maxGyro = monitor["max_gyro_dps"] as? Double
    }
    private static func vector(_ raw: Any?) -> [Double]? {
        guard let values = raw as? [Double], values.count == 3, values.allSatisfy(\.isFinite) else { return nil }
        return values
    }
}
