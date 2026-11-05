import Foundation
import CoreBluetooth
import BaduanjinCore

enum MagPhase {
    case idle, preparing, starting, rotating, finishing, checking, submitted, uncertain
    var busy: Bool { [.preparing,.starting,.rotating,.finishing,.checking].contains(self) }
    var writing: Bool { self == .starting || self == .finishing }
}

final class MagneticJob {
    var phase = MagPhase.idle
    var target: UUID?, generation: UUID?, due: UInt64 = 0, index = 0
    var message = "", operation = UUID(), before: Double?
}

extension BluetoothEngine {
    var magMarker: URL? { root?.appendingPathComponent("pending-magnetic-calibration.json") }
    func restoreMagTarget() {
        guard let file = magMarker, FileManager.default.fileExists(atPath:file.path) else { return }
        let marker = try? JSONFile.read(file)
        magneticJob.target = (marker?["target"] as? String).flatMap(UUID.init(uuidString:))
        magneticJob.before = marker?["before_ut"] as? Double
        if let value = marker?["operation"] as? String, let id = UUID(uuidString:value) { magneticJob.operation = id }
        magneticJob.phase = .uncertain
        magneticJob.message = magneticJob.target == nil ? "上次校准信息无法读取，请先核查操作日志。" : "上次操作中断。请重新连接原设备，核对后手动结束并保存。"
    }
    func magEligible(_ d: Link, _ now: UInt64) -> Bool {
        d.wanted && d.connected && d.initialized && d.subscribed && !d.closing && !d.maintenance &&
        d.writer != nil && !passive && WitProtocol.supportedFirmware(d.firmware) && d.registers[0x24] == 0 &&
        d.registers[0x96] == 0 && d.live.field != nil && (d.recent[2].age(now) ?? 1000) < 500
    }
    func magAudit(_ kind: String, _ extra: [String:Any] = [:]) throws {
        guard let root, let target = magneticJob.target else { throw LabError.invalid("缺少操作目录或设备") }
        var row = extra
        row["operation_id"] = magneticJob.operation.uuidString; row["address"] = target.uuidString
        row["type"] = "magnetic_calibration"; row["name"] = links[target]?.name ?? target.uuidString
        try OperationAudit.append(root:root,type:kind,details:row,at:Self.wall())
    }
    func interruptMag(_ why: String) {
        guard magneticJob.phase.busy else { return }
        magneticJob.phase = .uncertain
        magneticJob.message = why + "。硬件状态待核对，重新连接同一台后可手动结束并保存。"
        message = magneticJob.message
        try? magAudit("magnetic_interrupted",["reason":why])
    }
    func startMag(_ id: String) { work.async {
        let now = Self.now()
        guard self.idle(), self.appActive, self.magneticJob.phase != .uncertain,
              let uuid = UUID(uuidString:id), let d = self.links[uuid], self.magEligible(d,now),
              let marker = self.magMarker, let prepare = self.onMagPrepare else {
            self.message = "需要已核对固件、九轴配置和新鲜磁场数据的单台设备，并结束其他操作"; return
        }
        let job = self.magneticJob
        job.target = uuid; job.generation = d.generation; job.operation = UUID(); job.index = 0
        let token = job.operation
        job.before = d.live.field.map { $0.norm * FieldReading.reference }
        do {
            var data: [String:Any] = ["target":id,"operation":token.uuidString]
            data["before_ut"] = job.before
            try JSONFile.write(data,to:marker)
            try self.magAudit("magnetic_start_requested",data)
        } catch { self.restoreMagTarget(); self.message = "操作记录写入失败："+error.localizedDescription; return }
        job.phase = .preparing; job.message = "正在核对所选设备"
        self.central.stopScan(); self.scanning = false
        DispatchQueue.main.async { prepare(id) { issue in self.work.async {
            guard job.operation == token, job.phase == .preparing else { return }
            if let issue { self.interruptMag(issue); return }
            guard self.appActive, self.magEligible(d,Self.now()), d.generation == job.generation else { self.interruptMag("设备状态已变化"); return }
            d.live = LiveMonitor(); d.live.setType(d.registers[0x72]); d.goodSince = 0
            job.phase = .starting; job.due = Self.now()+WitMagSequence.intervalNS; job.message = "正在提交开始指令"
        } } }
    } }
    func finishMag(_ id: String) { work.async {
        let job = self.magneticJob
        guard let target = job.target, target.uuidString == id, let d = self.links[target],
              self.appActive, !self.passive, self.writer == nil, !self.saving, self.batch == nil, self.headingToken == nil,
              self.movementRole == nil, !self.referencePending, [.uncertain,.rotating].contains(job.phase),
              d.wanted, d.connected, d.subscribed, d.initialized, !d.closing, !d.maintenance,
              WitProtocol.supportedFirmware(d.firmware), d.registers[0x24] == 0, d.registers[0x96] == 0 else {
            self.message = "请核对并连接同一台设备后重试结束"; return
        }
        do { try self.magAudit("magnetic_finish_requested") }
        catch { job.message = error.localizedDescription; return }
        job.phase = .finishing; job.generation = d.generation; job.index = 0
        job.due = Self.now()+WitMagSequence.intervalNS; job.message = "正在退出并提交保存"
    } }
    func serviceMag(_ now: UInt64) {
        let job = magneticJob
        if job.phase == .checking, now >= job.due { completeMag(nil); return }
        guard job.phase.writing, now >= job.due else { return }
        guard let target = job.target, let d = links[target], appActive, d.generation == job.generation,
              d.connected, !d.closing, d.subscribed, let writer = d.writer else { interruptMag("连接已改变"); return }
        guard d.peripheral.canSendWriteWithoutResponse else {
            if now-job.due >= 2*secondNS { interruptMag("等待蓝牙写入超时") }; return
        }
        let sequence = job.phase == .starting ? WitMagSequence.start : WitMagSequence.finish
        let packet = sequence[job.index]
        do { try magAudit("operation_tx_intent",["hex":WitProtocol.hex(packet),"index":job.index,"phase":String(describing:job.phase)]) }
        catch { interruptMag("操作审计失败"); return }
        d.peripheral.writeValue(packet,for:writer,type:.withoutResponse)
        job.index += 1; job.due = Self.now()+WitMagSequence.intervalNS
        if job.index == sequence.count {
            if job.phase == .starting { job.phase = .rotating; job.message = "依次绕 X、Y、Z 指北轴慢转，完成后手动结束" }
            else { job.phase = .checking; job.due = Self.now()+3*secondNS; job.message = "已提交保存，等候新的磁场帧" }
        }
    }
    func observePostMag(_ d: Link, _ ns: UInt64) {
        guard magneticJob.phase == .checking, magneticJob.target == d.peripheral.identifier,
              let field = d.live.field else { return }
        completeMag(field.norm * FieldReading.reference)
    }
    func completeMag(_ after: Double?) {
        let job = magneticJob
        var result = "已提交保存；" + (after.map { String(format:"保存后首帧 %.2f µT",$0) } ?? "3秒内未收到有效磁场帧")
        if let before = job.before { result += String(format:"，开始前 %.2f µT",before) }
        var row: [String:Any] = ["save_submitted":true,"peripheral_acknowledged":false,"result":result]
        row["before_ut"] = job.before; row["after_ut"] = after
        do {
            try magAudit("operation_result", row)
            guard let marker = magMarker else { throw LabError.invalid("缺少操作标记") }
            try FileManager.default.removeItem(at:marker)
            job.phase = .submitted; job.message = result; message = result
            DispatchQueue.main.async { self.onOperationFinished?() }
        } catch { interruptMag("无法完成操作审计："+error.localizedDescription) }
    }
    func clearLiveReferences() { work.async {
        self.headingToken = nil
        for d in self.links.values { d.live = LiveMonitor(); d.live.setType(d.registers[0x72]) }
    } }
    func heading(_ ids: [String], revert: Bool, baseline: Bool = false) { work.async {
        let selected = ids.compactMap(UUID.init(uuidString:)).compactMap { self.links[$0] }
        guard self.idle(), self.appActive, !self.passive, !selected.isEmpty, selected.count == ids.count,
              selected.allSatisfy({ $0.wanted && $0.connected && $0.initialized && !$0.closing && !$0.maintenance }),
              !(self.magneticJob.phase == .uncertain && selected.contains { $0.peripheral.identifier == self.magneticJob.target }) else {
            self.message = "请核对选中的设备并结束当前操作"; return
        }
        if revert {
            for d in selected { var pose = d.live.pose; pose.revert(); d.live.changeHeading(pose) }
            self.message = "已恢复所选设备的原始航向"; return
        }
        let token = UUID(), placed = Self.now(), generations = selected.map(\.generation)
        self.headingToken = token; self.message = "已确认放稳，请保持姿态约3秒"
        self.work.asyncAfter(deadline:.now()+3.05) {
            guard self.headingToken == token else { return }
            defer { self.headingToken = nil }
            do {
                var poses: [PoseMonitor] = []
                let now = Self.now()
                for (idx,d) in selected.enumerated() {
                    guard d.connected, d.wanted, !d.closing, d.generation == generations[idx] else { throw LabError.invalid("设备连接已变化") }
                    var pose = d.live.pose
                    do { if baseline { try pose.setBaseline(now:now,confirmed:placed) } else { try pose.resetHeading(now:now,confirmed:placed) } }
                    catch { throw LabError.invalid(d.name+"："+error.localizedDescription) }
                    poses.append(pose)
                }
                for (d,pose) in zip(selected,poses) {
                    if baseline { d.live.pose = pose } else { d.live.changeHeading(pose) }
                }
                self.message = baseline ? "已保存观察基线" : "已将所选设备当前航向设为零"
            } catch { self.message = error.localizedDescription }
        }
    } }
}

