import Foundation

/// Only missing/recovering window evidence may wait. Motion and persistent stream loss never clear.
public struct CalibrationCheck {
    public var pending: [String], failures: [String]
    public var restartWindow: Bool
    public init(pending: [String] = [], failures: [String] = [], restartWindow: Bool = false) { self.pending = pending; self.failures = failures; self.restartWindow = restartWindow }
}

/// A write completion here means local submission and settling, never firmware acknowledgement.
public protocol CalibrationPort: AnyObject {
    var nowMS: UInt64 { get }
    var connected: Bool { get }
    func later(_ milliseconds: UInt64, _ action: @escaping () -> Void)
    func stableIssues(beforeSave: Bool) -> [String]
    func recoveryCheck() -> CalibrationCheck
    func resetVerificationWindow()
    func write(_ register: Int, _ value: Int, completion: @escaping (Bool,String) -> Void)
    func started()
    func phase(_ name: String)
    func verifySaved(_ completion: @escaping (Bool,String) -> Void)
}
public final class CalibrationController {
    public static let recoveryLimitMS: UInt64 = 8000
    private let port: CalibrationPort, completion: (Bool,String) -> Void, entered: UInt64
    private var finished = false, waiting = false, step = 0
    private var readbackFinished = false, recoveryPhase = ""
    public init(port: CalibrationPort, completion: @escaping (Bool,String) -> Void) { self.port = port; self.completion = completion; entered = port.nowMS }
    public func begin() {
        guard stable(false) else { return }; port.phase("waiting_unlock")
        port.later(100) { [self] in guard stable(false) else { return }; send(0x69,0xb588) { [self] in port.later(100) { [self] in start() } } }
    }
    public func cancel(_ reason: String) { end(false,reason) }
    private func end(_ ok: Bool, _ reason: String) { guard !finished else { return }; finished = true; port.phase(ok ? "verified_static":"failed"); completion(ok,reason) }
    private func active() -> Bool { guard !finished else { return false }; if !port.connected { end(false,"连接或前台状态已变化；不在重连后继续校准"); return false }; return true }
    private func stable(_ saving: Bool) -> Bool {
        guard active() else { return false }; let issues = port.stableIssues(beforeSave:saving)
        if !issues.isEmpty { end(false,(saving ? "保存前复核未通过，未发送保存：":"原始+Z放稳检查未通过，未启动校准：")+issues.joined(separator:"；")); return false }
        return true
    }
    private func start() {
        guard stable(false) else { return }; port.phase("starting")
        send(1,1) { [self] in port.started(); port.phase("waiting_save"); waitUntil(max(entered+11000,port.nowMS+10800)) }
    }
    private func waitUntil(_ deadline: UInt64) {
        port.later(deadline > port.nowMS ? deadline-port.nowMS : 0) { [self] in
            guard active() else { return }; if port.nowMS < deadline { waitUntil(deadline); return }
            inspectWindow(afterSave:false,deadline:port.nowMS+Self.recoveryLimitMS)
        }
    }
    private func inspectWindow(afterSave: Bool, deadline: UInt64) {
        guard active() else { return }
        let check = port.recoveryCheck()
        let prefix = afterSave ? "已提交保存，后续复核未通过：":"保存前复核未通过，未发送保存："
        if !check.failures.isEmpty { end(false,prefix+check.failures.joined(separator:"；")); return }
        if !check.pending.isEmpty {
            guard port.nowMS < deadline else { end(false,prefix+"等待数据恢复及完整稳定窗口超过8秒："+check.pending.joined(separator:"；")); return }
            let name = afterSave ? "recovering_after_save":"recovering_before_save"
            if recoveryPhase != name || check.restartWindow {
                recoveryPhase = name; port.phase(name)
                // Do not mix samples from before/after a calibration-related output step.
                // Only the recent verification window resets; the full-operation monitor and deadline do not.
                port.resetVerificationWindow()
            }
            port.later(min(200,deadline-port.nowMS)) { [self] in inspectWindow(afterSave:afterSave,deadline:deadline) }
            return
        }
        if afterSave {
            if readbackFinished { end(true,"三指令流程、回读及静态复核通过；内部完成应答未知"); return }
            port.phase("post_save_readback"); step += 1; let expected = step; waiting = true
            port.verifySaved { [self] ok,why in
                guard !finished, waiting, step == expected else { return }; waiting = false
                guard active() else { return }; guard ok else { end(false,"已提交保存，回读未通过："+why); return }
                readbackFinished = true
                // A gap while reading registers must also recover within the same bounded window.
                inspectWindow(afterSave:true,deadline:deadline)
            }
        } else {
            port.phase("saving_without_second_unlock")
            send(0,0) { [self] in
                guard active() else { return }; port.phase("post_save_verification")
                port.later(500) { [self] in
                    guard active() else { return }; port.resetVerificationWindow()
                    port.later(3200) { [self] in
                        guard active() else { return }
                        inspectWindow(afterSave:true,deadline:port.nowMS+Self.recoveryLimitMS)
                    }
                }
            }
        }
    }
    private func send(_ register: Int, _ value: Int, _ next: @escaping () -> Void) {
        guard active() else { return }; step += 1; let expected = step; waiting = true
        port.write(register,value) { [self] ok,why in
            guard !finished, waiting, step == expected else { return }; waiting = false
            guard active() else { return }; if !ok { end(false,"命令未完成："+why); return }; next()
        }
    }
}
public struct ConfigurationPlan {
    public let originalOrient: Int, commands: [(Int,Int)]
    public init(registers: [Int:Int], rewrite: Bool) throws {
        guard let orient = registers[0x23], registers[0x03] != nil, registers[0x24] != nil, registers[0x96] == 0 else { throw LabError.invalid("配置旧值未完整回读，或不是惯性输出模式") }
        originalOrient = orient
        var changes: [(Int,Int)] = []
        if rewrite || registers[3] != 8 { changes.append((3,8)) }
        if rewrite || registers[0x24] != 0 { changes.append((0x24,0)) }
        commands = changes.isEmpty ? [] : [(0x69,0xb588)]+changes+[(0,0)]
    }
    public func matches(_ registers: [Int:Int]) -> Bool { registers[3] == 8 && registers[0x24] == 0 && registers[0x23] == originalOrient && registers[0x96] == 0 }
}
