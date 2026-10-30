import SwiftUI

@main struct BaduanjinApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model).tint(Color(red:0.03,green:0.50,blue:0.55))
                .onChange(of:phase) { _, phase in model.engine.active(phase == .active) }
        }
    }
}
