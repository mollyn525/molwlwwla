import Foundation

/// Derived compatibility table. Cached auxiliary values are never reception counts.
public enum VendorTXT {
    public static let columns = ["时间","设备名称","加速度X(g)","加速度Y(g)","加速度Z(g)","角速度X(°/s)","角速度Y(°/s)","角速度Z(°/s)","角度X(°)","角度Y(°)","角度Z(°)","磁场X(uT)","磁场Y(uT)","磁场Z(uT)","位移X(mm)","位移Y(mm)","位移Z(mm)","速度X(mm/s)","速度Y(mm/s)","速度Z(mm/s)","四元数0()","四元数1()","四元数2()","四元数3()","温度(°C)","版本号()","电量(%)"]
    public static let sourceHeader = "txt_row,elapsed_ns,wall_ms,address,inertial_ns,magnetic_ns,quaternion_ns,magnetic_age_ms,quaternion_age_ms,magnetic_stale,quaternion_stale,phase\r\n"
    private struct State {
        var cells = Array(repeating:"null",count:27)
        var mag: [Int]?, magNS: UInt64?, qNS: UInt64?, magType: Int?
    }
    public static func magneticScale(_ type: Int?) -> Double? {
        switch type { case 2: return 0.15; case 3: return 0.013; case 4: return 0.058; case 5: return 0.098; case 6: return 1.0/150; case 7: return 0.02; default: return nil }
    }
    private static func clean(_ s: String) -> String { s.replacingOccurrences(of:"\t",with:" ").replacingOccurrences(of:"\r",with:" ").replacingOccurrences(of:"\n",with:" ") }
    private static func fixed(_ x: Double, _ digits: Int) -> String { String(format:"%.*f",locale:Locale(identifier:"en_US_POSIX"),digits,x) }
    private static func formatter(_ zone: TimeZone, _ pattern: String) -> DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier:"en_US_POSIX"); f.calendar = Calendar(identifier:.gregorian); f.timeZone = zone; f.dateFormat = pattern; return f
    }
    public static func fileName(metadata: [String:Any]) -> String {
        guard let ms = (metadata["recorded_ms"] as? NSNumber)?.int64Value, ms >= 0 else { return "recording.txt" }
        return formatter(zone(metadata),"yyyyMMddHHmmss").string(from:Date(timeIntervalSince1970:Double(ms)/1000))+".txt"
    }
    private static func zone(_ metadata: [String:Any]) -> TimeZone {
        if let offset = metadata["time_zone_offset_seconds"] as? Int, let zone = TimeZone(secondsFromGMT:offset) { return zone }
        return .current
    }
    private static func lines(_ file: URL, cancel: ExportCancellation, visit: (String) throws -> Void) throws {
        let input = try FileHandle(forReadingFrom:file); defer { try? input.close() }
        var pending = Data()
        while let chunk = try input.read(upToCount:64*1024), !chunk.isEmpty {
            try cancel.check(); pending.append(chunk)
            while let end = pending.firstIndex(of:10) {
                guard let text = String(data:pending[..<end],encoding:.utf8) else { throw LabError.invalid("TXT来源CSV含无效UTF-8") }
                try visit(text.hasSuffix("\r") ? String(text.dropLast()):text); pending.removeSubrange(...end)
            }
            guard pending.count < 1024*1024 else { throw LabError.invalid("TXT来源CSV单行异常过长") }
        }
        if !pending.isEmpty {
            guard let text = String(data:pending,encoding:.utf8) else { throw LabError.invalid("TXT来源CSV尾行编码无效") }; try visit(text)
        }
    }
    public static func write(session: URL, text: URL, sources: URL, cancel: ExportCancellation) throws -> [String:Any] {
        let metadata = try JSONFile.read(session.appendingPathComponent("metadata.json"))
        let summary = (try? JSONFile.read(session.appendingPathComponent("summary.json"))) ?? [:]
        let action = (summary["action_start_ns"] as? NSNumber)?.uint64Value ?? 0
        let devices = metadata["devices"] as? [[String:Any]] ?? []
        var states: [String:State] = [:]
        for d in devices {
            guard let id = d["address"] as? String else { continue }; var state = State()
            state.cells[1] = clean((d["name"] as? String ?? "WT")+"("+id+")")
            if let firmware = d["firmware"] as? String, !firmware.isEmpty, firmware != "未知" { state.cells[25] = clean(firmware) }
            let settings = d["settings"] as? [String:[String:Any]] ?? [:]
            state.magType = (settings["114"]?["words"] as? [Int])?.first.map { $0 & 65535 }
            states[id] = state
        }
        let fm = FileManager.default
        guard !fm.fileExists(atPath:text.path), !fm.fileExists(atPath:sources.path), fm.createFile(atPath:text.path,contents:nil), fm.createFile(atPath:sources.path,contents:nil) else { throw LabError.invalid("不能建立TXT导出临时文件") }
        let out = try FileHandle(forWritingTo:text), provenance = try FileHandle(forWritingTo:sources)
        defer { try? out.close(); try? provenance.close() }
        try out.write(contentsOf:Data((columns.joined(separator:"\t")+"\r\n").utf8))
        try provenance.write(contentsOf:Data(sourceHeader.utf8))
        let date = formatter(zone(metadata),"yyyy-MM-dd'T'HH:mm:ss")
        var first = true, rows = 0, skipped = 0, unknownMagRows = 0, textBuffer = Data(), sourceBuffer = Data()
        func flush() throws {
            try cancel.check(); try out.write(contentsOf:textBuffer); try provenance.write(contentsOf:sourceBuffer)
            textBuffer.removeAll(keepingCapacity:true); sourceBuffer.removeAll(keepingCapacity:true)
        }
        try lines(session.appendingPathComponent("samples.csv"),cancel:cancel) { line in
            if first { first = false; guard line == SessionWriter.header.trimmingCharacters(in:.newlines) else { throw LabError.invalid("TXT来源CSV列不兼容") }; return }
            if line.isEmpty { return }
            let c = line.split(separator:",",omittingEmptySubsequences:false).map(String.init)
            guard c.count == 21, let ns = UInt64(c[0]), let wall = Int64(c[1]), wall >= 0, !c[2].isEmpty,
                  let packet = try? WitProtocol.unhex(c[18]), packet.count == 20, packet.first == 0x55, [0x61,0x71].contains(packet[1]) else { throw LabError.invalid("TXT来源CSV存在损坏帧；原文件保留") }
            let id = c[2], f = WitFrame(packet); var state = states[id] ?? State()
            if state.cells[1] == "null" { state.cells[1] = clean(id) }
            if f.register == 0x72 { state.magType = f.words[0] & 65535 }
            if f.register == 0x3a { state.mag = Array(f.words.prefix(3)); state.magNS = ns }
            if f.register == 0x51 { for i in 0..<4 { state.cells[20+i] = fixed(f.quaternion[i],5) }; state.qNS = ns }
            if f.register == 0x40 { state.cells[24] = fixed(Double(f.words[0])/100,1) }
            if let mag = state.mag, let scale = magneticScale(state.magType) { for i in 0..<3 { state.cells[11+i] = fixed(Double(mag[i])*scale,3) } }
            else { for i in 11...13 { state.cells[i] = "null" } }
            if f.register == -1 {
                guard c[3] == "inertial", (4...9).allSatisfy({ Double(c[$0])?.isFinite == true }) else { skipped += 1; states[id] = state; return }
                for i in 0..<3 { state.cells[2+i] = fixed(f.acceleration[i],3); state.cells[5+i] = fixed(f.gyro[i],3); state.cells[8+i] = fixed(Double(f.words[6+i])*180/32768,2) }
                state.cells[0] = date.string(from:Date(timeIntervalSince1970:Double(wall/1000)))+String(format:".%03d",wall%1000)
                rows += 1; if state.mag != nil && magneticScale(state.magType) == nil { unknownMagRows += 1 }
                textBuffer.append(Data((state.cells.joined(separator:"\t")+"\r\n").utf8))
                func age(_ value: UInt64?) -> String { guard let value, ns >= value else { return "null" }; return fixed(Double(ns-value)/1e6,3) }
                func stale(_ value: UInt64?) -> String { guard let value, ns >= value, ns-value < staleNS else { return "true" }; return "false" }
                let origin = [String(rows),String(ns),String(wall),id,String(ns),state.magNS.map(String.init) ?? "null",state.qNS.map(String.init) ?? "null",age(state.magNS),age(state.qNS),stale(state.magNS),stale(state.qNS),action == 0 || ns < action ? "pre_action":"action"]
                sourceBuffer.append(Data((origin.joined(separator:",")+"\r\n").utf8))
                if textBuffer.count >= 64*1024 { try flush() }
            }
            states[id] = state
        }
        guard !first else { throw LabError.invalid("TXT来源CSV没有表头") }; try flush(); try out.synchronize(); try provenance.synchronize()
        return ["schema":"wit_text_27_columns_v1","derived":true,"rows":rows,"encoding":"UTF-8 without BOM","separator":"TAB","line_ending":"CRLF",
            "row_trigger":"one_verified_inertial_frame","auxiliary_values":"latest_received_per_device; repeated_values_are_not_new_frames",
            "source_timestamps_file":sources.lastPathComponent,"synchronization_proven":false,"used_for_quality_hz":false,
            "recording_scope":"entire_recording_including_countdown; see source phase and summary action markers",
            "time_zone_seconds":zone(metadata).secondsFromGMT(),"time_zone_source":metadata["time_zone_offset_seconds"] == nil ? "export_device_fallback":"recording_metadata",
            "unknown_magnetic_scale_rows":unknownMagRows,"unverified_inertial_frames_omitted":skipped,
            "missing_values":"null; displacement, velocity and battery unavailable; temperature only if recorded",
            "device_identifier":"iOS CoreBluetooth UUID, not an inferred MAC address"]
    }
}
