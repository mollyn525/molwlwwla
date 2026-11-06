import Foundation

public enum SubjectCalibrationKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case staticPose = "static_n_pose"
    case dynamicSquats = "dynamic_two_squats"
    public var id: String { rawValue }
    public var title: String { self == .staticPose ? "静态校正 · N-pose" : "动态校正 · 两个深蹲" }
    public var seconds: Int { self == .staticPose ? 5 : 0 }
}

public struct SubjectCalibration: Codable, Equatable, Sendable {
    public let kind: SubjectCalibrationKind
    public let studyID: String
    public let setup: String
    public init(kind: SubjectCalibrationKind, studyID: String, setup: String) {
        self.kind = kind; self.studyID = studyID; self.setup = setup
    }
    public static func setup(study: Study, roster: [String:SensorBinding], orientations: [String:Int]) throws -> String {
        let placements = Dictionary(uniqueKeysWithValues:roster.map { ($0.key,$0.value.peripheralID) })
        return JSONFile.sha(try JSONFile.bytes(["revision":study.calibrationRevision ?? "legacy",
                                              "roster":placements,"orientations":orientations]))
    }
    public static func latest(_ kind: SubjectCalibrationKind, studyID: String, trials: [Trial]) -> Trial? {
        trials.filter { $0.calibration?.kind == kind && $0.calibration?.studyID == studyID }.max { $0.id < $1.id }
    }
    public static func completed(_ kind: SubjectCalibrationKind, studyID: String, setup: String, trials: [Trial]) -> Bool {
        guard let latest = latest(kind,studyID:studyID,trials:trials) else { return false }
        return latest.calibration?.setup == setup && latest.qualityPassed && latest.normalCompletion && latest.status == "calibration_complete"
    }
    public static func ready(studyID: String, setup: String, trials: [Trial]) -> Bool {
        SubjectCalibrationKind.allCases.allSatisfy { completed($0,studyID:studyID,setup:setup,trials:trials) }
    }
}

