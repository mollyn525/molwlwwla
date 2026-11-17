import XCTest
import Foundation
@testable import BaduanjinCore

final class ExportFilesTests: XCTestCase {
    func testLegacyFilesAreDiscoveredWithoutChangingAnyBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        _ = try StudyFiles(root:root)
        let fixtures = ["old.zip":Data([1,2,3]),"crashed.partial.zip":Data([4,5]),"operations.jsonl":Data("{}\n".utf8),"empty.zip":Data()]
        for (name,data) in fixtures { try data.write(to:root.appendingPathComponent("exports/"+name)) }
        try FileManager.default.createDirectory(at:root.appendingPathComponent("exports/txt-work-old"),withIntermediateDirectories:false)
        let rows = try ExportFiles.list(root:root)
        XCTAssertEqual(Set(rows.map(\.id)),Set(fixtures.keys))
        XCTAssertEqual(Set(rows.filter(\.complete).map(\.id)),["old.zip","operations.jsonl"])
        XCTAssertEqual(rows.reduce(0) { $0 + $1.bytes },8)
        for (name,data) in fixtures { XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("exports/"+name)),data) }
    }
    func testExplicitDeletionOnlyRemovesSelectedExportAndRejectsEscapes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        _ = try StudyFiles(root:root)
        let protected = ["sessions/raw.csv","roster.json","studies/subject.json","exports/retain.zip"]
        for path in protected { try Data(path.utf8).write(to:root.appendingPathComponent(path)) }
        for name in ["chosen.zip","crashed.partial.zip"] {
            try Data([1,2,3]).write(to:root.appendingPathComponent("exports/"+name))
            try ExportFiles.delete(id:name,root:root)
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("exports/"+name).path))
        }
        for id in ["", ".", "..", "../roster.json", "../sessions/raw.csv", "/roster.json", "..\\roster.json"] {
            XCTAssertThrowsError(try ExportFiles.delete(id:id,root:root))
        }
        let directory = root.appendingPathComponent("exports/directory")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
        XCTAssertThrowsError(try ExportFiles.delete(id:"directory",root:root))
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("exports/alias.zip"),withDestinationURL:root.appendingPathComponent("sessions/raw.csv"))
        XCTAssertThrowsError(try ExportFiles.delete(id:"alias.zip",root:root))
        XCTAssertFalse(try ExportFiles.list(root:root).contains { $0.id == "alias.zip" })
        for path in protected { XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(path)),Data(path.utf8)) }
    }
}
