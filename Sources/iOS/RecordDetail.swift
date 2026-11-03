import Foundation
import BaduanjinCore

struct RecordedDevice: Identifiable {
    var id: String, name: String, role: String, streams: [StreamResult], issues: [String], notices: [String]
}
struct RecordDetail {
    var subject: String, actionName: String, duration: Double, reason: String, failureReasons: [String], devices: [RecordedDevice], recordedMS: Int64
    var policy: QualityPolicy?
    init(metadata: [String:Any], summary: [String:Any]) {
        subject = (metadata["study"] as? [String:Any])?["subject"] as? String ?? "诊断 / 无任务"
        actionName = metadata["action_name"] as? String ?? "诊断"
        recordedMS = (metadata["recorded_ms"] as? NSNumber)?.int64Value ?? 0
        duration = summary["duration_s"] as? Double ?? 0; reason = summary["reason"] as? String ?? summary["status"] as? String ?? "未知"
        failureReasons = []; devices = []
        policy = QualityPolicy.recorded(metadata:metadata,summary:summary)
        if policy == nil { failureReasons.append("无法识别此记录的质量标准，请以原始摘要为准；未重新判定") }
        if summary["status"] as? String == "incomplete_process_exit" { failureReasons.append("上次录制异常退出，原始文件保留") }
        if let error = summary["storage_error"] as? String, !error.isEmpty { failureReasons.append("写盘错误："+error) }
        if (summary["dropped_log_records"] as? Int ?? 0) > 0 { failureReasons.append("写盘队列发生丢弃") }
        if ((summary["action_start_ns"] as? NSNumber)?.uint64Value ?? 0) == 0 { failureReasons.append("倒计时内结束，尚未进入动作段") }
        let roster = metadata["roster"] as? [String:[String:Any]] ?? [:]
        let names = metadata["devices"] as? [[String:Any]] ?? []
        for row in summary["devices"] as? [[String:Any]] ?? [] {
            let id = row["address"] as? String ?? "未知"
            let bindings = roster.filter { $0.value["peripheralID"] as? String == id }
            let roleID = bindings.count == 1 ? bindings.first?.key : nil
            let role = BodyRole.all.first { $0.id == roleID }?.name ?? "未绑定部位"
            let name = names.first { $0["address"] as? String == id }?["name"] as? String ?? id
            let rates = (row["streams"] as? [[String:Any]] ?? []).compactMap { s -> StreamResult? in guard let data = try? JSONFile.bytes(s) else { return nil }; return try? JSONDecoder().decode(StreamResult.self,from:data) }
            var issues: [String] = [], notices: [String] = []
            for s in rates where policy?.requiredNames.contains(s.name) == true {
                let label = ["acceleration":"加速度","angular_velocity":"角速度","magnetic_field":"磁场","quaternion":"四元数"][s.name] ?? s.name
                if policy?.ratePasses(s.average_hz) != true {
                    issues.append(QualityPolicy.current.requiredNames.contains(s.name) ? String(format:"%@平均%.2fHz，未达到本条频率要求",label,s.average_hz) : label+"未达到记录时的频率要求（历史结果）")
                }
                if s.max_gap_ms >= 500 { issues.append(String(format:"%@最长间隙%.0fms",label,s.max_gap_ms)) }
            }
            if let policy, !policy.requiredNames.allSatisfy({ name in rates.filter { $0.name == name }.count == 1 }) { issues.append("必需数据统计缺失或重复") }
            if policy == .inertial {
                for s in rates where !QualityPolicy.current.requiredNames.contains(s.name) {
                    if s.frames == 0 || s.max_gap_ms >= 500 { notices.append((s.name == "quaternion" ? "四元数":"磁场")+"存在缺失或停更，详见导出；不参与惯性质量判定") }
                }
            }
            if (row["invalid_quaternions"] as? Int ?? 0) > 0 {
                if policy == .legacy { issues.append("四元数范数异常") } else { notices.append("四元数范数异常，派生姿态可能缺失；不参与惯性质量判定") }
            }
            if (row["parser_discarded_bytes"] as? Int ?? 0) > 0 || (row["tail_bytes"] as? Int ?? 0) > 0 { issues.append("解析字节丢弃或残留半帧") }
            devices.append(RecordedDevice(id:id,name:name,role:role,streams:rates,issues:issues,notices:notices))
        }
        if summary["fault_event"] as? Bool == true { failureReasons.append("记录过停更、断线或前台/存储异常事件，详见events.jsonl") }
        let order = BodyRole.all.map(\.name)
        devices.sort { (order.firstIndex(of:$0.role) ?? 99) < (order.firstIndex(of:$1.role) ?? 99) }
    }
}
struct OperationDetail: Identifiable {
    var id: String, title: String, result: String, passed: Bool, saveSubmitted: Bool, at: Int64
    init?(_ row: [String:Any]) {
        guard let d = row["details"] as? [String:Any], let id = d["operation_id"] as? String else { return nil }
        self.id = id; title = (d["name"] as? String ?? "设备")+" · "+((d["type"] as? String == "configuration") ? "配置":"加速度校准")
        result = d["result"] as? String ?? "结果待核验"; passed = d["verified"] as? Bool == true || d["static_check_passed"] as? Bool == true
        saveSubmitted = d["save_submitted"] as? Bool ?? false; at = (row["wall_ms"] as? NSNumber)?.int64Value ?? 0
    }
}
