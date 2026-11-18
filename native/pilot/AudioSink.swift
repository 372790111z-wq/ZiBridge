import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

struct AudioDeviceRow {
    let id: AudioDeviceID
    let uid: String
    let name: String
}
func audioString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var a = AudioObjectPropertyAddress(mSelector:selector,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
    let v = UnsafeMutablePointer<CFString?>.allocate(capacity:1);v.initialize(to:nil)
    defer { v.deinitialize(count:1);v.deallocate() }
    var n = UInt32(MemoryLayout<CFString?>.size)
    guard AudioObjectGetPropertyData(id,&a,0,nil,&n,v) == noErr else { return nil }
    return v.pointee as String?
}
func audioDevices() throws -> [AudioDeviceRow] {
    var a = AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDevices,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),&a,0,nil,&size) == noErr, size < 65536 else { throw ProbeError.invalid("audio_device_list") }
    var ids = [AudioDeviceID](repeating:0,count:Int(size)/MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&a,0,nil,&size,&ids) == noErr else { throw ProbeError.invalid("audio_device_list") }
    return ids.compactMap { id in
        guard let uid=audioString(id,kAudioDevicePropertyDeviceUID),let name=audioString(id,kAudioObjectPropertyName) else { return nil }
        return AudioDeviceRow(id:id,uid:uid,name:name)
    }
}
func defaultOutput() -> AudioDeviceID? {
    var a = AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDefaultOutputDevice,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
    var id: AudioDeviceID=0;var size=UInt32(MemoryLayout<AudioDeviceID>.size)
    return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&a,0,nil,&size,&id)==noErr ? id:nil
}

// Music playback is independent of the AUHAL device explicitly bound below.
// A transient missing default output must not invalidate a healthy bound sink.
// BlackHole becoming the default output is different: unrelated system sounds
// could then be mixed into the microphone, so fail closed in that case.
func validateIndependentOutputRoute(target:AudioDeviceID,bound:AudioDeviceID?,uid:String?,musicOutput:AudioDeviceID?) throws {
    guard let bound else {throw ProbeError.invalid("output_bound_device_query_failed")}
    guard bound==target else {throw ProbeError.invalid("output_bound_device_changed")}
    guard let uid else {throw ProbeError.invalid("output_bound_uid_query_failed")}
    guard uid=="BlackHole2ch_UID" else {throw ProbeError.invalid("output_bound_uid_changed")}
    guard musicOutput != target else {throw ProbeError.invalid("blackhole_became_system_default_output")}
}

protocol WorkbenchAudioOutput: AnyObject {
    var pending: Int { get }
    var queueMetrics:[String:Any] {get}
    func push(_ pcm: [Float]) throws
    func validateRoute() throws
    func close()
}
extension WorkbenchAudioOutput {var queueMetrics:[String:Any] {[:]}}
extension AudioSink: WorkbenchAudioOutput {}

// Output-only AUHAL bound before initialization. AVAudioEngine can stop when a
// separate BlackHole reader starts; a direct HAL render callback avoids that
// graph-reconfiguration lifecycle. No physical/default input is opened.
final class AudioSink {
    private var unit: AudioUnit?
    private let lock=NSLock()
    private var buffer:PCMOutputQueue
    private var stopped=false,started=false,renderError:OSStatus=noErr
    private var musicOutputChanged=false,defaultOutputReadUnavailable=false
    var clips:Int {lock.lock();defer{lock.unlock()};return buffer.clippedSamples}
    let initialOutput:AudioDeviceID?
    private let target:AudioDeviceID
    init(uid:String,capacityFrames:Int=8)throws {
        buffer=try PCMOutputQueue(capacityFrames:capacityFrames)
        let devices=try audioDevices()
        guard let d=devices.first(where:{$0.uid==uid}),d.name=="BlackHole 2ch" else {throw ProbeError.invalid("pilot_output_must_be_existing_blackhole_2ch")}
        target=d.id;initialOutput=defaultOutput()
        guard initialOutput != nil,initialOutput != target else {throw ProbeError.invalid("blackhole_is_system_default_output_refused")}
        var desc=AudioComponentDescription(componentType:kAudioUnitType_Output,componentSubType:kAudioUnitSubType_HALOutput,componentManufacturer:kAudioUnitManufacturer_Apple,componentFlags:0,componentFlagsMask:0)
        guard let component=AudioComponentFindNext(nil,&desc) else {throw ProbeError.invalid("output_hal_missing")}
        var created:AudioUnit?
        guard AudioComponentInstanceNew(component,&created)==noErr,let created else {throw ProbeError.invalid("output_hal_create")}
        unit=created
        do {
            var off:UInt32=0,on:UInt32=1,id=target
            guard AudioUnitSetProperty(created,kAudioOutputUnitProperty_EnableIO,kAudioUnitScope_Input,1,&off,4)==noErr,
                  AudioUnitSetProperty(created,kAudioOutputUnitProperty_EnableIO,kAudioUnitScope_Output,0,&on,4)==noErr,
                  AudioUnitSetProperty(created,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&id,4)==noErr else {throw ProbeError.invalid("output_hal_bind")}
            var hw=AudioStreamBasicDescription();var size=UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard AudioUnitGetProperty(created,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Output,0,&hw,&size)==noErr,
                  hw.mSampleRate==48000,hw.mChannelsPerFrame==2,hw.mFormatID==kAudioFormatLinearPCM,hw.mBitsPerChannel==32,hw.mFormatFlags & kAudioFormatFlagIsFloat != 0,hw.mBytesPerFrame==8 else {throw ProbeError.invalid("blackhole_output_requires_48khz_stereo_no_system_rate_changed")}
            var fmt=hw
            let formatStatus=AudioUnitSetProperty(created,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Input,0,&fmt,UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
            guard formatStatus==noErr else {throw ProbeError.invalid("output_hal_format_\(formatStatus)_hw_\(hw.mFormatFlags)_\(hw.mChannelsPerFrame)_\(hw.mBytesPerFrame)")}
            var cb=AURenderCallbackStruct(inputProc:{ ref,_,_,_,frames,data in
                Unmanaged<AudioSink>.fromOpaque(ref).takeUnretainedValue().render(frames:frames,data:data)
            },inputProcRefCon:Unmanaged.passUnretained(self).toOpaque())
            guard AudioUnitSetProperty(created,kAudioUnitProperty_SetRenderCallback,kAudioUnitScope_Input,0,&cb,UInt32(MemoryLayout<AURenderCallbackStruct>.size))==noErr,
                  AudioUnitInitialize(created)==noErr else {throw ProbeError.invalid("output_hal_initialize")}
            guard AudioOutputUnitStart(created)==noErr else {throw ProbeError.invalid("output_hal_start")}
            started=true
            try validateRoute()
        }catch{close();throw error}
    }
    func validateRoute()throws {
        guard let unit,!stopped,started else {throw ProbeError.invalid("output_hal_not_running")}
        let music=defaultOutput()
        lock.lock()
        if let music {if music != initialOutput {musicOutputChanged=true}}
        else {defaultOutputReadUnavailable=true}
        lock.unlock()
        var id:AudioDeviceID=0;var size:UInt32=4
        let status=AudioUnitGetProperty(unit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&id,&size)
        try validateIndependentOutputRoute(target:target,bound:status==noErr ? id:nil,
            uid:status==noErr ? audioString(id,kAudioDevicePropertyDeviceUID):nil,musicOutput:music)
        var a=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyDeviceIsAlive,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        var alive:UInt32=0;size=4
        guard AudioObjectGetPropertyData(id,&a,0,nil,&size,&alive)==noErr,alive != 0 else {throw ProbeError.invalid("output_device_not_alive")}
        var rate=Double(0);size=8;a.mSelector=kAudioDevicePropertyNominalSampleRate
        guard AudioObjectGetPropertyData(id,&a,0,nil,&size,&rate)==noErr,rate==48000 else {throw ProbeError.invalid("output_sample_rate_changed")}
        lock.lock();let error=renderError;lock.unlock()
        guard error==noErr else {throw ProbeError.invalid("output_hal_render_failed")}
    }
    func push(_ pcm:[Float])throws {
        guard pcm.count==960,pcm.allSatisfy({$0.isFinite}) else {throw ProbeError.invalid("output_invalid_pcm")}
        try validateRoute()
        lock.lock();defer{lock.unlock()}
        guard !stopped else {throw ProbeError.invalid("output_closed")}
        try buffer.enqueue(pcm)
    }
    private func render(frames:UInt32,data:UnsafeMutablePointer<AudioBufferList>?)->OSStatus {
        guard let data else {return kAudio_ParamError}
        let buffers=UnsafeMutableAudioBufferListPointer(data)
        for b in buffers {if let p=b.mData {memset(p,0,Int(b.mDataByteSize))}}
        lock.lock();defer{lock.unlock()}
        guard buffers.count==1,buffers[0].mNumberChannels==2,buffers[0].mData != nil,buffers[0].mDataByteSize>=frames*8 else {renderError=kAudio_ParamError;return kAudio_ParamError}
        guard !stopped else {return noErr}
        let stereo=buffers[0].mData!.assumingMemoryBound(to:Float.self)
        buffer.renderStereo(into:stereo,frames:Int(frames))
        return noErr
    }
    var pending:Int {lock.lock();defer{lock.unlock()};return buffer.pendingFrames}
    var peakPending:Int {lock.lock();defer{lock.unlock()};return (buffer.peakSamples+959)/960}
    var queueMetrics:[String:Any] {
        lock.lock();defer{lock.unlock()}
        var result=buffer.metrics
        result["music_output_changed"]=musicOutputChanged
        result["default_output_read_unavailable"]=defaultOutputReadUnavailable
        return result
    }
    func close(){
        lock.lock();stopped=true;buffer.clear();lock.unlock()
        if let unit {if started {AudioOutputUnitStop(unit)};AudioUnitUninitialize(unit);AudioComponentInstanceDispose(unit);self.unit=nil;started=false}
    }
    deinit{close()}
}
