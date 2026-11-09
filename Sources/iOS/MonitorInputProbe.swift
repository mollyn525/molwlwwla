#if DEBUG
import SwiftUI
import UIKit

/// Opt-in simulator diagnostics. No hardware commands or persistent data changes.
@MainActor private final class MonitorInputProbe: NSObject, ObservableObject {
    @Published private(set) var report = "ready"
    private var history: [String] = []
    private weak var watched: UISegmentedControl?
    private func views(_ root: UIView) -> [UIView] {
        [root] + root.subviews.flatMap { views($0) }
    }
    private func controls() -> [UISegmentedControl] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }.flatMap { views($0) }.compactMap { $0 as? UISegmentedControl }
            .filter { control in
                guard let window = control.window else { return false }
                return !control.isHidden && control.alpha > 0.05 && control.convert(control.bounds,to:window).intersects(window.bounds)
            }
    }
    private func target() -> UISegmentedControl? {
        let all = controls()
        return all.first { $0.titleForSegment(at:0) == "Mag Norm" } ?? all.first { $0.numberOfSegments == 2 }
    }
    private func append(_ value: String) {
        history.append(value)
        if history.count > 20 { history.removeFirst(history.count-20) }
        report = history.joined(separator:" | ")
        print("MONITOR_INPUT_PROBE "+value)
    }
    @objc private func changed(_ sender: UISegmentedControl) {
        append("valueChanged native=\(sender.selectedSegmentIndex) id=\(ObjectIdentifier(sender))")
    }
    func inspect() {
        guard let control = target(), let window = control.window else {
            let nodes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }.flatMap { views($0) }
                .filter { $0 is UIControl }.map { String(describing:type(of:$0))+" "+String(describing:$0.accessibilityLabel) }
            append("NO_NATIVE_CONTROL count=\(controls().count) controls=\(nodes)"); return
        }
        if watched !== control {
            watched = control
            control.addTarget(self,action:#selector(changed(_:)),for:.valueChanged)
            append("observe id=\(ObjectIdentifier(control))")
        }
        let point = control.convert(CGPoint(x:control.bounds.width*0.75,y:control.bounds.height*0.5),to:window)
        var chain: [String] = [], hit = window.hitTest(point,with:nil)
        for _ in 0..<8 {
            guard let view = hit else { break }
            chain.append(String(describing:type(of:view))); hit = view.superview
        }
        let titles = (0..<control.numberOfSegments).map { control.titleForSegment(at:$0) ?? "<nil>" }
        let targets = control.allTargets.map { String(describing:type(of:$0.base)) }
        append("sample native=\(control.selectedSegmentIndex) enabled=\(control.isEnabled) interactive=\(control.isUserInteractionEnabled) rect=\(control.convert(control.bounds,to:window)) titles=\(titles) hit=\(chain) targets=\(targets)")
    }
    func sendDiagnosticValueEvent() {
        guard let control = target() else { append("NO_CONTROL_FOR_EVENT"); return }
        append("PROGRAMMATIC_DIAGNOSTIC_ONLY")
        control.selectedSegmentIndex = 1
        control.sendActions(for:.valueChanged)
    }
}
struct MonitorInputProbePanel: View {
    @StateObject private var probe = MonitorInputProbe()
    var body: some View {
        VStack(spacing:2) {
            HStack {
                Button("Inspect touch") { probe.inspect() }.accessibilityIdentifier("monitorProbeInspect")
                Button("Diagnostic event") { probe.sendDiagnosticValueEvent() }.accessibilityIdentifier("monitorProbeEvent")
            }.buttonStyle(.bordered).font(.caption)
            Text(probe.report).font(.system(size:6)).lineLimit(1).accessibilityIdentifier("monitorProbeReport")
        }.padding(4).background(Color.white).foregroundStyle(.black)
    }
}
#endif

