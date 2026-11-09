import SwiftUI
import UIKit
import BaduanjinCore

enum InterfaceSpacing {
    static let tight: CGFloat = 4
    static let related: CGFloat = 8
    static let row: CGFloat = 12
    static let section: CGFloat = 20
}
enum InterfaceColor {
    static let tint = Color(uiColor:UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red:0.35,green:0.84,blue:0.81,alpha:1)
            : UIColor(red:0.03,green:0.46,blue:0.50,alpha:1)
    })
}
struct TaskLink<Destination: View>: View {
    let title: String, detail: String, symbol: String
    let destination: Destination
    init(_ title: String, detail: String, symbol: String, @ViewBuilder destination: () -> Destination) {
        self.title = title; self.detail = detail; self.symbol = symbol; self.destination = destination()
    }
    var body: some View {
        NavigationLink { destination } label: {
            HStack(alignment:.center,spacing:InterfaceSpacing.row) {
                Image(systemName:symbol).font(.body).foregroundStyle(.tint).frame(width:24).accessibilityHidden(true)
                VStack(alignment:.leading,spacing:InterfaceSpacing.tight) {
                    Text(title).font(.body.weight(.medium)).foregroundStyle(.primary)
                    if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }
                }
                Spacer(minLength:0)
            }.frame(minHeight:44).padding(.vertical,InterfaceSpacing.tight)
        }.accessibilityLabel(title).accessibilityHint(detail)
    }
}
struct CurrentTaskSummary: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment:.leading,spacing:InterfaceSpacing.related) {
            Text(model.study.map { "\($0.subject) · \(model.book.total)/120条合格" } ?? "尚未建立任务")
                .font(.headline).fixedSize(horizontal:false,vertical:true)
            if model.study != nil {
                ProgressView(value:Double(model.book.total),total:120)
                    .accessibilityLabel("正式采集进度").accessibilityValue("\(model.book.total) / 120")
            }
        }.padding(.vertical,InterfaceSpacing.tight)
    }
}
#if DEBUG
/// Visual review only. These switches are absent from the Release binary.
struct ReviewAppearance: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        let arguments = ProcessInfo.processInfo.arguments
        let scheme: ColorScheme? = arguments.contains("--ui-dark-appearance") ? .dark : nil
        if arguments.contains("--ui-accessibility-type") {
            content.preferredColorScheme(scheme).dynamicTypeSize(.accessibility2)
        } else {
            content.preferredColorScheme(scheme)
        }
    }
}
#endif

