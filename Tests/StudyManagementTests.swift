import XCTest
@testable import BaduanjinCore

final class StudyManagementTests: XCTestCase {
    private func save(_ files: StudyFiles, meta: [String:Any]) throws -> URL {
        let writer = try SessionWriter(root:files.sessions,metadata:meta)
        writer.event(ns:1,message:"synthetic ownership test")
        let done = expectation(description:"saved")
        writer.close(summary:["quality_passed":true,"normal_completion":true,"status":meta["subject_calibration"] == nil ? "accepted_default":"calibration_complete"]) { result in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }; done.fulfill()
        }
        wait(for:[done],timeout:5)
        return writer.directory
    }
    func testTrashRestoreAndPurgePreserveOtherSubjectsBindingsAndExports() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let files = try StudyFiles(root:root)
        try files.create(subject:"SAME",at:1); let first = try XCTUnwrap(files.study)
        let sensor = UUID().uuidString
        try files.bind(role:"head",id:sensor,name:"synthetic")
        let assignment = try Assignment(study:first.id,action:7,slot:1,attempt:1)
        let formal = try save(files,meta:["diagnostic":false,"assignment":try JSONFile.object(assignment)])
        var owned = [formal]
        for kind in SubjectCalibrationKind.allCases {
            let calibration = SubjectCalibration(kind:kind,studyID:first.id,setup:"fixture")
            owned.append(try save(files,meta:["diagnostic":false,"study_id":first.id,"subject_calibration":try JSONFile.object(calibration)]))
        }
        owned.append(try save(files,meta:["diagnostic":true,"study":try JSONFile.object(first)]))
        let unscoped = try save(files,meta:["diagnostic":true])
        let original = try Data(contentsOf:formal.appendingPathComponent("events.jsonl"))
        try files.create(subject:"SAME",at:2); let second = try XCTUnwrap(files.study)
        let other = try save(files,meta:["diagnostic":true,"study_id":second.id])
        let exported = root.appendingPathComponent("exports/existing.zip")
        try Data("existing shared export".utf8).write(to:exported)
        try files.activate(first.id)
        try files.trashStudy(first.id,at:3)
        XCTAssertNil(files.study)
        XCTAssertEqual(try files.studies().map(\.id),[second.id])
        XCTAssertEqual(try files.deletedStudies().first?.sessionIDs.count,4)
        XCTAssertEqual(files.trials.count,2)
        XCTAssertEqual(files.roster["head"]?.peripheralID,sensor)
        XCTAssertThrowsError(try files.activate(first.id))
        let reopened = try StudyFiles(root:root)
        XCTAssertNil(reopened.study); XCTAssertEqual(reopened.trials.count,2)
        XCTAssertEqual(try Data(contentsOf:formal.appendingPathComponent("events.jsonl")),original)
        try reopened.restoreStudy(first.id)
        XCTAssertEqual(reopened.trials.count,6); XCTAssertTrue(try reopened.deletedStudies().isEmpty)
        try reopened.activate(first.id); XCTAssertEqual(reopened.book.total,1)
        try reopened.trashStudy(first.id,at:4)
        try reopened.permanentlyDeleteStudy(first.id)
        XCTAssertTrue(owned.allSatisfy { !FileManager.default.fileExists(atPath:$0.path) })
        XCTAssertTrue(FileManager.default.fileExists(atPath:other.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:unscoped.path))
        XCTAssertEqual(try Data(contentsOf:exported),Data("existing shared export".utf8))
        XCTAssertEqual(reopened.roster["head"]?.peripheralID,sensor)
        XCTAssertTrue(try reopened.deletedStudies().isEmpty)
        XCTAssertEqual(try reopened.studies().map(\.id),[second.id])
    }
    func testInterruptedTrashClearsActiveStudyAndPartialPurgeCannotRestore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let files = try StudyFiles(root:root); try files.create(subject:"A",at:1)
        let study = try XCTUnwrap(files.study)
        let a = try save(files,meta:["diagnostic":true,"study_id":study.id])
        let b = try save(files,meta:["diagnostic":true,"study_id":study.id])
        try StudyTrash(root:root).move(study,at:2) // Simulate process exit before active-task cleanup.
        let reopened = try StudyFiles(root:root)
        XCTAssertNil(reopened.study); XCTAssertTrue(reopened.trials.isEmpty)
        var entry = try XCTUnwrap(reopened.deletedStudies().first); entry.purging = true
        try JSONFile.encode(entry,to:root.appendingPathComponent("recently-deleted/"+study.id+".json"))
        try FileManager.default.removeItem(at:a) // Simulate process exit midway through permanent deletion.
        let resumed = try StudyFiles(root:root)
        XCTAssertThrowsError(try resumed.restoreStudy(study.id))
        try resumed.permanentlyDeleteStudy(study.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath:b.path))
        XCTAssertTrue(try resumed.deletedStudies().isEmpty)
    }
    func testConflictingOwnershipAndSymlinksCannotDeleteAnotherDirectory() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:base) }
        let files = try StudyFiles(root:base.appendingPathComponent("app")); try files.create(subject:"A",at:1)
        let study = try XCTUnwrap(files.study)
        let directory = try save(files,meta:["diagnostic":true,"study_id":study.id])
        let meta = directory.appendingPathComponent("metadata.json")
        try JSONFile.write(["study_id":study.id,"study":["id":UUID().uuidString]],to:meta)
        XCTAssertThrowsError(try files.trashStudy(study.id,at:2))
        XCTAssertTrue(try files.deletedStudies().isEmpty)
        try JSONFile.write(["diagnostic":true,"study_id":study.id],to:meta)
        try files.trashStudy(study.id,at:2)
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true)
        let sentinel = outside.appendingPathComponent("keep.txt"); try Data("keep".utf8).write(to:sentinel)
        try FileManager.default.removeItem(at:directory)
        try FileManager.default.createSymbolicLink(at:directory,withDestinationURL:outside)
        XCTAssertThrowsError(try files.permanentlyDeleteStudy(study.id))
        XCTAssertEqual(try String(contentsOf:sentinel,encoding:.utf8),"keep")
    }
    func testInactiveForegroundContinuesAcquisitionButBackgroundDoesNot() {
        var lifecycle = AcquisitionLifecycle()
        lifecycle.transition(to:.inactive); XCTAssertFalse(lifecycle.acquisitionAllowed)
        lifecycle.transition(to:.active); XCTAssertTrue(lifecycle.acquisitionAllowed); XCTAssertTrue(lifecycle.interactive)
        for _ in 0..<5 {
            lifecycle.transition(to:.inactive)
            XCTAssertTrue(lifecycle.acquisitionAllowed); XCTAssertFalse(lifecycle.interactive)
            lifecycle.transition(to:.active); XCTAssertTrue(lifecycle.acquisitionAllowed)
        }
        lifecycle.transition(to:.background); XCTAssertFalse(lifecycle.acquisitionAllowed)
        lifecycle.transition(to:.inactive); XCTAssertFalse(lifecycle.acquisitionAllowed)
        lifecycle.transition(to:.active); XCTAssertTrue(lifecycle.acquisitionAllowed)
    }
}

