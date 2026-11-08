import SwiftUI
import BaduanjinCore

@main struct BaduanjinApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model).tint(Color(red:0.03,green:0.50,blue:0.55))
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
