import XCTest
@testable import BaduanjinCore

final class ParallelCalibrationTests: XCTestCase {
    func testAllFifteenStartBeforeAnySaveAndKeepIndependentTiming() throws {
        let clock = BatchClock(), ports = (0..<15).map { BatchPort($0,clock:clock) }
        for (i,p) in ports.enumerated() { p.prepareDelay = UInt64(i)*10; p.duplicate = true }
        var rows: [String:CalibrationOutcome] = [:], ended = 0
        let batch = try ParallelCalibration(entries:ports.map { ($0.id,$0) },result:{ rows[$0] = $1 },completed:{ ended += 1 })
        batch.start(); batch.start(); clock.drain()
        XCTAssertEqual(ended,1); XCTAssertEqual(rows.count,15); XCTAssertTrue(rows.values.allSatisfy(\.passed))
        let starts = ports.map { p in p.writes.first { $0.1 == 1 }!.0 }
        let saves = ports.map { p in p.writes.first { $0.1 == 0 }!.0 }
        XCTAssertLessThan(starts.max()!,saves.min()!)
        XCTAssertLessThan(saves.max()!-saves.min()!,500)
        for p in ports {
            XCTAssertEqual(p.writes.map { $0.1 },[0x69,1,0]); XCTAssertEqual(p.readbacks,1)
            XCTAssertGreaterThanOrEqual(p.writes[2].0-p.writes[1].0,10800)
        }
    }
    func testMixedFailuresDoNotStopOtherDevicesOrMixTheirSaveStates() throws {
        let clock = BatchClock(), ports = (0..<15).map { BatchPort($0,clock:clock) }
        ports[0].prepareOK = false; ports[1].badBefore = true; ports[2].badDuring = true
        ports[3].failedWrite = 1; ports[4].readbackOK = false
        var rows: [String:CalibrationOutcome] = [:], ended = 0
        let batch = try ParallelCalibration(entries:ports.map { ($0.id,$0) },result:{ rows[$0] = $1 },completed:{ ended += 1 })
        batch.start(); clock.drain()
        XCTAssertEqual(ended,1); XCTAssertEqual(rows.count,15)
        for i in 0..<5 { XCTAssertEqual(rows[ports[i].id]?.passed,false) }
        XCTAssertTrue(ports[0].writes.isEmpty); XCTAssertTrue(ports[1].writes.isEmpty)
        for i in 2...3 { XCTAssertFalse(ports[i].writes.contains { $0.1 == 0 }) }
        XCTAssertTrue(ports[4].writes.contains { $0.1 == 0 })
        for i in 5..<15 { XCTAssertEqual(rows[ports[i].id]?.passed,true); XCTAssertEqual(ports[i].writes.map { $0.1 },[0x69,1,0]) }
    }
    func testSlowPreparationAndRecoveryDoNotDelayHealthySaves() throws {
        let clock = BatchClock(), ports = (0..<15).map { BatchPort($0,clock:clock) }
        ports[0].prepareDelay = 5000; ports[1].recoverUntil = 16000
        var completed: [String:UInt64] = [:]
        let batch = try ParallelCalibration(entries:ports.map { ($0.id,$0) },result:{ id,outcome in XCTAssertTrue(outcome.passed); completed[id] = clock.now },completed:{})
        batch.start(); clock.drain()
        let fast = ports[2].writes.first { $0.1 == 0 }!.0
        XCTAssertLessThan(fast,ports[0].writes.first { $0.1 == 0 }!.0)
        XCTAssertLessThan(fast,ports[1].writes.first { $0.1 == 0 }!.0)
        XCTAssertLessThan(completed[ports[2].id]!,completed[ports[0].id]!)
        XCTAssertEqual(batch.outcomes.count,15)
    }
    func testDisconnectedDeviceCannotResumeAfterReconnectOrLateCallbacks() throws {
        let clock = BatchClock(), ports = (0..<15).map { BatchPort($0,clock:clock) }
        var rows: [String:CalibrationOutcome] = [:]
        let batch = try ParallelCalibration(entries:ports.map { ($0.id,$0) },result:{ rows[$0] = $1 },completed:{})
        batch.start()
        clock.later(2000) { ports[7].connected = false; batch.cancelDevice(ports[7].id,reason:"device disconnected") }
        clock.later(4000) { ports[7].connected = true }
        clock.drain()
        XCTAssertEqual(rows[ports[7].id]?.passed,false); XCTAssertEqual(ports[7].writes.map { $0.1 },[0x69,1])
        XCTAssertEqual(rows.values.filter(\.passed).count,14)
        batch.cancelDevice(ports[7].id,reason:"late duplicate"); XCTAssertEqual(rows.count,15)
    }
    func testCancelWholeBatchAfterSomeSavesRetainsEachIndependentOutcome() throws {
        let clock = BatchClock(), ports = (0..<15).map { BatchPort($0,clock:clock) }
        ports[0].recoverUntil = 17000
        var rows: [String:CalibrationOutcome] = [:], ended = 0
        let batch = try ParallelCalibration(entries:ports.map { ($0.id,$0) },result:{ rows[$0] = $1 },completed:{ ended += 1 })
        batch.start(); clock.later(12000) { batch.cancelAll("global cancellation") }; clock.drain()
        XCTAssertEqual(ended,1); XCTAssertEqual(rows.count,15); XCTAssertEqual(rows.values.filter(\.passed).count,0)
        XCTAssertFalse(ports[0].writes.contains { $0.1 == 0 })
        for p in ports.dropFirst() { XCTAssertEqual(p.writes.map { $0.1 },[0x69,1,0]) }
    }
    func testReentrantGlobalFailureDuringFirstPreparationCompletesEveryDeviceOnce() throws {
        let clock = BatchClock(), ports = (0..<15).map { BatchPort($0,clock:clock) }
        ports[0].prepareOK = false; ports[0].synchronousPrepare = true
        var ids: [String] = [], ended = 0
        var batch: ParallelCalibration!
        batch = try ParallelCalibration(entries:ports.map { ($0.id,$0) },result:{ id,_ in ids.append(id); if id == ports[0].id { batch.cancelAll("shared journal failed") } },completed:{ ended += 1 })
        batch.start(); clock.drain()
        XCTAssertEqual(ids.count,15); XCTAssertEqual(Set(ids).count,15); XCTAssertEqual(ended,1)
        XCTAssertTrue(ports.allSatisfy { $0.writes.isEmpty })
    }
    func testAdmissionRejectsDuplicateEmptyAndOversizedBatch() {
        let clock = BatchClock(), port = BatchPort(0,clock:BatchClock())
        XCTAssertThrowsError(try ParallelCalibration(entries:[],result:{ _,_ in },completed:{}))
        XCTAssertThrowsError(try ParallelCalibration(entries:[("one",port),("one",port)],result:{ _,_ in },completed:{}))
        let ports = (0..<16).map { BatchPort($0,clock:clock) }
        XCTAssertThrowsError(try ParallelCalibration(entries:ports.map { ($0.id,$0) },result:{ _,_ in },completed:{}))
    }
    func testInterleavedFifteenDeviceJournalAndCrashRecoveryKeepSaveOwnership() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let journal = try OperationJournal(root:root)
        for i in 0..<15 {
            try journal.append(type:"operation_started",details:["operation_id":"op\(i)","batch_id":"batch","address":"device\(i)","type":"accelerometer_calibration","save_submitted":false],at:1)
        }
        for round in 0..<30 { for i in (0..<15).reversed() {
            try journal.append(type:"operation_raw",details:["operation_id":"op\(i)","batch_id":"batch","address":"device\(i)","round":round,"hex":"5561"],at:2)
        } }
        for i in 0..<15 where i%2 == 0 {
            try journal.append(type:"operation_tx_submitted",details:["operation_id":"op\(i)","batch_id":"batch","address":"device\(i)","hex":"FFAA000000"],at:3)
        }
        try journal.close(); try journal.close()
        XCTAssertThrowsError(try journal.append(type:"late",details:[:],at:4))
        let original = try Data(contentsOf:root.appendingPathComponent("operations.jsonl"))
        try OperationAudit.recover(root:root,at:5); try OperationAudit.recover(root:root,at:6)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("operations.jsonl")).prefix(original.count),original)
        let rows = try OperationAudit.read(root:root)
        let interrupted = rows.filter { $0["type"] as? String == "operation_interrupted" }
        XCTAssertEqual(interrupted.count,15)
        for row in interrupted {
            let d = try XCTUnwrap(row["details"] as? [String:Any]), id = try XCTUnwrap(d["operation_id"] as? String)
            let i = try XCTUnwrap(Int(id.dropFirst(2)))
            XCTAssertEqual(d["address"] as? String,"device\(i)")
            XCTAssertEqual(d["save_submitted"] as? Bool,i%2 == 0)
            XCTAssertFalse(try XCTUnwrap(OperationDetail(row)).passed)
        }
    }
}

private final class BatchClock {
    var now: UInt64 = 0, serial = 0
    var events: [(UInt64,Int,() -> Void)] = []
    func later(_ ms: UInt64, _ action: @escaping () -> Void) { serial += 1; events.append((now+ms,serial,action)) }
    func drain() {
        var n = 0
        while !events.isEmpty && n < 10000 {
            events.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
            let event = events.removeFirst(); now = event.0; event.2(); n += 1
        }
        XCTAssertLessThan(n,10000)
    }
}
private final class BatchPort: PreparedCalibrationPort {
    let id: String, clock: BatchClock
    var connected = true, prepareOK = true, readbackOK = true, duplicate = false, synchronousPrepare = false
    var badBefore = false, badDuring = false, failedWrite: Int?
    var prepareDelay: UInt64 = 0, recoverUntil: UInt64 = 0, writes: [(UInt64,Int)] = [], readbacks = 0
    init(_ id: Int, clock: BatchClock) { self.id = "device\(id)"; self.clock = clock }
    var nowMS: UInt64 { clock.now }
    func later(_ ms: UInt64, _ action: @escaping () -> Void) { clock.later(ms,action) }
    func prepare(_ completion: @escaping (Bool,String) -> Void) {
        let action = { completion(self.prepareOK,"old values"); if self.duplicate { completion(self.prepareOK,"duplicate") } }
        if synchronousPrepare { action() } else { later(prepareDelay,action) }
    }
    func stableIssues(beforeSave: Bool) -> [String] { badBefore ? ["pose"]:[] }
    func recoveryCheck() -> CalibrationCheck { CalibrationCheck(pending:nowMS < recoverUntil ? ["recovering window"]:[],failures:badDuring ? ["motion"]:[]) }
    func resetVerificationWindow() {}
    func write(_ register: Int, _ value: Int, completion: @escaping (Bool,String) -> Void) {
        writes.append((nowMS,register)); later(100) {
            completion(self.failedWrite != register,"local write result")
            if self.duplicate { completion(self.failedWrite != register,"duplicate") }
        }
    }
    func started() {}
    func phase(_ name: String) {}
    func verifySaved(_ completion: @escaping (Bool,String) -> Void) {
        readbacks += 1; later(100) { completion(self.readbackOK,"readback"); if self.duplicate { completion(self.readbackOK,"duplicate") } }
    }
}
