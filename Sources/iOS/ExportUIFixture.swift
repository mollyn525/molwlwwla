#if DEBUG
import Foundation
import BaduanjinCore

extension AppModel {
    func prepareExportUIFixture() throws {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--export-files-ui-fixture"),
              let argument = args.first(where:{ $0.hasPrefix("--ui-storage-id=") }),
              UUID(uuidString:String(argument.dropFirst("--ui-storage-id=".count))) != nil,
              let files else { return }
        let completed = files.root.appendingPathComponent("exports/fixture-complete.zip")
        if !FileManager.default.fileExists(atPath:completed.path) {
            let zip = try StoredZIP(url:completed,cancellation:ExportCancellation())
            _ = try zip.add(name:"synthetic.txt",data:Data("Synthetic UI fixture only\n".utf8)); try zip.finish()
        }
        let partial = files.root.appendingPathComponent("exports/fixture.partial.zip")
        if !FileManager.default.fileExists(atPath:partial.path) { try Data([0x50,0x4b]).write(to:partial) }
    }
}
#endif
