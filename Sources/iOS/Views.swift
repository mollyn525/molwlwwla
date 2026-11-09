import SwiftUI
import UIKit
import BaduanjinCore

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
    var body: some View { VStack(alignment:.leading,spacing:8) {
        Label(model.engineState.message,systemImage:model.engineState.recording ? "record.circle.fill" : "info.circle")
            .font(.subheadline).fixedSize(horizontal:false,vertical:true)
        Text(model.engineState.freeBytes >= 0 ? String(format:"可用 %.2f GiB · 待写 %d项",Double(model.engineState.freeBytes)/1073741824,model.engineState.queuedWrites):"存储检查中").font(.caption).foregroundStyle(.secondary)
        if model.engineState.queuedWrites >= 2000 { Text("写盘积压较高，异常会保留并影响质量判定").font(.caption).foregroundStyle(.orange) }
        if model.engineState.batch { Text(model.engineState.batchMessage).foregroundStyle(.orange); Button(model.engineState.parallelCalibration ? "停止本批全部校准":"停止后续操作"){model.engine.cancelBatch()} }
        if model.engineState.movement { Button("取消本次佩戴检查"){model.engine.stopWearing()} }
        if model.exporting { ProgressView(model.exportProgress); Button("取消导出",role:.cancel){model.cancelExport()} }
    }.frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,4) }
}
struct DevicesView: View {
    @EnvironmentObject var model: AppModel
    @State private var bodyRole: Int?
    var body: some View {
        List {
            Section("连接概览") {
                HStack {
                    counter("已绑定",model.roster.count)
                    counter("已连接",model.engineState.devices.filter { $0.wanted && $0.connected }.count)
                    counter("部位就绪",BodyRole.all.compactMap { model.device($0) }.filter { color($0) == .green }.count)
                }
                ViewThatFits(in:.horizontal) {
                    HStack(spacing:12) { connectionButtons }
                    VStack(spacing:8) { connectionButtons }
                }.padding(.vertical,4)
                TaskLink("实时监测 · Mag Norm / Orientation",detail:"磁场四条曲线、姿态三轴与航向归零",symbol:"waveform.path.ecg") { MonitorView() }.accessibilityIdentifier("liveMonitor")
            }
            Section("部位就绪") {
                BodyMapView(selectedRole:$bodyRole).frame(height:400)
                Text("正面示意 · 左右按佩戴者 · 点击部位查看或绑定").font(.caption)
            }
            Section("采集与连接管理") {
                TaskLink("开始正式收集",detail:model.study?.subject ?? "先建立受试者任务",symbol:"record.circle") { if model.study == nil { CaptureView() } else { CollectionView() } }
                Text("绑定 \(model.roster.count)/15 · 连接 \(model.engineState.devices.filter(\.connected).count)/15").font(.caption).foregroundStyle(.secondary)
                StatusBanner()
                Button("断开所有设备",role:.destructive){model.engine.disconnect()}.disabled(model.engineState.saving || model.engineState.batch || model.engineState.movement)
                NavigationLink("少量设备诊断连接"){ DiagnosticPicker() }
            }
            ConnectionStatusSection()
            Section("15个部位") {
                ForEach(BodyRole.all) { role in
                    NavigationLink { RoleView(role:role) } label: {
                        let d = model.device(role)
                        HStack(alignment:.top) {
                            Circle().fill(color(d)).frame(width:10,height:10).padding(.top,6)
                            VStack(alignment:.leading) { Text(role.name).font(.headline); Text(model.roster[role.id]?.name ?? "未绑定").font(.subheadline); if let d { Text(d.issues.isEmpty ? d.status : d.issues.joined(separator:"；")).font(.caption).foregroundStyle(.secondary) }; if let b = model.roster[role.id], !b.wearConfirmed { Text("佩戴待核"+(b.wearPendingMS.map { String(format:" · 已持续%.0f秒",max(0,Double(BluetoothEngine.wall()-$0)/1000)) } ?? "")).font(.caption).foregroundStyle(.orange) } }
                        }
                    }
                }
            }
            Text("部位就绪表示已连接、初始化，近期加速度和角速度均有更新且各 >40 Hz。佩戴与参考姿态见部位详情。").font(.footnote).foregroundStyle(.secondary)
        }.buttonStyle(.borderless).navigationTitle("设备")
         .navigationDestination(item:$bodyRole) { index in RoleView(role:BodyRole.all[index]) }
    }
    private var connectionButtons: some View {
        Group {
            Button { model.engine.scan() } label: { Label("扫描设备",systemImage:"magnifyingglass").frame(minHeight:32) }
                .buttonStyle(.bordered).disabled(model.busy).accessibilityLabel("扫描设备")
            Button { model.engine.connect(model.roster.values.map(\.peripheralID)) } label: { Label("连接已绑定",systemImage:"link").frame(minHeight:32) }
                .buttonStyle(.borderedProminent).disabled(model.busy || model.roster.isEmpty).accessibilityLabel("连接已绑定")
        }
    }
    private func counter(_ label: String, _ count: Int) -> some View {
        VStack(alignment:.leading) { Text("\(count)/15").font(.title3.bold()).monospacedDigit(); Text(label).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth:.infinity,alignment:.leading)
    }
    func color(_ d:DeviceSnapshot?) -> Color { guard let d else{return .gray}; if !d.connected {return .red}; if !d.initialized {return .blue}; return d.wanted && !d.maintenance && QualityPolicy.current.recentDataHealthy(d.ages) && QualityPolicy.current.recentRatesPass(d.hz) ? .green : .orange }
}
struct DiagnosticPicker: View {
    @EnvironmentObject var model: AppModel
    @State private var selected = Set<String>()
    var body: some View {
        List {
            StatusBanner()
            Text("先扫描，再按设备贴纸核对。诊断连接不自动绑定部位。")
            ForEach(model.engineState.found.keys.sorted(),id:\.self) { id in Toggle(isOn:Binding(get:{selected.contains(id)},set:{if $0 {selected.insert(id)} else {selected.remove(id)}})) { VStack(alignment:.leading){Text(model.engineState.found[id] ?? id);Text(id).font(.caption).foregroundStyle(.secondary)} } }
            Button("连接选中的 \(selected.count) 台"){ model.engine.connect(Array(selected)) }.disabled(model.busy || selected.isEmpty || selected.count > 15)
            Button("仅连接诊断60秒（无订阅、无查询）"){model.engine.connect(Array(selected),passiveSeconds:60)}.disabled(model.busy || selected.isEmpty || selected.count > 15)
            Text("仅连接诊断需先断开全部；到时会断开并清除目标，不自动开启采集查询。").font(.caption).foregroundStyle(.secondary)
            ConnectionStatusSection()
            Button("断开所有设备",role:.destructive){model.engine.disconnect()}.disabled(model.engineState.saving || model.engineState.batch || model.engineState.movement)
            NavigationLink("查看连接过程 / 导出诊断"){ConnectionLogView()}
        }.buttonStyle(.borderless).navigationTitle("诊断设备")
    }
}
struct ConnectionStatusSection: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let devices = model.engineState.devices.filter { $0.wanted || $0.connected }
        if !devices.isEmpty {
            Section("选定设备连接状态") {
                ForEach(devices) { d in
                    VStack(alignment:.leading,spacing:5) {
                        Text(d.name).font(.headline)
                        Text("\(d.status) · 初始化\(d.initialized ? "完成" : "未完成")")
                        if !d.lastError.isEmpty { Text("最近失败：\(d.lastError)").font(.footnote).foregroundStyle(.orange) }
                        if d.initialized {
                            Text("近10秒 Hz（加速度 / 角速度）：" + d.hz.prefix(2).map { String(format:"%.2f",$0) }.joined(separator:" / ")).font(.caption).monospacedDigit()
                        }
                    }
                }
            }
        }
    }
}
struct ConnectionLogView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        List {
            Text("版本 \(model.version) · 保留本次打开App以来最近200条连接事件，断开后仍可查看。")
            Button("导出连接诊断"){model.exportConnectionDiagnostics()}.disabled(model.busy)
            ForEach(Array(model.engineState.connectionLog.reversed().enumerated()),id:\.offset) { row in Text(row.element).font(.caption).textSelection(.enabled) }
        }.navigationTitle("连接诊断")
    }
}
struct RoleView: View {
    @EnvironmentObject var model: AppModel
    let role: BodyRole
    @State private var bindID: String?
    @State private var trendKind = 0
    var body: some View {
        List {
            if let d = model.device(role) {
                NavigationLink("Mag Norm / Orientation") { MonitorView(selection:d.id) }
                Section("当前状态") { Text(d.name);Text(d.status);Text("固件 \(d.firmware)"); if !d.lastError.isEmpty { Text("最近失败：\(d.lastError)").foregroundStyle(.orange) }; ForEach(d.issues,id:\.self){Text($0).foregroundStyle(.orange)} }
                Section("实时数据") {
                    value("加速度 g",d.acceleration); value("角速度 °/s",d.gyro); value("磁场原始值",d.magnetic); value("四元数",d.quaternion)
                    Text("近10秒 Hz（加速度 / 角速度）：" + d.hz.prefix(2).map{String(format:"%.2f",$0)}.joined(separator:" / "))
                    Text("频率要求：加速度、角速度各 >40 Hz；磁场与四元数继续记录。").font(.caption)
                    Picker("趋势数据",selection:$trendKind){Text("加速").tag(0);Text("角速").tag(1);Text("磁场").tag(2);Text("四元数").tag(3)}.pickerStyle(.segmented)
                    LiveTrendView(samples:trendKind == 0 ? model.trend[d.id] ?? [] : model.otherTrends[d.id]?[streams[trendKind]] ?? [],quaternion:trendKind == 3).frame(height:135)
                    Text("实时趋势按界面刷新显示，数值来自最新接收帧；完整数据以导出为准，不提供录后回放。").font(.caption)
                    if !d.lastOperation.isEmpty { Text("最近维护："+d.lastOperation).font(.footnote) }
                }
            }
            NavigationLink("佩戴参考 / 引导动作 / 人工确认"){WearRoleView(role:role)}
            Section("绑定 / 更换单只设备") {
                if model.engineState.found.isEmpty { Button("扫描设备"){model.engine.scan()}.disabled(model.busy) }
                ForEach(model.engineState.found.keys.sorted(),id:\.self) { id in Button(model.engineState.found[id] ?? id) {bindID = id}.disabled(model.busy) }
            }
        }.navigationTitle(role.name).confirmationDialog("确认设备与部位",isPresented:Binding(get:{bindID != nil},set:{if !$0 {bindID = nil}})) { if let id = bindID { Button("绑定到\(role.name)"){model.bind(role:role.id,id:id,name:model.engineState.found[id] ?? id);bindID = nil} } } message: { Text("请核对设备标签。更换后参考与佩戴状态会重置，建议重新核验；未完成仍可采集原始数据。") }
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
struct ShareSheet:UIViewControllerRepresentable {
    let url:URL
    func makeUIViewController(context:Context)->UIActivityViewController{UIActivityViewController(activityItems:[url],applicationActivities:nil)}
    func updateUIViewController(_ uiViewController:UIActivityViewController,context:Context){}
}
