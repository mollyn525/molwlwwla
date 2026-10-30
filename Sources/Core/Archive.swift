import Foundation
import CryptoKit

// The only mutable field is protected by the same lock for every read and write.
public final class ExportCancellation: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    public init() {}
    public func cancel() { lock.lock(); value = true; lock.unlock() }
    public func check() throws { lock.lock(); let cancelled = value; lock.unlock(); if cancelled { throw LabError.invalid("导出已取消，原始数据保留") } }
}
private extension Data {
    mutating func le16(_ value: UInt16) { append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8)) }
    mutating func le32(_ value: UInt32) { le16(UInt16(truncatingIfNeeded: value)); le16(UInt16(truncatingIfNeeded: value >> 16)) }
}
/// Streaming ZIP STORE, with CRC32 and ZIP32 limits enforced before integer narrowing.
public final class StoredZIP {
    private static let table: [UInt32] = (0..<256).map { index in var c = UInt32(index); for _ in 0..<8 { c = (c >> 1) ^ (c & 1 == 1 ? 0xedb88320 : 0) }; return c }
    private let handle: FileHandle, cancellation: ExportCancellation
    private var directory = Data(), offset: UInt64 = 0, count = 0, names = Set<String>()
    public init(url: URL, cancellation: ExportCancellation) throws {
        guard !FileManager.default.fileExists(atPath: url.path), FileManager.default.createFile(atPath: url.path, contents: nil) else { throw LabError.invalid("导出文件已存在或无法建立") }
        handle = try FileHandle(forWritingTo: url); self.cancellation = cancellation
    }
    deinit { try? handle.close() }
    private func crc(_ chunk: Data, current: UInt32) -> UInt32 { chunk.reduce(current) { (value, byte) in (value >> 8) ^ Self.table[Int((value ^ UInt32(byte)) & 255)] } }
    private func write(_ bytes: Data) throws { try cancellation.check(); try handle.write(contentsOf: bytes); offset += UInt64(bytes.count) }
    public func add(name: String, data: Data) throws -> [String: Any] {
        try add(name: name, source: { consume in try consume(data) })
    }
    public func add(name: String, file: URL) throws -> [String: Any] {
        try add(name: name, source: { consume in
            let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
            while let chunk = try input.read(upToCount: 256*1024), !chunk.isEmpty { try consume(chunk) }
        })
    }
    private func add(name: String, source: (_ consume: (Data) throws -> Void) throws -> Void) throws -> [String: Any] {
        guard !name.hasPrefix("/"), !name.contains("\\"), !name.split(separator: "/").contains(".."), !names.contains(name), count < 65535 else { throw LabError.invalid("ZIP路径重复或无效") }
        let filename = Data(name.utf8); guard filename.count <= 65535 else { throw LabError.invalid("ZIP路径过长") }
        var size: UInt64 = 0, crcValue: UInt32 = 0xffffffff, hash = SHA256()
        try source { chunk in try cancellation.check(); size += UInt64(chunk.count); crcValue = crc(chunk, current: crcValue); hash.update(data: chunk) }
        guard size <= UInt64(UInt32.max), offset + size + UInt64(filename.count) + 30 <= UInt64(UInt32.max) else { throw LabError.invalid("单个ZIP超过4GiB，请分次导出") }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined(), crcFinal = crcValue ^ 0xffffffff, localOffset = UInt32(offset)
        var local = Data(); local.le32(0x04034b50); local.le16(20); local.le16(0x0800); local.le16(0); local.le16(0); local.le16(33)
        local.le32(crcFinal); local.le32(UInt32(size)); local.le32(UInt32(size)); local.le16(UInt16(filename.count)); local.le16(0); local.append(filename)
        try write(local)
        var actual: UInt64 = 0, verify = SHA256()
        try source { chunk in actual += UInt64(chunk.count); verify.update(data: chunk); try write(chunk) }
        guard actual == size, verify.finalize().map({ String(format: "%02x", $0) }).joined() == digest else { throw LabError.invalid("导出期间源文件变化，导出无效") }
        directory.le32(0x02014b50); directory.le16(20); directory.le16(20); directory.le16(0x0800); directory.le16(0); directory.le16(0); directory.le16(33)
        directory.le32(crcFinal); directory.le32(UInt32(size)); directory.le32(UInt32(size)); directory.le16(UInt16(filename.count)); directory.le16(0); directory.le16(0); directory.le16(0); directory.le16(0); directory.le32(0); directory.le32(localOffset); directory.append(filename)
        count += 1; names.insert(name); return ["path":name,"bytes":size,"sha256":digest]
    }
    public func finish() throws {
        guard offset + UInt64(directory.count) + 22 <= UInt64(UInt32.max) else { throw LabError.invalid("ZIP目录超过4GiB限制") }
        let centralOffset = UInt32(offset); try write(directory)
        var end = Data(); end.le32(0x06054b50); end.le16(0); end.le16(0); end.le16(UInt16(count)); end.le16(UInt16(count)); end.le32(UInt32(directory.count)); end.le32(centralOffset); end.le16(0)
        try write(end); try handle.synchronize(); try handle.close()
    }
}
public enum ArchiveExporter {
    public static let required = ["metadata.json","notifications.jsonl","samples.csv","relative_pose.csv","events.jsonl","summary.json"]
    public static func export(sessions: URL, trials: [Trial], destination: URL, cancel: ExportCancellation, allTrials: [Trial]? = nil, progress: @escaping (Int, Int) -> Void) throws {
        guard !trials.isEmpty else { throw LabError.invalid("没有可导出的记录") }
        let zip = try StoredZIP(url: destination, cancellation: cancel), context = allTrials ?? trials
        var manifest: [[String: Any]] = [], records: [[String: Any]] = []; var issues = 0
        for (index, trial) in trials.enumerated() {
            try cancel.check()
            guard trial.id.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil else { throw LabError.invalid("记录目录无效") }
            let folder = sessions.appendingPathComponent(trial.id), prefix: String
            if let a = trial.assignment, !trial.diagnostic { prefix = String(format: "study_%@/action_%02d/slot_%03d/attempt_%03d/%@", a.study_id, a.action+1, a.record_number, a.slot_attempt, trial.id) }
            else { prefix = "diagnostic/\(trial.id)" }
            var missing: [String] = []
            for name in required + ["action-review.json"] {
                let file = folder.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: file.path) { manifest.append(try zip.add(name: prefix+"/"+name, file: file)) }
                else if required.contains(name) { missing.append(name) }
            }
            let complete = missing.isEmpty; if !complete { issues += 1 }
            let effective: [String: Any] = ["accepted":complete && trial.accepted,"quality_passed":complete && trial.qualityPassed,"status":trial.status,"review_revision":trial.reviews.count,"source":"immutable_summary_plus_review"]
            manifest.append(try zip.add(name: prefix+"/effective-result-at-export.json", data: JSONFile.bytes(effective)))
            manifest.append(try zip.add(name: prefix+"/file-integrity-at-export.json", data: JSONFile.bytes(["required_files":required,"missing_files":missing,"complete":complete])))
            var row: [String: Any] = ["directory":trial.id,"archive_path":prefix,"diagnostic":trial.diagnostic,"counted_for_slot":false,"accepted":complete && trial.accepted,"integrity_passed":complete]
            if let a = trial.assignment {
                row["assignment"] = try JSONFile.object(a)
                let latest = context.filter { $0.assignment?.study_id == a.study_id && $0.assignment?.action == a.action && $0.assignment?.slot == a.slot }.max { ($0.assignment?.slot_attempt ?? 0) < ($1.assignment?.slot_attempt ?? 0) }
                let book = SlotBook(studyID:a.study_id,trials:context)
                row["counted_for_slot"] = complete && trial.accepted && latest?.id == trial.id && book.accepted(action:a.action,slot:a.slot)
            }
            records.append(row); progress(index+1, trials.count)
        }
        manifest.append(try zip.add(name: "collection-index.json", data: JSONFile.bytes(["records":records])))
        manifest.append(try zip.add(name: "export-checklist.json", data: JSONFile.bytes(["complete":issues == 0,"issue_count":issues,"records":records,"scope":"文件完整性不等于测量有效性"])))
        _ = try zip.add(name: "archive-files.json", data: JSONFile.bytes(["algorithm":"SHA-256","files":manifest]))
        try zip.finish()
    }
}
