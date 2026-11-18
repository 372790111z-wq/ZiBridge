import Foundation

// Diagnostic metadata only. Never retain or emit IDs, nonces, keys or payloads.
// Observing a head does not authorize it: FileHead/EarlyLiveBuffer remain the gates.
struct HeadDiagnostics {
    private(set) var count = 0
    private(set) var samples: [[String: Any]] = []
    static let limit = 4
    var omitted: Int { count - samples.count }

    mutating func observe(_ packet: Packet, expected: UInt32?, early: Bool) -> [String: Any]? {
        guard packet.type == 0x1a, packet.id == 7 else { return nil }
        count += 1
        guard samples.count < Self.limit else { return nil }
        let body = packet.payload
        var fields: [String: Any] = [
            "ordinal": count,
            "subscription": early ? "early" : "ordinary",
            "payload_bytes": body.count,
            "envelope_status_low_nibble": Int(packet.status & 0x0f),
            "envelope_accepted": packet.accepted,
            "shape": body == [0xff] ? "single_ff_rejection" : (body.count == 87 ? "expected_87" : "unexpected_length")
        ]
        // Do not interpret offsets in a short/error/extended response as this layout.
        if body.count == 87 {
            let id = u32(body, 0), size = u32(body, 4)
            let reserved = id == 0 || id == .max
            fields["id_class"] = id == 0 ? "zero" : (id == .max ? "all_ones" : "non_reserved")
            fields["session_match"] = reserved ? "invalid_id" : expected.map { id == $0 ? "matches" : "mismatch" } ?? "awaiting_new_recording"
            fields["size_class"] = size == .max ? "live_sentinel" : (size == 0 ? "zero" : "finite_nonzero")
            fields["head_error_code"] = Int(body[86])
        }
        samples.append(fields)
        return fields
    }
}
