import Foundation

// Only encrypted bytes may wait for the recording's 1A06 identity proof.
// No old-file lookup, no key unwrap, no output, and a hard 64-frame bound.
struct EarlyLiveBuffer {
    private(set) var head: [UInt8]?
    private(set) var packets: [[UInt8]] = []
    private(set) var frames = 0
    private(set) var released = false
    mutating func acceptHead(_ body: [UInt8]) throws {
        guard !released, head == nil, body.count == 87 else {throw ProbeError.invalid("early_head_shape_or_duplicate")}
        let id = u32(body,0)
        guard id != 0, id != .max else {throw ProbeError.invalid("early_head_invalid_id")}
        _ = try FileHead(body,expected:id)
        head = body
    }
    mutating func append(_ body: [UInt8]) throws {
        guard !released, head != nil, !body.isEmpty, body.count % 166 == 0,
              frames + body.count/166 <= 64 else {throw ProbeError.invalid("early_encrypted_buffer_limit_or_order")}
        packets.append(body);frames += body.count/166
    }
    mutating func release(matching id: UInt32) throws -> ([UInt8], [[UInt8]]) {
        guard !released, let head else {throw ProbeError.invalid("early_head_not_ready")}
        _ = try FileHead(head,expected:id)
        released = true
        let result = (head,packets)
        self.head=nil;packets.removeAll(keepingCapacity:false)
        return result
    }
    mutating func discard() {head=nil;packets.removeAll(keepingCapacity:false);released=true}
}
