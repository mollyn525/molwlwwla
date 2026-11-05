import SwiftUI
import BaduanjinCore

private let traceColors: [Color] = [
    Color(red:234/255,green:104/255,blue:82/255),
    Color(red:94/255,green:206/255,blue:177/255),
    Color(red:31/255,green:144/255,blue:250/255),
    Color(white:0.70)
]

struct FrameChart: View {
    let magnetic: Bool, points: [MonitorPoint], fresh: Bool
    var body: some View {
        let labels = magnetic ? ["X","Y","Z","Norm"] : ["X","Y","Z"]
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Text(magnetic ? "Magnetic Field (a.u.)" : "Orientation (°)").font(.subheadline.bold())
                Spacer()
                ForEach(labels.indices,id:\.self) { i in
                    HStack(spacing:3) { Circle().fill(traceColors[i]).frame(width:7,height:7); Text(labels[i]).font(.caption) }
                }
            }
            Canvas { context,size in
                let samples = points.flatMap { $0.values ?? [] }
                guard let minY = samples.min(), let maxY = samples.max() else { return }
                let span = max(magnetic ? 0.2 : 2, maxY-minY)
                let low = minY-span*0.1, high = maxY+span*0.1
                let left: CGFloat = 38, top: CGFloat = 9, height = size.height-2*top
                func y(_ val: Double) -> CGFloat { top + height * CGFloat((high-val)/(high-low)) }
                for i in 0...4 {
                    let val = low + (high-low)*Double(i)/4, row = y(val)
                    var line = Path(); line.move(to:CGPoint(x:left,y:row)); line.addLine(to:CGPoint(x:size.width,y:row))
                    context.stroke(line,with:.color(.secondary.opacity(0.2)),lineWidth:0.6)
                    context.draw(Text(String(format:"%.1f",val)).font(.system(size:9)).foregroundColor(.secondary),at:CGPoint(x:left-4,y:row),anchor:.trailing)
                }
                for axis in labels.indices {
                    var path = Path(), previous: (UInt64,Double)?
                    for (i,p) in points.enumerated() {
                        guard let values = p.values, axis < values.count else { previous = nil; continue }
                        let v = values[axis], x = left+(size.width-left)*CGFloat(i)/CGFloat(max(1,points.count-1))
                        let pt = CGPoint(x:x,y:y(v))
                        if let (ns,last) = previous, p.ns >= ns, p.ns-ns < 500_000_000, magnetic || abs(v-last) <= 180 { path.addLine(to:pt) }
                        else { path.move(to:pt) }
                        previous = (p.ns,v)
                    }
                    context.stroke(path,with:.color(traceColors[axis]),lineWidth:1.6)
                }
            }.frame(height:150).opacity(fresh ? 1 : 0.45)
             .overlay { if points.allSatisfy({$0.values == nil}) { Text("等待有效数据").font(.caption).foregroundStyle(.secondary) } }
        }
    }
}

private struct SensorAxes: View {
    let q: [Double]?
    var body: some View {
        Canvas { ctx,size in
            guard let q else { return }
            let origin = CGPoint(x:size.width/2,y:size.height/2), scale = min(size.width,size.height)*0.35
            for axis in 0..<3 {
                var basis = [0.0,0,0]; basis[axis] = 1
                guard let v = try? PoseMonitor.rotate(q,basis) else { continue }
                let end = CGPoint(x:origin.x+scale*CGFloat(0.85*v[0]-0.53*v[1]),y:origin.y+scale*CGFloat(0.28*v[0]+0.44*v[1]-0.85*v[2]))
                var line = Path(); line.move(to:origin); line.addLine(to:end)
                ctx.stroke(line,with:.color(traceColors[axis]),lineWidth:3)
                ctx.draw(Text(["X","Y","Z"][axis]).bold().foregroundColor(traceColors[axis]),at:CGPoint(x:end.x+8,y:end.y-6))
            }
        }.frame(height:140).accessibilityLabel("当前显示参考系中的传感器三轴")
    }
}

struct MonitorView: View {
    @EnvironmentObject var model: AppModel
    @State var selection = ""
    @State private var mode = 0, prompt: HeadingAction?
    private enum HeadingAction: String, Identifiable {
        case reset, all, baseline, revertAll
        var id: String { rawValue }
    }
    private func formatted(_ values: [Double]) -> String {
        zip(["X","Y","Z"],values).map { String(format:"%@ %+.3f",$0.0,$0.1) }.joined(separator:"   ")
    }
    var body: some View {
        let devices = model.engineState.devices.filter { $0.wanted || $0.connected || $0.id == selection }
        let d = devices.first { $0.id == selection }, now = model.engineState.timestamp
        let snap = d?.live.pose.snapshot(now:now,connected:d?.connected == true)
        let magFresh = d?.connected == true && (d?.ages[2] ?? nil).map { $0 < 500 } == true
        List {
            Section {
                Picker("设备",selection:$selection) { Text("选择设备").tag(""); ForEach(devices) { Text(model.monitorLabel($0)).tag($0.id) } }
                Picker("监测项目",selection:$mode) { Text("Mag Norm").tag(0); Text("Orientation").tag(1) }.pickerStyle(.segmented)
            }
            if mode == 0 {
                Section {
                    FrameChart(magnetic:true,points:d?.live.magPoints ?? [],fresh:magFresh)
                    if let f = d?.live.field, magFresh {
                        Text("µT    "+formatted(f.microtesla)); Text("a.u.  "+formatted(f.axes))
                        Text(String(format:"Norm  %.3f a.u.   ·   %.2f µT",f.norm,f.norm*FieldReading.reference)).font(.headline)
                    } else { Text(magFresh ? (d?.live.fieldReason ?? "等待磁场数据") : "等待新的磁场帧").foregroundStyle(.secondary) }
                    Text("三轴各自除以 40 µT，再计算模长。1.00 a.u. 对应 40 µT。").font(.footnote)
                }.monospacedDigit()
                Section("环境观察") {
                    Button("设置当前环境为观察基线") { prompt = .baseline }.disabled(model.busy || !magFresh)
                    if let change = snap?.change { Text(String(format:"相对基线 %+.1f%%",100*change)).foregroundStyle(snap?.warning == true ? Color.orange : Color.primary) }
                    NavigationLink("单台磁场校准") { MagneticCalibrationView(selection:selection) }
                }
            } else {
                Section {
                    FrameChart(magnetic:false,points:d?.live.anglePoints ?? [],fresh:snap?.q != nil)
                    if let angles = snap?.rpy { Text(formatted(angles)+" °").font(.headline).monospacedDigit() }
                    if let raw = d?.quaternion, snap?.q != nil, let angles = try? PoseMonitor.euler(raw) { Text("原始  "+formatted(angles)+" °").font(.caption).monospacedDigit() }
                    SensorAxes(q:snap?.q)
                    if snap?.q == nil { Text(snap?.orientationReason ?? "等待四元数").font(.caption) }
                    Text("X 滚转 · Y 俯仰 · Z 航向").font(.caption).foregroundStyle(.secondary)
                }
                Section("航向参考") {
                    Text(snap?.headingID.isEmpty == false ? "显示当前归零参考" : "显示原始航向")
                    Button("Heading reset · 本台归零") { prompt = .reset }.disabled(model.busy || snap?.headingDefined != true || snap?.headingID.isEmpty != true)
                    Button("Revert · 恢复本台航向") { model.engine.heading([selection],revert:true) }.disabled(model.busy || snap?.headingID.isEmpty != false)
                    Button("选中设备分别归零") { prompt = .all }.disabled(model.busy || devices.filter(\.wanted).isEmpty)
                    Button("恢复选中设备航向") { prompt = .revertAll }.disabled(model.busy || !devices.contains { $0.wanted && !$0.live.pose.headingID.isEmpty })
                }
            }
            Text(model.engineState.message).font(.footnote).foregroundStyle(.secondary)
        }
        .navigationTitle("实时监测")
        .onAppear { if selection.isEmpty, devices.count == 1 { selection = devices[0].id } }
        .alert(item:$prompt) { action in
            let ids = action == .all || action == .revertAll ? devices.filter(\.wanted).map(\.id) : [selection]
            if action == .revertAll { return Alert(title:Text("恢复所选 \(ids.count) 台原始航向？"),primaryButton:.default(Text("恢复")) { model.engine.heading(ids,revert:true) },secondaryButton:.cancel()) }
            let guidance = action == .baseline ? "请保持传感器和周围磁性物体不动。" : "将所选 \(ids.count) 台设备的 X 轴水平投影分别指向各自的零航向，X 轴避免竖直。"
            return Alert(title:Text("确认放稳"),message:Text(guidance),primaryButton:.default(Text("已放稳")) { model.engine.heading(ids,revert:false,baseline:action == .baseline) },secondaryButton:.cancel())
        }
    }
}

struct MagneticCalibrationView: View {
    @EnvironmentObject var model: AppModel
    @State var selection = ""
    @State private var confirm = false, finish = false
    var body: some View {
        let s = model.engineState, job = s.magPhase
        let held = job.busy || job == .uncertain
        let chosen = held ? (s.magTarget ?? "") : selection
        let d = s.devices.first { $0.id == chosen }
        List {
            Section("校准对象") {
                if held { Text(d.map(model.monitorLabel) ?? chosen) }
                else {
                    Picker("单台设备",selection:$selection) {
                        Text("请选择设备").tag("")
                        ForEach(s.devices.filter { $0.wanted || $0.connected }) { Text(model.monitorLabel($0)).tag($0.id) }
                    }
                }
                if let d { Text("固件 "+d.firmware).font(.caption); if let f = d.live.field, d.connected, (d.ages[2] ?? 1000) < 500 { Text(String(format:"磁场模长 %.2f µT",f.norm*40)) } }
            }
            Section("维特磁场校准") {
                Text("取下传感器，远离磁铁和金属物体。核对机身标记，先将 X 轴正向指北。")
                ForEach(["X","Y","Z"],id:\.self) { axis in Text("\(axis) 轴正向指北，绕 \(axis) 轴缓慢转 1–2 圈。") }
                Text("依次完成三轴后，手动结束并保存。").font(.footnote)
            }
            Section {
                Button("开始单台磁场校准") { confirm = true }.disabled(held || model.busy || d?.canStartMag != true)
                Button(job == .uncertain ? "核对原设备，结束并保存" : "结束并保存") { finish = true }
                    .disabled(!(job == .rotating || job == .uncertain) || d?.initialized != true || model.exporting || model.pending || s.recording || s.saving || s.batch || s.movement || s.headingPending)
                if !s.magMessage.isEmpty { Text(s.magMessage) }
                if !held && d?.canStartMag != true { Text("请连接已核对固件的九轴设备，等候磁场数据。").foregroundStyle(.secondary) }
            }
        }.navigationTitle("单台磁场校准")
        .confirmationDialog("开始校准 "+(d?.name ?? ""),isPresented:$confirm,titleVisibility:.visible) {
            Button("已核对设备及姿态，开始") { model.engine.startMag(chosen) }
        } message: { Text("将写入这台维特设备并清除该部位的旧佩戴参考。") }
        .confirmationDialog("结束校准 "+(d?.name ?? ""),isPresented:$finish,titleVisibility:.visible) {
            Button("向这台设备提交结束和保存") { model.engine.finishMag(chosen) }
        } message: { Text("请确认三轴旋转已经完成。") }
    }
}

