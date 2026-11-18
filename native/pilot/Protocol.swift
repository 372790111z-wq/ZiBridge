import Foundation

enum ProbeError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { switch self { case .invalid(let s): return s } }
}
func le32(_ n: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) } }
func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
    precondition(i >= 0 && i + 4 <= b.count)
    return (0..<4).reduce(UInt32(0)) { $0 | UInt32(b[i + $1]) << ($1 * 8) }
}
struct Packet {
    let status: UInt8, type: UInt8, id: UInt8, payload: [UInt8]
    var accepted: Bool { status & 0x0f == 1 && payload != [0xff] }
    var code: String { String(format: "%02X/%02X", type, id) }
}

// Bounded, checksum-checked notification reassembly. Never log payload bytes.
struct Assembler {
    private var buffer: [UInt8] = []
    private(set) var corrupt = 0
    var buffered: Int { buffer.count }
    mutating func feed(_ bytes: [UInt8]) throws -> [Packet] {
        guard bytes.count <= 65535, buffer.count + bytes.count <= 131070 else {
            throw ProbeError.invalid("notification_buffer_limit")
        }
        buffer += bytes
        var packets: [Packet] = []
        while buffer.count >= 10 {
            guard Array(buffer.prefix(4)) == [9, 255, 0, 0] else {
                buffer.removeFirst(); corrupt += 1; continue
            }
            let n = Int(buffer[7]) | Int(buffer[8]) << 8
            guard n >= 10 else { buffer.removeFirst(); corrupt += 1; continue }
            guard buffer.count >= n else { break }
            let raw = Array(buffer.prefix(n))
            guard raw.dropLast().reduce(UInt8(0), { $0 &+ $1 }) == raw.last else {
                buffer.removeFirst(); corrupt += 1; continue
            }
            packets.append(Packet(status: raw[4], type: raw[5], id: raw[6], payload: Array(raw[9..<(n-1)])))
            buffer.removeFirst(n)
        }
        return packets
    }
}

// No generic command escape hatch. Finished-file reads are gated to this session.
enum Request {
    case info
    case startOwned
    case pauseOwned
    case stopOwned
    case handshake([UInt8])
    case earlyLiveOwned
    case live(UInt32)
    case finished(UInt32)
    func encoded() throws -> [UInt8] {
        let type: UInt8, id: UInt8, body: [UInt8]
        switch self {
        case .info: (type, id, body) = (1, 1, [])
        case .startOwned: (type,id,body) = (0x18,0x82,[1])
        case .pauseOwned: (type,id,body) = (0x18,0x82,[2])
        case .stopOwned: (type,id,body) = (0x18,0x82,[0])
        case .handshake(let key):
            guard key.count == 65, key.first == 4 else { throw ProbeError.invalid("public_key_format") }
            (type, id, body) = (0x2e, 1, key)
        case .earlyLiveOwned:
            // Experimental current-live subscription; never offline/old-file access.
            (type,id,body) = (0x1a,7,le32(0)+le32(0)+[1])
        case .live(let file):
            guard file != 0 && file != UInt32.max else { throw ProbeError.invalid("invalid_live_id") }
            (type, id, body) = (0x1a, 7, le32(0) + le32(file) + [1])
        case .finished(let file):
            guard file != 0 && file != UInt32.max else { throw ProbeError.invalid("invalid_finished_id") }
            (type, id, body) = (0x1a, 7, le32(0) + le32(file) + [0])
        }
        let n = body.count + 10
        var b: [UInt8] = [8, 238, 0, 0, 0, type, id, UInt8(n & 255), UInt8(n >> 8)] + body
        b.append(b.reduce(UInt8(0), { $0 &+ $1 }))
        return b
    }
}

struct DeviceInfo {
    let firmware: String, caseFirmware: String, wifiFirmware: String
    let recording: Bool
    init(_ body: [UInt8]) throws {
        guard body.count >= 56, body[50] <= 1 else { throw ProbeError.invalid("device_info_layout_unknown") }
        func ascii(_ offset: Int) throws -> String {
            let b = Array(body[offset..<(offset+5)].prefix { $0 != 0 })
            guard !b.isEmpty, b.allSatisfy({ (48...57).contains($0) || $0 == 46 }) else {
                throw ProbeError.invalid("firmware_format_unknown")
            }
            return String(decoding: b, as: UTF8.self)
        }
        firmware = try ascii(3); caseFirmware = try ascii(33); wifiFirmware = try ascii(51)
        recording = body[50] == 1
    }
    var isRequestedRecorder: Bool { firmware.split(separator: ".").compactMap { Int($0) } == [4,92] }
}
struct FileHead {
    let file: UInt32, nonce: [UInt8], wrapped: [UInt8], sessionNonce: [UInt8]
    init(_ body: [UInt8], expected: UInt32, finishedFrames: Int? = nil) throws {
        if let n = finishedFrames { guard (1...1000).contains(n) else { throw ProbeError.invalid("finished_size_limit") } }
        let expectedSize = finishedFrames.map { UInt32($0 * 166) } ?? UInt32.max
        guard body.count == 87, body[86] == 0, u32(body,0) == expected,
              u32(body,4) == expectedSize else { throw ProbeError.invalid("file_head_rejected") }
        file = expected; nonce = Array(body[8..<24]); wrapped = Array(body[24..<70]); sessionNonce = Array(body[70..<86])
    }
}

enum Phase: String { case info, key, idleCheck, armed, head, streaming, draining, recoveryHead, recovering, recovered, ended }
// Session safety gates are pure/testable; no reads of old or already-running recordings.
struct SessionGate {
    private(set) var phase: Phase = .info
    private(set) var file: UInt32?
    mutating func information(_ info: DeviceInfo, observe: Bool) throws {
        guard phase == .info || phase == .idleCheck else { throw ProbeError.invalid("unsolicited_info") }
        if !observe { phase = .ended; return }
        guard info.isRequestedRecorder else { throw ProbeError.invalid("unexpected_recorder_firmware") }
        guard !info.recording else { throw ProbeError.invalid("already_recording_not_captured") }
        phase = phase == .info ? .key : .armed
    }
    mutating func keyReady() throws {
        guard phase == .key else { throw ProbeError.invalid("unexpected_key_reply") }
        phase = .idleCheck
    }
    mutating func newRecording(_ body: [UInt8]) throws -> UInt32? {
        guard phase == .armed else {
            // A new-file notification during handshake can be an old/ongoing recording.
            if phase == .key || phase == .idleCheck { throw ProbeError.invalid("recording_started_before_arm") }
            if phase == .head || phase == .streaming || phase == .draining || phase == .recoveryHead || phase == .recovering {
                guard body.count >= 4, u32(body,0) == file else { throw ProbeError.invalid("recording_changed_mid_session") }
            }
            return nil
        }
        guard body.count >= 4 else { throw ProbeError.invalid("new_recording_layout") }
        let id = u32(body,0)
        guard id != 0 && id != UInt32.max else { throw ProbeError.invalid("invalid_new_recording_id") }
        file = id; phase = .head; return id
    }
    mutating func headReady() throws {
        guard phase == .head else { throw ProbeError.invalid("duplicate_or_unrequested_head") }
        phase = .streaming
    }
    mutating func stopped() { if phase == .streaming { phase = .draining } }
    mutating func beginRecovery(stopped: Bool, done: Bool, finalSequence: UInt32?, lastFlag: Bool) throws -> Int {
        guard phase == .draining, file != nil, stopped, done, lastFlag,
              let finalSequence, finalSequence < 1000 else { throw ProbeError.invalid("recovery_not_authorized_by_live_session") }
        phase = .recoveryHead
        return Int(finalSequence) + 1
    }
    mutating func recoveryHeadReady() throws {
        guard phase == .recoveryHead else { throw ProbeError.invalid("unexpected_recovery_head") }
        phase = .recovering
    }
    mutating func recoveryDone(_ metrics: SliceMetrics, expected: Int) throws {
        guard phase == .recovering, metrics.startsAtZero, metrics.lastFlag, metrics.missing == 0,
              metrics.duplicates == 0, metrics.frames == expected else { throw ProbeError.invalid("recovery_incomplete") }
        phase = .recovered
    }
}

struct SliceMetrics {
    private(set) var first: UInt32?, last: UInt32?
    private(set) var frames = 0, missing = 0, duplicates = 0, marks = 0
    private(set) var firstFlag = false, lastFlag = false
    mutating func accept(seq: UInt32, flags: UInt8) throws -> Bool {
        guard frames < 1000, seq <= UInt32.max / 10 else { throw ProbeError.invalid("audio_frame_limit") }
        guard flags & 0xf8 == 0 else { throw ProbeError.invalid("unknown_slice_flags") }
        if let last {
            if seq == last { duplicates += 1; return false }
            guard !lastFlag else { throw ProbeError.invalid("audio_after_last_flag") }
            guard seq > last else { throw ProbeError.invalid("audio_out_of_order") }
            missing += Int(seq - last - 1)
        } else { first = seq }
        last = seq; frames += 1
        if flags & 1 != 0 { marks += 1 }
        if flags & 2 != 0 {
            guard seq == 0 else { throw ProbeError.invalid("first_flag_wrong_position") }
            firstFlag = true
        }
        if flags & 4 != 0 { lastFlag = true }
        return true
    }
    var startsAtZero: Bool { first == 0 && firstFlag }
}

struct PlainSlice: Equatable {
    let flags: UInt8
    let opus: [UInt8]
}

// Combine verified stopped live tail with only its missing prefix. An overlap
// frame is mandatory; both bytes and flags must match. No guessed/silent frames.
func mergePrefix(_ prefix:[UInt32:PlainSlice], live:[UInt32:PlainSlice], expected:Int) throws -> [PlainSlice] {
    guard (1...1000).contains(expected), let firstLive=live.keys.min(),
          live.keys.max()==UInt32(expected-1), prefix.keys.min()==0,
          prefix.keys.max()==firstLive, prefix.count==Int(firstLive)+1,
          live.count==expected-Int(firstLive), prefix[firstLive]==live[firstLive] else {
        throw ProbeError.invalid("prefix_scope_or_overlap_mismatch")
    }
    var result:[PlainSlice]=[], metrics=SliceMetrics()
    for n in 0..<expected {
        let seq=UInt32(n)
        guard let slice = n<Int(firstLive) ? prefix[seq] : live[seq], slice.opus.count==160 else {
            throw ProbeError.invalid("prefix_merge_gap")
        }
        guard try metrics.accept(seq:seq,flags:slice.flags) else { throw ProbeError.invalid("prefix_merge_duplicate") }
        result.append(slice)
    }
    guard metrics.startsAtZero,metrics.lastFlag,metrics.frames==expected else { throw ProbeError.invalid("prefix_merge_boundary_flags") }
    return result
}
