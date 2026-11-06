import SwiftUI
import BaduanjinCore

struct SubjectCalibrationView: View {
    @EnvironmentObject var model: AppModel
    @State private var kind: SubjectCalibrationKind = .staticPose
    @State private var confirm = false
    private var rows: [Trial] {
        model.trials.filter { $0.calibration?.studyID == model.study?.id && $0.calibration?.kind == kind }
    }
    var body: some View {
        List {
            Section {
                Text(model.study?.subject ?? "请先建立受试者任务").font(.headline)
                ForEach(SubjectCalibrationKind.allCases) { item in
                    Label(item.title,systemImage:model.calibrationCompleted(item) ? "checkmark.circle.fill":"circle")
                        .foregroundStyle(model.calibrationCompleted(item) ? .teal:.primary)
                }
                Picker("采集项目",selection:$kind) {
                    Text("静态 N-pose").tag(SubjectCalibrationKind.staticPose)
                    Text("动态 两个深蹲").tag(SubjectCalibrationKind.dynamicSquats)
                }.pickerStyle(.segmented).disabled(model.busy)
            }
            Section(kind.title) {
                if kind == .staticPose {
                    Text("受试者保持 N-pose，双臂自然下垂。站稳后点开始，倒计时3秒后保持不动5秒，随后自动保存。")
                } else {
                    Text("点开始，倒计时结束后完成两个深蹲，再点下方“已完成两个深蹲，结束并保存”。")
                }
                Text("每项独立保存，可重新采集。最近一次完成且数据质量通过后，该项显示完成。").font(.footnote).foregroundStyle(.secondary)
                Text(model.engineState.message).font(.footnote)
            }
            if !model.calibrationPreflight.ready && !model.engineState.recording {
                Section("采前检查") {
                    ForEach(model.calibrationPreflight.blockers) { item in
                        VStack(alignment:.leading) { Text(item.title); Text(item.detail).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            Section("本项采集记录") {
                if rows.isEmpty { Text("尚无记录").foregroundStyle(.secondary) }
                ForEach(rows) { trial in
                    NavigationLink { RecordView(trial:trial) } label: {
                        VStack(alignment:.leading) {
                            Text(trial.status == "calibration_complete" && trial.qualityPassed ? "采集完成" : "未完成 / 待重采")
                            Text(trial.id).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }.navigationTitle("受试者校正采集")
         .safeAreaInset(edge:.bottom) {
             CaptureDock(title:rows.isEmpty ? "开始本项采集" : "重新采集本项",enabled:model.calibrationPreflight.ready,identifier:"subjectCalibrationStart") { confirm = true }
         }
         .confirmationDialog(kind == .staticPose ? "确认 N-pose 已站稳" : "确认已准备好做两个深蹲",isPresented:$confirm,titleVisibility:.visible) {
             Button(kind == .staticPose ? "已站稳，开始倒计时" : "已准备好，开始倒计时") { model.startCalibration(kind) }
         } message: {
             Text(kind == .staticPose ? "倒计时3秒后保持不动5秒。": "倒计时3秒后开始动作，做完两个深蹲后手动结束。")
         }
    }
}

