import Foundation
import CoreAudio

struct OutputSnapshot {
    let device:AudioDeviceID?
    let rate:Double?
    let volume:Float?
    let mute:UInt32?
    static func capture()->OutputSnapshot {
        let device=defaultOutput()
        func scalar<T>(_ selector:AudioObjectPropertySelector,_ scope:AudioObjectPropertyScope,_ initial:T)->T? {
            guard let device else{return nil}
            var a=AudioObjectPropertyAddress(mSelector:selector,mScope:scope,mElement:kAudioObjectPropertyElementMain)
            guard AudioObjectHasProperty(device,&a) else{return nil}
            var v=initial;var n=UInt32(MemoryLayout<T>.size)
            let status=withUnsafeMutablePointer(to:&v){ptr in AudioObjectGetPropertyData(device,&a,0,nil,&n,ptr)}
            return status==noErr && n==MemoryLayout<T>.size ? v:nil
        }
        return OutputSnapshot(device:device,
            rate:scalar(kAudioDevicePropertyNominalSampleRate,kAudioObjectPropertyScopeGlobal,Double(0)),
            volume:scalar(kAudioDevicePropertyVolumeScalar,kAudioDevicePropertyScopeOutput,Float(0)),
            mute:scalar(kAudioDevicePropertyMute,kAudioDevicePropertyScopeOutput,UInt32(0)))
    }
    func comparison(_ end:OutputSnapshot)->[String:Any] {
        func eq<T:Equatable>(_ a:T?,_ b:T?)->Any {guard let a,let b else{return "unknown"};return a==b}
        return ["device_unchanged":eq(device,end.device),"sample_rate_unchanged":eq(rate,end.rate),"volume_unchanged":eq(volume,end.volume),"mute_unchanged":eq(mute,end.mute),"listening_test":"requires_user_confirmation"]
    }
}
