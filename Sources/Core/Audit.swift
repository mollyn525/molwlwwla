import Foundation

public enum OperationAudit {
    /// Serial caller; append-only journal. Hardware intents are persisted before submission.
    public static func append(root: URL, type: String, details: [String:Any], at: Int64) throws {
        let url = root.appendingPathComponent("operations.jsonl")
        if !FileManager.default.fileExists(atPath:url.path) { guard FileManager.default.createFile(atPath:url.path,contents:nil) else { throw LabError.invalid("无法建立操作审计") } }
        var data = try JSONFile.bytes(["type":type,"wall_ms":at,"details":details]); data.append(10)
        let file = try FileHandle(forWritingTo:url); defer { try? file.close() }
        try file.seekToEnd(); try file.write(contentsOf:data)
        if type != "operation_raw" { try file.synchronize() }
    }
    public static func read(root: URL) throws -> [[String:Any]] {
        let url = root.appendingPathComponent("operations.jsonl")
        guard FileManager.default.fileExists(atPath:url.path) else { return [] }
        let data = try Data(contentsOf:url)
        return try data.split(separator:10).enumerated().map { line,bytes in
            guard let row = try? JSONSerialization.jsonObject(with:Data(bytes)) as? [String:Any] else { throw LabError.invalid("操作审计第\(line+1)行损坏，原文件保留，请导出核查") }
            return row
        }
    }
    public static func recover(root: URL, at: Int64) throws {
        let rows = try read(root:root); var pending: [String:[String:Any]] = [:]
        for row in rows { guard let d = row["details"] as? [String:Any], let id = d["operation_id"] as? String else { continue }
            if row["type"] as? String == "operation_started" { pending[id] = d }
            if ["operation_result","operation_interrupted"].contains(row["type"] as? String ?? "") { pending.removeValue(forKey:id) }
        }
        for (_,var d) in pending {
            d["result"] = "上次操作异常中断；硬件可能已修改，需重新只读核对"; d["verified"] = false; d["internal_calibration_completion_known"] = false
            try append(root:root,type:"operation_interrupted",details:d,at:at)
        }
    }
}
