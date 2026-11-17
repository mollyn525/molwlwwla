import Foundation

public struct ExportedFile: Identifiable {
    public let url: URL
    public let bytes: Int64
    public let modified: Date
    public var id: String { url.lastPathComponent }
    public var complete: Bool { bytes > 0 && !id.hasSuffix(".partial.zip") }
}

/// Reads only directory metadata. Older exports need no migration or re-packing.
public enum ExportFiles {
    /// Called only after explicit UI confirmation. Cannot target recordings,
    /// directories, symlinks, or any path outside this app's exports folder.
    public static func delete(id: String, root: URL) throws {
        guard !id.isEmpty, id != ".", id != "..", !id.contains("/"), !id.contains("\\") else { throw LabError.invalid("导出文件名无效") }
        let directory = root.appendingPathComponent("exports",isDirectory:true).standardizedFileURL
        let url = directory.appendingPathComponent(id).standardizedFileURL
        let directoryValues = try directory.resourceValues(forKeys:[.isSymbolicLinkKey])
        let values = try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
        guard directoryValues.isSymbolicLink != true, url.deletingLastPathComponent() == directory,
              values.isRegularFile == true, values.isSymbolicLink != true else { throw LabError.invalid("只能删除导出目录内的普通文件") }
        try FileManager.default.removeItem(at:url)
    }
    public static func list(root: URL) throws -> [ExportedFile] {
        let directory = root.appendingPathComponent("exports",isDirectory:true)
        let keys: Set<URLResourceKey> = [.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey,.contentModificationDateKey]
        return try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:Array(keys)).compactMap { url in
            let value = try url.resourceValues(forKeys:keys)
            guard value.isRegularFile == true, value.isSymbolicLink != true else { return nil }
            return ExportedFile(url:url,bytes:Int64(value.fileSize ?? 0),modified:value.contentModificationDate ?? .distantPast)
        }.sorted { $0.modified == $1.modified ? $0.id < $1.id : $0.modified > $1.modified }
    }
}
