import XCTest
@testable import BaduanjinCore

final class LiveMonitorTests: XCTestCase {
    func testMagneticScaleAndNorm() throws {
        let factors: [Int:Double] = [1:0.6,2:0.15,3:0.013,4:0.15,5:0.098,6:1/150,7:1/120,8:0.02,111:100/1024]
        for (type,scale) in factors {
            let reading = try FieldReading(raw:[30,-40,0],type:type)
            XCTAssertEqual(reading.axes[1],-scale,accuracy:1e-10)
            XCTAssertEqual(reading.norm,50*scale/40,accuracy:1e-10)
        }
        let f = try FieldReading(raw:[3600,-4800,0],type:6)
        XCTAssertEqual(f.plotted, [0.6,-0.8,0,1])
        for raw in [[0.0,0,0],[-32768,1,1],[1,32767,1]] { XCTAssertThrowsError(try FieldReading(raw:raw,type:6)) }
        XCTAssertThrowsError(try FieldReading(raw:[1,2,3],type:99))
    }
    func testFrameWindowAndReset() throws {
        var m = LiveMonitor(); m.setType(6)
        for i in 0..<185 { m.magnetic(UInt64(i/2),[Double(i),1,0]) }
        XCTAssertEqual(m.magPoints.count,180); XCTAssertEqual(m.magPoints.first?.ns,2)
        m.setType(nil); XCTAssertNil(m.field); XCTAssertTrue(m.magPoints.isEmpty)
        let a = Double.pi/180
        let q = PoseMonitor.multiply([cos(40*a),0,0,sin(40*a)],PoseMonitor.multiply([cos(15*a),0,sin(15*a),0],[cos(10*a),sin(10*a),0,0]))
        for i in 0...150 { m.quaternion(UInt64(i)*20_000_000,i%2 == 0 ? q : q.map { -$0 }) }
        var pose = m.pose; try pose.resetHeading(now:3*secondNS,confirmed:0); m.changeHeading(pose)
        XCTAssertTrue(m.anglePoints.isEmpty)
        m.quaternion(3*secondNS+1,q)
        let adjusted = try XCTUnwrap(m.anglePoints.last?.values)
        for (value,want) in zip(adjusted,[20.0,30,0]) { XCTAssertEqual(value,want,accuracy:1e-7) }
        let row = m.row(id:"synthetic",ns:3*secondNS+1,magnetic:false)
        XCTAssertEqual((row["rpy_raw_deg"] as? [Double])?[2] ?? -1,80,accuracy:1e-7)
        m.pose.revert()
        XCTAssertEqual(try PoseMonitor.euler(m.pose.adjusted(q))[2],80,accuracy:1e-7)
        XCTAssertNil(m.pose.snapshot(now:4*secondNS,connected:true).q)
    }
    func testManualCalibrationSequences() {
        XCTAssertEqual(WitMagSequence.start.map(WitProtocol.hex),["FFAA6988B5","FFAA010700"])
        XCTAssertEqual(WitMagSequence.finish.map(WitProtocol.hex),["FFAA6988B5","FFAA010000","FFAA000000"])
        XCTAssertEqual(WitMagSequence.intervalNS,100_000_000)
        XCTAssertThrowsError(try WitProtocol.command(1,7))
    }
}

