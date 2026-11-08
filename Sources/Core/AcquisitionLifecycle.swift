import Foundation

public enum AcquisitionPhase: String, Sendable { case active, inactive, background }

/// An inactive foreground scene keeps an existing acquisition running.
/// Returning from background cannot resume acquisition until it becomes active.
public struct AcquisitionLifecycle: Sendable {
    public private(set) var phase = AcquisitionPhase.background
    public private(set) var acquisitionAllowed = false
    public var interactive: Bool { phase == .active }
    public init() {}
    public mutating func transition(to phase: AcquisitionPhase) {
        self.phase = phase
        switch phase {
        case .active: acquisitionAllowed = true
        case .inactive: break
        case .background: acquisitionAllowed = false
        }
    }
}

