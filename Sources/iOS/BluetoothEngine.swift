import Foundation
import CoreBluetooth
import BaduanjinCore

struct DeviceSnapshot: Identifiable {
    var id: String, name: String, status: String, wanted: Bool, connected: Bool, initialized: Bool
    var ages: [Double?], hz: [Double], acceleration: [Double], gyro: [Double], magnetic: [Double], quaternion: [Double]
    var configurationOK: Bool, firmware: String, issues: [String], lastError: String
}
struct EngineSnapshot {
    var enabled = false, scanning = false, recording = false, saving = false
    var countdown = 0, elapsed = 0.0, message = "尚未连接", devices: [DeviceSnapshot] = []
    var found: [String: String] = [:]
    var connectionLog: [String] = []
}
/// All CoreBluetooth state and parsing live on one queue; UI receives immutable snapshots.
/// This initial integration sends read-register commands only. Hardware writes are not exposed.
final class BluetoothEngine: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private final class Link {
        let peripheral: CBPeripheral
        var name: String, wanted = false, connected = false, subscribed = false, initialized = false
        var status = "未连接", lastError = "", closing = false, writer: CBCharacteristic?, notifier: CBCharacteristic?
        var parser = WitParser(), scheduler = QueryScheduler(), recent = (0..<4).map { _ in RecentStream() }, pose = PoseWindow()
        var settings: [Int: [String: Any]] = [:], registers: [Int: Int] = [:], firmware = "未知"
        var acceleration = [0.0,0,0], gyro = [0.0,0,0], magnetic = [0.0,0,0], quaternion = [1.0,0,0,0]
        var reads: [Int] = [], reading: Int?, readAt: UInt64 = 0, retries = 0, retryAt: UInt64 = 0, stageAt: UInt64 = 0
        var invalidQ = 0, trialStreams: [TrialStream] = [], severity = [0,0,0,0]
        init(_ peripheral: CBPeripheral, name: String) { self.peripheral = peripheral; self.name = name }
    }
    private let work = DispatchQueue(label: "dev.imulink.ios.bluetooth")
    private var central: CBCentralManager!, timer: DispatchSourceTimer?, links: [UUID: Link] = [:], found: [UUID: String] = [:]
    private var scanning = false, scanGeneration = UUID(), cursor = 0, lastPublish: UInt64 = 0, lastFlush: UInt64 = 0
    private var writer: SessionWriter?, targets: [UUID] = [], startNS: UInt64 = 0, actionNS: UInt64 = 0, endNS: UInt64 = 0, fault = false, saving = false
    private var message = "请扫描并逐一核对设备编号", appActive = true
    private var connectionLog: [String] = []
    var onSnapshot: ((EngineSnapshot) -> Void)?, onSaved: (() -> Void)?
    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    static func wall() -> Int64 { Int64(Date().timeIntervalSince1970*1000) }
    override init() {
        super.init(); work.async { self.central = CBCentralManager(delegate: self, queue: self.work, options: [CBCentralManagerOptionShowPowerAlertKey: true]); let timer = DispatchSource.makeTimerSource(queue: self.work); timer.schedule(deadline: .now(), repeating: .milliseconds(2)); timer.setEventHandler { [weak self] in self?.tick() }; self.timer = timer; timer.resume() }
    }
    private func idle() -> Bool { writer == nil && !saving }
    func scan() { work.async {
        guard self.idle(), self.central.state == .poweredOn else { self.message = "请先结束录制并开启蓝牙"; return }
        self.central.stopScan(); self.found = [:]; self.scanning = true; let epoch = UUID(); self.scanGeneration = epoch
        self.central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]); self.message = "扫描15秒，请核对设备贴纸与名称"
        self.work.asyncAfter(deadline: .now()+15) { if self.scanGeneration == epoch { self.central.stopScan(); self.scanning = false } }
    } }
    func connect(_ ids: [String]) { work.async {
        guard self.idle(), self.central.state == .poweredOn, !ids.isEmpty, ids.count <= 15, Set(ids).count == ids.count else { self.message = "请选择1–15台设备，且当前没有录制"; return }
        let uuids = ids.compactMap(UUID.init(uuidString:)); guard uuids.count == ids.count else { self.message = "iOS设备UUID无效"; return }
        self.central.stopScan(); self.scanning = false; self.scanGeneration = UUID()
        for p in self.central.retrievePeripherals(withIdentifiers: uuids) where self.links[p.identifier] == nil { self.links[p.identifier] = Link(p, name: p.name ?? p.identifier.uuidString) }
        guard uuids.allSatisfy({ self.links[$0] != nil }) else { self.message = "部分UUID无法恢复，请重新扫描绑定"; return }
        for (id,d) in self.links { d.wanted = uuids.contains(id); if !d.wanted { self.central.cancelPeripheralConnection(d.peripheral) } else if !d.connected { d.retryAt = 0; d.retries = 0; d.lastError = "" } }
        self.log(nil,"选择连接 \(uuids.count) 台；目标服务 \(WitProtocol.service)")
        self.message = "连接选定设备，不自动开始记录"
    } }
    func disconnect() { work.async {
        if self.writer != nil { self.finish(reason: "用户断开", at: Self.now()) }
        for d in self.links.values { d.wanted = false; self.central.cancelPeripheralConnection(d.peripheral); d.initialized = false; d.status = "正在断开" }
        self.central.stopScan(); self.scanning = false; self.scanGeneration = UUID()
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
    } }
    func startDiagnostic(root: URL, roster: [String: SensorBinding], seconds: Int = 60) { work.async {
        guard self.idle(), self.appActive, (5...120).contains(seconds) else { self.message = "诊断需前台运行，单次5–120秒"; return }
        let selected = self.links.filter { $0.value.wanted }
        guard !selected.isEmpty, selected.values.allSatisfy({ $0.initialized && $0.connected }) else { self.message = "选定设备必须全部连接并初始化"; return }
        do {
            let rosterObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(roster))
            let devices = selected.map { id,d -> [String: Any] in ["address":id.uuidString,"name":d.name,"firmware":d.firmware,"settings":Dictionary(uniqueKeysWithValues:d.settings.map { (String($0.key),$0.value) })] }
            self.writer = try SessionWriter(root: root, metadata: ["schema_version":5,"platform":"iOS","identity_kind":"corebluetooth_uuid_not_mac","diagnostic":true,"action_acceptance_policy":"default_normal_if_quality_passed","logic_profile":WitProtocol.profile,"recorded_ms":Self.wall(),"devices":devices,"roster":rosterObject,"internal_sampling_synchronization_verified":false])
            self.targets = Array(selected.keys); self.startNS = Self.now(); self.actionNS = 0; self.endNS = self.startNS+UInt64(seconds+3)*secondNS; self.fault = false
            for d in selected.values { d.trialStreams = []; d.invalidQ = 0; d.severity = [0,0,0,0]; d.parser = WitParser() }
            self.event(nil, "record_start countdown_seconds=3"); self.message = "已保存，3秒后标记动作开始"
        } catch { self.message = error.localizedDescription }
    } }
    func stop() { work.async { self.finish(reason: "诊断手动结束", at: Self.now()) } }
    private func event(_ d: Link?, _ text: String) { writer?.event(id: d?.peripheral.identifier.uuidString ?? "", ns: Self.now(), message: text) }
    private func log(_ d: Link?, _ text: String) {
        let device = d.map { "\($0.name) [\($0.peripheral.identifier.uuidString)]" } ?? "App"
        connectionLog.append("\(Self.wall()) \(device): \(text)")
        if connectionLog.count > 200 { connectionLog.removeFirst(connectionLog.count-200) }
        event(d,"connection \(text)")
    }
    private func detail(_ error: Error?) -> String {
        guard let error else { return "系统未提供错误码" }
        let value = error as NSError
        return "\(value.domain)(\(value.code)): \(value.localizedDescription)"
    }
    private func fail(_ d: Link, _ reason: String) {
        guard !d.closing else { return }
        d.lastError = reason; d.status = reason; d.closing = true
        log(d,reason); central.cancelPeripheralConnection(d.peripheral)
    }
    private func finish(reason: String, at: UInt64) {
        guard let recorder = writer else { return }; event(nil, "record_end reason=\(reason)")
        var devices: [[String: Any]] = []; var quality = actionNS > 0 && !fault
        for id in targets {
            guard let d = links[id] else { quality = false; continue }
            let results = d.trialStreams.enumerated().map { $0.element.result(end: at, name: streams[$0.offset]) }
            let passed = results.count == 4 && results.allSatisfy { $0.passed } && d.invalidQ == 0 && d.parser.discarded == 0 && d.parser.pendingBytes == 0
            quality = quality && passed
            devices.append(["address":id.uuidString,"streams":results.compactMap { try? JSONFile.object($0) },"invalid_quaternions":d.invalidQ,"parser_discarded_bytes":d.parser.discarded,"tail_bytes":d.parser.pendingBytes])
        }
        let summary: [String: Any] = ["action_start_ns":actionNS,"end_ns":at,"duration_s":actionNS > 0 ? Double(at-actionNS)/1e9 : 0,"reason":reason,"diagnostic":true,"fault_event":fault,"quality_passed":quality,"accepted":false,"normal_completion":false,"status":quality ? "diagnostic_pass" : "quality_failed","devices":devices]
        writer = nil; saving = true; message = "正在保存…"
        recorder.close(summary: summary) { result in self.work.async {
            self.saving = false
            switch result { case .success: self.message = "诊断已保存，不占正式编号"; case .failure(let e): self.message = "保存失败：\(e.localizedDescription)，原文件保留" }
            DispatchQueue.main.async { self.onSaved?() }
        } }
    }
    private func tick() {
        let now = Self.now()
        if central?.state == .poweredOn {
            let values = links.values.sorted { $0.peripheral.identifier.uuidString < $1.peripheral.identifier.uuidString }
            var connecting = values.filter { $0.wanted && $0.peripheral.state == .connecting }.count
            for d in values where d.wanted && !d.closing {
                if d.peripheral.state == .disconnected && now >= d.retryAt && connecting < 2 {
                    d.status = "连接中"; d.stageAt = now; d.parser = WitParser(); d.recent = (0..<4).map { _ in RecentStream() }; d.pose = PoseWindow(); d.settings = [:]; d.registers = [:]; d.firmware = "未知"; d.writer = nil; d.notifier = nil; d.subscribed = false; d.initialized = false; d.reads = []; d.reading = nil; d.scheduler = QueryScheduler(); log(d,"请求连接，第\(d.retries+1)次"); self.central.connect(d.peripheral); connecting += 1
                }
                if !d.initialized && d.peripheral.state != .disconnected && now > d.stageAt && now-d.stageAt > 15*secondNS { fail(d,"连接/初始化超时：\(d.status)") }
            }
            if !values.isEmpty {
                let startCursor = cursor; var submitted = 0
                for offset in 0..<values.count {
                    let i = (startCursor+offset)%values.count
                    if pump(values[i], now) { cursor = (i+1)%values.count; submitted += 1; if submitted == 4 { break } }
                }
            }
        }
        if writer != nil {
            if actionNS == 0 && now-startNS >= 3*secondNS { actionNS = now; for id in targets { links[id]?.trialStreams = (0..<4).map { _ in TrialStream(start: now) } }; event(nil,"action_start") }
            for id in targets {
                guard let d = links[id] else { fault = true; continue }
                for k in 0..<4 {
                    let age = d.recent[k].age(now) ?? Double(now-startNS)/1e6; let severity = age >= 2000 ? 2 : age >= 500 ? 1 : 0
                    if severity != d.severity[k] { event(d, "stream_health \(streams[k]) severity=\(severity) age_ms=\(age)"); d.severity[k] = severity }
                    if severity > 0 { fault = true }
                }
            }
            if now-lastFlush >= secondNS { writer?.flush(); lastFlush = now }
            if let state = writer?.status(), !state.error.isEmpty { fault = true; finish(reason: state.error, at: now) }
            else if now >= endNS { finish(reason: "诊断到时", at: now) }
        }
        if now-lastPublish >= 250_000_000 { publish(now); lastPublish = now }
    }
    private func pump(_ d: Link, _ now: UInt64) -> Bool {
        guard d.wanted && d.connected && d.subscribed && !d.closing, let c = d.writer else { return false }
        if d.reading != nil {
            if now-d.readAt >= 2*secondNS { fail(d,String(format:"寄存器0x%02X回读超时",d.reading!)); d.reading = nil }
            return false
        }
        guard d.peripheral.canSendWriteWithoutResponse else { return false }
        let reg: Int
        if !d.reads.isEmpty { reg = d.reads.removeFirst(); d.reading = reg; d.readAt = now; log(d,String(format:"读取寄存器0x%02X",reg)) }
        else { guard d.initialized && now >= d.scheduler.next else { return false }; reg = d.scheduler.choose(now); d.scheduler.sent(reg, at: now, hz: 90) }
        guard let bytes = try? WitProtocol.read(reg) else { return false }
        d.peripheral.writeValue(bytes, for: c, type: .withoutResponse)
        event(d,"tx=\(WitProtocol.hex(bytes)) submitted_to_corebluetooth=true peripheral_acknowledged=false"); return true
    }
    private func publish(_ now: UInt64) {
        var snapshot = EngineSnapshot(); snapshot.enabled = central?.state == .poweredOn; snapshot.scanning = scanning; snapshot.recording = writer != nil; snapshot.saving = saving
        snapshot.countdown = writer != nil && actionNS == 0 ? max(1,3-Int((now-startNS)/secondNS)) : 0
        snapshot.elapsed = writer != nil && actionNS > 0 ? Double(now-actionNS)/1e9 : 0; snapshot.message = message
        snapshot.found = Dictionary(uniqueKeysWithValues: found.map { ($0.key.uuidString,$0.value) })
        snapshot.connectionLog = connectionLog
        snapshot.devices = links.values.sorted { $0.name < $1.name }.map { d in
            let ages = d.recent.map { $0.age(now) }; var hz: [Double] = []
            for i in 0..<4 { hz.append(d.recent[i].rate(now, seconds: 10)) }
            var issues: [String] = []
            if d.wanted && !d.connected { issues.append("断开/重连中") }
            if d.connected { for k in 0..<4 { if let age = ages[k], age >= 500 { issues.append("\(streams[k])停更\(String(format:"%.1f",age/1000))秒") } else if ages[k] == nil { issues.append("\(streams[k])尚未收到") }; if d.initialized && now-d.stageAt >= 10*secondNS && hz[k] < 30 { issues.append("\(streams[k])近10秒不足30Hz") } } }
            return DeviceSnapshot(id:d.peripheral.identifier.uuidString,name:d.name,status:d.status,wanted:d.wanted,connected:d.connected,initialized:d.initialized,ages:ages,hz:hz,acceleration:d.acceleration,gyro:d.gyro,magnetic:d.magnetic,quaternion:d.quaternion,configurationOK:d.registers[0x03] == 8 && d.registers[0x24] == 0 && d.registers[0x96] == 0,firmware:d.firmware,issues:issues,lastError:d.lastError)
        }
        DispatchQueue.main.async { self.onSnapshot?(snapshot) }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log(nil,"蓝牙状态=\(central.state.rawValue)")
        if central.state != .poweredOn {
            if writer != nil { fault = true; event(nil,"bluetooth_unavailable") }
            for d in links.values { d.connected = false; d.initialized = false; d.subscribed = false; d.reading = nil; d.closing = false; d.status = "蓝牙不可用" }
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
        d.connected = true; d.stageAt = Self.now(); d.status = "发现服务"; log(d,"已连接，开始发现服务"); peripheral.delegate = self; peripheral.discoverServices([CBUUID(string: WitProtocol.service)])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) { disconnected(peripheral,error) }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) { disconnected(peripheral,error) }
    private func disconnected(_ peripheral: CBPeripheral, _ error: Error?) {
        guard let d = links[peripheral.identifier], d.peripheral === peripheral else { return }
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
        d.subscribed = true; d.status = "读取固件与配置"; d.reads = [0x2e,0x03,0x23,0x24,0x96]; d.reading = nil
    }
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) { /* Fair timer resumes eligible writes; no firmware acknowledgement is implied. */ }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let d = links[peripheral.identifier], d.wanted && d.connected && d.subscribed && !d.closing, characteristic === d.notifier else { return }
        guard error == nil else { fail(d,"接收通知失败：\(detail(error))"); return }
        guard let bytes = characteristic.value else { return }
        let ns = Self.now(), wall = Self.wall(); writer?.raw(id:peripheral.identifier.uuidString,ns:ns,wall:wall,data:bytes)
        for frame in d.parser.accept(bytes) {
            writer?.frame(id:peripheral.identifier.uuidString,ns:ns,wall:wall,frame:frame,verified:d.registers[0x96] == 0)
            var indices: [Int] = []
            if frame.register == -1 && d.registers[0x96] == 0 { d.acceleration = frame.acceleration; d.gyro = frame.gyro; d.pose.add(ns:ns,acceleration:d.acceleration,gyro:d.gyro); indices = [0,1] }
            else if frame.register == 0x3a { d.magnetic = frame.words.prefix(3).map(Double.init); indices = [2]; d.scheduler.reply(frame.register) }
            else if frame.register == 0x51 { d.quaternion = frame.quaternion; indices = [3]; d.scheduler.reply(frame.register); if !frame.quaternionValid { d.invalidQ += 1; if writer != nil { fault = true } } }
            else if frame.register >= 0 {
                d.registers[frame.register] = frame.words[0] & 65535; d.settings[frame.register] = ["elapsed_ns":ns,"packet_hex":WitProtocol.hex(frame.bytes),"words":frame.words]
                if frame.register == 0x2e { let a = frame.words[0] & 65535, b = frame.words[1] & 65535; d.firmware = "\(((b & 32767) << 2) | (a >> 14)).\((a >> 8) & 63).\(a & 255)" }
                if d.reading == frame.register && ns >= d.readAt { log(d,String(format:"寄存器0x%02X回读=%d",frame.register,frame.words[0] & 65535)); d.reading = nil }
                if !d.initialized && d.reading == nil && d.reads.isEmpty && [0x2e,0x03,0x23,0x24,0x96].allSatisfy({d.registers[$0] != nil}) { d.initialized = true; d.status = "四项接收中"; log(d,"初始化完成，开始四项接收") }
            }
            for i in indices { d.recent[i].add(ns); if writer != nil && actionNS > 0 && d.trialStreams.count == 4 { d.trialStreams[i].add(ns) } }
        }
    }
}
