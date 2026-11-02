import SwiftUI
import BaduanjinCore

struct RecordsView: View {
    @EnvironmentObject var model: AppModel
    @State private var quality = 0
    @State private var action = -1
    @State private var currentTask = false
    @State private var search = ""
    private var rows: [Trial] {
        model.trials.filter { trial in
            let d = model.details[trial.id]
            let taskOK = !currentTask || (trial.assignment?.study_id == model.study?.id && !trial.diagnostic)
            let actionOK = action == -1 || trial.assignment?.action == action
            let qualityOK = quality == 0 || quality == 1 && !trial.qualityPassed || quality == 2 && !trial.diagnostic && !trial.accepted || quality == 3 && trial.accepted
            let searchOK = search.isEmpty || (d?.subject ?? "").localizedCaseInsensitiveContains(search) || (d?.actionName ?? "").localizedCaseInsensitiveContains(search) || trial.id.localizedCaseInsensitiveContains(search)
            return taskOK && actionOK && qualityOK && searchOK
        }
    }
    var body: some View {
        List {
            StatusBanner()
            Section("筛选与导出") {
                Toggle("仅当前任务",isOn:$currentTask)
                Picker("动作",selection:$action) { Text("全部动作 / 诊断").tag(-1); ForEach(0..<8,id:\.self) { i in Text(model.study?.actions[i] ?? "动作\(i+1)").tag(i) } }
                Picker("结果",selection:$quality) { Text("全部").tag(0); Text("质量未通过").tag(1); Text("待补录").tag(2); Text("已合格").tag(3) }
                Button("导出当前任务全部尝试") { model.export(model.trials.filter { $0.assignment?.study_id == model.study?.id && !$0.diagnostic }) }.disabled(model.busy || model.study == nil)
                Button("导出筛选后的\(rows.count)条记录") { model.export(rows) }.disabled(model.busy || rows.isEmpty)
                Button("刷新记录") { model.reload() }.disabled(model.busy)
            }
            if rows.isEmpty { Text("没有符合筛选条件的记录").foregroundStyle(.secondary) }
            ForEach(rows) { trial in
                NavigationLink { RecordView(trial:trial) } label: {
                    VStack(alignment:.leading,spacing:4) {
                        Text(trial.diagnostic ? "诊断记录":String(format:"编号%03d · 尝试%d",trial.assignment?.record_number ?? 0,trial.assignment?.slot_attempt ?? 0)).font(.headline)
                        Text((model.details[trial.id]?.subject ?? "")+" · "+(model.details[trial.id]?.actionName ?? "")).font(.caption)
                        Text(trial.accepted ? "已合格":trial.diagnostic ? (trial.qualityPassed ? "诊断质量通过，不计正式编号":"诊断质量未通过"):"待补录").foregroundStyle(trial.qualityPassed ? .secondary:Color.orange)
                        Text(trial.id).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }.buttonStyle(.borderless).navigationTitle("记录与导出").searchable(text:$search,prompt:"受试者编号、动作名或记录编号")
    }
}
struct RecordView: View {
    @EnvironmentObject var model: AppModel
    let trial: Trial
    @State private var retry = false
    @State private var restore = false
    @State private var custom = false
    @State private var reason = ""
    private var current: Trial { model.trials.first { $0.id == trial.id } ?? trial }
    private var detail: RecordDetail? { model.details[trial.id] }
    var body: some View {
        List {
            Section("本条结果") {
                Text(current.id).font(.caption)
                if let d = detail { Text(d.subject+" · "+d.actionName); Text(String(format:"动作段 %.3f秒",d.duration)); Text("结束原因："+d.reason) }
                Text(current.qualityPassed ? "数据质量通过":"数据质量未通过").foregroundStyle(current.qualityPassed ? .teal:.orange)
                Text(current.diagnostic ? "诊断独立保存，不占正式编号":current.accepted ? "默认正常，计入合格次数":"待补录，原始记录保留")
                ForEach(detail?.failureReasons ?? [],id:\.self) { Text($0).font(.footnote).foregroundStyle(.orange) }
                Button("导出本次") { model.export([current]) }.disabled(model.busy)
            }
            if !current.diagnostic {
                Section("动作与补录") {
                    Button("这条有问题，标记补录",role:.destructive) { retry = true }.disabled(model.busy)
                    if !current.accepted, let a = current.assignment, a.study_id == model.study?.id { NavigationLink("去补录编号\(String(format:"%03d",a.record_number))") { ActionView(action:a.action,initialSlot:a.slot) } }
                    if current.reviews.last?.decision == "rejected", current.qualityPassed, current.normalCompletion {
                        Button("误标了，恢复动作合格") { reason = ""; restore = true }.disabled(model.busy)
                    }
                    Text("恢复仅限原始数据质量通过且正常结束的记录；修改保存审计，数据质量结果不能改写。").font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(detail?.devices ?? []) { device in
                Section(device.role+" · "+device.name) {
                    ForEach(device.issues,id:\.self) { Text($0).font(.footnote).foregroundStyle(.orange) }
                    ForEach(device.streams,id:\.name) { row in
                        VStack(alignment:.leading) {
                            Text(["acceleration":"加速度","angular_velocity":"角速度","magnetic_field":"磁场","quaternion":"四元数"][row.name] ?? row.name).font(.headline)
                            Text(String(format:"整段 %.2fHz · %d帧 · 最大间隙 %.1fms",row.average_hz,row.frames,row.max_gap_ms)).font(.footnote)
                            Text("完整秒窗不足30帧：\(row.complete_seconds_below_30)个").font(.caption)
                        }
                    }
                }
            }
            Section("修改审计") {
                if current.reviews.isEmpty { Text("没有人工修改，正常结束且质量通过时默认正常").font(.footnote) }
                ForEach(current.reviews,id:\.revision) { row in VStack(alignment:.leading) { Text("修改\(row.revision) · \(row.decision == "accepted" ? "恢复动作合格":"标记待补录")"); Text(row.reason).font(.footnote); Text(Date(timeIntervalSince1970:Double(row.wall_ms)/1000),style:.date).font(.caption) } }
            }
        }.buttonStyle(.borderless).navigationTitle("记录详情")
         .confirmationDialog("标记待补录",isPresented:$retry) {
            ForEach(["数据异常","动作做错","提前结束","绑带松动"],id:\.self) { reason in Button(reason) { model.retry(current,reason:reason) } }
            Button("其他原因") { reason = ""; custom = true }
         } message: { Text("旧数据保留，补录使用新尝试编号，不覆盖这条记录。") }
         .alert("补录原因",isPresented:$custom) { TextField("1–500字说明",text:$reason); Button("标记补录") { model.retry(current,reason:reason) }; Button("取消",role:.cancel) {} }
         .alert("恢复动作合格",isPresented:$restore) { TextField("说明误标原因",text:$reason); Button("保存修改") { model.review(current,accepted:true,reason:reason) }; Button("取消",role:.cancel) {} } message: { Text("只改变人工动作判定，原始数据和质量结果保留。") }
    }
}
