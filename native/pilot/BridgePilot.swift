import Foundation
import CoreBluetooth
import Darwin
import CoreAudio
import AppKit

private let service=CBUUID(string:"020CF5DA-0000-1000-8000-00805F9B34FB")
private let writeCharacteristic=CBUUID(string:"00007777-0000-1000-8000-00805F9B34FB")
private let notifyCharacteristic=CBUUID(string:"00008888-0000-1000-8000-00805F9B34FB")
enum WorkbenchOutputMode: String { case meterOnly = "meter_only", blackHole = "black_hole" }
func event(_ name:String,_ fields:[String:Any]=[:]) {
    var record=fields;record["event"]=name;record["monotonic_s"]=ProcessInfo.processInfo.systemUptime
    if let data=try? JSONSerialization.data(withJSONObject:record,options:.sortedKeys),let s=String(data:data,encoding:.utf8){print(s);fflush(stdout)}
}
struct PilotOptions {
    let inspectOnly:Bool
    let earlyDelay:Double
    let earlyLive:Bool
    let device:UUID?
    let output:String?
    let seconds:Double
    let workbench:Bool
    var connectKnown = false
    var speechTest = false
    var capturePath:String?
    var comparisonPath:String?
    // Opt-in stop-ordering probe (default nil = off). Narrow bounded window.
    var pauseBeforeStopMs:Int?
    init(_ args:[String]) throws {
        if args == ["workbench"] {inspectOnly=false;earlyDelay=0;earlyLive=false;device=nil;output=nil;seconds=15;workbench=true;return}
        if args == ["scan"] {inspectOnly=false;earlyDelay=0;earlyLive=false;device=nil;output=nil;seconds=0;workbench=false;return}
        if args.count==3,args[0]=="inspect",args[1]=="--device",let id=UUID(uuidString:args[2]) {inspectOnly=true;earlyDelay=0;earlyLive=false;device=id;output=nil;seconds=0;workbench=false;return}
        guard args.count>=6,args[0]=="live-pilot",args[1]=="--device",let id=UUID(uuidString:args[2]),args[3]=="--seconds",let seconds=Double(args[4]),seconds.isFinite,(3...15).contains(seconds),args[5]=="--public-session" else {throw ProbeError.invalid("usage_live_pilot_device_seconds_public_session")}
        var early=false,delay:Double?,uid:String?,pauseMs:Int?,i=6
        while i<args.count {
            if args[i]=="--connect-known",!connectKnown {connectKnown=true;i+=1}
            else if args[i]=="--early-live",!early {early=true;i+=1}
            else if args[i]=="--early-live-delay-ms",delay==nil,i+1<args.count,let ms=Double(args[i+1]),ms.isFinite,(0...750).contains(ms) {delay=ms/1000;i+=2}
            else if args[i]=="--output-uid",uid==nil,i+1<args.count,!args[i+1].isEmpty,!args[i+1].hasPrefix("--") {uid=args[i+1];i+=2}
            else if args[i]=="--ready-speech-test",!speechTest {speechTest=true;i+=1}
            else if args[i]=="--capture-wav",capturePath==nil,i+1<args.count,args[i+1].hasPrefix("/"),args[i+1].hasSuffix(".wav") {capturePath=args[i+1];i+=2}
            else if args[i]=="--compare-device-wav",comparisonPath==nil,i+1<args.count,args[i+1].hasPrefix("/"),args[i+1].hasSuffix(".wav") {comparisonPath=args[i+1];i+=2}
            else if args[i]=="--pause-before-stop-ms",pauseMs==nil,i+1<args.count,args[i+1].allSatisfy({$0.isNumber}),let ms=Int(args[i+1]),(PauseStopSequencer.minWindowMs...PauseStopSequencer.maxWindowMs).contains(ms) {pauseMs=ms;i+=2}
            else {throw ProbeError.invalid("unknown_or_duplicate_option")}
        }
        guard !connectKnown || !early else {throw ProbeError.invalid("known_connect_no_early_experiment")}
        guard !(early && uid != nil),delay==nil || early else {throw ProbeError.invalid("early_pilot_meter_only_until_validated")}
        guard (!speechTest || (!early && uid == nil)),capturePath == nil || speechTest else {throw ProbeError.invalid("speech_test_isolated_capture_only")}
        guard comparisonPath == nil || (speechTest && capturePath != nil && comparisonPath != capturePath && !early && uid == nil) else {throw ProbeError.invalid("comparison_requires_isolated_two_wav_trial")}
        guard pauseMs == nil || !early else {throw ProbeError.invalid("pause_experiment_not_with_early_live")}
        guard pauseMs == nil || uid == nil else {throw ProbeError.invalid("pause_experiment_not_with_system_output")}
        inspectOnly=false;earlyDelay=delay ?? 0;earlyLive=early;device=id;output=uid;self.seconds=seconds;workbench=false;pauseBeforeStopMs=pauseMs
    }
}
final class Pilot:NSObject,CBCentralManagerDelegate,CBPeripheralDelegate {
    // Pure routing decision for fail(): which safe shutdown path applies.
    // state == .ended means idle was verified, so the stop IS confirmed and the
    // "stop_unconfirmed_check_device" prompt would be factually wrong there.
    enum FailureFinish { case awaitNewSession,requestStop,confirmedStop,stopUnconfirmed,checkIndicator }
    static func failureRoute(ownsStart:Bool,hasFile:Bool,stopSent:Bool,state:PilotPolicy.State)->FailureFinish {
        if ownsStart,!hasFile {return .awaitNewSession}
        if ownsStart,hasFile,!stopSent {return .requestStop}
        if state == .ended {return .confirmedStop}
        return stopSent ? .stopUnconfirmed : .checkIndicator
    }
    let options:PilotOptions
    var manager:CBCentralManager!,peripheral:CBPeripheral?,writer:CBCharacteristic?
    var assembly=Assembler(),policy=PilotPolicy(),crypto=SessionCrypto(),fileCrypto:FileCrypto?,decoder:LiveOpus?,sink:AudioSink?
    var earlyBuffer=EarlyLiveBuffer(),earlyRequested=false,awaitingOwnedStop=false
    var headDiagnostics=HeadDiagnostics()
    var speechTrial=SpeechTrial(),trialWindow:SpeechTrialWindow?,trialWAV:TrialWAV?
    var stopVerification=StopIdleVerification()
    var preparation=PreparationTiming(),connectionRoute="not_started"
    var tailTelemetry=TailTelemetry()
    var comparison=DeviceComparison(),comparisonWAV:TrialWAV?,comparisonCrypto:FileCrypto?,comparisonDecoder:LiveOpus?
    var comparisonDeadline:Double?,liveFinishedAt:Double?,liveFinishReason:String?,liveFinishCode:Int32?
    var earlyDue:Double?,firstFailure:String?
    // Post-failure/awaiting-stop audio is discarded by policy (never decoded or
    // retained). It must still be COUNTED: the early zero-ID logs drew the
    // "no audio followed" conclusion while this discard was silent, which the
    // fixed sources later showed to be unprovable from those logs.
    var postFailureAudioNotifications=0,postFailureAudioFrames=0
    // Opt-in pause-first stop probe. Counters are observations only (late slices seen
    // while the device is paused); they never promote audio_complete.
    var pauseStop=PauseStopSequencer(),pauseFrames=0,pauseFirstSeq:UInt32?,pauseLastSeq:UInt32?
    // Last unknown-layout verify reply (length and state code only; never the body).
    var stopInfoUnknownBytes=0,stopInfoUnknownState:Int?
    // Workbench (GUI) state: only used when options.workbench. Connection alone never
    // starts capture; every session rechecks firmware/idle; the UI polls this state.
    var selectedDevice:UUID?,candidates:[(id:UUID,rssi:Int)]=[],discovered:[UUID:CBPeripheral]=[:]
    var onUpdate:(()->Void)?
    var lastRms:Double=0,workbenchNotice:String?,workbenchError:String?,workbenchDeviceIdle=false
    var manualStartPending=false,workbenchStaleAudio=0
    var workbenchIdleVerified=false,workbenchDisconnectPending=false,workbenchDisconnectCompletion:((Bool)->Void)?
    var workbenchGeneration=0
    var workbenchStopUnknown=false
    var workbenchFailurePhase:String?
    var workbenchOutputFrames=0,workbenchOutputPeak=0
    var workbenchLastDiagnostic=""
    var workbenchQueueMetrics:[String:Any]=[:]
    var decoderFactory:(()->LiveOpus?)?
    var workbenchOutputMode:WorkbenchOutputMode = .meterOnly
    var audioOutput: WorkbenchAudioOutput?
    var outputFactory: ((String) throws -> WorkbenchAudioOutput)?
    var workbenchSessionDefaultOutput: AudioDeviceID?
    var workbenchSessionLimitSeconds: Double? = 15
    var workbenchModeLocked: Bool {
        workbenchSessionActive || workbenchDisconnectPending
            || ["idleCheck","connecting","services","characteristics","notify","info","key","awaiting_owned_stop"].contains(phase)
    }
    struct WorkbenchAudioAvailability {
        let blackHoleAvailable: Bool
        let blackHoleIsDefaultOutput: Bool
        let defaultOutputName: String?
        let summary: String
    }
    var workbenchAudioCache:(at:Double,value:WorkbenchAudioAvailability)?
    func workbenchAudioAvailability() -> WorkbenchAudioAvailability {
        if let cached=workbenchAudioCache,now-cached.at<1 {return cached.value}
        let devices = (try? audioDevices()) ?? []
        let bh = devices.first { $0.uid == "BlackHole2ch_UID" && $0.name == "BlackHole 2ch" }
        let out = defaultOutput()
        let outName = devices.first { $0.id == out }?.name
        let bhIsOut = bh != nil && out == bh!.id
        let available = bh != nil && !bhIsOut
        let state = available ? "可用" : (bh == nil ? "未找到" : "是默认输出，预检会拒绝")
        let summary = "BlackHole 2ch：\(state) · 默认输出：\(outName ?? "未知")（不修改） · 队列写入≠客户已接收"
        let value=WorkbenchAudioAvailability(blackHoleAvailable: available, blackHoleIsDefaultOutput: bhIsOut,
                                          defaultOutputName: outName, summary: summary)
        workbenchAudioCache=(now,value);return value
    }
    func setWorkbenchOutputMode(_ mode: WorkbenchOutputMode) {
        guard options.workbench, !workbenchModeLocked else { return }
        workbenchOutputMode = mode; onUpdate?()
    }
    // Tests drive the controller with a command sink instead of a real peripheral.
    var workbenchLinkReady:Bool {peripheral != nil || commandSink != nil}
    // Deterministic fixture seams (production keeps both nil).
    var nowOverride:(()->Double)?
    var commandSink:((Request)throws->Void)?
    var failureCapture:((String)->Void)?
    var startAckAt:Double?,newFileAt:Double?,stopSentAt:Double?,terminalAt:Double?
    var phase="scan",seen=Set<UUID>(),finished=false,infoReads=0,headerSeen=false,stopSent=false
    var deadline=Double(0),hardDeadline=Double(0),stopAt:Double?,startSentAt:Double?,streamSentAt:Double?,firstAt:Double?,lastAudioAt:Double?,idleVerifiedAt:Double?
    var interArrival=RecentTimingSamples(),firstBatchFrames=0,outputPushTimes=RecentTimingSamples()
    var reason="pilot_finished",exitStatus:Int32=0,initialOutput:AudioDeviceID?, outputBefore:OutputSnapshot?
    var timer:DispatchSourceTimer?,signals=[DispatchSourceSignal]()
    var now:Double{nowOverride?() ?? ProcessInfo.processInfo.systemUptime}
    // Workbench session is active only while this process owns a start or a just
    // finished stop is being verified/drained. Idle connection is NOT a session.
    var workbenchSessionActive:Bool {policy.ownsStart || policy.file != nil || ["starting","head","streaming","recording","stopping","verify","pausing","awaiting_owned_stop"].contains(phase)}
    // Transient connection/handshake phases must not hang forever; scan and verified
    // idle are intentionally persistent.
    var workbenchCanRefresh:Bool {workbenchLinkReady && ["idleReady","idleBusy","idleTimeout"].contains(phase) && !workbenchDisconnectPending}
    var workbenchBoundedPhase:Bool {workbenchSessionActive || ["connecting","services","characteristics","notify","info","key"].contains(phase)}
    func selectDevice(_ id:UUID){
        guard options.workbench,peripheral==nil,phase=="scan",let p=discovered[id] else{return}
        selectedDevice=id;connectSelected(p,using:manager,route:"workbench_select")
    }
    func rescanWorkbench(){
        guard options.workbench else{return}
        guard !workbenchSessionActive,!workbenchDisconnectPending else{
            workbenchNotice="正在收音或停止核验中，不能重新扫描。";onUpdate?();return
        }
        workbenchGeneration+=1
        if let p=peripheral{manager?.cancelPeripheralConnection(p)}
        peripheral=nil;writer=nil;crypto=SessionCrypto();selectedDevice=nil;candidates.removeAll();discovered.removeAll()
        audioOutput?.close();audioOutput=nil;workbenchSessionDefaultOutput=nil;workbenchSessionLimitSeconds=15
        workbenchError=nil;workbenchNotice=nil;workbenchDeviceIdle=false;workbenchIdleVerified=false;manualStartPending=false;phase="scan";deadline=now+3600
        onUpdate?();manager?.scanForPeripherals(withServices:[service],options:[CBCentralManagerScanOptionAllowDuplicatesKey:false])
    }
    func startManualTest(){
        guard options.workbench,workbenchLinkReady,(phase=="idleReady"||phase=="idleBusy"),!policy.ownsStart,
              workbenchIdleVerified,decoder != nil else{return}
        manualStartPending=true;workbenchError=nil
        do{phase="idleCheck";deadline=now+5;try write(.info);event("workbench_idle_recheck",["reason":"manual_start"])}
        catch{manualStartPending=false;phase="idleReady";workbenchError="无法发送空闲检查：\((error as? ProbeError)?.description ?? "write_failed")"}
        onUpdate?()
    }
    func refreshIdleWorkbench(){
        guard options.workbench,workbenchCanRefresh else{return}
        manualStartPending=false
        do{phase="idleCheck";deadline=now+5;try write(.info)}catch{workbenchError="无法发送空闲检查"}
        onUpdate?()
    }
    func beginOwnedStart(){
        if options.workbench{
            workbenchFailurePhase=nil;workbenchOutputFrames=0;workbenchOutputPeak=0;workbenchLastDiagnostic="";workbenchQueueMetrics=[:]
            interArrival=RecentTimingSamples();outputPushTimes=RecentTimingSamples();firstBatchFrames=0
            decoder = decoderFactory.map{$0()} ?? (try? LiveOpus())
            guard decoder != nil else{
                workbenchError="音频解码器不可用（现有libopus校验失败）；本次不会开始。"
                phase="idleReady";onUpdate?();return
            }
            // Fresh output preflight BEFORE the BLE start command. Meter-only never
            // creates an output. A failed preflight must not start the device.
            audioOutput?.close();audioOutput=nil
            if workbenchOutputMode == .blackHole {
                let initial=defaultOutput()
                guard initial != nil else{
                    workbenchError="系统麦克风预检失败：无法读取当前默认输出。"
                    phase="idleReady";onUpdate?();return
                }
                do{
                    let make=outputFactory ?? { try AudioSink(uid:$0,capacityFrames:PCMOutputQueue.trialCapacityFrames) }
                    audioOutput=try make("BlackHole2ch_UID")
                }catch{
                    workbenchError="系统麦克风预检失败：\((error as? ProbeError)?.description ?? "output_unavailable")；本次不会开始。"
                    phase="idleReady";onUpdate?();return
                }
                workbenchSessionDefaultOutput=initial
                workbenchSessionLimitSeconds=nil
                policy=PilotPolicy(maxFrames:nil)
                event("workbench_system_output_preflight",["target":"BlackHole 2ch","uid":"BlackHole2ch_UID","queue_is_not_consumer_receipt":true,"max_session_s":NSNull(),"frame_budget":NSNull(),"wire_sequence_max":Int(PilotPolicy.maxSequence),"output_capacity_ms":960,"latency_acceptance":"not_passed"])
            }else{
                workbenchSessionDefaultOutput=nil
                workbenchSessionLimitSeconds=options.seconds
                policy=PilotPolicy(maxFrames:1500)
            }
        }
        workbenchIdleVerified=false
        do{try policy.start(firmwareOK:true,idle:true);phase="starting";startSentAt=now;preparation.mark(.startRequested,at:startSentAt!)
           deadline=now+3;try write(.startOwned);event("owned_start_sent",["do_not_speak_until_live_notice":true,"workbench":options.workbench])}
        catch{fail((error as? ProbeError)?.description ?? "start_failed")}
    }
    func disconnectWorkbench(completion:((Bool)->Void)?=nil){
        guard options.workbench else{completion?(false);return}
        if workbenchDisconnectPending{if let completion{workbenchDisconnectCompletion=completion};return}
        workbenchDisconnectPending=true;workbenchDisconnectCompletion=completion
        workbenchIdleVerified=false;manualStartPending=false
        if !workbenchSessionActive,policy.file==nil{
            forceDisconnectIfPending(generation:workbenchGeneration,reason:"idle_disconnect",deviceStateUnknown:workbenchStopUnknown)
            return
        }
        if policy.ownsStart,!stopSent{
            if policy.file != nil{requestStop()}
            else{
                // Start was sent but no owned file id yet: wait for the owned session
                // (bounded), then stop it before disconnecting. Never drop the device
                // silently while our start may still be taking effect.
                awaitingOwnedStop=true;phase="awaiting_owned_stop";deadline=now+3
                event("workbench_waiting_for_owned_session_before_disconnect")
            }
        }
        let gen=workbenchGeneration
        DispatchQueue.main.asyncAfter(deadline:.now()+6){[weak self] in
            self?.forceDisconnectIfPending(generation:gen,reason:"disconnect_timeout_device_state_unknown")
        }
    }
    func forceDisconnectIfPending(generation:Int,reason:String,deviceStateUnknown:Bool?=nil){
        guard options.workbench,workbenchDisconnectPending,generation==workbenchGeneration else{return}
        let unknown=workbenchStopUnknown || (deviceStateUnknown ?? ((policy.ownsStart || policy.file != nil) && policy.state != .ended))
        workbenchStopUnknown=unknown
        audioOutput?.close();audioOutput=nil;workbenchSessionDefaultOutput=nil;workbenchSessionLimitSeconds=15
        workbenchGeneration+=1 // invalidate any delayed callback from this disconnect
        if let p=peripheral{manager?.cancelPeripheralConnection(p)}
        peripheral=nil;writer=nil;phase="disconnected";workbenchDeviceIdle=false;workbenchIdleVerified=false
        workbenchError=unknown ? "已断开；设备停止状态未确认，可能仍在录音。请检查指示灯。" : "已断开；不会自动重连或录音。"
        if !workbenchLastDiagnostic.isEmpty {workbenchError=(workbenchError ?? "")+" "+workbenchLastDiagnostic}
        workbenchDisconnectPending=false
        let c=workbenchDisconnectCompletion;workbenchDisconnectCompletion=nil;onUpdate?();c?(unknown)
    }
    func forceDisconnectWorkbench(_ completion:((Bool)->Void)?=nil){
        workbenchDisconnectPending=true
        forceDisconnectIfPending(generation:workbenchGeneration,reason:"user_disconnect")
    }
    func shutdownWorkbench(completion:@escaping(Bool)->Void){disconnectWorkbench(completion:completion)}
    func retainWorkbenchDiagnostic(_ finishReason:String,idleVerified:Bool) {
        guard options.workbench else{return}
        if let out=audioOutput {workbenchQueueMetrics=out.queueMetrics}
        let primary=firstFailure ?? finishReason
        let fields:[String:Any]=["schema":1,"updated_at":ISO8601DateFormatter().string(from:Date()),
            "first_failure":firstFailure ?? NSNull(),"finish_reason":finishReason,
            "failure_phase":workbenchFailurePhase ?? phase,"frames":policy.frames,
            "output_frames":workbenchOutputFrames,"queue_peak_frames":workbenchOutputPeak,
            "idle_verified":idleVerified,"mode":workbenchOutputMode.rawValue,"output_queue":workbenchQueueMetrics]
        workbenchLastDiagnostic="原因：\(primary)；结束：\(finishReason)；阶段：\(workbenchFailurePhase ?? phase)；收到\(policy.frames)帧，送出\(workbenchOutputFrames)帧，最高队列\(workbenchOutputPeak)帧。"
        // One bounded status-only snapshot; never save audio, text, device identity,
        // protocol payloads or credentials. Test controllers never write here.
        guard manager != nil else{return}
        do {
            let base=try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
                .appendingPathComponent("ZiVoiceDeviceBridge/Diagnostics",isDirectory:true)
            try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let data=try JSONSerialization.data(withJSONObject:fields,options:[.sortedKeys])
            guard data.count<4096 else{return}
            try data.write(to:base.appendingPathComponent("last-session.json"),options:.atomic)
        }catch{event("diagnostic_snapshot_unavailable")}
    }
    func workbenchSessionFinished(_ why:String,_ code:Int32){
        if phase=="disconnected",peripheral==nil{return}
        let linkLost=why.contains("disconnected") || why.contains("connect_failed")
        let stoppedVerified=policy.state == .ended
        let unknown=(workbenchStopUnknown || policy.ownsStart || policy.file != nil) && !stoppedVerified
        workbenchStopUnknown=unknown
        let complete=policy.protocolAudioComplete && assembly.buffered==0
        let originalFailure=firstFailure
        let failedSession=originalFailure != nil || code != 0
        retainWorkbenchDiagnostic(why,idleVerified:stoppedVerified)
        event("workbench_session_result",["first_failure":originalFailure ?? NSNull(),"finish_reason":why,
              "failure_phase":workbenchFailurePhase ?? phase,"frames":policy.frames,"output_frames":workbenchOutputFrames,
              "queue_peak_frames":workbenchOutputPeak,"idle_verified":stoppedVerified,"audio_complete":complete && !failedSession])
        // The event-loop tail drain already accounts for this output queue.
        // Never block the main thread waiting for audio callbacks here.
        audioOutput?.close();audioOutput=nil
        workbenchSessionDefaultOutput=nil;workbenchSessionLimitSeconds=15
        if linkLost{peripheral=nil;writer=nil}
        assembly=Assembler();policy=PilotPolicy();fileCrypto=nil;headerSeen=false
        firstAt=nil;lastAudioAt=nil;idleVerifiedAt=nil;stopSent=false;stopAt=nil;stopSentAt=nil;terminalAt=nil
        startAckAt=nil;newFileAt=nil;startSentAt=nil;streamSentAt=nil;firstFailure=nil;exitStatus=0;earlyDue=nil
        awaitingOwnedStop=false;pauseStop=PauseStopSequencer();pauseFrames=0;pauseFirstSeq=nil;pauseLastSeq=nil
        tailTelemetry=TailTelemetry();stopVerification=StopIdleVerification();headDiagnostics=HeadDiagnostics();preparation=PreparationTiming()
        speechTrial=SpeechTrial();trialWAV=nil;trialWindow=nil
        manualStartPending=false;lastRms=0;workbenchDeviceIdle=false
        if decoder == nil { decoder = decoderFactory.map{$0()} ?? (try? LiveOpus()) }
        let decoderUsable = decoder != nil
        workbenchIdleVerified = stoppedVerified && decoderUsable
        if !decoderUsable{phase="error";workbenchError="音频解码器不可用（现有libopus校验失败）；不会进入可试音状态。"}
        else if linkLost{phase="disconnected";workbenchError=unknown ? "连接断开；设备可能仍在录音，请检查指示灯后重新扫描。" : "连接已断开；重新扫描后再连接。"}
        else if unknown{phase="unknown";workbenchError="停止状态未确认；设备可能仍在录音。请检查指示灯并断开。"}
        else if !stoppedVerified{phase="error";workbenchError="连接或协议失败（\(why)）；不会进入可试音状态。"}
        else{
            phase="idleReady";workbenchError=nil
            if let originalFailure {
                let description:String
                switch originalFailure {
                case "audio_output_backlog": description="系统麦克风缓冲达到960毫秒上限，已保护性停止"
                case "workbench_default_output_changed": description="播放设备发生变化，已停止收音"
                case "live_gap": description="蓝牙音频序号出现缺口，已停止收音"
                default: description="收音中断"
                }
                workbenchError="\(description)；录音豆已确认停止。\(workbenchLastDiagnostic)"
            }else{workbenchNotice=complete && !failedSession ? "已停止并核验设备空闲；连接保留，可再次开始。" : "已停止并核验设备空闲；本次音频完整性未通过。\(workbenchLastDiagnostic)"}
        }
        if let error=workbenchError,!error.contains(workbenchLastDiagnostic) {
            workbenchError=error+" "+workbenchLastDiagnostic
        }
        onUpdate?()
        if workbenchDisconnectPending{forceDisconnectIfPending(generation:workbenchGeneration,reason:"session_finished",deviceStateUnknown:unknown)}
    }
    init(_ o:PilotOptions){options=o;super.init()}
    func begin(){
        preparation.mark(.began,at:now)
        initialOutput=defaultOutput();outputBefore=OutputSnapshot.capture()
        event("policy",["public_test_only":true,"max_recording_s":options.seconds,"pc_audio_saved":false,"device_file_may_be_saved_and_synced":true,"global_audio_route_write":false,"early_live_experiment":options.earlyLive,"production_ready":false])
        if (options.device != nil || options.workbench) && !options.inspectOnly {
            do {decoder=try LiveOpus();if let uid=options.output{sink=try AudioSink(uid:uid)};if let path=options.capturePath{trialWAV=try TrialWAV(path:path)};if let path=options.comparisonPath{comparisonWAV=try TrialWAV(path:path);comparisonDecoder=try LiveOpus()}}catch{finish("audio_preflight_failed",2);return}
        }
        if options.speechTest {
            _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
            trialWindow=SpeechTrialWindow()
            if options.comparisonPath != nil {
                trialWindow?.detail.stringValue="变绿后读：开头是九，中间是五，最后是七。\n最后一个字说完就点“结束收音”。\n随后自动读取同一条设备录音，无需再次说话。"
            }
            trialWindow?.onStop = { [weak self] in self?.requestStop() }
            trialWindow?.onCancel = { [weak self] in self?.fail("user_cancelled") }
            event("speech_trial_policy",["capture_authorized_by_cli":options.capturePath != nil,"maximum_s_after_ready":options.seconds,"startup_completeness_gate_unchanged":true])
        }
        deadline=options.workbench ? now+3600 : now+12;hardDeadline=options.workbench ? now+3600 : now+60
        for sig in [SIGINT,SIGTERM]{signal(sig,SIG_IGN);let s=DispatchSource.makeSignalSource(signal:sig,queue:.main);s.setEventHandler{[weak self] in self?.fail("interrupted")};s.resume();signals.append(s)}
        let t=DispatchSource.makeTimerSource(queue:.main);t.schedule(deadline:.now(),repeating:.milliseconds(50));t.setEventHandler{[weak self] in self?.tick()};t.resume();timer=t
        manager=CBCentralManager(delegate:self,queue:.main,options:[CBCentralManagerOptionShowPowerAlertKey:false])
    }
    func tick(){
        guard !finished else{return}
        if options.speechTest, !stopSent, firstFailure==nil, defaultOutput() != initialOutput {fail("default_output_changed_during_trial");return}
        if !options.workbench,now>=hardDeadline{finish("hard_timeout_device_state_unknown",2);return}
        if options.workbench, let out=audioOutput {
            // Playback routing is independent of the explicitly bound sink.
            // AudioSink still validates the actual BlackHole target, format,
            // liveness and rejects routing system playback into BlackHole.
            do {try out.validateRoute()} catch {fail("workbench_output_route_unavailable_"+((error as? ProbeError)?.description ?? "unknown"));return}
        }
        if let limit=comparisonDeadline {
            if now>=limit {finish("comparison_timeout",2);return}
            if comparison.readyToComplete,assembly.buffered==0 {
                do {try comparison.complete(buffered:assembly.buffered,samples:comparisonWAV?.samples ?? -1)
                    finish(liveFinishReason ?? "comparison_live_outcome_missing",liveFinishCode ?? 2)
                }catch{fail((error as? ProbeError)?.description ?? "comparison_incomplete")}
            }
            return
        }
        if let t=idleVerifiedAt {
            switch tailDrainDecision(elapsed:now-t,quiet:now-(lastAudioAt ?? t),pending:audioOutput?.pending ?? sink?.pending ?? 0,
                                     lastFlag:policy.lastFlag,terminalMatched:policy.terminalMatched,unparsed:assembly.buffered) {
            case .finish: finishLiveDrain(reason,exitStatus)
            case .timeout:
                // Field-observed signature (tail-delivery-20261117.json): every
                // marker-delivered trial received frames past idle; both trials with
                // missing tail markers received none after idle. Surface those
                // counters with the timeout itself; no acceptance meaning.
                let tail=tailTelemetry.fields(stop:stopSentAt,idle:idleVerifiedAt,terminal:terminalAt,finish:now)
                event("tail_drain_budget_exhausted",["last_flag":policy.lastFlag,"terminal_matched":policy.terminalMatched,"unparsed_bytes":assembly.buffered,"pending_output_frames":audioOutput?.pending ?? sink?.pending ?? 0,"frames_after_stop":tailTelemetry.afterStop,"frames_after_idle":tailTelemetry.afterIdle,"frames_after_terminal":tailTelemetry.afterTerminal,"last_audio_minus_idle_s":tail["last_audio_minus_idle_s"] ?? NSNull(),"last_audio_minus_terminal_s":tail["last_audio_minus_terminal_s"] ?? NSNull()])
                finishLiveDrain("tail_drain_timeout",2)
            case .wait: break
            }
            return
        }
        if pauseStop.active {
            switch pauseStop.poll(at:now) {
            case .sendFinalStop(let why):
                event("pause_sequence_final_stop",["reason":why,"frames_during_pause":pauseFrames,"ack_received":pauseStop.pauseAckAt != nil])
                requestStop(forceDirect:true)
            case .none: break
            }
            if pauseStop.active {return}
        }
        if let t=earlyDue,now>=t {earlyDue=nil;do {try sendEarly()} catch {fail((error as? ProbeError)?.description ?? "early_send_failed")};return}
        if phase=="verify",firstFailure==nil {
            do {
                // Absolute deadline also applies when a requery was sent and never
                // answered (retryAt=nil): do not fall through to the generic timeout.
                try stopVerification.checkDeadline(at:now)
                if try stopVerification.takeDue(at:now) {try write(.info);stopVerification.markReplyExpected();return}
            } catch {fail((error as? ProbeError)?.description ?? "stop_verification_retry_failed");return}
        }
        if let t=stopAt,now>=t,!stopSent {requestStop();return}
        if now>=deadline,awaitingOwnedStop{finish(reason+"_new_session_unconfirmed_check_device",2);return}
        if options.workbench {
            if phase=="idleCheck",now>=deadline{
                manualStartPending=false;phase="idleTimeout"
                workbenchError="设备状态检查超时；请点刷新或断开。";onUpdate?()
            } else if workbenchBoundedPhase,now>=deadline{fail("timeout_"+phase)}
            return
        }
        if now>=deadline{if options.device==nil{finish(seen.isEmpty ? "no_device_found":"scan_finished",seen.isEmpty ? 2:0)}else{fail("timeout_"+phase)}}
    }
    func finishLiveDrain(_ why:String,_ code:Int32) {
        guard options.comparisonPath != nil else {finish(why,code);return}
        liveFinishedAt=now;liveFinishReason=why;liveFinishCode=code
        do {
            let id=try comparison.begin(policy,authorized:options.comparisonPath != nil,
                                        failed:firstFailure != nil || exitStatus != 0,buffered:assembly.buffered)
            comparisonDeadline=now+15;phase="comparison_head"
            trialWindow?.comparing()
            event("live_result_frozen",["drain_reason":why,"drain_exit_code":code,"frames":policy.frames,"last_flag":policy.lastFlag,"audio_complete":policy.protocolAudioComplete && code==0])
            try write(.finished(id))
            event("same_recording_file_requested",["current_session_only":true,"history_listed":false,"max_file_frames":1000])
        }catch{fail((error as? ProbeError)?.description ?? "comparison_start_failed")}
    }
    func finish(_ why:String,_ code:Int32){
        if options.workbench {workbenchSessionFinished(why,code);return}
        guard !finished else{return};finished=true;timer?.cancel();manager?.stopScan();sink?.close()
        abandonPauseProbe(why)
        speechTrial.close();trialWindow?.window.orderOut(nil)
        if let p=peripheral{manager?.cancelPeripheralConnection(p)}
        var f:[String:Any]=["reason":why,"frames":policy.frames,"first_sequence":policy.first.map(Int.init) ?? -1,"estimated_prefix_missing_s":Double(policy.prefixFramesMissing)*0.02,"starts_at_zero":policy.fromStartComplete,"last_flag":policy.lastFlag,"stop_event":policy.stopObserved,"end_matches_session":policy.terminalMatched,"device_idle_verified":policy.state == .ended,"audio_complete":policy.protocolAudioComplete && code==0 && assembly.buffered==0,"pc_audio_saved":false,"asr_executed":false,"system_microphone_acceptance":"not_yet_tested","acoustic_latency":"not_measured","default_output_unchanged":defaultOutput()==initialOutput && initialOutput != nil,"queue_peak_frames":sink?.peakPending ?? 0,"clipped_output_samples":sink?.clips ?? 0]
        f["early_live_experiment"]=options.earlyLive
        f["stop_busy_observations"]=stopVerification.busyObservations
        f["connection_route"]=connectionRoute
        f["preparation_timing_s"]=preparation.metrics
        f["preparation_timing_invalid_observations"]=preparation.invalidObservations
        f["preparation_acceptance"]="diagnostic_only_not_warm_p95"
        f["tail_timing"]=tailTelemetry.fields(stop:stopSentAt,idle:idleVerifiedAt,terminal:terminalAt,finish:liveFinishedAt ?? now)
        var finalCode=code
        if options.comparisonPath != nil {
            f["device_file_comparison"]=comparison.fields
            if let why=liveFinishReason {f["live_drain_reason"]=why;f["live_drain_exit_code"]=liveFinishCode ?? 2}
            if let wav=comparisonWAV {
                do {try wav.finish();f["device_file_wav_saved"]=true;f["device_file_pcm_samples"]=wav.samples;f["device_file_pcm_peak_abs"]=wav.peakAbs;f["device_file_pcm_over_unit_samples"]=wav.overUnitSamples}
                catch {f["device_file_capture_error"]=(error as? ProbeError)?.description ?? "comparison_capture_failed";finalCode=2}
            }
        }
        if let wav=trialWAV {
            do {try wav.finish();f["pc_audio_saved"]=true;f["saved_pcm_samples"]=wav.samples;f["saved_pcm_rate_hz"]=48000;f["saved_pcm_format"]="float32_unchanged";f["source_pcm_peak_abs"]=wav.peakAbs;f["source_pcm_over_unit_samples"]=wav.overUnitSamples}
            catch {f["capture_error"]=(error as? ProbeError)?.description ?? "capture_failed";finalCode=2}
        }
        if options.speechTest {
            f["ready_speech_test"]=true
            f["post_ready_transport_intact"]=speechTrial.transportIntact(policy,failed:finalCode != 0 || firstFailure != nil,buffered:assembly.buffered)
            f["speech_acoustic_completeness"]="requires_reference_and_listening"
            f["ready_sequence"]=speechTrial.readySequence.map(Int.init) ?? -1
            if let t=speechTrial.readyAt,let s=startSentAt {f["start_to_ready_s"]=t-s}
        }
        f["early_delay_ms"]=options.earlyDelay*1000
        if let ms=options.pauseBeforeStopMs {
            f["pause_before_stop_ms"]=ms
            f["pause_sequence_outcome"]=pauseStop.outcome.rawValue
            f["pause_ack_received"]=pauseStop.pauseAckAt != nil
            if let s=pauseStop.pauseSentAt,let a=pauseStop.pauseAckAt{f["pause_ack_s"]=a-s}
            f["pause_frames_received"]=pauseFrames
            if let q=pauseFirstSeq{f["pause_first_sequence"]=Int(q)}
            if let q=pauseLastSeq{f["pause_last_sequence"]=Int(q)}
            f["pause_duplicate_acks"]=pauseStop.duplicateAcks
            f["pause_late_acks"]=pauseStop.lateAcks
            f["pause_final_stop_sent"]=stopSent
            f["pause_probe_note"]="ordering probe only; no acoustic capture, same-file completeness or realtime acceptance proof"
        }
        f["file_head_observations"]=headDiagnostics.samples
        f["file_head_observation_count"]=headDiagnostics.count
        f["file_head_observations_omitted"]=headDiagnostics.omitted
        if let firstFailure {f["first_failure"]=firstFailure}
        if stopVerification.unknownLayoutObservations > 0 || stopVerification.duplicateUnknownLayout > 0 {
            f["stop_info_layout_unknown_observations"]=stopVerification.unknownLayoutObservations
            f["stop_info_layout_duplicate_observations"]=stopVerification.duplicateUnknownLayout
            f["stop_info_layout_last_payload_bytes"]=stopInfoUnknownBytes
            if let code=stopInfoUnknownState {f["stop_info_layout_last_state_code"]=code}
            f["stop_info_layout_recovery_note"]="unknown retained; read-only requery inside the original 2s deadline; never treated as idle or busy"
        }
        if postFailureAudioNotifications > 0 {
            f["post_failure_audio_notifications_discarded"]=postFailureAudioNotifications
            f["post_failure_audio_frames_discarded"]=postFailureAudioFrames
            f["post_failure_discard_note"]="discarded by policy, never decoded; count only proves arrival, not content"
        }
        f["last_sequence"]=policy.last.map(Int.init) ?? -1
        f["unparsed_transport_bytes"]=assembly.buffered
        if let t=startSentAt,let a=startAckAt {f["start_to_ack_s"]=a-t}
        if let t=startSentAt,let n=newFileAt {f["start_to_new_file_s"]=n-t}
        if let t=stopSentAt,let n=terminalAt {f["stop_to_terminal_s"]=n-t}
        if let t=stopSentAt,let n=idleVerifiedAt {f["stop_to_idle_s"]=n-t}
        f["music_output_observation"]=outputBefore?.comparison(OutputSnapshot.capture()) ?? ["state":"unknown"]
        if let start=startSentAt,let first=firstAt{f["start_command_to_first_decoded_s"]=first-start}
        if let start=streamSentAt,let first=firstAt{f["stream_request_to_first_decoded_s"]=first-start}
        if let lag=streamAttachLag(startToFirstPCM:startSentAt.flatMap{s in firstAt.map{$0-s}},firstSequence:policy.first){f["stream_attach_lag_s"]=lag}
        f["notification_interval_p95_s"]=percentile(interArrival.values,0.95) ?? 0;f["decode_to_output_enqueue_p95_s"]=percentile(outputPushTimes.values,0.95) ?? 0
        f["timing_sample_scope"]="most_recent_2048_per_session";f["timing_sample_count"]=outputPushTimes.total
        if finalCode==0, !options.inspectOnly, options.device != nil, !(policy.protocolAudioComplete && assembly.buffered==0) {f["reason"]="device_stopped_audio_completeness_unproven";event("summary",f);exit(2)}
        event("summary",f);exit(finalCode)
    }
    func fail(_ why:String){
        if let failureCapture {failureCapture(why);return}
        guard !finished else{return};if firstFailure==nil {firstFailure=why;workbenchFailurePhase=phase;event("failure",["reason":why,"phase":phase])};reason=why;exitStatus=2;earlyDue=nil;sink?.close()
        retainWorkbenchDiagnostic("stopping_after_failure",idleVerified:false)
        audioOutput?.close();audioOutput=nil
        speechTrial.close();trialWindow?.ending()
        earlyBuffer.discard()
        if comparisonDeadline != nil {finish(why,2);return}
        switch Pilot.failureRoute(ownsStart:policy.ownsStart,hasFile:policy.file != nil,stopSent:stopSent,state:policy.state) {
        case .awaitNewSession:
            if !awaitingOwnedStop {awaitingOwnedStop=true;phase="awaiting_owned_stop";deadline=now+3;event("waiting_for_owned_session_to_stop")}
        case .requestStop:requestStop(forceDirect:true)
        case .confirmedStop:finish(why,2)
        case .stopUnconfirmed:finish(why+"_stop_unconfirmed_check_device",2)
        case .checkIndicator:finish(why+"_check_device_indicator",2)
        }
    }
    func requestStop(forceDirect:Bool=false){
        guard !stopSent else{
            // Defensive: a stop was already sent, so a still-live probe is moot and
            // must not keep tick() returning early (which would starve verify retries).
            if pauseStop.active {pauseStop.forcedFinalStopWritten()}
            return
        }
        // A stop notice may arrive before our own timer (observed externally-triggered
        // stop ordering): never send a second stop into an already stopping/stopped
        // device; just retire the timer and let verification/drain proceed.
        if policy.stopObserved || policy.state == .ended {
            if pauseStop.active {pauseStop.deviceStopped()}
            stopAt=nil;event("stop_skipped_device_already_stopping");return
        }
        if !forceDirect,let ms=options.pauseBeforeStopMs,policy.ownsStart,policy.file != nil,
           policy.state == .streaming,!policy.lastFlag,!policy.terminalMatched {
            if pauseStop.active {stopAt=nil;return}
            guard pauseStop.begin(at:now) else {return}
            speechTrial.close();trialWindow?.ending();stopAt=nil
            do {
                try write(.pauseOwned);pauseStop.pauseWritten()
                phase="pausing";deadline=now+5
                event("pause_before_stop_sent",["window_ms":ms,"ack_timeout_s":PauseStopSequencer.ackTimeout,"note":"pause is not stop"])
                return
            } catch {
                pauseStop.pauseSendFailed()
                event("pause_send_failed_final_stop",["reason":(error as? ProbeError)?.description ?? "pause_write_failed"])
                requestStop(forceDirect:true);return
            }
        }
        speechTrial.close();trialWindow?.ending()
        do {
            try policy.requestStop();stopSent=true;stopSentAt=now;stopAt=nil;phase="stopping"
            try write(.stopOwned);deadline=now+5
            if pauseStop.stopSendPending {pauseStop.finalStopWritten()} else if pauseStop.active {pauseStop.forcedFinalStopWritten()}
            if options.pauseBeforeStopMs != nil {
                event("owned_stop_sent",["force_direct":forceDirect,"pause_experiment":true])
            } else {
                event("owned_stop_sent") // baseline event payload when the probe is off
            }
        } catch {
            if pauseStop.stopSendPending {pauseStop.finalStopWriteFailed()} else if pauseStop.active {pauseStop.forcedStopWriteFailed()}
            finish(pauseStop.pauseAckAt != nil ? "stop_send_failed_after_pause_device_paused_check_indicator"
                                               : "stop_send_failed_check_device_indicator",2)
        }
    }
    // Disconnect/final-exit path: the probe can no longer send anything, so it must
    // record an explicit abort instead of looking like a completed sequence.
    func abandonPauseProbe(_ why:String) {
        guard pauseStop.active else {return}
        pauseStop.abort()
        event("pause_sequence_aborted",["reason":why,"frames_during_pause":pauseFrames,"ack_received":pauseStop.pauseAckAt != nil])
    }
    func write(_ r:Request)throws{
        if options.inspectOnly {guard case .info = r else {throw ProbeError.invalid("inspect_read_only")}}
        switch r {
        case .info:guard ["info","idle","idleCheck","verify"].contains(phase) else{throw ProbeError.invalid("info_wrong_phase")}
        case .handshake:guard phase=="key" else{throw ProbeError.invalid("key_wrong_phase")}
        case .startOwned:guard policy.state == .starting,phase=="starting" else{throw ProbeError.invalid("start_wrong_phase")}
        case .pauseOwned:guard options.pauseBeforeStopMs != nil,policy.ownsStart,
                                (policy.state == .starting || policy.state == .streaming),
                                policy.file != nil,!stopSent,!policy.lastFlag,!policy.terminalMatched else{throw ProbeError.invalid("pause_wrong_phase")}
        case .stopOwned:guard policy.ownsStart,policy.state == .stopping,stopSent else{throw ProbeError.invalid("stop_wrong_phase")}
        case .earlyLiveOwned:guard options.earlyLive,policy.canRequestEarlyLive,!earlyRequested else{throw ProbeError.invalid("early_live_not_owned_or_duplicate")}
        case .live(let id):guard policy.file==id,policy.state == .streaming,!headerSeen else{throw ProbeError.invalid("live_wrong_phase")}
        case .finished(let id):
            guard options.comparisonPath != nil,phase=="comparison_head",policy.file==id,
                  policy.state == .ended,policy.stopObserved,policy.terminalMatched else {throw ProbeError.invalid("pilot_never_downloads_files")}
            try comparison.authorizeRequest(id)
        }
        let b=try r.encoded()
        if let commandSink {try commandSink(r);event("command",["code":String(format:"%02X/%02X",b[5],b[6])]);return}
        guard let p=peripheral,let w=writer else{throw ProbeError.invalid("no_writer")}
        guard w.properties.contains(.write),b.count<=p.maximumWriteValueLength(for:.withResponse) else{throw ProbeError.invalid("write_capability")}
        p.writeValue(Data(b),for:w,type:.withResponse);event("command",["code":String(format:"%02X/%02X",b[5],b[6])])
    }
    func centralManagerDidUpdateState(_ c:CBCentralManager){
        guard !finished else{return};if c.state == .unknown || c.state == .resetting{return}
        guard c.state == .poweredOn else{finish("bluetooth_unavailable_\(c.state.rawValue)",2);return}
        guard phase=="scan",peripheral==nil else{return}
        // A repeated poweredOn callback must not restart scanning or connection.
        if !options.workbench {guard preparation.mark(.bluetoothReady,at:now) else{return}}
        if options.connectKnown,let id=options.device {
            let known=c.retrievePeripherals(withIdentifiers:[id])
            if let index=knownPeripheralIndex(selected:id,retrieved:known.map(\.identifier)) {
                connectSelected(known[index],using:c,route:"known_identifier");return
            }
            event("known_device_unavailable_scan_same_identifier")
        }
        preparation.mark(.scanStarted,at:now);connectionRoute="scan"
        c.scanForPeripherals(withServices:[service],options:[CBCentralManagerScanOptionAllowDuplicatesKey:false]);event("scanning")
    }
    func centralManager(_ c:CBCentralManager,didDiscover p:CBPeripheral,advertisementData:[String:Any],rssi:NSNumber){
        guard !finished,peripheral==nil else{return}
        if options.workbench {
            discovered[p.identifier]=p
            if let i=candidates.firstIndex(where:{$0.id==p.identifier}){candidates[i].rssi=rssi.intValue}
            else{candidates.append((p.identifier,rssi.intValue));event("workbench_candidate",["rssi":rssi.intValue])}
            onUpdate?();return
        }
        if seen.insert(p.identifier).inserted{event("candidate",["local_identifier":p.identifier.uuidString,"rssi":rssi.intValue])}
        connectSelected(p,using:c,route:"scan")
    }
    func connectSelected(_ p:CBPeripheral,using c:CBCentralManager,route:String){
        guard !finished,phase=="scan",peripheral==nil,(options.workbench ? selectedDevice : options.device)==p.identifier else{return}
        peripheral=p;p.delegate=self;c.stopScan();phase="connecting";deadline=now+10;workbenchGeneration+=1
        connectionRoute=route;preparation.mark(.connectRequested,at:now)
        event("connect_requested",["route":route,"exact_selected_identifier":true])
        c.connect(p,options:nil)
    }
    func accepts(_ p:CBPeripheral)->Bool{!finished && peripheral === p && p.identifier==(options.workbench ? selectedDevice : options.device)}
    func centralManager(_ c:CBCentralManager,didConnect p:CBPeripheral){
        guard accepts(p),phase=="connecting" else{return}
        preparation.mark(.connected,at:now);phase="services";p.discoverServices([service]);deadline=now+8
    }
    func centralManager(_ c:CBCentralManager,didFailToConnect p:CBPeripheral,error:Error?){guard accepts(p) else{return};finish("connect_failed",2)}
    func centralManager(_ c:CBCentralManager,didDisconnectPeripheral p:CBPeripheral,error:Error?){guard accepts(p) else{return};finish("disconnected_device_state_unknown",2)}
    func peripheral(_ p:CBPeripheral,didDiscoverServices error:Error?){
        guard accepts(p),phase=="services" else{return}
        guard error==nil,let s=p.services?.first(where:{$0.uuid==service})else{fail("service_missing");return}
        preparation.mark(.servicesReady,at:now);phase="characteristics";deadline=now+8;p.discoverCharacteristics([writeCharacteristic,notifyCharacteristic],for:s)
    }
    func peripheral(_ p:CBPeripheral,didDiscoverCharacteristicsFor s:CBService,error:Error?){
        guard accepts(p),phase=="characteristics",s.uuid==service else{return}
        guard error==nil,let w=s.characteristics?.first(where:{$0.uuid==writeCharacteristic}),let n=s.characteristics?.first(where:{$0.uuid==notifyCharacteristic}),w.properties.contains(.write),n.properties.contains(.notify)||n.properties.contains(.indicate)else{fail("characteristics_missing");return};writer=w;preparation.mark(.characteristicsReady,at:now);phase="notify";deadline=now+8;p.setNotifyValue(true,for:n)
    }
    func peripheral(_ p:CBPeripheral,didUpdateNotificationStateFor c:CBCharacteristic,error:Error?){
        guard accepts(p),c.uuid==notifyCharacteristic else{return}
        guard error==nil,c.isNotifying else{fail("notify_failed");return}
        guard phase=="notify" else{return}
        preparation.mark(.notifyReady,at:now);phase="info";deadline=now+5;do{try write(.info)}catch{fail("initial_info_failed")}
    }
    func peripheral(_ p:CBPeripheral,didWriteValueFor c:CBCharacteristic,error:Error?){guard accepts(p) else{return};if error != nil{fail("write_failed")}}
    func peripheral(_ p:CBPeripheral,didUpdateValueFor c:CBCharacteristic,error:Error?){
        guard accepts(p) else{return};guard error==nil,c.uuid==notifyCharacteristic,let value=c.value else{fail("notify_data_error");return}
        do{try consumeNotification(Array(value))}catch{fail((error as? ProbeError)?.description ?? "decode_or_crypto_failed")}
    }
    // Shared by the actual BLE callback and offline wire-boundary tests.
    // A checksum/reassembly error is rejected before dispatching any packet.
    func consumeNotification(_ bytes:[UInt8])throws {
        let corrupt=assembly.corrupt
        let packets=try assembly.feed(bytes)
        guard assembly.corrupt==corrupt else{throw ProbeError.invalid("framing_error")}
        for packet in packets {try handle(packet)}
    }
    func handle(_ p:Packet)throws{
        if let fields=headDiagnostics.observe(p,expected:policy.file,early:earlyRequested) {event("file_head_observed",fields)}
        guard p.accepted else{throw ProbeError.invalid("device_rejected_"+p.code)}
        if comparisonDeadline != nil {try handleComparison(p);return}
        switch(p.type,p.id){
        case(1,1):
            if options.workbench,["scan","disconnected","error","connecting","services","characteristics","notify"].contains(phase){
                event("workbench_late_info_ignored",["phase":phase]);return
            }
            // After idle was verified, a duplicate idle may be ignored, but only after
            // validating firmware and recording=false: busy/wrong-firmware/malformed
            // replies during the drain stay fail-closed.
            if phase=="verify",policy.state == .ended {
                let info=try DeviceInfo(p.payload)
                guard info.isRequestedRecorder else{throw ProbeError.invalid("firmware_not_requested")}
                guard !info.recording else{throw ProbeError.invalid("post_verification_recording_true")}
                event("post_verification_info_ignored",["payload_bytes":p.payload.count]);return
            }
            if phase=="verify" {
                // Absolute cutoff for read-only verification replies: at/after it the
                // session fails as unconfirmed, never renews the deadline.
                guard let cutoff=stopVerification.deadline,now < cutoff else {throw ProbeError.invalid("device_stop_unconfirmed")}
                do {
                    let info=try DeviceInfo(p.payload)
                    guard info.isRequestedRecorder else{throw ProbeError.invalid("firmware_not_requested")}
                    event("device_state",["firmware":info.firmware,"case_firmware":info.caseFirmware,"wifi_firmware":info.wifiFirmware,"recording":info.recording])
                    if info.recording {
                        try stopVerification.stillRecording(at:now)
                        event("device_stop_pending",["busy_observations":stopVerification.busyObservations]);return
                    }
                    try policy.verifiedIdle(true);stopVerification.complete();idleVerifiedAt=now;deadline=now+1;event("device_stop_verified");return
                } catch {
                    // Only the layout guard is recoverable here: the reply proves neither
                    // idle nor busy. Firmware/layout-format errors stay fatal.
                    guard (error as? ProbeError)?.description == "device_info_layout_unknown" else {throw error}
                    stopInfoUnknownBytes=p.payload.count
                    stopInfoUnknownState=p.payload.count>50 ? Int(p.payload[50]) : nil
                    try stopVerification.unknownLayout(at:now)
                    if stopVerification.unknownLayoutObservations + stopVerification.duplicateUnknownLayout <= 8 {
                        event("stop_info_layout_unknown",["payload_bytes":p.payload.count,"state_code":stopInfoUnknownState ?? NSNull(),"unknown_observations":stopVerification.unknownLayoutObservations,"duplicate_observations":stopVerification.duplicateUnknownLayout,"note":"unknown retained; not idle or busy"])
                    }
                    return
                }
            }
            let info=try DeviceInfo(p.payload)
            guard info.isRequestedRecorder else{throw ProbeError.invalid("firmware_not_requested")}
            event("device_state",["firmware":info.firmware,"case_firmware":info.caseFirmware,"wifi_firmware":info.wifiFirmware,"recording":info.recording])
            if options.inspectOnly {finish("inspection_complete_no_recording_commands",0);return}
            if options.workbench,phase=="idleTimeout"{event("workbench_stale_idle_ignored");return}
            if options.workbench,phase=="idleCheck",now>=deadline{
                manualStartPending=false;phase="idleTimeout"
                workbenchError="设备状态检查超时；请点刷新或断开。";onUpdate?();return
            }
            if options.workbench,(phase=="idleCheck"||phase=="idleReady"||phase=="idleBusy"){
                workbenchDeviceIdle = !info.recording
                if info.recording{
                    manualStartPending=false;workbenchIdleVerified=false;phase="idleBusy"
                    workbenchNotice="设备正在录音（可能由按键开始）；本工具不会自动接管。"
                    event("workbench_device_busy_refused",["recording":true]);onUpdate?();return
                }
                workbenchIdleVerified=true;workbenchStopUnknown=false
                if manualStartPending,!workbenchDisconnectPending{manualStartPending=false;beginOwnedStart();return}
                manualStartPending=false
                phase="idleReady";workbenchNotice="已连接且设备空闲，可开始试音。";onUpdate?();return
            }
            guard phase=="info"||phase=="idle",!info.recording else{throw ProbeError.invalid("existing_recording_refused")}
            infoReads+=1
            if phase=="info"{preparation.mark(.initialIdle,at:now);phase="key";preparation.mark(.keyRequested,at:now);deadline=now+5;try write(.handshake(crypto.publicKey))}
            else{beginOwnedStart()}
        case(0x2e,1):
            guard phase=="key" else{throw ProbeError.invalid("unsolicited_key")};try crypto.complete(p.payload);preparation.mark(.keyReady,at:now)
            if options.workbench{phase="idleCheck";deadline=now+5;try write(.info)}else{phase="idle";try write(.info)}
        case(0x1a,6):
            guard p.payload.count>=4 else{throw ProbeError.invalid("new_file_shape")}
            if options.workbench,!policy.ownsStart{
                event("workbench_external_recording_ignored",["note":"no capture without owned start"])
                workbenchNotice="设备开始了外部录音；本工具不会接管。";onUpdate?();return
            }
            let id=u32(p.payload,0);try policy.opened(id);newFileAt=now;preparation.mark(.newFile,at:newFileAt!)
            event("new_owned_recording",["start_to_notice_s":now-(startSentAt ?? now)])
            if awaitingOwnedStop {awaitingOwnedStop=false;requestStop(forceDirect:true);return}
            phase="head";stopAt=(options.speechTest || options.workbench) ? nil : (startSentAt ?? now)+options.seconds;deadline=now+3
            if earlyRequested {try acceptEarlyIfMatched()}
            else {earlyDue=nil;streamSentAt=now;preparation.mark(.streamRequested,at:streamSentAt!);try write(.live(id))}
        case(0x1a,7):
            if awaitingOwnedStop {return}
            if earlyRequested,!headerSeen {try earlyBuffer.acceptHead(p.payload);try acceptEarlyIfMatched();return}
            guard phase=="head",!headerSeen,let id=policy.file else{throw ProbeError.invalid("unsolicited_head")}
            try installHeader(p.payload,id:id)
        case(0x1a,8):
            if options.workbench,!workbenchSessionActive{workbenchStaleAudio+=1;event("workbench_stale_audio_ignored",["notifications":workbenchStaleAudio]);return}
            if awaitingOwnedStop || exitStatus != 0 {
                postFailureAudioNotifications += 1
                if p.payload.count % 166 == 0 { postFailureAudioFrames += p.payload.count / 166 }
                return
            }
            if earlyRequested,!headerSeen {try earlyBuffer.append(p.payload);return}
            guard headerSeen,let key=fileCrypto,let decoder,!p.payload.isEmpty,p.payload.count%166==0 else{throw ProbeError.invalid("audio_shape")}
            let receipt=now;if let prev=lastAudioAt{interArrival.append(receipt-prev)};lastAudioAt=receipt
            for o in stride(from:0,to:p.payload.count,by:166){
                let seq=u32(p.payload,o),flags=p.payload[o+4];try policy.frame(seq:seq,flags:flags)
                let opus=try key.decode(Array(p.payload[o+5..<o+165]),sequence:seq)
                let pcm=try decoder.decode(opus);let decoded=now
                if pauseStop.pauseSentAt != nil,!stopSent {
                    pauseFrames+=1;if pauseFirstSeq==nil{pauseFirstSeq=seq};pauseLastSeq=seq
                }
                if options.comparisonPath != nil {try comparison.observeLive(sequence:seq,flags:flags,opus:opus)}
                tailTelemetry.record(sequence:seq,flags:flags,received:receipt,stop:stopSentAt,idle:idleVerifiedAt,terminal:terminalAt)
                try trialWAV?.append(pcm)
                if let wav=trialWAV {
                    event("captured_pcm_frame",["sequence":seq,"sample_offset":wav.samples-pcm.count,"sample_count":pcm.count,"received_monotonic_s":receipt,"decoded_monotonic_s":decoded,"last_flag":flags&4 != 0])
                }
                if let audioOutput{
                    workbenchOutputPeak=max(workbenchOutputPeak,audioOutput.pending)
                    try audioOutput.push(pcm)
                    workbenchOutputFrames+=1;workbenchOutputPeak=max(workbenchOutputPeak,audioOutput.pending)
                }
                if let sink{try sink.push(pcm)};outputPushTimes.append(now-decoded)
                lastRms=sqrt(pcm.reduce(0.0){$0+Double($1*$1)}/Double(pcm.count))
                if firstAt==nil{preparation.mark(.firstDecoded,at:decoded);firstAt=now;firstBatchFrames=p.payload.count/166;event("live_audio_available",["first_sequence":seq,"startup_audio_missing":seq>0,"route":audioOutput != nil || options.output != nil ? "existing_blackhole_test_only":"meter_only","warning":"首音完整性与声学延迟未验收，勿据此宣称系统麦克风可用。"])
                    if options.workbench{
                        let limit=workbenchOutputMode == .blackHole ? workbenchSessionLimitSeconds : options.seconds
                        stopAt=limit.map { decoded+$0 };phase="recording"
                        workbenchNotice=workbenchOutputMode == .blackHole ? "已收到有效当前声音；持续收音直到你结束，异常时保护性停止。" : "已收到有效当前声音；15秒后自动停止。"
                        onUpdate?()}}
                if options.speechTest,speechTrial.decoded(sequence:seq,at:decoded,streaming:SpeechTrial.mayAnnounce(policy,stopSent:stopSent)) {
                    stopAt=decoded+options.seconds;trialWindow?.ready();preparation.mark(.readyPresented,at:now)
                    event("speech_ready",["first_sequence":seq,"capture_sample_offset":max(0,(trialWAV?.samples ?? 960)-960),"automatic_stop_after_s":options.seconds,"acoustic_acceptance":"not_yet_tested"])
                }
                if policy.frames%(options.workbench ? 1500 : 50)==0 {let rms=sqrt(pcm.reduce(0.0){$0+Double($1*$1)}/Double(pcm.count));event("audio_meter",["seconds":Double(policy.frames)*0.02,"rms":rms])}
            }
            if !stopSent{deadline=now+3};try maybeVerify()
        case(0x18,0x82):
            guard let action=p.payload.first else{throw ProbeError.invalid("record_control_shape")}
            if options.workbench,!policy.ownsStart{event("workbench_control_ignored",["action":Int(action)]);return}
            if action==0{
                if pauseStop.active {pauseStop.deviceStopped();event("pause_sequence_cancelled_by_device_stop",["frames_during_pause":pauseFrames])}
                guard try policy.observeStop() else{event("duplicate_stop_notice");return};speechTrial.close();trialWindow?.ending();stopAt=nil;phase="stopping";deadline=now+5;try maybeVerify()
            }
            else if action==2{
                if pauseStop.awaitingAck,pauseStop.acknowledge(at:now,windowMs:options.pauseBeforeStopMs ?? 0){
                    event("pause_acknowledged",["since_pause_s":now-(pauseStop.pauseSentAt ?? now),"window_ms":options.pauseBeforeStopMs ?? 0,"note":"pause is not stop"])
                } else if pauseStop.noteDuplicateAck(){
                    event("duplicate_pause_ack",["count":pauseStop.duplicateAcks])
                } else if pauseStop.finished || pauseStop.stopSendPending {
                    pauseStop.noteLateAck();event("late_pause_ack_ignored",["note":"final stop already sent; pause ack cannot end the session"])
                } else if pauseStop.pauseSentAt != nil {
                    pauseStop.noteLateAck();event("late_pause_ack_ignored",["note":"ack beyond bounded timeout"])
                } else {throw ProbeError.invalid("paused_is_not_stopped")}
            }
            else if action==1{
                try policy.acknowledgeStart();startAckAt=now;preparation.mark(.startAck,at:startAckAt!)
                event("start_acknowledged",["payload_bytes":p.payload.count])
                if options.earlyLive,!awaitingOwnedStop {if options.earlyDelay==0 {try sendEarly()} else {earlyDue=now+options.earlyDelay}}
            }
            else{throw ProbeError.invalid("unknown_control_event")}
        case(0x1a,0x0a):
            if options.workbench,!workbenchSessionActive{event("workbench_stale_terminal_ignored");return}
            guard p.payload.count>=9 else{throw ProbeError.invalid("terminal_shape")};try policy.terminal(u32(p.payload,5));terminalAt=now;event("session_terminal",["payload_bytes":p.payload.count]);try maybeVerify()
        default:event("other_event",["code":p.code,"length":p.payload.count])
        }
    }
    func handleComparison(_ p:Packet)throws {
        guard let limit=comparisonDeadline,now<limit else {throw ProbeError.invalid("comparison_deadline")}
        switch(p.type,p.id) {
        case(0x1a,7):
            let head=try comparison.acceptHead(p.payload)
            comparisonCrypto=try crypto.decryptor(head);phase="comparison_audio"
            event("same_recording_finite_head_verified",["expected_file_frames":comparison.expectedFrames])
        case(0x1a,8):
            guard comparison.stage == .audio,let key=comparisonCrypto,let decoder=comparisonDecoder,
                  !p.payload.isEmpty,p.payload.count%166==0 else {throw ProbeError.invalid("comparison_audio_shape_or_phase")}
            for o in stride(from:0,to:p.payload.count,by:166) {
                let seq=u32(p.payload,o),flags=p.payload[o+4]
                let opus=try key.decode(Array(p.payload[o+5..<o+165]),sequence:seq)
                try comparison.acceptFrame(sequence:seq,flags:flags,opus:opus)
                try comparisonWAV?.append(decoder.decode(opus))
            }
        case(0x1a,0x0a):
            guard p.payload.count>=9 else {throw ProbeError.invalid("comparison_terminal_shape")}
            try comparison.acceptTerminal(u32(p.payload,5))
        case(0x18,0x82):
            guard p.payload.first==0,policy.stopObserved else {throw ProbeError.invalid("comparison_recording_state_changed")}
            event("duplicate_stop_notice")
        case(0x1a,6):throw ProbeError.invalid("comparison_new_recording_refused")
        case(1,1):
            let info=try DeviceInfo(p.payload)
            guard info.isRequestedRecorder,!info.recording else {throw ProbeError.invalid("comparison_device_state_changed")}
        default:throw ProbeError.invalid("comparison_unexpected_event_"+p.code)
        }
    }
    func sendEarly()throws {
        guard !awaitingOwnedStop,exitStatus==0 else{return}
        streamSentAt=now;preparation.mark(.streamRequested,at:streamSentAt!);try write(.earlyLiveOwned);earlyRequested=true
    }
    func installHeader(_ bytes:[UInt8],id:UInt32)throws {
        fileCrypto=try crypto.decryptor(FileHead(bytes,expected:id));headerSeen=true;phase="streaming";deadline=now+3;preparation.mark(.headerReady,at:now);event("live_header_verified")
    }
    func acceptEarlyIfMatched()throws {
        guard let id=policy.file,earlyBuffer.head != nil,!headerSeen else{return}
        let (head,packets)=try earlyBuffer.release(matching:id)
        try installHeader(head,id:id)
        for bytes in packets {try handle(Packet(status:1,type:0x1a,id:8,payload:bytes))}
    }
    func maybeVerify()throws{if policy.stopObserved&&policy.state == .stopping{try policy.verifyRequested();phase="verify";try stopVerification.begin(at:now);deadline=stopVerification.deadline!;try write(.info);stopVerification.markReplyExpected()}}
}

@main enum Main {
    static func main(){do{
        let args=Array(CommandLine.arguments.dropFirst())
        if args.isEmpty {runWorkbenchApp();return}
        if args==["ui-smoke"]{exit(runUISmoke())}
        if args.count==2,args[0]=="audio-burst-smoke" {exit(runHALBurstSmoke(timingPath:args[1]))}
        if args==["audio-loopback-smoke"]{exit(runHALLoopbackSmoke())}
        if args.count==2,args[0]=="continuous-soak",let seconds=Int(args[1]) {try runContinuousCaptureValidation(seconds:seconds);return}
        if args==["self-test"]{try pilotTests();return}
        if args==["output-smoke"] {
            let sink=try AudioSink(uid:"BlackHole2ch_UID")
            for _ in 0..<50 {try sink.push([Float](repeating:0,count:960));RunLoop.main.run(until:Date().addingTimeInterval(0.02))}
            let end=Date().addingTimeInterval(1)
            while sink.pending>0 && Date()<end {RunLoop.main.run(until:Date().addingTimeInterval(0.01))}
            let remaining=sink.pending,peak=sink.peakPending;sink.close()
            guard remaining==0,defaultOutput()==sink.initialOutput else {throw ProbeError.invalid("output_smoke_drain_or_route")}
            event("output_smoke_passed",["generated_silence_s":1,"queue_peak_frames":peak,"default_output_unchanged":true,"hardware_used":false,"microphone_captured":false,"music_listening_test":"not_performed"]);return
        }
        if args==["audio-devices"]{for d in try audioDevices() where d.name=="BlackHole 2ch"{event("existing_test_output",["name":d.name,"uid":d.uid,"is_default_output":defaultOutput()==d.id])};return}
        let p=Pilot(try PilotOptions(args));p.begin();withExtendedLifetime(p){if p.options.speechTest {NSApp.run()} else {RunLoop.main.run()}}
    }catch{event("error",["reason":(error as? ProbeError)?.description ?? "preflight_error"]);exit(2)}}
}
