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
            Section("异常提示") { Text("声音关闭 · 振动关闭"); Text("保留界面告警及质量事件。") }
            Section("手机查询上限") {
                Stepper("\(model.queryHz)次/秒/台",value:$model.queryHz,in:40...200,step:5).disabled(model.busy)
                Button("应用查询上限") { model.setQueryHz() }.disabled(model.busy)
                Text("默认90次/秒/台。上限不等于实际接收率或传感器内部采样率，不会修改传感器输出设置。").font(.caption).foregroundStyle(.secondary)
            }
            Section("统一传感器配置") {
                Text("选中\(selectedCount)台 · 目标为50Hz、九轴，保留各设备安装方向；逐台读旧值、写入并回读。")
                Button("读取当前配置") { model.engine.readConfiguration() }.disabled(model.busy || selectedCount == 0)
                Button("应用 / 重试未达标设备") { configure = true }.disabled(model.busy || selectedCount == 0)
                Button("重新写入并核验模板") { rewrite = true }.disabled(model.busy || selectedCount == 0)
            }
            Section("硬件加速度校准") {
                Text("佩戴前，按机身坐标标识让原始Z正向朝上（约+1g），放在水平稳定台面，至少放稳3秒；不能按外壳“正面”判断。")
                Text("当前选中\(selectedCount)台，逐台约16–20秒，全组预计约\(max(1,Int(ceil(Double(selectedCount)*20/60))))分钟。直到批次结束，全组都需保持不动。").font(.footnote)
                Button("已按原始+Z朝上放稳，准备校准") { calibrate = true }.disabled(model.busy || selectedCount == 0)
                Text("先检查姿态，再解锁、启动、等待、保存并静态复核。移动、缺口或断线会停止该台后续操作；静态复核不能证明内部完成状态或绝对精度。").font(.caption).foregroundStyle(.secondary)
                NavigationLink("查看逐台配置 / 校准结果") { OperationResultsView() }
            }
            Section("独立版本 \(model.version)") {
                NavigationLink("连接诊断 / 导出日志") { ConnectionLogView() }
                Text("保留本App现有任务、绑定与历史数据；ZIP通过系统分享或“文件”保存。")
                Text("手机接收时间不能证明四项内部同步或15台间同步；四元数范数正常不代表姿态正确。磁场校准、归零、恢复出厂和固件升级不开放。").font(.caption).foregroundStyle(.secondary)
            }
        }.buttonStyle(.borderless).navigationTitle("设置")
         .confirmationDialog("应用50Hz / 九轴配置",isPresented:$configure) { Button("对选中设备应用并回读") { model.batch(calibrate:false) } } message: { Text("只修改不符合模板的设备，逐台独立记录结果，保留安装方向。") }
         .confirmationDialog("重新写入配置模板",isPresented:$rewrite) { Button("重新写入并保存") { model.batch(calibrate:false,rewrite:true) } } message: { Text("即使旧值已符合，也会重新写入50Hz和九轴设置并保存；安装方向保留。") }
         .confirmationDialog("确认姿态与保持时长",isPresented:$calibrate) {
            Button("确认全部原始+Z朝上，开始校准") { model.batch(calibrate:true,placementConfirmed:true) }
         } message: { Text("此操作会修改硬件校准。确认选中\(selectedCount)台原始Z正向朝上、已放稳至少3秒，点击后全组继续保持约\(max(1,Int(ceil(Double(selectedCount)*20/60))))分钟，直到提示批量操作结束。失败不会自动重试。") }
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
