import SwiftUI
import BaduanjinCore

struct CaptureView: View {
    @EnvironmentObject var model: AppModel
    @State private var subject = ""
    @State private var showNew = false
    var body: some View {
        List {
            StatusBanner()
            #if DEBUG
            if !model.engineState.lifecycleProbe.isEmpty {
                Text(model.engineState.lifecycleProbe).font(.caption2).accessibilityIdentifier("lifecycleProbe")
            }
            #endif
            Section("本次采集任务") {
                CurrentTaskSummary()
                Button("新建受试者任务") { showNew = true }.disabled(model.busy)
                TaskLink("受试者管理 / 最近删除",detail:"继续历史任务、恢复或删除受试者",symbol:"person.crop.rectangle.stack") { StudyManagementView() }
                    .accessibilityIdentifier("manageSubjects")
            }
            Section("采集流程") {
                TaskLink("受试者静态 / 动态校正",detail:"N-pose 保持5秒 · 两个深蹲",symbol:"figure.stand") { SubjectCalibrationView() }.disabled(model.study == nil)
                TaskLink("开始正式收集",detail:"八个动作任选 · 每个动作15条",symbol:"record.circle") { CollectionView() }.disabled(model.study == nil)
            }
            Section("诊断录制") {
                Text("诊断独立保存，不占正式编号。点击即保存，3秒后标记动作开始。").font(.footnote).foregroundStyle(.secondary)
                Button("开始诊断录制（手动结束）") { model.diagnostic(seconds:0) }.disabled(model.busy)
                Button("开始60秒诊断") { model.diagnostic(seconds:60) }.disabled(model.busy)
                Text("下拉通知中心或控制中心时继续采集；锁屏或切到其他 App 进入后台时结束并保留本次记录。").font(.caption).foregroundStyle(.secondary)
            }
        }.buttonStyle(.borderless).navigationTitle("采集")
         .safeAreaInset(edge:.bottom) {
             if model.engineState.recording || model.engineState.saving { CaptureDock(title:"",enabled:false,identifier:"diagnosticDock") {} }
         }
         .alert("新建匿名受试者任务",isPresented:$showNew) {
            TextField("例如 S001",text:$subject).textInputAutocapitalization(.never)
            Button("建立") { model.create(subject) }; Button("取消",role:.cancel) {}
         } message: { Text("只填写匿名编号，不填写姓名。新任务会重置佩戴与参考状态；建议重新核验，未完成也可采集原始数据。") }
    }
}
struct RecordingControls: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if model.engineState.recording || model.engineState.saving {
            if let number = model.engineState.recordNumber { Text(String(format:"正在记录 %03d · 第%d次尝试",number,model.engineState.recordAttempt ?? 1)).font(.headline) }
            Text(model.engineState.saving ? "正在保存，请稍候" : model.engineState.countdown > 0 ? "准备 \(model.engineState.countdown)" : String(format:"动作段 %.1f 秒",model.engineState.elapsed)).font(.title2.monospacedDigit())
            if model.engineState.recordingCalibration == .staticPose {
                Text("N-pose 保持不动，满5秒自动保存").font(.subheadline)
                Button("提前结束并保留本次") { model.engine.stop() }.buttonStyle(.bordered).disabled(!model.engineState.recording)
            } else {
                Button {
                    model.engine.stop(calibrationComplete:model.engineState.recordingCalibration == .dynamicSquats)
                } label: {
                    Text(model.engineState.recordingCalibration == .dynamicSquats ? "已完成两个深蹲，结束并保存" : "结束并保存")
                        .frame(maxWidth:.infinity,minHeight:24).multilineTextAlignment(.center)
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.engineState.recording).accessibilityIdentifier("recordingStop")
                if model.engineState.recordingCalibration == .dynamicSquats {
                    Button("本次未完成，结束并保留") { model.engine.stop() }
                        .buttonStyle(.bordered).disabled(!model.engineState.recording)
                }
            }
        }
    }
}
struct CollectionView: View {
    @EnvironmentObject var model: AppModel
    @State private var edit = false
    @State private var names = Array(repeating:"",count:8)
    var body: some View {
        List {
            StatusBanner()
            Section("当前任务") {
                CurrentTaskSummary()
                NavigationLink("受试者静态 / 动态校正") { SubjectCalibrationView() }.accessibilityIdentifier("subjectCalibration")
                if let next = model.book.nextAction {
                    AdaptiveActionRow {
                        NavigationLink("继续正常采集") { ActionView(action:next,initialSlot:model.book.nextSlot(action:next,retry:false) ?? model.book.nextSlot(action:next,retry:true) ?? 1) }
                            .frame(maxWidth:.infinity,minHeight:44,alignment:.leading)
                        NavigationLink("定位待补录") { ActionView(action:next,initialSlot:model.book.nextSlot(action:next,retry:true) ?? 1) }
                            .frame(maxWidth:.infinity,minHeight:44,alignment:.leading).disabled(model.book.nextSlot(action:next,retry:true) == nil)
                    }.font(.subheadline)
                } else { Text("120条均已合格，可查看历史和分类导出").foregroundStyle(.teal) }
            }
            Section("八个动作 · 可任选") {
            ForEach(0..<8,id:\.self) { a in
                NavigationLink { ActionView(action:a) } label: {
                    HStack(spacing:12) {
                        Text(String(format:"%02d",a+1)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).frame(width:28)
                        VStack(alignment:.leading,spacing:4) {
                            Text(model.study?.actions[a] ?? "动作\(a+1)").font(.headline)
                            Text(String(format:"%03d–%03d · %d/15合格",a*15+1,(a+1)*15,model.book.count(action:a))).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength:0)
                    }.frame(minHeight:44).padding(.vertical,4)
                }.accessibilityIdentifier("collectionAction\(a)")
            }
            }
            Section("任务管理与导出") {
                Button("编辑八个动作名称") { names = model.study?.actions ?? (1...8).map { "动作\($0)" }; edit = true }.disabled(model.busy)
                Button("导出当前任务全部尝试") { model.export(model.trials.filter { $0.studyID == model.study?.id && !$0.diagnostic }) }.disabled(model.busy)
                NavigationLink("查看完整采前清单") { PreflightView() }
                DisclosureGroup("采集与导出说明") {
                    Text("八个动作各15条，共120个固定编号。正常结束且数据质量通过后默认正常；发现问题再标记补录。").font(.footnote)
                    Text("导出按动作、编号和尝试分类，每次均附示例格式TXT。").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.buttonStyle(.borderless).navigationTitle("正式收集").navigationBarTitleDisplayMode(.inline)
         .safeAreaInset(edge:.bottom) {
             if model.engineState.recording || model.engineState.saving { CaptureDock(title:"",enabled:false,identifier:"collectionDock") {} }
         }
         .sheet(isPresented:$edit) {
            NavigationStack {
                Form { ForEach(0..<8,id:\.self) { i in TextField("动作\(i+1)",text:$names[i]) } }
                .navigationTitle("动作名称").toolbar {
                    ToolbarItem(placement:.confirmationAction) { Button("保存") { model.rename(names); edit = false } }
                    ToolbarItem(placement:.cancellationAction) { Button("取消") { edit = false } }
                }
            }
         }
    }
}
struct ActionView: View {
    @EnvironmentObject var model: AppModel
    let action: Int
    @State private var slot: Int
    @State private var retryLatest = false
    init(action: Int, initialSlot: Int = 1) { self.action = action; _slot = State(initialValue:initialSlot) }
    private var rows: [Trial] { model.book.attempts(action:action,slot:slot) }
    private var startAllowed: Bool { model.preflight.ready && !model.book.accepted(action:action,slot:slot) }
    var body: some View {
        List {
            StatusBanner()
            Section("选择采集编号") {
            LazyVGrid(columns:Array(repeating:GridItem(.flexible()),count:3)) {
                ForEach(1...15,id:\.self) { n in
                    Button { slot = n } label: {
                        VStack { Text(String(format:"%03d",action*15+n)).bold(); Text(model.book.state(action:action,slot:n)).font(.caption) }
                        .frame(maxWidth:.infinity,minHeight:64).background(slot == n ? Color.teal.opacity(0.18):Color.gray.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius:10))
                    }.disabled(model.busy).buttonStyle(.plain)
                }
            }
            }
            Section("本条采集") {
            Text("第\(slot)/15条 · 下次第\((rows.last?.assignment?.slot_attempt ?? 0)+1)次尝试").font(.headline)
            Text("频率要求：每台加速度、角速度各 >40 Hz，平均值包含断流时间。").font(.caption).foregroundStyle(.secondary)
            if !startAllowed { blockedStartDetails }
            HStack {
                Button("继续正常采集") { if let next = model.book.nextSlot(action:action,retry:false) { slot = next } }.disabled(model.busy || model.book.nextSlot(action:action,retry:false) == nil)
                Button("定位待补录") { if let next = model.book.nextSlot(action:action,retry:true) { slot = next } }.disabled(model.busy || model.book.nextSlot(action:action,retry:true) == nil)
            }
            if let latest = rows.last {
                NavigationLink("查看最近一次结果及失败原因") { RecordView(trial:latest) }
                Button("这条有问题，标记补录",role:.destructive) { retryLatest = true }.disabled(model.busy)
            }
            if model.book.count(action:action) == 15, let next = model.book.nextAction {
                NavigationLink("本动作已完成，进入\(model.study?.actions[next] ?? "下一动作")") { ActionView(action:next) }
            }
            }
            Section("本条所有尝试") {
                ForEach(rows.reversed()) { trial in NavigationLink { RecordView(trial:trial) } label: { Text("尝试\(trial.assignment?.slot_attempt ?? 0) · \(trial.accepted ? "已合格":"待补录")") } }
            }
            preflightSection
        }.buttonStyle(.borderless).navigationTitle(model.study?.actions[action] ?? "动作\(action+1)").navigationBarTitleDisplayMode(.inline)
         .safeAreaInset(edge:.bottom) {
             CaptureDock(title:"开始本条采集",enabled:startAllowed,identifier:"formalStart") { model.start(action:action,slot:slot) }
         }
         .confirmationDialog("标记待补录，原始记录保留",isPresented:$retryLatest) {
             ForEach(["数据异常","动作做错","提前结束","绑带松动","其他原因"],id:\.self) { reason in Button(reason) { if let latest = rows.last { model.retry(latest,reason:reason) } } }
         }
    }
    private var blockedStartDetails: some View {
        VStack(alignment:.leading,spacing:6) {
            Text("暂不能开始的原因").font(.headline).accessibilityIdentifier("formalBlockedReason")
            if model.book.accepted(action:action,slot:slot) { Text("本编号已有合格记录；需要重采时，先点“这条有问题，标记补录”。") }
            ForEach(model.preflight.blockers.prefix(3)) { row in Text(row.title+"："+row.detail).font(.footnote) }
            NavigationLink("进行静态 / 动态校正") { SubjectCalibrationView() }
            NavigationLink("查看原因与处理步骤") { PreflightView() }.accessibilityIdentifier("formalBlockedHelp")
        }.foregroundStyle(.orange)
    }
    private var preflightSection: some View {
        Section("采前检查") {
            Text(model.preflight.ready ? "开始条件已满足，可采集":"还有\(model.preflight.blockers.count)项开始条件未满足")
            Text("另有\(model.preflight.reminders.count)项提醒，不阻止采集。佩戴、参考姿态与配置状态会随记录保存。").font(.footnote)
            DisclosureGroup("展开开始条件详情") {
                ForEach(model.preflight.blockers.prefix(8)) { row in VStack(alignment:.leading) { Text(row.title); Text(row.detail).font(.caption).foregroundStyle(.secondary) } }
            }
            NavigationLink("查看全部检查项与部位") { PreflightView() }
        }
    }
}
struct PreflightView: View {
    @EnvironmentObject var model: AppModel
    @State private var onlyFailures = true
    var body: some View {
        TimelineView(.periodic(from:.now,by:1)) { _ in
            List {
                Text(model.preflight.ready ? "可以开始采集":"\(model.preflight.blockers.count)项开始条件待处理").font(.title2)
                Text("主要条件：15台实际连接并就绪，每台加速度、角速度各 >40 Hz；正式动作前完成本受试者的两项校正采集。佩戴、参考姿态和配置检查属于提醒。").font(.footnote)
                NavigationLink("受试者静态 / 动态校正") { SubjectCalibrationView() }
                NavigationLink("设备绑定与连接") { DevicesView() }
                NavigationLink("配置读取与核验") { SettingsView() }
                NavigationLink("佩戴确认与参考姿态") { WearingView() }
                Toggle("只显示未通过项",isOn:$onlyFailures)
                ForEach((onlyFailures ? model.preflight.failures:model.preflight.checks).sorted { $0.blocksStart && !$1.blocksStart }) { row in
                    VStack(alignment:.leading,spacing:4) {
                        Label(row.title+(row.blocksStart ? " · 开始条件":" · 提醒，不阻止采集"),systemImage:row.passed ? "checkmark.circle.fill":"exclamationmark.circle").foregroundStyle(row.passed ? .teal:.orange)
                        Text(row.detail).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }.navigationTitle("采前检查清单")
        }
    }
}
