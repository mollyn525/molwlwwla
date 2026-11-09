import SwiftUI
import BaduanjinCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var configure = false
    @State private var rewrite = false
    @State private var calibrate = false
    private var selectedCount: Int { model.engineState.devices.filter(\.wanted).count }
    var body: some View {
        List {
            StatusBanner()
            Section("磁场维护") {
                TaskLink("单台磁场校准",detail:"按维特原版安卓流程，独立校准一台设备",symbol:"scope") { MagneticCalibrationView() }.accessibilityIdentifier("singleMagCalibration")
            }
            Section("安装方式标记") {
                Picker("安装方式",selection:Binding(get:{model.study?.mountingLabel ?? .vertical},set:{model.setMountingLabel($0)})) {
                    ForEach(MountingLabel.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).disabled(model.busy || model.study == nil).accessibilityIdentifier("mountingLabel")
                Text("用于当前受试者的界面说明和采集记录；切换标记不会修改设备设置或 XYZ 数据。").font(.caption).foregroundStyle(.secondary)
                if model.study == nil { Text("请先新建或继续受试者任务").font(.caption) }
            }
            Section("手机查询上限") {
                Stepper("\(model.queryHz)次/秒/台",value:$model.queryHz,in:40...200,step:5).disabled(model.busy)
                Button("应用查询上限") { model.setQueryHz() }.disabled(model.busy)
                Text("默认90次/秒/台。上限不等于实际接收率或传感器内部采样率，不会修改传感器输出设置。").font(.caption).foregroundStyle(.secondary)
            }
            Section("统一传感器配置") {
                Text("选中\(selectedCount)台 · 目标为50Hz、九轴，保留各设备安装方向；逐台读旧值、写入并回读。").font(.footnote).foregroundStyle(.secondary)
                Button("读取当前配置") { model.engine.readConfiguration() }.disabled(model.busy || selectedCount == 0)
                Button("应用 / 重试未达标设备") { configure = true }.disabled(model.busy || selectedCount == 0)
                Button("重新写入并核验模板") { rewrite = true }.disabled(model.busy || selectedCount == 0)
            }
            Section("硬件加速度校准") {
                TaskLink("查看加速度校准结果",detail:"查看每台设备的过程、前后读数和历史结果",symbol:"checklist") { CalibrationResultsView() }.accessibilityIdentifier("calibrationResults")
                Text("佩戴前，按机身坐标标识让原始Z正向朝上（约+1g），放在水平稳定台面，至少放稳3秒；不能按外壳“正面”判断。")
                Text("当前选中\(selectedCount)台，校准过程并行进行，每台独立复核和保存，单台失败不影响其他设备。全组通常约20–40秒，请预留1分钟，直到批次结束都保持不动。").font(.footnote).accessibilityIdentifier("parallelCalibrationExplanation")
                Button("一起校准选中的 \(selectedCount) 台") { calibrate = true }.disabled(model.busy || selectedCount == 0).accessibilityIdentifier("parallelCalibrationStart")
                NavigationLink("查看逐台配置 / 校准结果") { OperationResultsView() }
                DisclosureGroup("校准等待与中断说明") {
                    Text("短暂停顿后等待数据恢复，重新取得约3秒完整稳定窗口再复核。明显运动、500ms以上间隙或断线仍会停止该台；不会重复发送启动校准。结果可随时通过上方按钮查看。").font(.caption).foregroundStyle(.secondary)
                    Text("蓝牙指令仍依次提交，不代表硬件同步启动。离开前台、蓝牙整体不可用、用户取消或共同审计故障会停止整个批次。").font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.engineState.parallelCalibration { CalibrationProgressSection() }
            Section("提示方式") { Text("声音关闭 · 振动关闭"); Text("保留界面告警及质量事件。").font(.footnote).foregroundStyle(.secondary) }
            Section("独立版本 \(model.version)") {
                NavigationLink("连接诊断 / 导出日志") { ConnectionLogView() }
                Text("保留本App现有任务、绑定与历史数据；ZIP通过系统分享或“文件”保存。")
                Text("手机接收时间不能证明四项内部同步或15台间同步；四元数范数正常不代表姿态正确。磁场校准结果可在操作日志中查看。").font(.caption).foregroundStyle(.secondary)
            }
        }.buttonStyle(.borderless).navigationTitle("设置")
         .confirmationDialog("应用50Hz / 九轴配置",isPresented:$configure) { Button("对选中设备应用并回读") { model.batch(calibrate:false) } } message: { Text("只修改不符合模板的设备，逐台独立记录结果，保留安装方向。") }
         .confirmationDialog("重新写入配置模板",isPresented:$rewrite) { Button("重新写入并保存") { model.batch(calibrate:false,rewrite:true) } } message: { Text("即使旧值已符合，也会重新写入50Hz和九轴设置并保存；安装方向保留。") }
         .confirmationDialog("确认姿态与保持时长",isPresented:$calibrate) {
            Button("确认全部原始+Z朝上，一起开始") { model.batch(calibrate:true,placementConfirmed:true) }
         } message: { Text("此操作会修改硬件校准。确认选中\(selectedCount)台原始Z正向朝上、已放稳至少3秒，点击后一起校准，全组保持约1分钟，直到提示批次结束。每台独立等待、复核、保存；单台失败不影响其他设备，不自动重新启动校准。") }
    }
}
struct CalibrationProgressSection: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Section("本次并行校准 · 每台独立处理") {
            ForEach(model.engineState.operationProgress) { item in
                VStack(alignment:.leading,spacing:4) {
                    Text(item.name).font(.headline)
                    Text(item.finished ? (item.passed ? "保存后静态复核通过":"该台已结束，查看原因") : "进行中").foregroundStyle(item.finished ? (item.passed ? .teal:.orange):.secondary)
                    Text(item.message).font(.footnote)
                    Text(item.saveSubmitted ? "本台已提交保存":"本台尚未提交保存").font(.caption)
                }.accessibilityIdentifier("parallelProgress_"+item.id)
            }
        }
    }
}
struct CalibrationResultsView: View {
    @EnvironmentObject var model: AppModel
    private var results: [OperationDetail] { model.operationHistory.filter(\.calibration) }
    var body: some View {
        List {
            StatusBanner()
            if model.engineState.parallelCalibration { CalibrationProgressSection() }
            Section {
                Text("共\(results.count)次 · 保存后静态复核通过\(results.filter(\.passed).count)次").font(.headline)
                Text("按时间从新到旧保留每次尝试。点击设备查看校准前后读数与未通过原因。").font(.caption)
                Button("导出完整操作审计") { model.exportOperations() }.disabled(model.busy)
            }
            if results.isEmpty { Text("尚无加速度校准结果；完成一台后将在这里显示。").accessibilityIdentifier("calibrationResultsEmpty") }
            ForEach(results) { result in
                NavigationLink { CalibrationResultDetailView(result:result) } label: {
                    VStack(alignment:.leading,spacing:5) {
                        Text(result.name).font(.headline)
                        Text(result.status).foregroundStyle(result.passed ? .teal:.orange)
                        Text(result.result).font(.caption).lineLimit(3)
                        Text(Date(timeIntervalSince1970:Double(result.at)/1000),format:.dateTime.year().month().day().hour().minute().second()).font(.caption).foregroundStyle(.secondary)
                    }
                }.accessibilityIdentifier("calibrationResult_"+result.id)
            }
        }.navigationTitle("加速度校准结果")
    }
}
struct CalibrationResultDetailView: View {
    let result: OperationDetail
    private func number(_ vector: [Double]?, _ index: Int, signed: Bool = false) -> String {
        guard let vector else { return "未记录" }
        return String(format:signed ? "%+.5f":"%.5f",vector[index])
    }
    var body: some View {
        List {
            Section(result.name) {
                Text(result.status).font(.headline).foregroundStyle(result.passed ? .teal:.orange)
                Text(result.result)
                Text(result.saveSubmitted ? "已提交保存指令；没有固件内部完成应答。":"未提交保存；结束读数变化不代表已持久保存。")
                Text(Date(timeIntervalSince1970:Double(result.at)/1000),format:.dateTime.year().month().day().hour().minute().second())
            }
            Section("加速度读数对比 · 单位g") {
                Grid(alignment:.trailing,horizontalSpacing:12,verticalSpacing:10) {
                    GridRow { Text("轴"); Text("开始前"); Text("结束时"); Text("变化量") }.font(.caption)
                    ForEach(0..<3,id:\.self) { axis in
                        GridRow {
                            Text(["X","Y","Z"][axis])
                            Text(number(result.beforeMean,axis))
                            Text(number(result.afterMean,axis))
                            Text(number(result.delta,axis,signed:true))
                        }.font(.caption.monospacedDigit())
                    }
                }.accessibilityIdentifier("calibrationComparison")
                Text("变化量＝结束时窗口均值－开始前窗口均值；这是输出读数变化，不是IMU内部补偿系数或精度认证。").font(.caption).foregroundStyle(.secondary)
                Text(result.finalWindowPassed.map { $0 ? "结束时静态窗口通过；整体结果以上方结论为准。":"结束时静态窗口未通过，对比读数仅供排查。" } ?? "历史记录未单独保存结束窗口状态；请结合原始结果判断。").font(.caption)
            }
            Section("过程记录") {
                if result.recoveredBeforeSave { Text("保存前曾等待数据恢复并重新复核") }
                if result.recoveredAfterSave { Text("保存后曾等待数据恢复并重新复核") }
                if let gap = result.longestGapMS { Text(String(format:"过程最长接收间隔：%.1f ms",gap)) }
                if let gyro = result.maxGyro { Text(String(format:"过程最大角速度模长：%.3f °/s",gyro)) }
                Text("设备："+result.address).font(.caption).textSelection(.enabled)
                Text("操作编号："+result.id).font(.caption).textSelection(.enabled)
            }
        }.navigationTitle("校准结果详情")
    }
}
struct OperationResultsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        List {
            StatusBanner()
            Button("导出完整操作审计") { model.exportOperations() }.disabled(model.busy)
            ForEach(model.engineState.operationResults,id:\.self) { Text($0).font(.footnote) }
            if model.operationHistory.isEmpty { Text("尚无已完成操作") }
            ForEach(model.operationHistory) { result in
                Section(result.title) {
                    Text(result.result).foregroundStyle(result.passed ? .teal:.orange)
                    Text(result.saveSubmitted ? "已提交保存指令；仍以回读/静态复核结果为准":"没有记录到保存指令提交").font(.caption)
                    Text(Date(timeIntervalSince1970:Double(result.at)/1000),style:.date).font(.caption)
                }
            }
        }.navigationTitle("逐台操作结果")
    }
}
