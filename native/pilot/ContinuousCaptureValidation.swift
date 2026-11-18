import Foundation
import Darwin

// Explicit CLI validation, never invoked by the GUI. Synthetic encrypted silence
// follows the production reassembly/decrypt/Opus/policy path. The sink consumes the
// production fixed-capacity PCM queue in memory: no BLE, HAL, mic or system output.
private final class SoakQueueOutput: WorkbenchAudioOutput {
    var queue = try! PCMOutputQueue(capacityFrames: PCMOutputQueue.trialCapacityFrames)
    var scratch = [Float](repeating: 0, count: 1920)
    var closed = false
    var pending: Int { queue.pendingFrames }
    var queueMetrics: [String: Any] { queue.metrics }
    func validateRoute() throws { if closed { throw ProbeError.invalid("soak_closed_sink") } }
    func push(_ pcm: [Float]) throws { try queue.enqueue(pcm) }
    func consume() {
        scratch.withUnsafeMutableBufferPointer { queue.renderStereo(into: $0.baseAddress!, frames: 960) }
    }
    func close() { closed = true; queue.clear() }
}

func runContinuousCaptureValidation(seconds: Int) throws {
    guard (1...3600).contains(seconds) else { throw ProbeError.invalid("soak_duration_1_to_3600") }
    func require(_ value: Bool, _ why: String) throws {
        if !value { throw ProbeError.invalid("continuous_soak_" + why) }
    }
    func peakRSS() -> Int64 { var r = rusage(); getrusage(RUSAGE_SELF, &r); return Int64(r.ru_maxrss) }
    func wire(_ type: UInt8, _ id: UInt8, _ body: [UInt8]) -> [UInt8] {
        let size = body.count + 10
        var b: [UInt8] = [9,255,0,0,1,type,id,UInt8(size & 255),UInt8(size >> 8)] + body
        b.append(b.reduce(UInt8(0), { $0 &+ $1 })); return b
    }
    let crypto = FileCrypto(key: Array(repeating:0x31,count:32), nonce:Array(repeating:0x42,count:16))
    let opus: [UInt8] = [0xfc,0xff,0xfe] + Array(repeating:0,count:157)
    func audio(_ seq: UInt32, _ flags: UInt8) throws -> [UInt8] {
        wire(0x1a,8,le32(seq) + [flags] + (try crypto.decode(opus,sequence:seq)) + [0])
    }
    var now = 1000.0, commands: [String] = [], sinks: [SoakQueueOutput] = []
    let p = Pilot(try PilotOptions(["workbench"]))
    p.nowOverride = { now }
    p.commandSink = { commands.append(requestName($0)) }
    p.outputFactory = { _ in let sink = SoakQueueOutput(); sinks.append(sink); return sink }
    p.workbenchOutputMode = .blackHole
    p.phase = "idleReady"; p.workbenchIdleVerified = true
    p.beginOwnedStart()
    try require(p.policy.maxFrames == nil && p.workbenchSessionLimitSeconds == nil && commands == ["start"], "continuous_preflight")
    try p.consumeNotification(wire(0x18,0x82,[1]))
    try p.consumeNotification(wire(0x1a,6,le32(123)))
    // The test supplies synthetic session crypto instead of a BLE handshake.
    p.headerSeen = true; p.fileCrypto = crypto; p.phase = "streaming"
    let output = sinks[0]
    let began = ProcessInfo.processInfo.systemUptime
    let before = OutputSnapshot.capture()
    var warmRSS = peakRSS()
    event("continuous_soak_started", ["wall_seconds":seconds,"hardware":false,"sink":"memory_pcm_queue","audio_saved":false])
    for i in 0..<(seconds * 50) {
        let due = began + Double(i) * 0.02
        let wait = due - ProcessInfo.processInfo.systemUptime
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        now = 1000 + ProcessInfo.processInfo.systemUptime - began
        p.tick()
        try require(p.firstFailure == nil && !p.stopSent, "unexpected_stop_before_frame")
        try autoreleasepool { try p.consumeNotification(audio(UInt32(i), i == 0 ? 2 : 0)) }
        output.consume()
        try require(p.phase == "recording" && p.stopAt == nil && p.policy.frames == i+1, "frame_or_duration_limit")
        if i == min(seconds * 50 - 1, 3000) { warmRSS = peakRSS() }
        if i > 0 && i % 3000 == 0 {
            event("continuous_soak_progress", ["elapsed_s":now-1000,"frames":p.policy.frames,"peak_rss_bytes":peakRSS(),
                "timing_retained":p.outputPushTimes.values.count,"tail_retained":p.tailTelemetry.recent.count])
        }
    }
    now = 1000 + ProcessInfo.processInfo.systemUptime - began
    try p.consumeNotification(audio(UInt32(seconds*50),4)); output.consume()
    let frames = p.policy.frames, tailFrames = p.tailTelemetry.frames
    let retained = p.outputPushTimes.values.count, growth = max(0,peakRSS()-warmRSS)
    try require(frames == seconds*50+1 && tailFrames == frames, "tail_statistics_truncated")
    try require(retained <= 2048 && p.interArrival.values.count <= 2048 && p.tailTelemetry.recent.count == min(32,frames), "unbounded_metadata")
    try require(output.queue.acceptedSamples == frames*960 && output.queue.renderedSamples == frames*960 && output.pending == 0, "pcm_accounting")
    try require(growth < 32*1024*1024, "memory_growth_over_32mb")
    p.requestStop()
    try require(commands.filter{$0=="stop"}.count == 1, "manual_stop_not_once")
    try p.consumeNotification(wire(0x18,0x82,[0]))
    var info = [UInt8](repeating:0,count:56)
    info.replaceSubrange(3..<8,with:Array("04.92".utf8))
    info.replaceSubrange(33..<38,with:Array("1.2.2".utf8))
    info.replaceSubrange(51..<56,with:Array("03.06".utf8))
    try p.consumeNotification(wire(1,1,info))
    try p.consumeNotification(wire(0x1a,0x0a,[0,0,0,0,0] + le32(123)))
    try require(p.policy.protocolAudioComplete, "synthetic_terminal_not_complete")
    now += 0.4; p.tick()
    try require(p.phase == "idleReady" && output.closed && !p.workbenchStopUnknown, "manual_stop_idle_or_close")
    p.beginOwnedStart()
    try require(p.outputPushTimes.values.isEmpty && p.interArrival.values.isEmpty && p.policy.frames == 0 && p.firstAt == nil, "new_session_not_reset")
    sinks.last?.close() // no device was started; only a command sink exists.
    event("continuous_soak_passed", ["wall_seconds":ProcessInfo.processInfo.systemUptime-began,"frames":frames,"tail_frames":tailFrames,
        "pcm_samples":frames*960,"peak_rss_growth_after_warmup_bytes":growth,"timing_retained":retained,
        "manual_stop_verified":true,"new_session_reset":true,"output_observation":before.comparison(OutputSnapshot.capture()),
        "hardware":false,"hal":false,"music_listening":"not_tested","audio_saved":false])
}
