import Foundation
import CoreBluetooth
import BaduanjinCore

struct DeviceSnapshot: Identifiable {
    var id: String, name: String, status: String, wanted: Bool, connected: Bool, initialized: Bool
    var ages: [Double?], hz: [Double], acceleration: [Double], gyro: [Double], magnetic: [Double], quaternion: [Double]
    var configurationOK: Bool, firmware: String, issues: [String], lastError: String
    var readiness: DeviceReadiness, maintenance: Bool, lastOperation: String
    var installationOrientation: Int?
    var live = LiveMonitor(), canStartMag = false
    var submittedQueries: Int, backpressureTicks: Int, writeReadyCallbacks: Int
}
struct EngineSnapshot {
    var enabled = false, scanning = false, recording = false, saving = false
    var countdown = 0, elapsed = 0.0, message = "尚未连接", devices: [DeviceSnapshot] = []
    var found: [String: String] = [:]
    var connectionLog: [String] = []
    var timestamp: UInt64 = 0, freeBytes: Int64 = -1, queuedWrites = 0, storedBytes: UInt64 = 0
    var batch = false, movement = false, batchMessage = "未执行批量操作", queryHz = 90, passive = false
    var recordingCalibration: SubjectCalibrationKind?
    var recordingDiagnostic = true, recordNumber: Int?, recordAttempt: Int?
    var operationResults: [String] = []
    var magTarget: String?, magPhase = MagPhase.idle, magMessage = "", headingPending = false
    var parallelCalibration = false, operationProgress: [OperationProgress] = []
}
struct OperationProgress: Identifiable {
    let id: String, name: String, message: String, finished: Bool, passed: Bool, saveSubmitted: Bool
}
/// All CoreBluetooth state and parsing live on one queue; UI receives immutable snapshots.
/// Hardware writes use guarded, audited operation flows; routine acquisition only reads.
final class BluetoothEngine: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    final class Link {
        let peripheral: CBPeripheral
        var name: String, wanted = false, connected = false, subscribed = false, initialized = false
        var status = "未连接", lastError = "", closing = false, writer: CBCharacteristic?, notifier: CBCharacteristic?
        var parser = WitParser(), scheduler = QueryScheduler(), recent = (0..<4).map { _ in RecentStream() }, pose = PoseWindow()
        var settings: [Int: [String: Any]] = [:], registers: [Int: Int] = [:], firmware = "未知"
        var acceleration = [0.0,0,0], gyro = [0.0,0,0], magnetic = [0.0,0,0], quaternion = [1.0,0,0,0]
        var reads: [Int] = [], reading: Int?, readAt: UInt64 = 0, retries = 0, retryAt: UInt64 = 0, stageAt: UInt64 = 0
        var invalidQ = 0, trialStreams: [TrialStream] = [], severity = [0,0,0,0]
        var quaternionWindow = QuaternionWindow(), monitor: CalibrationMonitor?
        var live = LiveMonitor()
        var generation = UUID(), readyAt: UInt64 = 0, goodSince: UInt64 = 0, disconnectedAt: UInt64 = 0
        var lowSince: [UInt64] = [0,0,0,0], maintenance = false, lastOperation = ""
        var controls: [ControlRequest] = [], control: ControlRequest?, submittedQueries = 0, backpressureTicks = 0, writeReadyCallbacks = 0
        var trialDiscarded = 0
        init(_ peripheral: CBPeripheral, name: String) { self.peripheral = peripheral; self.name = name }
    }
    let work = DispatchQueue(label: "dev.imulink.ios.bluetooth")
    var central: CBCentralManager!, timer: DispatchSourceTimer?, links: [UUID: Link] = [:], found: [UUID: String] = [:]
    let magneticJob = MagneticJob()
    var headingToken: UUID?
    var onMagPrepare: ((String, @escaping (String?) -> Void) -> Void)?
    var scanning = false, scanGeneration = UUID(), cursor = 0, lastPublish: UInt64 = 0, lastFlush: UInt64 = 0
    var writer: SessionWriter?, targets: [UUID] = [], startNS: UInt64 = 0, actionNS: UInt64 = 0, endNS: UInt64 = 0, fault = false, saving = false
    var message = "请扫描并逐一核对设备编号", appActive = true
    var connectionLog: [String] = []
    var root: URL?, lastStorage: UInt64 = 0, lastHealth: UInt64 = 0, freeBytes: Int64 = -1
    var queryHz = 90, passive = false, passiveEnd: UInt64 = 0
    var batch: BatchState?, operationResults: [String] = []
    var movementRole: String?, movementEnd: UInt64 = 0, movementWindows: [String:MovementWindow] = [:]
    var movementRoster: [String:SensorBinding] = [:], referencePending = false
    var referenceGeneration = UUID()
    var onReferences: (([String:SensorBinding],String,Bool) -> Void)?, onMovement: ((MovementReport,String,String) -> Void)?
    var onOperationFinished: (() -> Void)?, onRequestFinished: (() -> Void)?
    var onOperationResult: (([String:Any]) -> Void)?
    var recordingCalibration: SubjectCalibration?
    var recordingDiagnostic = true, recordingAssignment: Assignment?, recordingRoster: [String:SensorBinding] = [:], overMinute = false
    var onSnapshot: ((EngineSnapshot) -> Void)?, onSaved: (() -> Void)?
    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    static func wall() -> Int64 { Int64(Date().timeIntervalSince1970*1000) }
    override init() {
        super.init(); work.async { self.central = CBCentralManager(delegate: self, queue: self.work, options: [CBCentralManagerOptionShowPowerAlertKey: true]); let timer = DispatchSource.makeTimerSource(queue: self.work); timer.schedule(deadline: .now(), repeating: .milliseconds(2)); timer.setEventHandler { [weak self] in self?.tick() }; self.timer = timer; timer.resume() }
    }
    func idle() -> Bool { writer == nil && !saving && batch == nil && movementRole == nil && !referencePending && !magneticJob.phase.busy && headingToken == nil }
    func configure(root: URL, queryHz: Int) { work.async { self.root = root; self.restoreMagTarget(); self.queryHz = (40...200).contains(queryHz) ? queryHz : 90; self.refreshStorage() } }
    func setQueryHz(_ hz: Int) { work.async { guard self.idle(), (40...200).contains(hz) else { return }; self.queryHz = hz; self.message = "查询上限已设为\(hz)次/秒/台，实际接收率另计" } }
    func scan() { work.async {
        guard self.idle(), self.central.state == .poweredOn else { self.message = "请先结束录制并开启蓝牙"; return }
        self.central.stopScan(); self.found = [:]; self.scanning = true; let epoch = UUID(); self.scanGeneration = epoch
        self.central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]); self.message = "扫描15秒，请核对设备贴纸与名称"
        self.work.asyncAfter(deadline: .now()+15) { if self.scanGeneration == epoch { self.central.stopScan(); self.scanning = false } }
    } }
    func connect(_ ids: [String], passiveSeconds: Int? = nil) { work.async {
        guard self.idle(), self.central.state == .poweredOn, !ids.isEmpty, ids.count <= 15, Set(ids).count == ids.count else { self.message = "请选择1–15台设备，且当前没有录制"; return }
        let uuids = ids.compactMap(UUID.init(uuidString:)); guard uuids.count == ids.count else { self.message = "iOS设备UUID无效"; return }
        self.central.stopScan(); self.scanning = false; self.scanGeneration = UUID()
        for p in self.central.retrievePeripherals(withIdentifiers: uuids) where self.links[p.identifier] == nil { self.links[p.identifier] = Link(p, name: p.name ?? p.identifier.uuidString) }
        guard uuids.allSatisfy({ self.links[$0] != nil }) else { self.message = "部分UUID无法恢复，请重新扫描绑定"; return }
        if passiveSeconds != nil || self.passive {
            guard self.links.values.allSatisfy({ !$0.wanted && $0.peripheral.state == .disconnected }) else { self.message = "切换仅连接诊断前，请先断开全部设备"; return }
        }
        self.passive = passiveSeconds != nil; self.passiveEnd = passiveSeconds.map { Self.now()+UInt64(max(5,min(600,$0)))*secondNS } ?? 0
        for (id,d) in self.links { d.wanted = uuids.contains(id); if !d.wanted { self.central.cancelPeripheralConnection(d.peripheral) } else if !d.connected { d.retryAt = 0; d.retries = 0; d.lastError = "" } }
        self.log(nil,"选择连接 \(uuids.count) 台；目标服务 \(WitProtocol.service)")
        self.message = "连接选定设备，不自动开始记录"
    } }
    func disconnect() { work.async {
        guard !self.magneticJob.phase.busy && self.headingToken == nil && self.batch == nil && self.movementRole == nil && !self.referencePending else { self.message = "请先停止当前操作"; return }
        if self.writer != nil { self.finish(reason: "用户断开", at: Self.now()) }
        for d in self.links.values { d.wanted = false; self.central.cancelPeripheralConnection(d.peripheral); d.initialized = false; d.status = "正在断开" }
        self.central.stopScan(); self.scanning = false; self.scanGeneration = UUID()
        self.passive = false; self.passiveEnd = 0
    } }
    func readConfiguration() { work.async {
        guard self.idle() else { self.message = "请先结束录制"; return }
        for d in self.links.values where d.wanted && d.initialized { if d.reads.isEmpty && d.reading == nil { d.reads = [0x03,0x23,0x24,0x96] } }
        self.message = "读取50Hz、九轴与安装方向，不修改传感器"
    } }
    func active(_ value: Bool) { work.async {
        self.appActive = value
        if !value && self.writer != nil { self.fault = true; self.event(nil, "app_left_foreground"); self.finish(reason: "应用离开前台，后台采集尚未验收", at: Self.now()) }
        if !value { self.central?.stopScan(); self.scanning = false; self.scanGeneration = UUID() }
        if !value { self.interruptMag("应用离开前台"); self.headingToken = nil; self.abortOperations("应用离开前台，停止后续操作；已提交指令的硬件状态须核验"); self.cancelWearing("佩戴检查因离开前台取消，请重新进行") }
    } }
    func stop(calibrationComplete: Bool = false) { work.async { self.finish(reason:"手动结束",at:Self.now(),userEnded:true,calibrationComplete:calibrationComplete) } }
    func event(_ d: Link?, _ text: String) { writer?.event(id: d?.peripheral.identifier.uuidString ?? "", ns: Self.now(), message: text) }
    func log(_ d: Link?, _ text: String) {
        let device = d.map { "\($0.name) [\($0.peripheral.identifier.uuidString)]" } ?? "App"
        connectionLog.append("\(Self.wall()) \(device): \(text)")
        if connectionLog.count > 200 { connectionLog.removeFirst(connectionLog.count-200) }
        event(d,"connection \(text)")
    }
    func detail(_ error: Error?) -> String {
        guard let error else { return "系统未提供错误码" }
        let value = error as NSError
        return "\(value.domain)(\(value.code)): \(value.localizedDescription)"
    }
    func fail(_ d: Link, _ reason: String) {
        guard !d.closing else { return }
        d.lastError = reason; d.status = reason; d.closing = true
        failOperation(d.peripheral.identifier,reason+"；仅结束该设备操作")
        log(d,reason); central.cancelPeripheralConnection(d.peripheral)
    }
    func finish(reason: String, at: UInt64, userEnded: Bool = false, calibrationComplete: Bool = false) {
        guard let recorder = writer else { return }; event(nil, "record_end reason=\(reason)")
        var devices: [[String: Any]] = []; var quality = actionNS > 0 && !fault && (recordingDiagnostic || Set(targets).count == 15)
        for id in targets {
            guard let d = links[id] else { quality = false; continue }
            let results = d.trialStreams.enumerated().map { $0.element.result(end: at, name: streams[$0.offset]) }
            let discarded = d.trialDiscarded+d.parser.discarded
            let passed = QualityPolicy.current.passes(results,discarded:discarded,tail:d.parser.pendingBytes,invalidQ:d.invalidQ)
            quality = quality && passed
            let bindings = recordingRoster.filter { $0.value.peripheralID == id.uuidString }
            let role = bindings.count == 1 ? bindings.first!.key : "unassigned"
            devices.append(["address":id.uuidString,"role":role,"streams":results.compactMap { try? JSONFile.object($0) },"invalid_quaternions":d.invalidQ,"parser_discarded_bytes":discarded,"tail_bytes":d.parser.pendingBytes,"query_submissions":d.submittedQueries,"backpressure_ticks":d.backpressureTicks,"write_ready_callbacks":d.writeReadyCallbacks])
        }
        let outcome = RecordingPolicy.summary(diagnostic:recordingDiagnostic,actionStarted:actionNS>0,userEnded:userEnded,quality:quality)
        var summary: [String: Any] = ["quality_policy":QualityPolicy.current.metadata,"action_start_ns":actionNS,"end_ns":at,"duration_s":actionNS > 0 ? Double(at-actionNS)/1e9 : 0,"reason":reason,"diagnostic":recordingDiagnostic,"fault_event":fault,"quality_passed":quality,"accepted":outcome.accepted,"normal_completion":outcome.normal,"status":outcome.status,"devices":devices]
        if let calibration = recordingCalibration {
            let duration = actionNS > 0 && at >= actionNS ? Double(at-actionNS)/1e9 : 0
            let complete = RecordingPolicy.calibrationCompleted(kind:calibration.kind,duration:duration,completionConfirmed:calibrationComplete)
            summary["normal_completion"] = complete
            summary["accepted"] = false
            summary["status"] = quality && complete ? "calibration_complete" : "calibration_incomplete"
            summary["subject_calibration"] = try? JSONFile.object(calibration)
            summary["operator_confirmed_two_squats"] = calibration.kind == .dynamicSquats && calibrationComplete
        }
        let wasCalibration = recordingCalibration != nil
        writer = nil; saving = true; message = "正在保存…"
        recorder.close(summary: summary) { result in self.work.async {
            self.saving = false
            switch result { case .success(let final): self.message = wasCalibration ? (final["status"] as? String == "calibration_complete" ? "校正数据已保存，采集完成" : "本次校正采集未完成，请查看原因后重采") : self.recordingDiagnostic ? "诊断已保存，不占正式编号" : (final["accepted"] as? Bool == true ? "已保存并默认正常；有问题可标记补录":"记录已保留，待补录；请查看失败原因"); case .failure(let e): self.message = "保存失败：\(e.localizedDescription)，原文件保留" }
            DispatchQueue.main.async { self.onSaved?() }
        } }
    }
    func tick() {
        let now = Self.now()
        if now-lastStorage >= secondNS { refreshStorage(); lastStorage = now }
        if passiveEnd > 0 && now >= passiveEnd {
            for d in links.values { d.wanted = false; central.cancelPeripheralConnection(d.peripheral) }
            passive = false; passiveEnd = 0; message = "仅连接诊断到时，已断开并清除连接目标；未启动查询"; log(nil,message)
        }
        if central?.state == .poweredOn && appActive {
            let values = links.values.sorted { $0.peripheral.identifier.uuidString < $1.peripheral.identifier.uuidString }
            var connecting = values.filter { $0.wanted && $0.peripheral.state == .connecting }.count
            for d in values where d.wanted && !d.closing {
                if d.peripheral.state == .disconnected && now >= d.retryAt && connecting < 2 {
                    if batch != nil && d.maintenance { continue }
                    if writer != nil { d.trialDiscarded += d.parser.discarded }
                    d.live = LiveMonitor(); d.generation = UUID(); d.readyAt = 0; d.goodSince = 0; d.quaternionWindow = QuaternionWindow()
                    d.status = "连接中"; d.stageAt = now; d.parser = WitParser(); d.recent = (0..<4).map { _ in RecentStream() }; d.pose = PoseWindow(); d.settings = [:]; d.registers = [:]; d.firmware = "未知"; d.writer = nil; d.notifier = nil; d.subscribed = false; d.initialized = false; d.reads = []; d.reading = nil; d.scheduler = QueryScheduler(); log(d,"请求连接，第\(d.retries+1)次"); self.central.connect(d.peripheral); connecting += 1
                }
                if !d.initialized && !(passive && d.connected) && d.peripheral.state != .disconnected && now > d.stageAt && now-d.stageAt > 15*secondNS { fail(d,"连接/初始化超时：\(d.status)") }
            }
            if !values.isEmpty {
                let startCursor = cursor; var submitted = 0
                for offset in 0..<values.count {
                    let i = (startCursor+offset)%values.count
                    if pump(values[i], now) { cursor = (i+1)%values.count; submitted += 1; if submitted == 4 { break } }
                }
            }
        }
        serviceMag(now)
        if now-lastHealth >= 50_000_000 { serviceOperations(now); updateHealth(now); lastHealth = now }
        if movementEnd > 0 && now >= movementEnd { finishMovement() }
        if writer != nil {
            if actionNS == 0 && now-startNS >= 3*secondNS { actionNS = now; for id in targets { links[id]?.trialStreams = (0..<4).map { _ in TrialStream(start: now) } }; event(nil,"action_start") }
            if recordingCalibration?.kind == .staticPose && actionNS > 0 && now-actionNS >= 5*secondNS {
                finish(reason:"N-pose 5秒采集完成",at:now,calibrationComplete:true)
            }
            if writer != nil && actionNS > 0 && now-actionNS >= 60*secondNS && !overMinute { overMinute = true; message = "动作已超过60秒，请完成后手动结束"; event(nil,"over_60_seconds_reminder") }
            if now-lastFlush >= secondNS { writer?.flush(); lastFlush = now }
            if let state = writer?.status(), !state.error.isEmpty { fault = true; finish(reason: state.error, at: now) }
            else if endNS > 0 && now >= endNS { finish(reason: "诊断到时", at: now) }
        }
        if now-lastPublish >= 250_000_000 { publish(now); lastPublish = now }
    }
    func pump(_ d: Link, _ now: UInt64) -> Bool {
        guard !passive, d.wanted && d.connected && d.subscribed && !d.closing, let c = d.writer else { return false }
        if magneticJob.target == d.peripheral.identifier && magneticJob.phase.writing { return false }
        if d.control != nil || !d.controls.isEmpty { return pumpControl(d,now) }
        if d.reading != nil {
            if now-d.readAt >= 2*secondNS {
                if d.reading == 0x72 { log(d,"磁场类型读取超时，TXT中磁场uT将留空；继续惯性初始化") }
                else { fail(d,String(format:"寄存器0x%02X回读超时",d.reading!)) }
                d.reading = nil
            }
            return false
        }
        guard !d.maintenance else { return false }
        guard d.peripheral.canSendWriteWithoutResponse else { d.backpressureTicks += 1; return false }
        let reg: Int
        if !d.reads.isEmpty { reg = d.reads.removeFirst(); d.reading = reg; d.readAt = now; log(d,String(format:"读取寄存器0x%02X",reg)) }
        else { guard d.initialized && now >= d.scheduler.next else { return false }; reg = d.scheduler.choose(now); d.scheduler.sent(reg, at: now, hz: queryHz); d.submittedQueries += 1 }
        guard let bytes = try? WitProtocol.read(reg) else { return false }
        d.peripheral.writeValue(bytes, for: c, type: .withoutResponse)
        event(d,"tx=\(WitProtocol.hex(bytes)) submitted_to_corebluetooth=true peripheral_acknowledged=false"); return true
    }
    func publish(_ now: UInt64) {
        var snapshot = EngineSnapshot(); snapshot.enabled = central?.state == .poweredOn; snapshot.scanning = scanning; snapshot.recording = writer != nil; snapshot.saving = saving
        snapshot.timestamp = now; snapshot.freeBytes = freeBytes; snapshot.queuedWrites = writer?.status().queued ?? 0; snapshot.storedBytes = writer?.status().storedBytes ?? 0
        snapshot.batch = batch != nil; snapshot.movement = movementRole != nil || referencePending; snapshot.batchMessage = batch?.message ?? "批量操作已结束"; snapshot.queryHz = queryHz; snapshot.passive = passive
        snapshot.operationResults = operationResults; snapshot.recordingCalibration = recordingCalibration?.kind; snapshot.recordingDiagnostic = recordingDiagnostic; snapshot.recordNumber = recordingAssignment?.record_number; snapshot.recordAttempt = recordingAssignment?.slot_attempt
        snapshot.magPhase = magneticJob.phase; snapshot.magTarget = magneticJob.target?.uuidString; snapshot.magMessage = magneticJob.message; snapshot.headingPending = headingToken != nil
        snapshot.parallelCalibration = batch?.calibrate == true
        if let b = batch {
            snapshot.operationProgress = b.order.compactMap { id in
                guard let op = b.operations[id] else { return nil }
                return OperationProgress(id:op.id,name:op.name,message:op.message,finished:op.finished,passed:op.passed,saveSubmitted:op.report["save_submitted"] as? Bool == true)
            }
        }
        snapshot.countdown = writer != nil && actionNS == 0 ? max(1,3-Int((now-startNS)/secondNS)) : 0
        snapshot.elapsed = writer != nil && actionNS > 0 ? Double(now-actionNS)/1e9 : 0; snapshot.message = message
        snapshot.found = Dictionary(uniqueKeysWithValues: found.map { ($0.key.uuidString,$0.value) })
        snapshot.connectionLog = connectionLog
        snapshot.devices = links.values.sorted { $0.name < $1.name }.map { d in
            let ages = d.recent.map { $0.age(now) }; var hz: [Double] = []
            for i in 0..<4 { hz.append(d.recent[i].rate(now, seconds: 10)) }
            var issues: [String] = []
            if d.wanted && !d.connected { issues.append(String(format:"断开/重连中 %.1f秒",d.disconnectedAt > 0 ? Double(now-d.disconnectedAt)/1e9:0)) }
            if d.maintenance { issues.append("维护中；结束后重新检查数据") }
            if d.connected && !d.maintenance && !passive {
                for k in 0..<4 {
                    let required = QualityPolicy.current.requires(k), label = ["加速度","角速度","磁场","四元数"][k]
                    let suffix = required ? "":"（辅助数据提示，不影响惯性质量判定）"
                    if let age = ages[k], age >= 500 { issues.append("\(label)停更\(String(format:"%.1f",age/1000))秒"+suffix) }
                    else if ages[k] == nil { issues.append("\(label)尚未收到"+suffix) }
                    if required && d.initialized && d.readyAt > 0 && now-d.readyAt >= 10*secondNS && !QualityPolicy.current.ratePasses(hz[k]) {
                        if d.lowSince[k] == 0 { d.lowSince[k] = now }
                        issues.append(String(format:"%@近10秒%.2fHz，未超过40Hz已持续%.1f秒",label,hz[k],Double(now-d.lowSince[k])/1e9))
                    } else { d.lowSince[k] = 0 }
                }
            }
            return DeviceSnapshot(id:d.peripheral.identifier.uuidString,name:d.name,status:d.status,wanted:d.wanted,connected:d.connected,initialized:d.initialized,ages:ages,hz:hz,acceleration:d.acceleration,gyro:d.gyro,magnetic:d.magnetic,quaternion:d.quaternion,configurationOK:d.registers[0x03] == 8 && d.registers[0x24] == 0 && d.registers[0x96] == 0,firmware:d.firmware,issues:issues,lastError:d.lastError,readiness:readiness(d,now),maintenance:d.maintenance,lastOperation:d.lastOperation,installationOrientation:d.registers[0x23],live:d.live,canStartMag:magEligible(d,now),submittedQueries:d.submittedQueries,backpressureTicks:d.backpressureTicks,writeReadyCallbacks:d.writeReadyCallbacks)
        }
        DispatchQueue.main.async { self.onSnapshot?(snapshot) }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log(nil,"蓝牙状态=\(central.state.rawValue)")
        if central.state != .poweredOn {
            interruptMag("手机蓝牙不可用"); headingToken = nil; for d in links.values { d.live = LiveMonitor() }
            abortOperations("手机蓝牙不可用，操作停止"); cancelWearing("蓝牙不可用，佩戴检查取消")
            if writer != nil { fault = true; event(nil,"bluetooth_unavailable") }
            for d in links.values { failControls(d,"手机蓝牙不可用"); d.connected = false; d.initialized = false; d.subscribed = false; d.reading = nil; d.closing = false; d.goodSince = 0; d.disconnectedAt = Self.now(); d.status = "蓝牙不可用" }
            scanning = false; message = "请开启蓝牙并允许本App访问蓝牙"
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        guard scanning, let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name, name.uppercased().hasPrefix("WT") else { return }
        found[peripheral.identifier] = name
        if links[peripheral.identifier] == nil { links[peripheral.identifier] = Link(peripheral, name:name) }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let d = links[peripheral.identifier], d.wanted, !d.closing, d.peripheral === peripheral else { central.cancelPeripheralConnection(peripheral); return }
        d.connected = true; d.stageAt = Self.now(); d.disconnectedAt = 0
        if passive { d.status = "仅连接；未发现服务、未订阅、未查询"; log(d,d.status); return }
        d.status = "发现服务"; log(d,"已连接，开始发现服务"); peripheral.delegate = self; peripheral.discoverServices([CBUUID(string: WitProtocol.service)])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) { disconnected(peripheral,error) }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) { disconnected(peripheral,error) }
    func disconnected(_ peripheral: CBPeripheral, _ error: Error?) {
        guard let d = links[peripheral.identifier], d.peripheral === peripheral else { return }
        if movementRole != nil, movementRoster.values.contains(where: { $0.peripheralID == peripheral.identifier.uuidString }) { cancelWearing("引导动作中部位断线，本次证据不足，请重新检查") }
        if magneticJob.target == peripheral.identifier { interruptMag("设备断线") }; d.live = LiveMonitor()
        d.generation = UUID(); d.goodSince = 0; d.disconnectedAt = Self.now()
        failOperation(peripheral.identifier,"该设备断线，旧操作不能跨重连继续；其他设备继续")
        failControls(d,"连接已断开，旧操作不能跨重连继续")
        if writer != nil && targets.contains(peripheral.identifier) { fault = true; event(d,"disconnected \(error?.localizedDescription ?? "连接结束")") }
        if d.wanted && !d.closing { d.lastError = "连接中断：\(detail(error))" }
        log(d,"连接结束：\(detail(error))；最近失败=\(d.lastError)")
        d.connected = false; d.initialized = false; d.subscribed = false; d.reading = nil; d.reads = []; d.closing = false; d.status = d.wanted ? "等待重连" : "已断开"
        d.retries += 1; d.retryAt = Self.now()+UInt64(min(30,1 << min(d.retries,4)))*secondNS
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let d = links[peripheral.identifier], d.wanted && d.connected && !d.closing else { return }
        log(d,"发现服务：\(peripheral.services?.map { $0.uuid.uuidString }.joined(separator:", ") ?? "无")")
        guard error == nil else { fail(d,"服务发现失败：\(detail(error))"); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string:WitProtocol.service) }) else { fail(d,"缺少维特自定义FFE5服务（9A34FB）"); return }
        d.status = "发现读写特征"
        peripheral.discoverCharacteristics([CBUUID(string:WitProtocol.notify),CBUUID(string:WitProtocol.write)], for:service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let d = links[peripheral.identifier], d.wanted && d.connected && !d.closing, service.uuid == CBUUID(string:WitProtocol.service) else { return }
        log(d,"发现特征：\(service.characteristics?.map { "\($0.uuid.uuidString) properties=\($0.properties.rawValue)" }.joined(separator:", ") ?? "无")")
        guard error == nil else { fail(d,"特征发现失败：\(detail(error))"); return }
        d.writer = service.characteristics?.first { $0.uuid == CBUUID(string:WitProtocol.write) }; d.notifier = service.characteristics?.first { $0.uuid == CBUUID(string:WitProtocol.notify) }
        guard let notify = d.notifier, d.writer?.properties.contains(.writeWithoutResponse) == true, notify.properties.contains(.notify) else { fail(d,"维特FFE4/FFE9特征或通知/写入属性不匹配"); return }
        d.status = "订阅数据通知"
        peripheral.setNotifyValue(true, for:notify)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard let d = links[peripheral.identifier], d.wanted && d.connected && !d.closing, characteristic === d.notifier else { return }
        guard error == nil, characteristic.isNotifying else { fail(d,"订阅通知失败：\(detail(error))"); return }
        log(d,"通知订阅成功")
        d.subscribed = true; d.status = "读取固件与配置"; d.reads = [0x2e,0x03,0x23,0x24,0x72,0x96]; d.reading = nil
    }
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) { links[peripheral.identifier]?.writeReadyCallbacks += 1 /* Fair timer resumes writes; this is not a firmware acknowledgement. */ }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let d = links[peripheral.identifier], d.wanted && d.connected && d.subscribed && !d.closing, characteristic === d.notifier else { return }
        guard error == nil else { fail(d,"接收通知失败：\(detail(error))"); return }
        guard let bytes = characteristic.value else { return }
        let ns = Self.now(), wall = Self.wall(); writer?.raw(id:peripheral.identifier.uuidString,ns:ns,wall:wall,data:bytes)
        if batch?.operations[peripheral.identifier]?.active == true { operationRaw(d,bytes,ns) }
        for frame in d.parser.accept(bytes) {
            writer?.frame(id:peripheral.identifier.uuidString,ns:ns,wall:wall,frame:frame,verified:d.registers[0x96] == 0)
            var indices: [Int] = []
            if frame.register == -1 && d.registers[0x96] == 0 { d.acceleration = frame.acceleration; d.gyro = frame.gyro; d.pose.add(ns:ns,acceleration:d.acceleration,gyro:d.gyro); d.monitor?.add(ns,acceleration:d.acceleration,gyro:d.gyro); movementWindows[peripheral.identifier.uuidString]?.add(ns,speed:sqrt(d.gyro.reduce(0) { $0+$1*$1 })); indices = [0,1] }
            else if frame.register == 0x3a { d.magnetic = frame.words.prefix(3).map(Double.init); indices = [2]; d.scheduler.reply(frame.register) }
            else if frame.register == 0x51 {
                d.quaternion = frame.quaternion; d.quaternionWindow.add(ns,frame.quaternion); indices = [3]; d.scheduler.reply(frame.register)
                if !frame.quaternionValid { d.invalidQ += 1; event(d,"auxiliary_quaternion_invalid; excluded_from_inertial_quality") }
                if writer != nil, let binding = recordingRoster.values.first(where: { $0.peripheralID == peripheral.identifier.uuidString }), let reference = binding.reference, let refID = binding.referenceID, let relative = try? QuaternionMath.relative(reference:reference,current:frame.quaternion) { writer?.relative(id:peripheral.identifier.uuidString,ns:ns,quaternion:relative,reference:refID) }
            }
            else if frame.register >= 0 {
                d.registers[frame.register] = frame.words[0] & 65535; d.settings[frame.register] = ["elapsed_ns":ns,"packet_hex":WitProtocol.hex(frame.bytes),"words":frame.words]
                if frame.register == 0x2e { let a = frame.words[0] & 65535, b = frame.words[1] & 65535; d.firmware = "\(((b & 32767) << 2) | (a >> 14)).\((a >> 8) & 63).\(a & 255)" }
                if d.reading == frame.register && ns >= d.readAt { log(d,String(format:"寄存器0x%02X回读=%d",frame.register,frame.words[0] & 65535)); d.reading = nil }
                receivedControl(d,frame,ns)
                if !d.initialized && d.reading == nil && d.reads.isEmpty && [0x2e,0x03,0x23,0x24,0x96].allSatisfy({d.registers[$0] != nil}) { d.initialized = true; d.readyAt = ns; d.disconnectedAt = 0; d.status = "四项接收中"; log(d,"初始化完成，开始四项接收") }
            }
            if frame.register == 0x72 { d.live.setType(frame.words[0] & 65535) }
            if frame.register == 0x3a || frame.register == 0x51 {
                let mag = frame.register == 0x3a
                if mag { d.live.magnetic(ns,d.magnetic); observePostMag(d,ns) }
                else { d.live.quaternion(ns,frame.quaternion) }
                if let writer, targets.contains(peripheral.identifier) { writer.derived(d.live.row(id:peripheral.identifier.uuidString,ns:ns,magnetic:mag)) }
            }
            for i in indices { d.recent[i].add(ns); if writer != nil && actionNS > 0 && d.trialStreams.count == 4 { d.trialStreams[i].add(ns) } }
        }
    }
}
