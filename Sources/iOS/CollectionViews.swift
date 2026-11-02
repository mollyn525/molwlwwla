import SwiftUI
import BaduanjinCore

struct CaptureView: View {
    @EnvironmentObject var model: AppModel
    @State private var subject = ""
    @State private var showNew = false
    var body: some View {
        List {
            StatusBanner()
            Section("本次采集任务") {
                Text(model.study.map { "\($0.subject) · \(model.book.total)/120条合格" } ?? "尚未建立任务")
                NavigationLink("开始正式收集") { CollectionView() }.disabled(model.study == nil)
                Button("新建受试者任务") { showNew = true }.disabled(model.busy)
                NavigationLink("查看 / 继续历史任务") {
                    List(model.studies) { study in
                        Button { model.activate(study.id) } label: { VStack(alignment:.leading) { Text(study.subject); Text(Date(timeIntervalSince1970:Double(study.created_ms)/1000),style:.date).font(.caption); if model.study?.id == study.id { Text("当前任务").font(.caption).foregroundStyle(.teal) } } }.disabled(model.busy)
                    }.navigationTitle("历史任务")
                }
            }
            Section("诊断录制") {
                Text("诊断独立保存，不占正式编号。点击即保存，3秒后标记动作开始。")
                Button("开始诊断录制（手动结束）") { model.diagnostic(seconds:0) }.disabled(model.busy)
                Button("开始60秒诊断") { model.diagnostic(seconds:60) }.disabled(model.busy)
                RecordingControls()
                Text("采集时保持App前台；离开前台会结束并保留异常记录。").font(.caption).foregroundStyle(.secondary)
            }
        }.buttonStyle(.borderless).navigationTitle("采集")
         .alert("新建匿名受试者任务",isPresented:$showNew) {
            TextField("例如 S001",text:$subject).textInputAutocapitalization(.never)
            Button("建立") { model.create(subject) }; Button("取消",role:.cancel) {}
         } message: { Text("只填写匿名编号，不填写姓名。新任务需要重新完成佩戴核验。") }
    }
}
struct RecordingControls: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if model.engineState.recording || model.engineState.saving {
            if let number = model.engineState.recordNumber { Text(String(format:"正在记录 %03d · 第%d次尝试",number,model.engineState.recordAttempt ?? 1)).font(.headline) }
            Text(model.engineState.saving ? "正在保存，请稍候" : model.engineState.countdown > 0 ? "准备 \(model.engineState.countdown)" : String(format:"动作段 %.1f 秒",model.engineState.elapsed)).font(.title2.monospacedDigit())
            Button("结束并保存") { model.engine.stop() }.buttonStyle(.borderedProminent).disabled(!model.engineState.recording)
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
            Text("八个动作各15条，共120个固定编号。正常结束且数据质量通过后默认正常；发现问题再标记补录。")
            Text("\(model.study?.subject ?? "无任务") · \(model.book.total)/120条合格").font(.headline)
            if let next = model.book.nextAction {
                NavigationLink("继续正常采集") { ActionView(action:next,initialSlot:model.book.nextSlot(action:next,retry:false) ?? model.book.nextSlot(action:next,retry:true) ?? 1) }
                NavigationLink("定位待补录") { ActionView(action:next,initialSlot:model.book.nextSlot(action:next,retry:true) ?? 1) }.disabled(model.book.nextSlot(action:next,retry:true) == nil)
            } else { Text("120条均已合格，可查看历史和分类导出").foregroundStyle(.teal) }
            Button("编辑八个动作名称") { names = model.study?.actions ?? (1...8).map { "动作\($0)" }; edit = true }.disabled(model.busy)
            ForEach(0..<8,id:\.self) { a in
                NavigationLink { ActionView(action:a) } label: {
                    VStack(alignment:.leading) { Text(model.study?.actions[a] ?? "动作\(a+1)").font(.headline); Text(String(format:"%03d–%03d · %d/15合格",a*15+1,(a+1)*15,model.book.count(action:a))) }
                }.accessibilityIdentifier("collectionAction\(a)")
            }
            Button("导出当前任务全部尝试") { model.export(model.trials.filter { $0.assignment?.study_id == model.study?.id && !$0.diagnostic }) }.disabled(model.busy)
            NavigationLink("查看完整采前清单") { PreflightView() }
        }.buttonStyle(.borderless).navigationTitle("正式收集")
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
    private var startAllowed: Bool { model.preflight.ready && model.book.nextAction == action && !model.book.accepted(action:action,slot:slot) }
    var body: some View {
        List {
            StatusBanner()
            LazyVGrid(columns:Array(repeating:GridItem(.flexible()),count:3)) {
                ForEach(1...15,id:\.self) { n in
                    Button { slot = n } label: {
                        VStack { Text(String(format:"%03d",action*15+n)).bold(); Text(model.book.state(action:action,slot:n)).font(.caption) }
                        .frame(maxWidth:.infinity,minHeight:64).background(slot == n ? Color.teal.opacity(0.18):Color.gray.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius:10))
                    }.disabled(model.busy).buttonStyle(.plain)
                }
            }
            Text("第\(slot)/15条 · 下次第\((rows.last?.assignment?.slot_attempt ?? 0)+1)次尝试").font(.headline)
            Button("开始本条") { model.start(action:action,slot:slot) }.buttonStyle(.borderedProminent).disabled(!startAllowed).accessibilityIdentifier("formalStart")
            RecordingControls()
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
            } else if model.book.nextAction != action { Text("须先完成最早未完成动作；历史记录仍可查看或标记补录。").font(.footnote).foregroundStyle(.orange) }
            Section("本条所有尝试") {
                ForEach(rows.reversed()) { trial in NavigationLink { RecordView(trial:trial) } label: { Text("尝试\(trial.assignment?.slot_attempt ?? 0) · \(trial.accepted ? "已合格":"待补录")") } }
            }
            Section("采前检查") {
                Text("通过 \(model.preflight.passed)/\(model.preflight.checks.count)项")
                ForEach(model.preflight.failures.prefix(8)) { row in VStack(alignment:.leading) { Text(row.title); Text(row.detail).font(.caption).foregroundStyle(.secondary) } }
                NavigationLink("查看全部检查项与部位") { PreflightView() }
            }
        }.buttonStyle(.borderless).navigationTitle(model.study?.actions[action] ?? "动作\(action+1)")
         .confirmationDialog("标记待补录，原始记录保留",isPresented:$retryLatest) {
             ForEach(["数据异常","动作做错","提前结束","绑带松动","其他原因"],id:\.self) { reason in Button(reason) { if let latest = rows.last { model.retry(latest,reason:reason) } } }
         }
    }
}
struct PreflightView: View {
    @EnvironmentObject var model: AppModel
    @State private var onlyFailures = true
    var body: some View {
        TimelineView(.periodic(from:.now,by:1)) { _ in
            List {
                Text("通过 \(model.preflight.passed)/\(model.preflight.checks.count)项").font(.title2)
                Toggle("只显示未通过项",isOn:$onlyFailures)
                ForEach(onlyFailures ? model.preflight.failures:model.preflight.checks) { row in
                    VStack(alignment:.leading,spacing:4) {
                        Label(row.title,systemImage:row.passed ? "checkmark.circle.fill":"exclamationmark.circle").foregroundStyle(row.passed ? .teal:.orange)
                        Text(row.detail).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }.navigationTitle("采前检查清单")
        }
    }
}
