import Foundation
import CryptoKit
import Darwin

// Uses an existing, pinned local libopus; no installation and no AVAudioConverter
// container pre-skip. Raw packet decoder must return every 20-ms frame (960 @48k).
final class LiveOpus {
    typealias Create = @convention(c) (Int32, Int32, UnsafeMutablePointer<Int32>?) -> OpaquePointer?
    typealias Decode = @convention(c) (OpaquePointer?, UnsafePointer<UInt8>?, Int32, UnsafeMutablePointer<Float>?, Int32, Int32) -> Int32
    typealias Destroy = @convention(c) (OpaquePointer?) -> Void
    let library: UnsafeMutableRawPointer, state: OpaquePointer, decodeFunction: Decode, destroy: Destroy
    init() throws {
        // Prefer a copy inside the app bundle (same pinned bytes), then the verified
        // existing Homebrew path. No download/install and no different library.
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("libopus.0.dylib").path
        let pinned = "/opt/homebrew/Cellar/opus/1.6.1/lib/libopus.0.dylib"
        let path = [bundled,pinned].compactMap{$0}.first{FileManager.default.fileExists(atPath:$0)} ?? pinned
        let bytes = try Data(contentsOf:URL(fileURLWithPath:path),options:.mappedIfSafe)
        let hash = SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined()
        guard hash == "98dcd3cc62c6cf913b789051536ab246c56cc163c74bd8b4968ac467ec74b68b",
              let lib=dlopen(path,RTLD_LOCAL|RTLD_NOW) else { throw ProbeError.invalid("existing_opus_integrity_or_load") }
        guard let create=dlsym(lib,"opus_decoder_create"), let decode=dlsym(lib,"opus_decode_float"),
              let destroy=dlsym(lib,"opus_decoder_destroy") else { dlclose(lib); throw ProbeError.invalid("opus_symbols") }
        var error:Int32=0
        guard let state=unsafeBitCast(create,to:Create.self)(48000,1,&error),error==0 else {
            dlclose(lib); throw ProbeError.invalid("opus_create")
        }
        self.library=lib; self.state=state; decodeFunction=unsafeBitCast(decode,to:Decode.self)
        self.destroy=unsafeBitCast(destroy,to:Destroy.self)
    }
    deinit { destroy(state); dlclose(library) }
    func decode(_ slot: [UInt8]) throws -> [Float] {
        guard slot.count == 160 else { throw ProbeError.invalid("opus_slot_size") }
        var packet = slot
        while packet.count > 1 && packet.last == 0 { packet.removeLast() }
        guard packet[0] & 3 == 0 else { throw ProbeError.invalid("opus_multiple_frames") }
        var out = [Float](repeating:0,count:960)
        let n = decodeFunction(state,packet,Int32(packet.count),&out,960,0)
        guard n == 960, out.allSatisfy({ $0.isFinite }) else { throw ProbeError.invalid("opus_frame_failed") }
        return out
    }
}
