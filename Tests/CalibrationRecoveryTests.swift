import XCTest
@testable import BaduanjinCore

final class CalibrationRecoveryTests: XCTestCase {
    private func run(_ p: RecoveryPort) -> (Bool,String) {
        var result: (Bool,String)?
        let c = CalibrationController(port:p) { ok,why in result = (ok,why); p.finished = true }
        p.controller = c; c.begin(); p.run()
        XCTAssertNotNil(result); return result ?? (false,"missing completion")
    }
    func testObservedTimingGapRecoversAndSavesExactlyOnce() {
        let p = RecoveryPort(); p.startGaps = [9500..<9740]; p.saveGaps = [0..<260]
        let result = run(p)
        XCTAssertTrue(result.0,result.1)
        XCTAssertEqual(p.writes.map { $0.1 },[0x69,1,0])
        XCTAssertGreaterThanOrEqual(p.saveAt!-p.startAt!,13700)
        XCTAssertLessThan(p.saveAt!-p.startAt!,15000)
        XCTAssertTrue(p.phases.contains("recovering_before_save")); XCTAssertEqual(p.readbacks,1)
        XCTAssertEqual(p.resets,2)
    }
    func testGapWithCalibrationOutputStepDoesNotMixOldAndNewMeans() {
        let p = RecoveryPort(offsetStep:true); p.startGaps = [9500..<9740]
        let result = run(p)
        XCTAssertTrue(result.0,result.1); XCTAssertTrue(p.phases.contains("recovering_before_save"))
        XCTAssertEqual(p.writes.map { $0.1 },[0x69,1,0])
        XCTAssertEqual(p.pose.mean[1],0,accuracy:1e-9)
    }
    func testPostSaveGapRequiresNewStableWindowWithoutAnotherSave() {
        let p = RecoveryPort(); p.saveGaps = [2200..<2460]
        let result = run(p)
        XCTAssertTrue(result.0,result.1)
        XCTAssertTrue(p.phases.contains("recovering_after_save"))
        XCTAssertGreaterThanOrEqual(p.nowMS-p.saveAt!,5200)
        XCTAssertEqual(p.writes.map { $0.1 },[0x69,1,0]); XCTAssertEqual(p.readbacks,1)
    }
    func testRepeatedShortGapsTimeOutBeforeSave() {
        let p = RecoveryPort(); p.repeatedGaps = true
        let result = run(p)
        XCTAssertFalse(result.0); XCTAssertTrue(result.1.contains("超过8秒"),result.1)
        XCTAssertEqual(p.writes.map { $0.1 },[0x69,1]); XCTAssertLessThanOrEqual(p.nowMS-p.startAt!,19000)
    }
    func testSustainedGapAndTransientMotionRemainFatal() {
        for motion in [false,true] {
            let p = RecoveryPort()
            if motion { p.startGaps = [9500..<9740]; p.motionAt = 6000 } else { p.startGaps = [9500..<10200] }
            let result = run(p)
            XCTAssertFalse(result.0)
            XCTAssertTrue(result.1.contains(motion ? "角速度":"500ms"),result.1)
            XCTAssertEqual(p.writes.map { $0.1 },[0x69,1])
        }
    }
    func testCancellationAndDisconnectionDuringRecoveryNeverResume() {
        for cancel in [false,true] {
            let p = RecoveryPort(); p.startGaps = [9500..<9740]
            p.later(11600) { if cancel { p.controller?.cancel("用户取消") } else { p.connected = false } }
            let result = run(p)
            XCTAssertFalse(result.0); XCTAssertTrue(p.phases.contains("recovering_before_save"))
            p.connected = true; p.finished = false; p.run(limit:1000)
            XCTAssertEqual(p.writes.map { $0.1 },[0x69,1])
        }
    }
    func testReadbackFailureAfterSaveRemainsUnverified() {
        let p = RecoveryPort(); p.readbackOK = false
        let result = run(p)
        XCTAssertFalse(result.0); XCTAssertTrue(result.1.contains("已提交保存，回读未通过"))
        XCTAssertEqual(p.writes.map { $0.1 },[0x69,1,0])
    }
    func testGapDuringReadbackAlsoRecoversWithoutReadingOrSavingAgain() {
        let p = RecoveryPort(); p.readbackDelay = 600; p.saveGaps = [3900..<4140]
        let result = run(p)
        XCTAssertTrue(result.0,result.1); XCTAssertTrue(p.phases.contains("recovering_after_save"))
        XCTAssertEqual(p.readbacks,1); XCTAssertEqual(p.writes.map { $0.1 },[0x69,1,0])
        XCTAssertGreaterThanOrEqual(p.nowMS-p.saveAt!,6900)
    }
    func testRepeatedPostSaveGapsTimeOutAndDoNotEraseSaveFact() {
        let p = RecoveryPort(); p.repeatedPostGaps = true
        let result = run(p)
        XCTAssertFalse(result.0); XCTAssertTrue(result.1.contains("已提交保存")); XCTAssertTrue(result.1.contains("超过8秒"))
        XCTAssertEqual(p.writes.map { $0.1 },[0x69,1,0]); XCTAssertEqual(p.readbacks,0)
    }
    func testPoseCheckSeparatesRecoverableEvidenceFromInvalidPose() {
        let empty = PoseWindow().calibrationCheck(now:0)
        XCTAssertFalse(empty.pending.isEmpty); XCTAssertTrue(empty.failures.isEmpty)
        var pose = PoseWindow()
        for i in 0...150 { pose.add(ns:UInt64(i)*20_000_000,acceleration:[0,0.1,1],gyro:[0,0,0]) }
        XCTAssertTrue(pose.calibrationCheck(now:3*secondNS).failures.contains("原始+Z参考姿态不满足门限"))
        pose.add(ns:3*secondNS,acceleration:[.nan,0,1],gyro:[0,0,0])
        XCTAssertTrue(pose.calibrationCheck(now:3*secondNS).failures.contains("静态数据非有限值或时间倒退"))
    }
    func testHistoricalResultProjectionDoesNotInventSuccessOrCoefficients() throws {
        let before: [String:Any] = ["static_mean_g":[0.01,0.06,0.99]]
        let after: [String:Any] = ["static_mean_g":[0.0,0.0,1.0]]
        var d: [String:Any] = ["operation_id":"test","type":"accelerometer_calibration","save_submitted":false,"static_check_passed":false,"fresh_before":before,"after":after]
        var row: [String:Any] = ["type":"operation_result","details":d,"wall_ms":1]
        let failed = try XCTUnwrap(OperationDetail(row))
        XCTAssertFalse(failed.passed); XCTAssertFalse(failed.saveSubmitted); XCTAssertNil(failed.finalWindowPassed)
        XCTAssertEqual(try XCTUnwrap(failed.delta)[1],-0.06,accuracy:1e-9)
        d["save_submitted"] = true; d["static_check_passed"] = true; row["details"] = d
        XCTAssertTrue(try XCTUnwrap(OperationDetail(row)).passed)
        row["type"] = "operation_interrupted"
        XCTAssertFalse(try XCTUnwrap(OperationDetail(row)).passed)
        d.removeValue(forKey:"after"); row["details"] = d
        XCTAssertNil(try XCTUnwrap(OperationDetail(row)).delta)
        row["type"] = "operation_started"; XCTAssertNil(OperationDetail(row))
        d["type"] = "configuration"; d["verified"] = true; row = ["type":"operation_result","details":d]
        let config = try XCTUnwrap(OperationDetail(row)); XCTAssertFalse(config.calibration); XCTAssertTrue(config.passed)
    }
}

/// Synthetic 50 Hz input, including the observed 9.5 s / 240 ms pattern; no real identifiers or recordings.
private final class RecoveryPort: CalibrationPort {
    var nowMS: UInt64 = 3000, connected = true, finished = false
    var startAt: UInt64?, saveAt: UInt64?, writes: [(UInt64,Int)] = [], phases: [String] = []
    var events: [(UInt64,Int,() -> Void)] = [], sequence = 0
    var pose = PoseWindow(), monitor: CalibrationMonitor?, controller: CalibrationController?
    var startGaps: [Range<UInt64>] = [], saveGaps: [Range<UInt64>] = []
    var repeatedGaps = false, repeatedPostGaps = false, motionAt: UInt64?
    var readbackOK = true, readbackDelay: UInt64 = 0, readbacks = 0, resets = 0
    let offsetStep: Bool
    init(offsetStep: Bool = false) {
        self.offsetStep = offsetStep
        for i in 0...150 { pose.add(ns:UInt64(i)*20_000_000,acceleration:[0,offsetStep ? 0.06:0,1],gyro:[0,0,0]) }
    }
    func later(_ ms: UInt64, _ action: @escaping () -> Void) { sequence += 1; events.append((nowMS+ms,sequence,action)) }
    func stableIssues(beforeSave: Bool) -> [String] { pose.issues(now:nowMS*1_000_000,tolerance:0.08) }
    func recoveryCheck() -> CalibrationCheck {
        var check = pose.calibrationCheck(now:nowMS*1_000_000)
        check.failures += monitor?.issues(now:nowMS*1_000_000) ?? ["missing monitor"]
        return check
    }
    func resetVerificationWindow() { resets += 1; pose = PoseWindow() }
    func started() { pose = PoseWindow() }
    func phase(_ name: String) {
        phases.append(name)
        if name == "starting" { monitor = CalibrationMonitor(start:nowMS*1_000_000,initial:pose.mean) }
    }
    func write(_ register: Int, _ value: Int, completion: @escaping (Bool,String) -> Void) {
        writes.append((nowMS,register))
        if register == 1 { startAt = nowMS }; if register == 0 { saveAt = nowMS }
        later(100) { completion(true,"local submission"); completion(true,"duplicate") }
    }
    func verifySaved(_ completion: @escaping (Bool,String) -> Void) {
        readbacks += 1; later(readbackDelay) { completion(self.readbackOK,"readback"); completion(self.readbackOK,"duplicate") }
    }
    func run(limit: UInt64 = 40000) {
        let end = nowMS+limit
        while !finished && nowMS < end {
            nowMS += 20
            let elapsed = startAt.map { nowMS-$0 } ?? 0, savedElapsed = saveAt.map { nowMS-$0 } ?? 0
            let skip = startAt != nil && (startGaps.contains { $0.contains(elapsed) } || (repeatedGaps && elapsed >= 9000 && elapsed%1000 < 220))
                || saveAt != nil && (saveGaps.contains { $0.contains(savedElapsed) } || (repeatedPostGaps && savedElapsed >= 1000 && savedElapsed%1000 < 220))
            if !skip {
                let gyro = [0.0,motionAt == elapsed ? 2:0,0]
                let acc = [0.0,offsetStep && (startAt == nil || elapsed < 9740) ? 0.06:0,1]
                pose.add(ns:nowMS*1_000_000,acceleration:acc,gyro:gyro)
                monitor?.add(nowMS*1_000_000,acceleration:acc,gyro:gyro)
            }
            while true {
                events.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
                guard let event = events.first, event.0 <= nowMS else { break }
                events.removeFirst(); event.2()
            }
        }
    }
}
