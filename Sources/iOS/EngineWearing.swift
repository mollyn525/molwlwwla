import Foundation
import BaduanjinCore

extension BluetoothEngine {
    func captureReference(roster: [String:SensorBinding], studyID: String, diagnostic: Bool) { work.async {
        guard self.idle(), self.magneticJob.phase != .uncertain, self.appActive, !self.passive else { self.message = "请先结束其他操作并保持前台"; self.notifyRequestFinished(); return }
        let selected = roster.filter { _,b in guard let id = UUID(uuidString:b.peripheralID) else { return false }; return self.links[id]?.wanted == true }
        guard !selected.isEmpty, diagnostic || selected.count == 15 else { self.message = "完整参考需要15个已绑定且选定的部位"; self.notifyRequestFinished(); return }
        let epochs = Dictionary(uniqueKeysWithValues:selected.compactMap { role,b -> (String,UUID)? in
            guard let id = UUID(uuidString:b.peripheralID), let d = self.links[id], d.connected && d.initialized else { return nil }
            d.pose = PoseWindow(); d.quaternionWindow = QuaternionWindow(); return (role,d.generation)
        })
        guard epochs.count == selected.count else { self.message = "选定部位尚未全部就绪"; self.notifyRequestFinished(); return }
        let generation = UUID(); self.referenceGeneration = generation
        self.referencePending = true; self.message = "请保持中立参考站姿3.2秒，双臂自然下垂，双脚平放，勿移动"
        self.work.asyncAfter(deadline:.now()+3.2) {
            guard self.referencePending, self.referenceGeneration == generation else { return }; self.referencePending = false
            defer { self.notifyRequestFinished() }
            do {
                guard self.appActive else { throw LabError.invalid("应用已离开前台") }
                var captured: [String:SensorBinding] = [:]; let referenceID = "pose-"+UUID().uuidString
                for (role,var b) in selected {
                    guard let id = UUID(uuidString:b.peripheralID), let d = self.links[id], d.generation == epochs[role], d.connected && d.initialized else { throw LabError.invalid("\(role)连接发生变化") }
                    let issues = d.pose.stabilityIssues(now:Self.now())
                    guard issues.isEmpty else { throw LabError.invalid("\(role)："+issues.joined(separator:"；")) }
                    b.reference = try d.quaternionWindow.estimate(now:Self.now()); b.gravity = d.pose.mean; b.referenceID = referenceID
                    b.referenceStudyID = studyID; b.referenceDiagnostic = diagnostic; b.referenceMS = Self.wall(); b.wearConfirmed = false; b.movement = nil
                    captured[role] = b
                }
                self.message = "已取得\(captured.count)个部位的参考，请继续引导动作和人工确认"
                DispatchQueue.main.async { self.onReferences?(captured,studyID,diagnostic) }
            } catch { self.message = "参考采集未通过："+error.localizedDescription }
        }
    } }
    func inspectRole(_ role: String, roster: [String:SensorBinding]) { work.async {
        guard self.idle(), self.magneticJob.phase != .uncertain, self.appActive, let b = roster[role], b.reference != nil, b.referenceID != nil,
              let id = UUID(uuidString:b.peripheralID), let target = self.links[id], target.connected && target.initialized && target.wanted else { self.message = "先完成参考姿态并连接目标部位"; self.notifyRequestFinished(); return }
        let start = Self.now(); self.movementRole = role; self.movementEnd = start+5*secondNS; self.movementRoster = roster
        self.movementWindows = Dictionary(uniqueKeysWithValues:roster.values.map { ($0.peripheralID,MovementWindow(start:start,end:self.movementEnd)) })
        self.message = "请按部位引导活动5秒，允许相邻肢段自然联动，其余部位尽量不动"; self.notifyRequestFinished()
    } }
    func finishMovement() {
        guard let role = movementRole, let b = movementRoster[role], let refID = b.referenceID else { cancelWearing("动作检查状态缺失"); return }
        let evidence = BodyRole.all.compactMap { peer -> MovementEvidence? in
            guard let p = movementRoster[peer.id], let window = movementWindows[p.peripheralID] else { return nil }
            return MovementEvidence(role:peer.id,window:window,coupled:MovementReport.coupled(target:role,other:peer.id))
        }
        let report = MovementReport(role:role,at:Self.wall(),evidence:evidence)
        movementRole = nil; movementEnd = 0; movementWindows = [:]; movementRoster = [:]; message = report.result
        DispatchQueue.main.async { self.onMovement?(report,b.peripheralID,refID) }; notifyRequestFinished()
    }
    func cancelWearing(_ reason: String) {
        guard movementRole != nil || referencePending else { return }
        movementRole = nil; movementEnd = 0; movementWindows = [:]; referencePending = false; message = reason; notifyRequestFinished()
    }
    func stopWearing() { work.async { self.cancelWearing("佩戴检查已取消，原始参考保留；本次不计完成") } }
}
