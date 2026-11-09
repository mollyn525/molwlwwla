import SwiftUI

struct CaptureDock: View {
    @EnvironmentObject var model: AppModel
    let title: String, enabled: Bool, identifier: String
    let start: () -> Void
    var body: some View {
        VStack(spacing:8) {
            if model.engineState.recording || model.engineState.saving { RecordingControls() }
            else {
                Button(action:start) {
                    Text(title).frame(maxWidth:.infinity,minHeight:24).multilineTextAlignment(.center)
                }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!enabled)
                    .accessibilityIdentifier(identifier)
            }
        }
        .frame(maxWidth:.infinity)
        .padding(.horizontal,20).padding(.vertical,10)
        .background(.regularMaterial)
    }
}

