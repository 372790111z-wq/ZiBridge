import Foundation
import AppKit
import Darwin

// Diagnostic only. Never changes the original whole-recording completeness gate.
struct SpeechTrial {
    private(set) var readyAt: Double?
    private(set) var readySequence: UInt32?
    private(set) var closed = false
    static func mayAnnounce(_ p: PilotPolicy, stopSent: Bool) -> Bool {
        p.state == .streaming && p.ownsStart && !stopSent && !p.lastFlag && !p.terminalMatched
    }
    mutating func decoded(sequence: UInt32, at: Double, streaming: Bool) -> Bool {
        guard !closed, readyAt == nil, streaming else { return false }
        readyAt = at; readySequence = sequence; return true
    }
    mutating func close() { closed = true }
    func transportIntact(_ p: PilotPolicy, failed: Bool, buffered: Int) -> Bool {
        readyAt != nil && !failed && buffered == 0 && p.state == .ended &&
        p.stopObserved && p.terminalMatched && p.lastFlag && p.gaps == 0 && p.frames > 0
    }
}

// Explicit opt-in only; at most 30 s of unchanged 48 kHz float PCM in memory.
// Reserve a new 0600 file BEFORE touching the device, and never overwrite a path.
final class TrialWAV {
    private var fd: Int32
    private var pcm = Data()
    private(set) var samples = 0
    private(set) var peakAbs: Float = 0
    private(set) var overUnitSamples = 0
    private var finished = false
    static let limit = 1500 * 960
    init(path: String) throws {
        guard path.hasPrefix("/"), path.hasSuffix(".wav") else { throw ProbeError.invalid("trial_wav_absolute_path_required") }
        fd = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ProbeError.invalid("trial_wav_create_failed_no_overwrite") }
    }
    deinit { if fd >= 0 { Darwin.close(fd) } }
    func append(_ frame: [Float]) throws {
        guard !finished, frame.count == 960, frame.allSatisfy({ $0.isFinite }), samples + frame.count <= Self.limit else {
            throw ProbeError.invalid("trial_pcm_invalid_or_over_budget")
        }
        for sample in frame {
            peakAbs = max(peakAbs,abs(sample));if abs(sample)>1 {overUnitSamples += 1}
            pcm.append(contentsOf: le32(sample.bitPattern))
        }
        samples += frame.count
    }
    static func header(samples: Int) -> Data {
        let bytes = UInt32(samples * 4)
        return Data(Array("RIFF".utf8) + le32(36 + bytes) + Array("WAVEfmt ".utf8) +
            le32(16) + [3,0,1,0] + le32(48000) + le32(192000) + [4,0,32,0] + Array("data".utf8) + le32(bytes))
    }
    func finish() throws {
        guard !finished else { throw ProbeError.invalid("trial_wav_already_finalized") }
        finished = true
        let data = Self.header(samples: samples) + pcm
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw ProbeError.invalid("trial_wav_write_failed") }
                offset += n
            }
        }
        guard Darwin.close(fd) == 0 else { fd = -1; throw ProbeError.invalid("trial_wav_close_failed") }
        fd = -1; pcm.removeAll(keepingCapacity: false)
    }
}

final class SpeechTrialWindow: NSObject {
    let window: NSWindow
    let label = NSTextField(labelWithString: "正在准备，请先不要说话")
    let detail = NSTextField(wrappingLabelWithString: "变绿后立即读：不是十五，是十三。\n（停顿一秒）最后确认，零元七分，不退。\n说完点“结束收音”，到时自动停止。")
    let stop = NSButton(title: "结束收音", target: nil, action: nil)
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    override init() {
        window = NSWindow(contentRect: NSRect(x:0,y:0,width:600,height:230), styleMask:[.titled], backing:.buffered, defer:false)
        super.init()
        window.title = "Bridge · 本轮公开语音测试"
        window.isReleasedWhenClosed = false
        label.font = .systemFont(ofSize:28, weight:.semibold); label.textColor = .systemOrange
        label.frame = NSRect(x:24,y:170,width:552,height:40)
        detail.font = .systemFont(ofSize:17); detail.frame = NSRect(x:24,y:75,width:552,height:85)
        stop.frame = NSRect(x:330,y:20,width:120,height:36); stop.target=self; stop.action=#selector(end); stop.isEnabled=false
        let cancel = NSButton(title:"取消并停止",target:self,action:#selector(cancelTrial))
        cancel.frame=NSRect(x:465,y:20,width:115,height:36)
        for view in [label,detail,stop,cancel] { window.contentView?.addSubview(view) }
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    }
    func ready() { label.stringValue="可以说话"; label.textColor = .systemGreen; stop.isEnabled=true }
    func ending() { label.stringValue="正在停止并接收尾音"; label.textColor = .systemOrange; stop.isEnabled=false }
    func comparing() { label.stringValue="收音已停，正在读取同一条录音"; label.textColor = .systemOrange; stop.isEnabled=false }
    @objc private func end() { onStop?() }
    @objc private func cancelTrial() { onCancel?() }
}
