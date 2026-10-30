import XCTest
import Foundation
@testable import BaduanjinCore

final class CoreTests: XCTestCase {
    func testAndroidProductionParserFixtures() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource:"protocol-vectors",withExtension:"json",subdirectory:"Fixtures"))
        let object = try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any]
        let cases = object["cases"] as! [[String:Any]]
        XCTAssertGreaterThan(cases.count,100)
        for c in cases {
            var parser = WitParser(), frames:[WitFrame] = []
            for chunk in c["chunks"] as! [String] { frames += parser.accept(try WitProtocol.unhex(chunk)) }
            let expected = c["expected"] as! [String:Any], rows = expected["frames"] as! [[String:Any]]
            XCTAssertEqual(frames.count,rows.count)
            for (f,row) in zip(frames,rows) { XCTAssertEqual(WitProtocol.hex(f.bytes),row["hex"] as? String);XCTAssertEqual(f.register,row["register"] as? Int);XCTAssertEqual(f.words,row["words"] as? [Int]);XCTAssertEqual(f.kind,row["kind"] as? String) }
            XCTAssertEqual(parser.discarded,expected["discarded"] as? Int);XCTAssertEqual(parser.pendingBytes,expected["pending"] as? Int)
        }
    }
    func testReadOnlyCommandWhitelistAndSignedScaling() throws {
        XCTAssertThrowsError(try WitProtocol.read(0x69));XCTAssertEqual(try WitProtocol.read(0x51),Data([255,170,39,81,0]))
        let f = WitFrame(try WitProtocol.unhex("5561008000800080008000800080000000000000"))
        XCTAssertEqual(f.acceleration,[-16,-16,-16]);XCTAssertEqual(f.gyro,[-2000,-2000,-2000])
        XCTAssertThrowsError(try WitProtocol.unhex("FFF"))
    }
    func testWholeDurationIncludesTailAndNoData() {
        var stream = TrialStream(start:0)
        for i in 0..<60 {stream.add(UInt64(i)*16_666_666)}
        let s = stream.result(end:2*secondNS,name:"acceleration")
        XCTAssertEqual(s.average_hz,30);XCTAssertGreaterThan(s.max_gap_ms,1000);XCTAssertFalse(s.passed);XCTAssertEqual(s.complete_seconds_below_30,1)
        let empty = TrialStream(start:100).result(end:2*secondNS+100,name:"quaternion")
        XCTAssertEqual(empty.max_gap_ms,2000);XCTAssertFalse(empty.passed)
    }
    func test120SlotsRetryIsAppendOnlyAndQualityCannotBeOverridden() throws {
        var rows:[Trial] = [];let study = "subject-task"
        for a in 0..<8 { for slot in 1...15 {
            let assignment = try SlotBook(studyID:study,trials:rows).begin(action:a,slot:slot)
            rows.append(Trial(id:"record-\(a)-\(slot)",assignment:assignment,diagnostic:false,quality:true,normal:true,status:"accepted_default"))
        } }
        XCTAssertEqual(SlotBook(studyID:study,trials:rows).total,120)
        let original = rows[6];try rows[6].markRetry(reason:"动作做错",revision:0,at:1)
        XCTAssertTrue(original.accepted);XCTAssertEqual(SlotBook(studyID:study,trials:rows).total,119)
        let retry = try SlotBook(studyID:study,trials:rows).begin(action:0,slot:7)
        XCTAssertEqual(retry.record_number,7);XCTAssertEqual(retry.slot_attempt,2)
        rows.append(Trial(id:"retry",assignment:retry,diagnostic:false,quality:false,normal:true,status:"quality_failed",reviews:[Review(revision:1,at:2,decision:"accepted",reason:"test")]))
        XCTAssertFalse(rows.last!.accepted);XCTAssertEqual(SlotBook(studyID:study,trials:rows).total,119)
        XCTAssertThrowsError(try SlotBook(studyID:study,trials:rows).begin(action:1,slot:1))
        XCTAssertThrowsError(try rows[6].markRetry(reason:"changed",revision:0,at:3))
        let final = try SlotBook(studyID:study,trials:rows).begin(action:0,slot:7)
        XCTAssertEqual(final.slot_attempt,3)
        rows.append(Trial(id:"retry-3",assignment:final,diagnostic:false,quality:true,normal:true,status:"accepted_default"))
        XCTAssertEqual(SlotBook(studyID:study,trials:rows).total,120);XCTAssertEqual(rows.count,122)
    }
    func testCorruptAssignmentsAndDuplicateAttemptsFailClosed() throws {
        let bytes = Data("{\"study_id\":\"s\",\"action\":0,\"slot\":1,\"slot_attempt\":1,\"record_number\":99}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(Assignment.self,from:bytes))
        let a = try Assignment(study:"s",action:0,slot:1,attempt:1)
        let t = Trial(id:"1",assignment:a,diagnostic:false,quality:true,normal:true,status:"accepted_default")
        let book = SlotBook(studyID:"s",trials:[t,t]);XCTAssertFalse(book.accepted(action:0,slot:1));XCTAssertThrowsError(try book.begin(action:0,slot:1))
    }
    func testStaticFailureNamesTheActualPeakCondition() {
        var pose = PoseWindow()
        for i in 0..<150 {pose.add(ns:UInt64(i)*20_000_000,acceleration:[0,0,i == 140 ? 0.953:1],gyro:[0,0,0])}
        let issues = pose.issues(now:3*secondNS)
        XCTAssertTrue(issues.contains("加速度相对窗口均值波动超过0.04g"));XCTAssertFalse(issues.contains("原始+Z参考姿态不满足门限"))
    }
    func testTaskHistoryAndCrashRecoveryPreserveRawBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let files = try StudyFiles(root:root);try files.create(subject:"S001",at:1)
        let id = files.study!.id;try files.rename(["测试动作"]+(2...8).map{"动作\($0)"},at:2)
        let folder = files.sessions.appendingPathComponent("incomplete");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
        try JSONFile.write(["diagnostic":true],to:folder.appendingPathComponent("metadata.json"))
        let raw = Data("unaltered raw bytes\n".utf8);try raw.write(to:folder.appendingPathComponent("notifications.jsonl"))
        let reopened = try StudyFiles(root:root)
        XCTAssertEqual(reopened.study?.id,id);XCTAssertEqual(reopened.study?.name_history.count,1)
        XCTAssertEqual(reopened.trials.first?.status,"incomplete_process_exit");XCTAssertEqual(reopened.book.total,0)
        XCTAssertEqual(try Data(contentsOf:folder.appendingPathComponent("notifications.jsonl")),raw)
    }
    func testRecordingAndArchiveContainRealFileHashes() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let files = try StudyFiles(root:base), writer = try SessionWriter(root:files.sessions,metadata:["diagnostic":true,"platform":"test"])
        writer.raw(id:"sensor",ns:1,wall:1,data:try WitProtocol.unhex("5561000000000008000000000000000000000000"))
        let done = expectation(description:"writer closes")
        writer.close(summary:["quality_passed":false,"normal_completion":false,"diagnostic":true,"accepted":false,"status":"quality_failed"]) { result in if case .failure(let e) = result {XCTFail(e.localizedDescription)};done.fulfill() }
        wait(for:[done],timeout:10);try files.recover();XCTAssertEqual(files.trials.count,1)
        let artifacts = ProcessInfo.processInfo.environment["IMU_TEST_ARTIFACT_DIR"].map {URL(fileURLWithPath:$0)} ?? base.appendingPathComponent("artifacts")
        try FileManager.default.createDirectory(at:artifacts,withIntermediateDirectories:true)
        let zip = artifacts.appendingPathComponent("diagnostic-export.zip")
        try ArchiveExporter.export(sessions:files.sessions,trials:files.trials,destination:zip,cancel:ExportCancellation()){_,_ in}
        XCTAssertGreaterThan(try Data(contentsOf:zip).count,100)
        let cancellation = ExportCancellation();cancellation.cancel()
        XCTAssertThrowsError(try ArchiveExporter.export(sessions:files.sessions,trials:files.trials,destination:base.appendingPathComponent("cancelled.zip"),cancel:cancellation){_,_ in})
        XCTAssertTrue(FileManager.default.fileExists(atPath:writer.directory.appendingPathComponent("notifications.jsonl").path))
    }
}
