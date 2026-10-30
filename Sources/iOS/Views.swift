import SwiftUI
import UIKit
import BaduanjinCore

private let ink = Color(red:0.12,green:0.25,blue:0.28)
struct RootView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        TabView {
            NavigationStack { DevicesView() }.tabItem { Label("设备",systemImage:"figure.stand") }
            NavigationStack { CaptureView() }.tabItem { Label("采集",systemImage:"record.circle") }
            NavigationStack { WearingView() }.tabItem { Label("佩戴",systemImage:"person.crop.rectangle") }
            NavigationStack { RecordsView() }.tabItem { Label("记录",systemImage:"folder") }
            NavigationStack { SettingsView() }.tabItem { Label("设置",systemImage:"slider.horizontal.3") }
        }
        .alert("提示",isPresented:Binding(get:{model.error != nil},set:{ if !$0 {model.error = nil} })) { Button("知道了"){ model.error = nil } } message: { Text(model.error ?? "") }
        .sheet(isPresented:Binding(get:{model.shareURL != nil},set:{if !$0 {model.shareURL = nil}})) { if let url = model.shareURL { ShareSheet(url:url) } }
    }
}
struct StatusBanner: View {
    @EnvironmentObject var model: AppModel
    var body: some View { VStack(alignment:.leading,spacing:8) { Text("八段锦采集 · iOS").font(.title2.bold()).foregroundStyle(ink); Text(model.engineState.message).font(.subheadline); if model.exporting { ProgressView(model.exportProgress); Button("取消导出",role:.cancel){model.cancelExport()} } }.frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,8) }
}
struct DevicesView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        List {
            StatusBanner()
            Section {
                Text("绑定 \(model.roster.count)/15 · 连接 \(model.engineState.devices.filter(\.connected).count)/15")
                HStack { Button("扫描设备"){model.engine.scan()}.disabled(model.busy); Button("连接已绑定"){model.engine.connect(model.roster.values.map(\.peripheralID))}.disabled(model.busy || model.roster.isEmpty) }
                Button("断开所有设备",role:.destructive){model.engine.disconnect()}.disabled(model.engineState.saving)
                NavigationLink("少量设备诊断连接"){ DiagnosticPicker() }
            }
            Section("15个部位") {
                ForEach(BodyRole.all) { role in
                    NavigationLink { RoleView(role:role) } label: {
                        let d = model.device(role)
                        HStack(alignment:.top) {
                            Circle().fill(color(d)).frame(width:10,height:10).padding(.top,6)
                            VStack(alignment:.leading) { Text(role.name).font(.headline); Text(model.roster[role.id]?.name ?? "未绑定").font(.subheadline); if let d { Text(d.issues.isEmpty ? d.status : d.issues.joined(separator:"；")).font(.caption).foregroundStyle(.secondary) }; if model.roster[role.id] != nil { Text("佩戴未确认").font(.caption).foregroundStyle(.orange) } }
                        }
                    }
                }
            }
            Text("绿色仅表示连接和近期四项更新，不代表30Hz达标、佩戴正确或姿态精度合格。").font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("设备").navigationBarTitleDisplayMode(.inline)
    }
    func color(_ d:DeviceSnapshot?) -> Color { guard let d else{return .gray}; if !d.connected {return .red}; if !d.initialized {return .blue}; return d.ages.allSatisfy { $0 != nil && $0! < 500 } ? .green : .orange }
}
struct DiagnosticPicker: View {
    @EnvironmentObject var model: AppModel
    @State private var selected = Set<String>()
    var body: some View {
        List {
            Text("先扫描，再按设备贴纸核对。诊断连接不自动绑定部位。")
            ForEach(model.engineState.found.keys.sorted(),id:\.self) { id in Toggle(isOn:Binding(get:{selected.contains(id)},set:{if $0 {selected.insert(id)} else {selected.remove(id)}})) { VStack(alignment:.leading){Text(model.engineState.found[id] ?? id);Text(id).font(.caption).foregroundStyle(.secondary)} } }
            Button("连接选中的 \(selected.count) 台"){ model.engine.connect(Array(selected)) }.disabled(model.busy || selected.isEmpty || selected.count > 15)
        }.navigationTitle("诊断设备")
    }
}
struct RoleView: View {
    @EnvironmentObject var model: AppModel
    let role: BodyRole
    @State private var bindID: String?
    var body: some View {
        List {
            if let d = model.device(role) {
                Section("当前状态") { Text(d.name);Text(d.status);Text("固件 \(d.firmware)"); ForEach(d.issues,id:\.self){Text($0).foregroundStyle(.orange)} }
                Section("实时数据") {
                    value("加速度 g",d.acceleration); value("角速度 °/s",d.gyro); value("磁场原始值",d.magnetic); value("四元数",d.quaternion)
                    Text("近10秒 Hz：" + d.hz.map{String(format:"%.2f",$0)}.joined(separator:" / "))
                    TrendView(samples:model.trend[d.id] ?? []).frame(height:110)
                    Text("趋势仅显示最近实时加速度，不提供录后回放。").font(.caption)
                }
            }
            Section("绑定 / 更换单只设备") {
                if model.engineState.found.isEmpty { Button("扫描设备"){model.engine.scan()}.disabled(model.busy) }
                ForEach(model.engineState.found.keys.sorted(),id:\.self) { id in Button(model.engineState.found[id] ?? id) {bindID = id}.disabled(model.busy) }
            }
        }.navigationTitle(role.name).confirmationDialog("确认设备与部位",isPresented:Binding(get:{bindID != nil},set:{if !$0 {bindID = nil}})) { if let id = bindID { Button("绑定到\(role.name)"){model.bind(role:role.id,id:id,name:model.engineState.found[id] ?? id);bindID = nil} } } message: { Text("请核对设备标签。更换后需要重新完成佩戴核验。") }
    }
    func value(_ name:String,_ v:[Double])->some View { VStack(alignment:.leading){Text(name).font(.caption);Text(v.map{String(format:"%.5f",$0)}.joined(separator:"  ")).monospacedDigit().font(.footnote)} }
}
struct TrendView: View {
    let samples: [[Double]]
    var body: some View { Canvas { context,size in
        guard samples.count>1 else{return}; let colors:[Color] = [.red,.green,.blue]
        for axis in 0..<3 { var path = Path(); for (i,s) in samples.enumerated() where s.count == 3 { let point = CGPoint(x:CGFloat(i)*size.width/CGFloat(samples.count-1),y:size.height*(0.5-CGFloat(max(-2,min(2,s[axis])))/4)); if i == 0 {path.move(to:point)} else {path.addLine(to:point)} }; context.stroke(path,with:.color(colors[axis]),lineWidth:1.2) }
    }.accessibilityLabel("近期加速度三个轴趋势") }
}
struct CaptureView: View {
    @EnvironmentObject var model: AppModel
    @State private var subject = ""
    @State private var showNew = false
    var body: some View {
        List {
            StatusBanner()
            Section("本次采集任务") {
                Text(model.study.map{"\($0.subject) · \(model.book.total)/120 条合格"} ?? "尚未建立任务")
                NavigationLink("开始正式收集"){CollectionView()}.disabled(model.study == nil || model.busy)
                Button("新建受试者任务"){showNew = true}.disabled(model.busy)
                NavigationLink("查看 / 继续历史任务"){List(model.studies){study in Button(study.subject){model.activate(study.id)}.disabled(model.busy)}}
            }
            Section("诊断录制") {
                Text("点击即保存，3秒后标记动作开始；诊断不占用正式编号。")
                Text(model.engineState.countdown > 0 ? "准备 \(model.engineState.countdown)" : model.engineState.recording ? String(format:"录制 %.1f 秒",model.engineState.elapsed) : "等待开始").font(.title2.monospacedDigit())
                HStack { Button("开始60秒诊断"){model.diagnostic(seconds:60)}.disabled(model.busy); Button("结束并保存"){model.engine.stop()}.disabled(!model.engineState.recording) }
                Text("目前仅验证前台采集；离开前台将结束并标记异常。").font(.caption)
            }
        }.navigationTitle("采集").alert("新建匿名受试者任务",isPresented:$showNew) { TextField("例如 S001",text:$subject).textInputAutocapitalization(.never); Button("建立"){model.create(subject)}; Button("取消",role:.cancel){} } message: { Text("只填写匿名编号，不填写姓名。") }
    }
}
struct CollectionView: View {
    @EnvironmentObject var model: AppModel
    @State private var edit = false
    @State private var names = Array(repeating:"",count:8)
    var body: some View {
        List {
            Text("八个动作各15条，共120个固定编号。正常结束且数据质量通过才默认正常；发现问题再标记补录。")
            Button("编辑八个动作名称"){names = model.study?.actions ?? (1...8).map{"动作\($0)"};edit = true}.disabled(model.busy)
            ForEach(0..<8,id:\.self) { a in NavigationLink { ActionView(action:a) } label: { VStack(alignment:.leading) { Text(model.study?.actions[a] ?? "动作\(a+1)").font(.headline);Text(String(format:"%03d–%03d · %d/15 合格",a*15+1,(a+1)*15,model.book.count(action:a))) } } }
            Button("导出当前任务全部尝试"){model.export(model.trials.filter{$0.assignment?.study_id == model.study?.id && !$0.diagnostic})}.disabled(model.busy)
        }.navigationTitle("正式收集").sheet(isPresented:$edit) { NavigationStack { Form { ForEach(0..<8,id:\.self){i in TextField("动作\(i+1)",text:$names[i])} }.navigationTitle("动作名称").toolbar { ToolbarItem(placement:.confirmationAction){Button("保存"){model.rename(names);edit = false}};ToolbarItem(placement:.cancellationAction){Button("取消"){edit = false}} } } }
    }
}
struct ActionView: View {
    @EnvironmentObject var model: AppModel
    let action:Int
    @State private var slot = 1
    var body: some View {
        List {
            LazyVGrid(columns:Array(repeating:GridItem(.flexible()),count:3)) { ForEach(1...15,id:\.self){n in Button {slot = n} label:{VStack{Text(String(format:"%03d",action*15+n)).bold();Text(model.book.state(action:action,slot:n)).font(.caption)}.frame(maxWidth:.infinity,minHeight:65).background(slot == n ? Color.teal.opacity(0.18):Color.gray.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius:10))}} }
            Text("第\(slot)/15条 · 下次第\((model.book.attempts(action:action,slot:slot).last?.assignment?.slot_attempt ?? 0)+1)次尝试")
            Button("开始本条"){}.disabled(true)
            HStack { Button("继续正常采集"){if let next = model.book.nextSlot(action:action,retry:false){slot = next}};Button("定位待补录"){if let next = model.book.nextSlot(action:action,retry:true){slot = next}} }
            Section("本条所有尝试") { ForEach(model.book.attempts(action:action,slot:slot).reversed()) {trial in NavigationLink {RecordView(trial:trial)} label:{Text("尝试\(trial.assignment?.slot_attempt ?? 0) · \(trial.accepted ? "已合格":"待补录")")} } }
            Section("采前检查") { ForEach(model.checklist,id:\.self){Text($0).font(.footnote)} }
        }.navigationTitle(model.study?.actions[action] ?? "动作\(action+1)")
    }
}
struct RecordsView: View {
    @EnvironmentObject var model: AppModel
    @State private var filter = 0
    var body: some View { List {
        StatusBanner()
        Picker("记录范围",selection:$filter){Text("全部").tag(0);Text("当前任务").tag(1);Text("异常").tag(2)}.pickerStyle(.segmented)
        ForEach(model.trials.filter{filter == 0 || filter == 1 && $0.assignment?.study_id == model.study?.id && !$0.diagnostic || filter == 2 && !$0.qualityPassed}) { trial in NavigationLink {RecordView(trial:trial)} label: {VStack(alignment:.leading){Text(trial.diagnostic ? "诊断记录":String(format:"编号%03d · 尝试%d",trial.assignment?.record_number ?? 0,trial.assignment?.slot_attempt ?? 0));Text(trial.id).font(.caption);Text(trial.accepted ? "已合格":trial.status).font(.caption).foregroundStyle(trial.qualityPassed ? .secondary:Color.orange)}} }
    }.navigationTitle("记录与导出") }
}
struct RecordView: View {
    @EnvironmentObject var model: AppModel
    let trial:Trial
    @State private var retry = false
    var current:Trial {model.trials.first{$0.id == trial.id} ?? trial}
    var body: some View { List {
        Text(current.id).font(.footnote);Text(current.qualityPassed ? "数据质量通过":"数据质量未通过");Text(current.accepted ? "计入正式合格次数":"不计入正式合格次数")
        Button("导出本次"){model.export([current])}.disabled(model.busy)
        if !current.diagnostic { Button("这条有问题，标记补录",role:.destructive){retry = true}.disabled(model.busy) }
        ForEach(current.reviews,id:\.revision){row in Text("修改\(row.revision)：\(row.reason)")}
    }.navigationTitle("记录详情").confirmationDialog("标记待补录",isPresented:$retry){ForEach(["数据异常","动作做错","提前结束","绑带松动","其他原因"],id:\.self){reason in Button(reason){model.retry(current,reason:reason)}}} message:{Text("原记录保留，补录使用新尝试编号。数据质量不通过不能强制计为达标。")} }
}
struct WearingView: View {
    @EnvironmentObject var model:AppModel
    var body:some View { List {
        Section {Text("佩戴核验尚未开放，正式采集暂不可用。请先完成iPhone设备诊断。")}
        ForEach(BodyRole.all){role in VStack(alignment:.leading){Text(role.name);Text(model.roster[role.id]?.name ?? "未绑定").font(.caption);Text("参考姿态 · 引导动作 · 人工确认：未完成").font(.caption).foregroundStyle(.orange)}}
    }.navigationTitle("佩戴核验") }
}
struct SettingsView:View {
    @EnvironmentObject var model:AppModel
    var body:some View { List {
        Section("异常提示"){Text("声音关闭 · 振动关闭");Text("保留界面提示和记录中的质量事件。")}
        Section("传感器配置"){Text("目标：自动惯性50Hz、九轴；保留每台安装方向。查询上限90次/秒/台，不等于接收率。");Button("读取当前配置"){model.engine.readConfiguration()}.disabled(model.busy);Text("配置写入尚未开放。").foregroundStyle(.secondary)}
        Section("硬件加速度校准"){Text("需原始Z正向朝上、放稳，并在启动前确认保持时长。");Text("iOS真实校准尚未验收，当前不发送校准指令。").foregroundStyle(.secondary)}
        Section("独立版本 0.1.0-dev"){Text("仅使用本App文件。导出的ZIP可保存到“文件”或通过系统分享。");Text("手机接收时间不证明内部同步或多台同步；四元数范数正常不代表姿态正确。")}
    }.navigationTitle("设置") }
}
struct ShareSheet:UIViewControllerRepresentable {
    let url:URL
    func makeUIViewController(context:Context)->UIActivityViewController{UIActivityViewController(activityItems:[url],applicationActivities:nil)}
    func updateUIViewController(_ uiViewController:UIActivityViewController,context:Context){}
}
