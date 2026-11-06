import XCTest
@testable import BaduanjinCore

final class SubjectCalibrationTests: XCTestCase {
    private func trial(_ id: String, study: String, kind: SubjectCalibrationKind, setup: String, complete: Bool = true) -> Trial {
        var t = Trial(id:id,assignment:nil,diagnostic:false,quality:complete,normal:complete,status:complete ? "calibration_complete" : "calibration_incomplete")
        t.calibration = SubjectCalibration(kind:kind,studyID:study,setup:setup)
        return t
    }
    func testNposeMustReachFiveSecondsAndSquatsRequireConfirmation() {
        for duration in [-1.0,0,4.999,5,5.001] {
            XCTAssertEqual(RecordingPolicy.calibrationCompleted(kind:.staticPose,duration:duration,completionConfirmed:true),duration >= 5)
            XCTAssertFalse(RecordingPolicy.calibrationCompleted(kind:.staticPose,duration:duration,completionConfirmed:false))
            XCTAssertEqual(RecordingPolicy.calibrationCompleted(kind:.dynamicSquats,duration:duration,completionConfirmed:true),duration > 0)
            XCTAssertFalse(RecordingPolicy.calibrationCompleted(kind:.dynamicSquats,duration:duration,completionConfirmed:false))
        }
        XCTAssertFalse(RecordingPolicy.calibrationCompleted(kind:.staticPose,duration:.infinity,completionConfirmed:true))
    }
    func testBothPreparationsBelongToCurrentSubjectAndSetup() {
        let staticPose = trial("001",study:"s1",kind:.staticPose,setup:"a")
        let squats = trial("002",study:"s1",kind:.dynamicSquats,setup:"a")
        XCTAssertFalse(SubjectCalibration.ready(studyID:"s1",setup:"a",trials:[staticPose]))
        XCTAssertTrue(SubjectCalibration.ready(studyID:"s1",setup:"a",trials:[staticPose,squats]))
        XCTAssertFalse(SubjectCalibration.ready(studyID:"s2",setup:"a",trials:[staticPose,squats]))
        XCTAssertFalse(SubjectCalibration.ready(studyID:"s1",setup:"b",trials:[staticPose,squats]))
        let failed = trial("003",study:"s1",kind:.staticPose,setup:"a",complete:false)
        XCTAssertFalse(SubjectCalibration.ready(studyID:"s1",setup:"a",trials:[staticPose,squats,failed]))
        XCTAssertEqual(SlotBook(studyID:"s1",trials:[staticPose,squats]).total,0)
    }
    func testMountingIsAnAnnotationAndDoesNotInvalidateCalibration() throws {
        var study = try Study(subject:"S1",at:1)
        let before = try SubjectCalibration.setup(study:study,roster:[:],orientations:["sensor":0])
        study.mountingLabel = .horizontal
        XCTAssertEqual(try SubjectCalibration.setup(study:study,roster:[:],orientations:["sensor":0]),before)
        XCTAssertNotEqual(try SubjectCalibration.setup(study:study,roster:[:],orientations:["sensor":1]),before)
        study.calibrationRevision = "changed"
        XCTAssertNotEqual(try SubjectCalibration.setup(study:study,roster:[:],orientations:["sensor":0]),before)
        XCTAssertThrowsError(try WitProtocol.command(0x23,1))
        XCTAssertThrowsError(try WitProtocol.command(0x23,0))
    }
    func testLegacyStudyAndTrialDecode() throws {
        var study = try JSONFile.object(Study(subject:"OLD",at:1))
        study.removeValue(forKey:"calibrationRevision"); study.removeValue(forKey:"mountingLabel")
        let legacy = try JSONDecoder().decode(Study.self,from:JSONFile.bytes(study))
        XCTAssertNil(legacy.mountingLabel); XCTAssertNil(legacy.calibrationRevision)
        let assignment = try Assignment(study:legacy.id,action:6,slot:1,attempt:1)
        let original = Trial(id:"legacy",assignment:assignment,diagnostic:false,quality:true,normal:true,status:"accepted_default")
        let restored = try JSONDecoder().decode(Trial.self,from:JSONEncoder().encode(original))
        XCTAssertTrue(restored.accepted); XCTAssertNil(restored.calibration)
    }
    func testCalibrationFilesRecoverWithoutTakingActionSlots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let files = try StudyFiles(root:root)
        try files.create(subject:"S1",at:1)
        let study = try XCTUnwrap(files.study)
        let calibration = SubjectCalibration(kind:.staticPose,studyID:study.id,setup:"a")
        let recorder = try SessionWriter(root:files.sessions,metadata:["diagnostic":false,"study_id":study.id,"subject_calibration":try JSONFile.object(calibration)])
        let done = expectation(description:"close calibration")
        recorder.close(summary:["quality_passed":true,"normal_completion":true,"accepted":false,"status":"calibration_complete"]) { result in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }; done.fulfill()
        }
        wait(for:[done],timeout:5)
        let recovered = try StudyFiles(root:root)
        XCTAssertEqual(recovered.trials.count,1); XCTAssertTrue(recovered.warnings.isEmpty)
        XCTAssertEqual(recovered.trials.first?.calibration,calibration)
        XCTAssertEqual(recovered.book.total,0)
        XCTAssertTrue(SubjectCalibration.completed(.staticPose,studyID:study.id,setup:"a",trials:recovered.trials))
        let artifacts = ProcessInfo.processInfo.environment["IMU_TEST_ARTIFACT_DIR"].map { URL(fileURLWithPath:$0) } ?? root.appendingPathComponent("exports")
        try FileManager.default.createDirectory(at:artifacts,withIntermediateDirectories:true)
        try ArchiveExporter.export(sessions:files.sessions,trials:recovered.trials,destination:artifacts.appendingPathComponent("subject-calibration-export.zip"),cancel:ExportCancellation()) { _,_ in }
        let interrupted = try SessionWriter(root:files.sessions,metadata:["diagnostic":false,"study_id":study.id,"subject_calibration":try JSONFile.object(calibration)])
        interrupted.flush()
        try recovered.recover()
        XCTAssertFalse(SubjectCalibration.completed(.staticPose,studyID:study.id,setup:"a",trials:recovered.trials))
    }
}

