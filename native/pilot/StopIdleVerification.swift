import Foundation

// A stop acknowledgement may precede the device info bit changing to idle.
// Retry only read-only info, never resend stop or extend the absolute deadline.
struct StopIdleVerification {
    private(set) var deadline: Double?
    private(set) var retryAt: Double?
    private(set) var busyObservations = 0
    // Unknown-layout replies are neither idle nor busy: retain unknown state and
    // schedule a read-only requery inside the original absolute deadline only.
    private(set) var unknownLayoutObservations = 0
    private(set) var duplicateUnknownLayout = 0
    // True between sending a read-only info query and receiving any reply. Lets tick
    // enforce the original deadline even when a requery is never answered.
    private(set) var awaitingReply = false
    static let maxUnknownLayout = 4
    mutating func begin(at now: Double) throws {
        guard deadline == nil, now.isFinite else { throw ProbeError.invalid("duplicate_stop_verification") }
        deadline = now + 2
    }
    mutating func stillRecording(at now: Double) throws {
        guard let deadline, now.isFinite, now + 0.15 < deadline, busyObservations < 8, retryAt == nil else {
            throw ProbeError.invalid("device_stop_unconfirmed")
        }
        awaitingReply = false
        busyObservations += 1; retryAt = now + 0.15
    }
    mutating func unknownLayout(at now: Double) throws {
        guard let deadline, now.isFinite, now < deadline else { throw ProbeError.invalid("device_stop_unconfirmed") }
        awaitingReply = false
        if retryAt != nil { duplicateUnknownLayout += 1; return } // duplicate reply for one query
        guard unknownLayoutObservations < Self.maxUnknownLayout, now + 0.15 < deadline else {
            throw ProbeError.invalid("device_stop_unconfirmed")
        }
        unknownLayoutObservations += 1; retryAt = now + 0.15
    }
    mutating func markReplyExpected() { awaitingReply = true }
    mutating func checkDeadline(at now: Double) throws {
        guard let deadline, now.isFinite, now < deadline else { throw ProbeError.invalid("device_stop_unconfirmed") }
    }
    mutating func takeDue(at now: Double) throws -> Bool {
        guard let retryAt else { return false }
        guard let deadline, now < deadline else { throw ProbeError.invalid("device_stop_unconfirmed") }
        guard now >= retryAt else { return false }
        self.retryAt = nil; return true
    }
    mutating func complete() { retryAt = nil; awaitingReply = false }
}
