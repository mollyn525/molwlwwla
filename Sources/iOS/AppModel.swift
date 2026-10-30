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
    private(set) var files: StudyFiles?
    let engine = BluetoothEngine()
    private var cancellation: ExportCancellation?
    var busy: Bool { engineState.recording || engineState.saving || exporting }
    var book: SlotBook { SlotBook(studyID: study?.id ?? "", trials: trials) }
    init() {
        do {
            let docs = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            files = try StudyFiles(root: docs.appendingPathComponent("Baduanjin",isDirectory:true)); reload()
        } catch { self.error = "读取本App记录失败：\(error.localizedDescription)；请先导出文件核查" }
        engine.onSnapshot = { [weak self] state in
            guard let self else { return }; self.engineState = state
            for d in state.devices where d.connected { var values = self.trend[d.id] ?? []; values.append(d.acceleration); if values.count > 120 { values.removeFirst(values.count-120) }; self.trend[d.id] = values }
        }
        engine.onSaved = { [weak self] in self?.reload() }
    }
    func reload() {
        guard let files else { return }
        do { try files.recover(); studies = try files.studies(); study = files.study; roster = files.roster; trials = files.trials; if !files.warnings.isEmpty { error = files.warnings.joined(separator:"\n") } }
        catch { self.error = error.localizedDescription }
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
    func diagnostic(seconds: Int) { guard !busy, let files else { return }; engine.startDiagnostic(root:files.sessions,roster:roster,seconds:seconds) }
    func export(_ rows: [Trial]) {
        guard !busy, let files else { return }; exporting = true; exportProgress = "准备导出…"
        let cancellation = ExportCancellation(); self.cancellation = cancellation
        let staged = files.root.appendingPathComponent("exports/\(UUID().uuidString).partial.zip")
        let destination = files.root.appendingPathComponent("exports/八段锦-\(BluetoothEngine.wall()).zip")
        let sessions = files.sessions, allTrials = trials
        DispatchQueue.global(qos:.utility).async {
            do {
                try ArchiveExporter.export(sessions:sessions,trials:rows,destination:staged,cancel:cancellation,allTrials:allTrials) { done,total in DispatchQueue.main.async { self.exportProgress = "已整理 \(done)/\(total) 条" } }
                try cancellation.check(); try FileManager.default.moveItem(at:staged,to:destination)
                DispatchQueue.main.async { self.exporting = false; self.shareURL = destination; self.exportProgress = "导出完成，附SHA-256文件清单"; self.cancellation = nil }
            } catch { DispatchQueue.main.async { self.exporting = false; self.error = error.localizedDescription; self.cancellation = nil; self.exportProgress = "导出未完成，原记录保留" } }
        }
    }
    func cancelExport() { cancellation?.cancel() }
    func device(_ role: BodyRole) -> DeviceSnapshot? { guard let id = roster[role.id]?.peripheralID else { return nil }; return engineState.devices.first { $0.id == id } }
    var checklist: [String] {
        var result = ["iOS正式采集尚未验收，当前先进行设备诊断"]
        for role in BodyRole.all {
            guard let binding = roster[role.id] else { result.append("\(role.name)：未绑定"); continue }
            guard let d = device(role), d.connected && d.initialized else { result.append("\(role.name)：未连接或未初始化"); continue }
            if !d.configurationOK { result.append("\(role.name)：配置未达到50Hz/九轴要求") }
            if !d.issues.isEmpty { result.append("\(role.name)：\(d.issues.joined(separator:"、"))") }
            if !binding.wearConfirmed || binding.reference == nil { result.append("\(role.name)：佩戴核验及参考姿态未完成") }
        }; return result
    }
}
