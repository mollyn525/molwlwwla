import Foundation

public struct BodyRole: Identifiable, Codable {
    public let id: String, name: String
    public static let all: [BodyRole] = zip(
        ["head","thoracic_spine","pelvis","left_upper_arm","right_upper_arm","left_forearm","right_forearm","left_hand_dorsum","right_hand_dorsum","left_thigh","right_thigh","left_shank","right_shank","left_foot_dorsum","right_foot_dorsum"],
        ["头部","胸椎","骨盆","左大臂","右大臂","左小臂","右小臂","左手背","右手背","左大腿","右大腿","左小腿","右小腿","左足背","右足背"]).map { BodyRole(id: $0.0, name: $0.1) }
}
public struct SensorBinding: Codable {
    public var peripheralID: String, name: String, wearConfirmed = false
    public var reference: [Double]?, referenceID: String?
    public init(peripheralID: String, name: String) { self.peripheralID = peripheralID; self.name = name }
}
public struct NameChange: Codable { public var wall_ms: Int64, before: [String], after: [String] }
public struct Study: Identifiable, Codable {
    public var id: String, subject: String, created_ms: Int64, actions: [String], name_history: [NameChange]
    public init(subject: String, at: Int64) throws {
        guard subject.range(of: "^[A-Za-z0-9_-]{1,40}$", options: .regularExpression) != nil else { throw LabError.invalid("匿名编号限1–40位字母、数字、下划线或短横线") }
        id = UUID().uuidString; self.subject = subject; created_ms = at; actions = (1...8).map { "动作\($0)" }; name_history = []
    }
    public mutating func rename(_ names: [String], at: Int64) throws {
        let clean = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard clean.count == 8, clean.allSatisfy({ !$0.isEmpty && $0.count <= 80 }) else { throw LabError.invalid("请填写8个1–80字的动作名称") }
        name_history.append(NameChange(wall_ms: at, before: actions, after: clean)); actions = clean
    }
}
public struct Assignment: Codable, Equatable, Sendable {
    public let study_id: String, action: Int, slot: Int, slot_attempt: Int, record_number: Int
    public init(study: String, action: Int, slot: Int, attempt: Int) throws {
        guard study.range(of:"^[A-Za-z0-9_-]{1,80}$",options:.regularExpression) != nil, (0..<8).contains(action), (1...15).contains(slot), attempt > 0 else { throw LabError.invalid("无效固定编号") }
        study_id = study; self.action = action; self.slot = slot; slot_attempt = attempt; record_number = action*15+slot
    }
    enum CodingKeys: String, CodingKey { case study_id, action, slot, slot_attempt, record_number }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(study: c.decode(String.self, forKey: .study_id), action: c.decode(Int.self, forKey: .action), slot: c.decode(Int.self, forKey: .slot), attempt: c.decode(Int.self, forKey: .slot_attempt))
        guard try c.decode(Int.self, forKey: .record_number) == record_number else { throw LabError.invalid("固定编号与动作不匹配") }
    }
}
public struct Review: Codable, Sendable {
    public var revision: Int, wall_ms: Int64, decision: String, reason: String
    public init(revision: Int, at: Int64, decision: String, reason: String) { self.revision = revision; wall_ms = at; self.decision = decision; self.reason = reason }
}
public struct Trial: Codable, Identifiable, Sendable {
    public var id: String, assignment: Assignment?, diagnostic: Bool, qualityPassed: Bool, normalCompletion: Bool, status: String
    public var reviews: [Review]
    public init(id: String, assignment: Assignment?, diagnostic: Bool, quality: Bool, normal: Bool, status: String, reviews: [Review] = []) {
        self.id = id; self.assignment = assignment; self.diagnostic = diagnostic; qualityPassed = quality; normalCompletion = normal; self.status = status; self.reviews = reviews
    }
    public var reviewValid: Bool { reviews.enumerated().allSatisfy { $0.element.revision == $0.offset+1 && ["accepted","rejected"].contains($0.element.decision) && !$0.element.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
    public var accepted: Bool { !diagnostic && assignment != nil && qualityPassed && normalCompletion && status != "incomplete_process_exit" && reviewValid && (reviews.last?.decision ?? "accepted") == "accepted" }
    public mutating func markRetry(reason: String, revision: Int, at: Int64) throws {
        guard !diagnostic, assignment != nil, reviewValid, revision == reviews.count else { throw LabError.invalid("记录状态已变化或属于诊断记录") }
        let clean = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 500 else { throw LabError.invalid("请填写1–500字补录原因") }
        reviews.append(Review(revision: revision+1, at: at, decision: "rejected", reason: clean))
    }
}
public struct SlotBook {
    public let studyID: String, trials: [Trial]
    public init(studyID: String, trials: [Trial]) { self.studyID = studyID; self.trials = trials }
    public func attempts(action: Int, slot: Int) -> [Trial] {
        trials.filter { !$0.diagnostic && $0.assignment?.study_id == studyID && $0.assignment?.action == action && $0.assignment?.slot == slot }.sorted { ($0.assignment?.slot_attempt ?? 0) < ($1.assignment?.slot_attempt ?? 0) }
    }
    public func accepted(action: Int, slot: Int) -> Bool {
        let rows = attempts(action: action, slot: slot)
        guard Set(rows.compactMap { $0.assignment?.slot_attempt }).count == rows.count else { return false }
        return rows.last?.accepted ?? false
    }
    public func state(action: Int, slot: Int) -> String { attempts(action: action, slot: slot).isEmpty ? "未采集" : accepted(action: action, slot: slot) ? "已合格" : "待补录" }
    public func count(action: Int) -> Int { (1...15).filter { accepted(action: action, slot: $0) }.count }
    public var total: Int { (0..<8).reduce(0) { $0+count(action: $1) } }
    public var nextAction: Int? { (0..<8).first { count(action: $0) < 15 } }
    public func nextSlot(action: Int, retry: Bool) -> Int? { (1...15).first { state(action: action, slot: $0) == (retry ? "待补录" : "未采集") } }
    public func begin(action: Int, slot: Int) throws -> Assignment {
        guard nextAction == action, !accepted(action: action, slot: slot) else { throw LabError.invalid("请完成最早未完成动作，合格编号需先标记补录") }
        let rows = attempts(action: action, slot: slot)
        guard Set(rows.compactMap { $0.assignment?.slot_attempt }).count == rows.count else { throw LabError.invalid("尝试编号重复，须核查记录") }
        return try Assignment(study: studyID, action: action, slot: slot, attempt: (rows.compactMap { $0.assignment?.slot_attempt }.max() ?? 0)+1)
    }
}
