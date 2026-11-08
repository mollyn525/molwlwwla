#if DEBUG
import Foundation
import BaduanjinCore

extension BluetoothEngine {
    func prepareLifecycleFixture(_ sessions: URL) {
        work.async { self.lifecycleTestRoot = sessions }
    }
    func tickLifecycleFixture(_ now: UInt64) {
        if let sessions = lifecycleTestRoot, lifecycle.interactive, writer == nil {
            lifecycleTestRoot = nil
            do {
                let recorder = try SessionWriter(root:sessions,metadata:["diagnostic":true,"ui_synthetic_only":true])
                writer = recorder; lifecycleTestID = recorder.directory.lastPathComponent
                recordingDiagnostic = true; targets = []; recordingCalibration = nil
                startNS = now; actionNS = 0; endNS = 0; fault = false
            } catch { message = error.localizedDescription }
        }
        guard lifecycleTestID != nil, writer != nil, lifecycle.acquisitionAllowed, now-lifecycleTestLast >= 50_000_000 else { return }
        lifecycleTestLast = now; lifecycleTestTicks += 1
        if lifecycle.phase == .inactive { lifecycleInactiveTicks += 1 }
        writer?.event(ns:now,message:"UI_SYNTHETIC_TICK")
    }
    var lifecycleFixtureProbe: String {
        guard let id = lifecycleTestID else { return "" }
        return "\(id)|\(lifecycleTestTicks)|\(lifecycleInactiveTicks)|\(lifecycle.phase.rawValue)|\(writer != nil ? 1:0)"
    }
}
#endif

