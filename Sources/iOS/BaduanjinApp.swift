import SwiftUI
import BaduanjinCore

@main struct BaduanjinApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model).tint(InterfaceColor.tint)
                #if DEBUG
                .modifier(ReviewAppearance())
                .overlay(alignment:.bottomLeading) {
                    if ProcessInfo.processInfo.arguments.contains("--monitor-touch-probe") { MonitorInputProbePanel() }
                }
                #endif
                .onChange(of:phase,initial:true) { _, phase in
                    switch phase {
                    case .active: model.engine.scene(.active)
                    case .inactive: model.engine.scene(.inactive)
                    case .background: model.engine.scene(.background)
                    @unknown default: model.engine.scene(.background)
                    }
                }
        }
    }
}
