import Foundation

public struct DeviceReadiness: Sendable {
    public var id: String
    public var wanted = false, connected = false, initialized = false, maintenance = false, configurationOK = false
    public var checkedSeconds = 0.0, hz = [0.0,0,0,0], ages: [Double?] = [nil,nil,nil,nil], status = "未连接"
    public init(id: String) { self.id = id }
}
public struct CheckItem: Identifiable, Sendable {
    public var id: String, role: String, title: String, passed: Bool, detail: String
}
public struct PreflightResult: Sendable {
    public var checks: [CheckItem]
    public var ready: Bool { !checks.isEmpty && checks.allSatisfy(\.passed) }
    public var passed: Int { checks.filter(\.passed).count }
    public var failures: [CheckItem] { checks.filter { !$0.passed } }
}
public enum Preflight {
    public static func evaluate(study: String?, nextAction: Int?, roster: [String:SensorBinding], devices: [DeviceReadiness],
                                idle: Bool, bluetooth: Bool, freeBytes: Int64, fresh: Bool, normalMode: Bool = true, classificationOK: Bool = true) -> PreflightResult {
        var checks: [CheckItem] = []
        func add(_ id: String, _ role: String, _ title: String, _ passed: Bool, _ detail: String) { checks.append(CheckItem(id:role+":"+id,role:role,title:title,passed:passed,detail:detail)) }
        add("fresh","","服务状态",fresh,"服务状态超过1秒未刷新时不能开始")
        add("study","","采集任务",study != nil && nextAction != nil,"按顺序完成八个动作，每个15条")
        add("idle","","当前操作",idle,"请结束录制、保存、导出、佩戴检查或批量操作")
        add("bluetooth","","手机蓝牙",bluetooth,"开启蓝牙并授权本App")
        add("storage","","可用空间",freeBytes >= 256*1024*1024,"至少保留256MiB；录制时低于64MiB自动结束并记异常")
        add("mode","","正常连接模式",normalMode,"仅连接诊断结束后，请重新选择正常连接")
        add("classification","","固定编号与历史",classificationOK,"记录归类或复核历史损坏时不能开始；原文件保留")
        var seen = Set<String>()
        for role in BodyRole.all {
            let b = roster[role.id], d = devices.first { $0.id == b?.peripheralID }
            let unique = b.map { seen.insert($0.peripheralID).inserted } ?? false
            let online = d.map { $0.wanted && $0.connected && $0.initialized && !$0.maintenance } ?? false
            add("binding",role.id,role.name+" · 绑定",unique,"每个部位须独立设备")
            add("connection",role.id,role.name+" · 连接",online,d?.status ?? "尚未连接")
            add("configuration",role.id,role.name+" · 配置",online && d?.configurationOK == true,"50Hz、九轴、惯性输出已回读；保留安装方向")
            let data = online && (d?.checkedSeconds ?? 0) >= 10 && d?.hz.count == 4 && d?.ages.count == 4 && d!.hz.allSatisfy { $0 >= 30 } && d!.ages.allSatisfy { $0 != nil && $0! < 500 }
            var detail = String(format:"连续检查 %.1f/10秒",min(10,d?.checkedSeconds ?? 0))
            if let d { detail += "；加速/角速/磁场/四元数："+d.hz.map { String(format:"%.1fHz",$0) }.joined(separator:" / ") }
            add("data",role.id,role.name+" · 四项数据",data,detail)
            let ref = b?.reference?.count == 4 && b?.referenceStudyID == study && study != nil && b?.referenceDiagnostic == false
            add("reference",role.id,role.name+" · 参考姿态",ref,"须当前任务完整参考；诊断参考不可替代")
            add("wear",role.id,role.name+" · 佩戴确认",b?.wearConfirmed == true && b?.movement != nil,"引导动作后人工核对编号、贴附点、方向和松紧")
        }
        return PreflightResult(checks: checks)
    }
}

public enum RecordingPolicy {
    public static func summary(diagnostic: Bool, actionStarted: Bool, userEnded: Bool, quality: Bool) -> (accepted: Bool, normal: Bool, status: String) {
        let normal = !diagnostic && actionStarted && userEnded
        if diagnostic { return (false,false,quality ? "diagnostic_pass":"quality_failed") }
        return (normal && quality,normal,!quality ? "quality_failed":normal ? "accepted_default":"abnormal_end")
    }
}
