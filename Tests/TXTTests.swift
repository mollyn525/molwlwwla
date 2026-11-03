import XCTest
import Foundation
@testable import BaduanjinCore

final class TXTTests: XCTestCase {
    private func frame(_ reg: Int, _ values: [Int]) -> WitFrame {
        var bytes: [UInt8] = reg == -1 ? [0x55,0x61]:[0x55,0x71,UInt8(reg),0]
        for i in 0..<(reg == -1 ? 9:8) { let word = UInt16(bitPattern:Int16(i < values.count ? values[i]:0)); bytes += [UInt8(word & 255),UInt8(word >> 8)] }
        return WitFrame(Data(bytes))
    }
    func testTXTMatches27ColumnsAndRetainsCachedValueSourceTimes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let files = try StudyFiles(root:root)
        let meta: [String:Any] = ["recorded_ms":1000,"time_zone_offset_seconds":28800,"devices":[["address":"sensor-a","name":"WT-test","firmware":"10080.1.21","settings":["114":["words":[6]]]]]]
        let writer = try SessionWriter(root:files.sessions,metadata:meta)
        writer.frame(id:"sensor-a",ns:100_000_000,wall:1000,frame:frame(0x3a,[-150,300,450]),verified:true)
        writer.frame(id:"sensor-a",ns:200_000_000,wall:1100,frame:frame(0x51,[32767,0,0,0]),verified:true)
        writer.frame(id:"sensor-a",ns:300_000_000,wall:1200,frame:frame(-1,[2048,-1024,0,16384,0,-16384,16384,0,-16384]),verified:true)
        writer.frame(id:"sensor-a",ns:900_000_000,wall:1800,frame:frame(-1,[2048,0,0,0,0,0,0,0,0]),verified:true)
        writer.frame(id:"sensor-b",ns:950_000_000,wall:1850,frame:frame(-1,[0,0,2048]),verified:true)
        writer.frame(id:"sensor-a",ns:970_000_000,wall:1870,frame:frame(-1,[0,0,2048]),verified:false)
        let done = expectation(description:"saved")
        writer.close(summary:["action_start_ns":400_000_000,"diagnostic":true,"accepted":false]) { _ in done.fulfill() }
        wait(for:[done],timeout:10)
        let input = writer.directory.appendingPathComponent("samples.csv"), before = try Data(contentsOf:input)
        let artifacts = ProcessInfo.processInfo.environment["IMU_TEST_ARTIFACT_DIR"].map { URL(fileURLWithPath:$0) } ?? root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at:artifacts,withIntermediateDirectories:true)
        let text = artifacts.appendingPathComponent("compatibility.txt"), times = artifacts.appendingPathComponent("compatibility-source-times.csv")
        let info = try VendorTXT.write(session:writer.directory,text:text,sources:times,cancel:ExportCancellation())
        try JSONFile.write(info,to:artifacts.appendingPathComponent("compatibility-format.json"))
        XCTAssertEqual(VendorTXT.fileName(metadata:meta),"19700101080001.txt")
        let lines = try String(contentsOf:text,encoding:.utf8).components(separatedBy:"\r\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count,4); XCTAssertEqual(lines[0].components(separatedBy:"\t"),VendorTXT.columns)
        let first = lines[1].components(separatedBy:"\t"), second = lines[2].components(separatedBy:"\t"), other = lines[3].components(separatedBy:"\t")
        XCTAssertEqual(first.count,27); XCTAssertEqual(first[0],"1970-01-01T08:00:01.200")
        XCTAssertEqual(first[1],"WT-test(sensor-a)"); XCTAssertEqual(Array(first[2...10]),["1.000","-0.500","0.000","1000.000","0.000","-1000.000","90.00","0.00","-90.00"])
        XCTAssertEqual(Array(first[11...13]),["-1.000","2.000","3.000"])
        XCTAssertEqual(first[20],"0.99997"); XCTAssertEqual(second[20],first[20]); XCTAssertEqual(other[20],"null")
        XCTAssertEqual(first[24],"null"); XCTAssertEqual(first[26],"null")
        let provenance = try String(contentsOf:times,encoding:.utf8).components(separatedBy:"\r\n").filter { !$0.isEmpty }
        XCTAssertEqual(provenance.count,4)
        let secondSource = provenance[2].components(separatedBy:",")
        XCTAssertEqual(secondSource[5],"100000000"); XCTAssertEqual(secondSource[6],"200000000")
        XCTAssertEqual(secondSource[9],"true"); XCTAssertEqual(secondSource[10],"true"); XCTAssertEqual(secondSource[11],"action")
        XCTAssertEqual(info["unverified_inertial_frames_omitted"] as? Int,1)
        XCTAssertEqual(try Data(contentsOf:input),before)
        let cancelled = ExportCancellation(); cancelled.cancel()
        XCTAssertThrowsError(try VendorTXT.write(session:writer.directory,text:root.appendingPathComponent("cancel.txt"),sources:root.appendingPathComponent("cancel.csv"),cancel:cancelled))
    }
    func testMagneticUnitsRequireKnownType() {
        XCTAssertNil(VendorTXT.magneticScale(nil)); XCTAssertNil(VendorTXT.magneticScale(99))
        XCTAssertEqual(VendorTXT.magneticScale(6)!,1.0/150,accuracy:1e-12)
        XCTAssertEqual(VendorTXT.magneticScale(2),0.15); XCTAssertEqual(VendorTXT.magneticScale(3),0.013)
        XCTAssertEqual(VendorTXT.columns.count,27)
    }
}
