import Foundation
import CryptoKit

// Explicit diagnostic only. Never substitutes file playback for live audio.
// A current-session capability, not an arbitrary file-ID download interface.
struct DeviceComparison {
    enum Stage { case live, head, audio, complete }
    private(set) var stage: Stage = .live
    private(set) var file: UInt32?
    private(set) var requestSent = false
    private(set) var expectedFrames = 0
    private(set) var frames = 0
    private(set) var terminal = false
    private(set) var lastFlag = false
    private(set) var overlap = 0
    private(set) var byteMismatches = 0
    private(set) var flagDifferences = 0
    private(set) var otherFlagDifferences = 0
    private var live: [UInt32: (Data, UInt8)] = [:]
    var liveFirst: UInt32? { live.keys.min() }
    var liveLast: UInt32? { live.keys.max() }
    mutating func observeLive(sequence: UInt32, flags: UInt8, opus: [UInt8]) throws {
        guard stage == .live, sequence < 1000, live.count < 1000, live[sequence] == nil,
              opus.count == 160 else { throw ProbeError.invalid("comparison_live_scope") }
        live[sequence] = (Data(SHA256.hash(data: Data(opus))), flags)
    }
    mutating func begin(_ p: PilotPolicy, authorized: Bool, failed: Bool, buffered: Int) throws -> UInt32 {
        guard authorized, !failed, buffered == 0, stage == .live, !requestSent,
              p.state == .ended, p.stopObserved, p.terminalMatched, let id = p.file,
              !live.isEmpty, live.count == p.frames, liveFirst == p.first, liveLast == p.last else {
            throw ProbeError.invalid("comparison_requires_current_stopped_session")
        }
        file = id; stage = .head; return id
    }
    mutating func authorizeRequest(_ id: UInt32) throws {
        guard stage == .head, file == id, !requestSent else { throw ProbeError.invalid("comparison_request_scope") }
        requestSent = true
    }
    mutating func acceptHead(_ bytes: [UInt8]) throws -> FileHead {
        guard stage == .head, requestSent, let id = file, bytes.count == 87 else {
            throw ProbeError.invalid("comparison_unrequested_head")
        }
        let size = u32(bytes, 4)
        guard size > 0, size != UInt32.max, size % 166 == 0, size / 166 <= 1000,
              let last = liveLast, size / 166 > last else { throw ProbeError.invalid("comparison_finite_size") }
        let head = try FileHead(bytes, expected: id, finishedFrames: Int(size / 166))
        expectedFrames = Int(size / 166); stage = .audio; return head
    }
    mutating func acceptFrame(sequence: UInt32, flags: UInt8, opus: [UInt8]) throws {
        guard stage == .audio, !lastFlag, frames < expectedFrames, sequence == UInt32(frames),
              flags & 0xf8 == 0, (flags & 2 != 0) == (sequence == 0),
              (flags & 4 != 0) == (frames == expectedFrames - 1), opus.count == 160 else {
            throw ProbeError.invalid("comparison_frame_boundary_or_order")
        }
        if let (hash, liveFlags) = live[sequence] {
            overlap += 1
            if hash != Data(SHA256.hash(data: Data(opus))) { byteMismatches += 1 }
            if liveFlags != flags {
                flagDifferences += 1
                // Only the final frame missing exactly its last-flag bit is the known
                // marker-only pattern; any other flag difference leaves the overlap
                // content unproven and must not yield a confident tail classification.
                let markerOnly = sequence == UInt32(expectedFrames - 1) && (liveFlags | 4) == flags
                if !markerOnly { otherFlagDifferences += 1 }
            }
        }
        frames += 1; lastFlag = flags & 4 != 0
    }
    mutating func acceptTerminal(_ id: UInt32) throws {
        guard stage == .audio, file == id, !terminal else { throw ProbeError.invalid("comparison_terminal_scope") }
        terminal = true
    }
    var readyToComplete: Bool {
        stage == .audio && terminal && lastFlag && frames == expectedFrames && overlap == live.count
    }
    mutating func complete(buffered: Int, samples: Int) throws {
        guard readyToComplete, buffered == 0, samples == frames * 960 else {
            throw ProbeError.invalid("comparison_incomplete")
        }
        stage = .complete
    }
    var fields: [String: Any] {
        var result: [String: Any] = ["requested": requestSent, "file_complete": stage == .complete,
            "expected_file_frames": expectedFrames, "received_file_frames": frames,
            "overlap_frames": overlap, "opus_byte_mismatches": byteMismatches,
            "flag_differences": flagDifferences, "file_terminal": terminal, "file_last_flag": lastFlag,
            "comparison_is_live_repair": false, "acoustic_acceptance": "requires_listening"]
        if stage == .complete, let first = liveFirst, let last = liveLast {
            result["prefix_frames_absent_from_live"] = Int(first)
            result["suffix_frames_absent_from_live"] = expectedFrames - Int(last) - 1
            result["middle_frames_absent_from_live"] = Int(last - first + 1) - live.count
            result["all_live_opus_bytes_equal_file"] = byteMismatches == 0
            result["flag_differences_other_than_marker"] = otherFlagDifferences
            // Transport-only classification of the live tail. It never upgrades
            // audio_complete, and stays unproven whenever overlap content cannot be
            // proven equal (any Opus byte difference or non-marker flag difference).
            if byteMismatches > 0 || otherFlagDifferences > 0 { result["live_tail_outcome"] = "overlap_mismatch_tail_outcome_unproven" }
            else if expectedFrames - Int(last) - 1 > 0 { result["live_tail_outcome"] = "tail_frames_absent_from_live" }
            else if live[last].map({ $0.1 & 4 != 0 }) != true { result["live_tail_outcome"] = "tail_marker_flag_missing_in_live_only" }
            else { result["live_tail_outcome"] = "tail_frames_and_marker_intact" }
        }
        return result
    }
}
