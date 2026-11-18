import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio

// HAL-only loopback verification for the explicit experimental system-microphone
// path. Input is an AUHAL input unit bound to BlackHole BEFORE initialization, so
// AVAudioEngine.inputNode is never touched and no default/Bluetooth mic is opened.
// Output reuses the existing AudioSink (output-only AVAudioEngine bound to the same
// BlackHole). Nothing is persisted; the generated public tone is memory-only.

private func deviceRunningSomewhere(_ id: AudioDeviceID) -> Bool? {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                       mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectHasProperty(id, &a) else { return nil }
    var value: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr else { return nil }
    return value != 0
}

private final class HALInputCapture {
    private var unit: AudioUnit?
    private let format: AVAudioFormat
    private let buffer: AVAudioPCMBuffer
    private let lock = NSLock()
    private var samples: [Float] = []
    private let sampleLimit: Int
    private var running = false

    init(deviceID: AudioDeviceID, seconds: Double) throws {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                                   componentSubType: kAudioUnitSubType_HALOutput,
                                                   componentManufacturer: kAudioUnitManufacturer_Apple,
                                                   componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw ProbeError.invalid("loopback_hal_component_missing")
        }
        var instance: AudioUnit?
        guard AudioComponentInstanceNew(component, &instance) == noErr, let instance else {
            throw ProbeError.invalid("loopback_hal_instance")
        }
        unit = instance
        do {
            var enable: UInt32 = 1, disable: UInt32 = 0, selected = deviceID
            guard AudioUnitSetProperty(instance, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, 4) == noErr,
                  AudioUnitSetProperty(instance, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable, 4) == noErr,
                  AudioUnitSetProperty(instance, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &selected, 4) == noErr else {
                throw ProbeError.invalid("loopback_bind_before_init")
            }
            var hardware = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard AudioUnitGetProperty(instance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size) == noErr,
                  hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0,
                  let client = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardware.mSampleRate,
                                             channels: hardware.mChannelsPerFrame, interleaved: false) else {
                throw ProbeError.invalid("loopback_input_format")
            }
            format = client
            var stream = client.streamDescription.pointee
            guard AudioUnitSetProperty(instance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                                       &stream, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr else {
                throw ProbeError.invalid("loopback_client_format")
            }
            var capacity: UInt32 = 0; size = 4
            guard AudioUnitGetProperty(instance, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                                       &capacity, &size) == noErr, capacity > 0,
                  let allocated = AVAudioPCMBuffer(pcmFormat: client, frameCapacity: capacity) else {
                throw ProbeError.invalid("loopback_input_buffer")
            }
            buffer = allocated
            sampleLimit = Int(hardware.mSampleRate * seconds)
            samples.reserveCapacity(sampleLimit)
            var callback = AURenderCallbackStruct(inputProc: { ref, flags, time, _, frames, _ in
                let capture = Unmanaged<HALInputCapture>.fromOpaque(ref).takeUnretainedValue()
                return capture.receive(flags: flags, time: time, frames: frames)
            }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            guard AudioUnitSetProperty(instance, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                       &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr else {
                throw ProbeError.invalid("loopback_input_callback")
            }
        } catch {
            AudioComponentInstanceDispose(instance); unit = nil; throw error
        }
    }

    deinit { close() }

    func start() throws {
        guard let unit, !running else { throw ProbeError.invalid("loopback_input_state") }
        guard AudioUnitInitialize(unit) == noErr else { throw ProbeError.invalid("loopback_input_initialize") }
        guard AudioOutputUnitStart(unit) == noErr else {
            AudioUnitUninitialize(unit); throw ProbeError.invalid("loopback_input_start")
        }
        running = true
    }

    func close() {
        if let unit {
            if running { AudioOutputUnitStop(unit); AudioUnitUninitialize(unit); running = false }
            AudioComponentInstanceDispose(unit); self.unit = nil
        }
    }

    var captured: [Float] {
        lock.lock(); defer { lock.unlock() }; return samples
    }

    var captureRate: Double { format.sampleRate }

    var boundDeviceID: AudioDeviceID? {
        guard let unit else { return nil }
        var value: AudioDeviceID = 0; var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &value, &size) == noErr ? value : nil
    }

    private func receive(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, time: UnsafePointer<AudioTimeStamp>, frames: UInt32) -> OSStatus {
        guard let unit else { return noErr }
        guard frames <= buffer.frameCapacity else { return kAudioUnitErr_TooManyFramesToProcess }
        buffer.frameLength = frames
        let status = AudioUnitRender(unit, flags, time, 1, frames, buffer.mutableAudioBufferList)
        guard status == noErr, let channel = buffer.floatChannelData?[0] else { return status }
        lock.lock()
        if samples.count < sampleLimit {
            let room = min(Int(frames), sampleLimit - samples.count)
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: room))
        }
        lock.unlock()
        return noErr
    }
}

// Short deterministic linear chirp: far less periodic ambiguity than a single
// tone. It verifies the path only; it is not an acoustic-latency measurement.
private func generatedChirp(rate: Double, seconds: Double, from: Double = 300, to: Double = 800) -> [Float] {
    let count = Int(rate * seconds)
    var phase = 0.0
    return (0..<count).map { index in
        let t = count > 1 ? Double(index) / Double(count - 1) : 0
        let frequency = from + (to - from) * t
        phase += 2 * Double.pi * frequency / rate
        return Float(0.2 * sin(phase))
    }
}

private func resampleTo48k(_ samples: [Float], from rate: Double) -> [Float] {
    guard rate > 0, rate != 48000, !samples.isEmpty else { return samples }
    let ratio = 48000.0 / rate
    let count = Int(Double(samples.count) * ratio)
    return (0..<count).map { index in
        let position = Double(index) / ratio
        let base = Int(position)
        let fraction = position - Double(base)
        let a = samples[min(base, samples.count - 1)]
        let b = samples[min(base + 1, samples.count - 1)]
        return a + (b - a) * Float(fraction)
    }
}

private func bestCorrelation(capture: [Float], tone: [Float], maxLag: Int) -> (correlation: Double, lag: Int) {
    guard !capture.isEmpty, !tone.isEmpty else { return (0, 0) }
    var best = (0.0, 0)
    var toneEnergy = 0.0
    for v in tone { toneEnergy += Double(v * v) }
    guard toneEnergy > 0 else { return (0, 0) }
    for lag in 0...max(0, maxLag) where lag + tone.count <= capture.count {
        var dot = 0.0, energy = 0.0
        for i in 0..<tone.count {
            let c = Double(capture[lag + i]); dot += c * Double(tone[i]); energy += c * c
        }
        guard energy > 1e-9 else { continue }
        let corr = dot / (toneEnergy * energy).squareRoot()
        if abs(corr) > abs(best.0) { best = (corr, lag) }
    }
    return best
}

// Explicit command: no BLE, no default route writes, no persistence. Refuses when
// BlackHole is the default output or already in use by another producer.
func runHALLoopbackSmoke() -> Int32 {
    do {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .authorized else {
            event("loopback_not_run", ["reason": "microphone_permission_not_authorized",
                                       "authorization": status == .notDetermined ? "not_determined" : (status == .denied ? "denied" : "restricted"),
                                       "note": "工具不会请求权限；授权后由用户显式再运行"])
            return 3
        }
        let devices = try audioDevices()
        guard let blackhole = devices.first(where: { $0.uid == "BlackHole2ch_UID" && $0.name == "BlackHole 2ch" }) else {
            event("loopback_refused", ["reason": "blackhole_missing"]); return 4
        }
        guard defaultOutput() != blackhole.id else {
            event("loopback_refused", ["reason": "blackhole_is_default_output"]); return 4
        }
        guard let running = deviceRunningSomewhere(blackhole.id) else {
            event("loopback_refused", ["reason": "blackhole_running_state_unknown"]); return 4
        }
        guard !running else {
            event("loopback_refused", ["reason": "blackhole_already_running_somewhere"]); return 4
        }
        let initialDefault = defaultOutput()
        let musicBefore=OutputSnapshot.capture()
        let outputRate = 48000.0
        let chirp = generatedChirp(rate: outputRate, seconds: 0.4)
        let input = try HALInputCapture(deviceID: blackhole.id, seconds: 1.6)
        let sink = try AudioSink(uid: "BlackHole2ch_UID")
        defer { input.close(); sink.close() }
        guard input.boundDeviceID == blackhole.id else {
            event("loopback_refused", ["reason": "input_not_bound_to_blackhole"]); return 4
        }
        try input.start()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        var offset = 0
        let feedDeadline=Date().addingTimeInterval(2)
        while offset < chirp.count {
            while sink.pending>=4 {
                guard Date()<feedDeadline else {throw ProbeError.invalid("loopback_feed_timeout")}
                RunLoop.current.run(until:Date().addingTimeInterval(0.002))
            }
            let n = min(960, chirp.count - offset)
            var chunk = Array(chirp[offset..<(offset + n)])
            if chunk.count < 960 { chunk += [Float](repeating: 0, count: 960 - chunk.count) }
            do { try sink.push(chunk) } catch {
                let got = input.captured
                event("loopback_output_diagnostic", ["captured_samples":got.count,
                    "peak":got.map{abs($0)}.max() ?? 0,"pending":sink.pending,
                    "rate":input.captureRate])
                throw error
            }
            offset += n
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.7))
        sink.close()
        RunLoop.current.run(until:Date().addingTimeInterval(0.15))
        let captured = input.captured
        let inputRate = input.captureRate
        guard inputRate > 0 else {
            event("loopback_refused", ["reason": "input_rate_unavailable"]); return 4
        }
        // Never pretend a hardware-rate capture is 48 kHz. Resampling is only for the
        // path correlation; no latency claim is made from it.
        guard captured.allSatisfy({$0.isFinite}) else { throw ProbeError.invalid("loopback_nonfinite_capture") }
        input.close(); sink.close()
        let capture = resampleTo48k(captured, from: inputRate)
        let best = bestCorrelation(capture: capture, tone: chirp, maxLag: Int(outputRate * 0.4))
        var peak: Float = 0, energy = 0.0
        for v in capture { peak = max(peak, abs(v)); energy += Double(v * v) }
        let rms = capture.isEmpty ? 0 : (energy / Double(capture.count)).squareRoot()
        let routeUnchanged = defaultOutput() == initialDefault
        let stoppedPeak=capture.suffix(2400).map{abs($0)}.max() ?? 1
        let passed = best.correlation >= 0.99 && peak > 0.005 && routeUnchanged && stoppedPeak<0.0001
        event("loopback_result", ["passed": passed, "path_verified": passed,
                                  "captured_samples": captured.count,
                                  "capture_rate_hz": inputRate,
                                  "resampled_for_path_check": inputRate != 48000,
                                  "peak_abs": peak, "rms": rms, "stopped_tail_peak":stoppedPeak,
                                  "music_output_observation":musicBefore.comparison(OutputSnapshot.capture()),
                                  "correlation_chirp": best.correlation,
                                  "correlation_lag_samples_uncalibrated": best.lag,
                                  "latency_claim": "none_path_only",
                                  "default_output_unchanged": routeUnchanged,
                                  "explicit_blackhole_input_output_only": true,
                                  "audio_persisted": false,
                                  "music_or_default_route_written": false])
        return passed ? 0 : 5
    } catch {
        event("loopback_failed", ["reason": (error as? ProbeError)?.description ?? "loopback_error"])
        return 2
    }
}

// Replays ONLY public timing offsets, never source audio. Positive uniquely
// sequenced frame values allow exact sample-count/order checks after removing
// driver silence. No device recording, no ASR, and no audio files are created.
func runHALBurstSmoke(timingPath:String)->Int32 {
    do {
        guard AVCaptureDevice.authorizationStatus(for:.audio) == .authorized else {throw ProbeError.invalid("microphone_permission_not_authorized")}
        let data=try Data(contentsOf:URL(fileURLWithPath:timingPath))
        guard data.count<65536,let offsets=try JSONSerialization.jsonObject(with:data) as? [Double],
              !offsets.isEmpty,offsets.count<=500,offsets[0]==0,
              offsets.allSatisfy({$0.isFinite && $0>=0 && $0<=10}),
              zip(offsets,offsets.dropFirst()).allSatisfy({$0.0 <= $0.1}) else {throw ProbeError.invalid("invalid_public_timing")}
        guard let target=try audioDevices().first(where:{$0.uid=="BlackHole2ch_UID" && $0.name=="BlackHole 2ch"}),
              defaultOutput() != target.id,deviceRunningSomewhere(target.id)==false else {throw ProbeError.invalid("blackhole_busy_or_unavailable")}
        let before=OutputSnapshot.capture()
        let input=try HALInputCapture(deviceID:target.id,seconds:13)
        let output=try AudioSink(uid:"BlackHole2ch_UID",capacityFrames:PCMOutputQueue.trialCapacityFrames)
        defer{input.close();output.close()}
        guard input.captureRate==48000 else {throw ProbeError.invalid("burst_exact_check_requires_48k")}
        try input.start()
        RunLoop.current.run(until:Date().addingTimeInterval(0.1))
        let start=ProcessInfo.processInfo.systemUptime
        for (index,offset) in offsets.enumerated() {
            let due=start+offset
            while ProcessInfo.processInfo.systemUptime<due {RunLoop.current.run(until:Date().addingTimeInterval(0.001))}
            let value=Float(index%100+1)/200
            try output.push([Float](repeating:value,count:960))
        }
        let deadline=ProcessInfo.processInfo.systemUptime+1
        while output.pending>0 && ProcessInfo.processInfo.systemUptime<deadline {
            RunLoop.current.run(until:Date().addingTimeInterval(0.002))
        }
        let metrics=output.queueMetrics
        guard output.pending==0 else {throw ProbeError.invalid("burst_output_not_drained")}
        output.close()
        RunLoop.current.run(until:Date().addingTimeInterval(0.2))
        let captured=input.captured;input.close()
        guard captured.allSatisfy({$0.isFinite}) else {throw ProbeError.invalid("burst_capture_invalid")}
        let signal=captured.filter{abs($0)>0.001}
        var exact=signal.count==offsets.count*960
        if exact {for i in signal.indices {if signal[i] != Float((i/960)%100+1)/200 {exact=false;break}}}
        let stopPeak=captured.suffix(2400).map{abs($0)}.max() ?? 1
        let unchanged=defaultOutput()==before.device
        event("burst_loopback_result",["passed":exact && stopPeak==0 && unchanged,
              "frames":offsets.count,"expected_samples":offsets.count*960,"received_signal_samples":signal.count,
              "exact_sample_order":exact,"stopped_peak":stopPeak,"output_queue":metrics,
              "music_output_observation":before.comparison(OutputSnapshot.capture()),
              "audio_saved":false,"device_recording":false,"source_audio_used":false,
              "latency_acceptance":"not_measured"])
        return exact && stopPeak==0 && unchanged ? 0:5
    }catch{event("burst_loopback_failed",["reason":(error as? ProbeError)?.description ?? "burst_io_error"]);return 2}
}
