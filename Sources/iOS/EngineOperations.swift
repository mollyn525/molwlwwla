import Foundation
import CoreBluetooth
import BaduanjinCore

final class DeviceOperation {
    let id = UUID().uuidString, batchID: String, deviceID: UUID, generation: UUID, name: String, calibrate: Bool
    var started = false, finished = false, passed = false, startedNS: UInt64 = 0
    var message = "等待准备", report: [String:Any] = [:]
    var active: Bool { started && !finished }
    init(_ link: BluetoothEngine.Link, batchID: String, calibrate: Bool) {
        self.batchID = batchID; deviceID = link.peripheral.identifier; generation = link.generation
        name = link.name; self.calibrate = calibrate
    }
}
final class ControlRequest {
    let bytes: Data, register: Int?, operation: DeviceOperation, queuedAt: UInt64, settleNS: UInt64, done: (Bool,String) -> Void
    var submittedAt: UInt64 = 0
    init(bytes: Data, register: Int?, operation: DeviceOperation, settleNS: UInt64, done: @escaping (Bool,String) -> Void) {
        self.bytes = bytes; self.register = register; self.operation = operation; self.settleNS = settleNS
        self.done = done; queuedAt = BluetoothEngine.now()
    }
}
final class BatchState {
    let id = UUID().uuidString, calibrate: Bool, rewrite: Bool, order: [UUID], journal: OperationJournal
    var operations: [UUID:DeviceOperation] = [:], remaining: [UUID], coordinator: ParallelCalibration?
    var cancelled = false, auditFailed = false, finishing = false
    var completed: Int { operations.values.filter(\.finished).count }
    var message: String {
        if calibrate { return "并行校准：\(completed)/\(order.count)台结束 · 通过\(operations.values.filter(\.passed).count)台；请保持全组不动" }
        return operations.values.first(where: \.active).map { $0.name+"："+$0.message } ?? "配置：\(completed)/\(order.count)台结束"
    }
    init(links: [BluetoothEngine.Link], calibrate: Bool, rewrite: Bool, journal: OperationJournal) {
        self.calibrate = calibrate; self.rewrite = rewrite; self.journal = journal
        order = links.map { $0.peripheral.identifier }; remaining = calibrate ? []:order
        for link in links { operations[link.peripheral.identifier] = DeviceOperation(link,batchID:id,calibrate:calibrate) }
    }
}
final class IOSCalibrationPort: PreparedCalibrationPort {
    weak var engine: BluetoothEngine?
    let link: BluetoothEngine.Link, operation: DeviceOperation
    private var orient = -1
    init(engine: BluetoothEngine, link: BluetoothEngine.Link, operation: DeviceOperation) {
        self.engine = engine; self.link = link; self.operation = operation
    }
    var nowMS: UInt64 { BluetoothEngine.now()/1_000_000 }
    var connected: Bool { engine?.operationActive(operation,link:link) == true }
    func later(_ milliseconds: UInt64, _ action: @escaping () -> Void) { engine?.work.asyncAfter(deadline:.now()+Double(milliseconds)/1000,execute:action) }
    func prepare(_ completion: @escaping (Bool,String) -> Void) {
        guard let engine else { completion(false,"采集服务不可用"); return }
        engine.prepareOperation(operation) { [self] ok,why in
            if ok { orient = link.registers[0x23] ?? -1 }
            completion(ok,why)
        }
    }
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
        guard connected, let engine else { completion(false,"该设备连接或操作已变化"); return }
        engine.controlWrite(link,operation,register,value,settleMS:100,completion:completion)
    }
    func started() { link.pose = PoseWindow() }
    func phase(_ name: String) {
        guard let engine, engine.batch?.id == operation.batchID, !operation.finished else { return }
        if name == "starting" { link.monitor = CalibrationMonitor(start:BluetoothEngine.now(),initial:link.pose.mean) }
        if name == "saving_without_second_unlock" { operation.report["pre_save_mean_g"] = link.pose.mean }
        if name == "recovering_before_save" || name == "recovering_after_save" { operation.report[name+"_entered"] = true }
        operation.message = ["waiting_unlock":"检查姿态","starting":"启动校准","waiting_save":"保持不动，独立等待保存",
            "recovering_before_save":"等待数据恢复及新的3秒稳定窗口（最多延长8秒），尚未保存",
            "saving_without_second_unlock":"复核通过，提交保存","post_save_verification":"已提交保存，采集新的静态窗口",
            "recovering_after_save":"已提交保存，等待恢复后复核（最多延长8秒）","post_save_readback":"稳定窗口通过，回读配置",
            "verified_static":"保存后静态复核通过","failed":"未通过，查看原因"][name,default:name]
        engine.auditOperation(operation,"calibration_phase",["phase":name,"elapsed_ns":BluetoothEngine.now()])
    }
    func verifySaved(_ completion: @escaping (Bool,String) -> Void) {
        guard connected, let engine else { completion(false,"保存后连接变化，结果待核验"); return }
        operation.report["post_wait_mean_g"] = link.pose.mean
        engine.controlReadMany(link,operation,[0x05,0x01,0x03,0x23,0x24,0x96]) { [self] ok,why in
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
    func operationActive(_ op: DeviceOperation, link: Link) -> Bool {
        guard let b = batch else { return false }
        return b.id == op.batchID && b.operations[link.peripheral.identifier] === op && op.active && !b.cancelled &&
            appActive && link.generation == op.generation && link.connected && link.initialized && link.subscribed &&
            link.wanted && link.maintenance && !link.closing && link.writer != nil
    }
    func controlRead(_ d: Link, _ op: DeviceOperation, _ register: Int, completion: @escaping (Bool,String) -> Void) {
        guard operationActive(op,link:d) else { completion(false,"该设备操作或连接已变化"); return }
        do { d.controls.append(ControlRequest(bytes:try WitProtocol.read(register),register:register,operation:op,settleNS:0,done:completion)) }
        catch { completion(false,error.localizedDescription) }
    }
    func controlWrite(_ d: Link, _ op: DeviceOperation, _ register: Int, _ value: Int, settleMS: UInt64, completion: @escaping (Bool,String) -> Void) {
        guard operationActive(op,link:d) else { completion(false,"该设备操作或连接已变化"); return }
        do { d.controls.append(ControlRequest(bytes:try WitProtocol.command(register,value),register:nil,operation:op,settleNS:settleMS*1_000_000,done:completion)) }
        catch { completion(false,error.localizedDescription) }
    }
    func controlReadMany(_ d: Link, _ op: DeviceOperation, _ registers: [Int], completion: @escaping (Bool,String) -> Void) {
        guard operationActive(op,link:d) else { completion(false,"该设备操作或连接已变化"); return }
        guard let reg = registers.first else { completion(true,"回读完成"); return }
        controlRead(d,op,reg) { ok,why in
            if !ok { completion(false,String(format:"寄存器0x%02X：",reg)+why); return }
            self.controlReadMany(d,op,Array(registers.dropFirst()),completion:completion)
        }
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
        let op = request.operation
        guard operationActive(op,link:d) else { completeControl(d,false,"该设备连接、批次或前台状态变化"); return false }
        if request.submittedAt > 0 {
            if request.register == nil && now-request.submittedAt >= request.settleNS { completeControl(d,true,"已提交并等待；没有传感器执行应答") }
            else if now-request.submittedAt >= 2*secondNS { completeControl(d,false,"该设备回读等待超过2秒") }
            return false
        }
        guard now-request.queuedAt < 3*secondNS else { completeControl(d,false,"该设备等待可写状态超过3秒，未提交"); return false }
        guard d.peripheral.canSendWriteWithoutResponse, let characteristic = d.writer else { return false }
        guard auditOperation(op,"operation_tx_intent",["elapsed_ns":now,"hex":WitProtocol.hex(request.bytes),"peripheral_acknowledged":false]) else { return false }
        request.submittedAt = Self.now()
        d.peripheral.writeValue(request.bytes,for:characteristic,type:.withoutResponse)
        if request.register == nil && request.bytes == (try? WitProtocol.command(0,0)) { op.report["save_submitted"] = true }
        if request.register == nil && request.bytes == (try? WitProtocol.command(1,1)) { op.report["calibration_start_submitted_ns"] = request.submittedAt }
        auditOperation(op,"operation_tx_submitted",["elapsed_ns":Self.now(),"hex":WitProtocol.hex(request.bytes),"submitted_to_corebluetooth":true,"peripheral_acknowledged":false])
        return true
    }
    func receivedControl(_ d: Link, _ frame: WitFrame, _ ns: UInt64) {
        guard let request = d.control, operationActive(request.operation,link:d), request.submittedAt > 0,
              ns >= request.submittedAt, request.register == frame.register else { return }
        guard auditOperation(request.operation,"operation_readback",["elapsed_ns":ns,"register":frame.register,"packet_hex":WitProtocol.hex(frame.bytes),"words":frame.words]) else { return }
        completeControl(d,true,"已收到该设备寄存器回包")
    }
    @discardableResult func auditOperation(_ op: DeviceOperation, _ type: String, _ value: [String:Any]) -> Bool {
        guard let b = batch, b.id == op.batchID, b.operations[op.deviceID] === op, !b.auditFailed else { return false }
        var details = value; details["batch_id"] = op.batchID; details["operation_id"] = op.id; details["address"] = op.deviceID.uuidString
        do { try b.journal.append(type:type,details:details,at:Self.wall()); return true }
        catch { b.auditFailed = true; abortOperations("操作审计写入失败，整个批次停止："+error.localizedDescription,audit:false); return false }
    }
    func operationRaw(_ d: Link, _ bytes: Data, _ ns: UInt64) {
        guard let op = batch?.operations[d.peripheral.identifier], op.active, op.generation == d.generation else { return }
        auditOperation(op,"operation_raw",["elapsed_ns":ns,"hex":WitProtocol.hex(bytes)])
    }
    func operationSnapshot(_ d: Link) -> [String:Any] {
        ["firmware":d.firmware,"generation":d.generation.uuidString,"connected":d.connected,"initialized":d.initialized,
         "registers":Dictionary(uniqueKeysWithValues:d.registers.map { (String($0.key),$0.value) }),
         "settings":Dictionary(uniqueKeysWithValues:d.settings.map { (String($0.key),$0.value) }),"static_mean_g":d.pose.mean]
    }
    func beginBatch(calibrate: Bool, rewrite: Bool = false, placementConfirmed: Bool = false) { work.async {
        defer { self.notifyRequestFinished() }
        guard self.idle(), self.appActive, !self.passive, let root = self.root else { self.message = "请保持前台，结束其他操作并正常连接设备"; return }
        guard !calibrate || placementConfirmed else { self.message = "先确认原始+Z朝上放稳及全组保持时长"; return }
        let selected = self.links.values.filter(\.wanted).sorted { $0.name < $1.name }
        guard !selected.isEmpty, selected.count <= 15 else { self.message = "请选择1–15台设备"; return }
        let b: BatchState
        do {
            _ = try OperationAudit.read(root:root)
            b = BatchState(links:selected,calibrate:calibrate,rewrite:rewrite,journal:try OperationJournal(root:root))
            try b.journal.append(type:"operation_batch_started",details:["batch_id":b.id,"type":calibrate ? "accelerometer_calibration":"configuration",
                "addresses":b.order.map(\.uuidString),"rewrite":rewrite,"execution_mode":calibrate ? "parallel_per_device_v1":"sequential_configuration"],at:Self.wall())
        } catch { self.message = "审计无法保存，操作未启动："+error.localizedDescription; return }
        self.batch = b; self.operationResults = []
        for d in selected { d.maintenance = true; d.goodSince = 0 }
        if calibrate {
            let entries: [(String,PreparedCalibrationPort)] = selected.map { d in
                (d.peripheral.identifier.uuidString,IOSCalibrationPort(engine:self,link:d,operation:b.operations[d.peripheral.identifier]!))
            }
            do {
                b.coordinator = try ParallelCalibration(entries:entries,result:{ [weak self,weak b] id,outcome in
                    guard let self, let b, self.batch === b, let uuid = UUID(uuidString:id), let op = b.operations[uuid] else { return }
                    self.finishOperation(op,outcome.passed,outcome.reason)
                },completed:{ [weak self,weak b] in
                    guard let self, let b, self.batch === b else { return }; self.finishBatch()
                })
                b.coordinator?.start()
            } catch { self.abortOperations(error.localizedDescription) }
        } else { self.nextConfiguration() }
    } }
    func prepareOperation(_ op: DeviceOperation, completion: @escaping (Bool,String) -> Void) {
        guard let b = batch, b.id == op.batchID, !b.cancelled, !op.started, !op.finished, let d = links[op.deviceID] else { completion(false,"设备状态或批次已变化"); return }
        op.started = true; op.startedNS = Self.now(); op.message = "读取本台旧值"
        op.report = ["operation_id":op.id,"batch_id":op.batchID,"address":op.deviceID.uuidString,"name":op.name,
            "type":op.calibrate ? "accelerometer_calibration":"configuration","before":operationSnapshot(d),"started_ns":op.startedNS,
            "rewrite":b.rewrite,"save_submitted":false,"internal_calibration_completion_known":false,
            "write_completion_meaning":"local_submission_and_settling_not_peripheral_acknowledgement",
            "execution_mode":op.calibrate ? "parallel_per_device_v1":"sequential_configuration"]
        if op.calibrate { op.report["calibration_policy"] = "bounded_stable_window_recovery_v2"; op.report["recovery_limit_ms_per_stage"] = CalibrationController.recoveryLimitMS }
        guard auditOperation(op,"operation_started",op.report) else { return }
        guard operationActive(op,link:d) else { completion(false,"未执行：该设备尚未就绪或连接已变化"); return }
        guard d.reading == nil, d.reads.isEmpty else { completion(false,"未执行：该设备当前配置回读尚未结束"); return }
        guard WitProtocol.supportedFirmware(d.firmware) else { completion(false,"未执行：仅支持已核实固件10080.1.21 / 10080.1.22"); return }
        controlReadMany(d,op,[3,0x23,0x24,0x96,0x05,0x01]) { ok,why in
            guard self.operationActive(op,link:d) else { completion(false,"该设备操作或连接已变化"); return }
            guard ok, d.registers[0x96] == 0 else { completion(false,"旧值回读未通过："+why); return }
            op.report["fresh_before"] = self.operationSnapshot(d); completion(true,"旧值已独立回读")
        }
    }
    func nextConfiguration() {
        guard let b = batch, !b.calibrate else { return }
        guard !b.cancelled, !b.remaining.isEmpty else { finishBatch(); return }
        let id = b.remaining.removeFirst()
        guard let op = b.operations[id], let d = links[id] else { abortOperations("配置设备状态缺失"); return }
        prepareOperation(op) { ok,why in
            guard self.batch === b, !op.finished else { return }
            guard ok else { self.finishOperation(op,false,why); return }
            do {
                let plan = try ConfigurationPlan(registers:d.registers,rewrite:b.rewrite)
                if plan.commands.isEmpty { self.finishOperation(op,plan.matches(d.registers),"回读已符合50Hz/九轴模板，无需写入"); return }
                self.applyConfiguration(d,op,plan:plan,index:0)
            } catch { self.finishOperation(op,false,error.localizedDescription) }
        }
    }
    func applyConfiguration(_ d: Link, _ op: DeviceOperation, plan: ConfigurationPlan, index: Int) {
        guard operationActive(op,link:d) else { failOperation(op.deviceID,"该设备配置连接已变化"); return }
        if index == plan.commands.count {
            controlReadMany(d,op,[3,0x24,0x23,0x96]) { ok,why in
                guard !op.finished else { return }
                let matches = ok && plan.matches(d.registers)
                self.finishOperation(op,matches,matches ? "配置写入及回读匹配，安装方向保留":"已提交配置，回读不匹配："+why)
            }; return
        }
        let command = plan.commands[index]; op.message = "应用50Hz/九轴模板，保留安装方向"
        controlWrite(d,op,command.0,command.1,settleMS:command.0 == 0 ? 500:50) { ok,why in
            guard !op.finished else { return }
            if !ok { self.finishOperation(op,false,why); return }
            self.applyConfiguration(d,op,plan:plan,index:index+1)
        }
    }
    func finishOperation(_ op: DeviceOperation, _ ok: Bool, _ why: String) {
        guard let b = batch, b.id == op.batchID, !op.finished else { return }
        op.finished = true; op.passed = ok; op.message = why
        var report = op.report
        report["operation_id"] = op.id; report["batch_id"] = op.batchID; report["address"] = op.deviceID.uuidString
        report["name"] = op.name; report["type"] = op.calibrate ? "accelerometer_calibration":"configuration"
        report["result"] = why; report["verified"] = ok && !op.calibrate; report["static_check_passed"] = op.calibrate && ok; report["ended_ns"] = Self.now()
        report["execution_mode"] = op.calibrate ? "parallel_per_device_v1":"sequential_configuration"
        if let d = links[op.deviceID] {
            report["after"] = operationSnapshot(d)
            if op.calibrate {
                let issues = d.pose.issues(now:Self.now(),tolerance:0.05)
                report["final_window_issues"] = issues; report["final_window_passed"] = issues.isEmpty
            }
            if let m = d.monitor { report["motion_monitor"] = ["samples":m.count,"max_gap_ms":m.maxGapMS,"max_gyro_dps":m.maxGyro,"max_accel_change_g":m.maxDeviation] }
            d.monitor = nil; d.lastOperation = why; failControls(d,"该台操作已结束，丢弃未提交指令")
        }
        op.report = report
        if !b.auditFailed {
            do {
                let at = Self.wall(); try b.journal.append(type:"operation_result",details:report,at:at)
                let row: [String:Any] = ["type":"operation_result","wall_ms":at,"details":report]
                DispatchQueue.main.async { self.onOperationResult?(row) }
            } catch {
                b.auditFailed = true; op.passed = false
                self.abortOperations("结果审计写入失败，整个批次停止："+error.localizedDescription,audit:false)
            }
        }
        operationResults.append(op.name+"："+why)
        if !b.calibrate, !b.cancelled {
            work.asyncAfter(deadline:.now()+0.25) { guard self.batch === b else { return }; self.nextConfiguration() }
        }
    }
    func failOperation(_ id: UUID, _ reason: String) {
        guard let b = batch, let op = b.operations[id], !op.finished else { return }
        if b.calibrate { b.coordinator?.cancelDevice(id.uuidString,reason:reason) }
        else if op.started { finishOperation(op,false,reason) }
    }
    func serviceOperations(_ now: UInt64) {
        guard let b = batch, !b.cancelled else { return }
        for id in b.order {
            guard batch === b, let op = b.operations[id], op.active else { continue }
            guard let d = links[id], operationActive(op,link:d) else { failOperation(id,"该设备连接或就绪状态变化；其他设备继续"); continue }
            if now >= op.startedNS && now-op.startedNS >= 60*secondNS { failOperation(id,"该设备操作超过60秒，停止后续指令；其他设备继续") }
        }
    }
    func finishBatch() {
        guard let b = batch, !b.finishing else { return }; b.finishing = true
        var auditError = b.auditFailed
        if !b.auditFailed {
            do { try b.journal.append(type:"operation_batch_finished",details:["batch_id":b.id,"cancelled":b.cancelled,"completed":b.completed,
                "total":b.order.count,"execution_mode":b.calibrate ? "parallel_per_device_v1":"sequential_configuration"],at:Self.wall()) }
            catch { auditError = true }
        }
        do { try b.journal.close() } catch { auditError = true }
        for id in b.order {
            guard let d = links[id] else { continue }
            d.maintenance = false; d.monitor = nil; d.readyAt = Self.now(); d.goodSince = 0
            d.lowSince = [0,0,0,0]; d.recent = (0..<4).map { _ in RecentStream() }; d.scheduler = QueryScheduler()
        }
        batch = nil; b.coordinator = nil
        message = auditError ? "操作审计保存异常，整个批次已停止；请导出已有日志核查" :
            b.cancelled ? "批次已停止，逐台结果已保留；已提交指令不会自动撤销" :
            "批次结束：\(b.completed)/\(b.order.count)台，\(b.operations.values.filter(\.passed).count)台复核通过；请查看各台结果"
        DispatchQueue.main.async { self.onOperationFinished?() }; notifyRequestFinished()
    }
    func abortOperations(_ reason: String, audit: Bool = true) {
        guard let b = batch, !b.finishing else { return }
        b.cancelled = true; if !audit { b.auditFailed = true }
        if let coordinator = b.coordinator { coordinator.cancelAll(reason) }
        for id in b.order {
            if let op = b.operations[id], !op.finished { finishOperation(op,false,reason) }
        }
        if batch === b { finishBatch() }
    }
    func cancelBatch() { work.async { self.abortOperations("用户取消整个批次；已提交的硬件指令状态需核验") } }
}
