import SwiftUI
import UIKit
import BaduanjinCore

struct ExportFilesView: View {
    @EnvironmentObject var model: AppModel
    @State private var files: [ExportedFile] = []
    @State private var saveFile: ExportedFile?
    @State private var pendingDelete: ExportedFile?
    var body: some View {
        List {
            Section {
                Text("打包文件保存在本机，分享后仍会保留。可再次分享，或另存一份到“文件”App。").font(.subheadline)
                Text("\(files.filter(\.complete).count)个可用文件 · 共 \(size(files.reduce(0) { $0 + $1.bytes }))").foregroundStyle(.secondary)
                Button("刷新已导出文件",action:refresh).accessibilityIdentifier("refreshExports")
            }
            if files.isEmpty {
                ContentUnavailableView("尚无导出文件",systemImage:"archivebox",description:Text("在记录页完成导出后，会自动显示在这里。"))
            }
            ForEach(files) { file in
                Section {
                    VStack(alignment:.leading,spacing:6) {
                        Text(file.id).font(.headline).textSelection(.enabled)
                        Text(size(file.bytes)+" · "+file.modified.formatted(date:.abbreviated,time:.shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                    if file.complete {
                        Button { model.shareURL = file.url } label: { Label("再次分享",systemImage:"square.and.arrow.up") }
                            .accessibilityIdentifier("shareExport-"+file.id)
                        Button { saveFile = file } label: { Label("存储到“文件”",systemImage:"folder") }
                            .accessibilityIdentifier("saveExport-"+file.id)
                    } else {
                        Label("未完成的打包文件",systemImage:"exclamationmark.circle").foregroundStyle(.orange)
                        Text("这份文件不能作为完整数据包使用，原文件仍保留。请从采集记录重新导出。").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("删除打包文件",role:.destructive) { pendingDelete = file }
                        .disabled(model.busy).accessibilityIdentifier("deleteExport-"+file.id)
                }
            }
        }.navigationTitle("已导出文件").buttonStyle(.borderless)
            .task { refresh() }
            .sheet(item:$saveFile) { file in SaveExportCopy(url:file.url) }
            .alert("删除打包文件？",isPresented:Binding(get:{pendingDelete != nil},set:{ if !$0 { pendingDelete = nil } }),presenting:pendingDelete) { file in
                Button("删除此文件",role:.destructive) { remove(file) }
                Button("取消",role:.cancel) {}
            } message: { file in
                Text("\(file.id)\n\(size(file.bytes))\n仅删除这份导出副本，原始采集、受试者和校正记录仍保留，可重新导出。删除的副本无法在此恢复。")
            }
    }
    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount:bytes,countStyle:.file) }
    private func refresh() {
        guard let root = model.files?.root else { return }
        do { files = try ExportFiles.list(root:root) } catch { model.error = "读取已导出文件失败：\(error.localizedDescription)" }
    }
    private func remove(_ file: ExportedFile) {
        guard !model.busy, let root = model.files?.root else { return }
        do { try ExportFiles.delete(id:file.id,root:root); refresh() }
        catch { model.error = "删除打包文件失败：\(error.localizedDescription)" }
    }
}

/// The system copies an existing URL; never load an archive into a FileDocument,
/// and never use the move variant of the document picker.
struct SaveExportCopy: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting:[url],asCopy:true)
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController,context: Context) {}
}
