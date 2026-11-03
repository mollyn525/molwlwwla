import Foundation

public protocol PreparedCalibrationPort: CalibrationPort {
    /// Read and validate this device's old values before any hardware calibration command.
    func prepare(_ completion: @escaping (Bool,String) -> Void)
}
public struct CalibrationOutcome {
    public let passed: Bool, reason: String
}
/// Serial caller, overlapping per-device state machines. No shared current-device pointer.
public final class ParallelCalibration {
    private enum State { case pending, preparing, running, finished }
    private let entries: [(String,PreparedCalibrationPort)]
    private let result: (String,CalibrationOutcome) -> Void, completed: () -> Void
    private var states: [String:State], controllers: [String:CalibrationController] = [:]
    private var started = false, cancelled = false, completionSent = false
    public private(set) var outcomes: [String:CalibrationOutcome] = [:]
    public init(entries: [(String,PreparedCalibrationPort)], result: @escaping (String,CalibrationOutcome) -> Void, completed: @escaping () -> Void) throws {
        guard !entries.isEmpty, entries.count <= 15, Set(entries.map { $0.0 }).count == entries.count else { throw LabError.invalid("并行校准需1–15台不同设备") }
        self.entries = entries; self.result = result; self.completed = completed
        states = Dictionary(uniqueKeysWithValues:entries.map { ($0.0,.pending) })
    }
    public func start() {
        guard !started, !cancelled else { return }; started = true
        for (id,port) in entries {
            guard !cancelled, states[id] == .pending else { continue }
            states[id] = .preparing
            port.prepare { [weak self] ok,why in
                guard let self, self.states[id] == .preparing, !self.cancelled else { return }
                guard ok else { self.finish(id,false,why); return }
                self.states[id] = .running
                let controller = CalibrationController(port:port) { [weak self] ok,why in self?.finish(id,ok,why) }
                self.controllers[id] = controller
                controller.begin()
            }
        }
    }
    public func cancelDevice(_ id: String, reason: String) { finish(id,false,reason) }
    public func cancelAll(_ reason: String) {
        cancelled = true
        for (id,_) in entries { finish(id,false,reason) }
    }
    private func finish(_ id: String, _ passed: Bool, _ reason: String) {
        guard let state = states[id], state != .finished else { return }
        states[id] = .finished
        let outcome = CalibrationOutcome(passed:passed,reason:reason); outcomes[id] = outcome
        let controller = controllers.removeValue(forKey:id)
        if !passed { controller?.cancel(reason) }
        result(id,outcome)
        if outcomes.count == entries.count && !completionSent { completionSent = true; completed() }
    }
}
