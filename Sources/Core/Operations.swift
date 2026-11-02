import Foundation

/// A write completion here means local submission and settling, never firmware acknowledgement.
public protocol CalibrationPort: AnyObject {
    var nowMS: UInt64 { get }
    var connected: Bool { get }
    func later(_ milliseconds: UInt64, _ action: @escaping () -> Void)
    func stableIssues(beforeSave: Bool) -> [String]
    func write(_ register: Int, _ value: Int, completion: @escaping (Bool,String) -> Void)
    func started()
    func phase(_ name: String)
    func verifySaved(_ completion: @escaping (Bool,String) -> Void)
}
public final class CalibrationController {
    private let port: CalibrationPort, completion: (Bool,String) -> Void, entered: UInt64
    private var finished = false, waiting = false, step = 0
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
            guard stable(true) else { return }; port.phase("saving_without_second_unlock")
            send(0,0) { [self] in
                guard active() else { return }; port.phase("post_save_verification"); step += 1; let expected = step; waiting = true
                port.verifySaved { [self] ok,why in guard !finished, waiting, step == expected else { return }; waiting = false; guard active() else { return }; end(ok,why) }
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
