import SwiftUI
import BaduanjinCore

struct BodyMapView: View {
    @EnvironmentObject var model: AppModel
    @Binding var selectedRole: Int?
    private let points: [(CGFloat,CGFloat)] = [(0.5,0.10),(0.5,0.28),(0.5,0.46),(0.70,0.27),(0.30,0.27),(0.77,0.40),(0.23,0.40),(0.84,0.53),(0.16,0.53),(0.60,0.60),(0.40,0.60),(0.62,0.77),(0.38,0.77),(0.65,0.93),(0.35,0.93)]
    var body: some View {
        TimelineView(.periodic(from:.now,by:1)) { _ in
            GeometryReader { geo in
                ZStack {
                    Canvas { context,size in
                        var path = Path()
                        for chain in [[0,1,2],[1,3,5,7],[1,4,6,8],[2,9,11,13],[2,10,12,14]] {
                            for (n,i) in chain.enumerated() { let p = CGPoint(x:points[i].0*size.width,y:points[i].1*size.height); if n == 0 { path.move(to:p) } else { path.addLine(to:p) } }
                        }
                        context.stroke(path,with:.color(.teal.opacity(0.22)),style:StrokeStyle(lineWidth:18,lineCap:.round,lineJoin:.round))
                    }
                    ForEach(Array(BodyRole.all.enumerated()),id:\.element.id) { index,role in
                        Button { selectedRole = index } label: {
                            VStack(spacing:2) {
                                ZStack { Circle().fill(color(role)).frame(width:27,height:27); if attention(role) { Text("!").font(.headline.bold()).foregroundStyle(.white) } }
                                Text(role.name).font(.system(size:11,weight:.semibold)).foregroundStyle(.primary).padding(.horizontal,3).background(Color(.systemBackground).opacity(0.9))
                            }.frame(width:64,height:48)
                        }.buttonStyle(.plain).frame(width:64,height:48).position(x:points[index].0*geo.size.width,y:points[index].1*geo.size.height)
                         .accessibilityLabel(role.name+" · "+(model.device(role)?.status ?? "未连接"))
                         .accessibilityIdentifier("bodyRole_"+role.id)
                    }
                }
            }
        }
    }
    private var fresh: Bool { let now = BluetoothEngine.now(); return model.engineState.timestamp > 0 && now >= model.engineState.timestamp && now-model.engineState.timestamp < secondNS }
    private func attention(_ role: BodyRole) -> Bool { !fresh || !(model.device(role)?.issues.isEmpty ?? true) || model.roster[role.id]?.wearConfirmed == false }
    private func color(_ role: BodyRole) -> Color {
        guard model.roster[role.id] != nil else { return .gray }
        guard fresh else { return .orange }
        guard let d = model.device(role) else { return .gray }
        guard d.connected else { return d.wanted ? .red:.gray }
        if !d.initialized || d.maintenance || model.engineState.passive { return .blue }
        if d.ages.prefix(2).contains(where: { ($0 ?? 2000) >= 2000 }) { return .red }
        if !QualityPolicy.current.recentDataHealthy(d.ages) || !QualityPolicy.current.recentRatesPass(d.hz) { return .orange }
        return .green
    }
}
struct LiveTrendView: View {
    let samples: [[Double]], quaternion: Bool
    var body: some View {
        VStack(spacing:4) {
            Canvas { context,size in
                let dimensions = quaternion ? 4:3
                guard samples.count > 1 else { return }
                let values = samples.flatMap { $0 }.filter(\.isFinite)
                let low = quaternion ? -1:min(0,values.min() ?? -1), high = quaternion ? 1:max(0,values.max() ?? 1)
                let span = max(0.01,high-low), colors: [Color] = [.red,.green,.blue,.purple]
                for k in 0..<dimensions {
                    var path = Path()
                    for (i,s) in samples.enumerated() where s.count == dimensions {
                        let point = CGPoint(x:Double(i)*size.width/Double(samples.count-1),y:size.height*(0.95-0.9*(s[k]-low)/span))
                        if i == 0 { path.move(to:point) } else { path.addLine(to:point) }
                    }
                    context.stroke(path,with:.color(colors[k]),lineWidth:1.5)
                }
            }
            Text(quaternion ? "红w · 绿x · 蓝y · 紫z（−1到1）":"红x · 绿y · 蓝z（自动纵轴）").font(.caption2).foregroundStyle(.secondary)
        }.accessibilityLabel("最近实时数据趋势")
    }
}
