import Foundation

// Opt-in (default off) stop-ordering experiment: pause the owned recording, require
// its ACK, hold a short bounded window so late slices can still arrive, then send the
// real stop. Pause is NEVER treated as a stop: only a stop notice plus idle
// verification may end the session. Pure and time-injected so the whole lifecycle can
// be replayed through deterministic transport fixtures; transport side effects stay
// in Pilot. Hardware semantics (does pause improve tail delivery?) are unvalidated.
struct PauseStopSequencer {
    enum Phase: String { case idle, sendingPause, waitingAck, holding, completing, done }
    enum Outcome: String { case none, finalStopSent, deviceStopped, aborted, stopWriteFailed, pauseSendFailed }
    enum Action: Equatable { case none, sendFinalStop(String) }

    static let ackTimeout = 2.0
    static let minWindowMs = 100
    static let maxWindowMs = 500

    private(set) var phase: Phase = .idle
    private(set) var pauseSentAt: Double?
    private(set) var pauseAckAt: Double?
    private(set) var stopDueAt: Double?
    private(set) var outcome: Outcome = .none
    private(set) var duplicateAcks = 0, lateAcks = 0
    private(set) var finalStopReason: String?

    var active: Bool { phase != .idle && phase != .done }
    var awaitingAck: Bool { phase == .waitingAck }
    var holding: Bool { phase == .holding }
    var stopSendPending: Bool { phase == .completing }
    var finished: Bool { phase == .done }

    mutating func begin(at now: Double) -> Bool {
        guard phase == .idle, now.isFinite, now >= 0 else { return false }
        phase = .sendingPause; pauseSentAt = now; return true
    }

    mutating func pauseWritten() {
        guard phase == .sendingPause else { return }
        phase = .waitingAck
    }

    // Returns false for a malformed/too-late ACK. Strict boundary: an ACK at exactly
    // ackTimeout is REJECTED and poll() at that same instant times out, so there is
    // one consistent rule. The caller decides whether a false result is a late
    // observation (ignored) or an unexpected pause (rejected).
    mutating func acknowledge(at now: Double, windowMs: Int) -> Bool {
        guard phase == .waitingAck, let sent = pauseSentAt, now.isFinite, now >= sent,
              now - sent < Self.ackTimeout,
              (Self.minWindowMs...Self.maxWindowMs).contains(windowMs) else { return false }
        pauseAckAt = now
        stopDueAt = now + Double(windowMs) / 1000
        phase = .holding
        return true
    }

    mutating func poll(at now: Double) -> Action {
        guard now.isFinite else { return .none }
        switch phase {
        case .waitingAck:
            if let sent = pauseSentAt, now - sent >= Self.ackTimeout {
                phase = .completing; finalStopReason = "pause_ack_timeout"
                return .sendFinalStop("pause_ack_timeout")
            }
        case .holding:
            if let due = stopDueAt, now >= due {
                phase = .completing; finalStopReason = "pause_window_elapsed"
                return .sendFinalStop("pause_window_elapsed")
            }
        default: break
        }
        return .none
    }

    mutating func finalStopWritten() {
        guard phase == .completing else { return }
        outcome = .finalStopSent; phase = .done
    }

    mutating func finalStopWriteFailed() {
        guard phase == .completing else { return }
        outcome = .stopWriteFailed; phase = .done
    }

    // A direct stop (cancellation/error/timeout path) bypasses the window but still
    // completes the probe; without this the sequence would look unfinished forever.
    mutating func forcedFinalStopWritten() {
        guard active else { return }
        finalStopReason = finalStopReason ?? "forced_direct_stop"
        outcome = .finalStopSent; phase = .done
    }

    mutating func forcedStopWriteFailed() {
        guard active else { return }
        outcome = .stopWriteFailed; phase = .done
    }

    mutating func pauseSendFailed() {
        guard phase == .sendingPause || phase == .waitingAck else { return }
        outcome = .pauseSendFailed; phase = .done
    }

    mutating func deviceStopped() {
        guard active else { return }
        outcome = .deviceStopped; phase = .done
    }

    mutating func abort() {
        guard active else { return }
        outcome = .aborted; phase = .done
    }

    @discardableResult mutating func noteDuplicateAck() -> Bool {
        guard pauseAckAt != nil, phase == .holding || phase == .completing || phase == .done else { return false }
        duplicateAcks += 1; return true
    }

    mutating func noteLateAck() { lateAcks += 1 }
}
