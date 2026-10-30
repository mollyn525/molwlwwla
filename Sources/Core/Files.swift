import Foundation
import CryptoKit

public enum JSONFile {
    public static func bytes(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    public static func write(_ object: Any, to url: URL) throws { try bytes(object).write(to: url, options: .atomic) }
    public static func read(_ url: URL) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { throw LabError.invalid("JSON对象无效") }; return result
    }
    public static func encode<T: Encodable>(_ object: T, to url: URL) throws { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; try e.encode(object).write(to: url, options: .atomic) }
    public static func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T { try JSONDecoder().decode(type, from: Data(contentsOf: url)) }
    public static func object<T: Encodable>(_ object: T) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(object)) as? [String: Any] else { throw LabError.invalid("编码对象无效") }; return value
    }
    public static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
public final class StudyFiles {
    public let root: URL, sessions: URL
    public private(set) var study: Study?, roster: [String: SensorBinding] = [:], trials: [Trial] = [], warnings: [String] = []
    private let fm = FileManager.default
    public init(root: URL) throws {
        self.root = root; sessions = root.appendingPathComponent("sessions", isDirectory: true)
        for p in [root, sessions, root.appendingPathComponent("studies"), root.appendingPathComponent("exports")] { try fm.createDirectory(at: p, withIntermediateDirectories: true) }
        if fm.fileExists(atPath: root.appendingPathComponent("active-study.json").path) { study = try JSONFile.decode(Study.self, from: root.appendingPathComponent("active-study.json")) }
        if fm.fileExists(atPath: root.appendingPathComponent("roster.json").path) { roster = try JSONFile.decode([String: SensorBinding].self, from: root.appendingPathComponent("roster.json")) }
        try recover()
    }
    public var book: SlotBook { SlotBook(studyID: study?.id ?? "", trials: trials) }
    public func create(subject: String, at: Int64) throws { let next = try Study(subject: subject, at: at); try commit(next); try resetWear() }
    private func commit(_ next: Study) throws {
        try JSONFile.encode(next, to: root.appendingPathComponent("studies/\(next.id).json"))
        try JSONFile.encode(next, to: root.appendingPathComponent("active-study.json")); study = next
    }
    public func studies() throws -> [Study] {
        try fm.contentsOfDirectory(at: root.appendingPathComponent("studies"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.map { try JSONFile.decode(Study.self, from: $0) }.sorted { $0.created_ms > $1.created_ms }
    }
    public func activate(_ id: String) throws {
        guard UUID(uuidString: id) != nil else { throw LabError.invalid("任务编号无效") }
        let next = try JSONFile.decode(Study.self, from: root.appendingPathComponent("studies/\(id).json")); try commit(next); try resetWear(); try recover()
    }
    public func rename(_ names: [String], at: Int64) throws { guard var next = study else { throw LabError.invalid("请先建立任务") }; try next.rename(names, at: at); try commit(next) }
    public func bind(role: String, id: String, name: String) throws {
        guard BodyRole.all.contains(where: { $0.id == role }), UUID(uuidString: id) != nil else { throw LabError.invalid("部位或iOS设备UUID无效") }
        guard !roster.contains(where: { $0.key != role && $0.value.peripheralID == id }) else { throw LabError.invalid("设备已绑定其他部位") }
        var next = roster; next[role] = SensorBinding(peripheralID: id, name: name); try saveRoster(next)
    }
    private func saveRoster(_ next: [String: SensorBinding]) throws { try JSONFile.encode(next, to: root.appendingPathComponent("roster.json")); roster = next }
    private func resetWear() throws {
        var next = roster; for key in next.keys { next[key]?.wearConfirmed = false; next[key]?.reference = nil; next[key]?.referenceID = nil }; try saveRoster(next)
    }
    public func recover() throws {
        trials = []; warnings = []
        for dir in try fm.contentsOfDirectory(at: sessions, includingPropertiesForKeys: [.isDirectoryKey]) {
            guard (try dir.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { continue }
            do {
                let meta = try JSONFile.read(dir.appendingPathComponent("metadata.json")), summaryURL = dir.appendingPathComponent("summary.json")
                if !fm.fileExists(atPath: summaryURL.path) { try JSONFile.write(["accepted":false,"quality_passed":false,"status":"incomplete_process_exit","recovered_ms":Int64(Date().timeIntervalSince1970*1000)], to: summaryURL) }
                let summary = try JSONFile.read(summaryURL)
                let assignment = try (meta["assignment"] as? [String: Any]).map { try JSONDecoder().decode(Assignment.self, from: JSONFile.bytes($0)) }
                var trial = Trial(id: dir.lastPathComponent, assignment: assignment, diagnostic: meta["diagnostic"] as? Bool ?? true, quality: summary["quality_passed"] as? Bool ?? false, normal: summary["normal_completion"] as? Bool ?? false, status: summary["status"] as? String ?? "unknown")
                if (summary["fault_event"] as? Bool ?? false) || (summary["dropped_log_records"] as? Int ?? 0) > 0 || !(summary["storage_error"] as? String ?? "").isEmpty || trial.status == "incomplete_process_exit" { trial.qualityPassed = false }
                let review = dir.appendingPathComponent("action-review.json")
                if fm.fileExists(atPath: review.path) { trial.reviews = try JSONFile.decode([Review].self, from: review) }
                if !trial.reviewValid { trial.qualityPassed = false; warnings.append("\(trial.id)：复核历史损坏") }
                trials.append(trial)
            } catch { warnings.append("\(dir.lastPathComponent)：\(error.localizedDescription)") }
        }
        trials.sort { $0.id > $1.id }
    }
    public func markRetry(id: String, reason: String, revision: Int, at: Int64) throws {
        guard var row = trials.first(where: { $0.id == id }) else { throw LabError.invalid("记录不存在") }
        try row.markRetry(reason: reason, revision: revision, at: at)
        try JSONFile.encode(row.reviews, to: sessions.appendingPathComponent(id).appendingPathComponent("action-review.json")); try recover()
    }
}

public struct WriterResult { public var dropped: Int, error: String, peak: Int, notifications: Int, frames: Int }
public final class SessionWriter {
    public let directory: URL
    private let io = DispatchQueue(label: "dev.imulink.ios.files"), lock = NSLock()
    private var handles: [String: FileHandle] = [:], queued = 0, closed = false
    private var result = WriterResult(dropped: 0, error: "", peak: 0, notifications: 0, frames: 0)
    public static let header = "elapsed_ns,wall_ms,address,type,ax_g,ay_g,az_g,gx_dps,gy_dps,gz_dps,qw,qx,qy,qz,mx_raw,my_raw,mz_raw,register,packet_hex,quaternion_norm,quaternion_norm_check\n"
    public init(root: URL, metadata: [String: Any]) throws {
        let free = (try FileManager.default.attributesOfFileSystem(forPath: root.path)[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
        guard free >= 256*1024*1024 else { throw LabError.invalid("可用空间不足256MiB") }
        directory = root.appendingPathComponent("\(Int64(Date().timeIntervalSince1970*1000))-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try JSONFile.write(metadata, to: directory.appendingPathComponent("metadata.json"))
        do {
            for name in ["notifications.jsonl","samples.csv","events.jsonl","relative_pose.csv"] {
                let url = directory.appendingPathComponent(name); guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw LabError.invalid("创建记录文件失败") }; handles[name] = try FileHandle(forWritingTo: url)
            }
            try handles["samples.csv"]?.write(contentsOf: Data(Self.header.utf8))
            try handles["relative_pose.csv"]?.write(contentsOf: Data("elapsed_ns,address,qw,qx,qy,qz,reference_id\n".utf8))
        } catch { for handle in handles.values { try? handle.close() }; throw error }
    }
    public func status() -> WriterResult { lock.lock(); defer { lock.unlock() }; return result }
    private func append(_ name: String, _ data: Data, notification: Bool = false, frame: Bool = false) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        if queued >= 8000 { result.dropped += 1; result.error = "写盘积压超过8000项"; lock.unlock(); return }
        queued += 1; result.peak = max(result.peak, queued); lock.unlock()
        io.async {
            do {
                guard let handle = self.handles[name] else { throw LabError.invalid("写盘句柄缺失") }; try handle.write(contentsOf: data)
                self.lock.lock(); if notification { self.result.notifications += 1 }; if frame { self.result.frames += 1 }; self.lock.unlock()
            } catch { self.lock.lock(); self.result.error = error.localizedDescription; self.lock.unlock() }
            self.lock.lock(); self.queued -= 1; self.lock.unlock()
        }
    }
    public func raw(id: String, ns: UInt64, wall: Int64, data: Data) {
        do { var line = try JSONFile.bytes(["elapsed_ns":ns,"wall_ms":wall,"address":id,"hex":WitProtocol.hex(data)]); line.append(10); append("notifications.jsonl", line, notification: true) }
        catch { recordError(error) }
    }
    public func frame(id: String, ns: UInt64, wall: Int64, frame: WitFrame, verified: Bool) { append("samples.csv", Data(frame.csv(identifier: id, ns: ns, wall: wall, inertialVerified: verified).utf8), frame: true) }
    public func event(id: String = "", ns: UInt64, message: String) {
        do { var line = try JSONFile.bytes(["elapsed_ns":ns,"address":id,"message":message]); line.append(10); append("events.jsonl", line) } catch { recordError(error) }
    }
    private func recordError(_ error: Error) { lock.lock(); result.error = error.localizedDescription; lock.unlock() }
    public func flush() {
        io.async {
            do {
                for handle in self.handles.values { try handle.synchronize() }
                let free = (try FileManager.default.attributesOfFileSystem(forPath: self.directory.path)[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
                if free < 64*1024*1024 { throw LabError.invalid("剩余空间不足64MiB") }
            } catch { self.recordError(error) }
        }
    }
    public func close(summary: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        lock.lock(); if closed { lock.unlock(); return }; closed = true; lock.unlock()
        io.async {
            for handle in self.handles.values { do { try handle.synchronize(); try handle.close() } catch { self.recordError(error) } }
            var final = summary; let result = self.status()
            final["dropped_log_records"] = result.dropped; final["storage_error"] = result.error; final["writer_queue_peak"] = result.peak
            final["notifications"] = result.notifications; final["frames"] = result.frames
            if result.dropped > 0 || !result.error.isEmpty { final["quality_passed"] = false; final["accepted"] = false; final["status"] = "storage_error" }
            do { try JSONFile.write(final, to: self.directory.appendingPathComponent("summary.json")); completion(.success(final)) } catch { completion(.failure(error)) }
        }
    }
}
