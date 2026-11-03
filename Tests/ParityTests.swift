import XCTest
import Foundation
@testable import BaduanjinCore

final class ParityTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true); return url
    }
    private func movement(hz: Int = 50, speed: Double = 10, gap: Bool = false, duplicate: Bool = false) -> MovementWindow {
        var w = MovementWindow(start:0,end:5*secondNS)
        for i in 0...5*hz {
            let ns = UInt64(i)*secondNS/UInt64(hz)
            if gap && ns > 2*secondNS && ns < 3*secondNS { continue }
            w.add(ns,speed:speed); if duplicate { w.add(ns,speed:2000) }
        }; return w
    }
    private func readySetup() -> ([String:SensorBinding],[DeviceReadiness]) {
        var roster: [String:SensorBinding] = [:], devices: [DeviceReadiness] = []
        for role in BodyRole.all {
            var b = SensorBinding(peripheralID:UUID().uuidString,name:role.name)
            b.reference = [1,0,0,0]; b.referenceID = "reference"; b.referenceStudyID = "study"; b.referenceDiagnostic = false
            b.wearConfirmed = true; b.movement = MovementReport(role:role.id,at:1,evidence:[]); roster[role.id] = b
            var d = DeviceReadiness(id:b.peripheralID); d.wanted = true; d.connected = true; d.initialized = true
            d.configurationOK = true; d.checkedSeconds = 10; d.hz = [50,50,35,35]; d.ages = [20,20,30,30]; devices.append(d)
        }; return (roster,devices)
    }
    private func gate(_ roster: [String:SensorBinding], _ devices: [DeviceReadiness], fresh: Bool = true, bytes: Int64 = 1_000_000_000, normal: Bool = true, history: Bool = true) -> PreflightResult {
        Preflight.evaluate(study:"study",nextAction:0,roster:roster,devices:devices,idle:true,bluetooth:true,freeBytes:bytes,fresh:fresh,normalMode:normal,classificationOK:history)
    }
    func testPreflightSeparatesStartConditionsFromWearingReminders() {
        let (roster,devices) = readySetup(); XCTAssertTrue(gate(roster,devices).ready); XCTAssertEqual(gate(roster,devices).checks.count,99)
        for index in 0..<15 {
            let role = BodyRole.all[index].id
            var changed = devices; changed[index].hz[0] = 40
            XCTAssertTrue(gate(roster,changed).failures.contains { $0.role == role && $0.id.hasSuffix(":data") })
            changed = devices; changed[index].ages[1] = 500; XCTAssertTrue(gate(roster,changed).ready); XCTAssertFalse(gate(roster,changed).reminders.isEmpty)
            changed = devices; changed[index].checkedSeconds = 9.99; XCTAssertTrue(gate(roster,changed).ready)
            changed = devices; changed[index].connected = false; XCTAssertFalse(gate(roster,changed).ready)
            var bindings = roster; bindings[role]?.referenceDiagnostic = true; XCTAssertTrue(gate(bindings,devices).ready); XCTAssertFalse(gate(bindings,devices).reminders.isEmpty)
            bindings = roster; bindings[role]?.referenceStudyID = "old-study"; XCTAssertTrue(gate(bindings,devices).ready)
            bindings = roster; bindings[role]?.wearConfirmed = false; XCTAssertTrue(gate(bindings,devices).ready)
            bindings = roster; bindings.removeValue(forKey:role); XCTAssertTrue(gate(bindings,devices).ready)
            changed = devices; changed[index].configurationOK = false; XCTAssertTrue(gate(roster,changed).ready)
        }
        var duplicate = roster; duplicate[BodyRole.all[1].id] = duplicate[BodyRole.all[0].id]; XCTAssertTrue(gate(duplicate,devices).ready)
        XCTAssertTrue(gate([:],devices).ready)
        XCTAssertFalse(gate(roster,Array(devices.prefix(14))).ready)
        var repeated = devices; repeated[1].id = repeated[0].id; XCTAssertFalse(gate(roster,repeated).ready)
        var extra = devices[0]; extra.id = "extra"; XCTAssertFalse(gate(roster,devices+[extra]).ready)
        XCTAssertFalse(gate(roster,devices,fresh:false).ready); XCTAssertFalse(gate(roster,devices,bytes:256*1024*1024-1).ready)
        XCTAssertFalse(gate(roster,devices,normal:false).ready); XCTAssertFalse(gate(roster,devices,history:false).ready)
    }
    func testManualCompletionDefaultAndAllAbnormalCases() {
        for diagnostic in [true,false] { for started in [true,false] { for manual in [true,false] { for quality in [true,false] {
            let result = RecordingPolicy.summary(diagnostic:diagnostic,actionStarted:started,userEnded:manual,quality:quality)
            XCTAssertEqual(result.accepted,!diagnostic && started && manual && quality)
            XCTAssertEqual(result.normal,!diagnostic && started && manual)
        } } } }
    }
    func testFifteenInertialStreamsPassWithoutAuxiliaryFrequencyGate() {
        let (roster,original) = readySetup()
        var devices = original
        for i in devices.indices { devices[i].hz = [49.63,49.63,7.85,7.85]; devices[i].ages = [20,20,650,nil] }
        XCTAssertTrue(gate(roster,devices).ready)
        for i in devices.indices {
            for stream in 0..<2 {
                var changed = devices; changed[i].hz[stream] = 40
                XCTAssertFalse(gate(roster,changed).ready)
                changed[i].hz[stream] = 40.01; XCTAssertTrue(gate(roster,changed).ready)
                changed[i].ages[stream] = 500; XCTAssertTrue(gate(roster,changed).ready)
                changed[i].ages[stream] = nil; XCTAssertTrue(gate(roster,changed).ready)
            }
        }
        var incomplete = roster; incomplete[BodyRole.all[0].id]?.reference = nil
        XCTAssertTrue(gate(incomplete,devices).ready); XCTAssertFalse(gate(incomplete,devices).reminders.isEmpty)
        XCTAssertFalse(QualityPolicy.current.recentRatesPass([Double.nan,50]))
        XCTAssertFalse(QualityPolicy.current.recentDataHealthy([20,Double.nan]))
    }
    func testStrict40HzQualityUsesWholeDurationAndKeepsGapAndStorageGuards() {
        func result(_ hz: Int, _ name: String, end: UInt64 = 2*secondNS) -> StreamResult {
            var s = TrialStream(start:0)
            for i in 0..<hz*2 { s.add(UInt64(i)*secondNS/UInt64(hz)) }
            return s.result(end:end,name:name)
        }
        let good = [result(50,"acceleration"),result(50,"angular_velocity"),result(8,"magnetic_field"),result(8,"quaternion")]
        XCTAssertTrue(QualityPolicy.current.passes(good))
        XCTAssertFalse(QualityPolicy.legacy.passes(good))
        XCTAssertTrue(QualityPolicy.current.passes(Array(good.prefix(2)),invalidQ:3))
        for index in 0..<2 {
            var changed = good; changed[index] = result(40,streams[index]); XCTAssertFalse(QualityPolicy.current.passes(changed))
            XCTAssertEqual(changed[index].complete_seconds_at_or_below_40,2)
            changed[index] = result(41,streams[index]); XCTAssertTrue(QualityPolicy.current.passes(changed))
            changed[index] = result(50,streams[index],end:3*secondNS)
            XCTAssertEqual(changed[index].average_hz,100.0/3,accuracy:0.0001)
            XCTAssertFalse(QualityPolicy.current.passes(changed))
        }
        XCTAssertFalse(QualityPolicy.current.passes(good,discarded:1))
        XCTAssertFalse(QualityPolicy.current.passes(good,tail:1))
        XCTAssertFalse(QualityPolicy.current.passes([good[0],good[0]]))
        var burst = TrialStream(start:0)
        for i in 0..<100 { burst.add(UInt64(i)*10_000_000) }
        let gapped = burst.result(end:2*secondNS,name:"acceleration")
        XCTAssertEqual(gapped.average_hz,50); XCTAssertFalse(QualityPolicy.current.passes([gapped,good[1]]))
        let fault = RecordingPolicy.summary(diagnostic:false,actionStarted:true,userEnded:false,quality:true)
        XCTAssertFalse(fault.accepted)
    }
    func testLegacyQualityMetadataAndStatisticsRemainReadable() throws {
        let old: [String:Any] = ["name":"acceleration","frames":70,"average_hz":35.0,"max_gap_ms":30.0,"complete_seconds_below_30":0,"second_frame_counts":[35,35]]
        let decoded = try JSONDecoder().decode(StreamResult.self,from:JSONFile.bytes(old))
        XCTAssertNil(decoded.complete_seconds_at_or_below_40)
        XCTAssertEqual(QualityPolicy.recorded(metadata:[:],summary:[:]),.legacy)
        XCTAssertEqual(QualityPolicy.recorded(metadata:["quality_policy":QualityPolicy.current.metadata],summary:[:]),.inertial)
        XCTAssertNil(QualityPolicy.recorded(metadata:[:],summary:["quality_policy":["id":"unknown-policy"]]))
        XCTAssertTrue(QualityPolicy.legacy.ratePasses(35)); XCTAssertFalse(QualityPolicy.current.ratePasses(35))
    }
    func testMissingOrOtherStudyReferenceDoesNotProduceRelativePose() {
        var b = SensorBinding(peripheralID:"sensor",name:"WT")
        XCTAssertFalse(b.hasRecordingReference(studyID:"s"))
        b.reference = [1,0,0,0]; b.referenceID = "ref"; b.referenceStudyID = "s"; b.referenceDiagnostic = false
        XCTAssertTrue(b.hasRecordingReference(studyID:"s")); XCTAssertFalse(b.hasRecordingReference(studyID:nil))
        XCTAssertFalse(b.hasRecordingReference(studyID:"other"))
        b.referenceDiagnostic = true; XCTAssertFalse(b.hasRecordingReference(studyID:"s"))
    }
    func testLegacyRosterKeepsBindingsWithoutGrantingFormalReference() throws {
        let root = try folder(), id = UUID().uuidString
        let legacy: [String:Any] = ["head":["peripheralID":id,"name":"WT-old","wearConfirmed":true,"reference":[1,0,0,0],"referenceID":"legacy"]]
        try JSONFile.write(legacy,to:root.appendingPathComponent("roster.json"))
        let before = try Data(contentsOf:root.appendingPathComponent("roster.json")), files = try StudyFiles(root:root)
        XCTAssertEqual(files.roster["head"]?.peripheralID,id); XCTAssertNil(files.roster["head"]?.referenceStudyID)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("roster.json")),before)
        XCTAssertFalse(gate(files.roster,[]).ready)
    }
    func testMovementUsesTimeNotFrameCountAndDoesNotFillGaps() {
        for hz in [30,50,100] {
            let w = movement(hz:hz); XCTAssertTrue(w.sufficient); XCTAssertEqual(w.integral,50,accuracy:0.0001)
            let duplicated = movement(hz:hz,duplicate:true); XCTAssertEqual(duplicated.integral,w.integral,accuracy:0.0001); XCTAssertEqual(duplicated.count,w.count)
        }
        let missing = movement(gap:true); XCTAssertFalse(missing.sufficient); XCTAssertLessThan(missing.coverage,0.9); XCTAssertLessThan(missing.integral,50)
    }
    func testCoupledSegmentsDoNotBecomeAutomaticWrongBinding() {
        let target = "left_upper_arm"
        var evidence = BodyRole.all.map { r in MovementEvidence(role:r.id,window:movement(speed:r.id == "left_hand_dorsum" ? 200:10),coupled:MovementReport.coupled(target:target,other:r.id)) }
        XCTAssertTrue(MovementReport(role:target,at:1,evidence:evidence).result.contains("仍需人工确认"))
        evidence[4] = MovementEvidence(role:BodyRole.all[4].id,window:movement(speed:200),coupled:false)
        XCTAssertTrue(MovementReport(role:target,at:1,evidence:evidence).result.contains("疑似异常"))
        evidence[14] = MovementEvidence(role:BodyRole.all[14].id,window:movement(gap:true),coupled:false)
        XCTAssertTrue(MovementReport(role:target,at:1,evidence:evidence).result.hasPrefix("无法判断"))
    }
    func testQuaternionAntipodesStableMeanAndRelativePose() throws {
        var w = QuaternionWindow()
        let q = [cos(Double.pi/8),0,0,sin(Double.pi/8)]
        for i in 0...150 { w.add(UInt64(i)*20_000_000,i%2 == 0 ? q:q.map { -$0 }) }
        let mean = try w.estimate(now:3*secondNS)
        for k in 0..<4 { XCTAssertEqual(mean[k],q[k],accuracy:0.000001) }
        let relative = try QuaternionMath.relative(reference:mean,current:q)
        XCTAssertEqual(relative[0],1,accuracy:0.000001); for k in 1..<4 { XCTAssertEqual(relative[k],0,accuracy:0.000001) }
        XCTAssertThrowsError(try QuaternionMath.normalized([0,0,0,0]))
    }
    func testReferenceRejectsChangingOrientationAndGaps() {
        var moving = QuaternionWindow(), missing = QuaternionWindow()
        for i in 0...150 {
            let ns = UInt64(i)*20_000_000, angle = i < 75 ? 0.0:Double.pi/6
            moving.add(ns,[cos(angle/2),sin(angle/2),0,0])
            if i < 60 || i > 90 { missing.add(ns,[1,0,0,0]) }
        }
        XCTAssertThrowsError(try moving.estimate(now:3*secondNS)); XCTAssertThrowsError(try missing.estimate(now:3*secondNS))
    }
    func testConfigurationPreservesOrientAndOnlyWhitelistedWrites() throws {
        let good = [3:8,0x24:0,0x23:1,0x96:0]
        XCTAssertTrue(try ConfigurationPlan(registers:good,rewrite:false).commands.isEmpty)
        var old = good; old[0x24] = 1
        let changed = try ConfigurationPlan(registers:old,rewrite:false)
        XCTAssertEqual(changed.commands.map { $0.0 },[0x69,0x24,0]); XCTAssertTrue(changed.matches(good))
        var flipped = good; flipped[0x23] = 0; XCTAssertFalse(changed.matches(flipped))
        XCTAssertEqual(try ConfigurationPlan(registers:good,rewrite:true).commands.map { $0.0 },[0x69,3,0x24,0])
        for pair in [(0x23,0),(1,7),(0,1),(3,7),(0x69,0x88b5)] { XCTAssertThrowsError(try WitProtocol.command(pair.0,pair.1)) }
        XCTAssertEqual(WitProtocol.hex(try WitProtocol.command(0x69,0xb588)),"FFAA6988B5")
        XCTAssertFalse(WitProtocol.supportedFirmware("unknown")); XCTAssertTrue(WitProtocol.supportedFirmware("10080.1.22"))
    }
    func testCalibrationThreeCommandsTimingAndDuplicateCallbacks() {
        let port = FakeCalibrationPort(); port.duplicate = true; var results: [Bool] = []
        let controller = CalibrationController(port:port) { ok,_ in results.append(ok) }; controller.begin(); port.drain()
        XCTAssertEqual(port.writes.map { $0.1 },[0x69,1,0]); XCTAssertEqual(port.writes.map { $0.0 },[100,200,11000]); XCTAssertEqual(results,[true]); XCTAssertEqual(port.verifications,1)
    }
    func testCalibrationWaitsFromDelayedStartAndNeverResumesAfterDrop() {
        let delayed = FakeCalibrationPort(); delayed.writeDelay = 3000
        let c = CalibrationController(port:delayed) { _,_ in }; c.begin(); delayed.drain()
        XCTAssertEqual(delayed.writes.count,3)
        XCTAssertGreaterThanOrEqual(delayed.writes[2].0-delayed.writes[1].0-delayed.writeDelay,10800)
        let disconnected = FakeCalibrationPort(); var outcomes: [Bool] = []
        let d = CalibrationController(port:disconnected) { ok,_ in outcomes.append(ok) }; d.begin()
        disconnected.later(1000) { disconnected.connected = false }; disconnected.later(15000) { disconnected.connected = true }; disconnected.drain()
        XCTAssertEqual(disconnected.writes.map { $0.1 },[0x69,1]); XCTAssertEqual(outcomes,[false])
    }
    func testCalibrationMovementAndCancelBlockSaveAndPostcheckCanFail() {
        for before in [true,false] {
            let p = FakeCalibrationPort(); p.badBefore = before; p.badAfter = !before; var ok: Bool?
            let c = CalibrationController(port:p) { value,_ in ok = value }; c.begin(); p.drain()
            XCTAssertEqual(ok,false); XCTAssertFalse(p.writes.contains { $0.1 == 0 })
        }
        let p = FakeCalibrationPort(); var result: Bool?; p.verifyOK = false
        let c = CalibrationController(port:p) { ok,_ in result = ok }; c.begin(); p.drain()
        XCTAssertEqual(p.writes.count,3); XCTAssertEqual(result,false)
        let cancelled = FakeCalibrationPort(); let d = CalibrationController(port:cancelled) { _,_ in }; d.begin(); d.cancel("cancel"); cancelled.drain(); XCTAssertTrue(cancelled.writes.isEmpty)
    }
    func testCalibrationContinuousMonitorCatchesTransientMotionAndGap() {
        var m = CalibrationMonitor(start:0,initial:[0,0,1])
        for i in 1...500 { m.add(UInt64(i)*20_000_000,acceleration:[0,0,1],gyro:[0,0,0]) }
        XCTAssertTrue(m.issues(now:10*secondNS).isEmpty)
        m.add(11*secondNS,acceleration:[0.2,0,1],gyro:[0,2,0])
        XCTAssertEqual(m.issues(now:11*secondNS).count,3)
    }
    private func save(_ files: StudyFiles, assignment: Assignment, quality: Bool, policy: QualityPolicy = .legacy) throws -> URL {
        let writer = try SessionWriter(root:files.sessions,metadata:["quality_policy":policy.metadata,"diagnostic":false,"assignment":try JSONFile.object(assignment),"study":try JSONFile.object(files.study!)])
        writer.raw(id:"sensor",ns:1,wall:1,data:try WitProtocol.unhex("5561000000000008000000000000000000000000"))
        writer.relative(id:"sensor",ns:1,quaternion:[1,0,0,0],reference:"test-reference")
        let done = expectation(description:"save formal attempt")
        writer.close(summary:["quality_policy":policy.metadata,"diagnostic":false,"quality_passed":quality,"normal_completion":true,"accepted":quality,"status":quality ? "accepted_default":"quality_failed"]) { r in if case .failure(let e) = r { XCTFail(e.localizedDescription) }; done.fulfill() }
        wait(for:[done],timeout:10); try files.recover(); return writer.directory
    }
    func testFormalSaveReviewRetryReopenAndClassifiedArchivePreserveBytes() throws {
        let files = try StudyFiles(root:folder()); try files.create(subject:"S001",at:1)
        let first = try save(files,assignment:files.book.begin(action:0,slot:1),quality:true)
        let raw = try Data(contentsOf:first.appendingPathComponent("notifications.jsonl")), summary = try Data(contentsOf:first.appendingPathComponent("summary.json"))
        XCTAssertEqual(files.book.total,1)
        try files.markRetry(id:first.lastPathComponent,reason:"绑带松动",revision:0,at:2); XCTAssertEqual(files.book.total,0)
        try files.review(id:first.lastPathComponent,decision:"accepted",reason:"误标",revision:1,at:3); XCTAssertEqual(files.book.total,1)
        try files.markRetry(id:first.lastPathComponent,reason:"动作做错",revision:2,at:4)
        let second = try save(files,assignment:files.book.begin(action:0,slot:1),quality:false,policy:.inertial)
        XCTAssertThrowsError(try files.review(id:second.lastPathComponent,decision:"accepted",reason:"override",revision:0,at:5))
        _ = try save(files,assignment:files.book.begin(action:0,slot:1),quality:true,policy:.inertial)
        let reopened = try StudyFiles(root:files.root); XCTAssertEqual(reopened.book.total,1); XCTAssertEqual(reopened.trials.count,3)
        XCTAssertEqual(reopened.book.attempts(action:0,slot:1).map { $0.assignment!.slot_attempt },[1,2,3])
        XCTAssertEqual(try Data(contentsOf:first.appendingPathComponent("notifications.jsonl")),raw)
        XCTAssertEqual(try Data(contentsOf:first.appendingPathComponent("summary.json")),summary)
        let artifacts = ProcessInfo.processInfo.environment["IMU_TEST_ARTIFACT_DIR"].map { URL(fileURLWithPath:$0) } ?? files.root.appendingPathComponent("exports")
        try FileManager.default.createDirectory(at:artifacts,withIntermediateDirectories:true)
        try ArchiveExporter.export(sessions:files.sessions,trials:reopened.trials,destination:artifacts.appendingPathComponent("formal-retry-export.zip"),cancel:ExportCancellation(),attachments:["operations.jsonl":Data(contentsOf:files.root.appendingPathComponent("operations.jsonl")),"roster-at-export.json":JSONEncoder().encode(files.roster),"studies-at-export.json":JSONEncoder().encode(files.studies())]) { _,_ in }
    }
    func testInterruptedOperationRecoveryIsAppendOnlyAndNeverSuccess() throws {
        let root = try folder()
        try OperationAudit.append(root:root,type:"operation_started",details:["operation_id":"one","type":"accelerometer_calibration"],at:1)
        try OperationAudit.append(root:root,type:"operation_tx_submitted",details:["operation_id":"one","hex":"FFAA000000"],at:1)
        let url = root.appendingPathComponent("operations.jsonl"), before = try Data(contentsOf:url)
        try OperationAudit.recover(root:root,at:2); try OperationAudit.recover(root:root,at:3)
        let after = try Data(contentsOf:url); XCTAssertEqual(after.prefix(before.count),before)
        let interrupted = try OperationAudit.read(root:root).filter { $0["type"] as? String == "operation_interrupted" }; XCTAssertEqual(interrupted.count,1)
        XCTAssertEqual((interrupted[0]["details"] as? [String:Any])?["verified"] as? Bool,false)
        XCTAssertEqual((interrupted[0]["details"] as? [String:Any])?["save_submitted"] as? Bool,true)
    }
    func testMissingFilesCannotRetainAcceptedStatusOrBeOverridden() throws {
        let files = try StudyFiles(root:folder()); try files.create(subject:"S002",at:1)
        let directory = try save(files,assignment:files.book.begin(action:0,slot:1),quality:true)
        try FileManager.default.removeItem(at:directory.appendingPathComponent("samples.csv"))
        try files.recover(); XCTAssertEqual(files.book.total,0); XCTAssertFalse(files.warnings.isEmpty)
        XCTAssertThrowsError(try files.review(id:directory.lastPathComponent,decision:"accepted",reason:"missing file",revision:0,at:2))
    }
    func testDamagedAuditKeepsExistingDataAccessibleAndBlocksNewAudit() throws {
        let root = try folder(), original = Data("{broken\n".utf8)
        try original.write(to:root.appendingPathComponent("operations.jsonl"))
        let files = try StudyFiles(root:root); XCTAssertFalse(files.warnings.isEmpty)
        XCTAssertThrowsError(try files.audit("new",[:]))
        try files.recover(); XCTAssertFalse(files.warnings.isEmpty)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("operations.jsonl")),original)
    }
}

private final class FakeCalibrationPort: CalibrationPort {
    var nowMS: UInt64 = 0, connected = true, writeDelay: UInt64 = 0
    var writes: [(UInt64,Int,Int)] = [], events: [(UInt64,() -> Void)] = []
    var badBefore = false, badAfter = false, duplicate = false, verifyOK = true, verifications = 0
    func later(_ milliseconds: UInt64, _ action: @escaping () -> Void) { events.append((nowMS+milliseconds,action)) }
    func stableIssues(beforeSave: Bool) -> [String] { (beforeSave ? badAfter:badBefore) ? ["movement"]:[] }
    func recoveryCheck() -> CalibrationCheck { CalibrationCheck(failures:badAfter ? ["movement"]:[]) }
    func resetVerificationWindow() {}
    func write(_ register: Int, _ value: Int, completion: @escaping (Bool,String) -> Void) {
        writes.append((nowMS,register,value)); later(writeDelay) { completion(true,"local submission"); if self.duplicate { completion(true,"duplicate callback") } }
    }
    func started() {}
    func phase(_ name: String) {}
    func verifySaved(_ completion: @escaping (Bool,String) -> Void) { verifications += 1; later(3700) { completion(self.verifyOK,"static result, no firmware acknowledgement") } }
    func drain() { var count = 0; while !events.isEmpty && count < 1000 { events.sort { $0.0 < $1.0 }; let e = events.removeFirst(); nowMS = e.0; e.1(); count += 1 }; XCTAssertLessThan(count,1000) }
}
