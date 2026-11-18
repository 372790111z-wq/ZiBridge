import Foundation

// Metadata only, called AFTER current-session validation and successful decode.
// No PCM, file identity, key material or recording authority is stored here.
struct TailTelemetry {
    struct Frame { let sequence: UInt32, flags: UInt8, received: Double }
    private(set) var recent: [Frame] = []
    private(set) var frames = 0, afterStop = 0, afterIdle = 0, afterTerminal = 0
    private(set) var invalid = 0
    private(set) var lastFlagAt: Double?
    @discardableResult mutating func record(sequence: UInt32, flags: UInt8, received: Double,
                                            stop: Double?, idle: Double?, terminal: Double?) -> Bool {
        guard sequence <= PilotPolicy.maxSequence, flags & 0xf8 == 0,
              received.isFinite, received >= 0,
              received >= (recent.last?.received ?? 0),
              recent.last.map({ sequence > $0.sequence }) ?? true else { invalid += 1; return false }
        frames += 1
        if let stop, received >= stop { afterStop += 1 }
        if let idle, received >= idle { afterIdle += 1 }
        if let terminal, received >= terminal { afterTerminal += 1 }
        if flags & 4 != 0 { lastFlagAt = received }
        recent.append(Frame(sequence:sequence,flags:flags,received:received))
        if recent.count > 32 { recent.removeFirst() }
        return true
    }
    func fields(stop: Double?, idle: Double?, terminal: Double?, finish: Double) -> [String: Any] {
        var result: [String: Any] = ["decoded_frames":frames,"frames_after_stop":afterStop,
            "frames_after_idle":afterIdle,"frames_after_terminal":afterTerminal,
            "invalid_observations":invalid,"retained_frame_count":recent.count]
        func interval(_ name:String,_ value:Double?,_ origin:Double?) {
            if let value,let origin,value.isFinite,origin.isFinite { result[name]=value-origin }
        }
        interval("last_audio_minus_stop_s",recent.last?.received,stop)
        interval("last_audio_minus_idle_s",recent.last?.received,idle)
        interval("last_audio_minus_terminal_s",recent.last?.received,terminal)
        interval("tail_flag_minus_stop_s",lastFlagAt,stop)
        interval("tail_flag_minus_idle_s",lastFlagAt,idle)
        interval("finish_minus_idle_s",finish,idle)
        result["recent_frames"] = recent.map { frame -> [String:Any] in
            var row: [String:Any] = ["sequence":frame.sequence,"flags":frame.flags]
            if let stop { row["received_minus_stop_s"]=frame.received-stop }
            return row
        }
        return result
    }
}
