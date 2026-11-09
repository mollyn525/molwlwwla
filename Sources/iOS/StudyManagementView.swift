import SwiftUI
import BaduanjinCore

struct StudyManagementView: View {
    @EnvironmentObject var model: AppModel
    @State private var deleting: Study?
    @State private var purging: DeletedStudy?
    @State private var confirmTrash = false
    @State private var confirmPurge = false
    @State private var typedSubject = ""
    var body: some View {
        List {
            Section("受试者任务") {
                if model.studies.isEmpty { Text("暂无受试者任务").foregroundStyle(.secondary) }
                ForEach(model.studies) { study in
                    HStack {
                        Button { model.activate(study.id) } label: {
                            VStack(alignment:.leading,spacing:4) {
                                Text(study.subject).font(.headline)
                                Text(Date(timeIntervalSince1970:Double(study.created_ms)/1000),format:.dateTime.year().month().day().hour().minute()).font(.caption)
                                Text(model.study?.id == study.id ? "当前任务" : "点此继续此任务").font(.caption)
                            }.frame(maxWidth:.infinity,alignment:.leading)
                        }.accessibilityIdentifier("continueSubject_"+study.subject)
                        Button(role:.destructive) { deleting = study; confirmTrash = true } label: {
                            Image(systemName:"trash").padding(10)
                        }.accessibilityLabel("删除受试者 "+study.subject).accessibilityIdentifier("trashSubject_"+study.subject)
                    }.disabled(model.busy)
                }
            }
            Section("最近删除") {
                Text("移入最近删除后，受试者及关联记录不再显示在采集和导出列表；文件仍保留，可以恢复。").font(.footnote)
                if model.deletedStudies.isEmpty { Text("最近删除为空").foregroundStyle(.secondary) }
                ForEach(model.deletedStudies) { row in
                    VStack(alignment:.leading,spacing:8) {
                        Text(row.study.subject).font(.headline)
                        Text("\(row.sessionIDs.count) 份关联记录 · "+Date(timeIntervalSince1970:Double(row.deletedMS)/1000).formatted(date:.numeric,time:.shortened)).font(.caption)
                        if row.purging { Text("彻底删除未完成，请继续；已删除部分不能恢复。").font(.caption).foregroundStyle(.orange) }
                        HStack {
                            Button("恢复") { model.restoreStudy(row.id) }.disabled(row.purging)
                                .accessibilityIdentifier("restoreSubject_"+row.study.subject)
                            Spacer()
                            Button(row.purging ? "继续彻底删除" : "彻底删除",role:.destructive) {
                                purging = row; typedSubject = ""; confirmPurge = true
                            }.accessibilityIdentifier("purgeSubject_"+row.study.subject)
                        }
                    }.disabled(model.busy)
                }
                Text("彻底删除会释放关联原始记录占用的空间。已生成或分享的导出文件、共享操作日志不会随之删除。").font(.footnote).foregroundStyle(.secondary)
            }
        }.buttonStyle(.borderless).navigationTitle("受试者管理").navigationBarTitleDisplayMode(.inline)
         .confirmationDialog("移入最近删除？",isPresented:$confirmTrash,titleVisibility:.visible) {
             if let deleting { Button("移入最近删除",role:.destructive) { model.trashStudy(deleting.id) } }
         } message: {
             Text("将“\(deleting?.subject ?? "")”及其正式采集、补录、静态／动态校正和关联诊断记录移入最近删除。可恢复；其他受试者不受影响。")
         }
         .alert("彻底删除受试者记录？",isPresented:$confirmPurge) {
             TextField("输入受试者编号",text:$typedSubject).textInputAutocapitalization(.never)
             Button("彻底删除",role:.destructive) { if let purging { model.purgeStudy(purging.id) } }
                 .disabled(typedSubject != purging?.study.subject || model.busy)
             Button("取消",role:.cancel) {}
         } message: {
             Text("输入“\(purging?.study.subject ?? "")”确认。全部关联原始记录将永久删除，无法恢复；已有导出文件不受影响。")
         }
    }
}

