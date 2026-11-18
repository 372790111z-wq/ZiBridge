// SPDX-License-Identifier: Apache-2.0
// Modified from OpenBean c477586; see NOTICE.md. Secret values never enter errors/logs.
import Foundation
import CommonCrypto
import CryptoKit

final class SessionCrypto {
    private let privateKey = P256.KeyAgreement.PrivateKey()
    private var sessionKey: [UInt8]?
    var publicKey: [UInt8] { Array(privateKey.publicKey.x963Representation) }
    func complete(_ payload: [UInt8]) throws {
        guard payload.count == 97,
              let peer = try? P256.KeyAgreement.PublicKey(x963Representation: payload[0..<65]) else {
            throw ProbeError.invalid("peer_key_layout")
        }
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        let shared = secret.withUnsafeBytes { Array($0) }
        // The device includes its copy of the shared value in this protocol.
        // Compare without including either value in diagnostics.
        var diff: UInt8 = 0
        for i in 0..<32 { diff |= shared[i] ^ payload[65+i] }
        guard diff == 0 else { throw ProbeError.invalid("shared_key_mismatch") }
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: shared),
            salt: [UInt8](arrayLiteral:1,2,3), info: [UInt8](arrayLiteral:1,2,3), outputByteCount: 32)
        sessionKey = key.withUnsafeBytes { Array($0) }
    }
    func decryptor(_ head: FileHead) throws -> FileCrypto {
        guard let sessionKey else { throw ProbeError.invalid("key_not_ready") }
        let plain = try aesCTR(key: sessionKey, iv: head.sessionNonce, bytes: head.wrapped)
        guard plain.count == 46, Array(plain.prefix(14)) == Array("soundcored3200".utf8) else {
            throw ProbeError.invalid("file_key_unwrap_failed")
        }
        return FileCrypto(key: Array(plain[14..<46]), nonce: head.nonce)
    }
}
struct FileCrypto {
    let key: [UInt8], nonce: [UInt8]
    func decode(_ bytes: [UInt8], sequence: UInt32) throws -> [UInt8] {
        guard bytes.count == 160, nonce.count == 16, sequence <= UInt32.max/10 else {
            throw ProbeError.invalid("encrypted_slice_layout")
        }
        let n = sequence * 10
        let iv = Array(nonce.prefix(12)) + (0..<4).reversed().map { UInt8(truncatingIfNeeded: n >> ($0*8)) }
        return try aesCTR(key:key, iv:iv, bytes:bytes)
    }
}
func aesCTR(key: [UInt8], iv: [UInt8], bytes: [UInt8]) throws -> [UInt8] {
    guard key.count == 32, iv.count == 16, bytes.count <= 4096 else { throw ProbeError.invalid("aes_input_size") }
    var ref: CCCryptorRef?
    let result = CCCryptorCreate(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
        CCOptions(kCCOptionECBMode), key, key.count, nil, &ref)
    guard result == kCCSuccess, let ref else { throw ProbeError.invalid("aes_init_failed") }
    defer { CCCryptorRelease(ref) }
    var counter = iv, output = bytes
    for pos in stride(from:0, to:bytes.count, by:16) {
        var stream = [UInt8](repeating:0,count:16), moved = 0
        let status = CCCryptorUpdate(ref, counter, 16, &stream, 16, &moved)
        guard status == kCCSuccess, moved == 16 else { throw ProbeError.invalid("aes_update_failed") }
        for i in 0..<min(16, bytes.count-pos) { output[pos+i] ^= stream[i] }
        for i in (0..<16).reversed() { counter[i] &+= 1; if counter[i] != 0 { break } }
    }
    return output
}
