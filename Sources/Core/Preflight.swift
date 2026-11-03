import Foundation

public struct DeviceReadiness: Sendable {
    public var id: String, name = ""
    public var wanted = false, connected = false, initialized = false, maintenance = false, configurationOK = false
    public var checkedSeconds = 0.0, hz = [0.0,0,0,0], ages: [Double?] = [nil,nil,nil,nil], status = "未连接"
    public init(id: String) { self.id = id }
}
public struct CheckItem: Identifiable, Sendable {
    public var id: String, role: String, title: String, passed: Bool, detail: String
    public var blocksStart = true
}
public struct PreflightResult: Sendable {
    public var checks: [CheckItem]
    public var ready: Bool { !checks.isEmpty && blockers.isEmpty }
    public var passed: Int { checks.filter(\.passed).count }
    public var failures: [CheckItem] { checks.filter { !$0.passed } }
    public var blockers: [CheckItem] { failures.filter(\.blocksStart) }
    public var reminders: [CheckItem] { failures.filter { !$0.blocksStart } }
}
public enum Preflight {
    public static func evaluate(study: String?, nextAction: Int?, roster: [String:SensorBinding], devices: [DeviceReadiness],
                                idle: Bool, bluetooth: Bool, freeBytes: Int64, fresh: Bool, normalMode: Bool = true, classificationOK: Bool = true) -> PreflightResult {
        var checks: [CheckItem] = []
        func add(_ id: String, _ role: String, _ title: String, _ passed: Bool, _ detail: String, blocking: Bool = true) { checks.append(CheckItem(id:role+":"+id,role:role,title:title,passed:passed,detail:detail,blocksStart:blocking)) }
        add("fresh","","服务状态",fresh,"服务状态超过1秒未刷新时不能开始")
        add("study","","采集任务",study != nil && nextAction != nil,"按顺序完成八个动作，每个15条")
        add("idle","","当前操作",idle,"请结束录制、保存、导出、佩戴检查或批量操作")
        add("bluetooth","","手机蓝牙",bluetooth,"开启蓝牙并授权本App")
        add("storage","","可用空间",freeBytes >= 256*1024*1024,"至少保留256MiB；录制时低于64MiB自动结束并记异常")
        add("mode","","正常连接模式",normalMode,"仅连接诊断结束后，请重新选择正常连接")
        add("classification","","固定编号与历史",classificationOK,"记录归类或复核历史损坏时不能开始；原文件保留")
        let selected = devices.filter(\.wanted)
        let connected = selected.filter { $0.connected && $0.initialized && !$0.maintenance }
        let countOK = selected.count == 15 && connected.count == 15 && Set(connected.map(\.id)).count == 15
        add("device_count","","15台实际连接",countOK,"已选\(selected.count)台，已连接并就绪\(connected.count)/15台；扫描发现数量不算连接数量")
        let slow = selected.filter { !QualityPolicy.current.recentRatesPass($0.hz) }
        let slowDetail = slow.map { d in
            let role = BodyRole.all.first { roster[$0.id]?.peripheralID == d.id }?.name
            return (role ?? (d.name.isEmpty ? d.id:d.name))+"："+d.hz.prefix(2).map { String(format:"%.2fHz",$0) }.joined(separator:" / ")
        }.joined(separator:"；")
        add("inertial_rate","","加速度 / 角速度频率",countOK && slow.isEmpty,"每台近10秒平均接收率须各 >40 Hz，包含断流时间"+(slowDetail.isEmpty ? "":"；未通过："+slowDetail))
        var seen = Set<String>()
        for role in BodyRole.all {
            let b = roster[role.id], d = devices.first { $0.id == b?.peripheralID }
            let unique = b.map { seen.insert($0.peripheralID).inserted } ?? false
            let online = d.map { $0.wanted && $0.connected && $0.initialized && !$0.maintenance } ?? false
            add("binding",role.id,role.name+" · 绑定",unique,"建议每部位绑定独立设备；未绑定仍按设备标识保存",blocking:false)
            add("connection",role.id,role.name+" · 连接",online,d?.status ?? "此部位尚未绑定或连接",blocking:false)
            add("configuration",role.id,role.name+" · 配置",online && d?.configurationOK == true,"建议50Hz、九轴、惯性输出；实际达标按收到的加速度、角速度判定",blocking:false)
            let policy = QualityPolicy.current
            let data = online && (d?.checkedSeconds ?? 0) >= 10 && policy.recentRatesPass(d?.hz ?? []) && policy.recentDataHealthy(d?.ages ?? [])
            var detail = String(format:"连续检查 %.1f/10秒",min(10,d?.checkedSeconds ?? 0))
            detail += "；近10秒加速度、角速度须各 >40 Hz，且各自未停更500ms"
            if let d { detail += "；当前："+d.hz.prefix(2).map { String(format:"%.2fHz",$0) }.joined(separator:" / ") }
            add("data",role.id,role.name+" · 连续数据提醒",data,detail,blocking:false)
            let ref = b?.reference?.count == 4 && b?.referenceStudyID == study && study != nil && b?.referenceDiagnostic == false
            add("reference",role.id,role.name+" · 参考姿态",ref,"未完成仍可采集；仅当前任务正式参考可生成相对姿态",blocking:false)
            add("wear",role.id,role.name+" · 佩戴确认",b?.wearConfirmed == true && b?.movement != nil,"建议人工核对编号、贴附点、方向和松紧；未确认仍可采集",blocking:false)
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
