import Foundation
import SwiftUI
import BaduanjinCore

@MainActor final class AppModel: ObservableObject {
    @Published var engineState = EngineSnapshot()
    @Published var studies: [Study] = []
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
    var busy: Bool { pending || engineState.recording || engineState.saving || exporting || engineState.batch || engineState.movement }
    var book: SlotBook { SlotBook(studyID: study?.id ?? "", trials: trials) }
    init() {
        do {
            let docs = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            files = try StudyFiles(root: docs.appendingPathComponent("Baduanjin",isDirectory:true)); reload()
            let savedHz = UserDefaults.standard.integer(forKey:"queryHz"); queryHz = (40...200).contains(savedHz) ? savedHz:90
            engine.configure(root:files!.root,queryHz:queryHz)
        } catch { self.error = "读取本App记录失败：\(error.localizedDescription)；请先导出文件核查" }
        engine.onSnapshot = { [weak self] state in
            guard let self else { return }; self.engineState = state
            for d in state.devices where d.connected {
                var values = self.trend[d.id] ?? []; values.append(d.acceleration); if values.count > 120 { values.removeFirst(values.count-120) }; self.trend[d.id] = values
                var history = self.otherTrends[d.id] ?? [:]
                for (key,sample) in [("angular_velocity",d.gyro),("magnetic_field",d.magnetic),("quaternion",d.quaternion)] { var rows = history[key] ?? []; rows.append(sample); if rows.count > 120 { rows.removeFirst(rows.count-120) }; history[key] = rows }; self.otherTrends[d.id] = history
            }
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
            try files.recover(); studies = try files.studies(); study = files.study; roster = files.roster; trials = files.trials
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
    func create(_ subject: String) { perform { try $0.create(subject: subject,at:BluetoothEngine.wall()) } }
    func activate(_ id: String) { perform { try $0.activate(id) } }
    func rename(_ names: [String]) { perform { try $0.rename(names,at:BluetoothEngine.wall()) } }
    func bind(role: String, id: String, name: String) { perform { try $0.bind(role:role,id:id,name:name) } }
    func retry(_ trial: Trial, reason: String) { perform { try $0.markRetry(id:trial.id,reason:reason,revision:trial.reviews.count,at:BluetoothEngine.wall()) } }
    func diagnostic(seconds: Int) { guard !busy, let files else { return }; pending = true; engine.startDiagnostic(root:files.sessions,roster:roster,study:study,seconds:seconds) }
    func start(action: Int, slot: Int) {
        guard !busy, let files, let study else { return }
        do {
            guard preflight.ready else { throw LabError.invalid(preflight.blockers.map { $0.title+"："+$0.detail }.joined(separator:"\n")) }
            let assignment = try book.begin(action:action,slot:slot); pending = true
            engine.startFormal(root:files.sessions,roster:roster,study:study,assignment:assignment,classificationOK:files.warnings.isEmpty)
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
    func batch(calibrate: Bool, rewrite: Bool = false, placementConfirmed: Bool = false) { guard !busy else { return }; pending = true; engine.beginBatch(calibrate:calibrate,rewrite:rewrite,placementConfirmed:placementConfirmed) }
    func setQueryHz() { guard !busy, (40...200).contains(queryHz) else { return }; UserDefaults.standard.set(queryHz,forKey:"queryHz"); engine.setQueryHz(queryHz) }
    func export(_ rows: [Trial]) {
        guard !busy, let files else { return }; exporting = true; exportProgress = "准备导出…"
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
    func device(_ role: BodyRole) -> DeviceSnapshot? { guard let id = roster[role.id]?.peripheralID else { return nil }; return engineState.devices.first { $0.id == id } }
    var preflight: PreflightResult {
        let now = BluetoothEngine.now(), stamp = engineState.timestamp
        return Preflight.evaluate(study:study?.id,nextAction:book.nextAction,roster:roster,devices:engineState.devices.map(\.readiness),idle:!busy,bluetooth:engineState.enabled,freeBytes:engineState.freeBytes,fresh:stamp > 0 && now >= stamp && now-stamp < secondNS,normalMode:!engineState.passive,classificationOK:files?.warnings.isEmpty == true)
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
