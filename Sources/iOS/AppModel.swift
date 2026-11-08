import Foundation
import SwiftUI
import BaduanjinCore

@MainActor final class AppModel: ObservableObject {
    @Published var engineState = EngineSnapshot()
    @Published var studies: [Study] = []
    @Published var deletedStudies: [DeletedStudy] = []
    @Published var trials: [Trial] = []
    @Published var roster: [String: SensorBinding] = [:]
    @Published var study: Study?
    @Published var error: String?
    @Published var exporting = false
    @Published var exportProgress = ""
    @Published var shareURL: URL?
    @Published var trend: [String: [[Double]]] = [:]
    @Published var otherTrends: [String:[String:[[Double]]]] = [:]
    @Published var pending = false
    @Published var details: [String:RecordDetail] = [:]
    @Published var operationHistory: [OperationDetail] = []
    @Published var queryHz = 90
    private(set) var files: StudyFiles?
    let engine = BluetoothEngine()
    private var cancellation: ExportCancellation?
    var busy: Bool { pending || engineState.magPhase.busy || engineState.headingPending || engineState.recording || engineState.saving || exporting || engineState.batch || engineState.movement }
    var book: SlotBook { SlotBook(studyID: study?.id ?? "", trials: trials) }
    init() {
        do {
            let docs = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            var storage = docs.appendingPathComponent("Baduanjin",isDirectory:true)
            #if DEBUG
            if let argument = ProcessInfo.processInfo.arguments.first(where:{ $0.hasPrefix("--ui-storage-id=") }),
               let id = UUID(uuidString:String(argument.dropFirst("--ui-storage-id=".count))) {
                storage = docs.appendingPathComponent("BaduanjinUITests/"+id.uuidString,isDirectory:true)
            }
            #endif
            files = try StudyFiles(root:storage); reload()
            let savedHz = UserDefaults.standard.integer(forKey:"queryHz"); queryHz = (40...200).contains(savedHz) ? savedHz:90
            engine.configure(root:files!.root,queryHz:queryHz)
        } catch { self.error = "读取本App记录失败：\(error.localizedDescription)；请先导出文件核查" }
        engine.onSnapshot = { [weak self] state in
            guard let self else { return }; self.engineState = state
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--recording-dock-ui-fixture") {
                self.engineState.recording = true; self.engineState.saving = false
                self.engineState.recordingCalibration = .dynamicSquats; self.engineState.countdown = 0; self.engineState.elapsed = 2
            }
            if ProcessInfo.processInfo.arguments.contains("--parallel-calibration-ui-fixture") {
                self.engineState.batch = true; self.engineState.parallelCalibration = true
                self.engineState.batchMessage = "并行校准：2/15台结束 · 通过1台；请保持全组不动"
                self.engineState.operationProgress = (0..<15).map { i in
                    OperationProgress(id:"UI_PARALLEL_\(i)",name:"模拟设备\(i+1)",message:i == 0 ? "保存后静态复核通过":i == 1 ? "该设备断线；其他设备继续":"保持不动，独立等待保存",finished:i < 2,passed:i == 0,saveSubmitted:i == 0)
                }
            }
            #endif
            for d in state.devices where d.connected {
                var values = self.trend[d.id] ?? []; values.append(d.acceleration); if values.count > 120 { values.removeFirst(values.count-120) }; self.trend[d.id] = values
                var history = self.otherTrends[d.id] ?? [:]
                for (key,sample) in [("angular_velocity",d.gyro),("magnetic_field",d.magnetic),("quaternion",d.quaternion)] { var rows = history[key] ?? []; rows.append(sample); if rows.count > 120 { rows.removeFirst(rows.count-120) }; history[key] = rows }; self.otherTrends[d.id] = history
            }
        }
        engine.onMagPrepare = { [weak self] id, done in
            guard let self, let files = self.files else { done("无法读取名册"); return }
            do { try files.invalidateWear(peripheralID:id); self.roster = files.roster; self.study = files.study; done(nil) }
            catch { done(error.localizedDescription) }
        }
        engine.onSaved = { [weak self] in self?.reload() }
        engine.onRequestFinished = { [weak self] in self?.pending = false }
        engine.onOperationFinished = { [weak self] in self?.reload() }
        engine.onOperationResult = { [weak self] row in
            guard let self, let result = OperationDetail(row) else { return }
            self.operationHistory.removeAll { $0.id == result.id }; self.operationHistory.insert(result,at:0)
        }
        engine.onReferences = { [weak self] references,studyID,diagnostic in
            guard let self, let files = self.files else { return }
            do { try files.saveReferences(references,studyID:studyID,diagnostic:diagnostic,at:BluetoothEngine.wall()); self.reload() } catch { self.error = error.localizedDescription }
        }
        engine.onMovement = { [weak self] report,id,reference in
            guard let self, let files = self.files else { return }
            do { try files.saveMovement(report,peripheralID:id,referenceID:reference); self.reload() } catch { self.error = error.localizedDescription }
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--recording-dock-ui-fixture") {
            study = try? Study(subject:"UI_FIXTURE",at:1)
        }
        if ProcessInfo.processInfo.arguments.contains("--lifecycle-ui-fixture"),
           ProcessInfo.processInfo.arguments.contains(where:{ $0.hasPrefix("--ui-storage-id=") }), let files {
            engine.prepareLifecycleFixture(files.sessions)
        }
        // Simulator UI fixture only; in-memory, no hardware writes or persistent history changes.
        if ProcessInfo.processInfo.arguments.contains("--calibration-ui-fixture") {
            let details: [String:Any] = ["operation_id":"UI_CALIBRATION","name":"模拟设备","type":"accelerometer_calibration","save_submitted":true,"static_check_passed":true,"final_window_passed":true,"result":"静态复核通过（模拟界面测试）","fresh_before":["static_mean_g":[0.01,0.02,0.99]],"after":["static_mean_g":[0.0,0.0,1.0]],"recovering_before_save_entered":true]
            operationHistory = [OperationDetail(["type":"operation_result","wall_ms":1,"details":details])].compactMap { $0 }
        }
        #endif
    }
    func reload() {
        guard let files else { return }
        do {
            try files.recover(); studies = try files.studies(); deletedStudies = try files.deletedStudies(); study = files.study; roster = files.roster; trials = files.trials
            details = Dictionary(uniqueKeysWithValues:trials.compactMap { trial in
                guard let meta = try? files.metadata(trial.id), let summary = try? files.summary(trial.id) else { return nil }
                return (trial.id,RecordDetail(metadata:meta,summary:summary))
            })
            reloadOperationHistory()
            if !files.warnings.isEmpty { error = files.warnings.joined(separator:"\n") }
        }
        catch { self.error = error.localizedDescription }
    }
    func reloadOperationHistory() {
        guard let files else { return }
        do { operationHistory = try OperationAudit.read(root:files.root).reversed().compactMap(OperationDetail.init) }
        catch { operationHistory = []; self.error = error.localizedDescription }
    }
    func perform(_ body: (StudyFiles) throws -> Void) {
        guard !busy, let files else { return }
        do { try body(files); reload() } catch { self.error = error.localizedDescription }
    }
    func create(_ subject: String) { perform { try $0.create(subject: subject,at:BluetoothEngine.wall()); engine.clearLiveReferences() } }
    func activate(_ id: String) { perform { try $0.activate(id); engine.clearLiveReferences() } }
    private func manageStudy(_ operation: (StudyFiles) throws -> Void) {
        guard !busy, let files else { return }
        do { try operation(files) } catch { self.error = error.localizedDescription }
        reload()
    }
    func trashStudy(_ id: String) {
        let wasActive = study?.id == id
        manageStudy { try $0.trashStudy(id,at:BluetoothEngine.wall()) }
        if wasActive && study == nil { engine.clearLiveReferences() }
    }
    func restoreStudy(_ id: String) { manageStudy { try $0.restoreStudy(id) } }
    func purgeStudy(_ id: String) { manageStudy { try $0.permanentlyDeleteStudy(id) } }
    func rename(_ names: [String]) { perform { try $0.rename(names,at:BluetoothEngine.wall()) } }
    func bind(role: String, id: String, name: String) { perform { try $0.bind(role:role,id:id,name:name); engine.clearLiveReferences() } }
    func retry(_ trial: Trial, reason: String) { perform { try $0.markRetry(id:trial.id,reason:reason,revision:trial.reviews.count,at:BluetoothEngine.wall()) } }
    func setMountingLabel(_ value: MountingLabel) { perform { try $0.setMountingLabel(value) } }
    var calibrationSetup: String? {
        guard let study else { return nil }
        let directions = Dictionary(uniqueKeysWithValues:engineState.devices.filter(\.wanted).map { ($0.id,$0.installationOrientation ?? -1) })
        return try? SubjectCalibration.setup(study:study,roster:roster,orientations:directions)
    }
    func calibrationCompleted(_ kind: SubjectCalibrationKind) -> Bool {
        guard let study, let setup = calibrationSetup else { return false }
        return SubjectCalibration.completed(kind,studyID:study.id,setup:setup,trials:trials)
    }
    func startCalibration(_ kind: SubjectCalibrationKind) {
        guard !busy, let files, let study else { return }
        guard calibrationPreflight.ready else { error = calibrationPreflight.blockers.map { $0.title+"，"+$0.detail }.joined(separator:"\n"); return }
        pending = true
        engine.startSubjectCalibration(root:files.sessions,roster:roster,study:study,kind:kind,classificationOK:files.warnings.isEmpty)
    }
    func diagnostic(seconds: Int) { guard !busy, let files else { return }; pending = true; engine.startDiagnostic(root:files.sessions,roster:roster,study:study,seconds:seconds) }
    func start(action: Int, slot: Int) {
        guard !busy, let files, let study else { return }
        do {
            guard preflight.ready else { throw LabError.invalid(preflight.blockers.map { $0.title+"："+$0.detail }.joined(separator:"\n")) }
            let assignment = try book.begin(action:action,slot:slot); pending = true
            engine.startFormal(root:files.sessions,roster:roster,study:study,assignment:assignment,classificationOK:files.warnings.isEmpty,calibrationTrials:trials)
        } catch { self.error = error.localizedDescription }
    }
    func captureReference(diagnostic: Bool) { guard !busy, let study else { error = "请先新建或继续受试者任务"; return }; pending = true; engine.captureReference(roster:roster,studyID:study.id,diagnostic:diagnostic) }
    func inspect(_ role: String) {
        guard !busy, let files else { return }
        do { try files.beginMovement(role:role); roster = files.roster; pending = true; engine.inspectRole(role,roster:roster) } catch { self.error = error.localizedDescription }
    }
    func confirmWear(_ role: BodyRole, note: String) {
        guard device(role)?.initialized == true else { error = "请先连接并初始化该部位"; return }
        perform { try $0.confirmWear(role:role.id,note:note,at:BluetoothEngine.wall()) }
    }
    func invalidateWear() { perform { try $0.invalidateWear() } }
    func review(_ trial: Trial, accepted: Bool, reason: String) { perform { try $0.review(id:trial.id,decision:accepted ? "accepted":"rejected",reason:reason,revision:trial.reviews.count,at:BluetoothEngine.wall()) } }
    func batch(calibrate: Bool, rewrite: Bool = false, placementConfirmed: Bool = false) {
        guard !busy, let files else { return }
        do {
            try files.invalidateSubjectCalibration(); study = files.study
            pending = true; engine.beginBatch(calibrate:calibrate,rewrite:rewrite,placementConfirmed:placementConfirmed)
        } catch { self.error = error.localizedDescription }
    }
    func setQueryHz() { guard !busy, (40...200).contains(queryHz) else { return }; UserDefaults.standard.set(queryHz,forKey:"queryHz"); engine.setQueryHz(queryHz) }
    func export(_ rows: [Trial]) {
        guard !busy, let files else { return }
        guard rows.allSatisfy({ row in trials.contains(where:{ $0.id == row.id }) }) else { error = "记录已移入最近删除或不存在，请刷新后导出"; return }
        exporting = true; exportProgress = "准备导出…"
        let cancellation = ExportCancellation(); self.cancellation = cancellation
        let staged = files.root.appendingPathComponent("exports/\(UUID().uuidString).partial.zip")
        let destination = files.root.appendingPathComponent("exports/八段锦-\(BluetoothEngine.wall()).zip")
        let sessions = files.sessions, allTrials = trials
        var attachments: [String:Data] = [:]
        do {
            attachments["roster-at-export.json"] = try JSONEncoder().encode(roster)
            attachments["studies-at-export.json"] = try JSONEncoder().encode(studies)
            let operations = files.root.appendingPathComponent("operations.jsonl")
            if FileManager.default.fileExists(atPath:operations.path) { attachments["operations.jsonl"] = try Data(contentsOf:operations) }
        } catch { exporting = false; self.error = error.localizedDescription; return }
        let exportAttachments = attachments
        DispatchQueue.global(qos:.utility).async {
            do {
                try ArchiveExporter.export(sessions:sessions,trials:rows,destination:staged,cancel:cancellation,allTrials:allTrials,attachments:exportAttachments) { done,total in DispatchQueue.main.async { self.exportProgress = "已整理 \(done)/\(total) 条" } }
                try cancellation.check(); try FileManager.default.moveItem(at:staged,to:destination)
                DispatchQueue.main.async { self.exporting = false; self.shareURL = destination; self.exportProgress = "导出完成，附SHA-256文件清单"; self.cancellation = nil }
            } catch { DispatchQueue.main.async { self.exporting = false; self.error = error.localizedDescription; self.cancellation = nil; self.exportProgress = "导出未完成，原记录保留" } }
        }
    }
    func cancelExport() { cancellation?.cancel() }
    var version: String { "\(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "未知") (\(Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "?"))" }
    func exportConnectionDiagnostics() {
        guard !busy, let files else { return }
        let destination = files.root.appendingPathComponent("exports/connection-diagnostics-\(UUID().uuidString).json")
        let devices: [[String: Any]] = engineState.devices.filter { $0.wanted || !$0.lastError.isEmpty }.map {
            ["id":$0.id,"name":$0.name,"status":$0.status,"wanted":$0.wanted,"connected":$0.connected,"initialized":$0.initialized,"last_error":$0.lastError,"recent_10s_hz":$0.hz,"issues":$0.issues,"submitted_queries":$0.submittedQueries,"backpressure_ticks":$0.backpressureTicks,"write_ready_callbacks":$0.writeReadyCallbacks]
        }
        do {
            try JSONFile.write(["schema_version":1,"app_version":version,"system_version":ProcessInfo.processInfo.operatingSystemVersionString,"created_ms":BluetoothEngine.wall(),"service_uuid":WitProtocol.service,"notify_uuid":WitProtocol.notify,"write_uuid":WitProtocol.write,"devices":devices,"connection_log":engineState.connectionLog],to:destination)
            shareURL = destination
        } catch { self.error = "连接诊断导出失败：\(error.localizedDescription)" }
    }
    func monitorLabel(_ d: DeviceSnapshot) -> String {
        if let role = BodyRole.all.first(where:{ roster[$0.id]?.peripheralID == d.id }) { return role.name+" · "+d.name }
        return d.name+" · "+String(d.id.suffix(6))
    }
    func device(_ role: BodyRole) -> DeviceSnapshot? { guard let id = roster[role.id]?.peripheralID else { return nil }; return engineState.devices.first { $0.id == id } }
    private func checkAcquisition(nextAction: Int?) -> PreflightResult {
        let now = BluetoothEngine.now(), stamp = engineState.timestamp
        return Preflight.evaluate(study:study?.id,nextAction:nextAction,roster:roster,devices:engineState.devices.map(\.readiness),idle:!busy && engineState.magPhase != .uncertain,bluetooth:engineState.enabled,freeBytes:engineState.freeBytes,fresh:stamp > 0 && now >= stamp && now-stamp < secondNS,normalMode:!engineState.passive,classificationOK:files?.warnings.isEmpty == true)
    }
    var calibrationPreflight: PreflightResult { checkAcquisition(nextAction:0) }
    var preflight: PreflightResult {
        var result = checkAcquisition(nextAction:book.nextAction)
        for kind in SubjectCalibrationKind.allCases {
            result.checks.append(CheckItem(id:"subject_calibration_"+kind.rawValue,role:"",title:kind.title,passed:calibrationCompleted(kind),detail:kind == .staticPose ? "完成当前受试者的 N-pose 5秒采集" : "完成当前受试者的两个深蹲采集"))
        }
        return result
    }
    var checklist: [String] { preflight.checks.map { ($0.passed ? "✓ ":"待处理 · ")+$0.title+"："+$0.detail } }
    func exportOperations() {
        guard !busy, let files else { return }
        do {
            let source = files.root.appendingPathComponent("operations.jsonl")
            guard FileManager.default.fileExists(atPath:source.path) else { throw LabError.invalid("尚无操作审计") }
            let destination = files.root.appendingPathComponent("exports/operations-\(UUID().uuidString).jsonl")
            try FileManager.default.copyItem(at:source,to:destination); shareURL = destination
        } catch { self.error = error.localizedDescription }
    }
}
