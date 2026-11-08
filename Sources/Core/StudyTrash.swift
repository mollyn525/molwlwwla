import Foundation

public struct DeletedStudy: Codable, Identifiable, Sendable {
    public let study: Study
    public let deletedMS: Int64
    public var sessionIDs: [String]
    public var purging: Bool
    public var id: String { study.id }
}

/// Markers hide records atomically. Raw files stay in place until explicit permanent deletion.
public struct StudyTrash {
    public let root: URL
    private let fm = FileManager.default
    public init(root: URL) throws {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        let folder = self.root.appendingPathComponent("recently-deleted",isDirectory:true)
        guard folder.resolvingSymlinksInPath().standardizedFileURL == folder.standardizedFileURL else { throw LabError.invalid("最近删除目录无效") }
        try fm.createDirectory(at:folder,withIntermediateDirectories:true)
    }
    private func item(_ folder: String, _ name: String) throws -> URL {
        guard name.range(of:"^[A-Za-z0-9.-]+$",options:.regularExpression) != nil, name != ".", name != ".." else { throw LabError.invalid("记录路径无效") }
        let base = root.appendingPathComponent(folder,isDirectory:true).standardizedFileURL
        let url = base.appendingPathComponent(name).standardizedFileURL
        guard url.resolvingSymlinksInPath().standardizedFileURL == url, url.deletingLastPathComponent() == base else { throw LabError.invalid("记录路径包含链接，未删除任何外部文件") }
        return url
    }
    private func marker(_ id: String) throws -> URL {
        guard UUID(uuidString:id) != nil else { throw LabError.invalid("受试者任务编号无效") }
        return try item("recently-deleted",id+".json")
    }
    public func entries() throws -> [DeletedStudy] {
        try fm.contentsOfDirectory(at:root.appendingPathComponent("recently-deleted"),includingPropertiesForKeys:nil)
            .filter { $0.pathExtension == "json" }.map { path in
                let id = path.deletingPathExtension().lastPathComponent
                let entry = try JSONFile.decode(DeletedStudy.self,from:marker(id))
                guard entry.id == id, Set(entry.sessionIDs).count == entry.sessionIDs.count,
                      entry.sessionIDs.allSatisfy({ $0.range(of:"^[A-Za-z0-9-]+$",options:.regularExpression) != nil }) else { throw LabError.invalid("最近删除清单损坏") }
                return entry
            }.sorted { $0.deletedMS > $1.deletedMS }
    }
    public static func owner(_ meta: [String:Any]) throws -> String? {
        let candidates = [meta["study_id"] as? String,
                          (meta["study"] as? [String:Any])?["id"] as? String,
                          (meta["assignment"] as? [String:Any])?["study_id"] as? String,
                          (meta["subject_calibration"] as? [String:Any])?["studyID"] as? String].compactMap { $0 }
        let ids = Set(candidates)
        guard ids.count <= 1 else { throw LabError.invalid("记录包含相互冲突的受试者编号") }
        return ids.first
    }
    public func sessionIDs(for studyID: String) throws -> [String] {
        var ids: [String] = []
        for path in try fm.contentsOfDirectory(at:root.appendingPathComponent("sessions"),includingPropertiesForKeys:[.isDirectoryKey]) {
            guard (try path.resourceValues(forKeys:[.isDirectoryKey])).isDirectory == true else { continue }
            // Unreadable, unattributable records stay untouched.
            guard let meta = try? JSONFile.read(path.appendingPathComponent("metadata.json")) else { continue }
            let candidates = [meta["study_id"] as? String,(meta["study"] as? [String:Any])?["id"] as? String,
                              (meta["assignment"] as? [String:Any])?["study_id"] as? String,
                              (meta["subject_calibration"] as? [String:Any])?["studyID"] as? String]
            guard candidates.contains(studyID) else { continue }
            guard try Self.owner(meta) == studyID else { throw LabError.invalid("记录归属冲突") }
            _ = try item("sessions",path.lastPathComponent)
            ids.append(path.lastPathComponent)
        }
        return ids.sorted()
    }
    public func move(_ study: Study, at: Int64) throws {
        let destination = try marker(study.id)
        guard !fm.fileExists(atPath:destination.path) else { throw LabError.invalid("受试者已在最近删除中") }
        let entry = DeletedStudy(study:study,deletedMS:at,sessionIDs:try sessionIDs(for:study.id),purging:false)
        try JSONFile.encode(entry,to:destination)
    }
    private func entry(_ id: String) throws -> DeletedStudy {
        guard let entry = try entries().first(where: { $0.id == id }) else { throw LabError.invalid("最近删除中没有该受试者") }
        return entry
    }
    public func restore(_ id: String) throws {
        let row = try entry(id)
        guard !row.purging else { throw LabError.invalid("彻底删除已经开始，不能恢复部分记录；请继续彻底删除") }
        let path = try item("studies",id+".json")
        if fm.fileExists(atPath:path.path) {
            guard try JSONFile.decode(Study.self,from:path).id == id else { throw LabError.invalid("受试者任务文件不一致") }
        } else { try JSONFile.encode(row.study,to:path) }
        try fm.removeItem(at:marker(id))
    }
    public func permanentlyDelete(_ id: String) throws {
        var row = try entry(id)
        row.sessionIDs = Array(Set(row.sessionIDs + (try sessionIDs(for:id)))).sorted()
        // Validate all surviving folders before deleting the first one.
        for name in row.sessionIDs {
            let path = try item("sessions",name)
            guard fm.fileExists(atPath:path.path) else { continue }
            guard try Self.owner(JSONFile.read(path.appendingPathComponent("metadata.json"))) == id else { throw LabError.invalid("记录归属已变化，未继续删除") }
        }
        let studyFile = try item("studies",id+".json")
        if fm.fileExists(atPath:studyFile.path) {
            guard try JSONFile.decode(Study.self,from:studyFile).id == id else { throw LabError.invalid("受试者任务文件不一致，未继续删除") }
        }
        row.purging = true
        try JSONFile.encode(row,to:marker(id))
        for name in row.sessionIDs {
            let path = try item("sessions",name)
            if fm.fileExists(atPath:path.path) { try fm.removeItem(at:path) }
        }
        if fm.fileExists(atPath:studyFile.path) { try fm.removeItem(at:studyFile) }
        try fm.removeItem(at:marker(id))
    }
}

