import Foundation
import CryptoKit

// Compile together with Sources/Core, either from baseline or current checkout.
// All inputs are generated; no participant data is used by CI.
let args = CommandLine.arguments
let root = URL(fileURLWithPath:args[1],isDirectory:true)
let recordCount = Int(args[2])!, rowsPerRecord = Int(args[3])!, paddingMB = Int(args[4])!
let fm = FileManager.default
try fm.createDirectory(at:root,withIntermediateDirectories:true)
let sessions = root.appendingPathComponent("sessions",isDirectory:true)
try fm.createDirectory(at:sessions,withIntermediateDirectories:true)
var trials: [Trial] = []
let inertial = WitFrame(try WitProtocol.unhex("5561000000000008000000000000000000000000"))
let magnetic = WitFrame(try WitProtocol.unhex("55713A0096002C01C20100000000000000000000"))
var expected: [String:String] = [:]
func digest(_ url: URL) throws -> String {
    let f = try FileHandle(forReadingFrom:url); defer { try? f.close() }; var sha = SHA256()
    while try autoreleasepool(invoking:{ () throws -> Bool in
        guard let chunk = try f.read(upToCount:256*1024), !chunk.isEmpty else { return false }
        sha.update(data:chunk); return true
    }) {}
    return sha.finalize().map { String(format:"%02x",$0) }.joined()
}
try autoreleasepool {
    for i in 0..<recordCount {
        let id = "SYNTHETIC-\(i)", folder = sessions.appendingPathComponent(id,isDirectory:true)
        try fm.createDirectory(at:folder,withIntermediateDirectories:false)
        try JSONFile.write(["diagnostic":true,"recorded_ms":1000,"time_zone_offset_seconds":0,"devices":[["address":"sensor","name":"SYNTHETIC","settings":["114":["words":[6]]]]]],to:folder.appendingPathComponent("metadata.json"))
        try JSONFile.write(["diagnostic":true,"action_start_ns":1],to:folder.appendingPathComponent("summary.json"))
        for name in ["relative_pose.csv","events.jsonl"] { try Data().write(to:folder.appendingPathComponent(name)) }
        let samples = folder.appendingPathComponent("samples.csv")
        fm.createFile(atPath:samples.path,contents:Data(SessionWriter.header.utf8))
        let output = try FileHandle(forWritingTo:samples); try output.seekToEnd()
        let line = magnetic.csv(identifier:"sensor",ns:1,wall:1000,inertialVerified:true)+inertial.csv(identifier:"sensor",ns:2,wall:1001,inertialVerified:true)
        let block = Data(String(repeating:line,count:500).utf8)
        precondition(rowsPerRecord % 500 == 0)
        for _ in 0..<(rowsPerRecord/500) { try output.write(contentsOf:block) }
        try output.close()
        let raw = folder.appendingPathComponent("notifications.jsonl")
        fm.createFile(atPath:raw.path,contents:nil)
        let rawHandle = try FileHandle(forWritingTo:raw)
        let padding = Data(String(repeating:"{}\n",count:349525).utf8)
        for _ in 0..<paddingMB { try rawHandle.write(contentsOf:padding) }; try rawHandle.close()
        for name in ArchiveExporter.required { expected[id+"/"+name] = try digest(folder.appendingPathComponent(name)) }
        trials.append(Trial(id:id,assignment:nil,diagnostic:true,quality:false,normal:true,status:"synthetic"))
    }
}
let destination = root.appendingPathComponent("synthetic-export.zip"), start = Date()
// Same long-lived GCD work item as the iPhone app: the old exporter has no
// inner autorelease pools, so its temporary Foundation objects accumulate.
let done = DispatchSemaphore(value:0)
var failure: Error?
DispatchQueue.global(qos:.utility).async {
    do {
        try ArchiveExporter.export(sessions:sessions,trials:trials,destination:destination,cancel:ExportCancellation()) { _,_ in }
    } catch { failure = error }
    done.signal()
}
done.wait()
if let failure { throw failure }
for (relative,hash) in expected {
    let actual = try digest(sessions.appendingPathComponent(relative)); precondition(actual == hash,"Source bytes changed")
}
let attributes = try fm.attributesOfItem(atPath:destination.path)
let report: [String:Any] = ["records":recordCount,"inertial_rows":recordCount*rowsPerRecord,"zip_bytes":attributes[.size]!,"seconds":Date().timeIntervalSince(start),"source_hashes_preserved":true]
try JSONFile.write(report,to:root.appendingPathComponent("result.json"))
print(String(data:try JSONFile.bytes(report),encoding:.utf8)!)
