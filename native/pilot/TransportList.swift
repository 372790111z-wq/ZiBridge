import Foundation

// Pure, deliberately DISCONNECTED parser for the 1B0E list-with-end-time payload
// layout documented by pinned upstream sources (docs/research/protocol-semantics-20261117.md:
// tacshi/Soundcore d296a1c models.dart OfflineFileList.parse; OpenBean c4775863
// PROTOCOL.md §1B0E "8 trailing bytes"). It is not wired to any Request encoding,
// dispatch path, or policy state: parsing NEVER authorizes audio capture and NEVER
// supersedes the 1A06 session identity. The list refreshes about once a minute
// (OpenBean, 04.82) — that says nothing about the trailer's update cadence, so
// the numeric ID is only compared with an explicit caller-supplied baseline.
// A larger value is not freshness or ownership proof. Trailer duration units and
// quantization are unverified on this firmware, so the raw value is preserved.
struct TransportListSample: Equatable {
    enum Trailer: Equatable {
        case absent
        case unassessed(fileId: UInt32, rawDuration: UInt32)
        case newerThanBaseline(fileId: UInt32, rawDuration: UInt32)
        case invalid(reason: String)
    }

    static let maxEntries = 64
    let reportedCount: Int
    let listedEntries: Int
    let firstListedFileId: UInt32?
    let trailer: Trailer

    static func parse(_ payload: [UInt8], baseline: UInt32?) -> TransportListSample {
        guard payload.count >= 2 else {
            return TransportListSample(reportedCount: 0, listedEntries: 0, firstListedFileId: nil,
                                       trailer: .invalid(reason: "truncated_header"))
        }
        let count = Int(payload[0]) | Int(payload[1]) << 8
        guard count <= maxEntries else {
            return TransportListSample(reportedCount: count, listedEntries: 0, firstListedFileId: nil,
                                       trailer: .invalid(reason: "entry_count_layout_unknown"))
        }
        let entriesEnd = 2 + count * 12
        guard payload.count >= entriesEnd else {
            return TransportListSample(reportedCount: count, listedEntries: 0, firstListedFileId: nil,
                                       trailer: .invalid(reason: "count_exceeds_payload"))
        }
        var listed = 0
        var first: UInt32?
        for index in 0..<count {
            let offset = 2 + index * 12
            let entryId = u32(payload, offset)
            let duration = u32(payload, offset + 8)
            // tacshi skips zero-duration entries; ordering is their assumption,
            // not documented — we only surface the first listed id, no "newest" claim.
            guard duration > 0 else { continue }
            listed += 1
            if first == nil { first = entryId }
        }
        let trailing = payload.count - entriesEnd
        var trailer: Trailer
        switch trailing {
        case 0:
            trailer = .absent
        case 1...7:
            trailer = .invalid(reason: "truncated_trailer")
        case 8:
            let id = u32(payload, entriesEnd)
            let duration = u32(payload, entriesEnd + 4)
            if id == 0 || id == .max {
                trailer = .invalid(reason: "reserved_trailer_id")
            } else if let baseline {
                trailer = id > baseline ? .newerThanBaseline(fileId: id, rawDuration: duration)
                                        : .invalid(reason: "not_newer_than_baseline")
            } else {
                trailer = .unassessed(fileId: id, rawDuration: duration)
            }
        default:
            trailer = .invalid(reason: "trailing_length_unknown")
        }
        return TransportListSample(reportedCount: count, listedEntries: listed,
                                   firstListedFileId: first, trailer: trailer)
    }
}
