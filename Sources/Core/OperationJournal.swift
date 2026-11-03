import Foundation

/// One handle per batch on the BLE work queue. Avoid opening/closing for every raw notification.
/// Hardware intents and results are still synchronized before proceeding, as in OperationAudit.
public final class OperationJournal {
    private let file: FileHandle
    private var closed = false
    public init(root: URL) throws {
        let url = root.appendingPathComponent("operations.jsonl")
        if !FileManager.default.fileExists(atPath:url.path) {
            guard FileManager.default.createFile(atPath:url.path,contents:nil) else { throw LabError.invalid("无法建立操作审计") }
        }
        file = try FileHandle(forWritingTo:url)
        try file.seekToEnd()
    }
    public func append(type: String, details: [String:Any], at: Int64) throws {
        guard !closed else { throw LabError.invalid("操作审计已关闭") }
        var bytes = try JSONFile.bytes(["type":type,"wall_ms":at,"details":details]); bytes.append(10)
        try file.write(contentsOf:bytes)
        if type != "operation_raw" { try file.synchronize() }
    }
    public func close() throws {
        guard !closed else { return }; closed = true
        defer { try? file.close() }; try file.synchronize()
    }
    deinit { try? close() }
}
