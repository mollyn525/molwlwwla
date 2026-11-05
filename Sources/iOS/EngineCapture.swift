import Foundation
import CoreBluetooth
import BaduanjinCore

extension BluetoothEngine {
    func refreshStorage() {
        guard let root else { return }
        freeBytes = (try? FileManager.default.attributesOfFileSystem(forPath:root.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? -1
    }
    func notifyRequestFinished() { publish(Self.now()); DispatchQueue.main.async { self.onRequestFinished?() } }
    func readiness(_ d: Link, _ now: UInt64) -> DeviceReadiness {
        var r = DeviceReadiness(id:d.peripheral.identifier.uuidString)
        r.name = d.name
        r.wanted = d.wanted; r.connected = d.connected; r.initialized = d.initialized; r.maintenance = d.maintenance
        r.configurationOK = d.registers[3] == 8 && d.registers[0x24] == 0 && d.registers[0x96] == 0
        r.ages = d.recent.map { $0.age(now) }; r.hz = (0..<4).map { d.recent[$0].rate(now,seconds:10) }
        r.checkedSeconds = d.goodSince > 0 && d.readyAt > 0 && now >= max(d.goodSince,d.readyAt) ? Double(now-max(d.goodSince,d.readyAt))/1e9:0
        r.status = d.maintenance ? "维护中":d.status
        return r
    }
    func updateHealth(_ now: UInt64) {
        for d in links.values {
            guard d.wanted, d.connected, d.initialized, !d.maintenance, !passive else { d.goodSince = 0; continue }
            var good = true
            for k in 0..<4 {
                let age = d.recent[k].age(now) ?? (d.readyAt > 0 ? Double(now-d.readyAt)/1e6 : 2000)
                let level = age >= 2000 ? 2 : age >= 500 ? 1 : 0
                if level != d.severity[k] { log(d,"stream_health \(streams[k]) severity=\(level) age_ms=\(age)"); d.severity[k] = level }
                if QualityPolicy.current.requires(k) && (d.recent[k].last == nil || level > 0) { good = false; if writer != nil && targets.contains(d.peripheral.identifier) { fault = true } }
            }
            if good { if d.goodSince == 0 { d.goodSince = now } } else { d.goodSince = 0 }
        }
    }
    func startDiagnostic(root: URL, roster: [String:SensorBinding], study: Study? = nil, seconds: Int = 60) {
        work.async { self.beginRecording(root:root,roster:roster,study:study,assignment:nil,seconds:seconds,classificationOK:true) }
    }
    func startFormal(root: URL, roster: [String:SensorBinding], study: Study, assignment: Assignment, classificationOK: Bool) {
        work.async { self.beginRecording(root:root,roster:roster,study:study,assignment:assignment,seconds:0,classificationOK:classificationOK) }
    }
    func beginRecording(root: URL, roster: [String:SensorBinding], study: Study?, assignment: Assignment?, seconds: Int, classificationOK: Bool) {
        defer { notifyRequestFinished() }
        guard idle(), magneticJob.phase != .uncertain, appActive, !passive, central.state == .poweredOn else { message = "请保持前台并结束其他操作，正常连接后再录制"; return }
        let diagnostic = assignment == nil
        guard !diagnostic || seconds == 0 || (5...600).contains(seconds) else { message = "限时诊断5–600秒，或选择手动结束"; return }
        refreshStorage()
        let selected = links.filter { $0.value.wanted }
        guard !selected.isEmpty, selected.values.allSatisfy({ $0.initialized && $0.connected && !$0.closing && !$0.maintenance }) else { message = "选定设备必须全部连接并初始化"; return }
        if let assignment {
            let check = Preflight.evaluate(study:study?.id,nextAction:assignment.action,roster:roster,devices:links.values.map { readiness($0,Self.now()) },idle:idle(),bluetooth:true,freeBytes:freeBytes,fresh:true,normalMode:!passive,classificationOK:classificationOK)
            guard check.ready, assignment.study_id == study?.id else { message = "正式采前检查未通过："+(check.blockers.first.map { $0.title+"，"+$0.detail } ?? "采集任务不一致"); return }
        }
        do {
            var meta: [String:Any] = ["schema_version":7,"quality_policy":QualityPolicy.current.metadata,"platform":"iOS","package":Bundle.main.bundleIdentifier ?? "dev.imulink.baduanjin.ios",
                "app_version":Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "unknown",
                "app_build":Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "unknown",
                "system_version":ProcessInfo.processInfo.operatingSystemVersionString,"identity_kind":"corebluetooth_uuid_not_mac",
                "diagnostic":diagnostic,"action_acceptance_policy":"default_normal_if_quality_passed","logic_profile":WitProtocol.profile,
                "recorded_ms":Self.wall(),"time_zone_offset_seconds":TimeZone.current.secondsFromGMT(),"roster":try JSONSerialization.jsonObject(with:JSONEncoder().encode(roster)),
                "internal_sampling_synchronization_verified":false,"sampling_clock":"phone_receive_monotonic_not_sensor_sampling","host_query_hz":queryHz,
                "relative_pose_method":"conjugate_normalized_reference_times_normalized_current; neutral_reference_not_anatomical_frame"]
            meta["live_monitor"] = PoseMonitor.definition
            meta["magnetic_reference_ut"] = FieldReading.reference
            meta["devices"] = selected.map { id,d in ["address":id.uuidString,"name":d.name,"firmware":d.firmware,"settings":Dictionary(uniqueKeysWithValues:d.settings.map { (String($0.key),$0.value) })] as [String:Any] }
            meta["formal_start_policy"] = "15_ready_connections_and_inertial_gt40; wear_reference_configuration_are_reminders"
            if !diagnostic {
                let check = Preflight.evaluate(study:study?.id,nextAction:assignment?.action,roster:roster,devices:links.values.map { readiness($0,Self.now()) },idle:idle(),bluetooth:true,freeBytes:freeBytes,fresh:true,normalMode:!passive,classificationOK:classificationOK)
                meta["preflight_reminders"] = check.reminders.map { ["id":$0.id,"title":$0.title,"detail":$0.detail] }
            }
            meta["relative_pose_missing_reference_policy"] = "raw_data_retained; no_fabricated_or_diagnostic_or_other_study_reference"
            if let study { meta["study"] = try JSONFile.object(study); meta["study_id"] = study.id }
            if let assignment { meta["assignment"] = try JSONFile.object(assignment); meta["action_name"] = study!.actions[assignment.action] }
            writer = try SessionWriter(root:root,metadata:meta)
            targets = Array(selected.keys); startNS = Self.now(); actionNS = 0; endNS = seconds > 0 ? startNS+UInt64(seconds+3)*secondNS:0
            fault = false; recordingDiagnostic = diagnostic; recordingAssignment = assignment; recordingRoster = roster; overMinute = false
            for role in Array(recordingRoster.keys) {
                let unique = roster.values.filter { $0.peripheralID == roster[role]?.peripheralID }.count == 1
                if !unique || recordingRoster[role]?.hasRecordingReference(studyID:study?.id) != true { recordingRoster[role]?.reference = nil; recordingRoster[role]?.referenceID = nil }
            }
            for d in selected.values { d.trialStreams = []; d.invalidQ = 0; d.severity = [0,0,0,0]; d.parser = WitParser(); d.trialDiscarded = 0; d.submittedQueries = 0; d.backpressureTicks = 0; d.writeReadyCallbacks = 0 }
            event(nil,"record_start countdown_seconds=3"); message = "数据已开始保存，3秒后标记动作开始"
        } catch { message = "录制未启动："+error.localizedDescription; DispatchQueue.main.async { self.onSaved?() } }
    }
}
