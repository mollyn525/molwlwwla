import Foundation

/// Operator annotation only. Never mapped to a device command or coordinate transform.
public enum MountingLabel: String, CaseIterable, Codable, Identifiable, Sendable {
    case horizontal, vertical
    public var id: String { rawValue }
    public var title: String { self == .vertical ? "竖直" : "水平" }
}

