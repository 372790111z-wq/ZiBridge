import Foundation

// No hardware side effects. Permission to send a control command is minted once
// by current-session evidence, never by a cached device or a generic command API.
struct PilotPolicy {
    enum State: String { case checking, starting, streaming, stopping, verifying, ended }
    // nil removes only the experiment duration/frame budget. Wire counter safety,
    // ordering, ownership, framing and stop protections always apply.
    static let maxSequence = UInt32.max / 10 // AES counter uses sequence * 10.
    let maxFrames: Int?
    init(maxFrames: Int? = 1500) { self.maxFrames = maxFrames }
    private(set) var state: State = .checking
    private(set) var ownsStart = false
    private(set) var startAcknowledged = false
    private(set) var file: UInt32?
    private(set) var stopObserved = false
    private(set) var terminalMatched = false
    private(set) var first: UInt32?
    private(set) var last: UInt32?
    private(set) var frames = 0
    private(set) var firstFlag = false
    private(set) var lastFlag = false
    private(set) var gaps = 0
    mutating func start(firmwareOK: Bool, idle: Bool) throws {
        guard state == .checking, firmwareOK, idle else { throw ProbeError.invalid("pilot_not_idle_or_wrong_firmware") }
        ownsStart = true; state = .starting
    }
    mutating func acknowledgeStart() throws {
        guard state == .starting, ownsStart, !startAcknowledged else { throw ProbeError.invalid("unexpected_start_ack") }
        startAcknowledged = true
    }
    mutating func opened(_ id: UInt32) throws {
        guard state == .starting, ownsStart, startAcknowledged, id != 0, id != .max else { throw ProbeError.invalid("unowned_or_duplicate_recording") }
        file = id; state = .streaming
    }
    mutating func frame(seq: UInt32, flags: UInt8) throws {
        guard (state == .streaming || state == .stopping || state == .verifying || state == .ended), file != nil,
              seq <= Self.maxSequence, maxFrames.map({ frames < $0 && Int(seq) < $0 }) ?? true,
              flags & 0xf8 == 0, !lastFlag else { throw ProbeError.invalid("invalid_stream_state") }
        if let last {
            guard seq > last else { throw ProbeError.invalid("repeated_or_reordered_frame") }
            guard seq == last + 1 else { gaps += Int(seq-last-1); throw ProbeError.invalid("live_gap") }
        } else { first = seq }
        if flags & 2 != 0 { guard seq == 0 else { throw ProbeError.invalid("wrong_first_flag") }; firstFlag = true }
        lastFlag = flags & 4 != 0; last = seq; frames += 1
    }
    mutating func requestStop() throws {
        guard ownsStart, file != nil, state == .starting || state == .streaming else { throw ProbeError.invalid("stop_without_owned_start") }
        state = .stopping
    }
    @discardableResult mutating func observeStop() throws -> Bool {
        if stopObserved, file != nil, state == .stopping || state == .verifying || state == .ended { return false }
        guard ownsStart, state == .stopping || state == .streaming else { throw ProbeError.invalid("unexpected_stop") }
        state = .stopping; stopObserved = true; return true
    }
    mutating func terminal(_ id: UInt32) throws {
        guard let file, file == id, ownsStart || state == .ended, state == .stopping || state == .streaming || state == .verifying || state == .ended, !terminalMatched else { throw ProbeError.invalid("terminal_wrong_session") }
        terminalMatched = true
    }
    mutating func verifyRequested() throws {
        guard stopObserved, file != nil, ownsStart, state == .stopping else { throw ProbeError.invalid("stop_not_yet_proven") }
        state = .verifying
    }
    mutating func verifiedIdle(_ idle: Bool) throws {
        guard state == .verifying, idle else { throw ProbeError.invalid("device_stop_unconfirmed") }
        state = .ended; ownsStart = false
    }
    var protocolAudioComplete: Bool { state == .ended && stopObserved && terminalMatched && fromStartComplete && lastFlag }
    var canRequestEarlyLive: Bool {ownsStart && startAcknowledged && state == .starting && file == nil}
    var prefixFramesMissing: UInt32 { first ?? 0 }
    var fromStartComplete: Bool { first == 0 && firstFlag && gaps == 0 }
}

struct QueueBudget {
    private(set) var pending = 0
    private(set) var peak = 0
    let limit = 8 // 160 ms; fail instead of accumulating old audio.
    mutating func acquire() throws {
        guard pending < limit else { throw ProbeError.invalid("audio_output_backlog") }
        pending += 1; peak = max(peak,pending)
    }
    mutating func release() { if pending > 0 { pending -= 1 } }
}

func percentile(_ values: [Double], _ p: Double) -> Double? {
    guard !values.isEmpty, (0...1).contains(p) else { return nil }
    let v = values.sorted(); return v[max(0, Int(ceil(Double(v.count)*p))-1)]
}

// Diagnostic only: how much later the first delivered frame arrived beyond its own
// position in the recording. Bundles device capture origin and initial stream
// buffering; it is not tool latency alone and never an acceptance metric.
func streamAttachLag(startToFirstPCM: Double?, firstSequence: UInt32?) -> Double? {
    guard let t = startToFirstPCM, let first = firstSequence,
          t.isFinite, t >= 0, first < 1500 else { return nil }
    return t - Double(first) * 0.02
}
