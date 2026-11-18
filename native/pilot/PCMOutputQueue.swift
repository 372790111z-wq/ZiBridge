import Foundation

// Caller owns synchronization. Storage is fixed; rendering allocates no memory.
// Capacity is a safety limit, NOT a mandatory playout delay. Consume immediately.
struct PCMOutputQueue {
    static let sampleRate = 48000
    static let frameSamples = 960
    static let trialCapacityFrames = 48
    private var storage: [Float]
    private var readIndex=0,writeIndex=0
    private(set) var queued=0,peakSamples=0,acceptedSamples=0,renderedSamples=0
    private(set) var underflowSamples=0,clippedSamples=0
    var capacitySamples:Int {storage.count}
    var pendingFrames:Int {(queued+959)/960}
    init(capacityFrames:Int)throws {
        guard (1...48).contains(capacityFrames) else {throw ProbeError.invalid("output_capacity_invalid")}
        storage=[Float](repeating:0,count:capacityFrames*960)
    }
    mutating func enqueue(_ pcm:[Float])throws {
        guard pcm.count==960,pcm.allSatisfy({$0.isFinite}) else {throw ProbeError.invalid("output_invalid_pcm")}
        // Reject atomically: never partially overwrite or discard speech.
        guard queued+pcm.count<=storage.count else {throw ProbeError.invalid("audio_output_backlog")}
        for value in pcm {
            if abs(value)>1 {clippedSamples+=1}
            storage[writeIndex]=max(-1,min(1,value));writeIndex=(writeIndex+1)%storage.count
        }
        queued+=pcm.count;acceptedSamples+=pcm.count;peakSamples=max(peakSamples,queued)
    }
    mutating func renderStereo(into stereo:UnsafeMutablePointer<Float>,frames:Int) {
        guard frames>0 else{return}
        let n=min(frames,queued)
        for i in 0..<n {
            let value=storage[readIndex];readIndex=(readIndex+1)%storage.count
            stereo[i*2]=value;stereo[i*2+1]=value
        }
        for i in n..<frames {stereo[i*2]=0;stereo[i*2+1]=0}
        queued-=n;renderedSamples+=n
        if acceptedSamples>0 {underflowSamples+=frames-n}
    }
    mutating func clear(){queued=0;readIndex=0;writeIndex=0}
    var metrics:[String:Any] {
        ["capacity_frames":storage.count/960,"capacity_ms":Double(storage.count)/48,
         "queued_samples":queued,"queue_peak_samples":peakSamples,"queue_peak_ms":Double(peakSamples)/48,
         "accepted_samples":acceptedSamples,"rendered_samples":renderedSamples,
         "underflow_samples":underflowSamples,"clipped_samples":clippedSamples]
    }
}
