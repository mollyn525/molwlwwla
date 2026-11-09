import SwiftUI
import BaduanjinCore

struct WearingView: View {
    @EnvironmentObject var model: AppModel
    @State private var referenceMode: Int?
    @State private var invalidate = false
    var body: some View {
        List {
            StatusBanner()
            Section("本次佩戴核验") {
                Text("本页项目属于提醒，未完成也可开始正式采集。没有当前任务的有效参考时，只保存原始数据，不生成对应相对姿态。").font(.footnote).foregroundStyle(.secondary)
                DisclosureGroup("佩戴核验步骤") {
                    Text("1 核对设备编号、贴附点、方向和松紧\n2 保持中立站姿，双臂自然下垂、双脚平放\n3 每个部位做5秒引导动作\n4 记录人工确认").font(.footnote).lineSpacing(6)
                }
                Button("采集15部位完整参考姿态") { referenceMode = 0 }.disabled(model.busy || model.study == nil)
                Button("诊断：仅采集已连接的绑定部位") { referenceMode = 1 }.disabled(model.busy || model.study == nil)
                Button("调整过佩戴，清除当前参考",role:.destructive) { invalidate = true }.disabled(model.busy)
            }
            Section("逐部位核验") {
            ForEach(BodyRole.all) { role in
                NavigationLink { WearRoleView(role:role) } label: {
                    VStack(alignment:.leading) {
                        Text(role.name).font(.headline); Text(model.roster[role.id]?.name ?? "未绑定").font(.caption)
                        if let b = model.roster[role.id] {
                            Text(b.wearConfirmed ? "已人工确认" : b.reference == nil ? "参考姿态未采集" : b.movement == nil ? "待引导动作检查":"待人工确认").font(.footnote).foregroundStyle(b.wearConfirmed ? .teal:.orange)
                            if b.referenceDiagnostic == true { Text("诊断参考，不用于正式采集").font(.caption).foregroundStyle(.orange) }
                        }
                    }
                }
            }
            }
            Text("引导动作只提供疑似错绑线索。参考姿态是中立参考，不是解剖坐标系精度认证，不会消除航向漂移或建立设备内部同步。").font(.footnote).foregroundStyle(.secondary)
        }.buttonStyle(.borderless).navigationTitle("佩戴核验")
         .confirmationDialog("采集参考姿态",isPresented:Binding(get:{referenceMode != nil},set:{if !$0 {referenceMode = nil}})) {
            Button("已保持参考站姿，开始3.2秒采集") { let diagnostic = referenceMode == 1; referenceMode = nil; model.captureReference(diagnostic:diagnostic) }
         } message: { Text("请站稳，双臂自然下垂、双脚平放；点击后继续保持3.2秒。若波动或数据缺口过大，会保留未通过提示。") }
         .alert("清除当前参考与佩戴确认？",isPresented:$invalidate) { Button("清除当前参考",role:.destructive) { model.invalidateWear() }; Button("取消",role:.cancel) {} } message: { Text("历史记录中的参考快照保留。调整绑带、换设备或改变位置后，应重新核验。") }
    }
}
struct WearRoleView: View {
    @EnvironmentObject var model: AppModel
    let role: BodyRole
    @State private var movementPrompt = false
    @State private var note = ""
    private var binding: SensorBinding? { model.roster[role.id] }
    private var guide: String {
        switch role.id {
        case "head": return "保持躯干基本不动，在舒适范围内缓慢左右转头。"
        case "thoracic_spine": return "双脚站稳，小幅缓慢转动上身，避免快速扭转。"
        case "pelvis": return "双脚站稳，小幅缓慢转动骨盆，允许腿部自然联动。"
        default:
            if role.id.contains("upper_arm") { return "缓慢抬起并放下对应侧手臂，允许小臂和手部自然联动。" }
            if role.id.contains("forearm") { return "对应侧大臂尽量稳定，缓慢屈伸肘部，允许手部随动。" }
            if role.id.contains("hand") { return "对应侧小臂尽量稳定，缓慢屈伸手腕。" }
            if role.id.contains("thigh") { return "在稳定支撑下，小幅抬起并放下对应侧大腿，允许小腿和足部随动。" }
            if role.id.contains("shank") { return "保持稳定支撑，缓慢屈伸对应侧膝部，允许足部随动。" }
            return "保持稳定支撑，缓慢抬起和放下对应侧足尖。"
        }
    }
    var body: some View {
        Form {
            StatusBanner()
            Section("当前绑定与参考") {
                Text(binding?.name ?? "未绑定")
                Text(binding?.reference == nil ? "尚未采集参考姿态" : binding?.referenceDiagnostic == true ? "已有诊断参考" : "已有正式参考")
                if let q = binding?.reference { Text("参考四元数："+q.map { String(format:"%.5f",$0) }.joined(separator:" / ")).font(.caption) }
            }
            Section("5秒引导动作") {
                Text(guide)
                Button("开始本部位动作检查") { movementPrompt = true }.disabled(model.busy || binding?.reference == nil || model.device(role)?.initialized != true)
                if let report = binding?.movement {
                    Text(report.result).foregroundStyle(.orange)
                    ForEach(report.evidence,id:\.role) { row in
                        Text("\(BodyRole.all.first { $0.id == row.role }?.name ?? row.role)："+String(format:"接收时间积分%.1f°，覆盖%.0f%%，最大缺口%.0fms",row.integralDegrees,row.coverage*100,row.maxGapMS)+(row.coupled ? " · 联动范围":"")).font(.caption)
                    }
                }
            }
            Section("人工确认") {
                Text("请实际核对编号、贴附点、朝向及松紧。自动结果为线索，显示“无法判断”时也需要人工检查，不能据此自动判定正确。")
                TextField("填写检查说明",text:$note,axis:.vertical).lineLimit(3...6)
                Button("已核对，保存人工确认") { model.confirmWear(role,note:note) }.disabled(model.busy || binding?.movement == nil || note.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                if binding?.wearConfirmed == true { Label("已保存人工确认",systemImage:"checkmark.circle.fill").foregroundStyle(.teal); Text(binding?.wearNote ?? "").font(.footnote) }
            }
        }.buttonStyle(.borderless).navigationTitle(role.name+" · 佩戴").navigationBarTitleDisplayMode(.inline)
         .onAppear { note = binding?.wearNote ?? "" }
         .confirmationDialog("准备开始5秒引导动作",isPresented:$movementPrompt) { Button("已准备，开始5秒检查") { model.inspect(role.id) } } message: { Text(guide+"持续5秒，允许相邻肢段自然联动，其余部位尽量不动。") }
    }
}
