import Foundation
import CoreBluetooth
import BaduanjinCore

final class ControlRequest {
    let bytes: Data, register: Int?, generation: UUID, queuedAt: UInt64, settleNS: UInt64, done: (Bool,String) -> Void
    var submittedAt: UInt64 = 0
    init(bytes: Data, register: Int?, generation: UUID, settleNS: UInt64, done: @escaping (Bool,String) -> Void) {
        self.bytes = bytes; self.register = register; self.generation = generation; self.settleNS = settleNS; self.done = done; queuedAt = BluetoothEngine.now()
    }
}
final class BatchState {
    let id = UUID().uuidString, calibrate: Bool, rewrite: Bool, total: Int
    var remaining: [UUID], current: UUID?, operationID = "", generation = UUID(), message = "准备操作", report: [String:Any] = [:]
    var cancelled = false, completed = 0
    init(ids: [UUID], calibrate: Bool, rewrite: Bool) { remaining = ids; total = ids.count; self.calibrate = calibrate; self.rewrite = rewrite }
}
final class IOSCalibrationPort: CalibrationPort {
    weak var engine: BluetoothEngine?
    let link: BluetoothEngine.Link, batchID: String, operationID: String, generation: UUID, orient: Int
    init(engine: BluetoothEngine, link: BluetoothEngine.Link, batch: BatchState, orient: Int) { self.engine = engine; self.link = link; batchID = batch.id; operationID = batch.operationID; generation = link.generation; self.orient = orient }
    var nowMS: UInt64 { BluetoothEngine.now()/1_000_000 }
    var connected: Bool { guard let engine else { return false }; return engine.appActive && engine.batch?.id == batchID && engine.batch?.operationID == operationID && engine.batch?.cancelled == false && link.generation == generation && link.connected && link.initialized && link.wanted && link.maintenance && !link.closing }
    func later(_ milliseconds: UInt64, _ action: @escaping () -> Void) { engine?.work.asyncAfter(deadline:.now()+Double(milliseconds)/1000,execute:action) }
    func stableIssues(beforeSave: Bool) -> [String] {
        var issues = link.pose.issues(now:BluetoothEngine.now(),tolerance:beforeSave ? 0.05:0.08)
        if beforeSave { issues += link.monitor?.issues(now:BluetoothEngine.now()) ?? ["缺少全程静止监测"] }
        return issues
    }
    func recoveryCheck() -> CalibrationCheck {
        let now = BluetoothEngine.now()
        var check = link.pose.calibrationCheck(now:now)
        check.failures += link.monitor?.issues(now:now) ?? ["缺少全程静止监测"]
        return check
    }
    func resetVerificationWindow() { link.pose = PoseWindow() }
    func write(_ register: Int, _ value: Int, completion: @escaping (Bool,String) -> Void) {
        guard connected, let engine else { completion(false,"连接或批次已变化"); return }
        engine.controlWrite(link,register,value,settleMS:100,completion:completion)
    }
    func started() { link.pose = PoseWindow() }
    func phase(_ name: String) {
        guard let engine, engine.batch?.operationID == operationID else { return }
        if name == "starting" { link.monitor = CalibrationMonitor(start:BluetoothEngine.now(),initial:link.pose.mean) }
        if name == "saving_without_second_unlock" { engine.batch?.report["pre_save_mean_g"] = link.pose.mean }
        if name == "recovering_before_save" || name == "recovering_after_save" {
            engine.batch?.report[name+"_entered"] = true
        }
        engine.batch?.message = link.name+"："+["waiting_unlock":"检查姿态","starting":"启动校准","waiting_save":"请继续保持不动，等待保存","recovering_before_save":"等待数据恢复及新的3秒稳定窗口（最多延长8秒），尚未保存","saving_without_second_unlock":"保存前复核通过，提交保存","post_save_verification":"已提交保存，采集新的静态窗口","recovering_after_save":"已提交保存，等待恢复后重新复核（最多延长8秒）","post_save_readback":"稳定窗口通过，回读配置","verified_static":"静态复核通过","failed":"未通过，查看逐台原因"][name,default:name]
        engine.auditOperation("calibration_phase",["phase":name,"elapsed_ns":BluetoothEngine.now()])
    }
    func verifySaved(_ completion: @escaping (Bool,String) -> Void) {
        guard connected, let engine else { completion(false,"保存后连接变化，结果待核验"); return }
        engine.batch?.report["post_wait_mean_g"] = link.pose.mean
        engine.controlReadMany(link,[0x05,0x01,0x03,0x23,0x24,0x96]) { [self] ok,why in
            guard connected else { completion(false,"保存后连接变化，不能确认结果"); return }
            var issues: [String] = []
            if link.registers[0x23] != orient { issues.append("安装方向与操作前不一致") }
            if link.registers[0x96] != 0 { issues.append("惯性输出回读不匹配") }
            if !ok { issues.append(why) }
            completion(issues.isEmpty,issues.isEmpty ? "配置回读通过":issues.joined(separator:"；"))
        }
    }
}

extension BluetoothEngine {
    func controlRead(_ d: Link, _ register: Int, completion: @escaping (Bool,String) -> Void) {
        do { d.controls.append(ControlRequest(bytes:try WitProtocol.read(register),register:register,generation:d.generation,settleNS:0,done:completion)) }
        catch { completion(false,error.localizedDescription) }
    }
    func controlWrite(_ d: Link, _ register: Int, _ value: Int, settleMS: UInt64, completion: @escaping (Bool,String) -> Void) {
        do { d.controls.append(ControlRequest(bytes:try WitProtocol.command(register,value),register:nil,generation:d.generation,settleNS:settleMS*1_000_000,done:completion)) }
        catch { completion(false,error.localizedDescription) }
    }
    func controlReadMany(_ d: Link, _ registers: [Int], completion: @escaping (Bool,String) -> Void) {
        guard let reg = registers.first else { completion(true,"回读完成"); return }
        controlRead(d,reg) { ok,why in if !ok { completion(false,String(format:"寄存器0x%02X：",reg)+why); return }; self.controlReadMany(d,Array(registers.dropFirst()),completion:completion) }
    }
    func completeControl(_ d: Link, _ ok: Bool, _ reason: String) {
        guard let request = d.control else { return }; d.control = nil; request.done(ok,reason)
    }
    func failControls(_ d: Link, _ reason: String) {
        let pending = (d.control.map { [$0] } ?? [])+d.controls; d.control = nil; d.controls = []
        for request in pending { request.done(false,reason) }
    }
    func pumpControl(_ d: Link, _ now: UInt64) -> Bool {
        if d.control == nil, !d.controls.isEmpty { d.control = d.controls.removeFirst() }
        guard let request = d.control else { return false }
        guard request.generation == d.generation, d.connected, d.initialized, appActive, batch != nil, batch?.cancelled == false else { completeControl(d,false,"连接、批次或前台状态变化"); return false }
        if request.submittedAt > 0 {
            if request.register == nil && now-request.submittedAt >= request.settleNS { completeControl(d,true,"已提交并等待；没有传感器执行应答") }
            else if now-request.submittedAt >= 2*secondNS { completeControl(d,false,"回读等待超过2秒") }
            return false
        }
        guard now-request.queuedAt < 3*secondNS else { completeControl(d,false,"等待可写状态超过3秒，未提交"); return false }
        guard d.peripheral.canSendWriteWithoutResponse, let characteristic = d.writer else { return false }
        guard auditOperation("operation_tx_intent",["elapsed_ns":now,"hex":WitProtocol.hex(request.bytes),"peripheral_acknowledged":false]) else { return false }
        request.submittedAt = now
        d.peripheral.writeValue(request.bytes,for:characteristic,type:.withoutResponse)
        if request.register == nil && request.bytes == (try? WitProtocol.command(0,0)) { batch?.report["save_submitted"] = true }
        auditOperation("operation_tx_submitted",["elapsed_ns":Self.now(),"hex":WitProtocol.hex(request.bytes),"submitted_to_corebluetooth":true,"peripheral_acknowledged":false])
        return true
    }
    func receivedControl(_ d: Link, _ frame: WitFrame, _ ns: UInt64) {
        guard let request = d.control, request.submittedAt > 0, ns >= request.submittedAt, request.generation == d.generation, request.register == frame.register else { return }
        guard auditOperation("operation_readback",["elapsed_ns":ns,"register":frame.register,"packet_hex":WitProtocol.hex(frame.bytes),"words":frame.words]) else { return }
        completeControl(d,true,"已收到寄存器回包")
    }
    @discardableResult func auditOperation(_ type: String, _ value: [String:Any]) -> Bool {
        guard let root, let b = batch else { return false }
        var details = value; details["batch_id"] = b.id; details["operation_id"] = b.operationID
        if let id = b.current { details["address"] = id.uuidString }
        do { try OperationAudit.append(root:root,type:type,details:details,at:Self.wall()); return true }
        catch { abortOperations("操作审计写入失败："+error.localizedDescription,audit:false); return false }
    }
    func operationRaw(_ d: Link, _ bytes: Data, _ ns: UInt64) { auditOperation("operation_raw",["elapsed_ns":ns,"hex":WitProtocol.hex(bytes)]) }
    func operationSnapshot(_ d: Link) -> [String:Any] {
        ["firmware":d.firmware,"generation":d.generation.uuidString,"connected":d.connected,"initialized":d.initialized,"registers":Dictionary(uniqueKeysWithValues:d.registers.map { (String($0.key),$0.value) }),"settings":Dictionary(uniqueKeysWithValues:d.settings.map { (String($0.key),$0.value) }),"static_mean_g":d.pose.mean]
    }
    func beginBatch(calibrate: Bool, rewrite: Bool = false, placementConfirmed: Bool = false) { work.async {
        defer { self.notifyRequestFinished() }
        guard self.idle(), self.appActive, !self.passive, let root = self.root else { self.message = "请保持前台，结束其他操作并正常连接设备"; return }
        guard !calibrate || placementConfirmed else { self.message = "先确认原始+Z朝上放稳及全组保持时长"; return }
        let selected = self.links.values.filter(\.wanted).sorted { $0.name < $1.name }
        guard !selected.isEmpty else { self.message = "没有选定设备"; return }
        guard selected.allSatisfy({ !$0.initialized || ($0.reading == nil && $0.reads.isEmpty) }) else { self.message = "请等待当前配置回读完成，再启动批量操作"; return }
        let b = BatchState(ids:selected.map { $0.peripheral.identifier },calibrate:calibrate,rewrite:rewrite)
        do { _ = try OperationAudit.read(root:root); try OperationAudit.append(root:root,type:"operation_batch_started",details:["batch_id":b.id,"type":calibrate ? "accelerometer_calibration":"configuration","addresses":selected.map { $0.peripheral.identifier.uuidString },"rewrite":rewrite],at:Self.wall()) }
        catch { self.message = "审计无法保存，操作未启动："+error.localizedDescription; return }
        self.batch = b; self.operationResults = []
        for d in selected { d.maintenance = true; d.goodSince = 0 }
        self.nextOperation()
    } }
    func nextOperation() {
        guard let b = batch else { return }
        guard !b.cancelled, !b.remaining.isEmpty else { finishBatch(); return }
        let id = b.remaining.removeFirst(); b.current = id; b.operationID = UUID().uuidString
        guard let d = links[id] else { finishOperation(false,"设备状态缺失"); return }
        b.generation = d.generation; b.message = "第\(b.completed+1)/\(b.total)台 · \(d.name) · 读取旧值"
        b.report = ["operation_id":b.operationID,"batch_id":b.id,"address":id.uuidString,"name":d.name,"type":b.calibrate ? "accelerometer_calibration":"configuration","before":operationSnapshot(d),"started_ns":Self.now(),"rewrite":b.rewrite,"save_submitted":false,"internal_calibration_completion_known":false,"write_completion_meaning":"local_submission_and_settling_not_peripheral_acknowledgement"]
        b.report["calibration_policy"] = "bounded_stable_window_recovery_v2"
        b.report["recovery_limit_ms_per_stage"] = CalibrationController.recoveryLimitMS
        guard auditOperation("operation_started",b.report) else { return }
        guard d.connected && d.initialized && d.wanted && !d.closing else { finishOperation(false,"未执行：设备尚未就绪"); return }
        guard WitProtocol.supportedFirmware(d.firmware) else { finishOperation(false,"未执行：仅支持已核实固件10080.1.21 / 10080.1.22"); return }
        let operationID = b.operationID
        controlReadMany(d,[3,0x23,0x24,0x96,0x05,0x01]) { ok,why in
            guard self.batch === b, b.operationID == operationID else { return }
            guard ok, !b.cancelled, d.generation == b.generation, d.registers[0x96] == 0 else { self.finishOperation(false,"旧值回读未通过："+why); return }
            b.report["fresh_before"] = self.operationSnapshot(d)
            if b.calibrate {
                let port = IOSCalibrationPort(engine:self,link:d,batch:b,orient:d.registers[0x23] ?? -1)
                self.calibration = CalibrationController(port:port) { ok,why in guard self.batch === b, b.operationID == operationID else { return }; self.finishOperation(ok,why) }
                self.calibration?.begin()
            } else {
                do {
                    let plan = try ConfigurationPlan(registers:d.registers,rewrite:b.rewrite)
                    if plan.commands.isEmpty { self.finishOperation(plan.matches(d.registers),"回读已符合50Hz/九轴模板，无需写入"); return }
                    self.applyConfiguration(d,plan:plan,index:0,operationID:operationID)
                } catch { self.finishOperation(false,error.localizedDescription) }
            }
        }
    }
    func applyConfiguration(_ d: Link, plan: ConfigurationPlan, index: Int, operationID: String) {
        guard let b = batch, b.operationID == operationID, !b.cancelled, d.generation == b.generation else { return }
        if index == plan.commands.count {
            controlReadMany(d,[3,0x24,0x23,0x96]) { ok,why in
                guard self.batch?.operationID == operationID else { return }
                let matches = ok && plan.matches(d.registers)
                self.finishOperation(matches,matches ? "配置写入及回读匹配，安装方向保留":"已提交配置，回读不匹配："+why)
            }; return
        }
        let command = plan.commands[index]
        b.message = "\(d.name)：应用50Hz/九轴模板，保留安装方向"
        controlWrite(d,command.0,command.1,settleMS:command.0 == 0 ? 500:50) { ok,why in
            guard self.batch?.operationID == operationID else { return }
            if !ok { self.finishOperation(false,why); return }
            self.applyConfiguration(d,plan:plan,index:index+1,operationID:operationID)
        }
    }
    func finishOperation(_ ok: Bool, _ why: String, audit: Bool = true) {
        guard let b = batch, let id = b.current else { return }
        var report = b.report; report["result"] = why; report["verified"] = ok && !b.calibrate; report["static_check_passed"] = b.calibrate ? ok : false; report["ended_ns"] = Self.now()
        if let d = links[id] {
            report["after"] = operationSnapshot(d)
            if b.calibrate {
                report["final_window_issues"] = d.pose.issues(now:Self.now(),tolerance:0.05)
                report["final_window_passed"] = d.pose.issues(now:Self.now(),tolerance:0.05).isEmpty
            }
            if let m = d.monitor { report["motion_monitor"] = ["samples":m.count,"max_gap_ms":m.maxGapMS,"max_gyro_dps":m.maxGyro,"max_accel_change_g":m.maxDeviation] }
            d.monitor = nil; d.lastOperation = why
        }
        if audit, let root {
            do {
                let at = Self.wall()
                try OperationAudit.append(root:root,type:"operation_result",details:report,at:at)
                let row: [String:Any] = ["type":"operation_result","wall_ms":at,"details":report]
                DispatchQueue.main.async { self.onOperationResult?(row) }
            }
            catch { b.cancelled = true; message = "结果审计保存失败："+error.localizedDescription }
        }
        operationResults.append((links[id]?.name ?? id.uuidString)+"："+why)
        b.current = nil; b.operationID = ""; b.completed += 1; calibration = nil
        if b.cancelled { finishBatch() } else { work.asyncAfter(deadline:.now()+0.25) { guard self.batch === b else { return }; self.nextOperation() } }
    }
    func finishBatch() {
        guard let b = batch else { return }
        for id in b.remaining { if let d = links[id] { d.lastOperation = "本批后续操作已取消，未执行"; operationResults.append(d.name+"："+d.lastOperation) } }
        for d in links.values { d.maintenance = false; d.monitor = nil; d.readyAt = Self.now(); d.goodSince = 0; d.lowSince = [0,0,0,0]; d.recent = (0..<4).map { _ in RecentStream() }; d.scheduler = QueryScheduler() }
        if let root { try? OperationAudit.append(root:root,type:"operation_batch_finished",details:["batch_id":b.id,"cancelled":b.cancelled,"completed":b.completed,"total":b.total],at:Self.wall()) }
        batch = nil; calibration = nil; message = b.cancelled ? "批量操作已停止，请核对逐台结果；已提交指令不会自动撤销":"批量操作结束，请查看逐台结果；正在重新检查连续数据"
        DispatchQueue.main.async { self.onOperationFinished?() }; notifyRequestFinished()
    }
    func abortOperations(_ reason: String, audit: Bool = true) {
        guard let b = batch else { return }; b.cancelled = true
        let controller = calibration; calibration = nil
        if !audit { finishOperation(false,reason,audit:false) }
        controller?.cancel(reason)
        for d in links.values { failControls(d,reason) }
        if batch === b { if b.current != nil { finishOperation(false,reason,audit:audit) } else { finishBatch() } }
    }
    func cancelBatch() { work.async { self.abortOperations("用户取消后续操作；已提交的硬件指令状态需核验") } }
}
